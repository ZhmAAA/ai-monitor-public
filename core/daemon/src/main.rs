mod privacy;
mod security;
mod terminal;

use ai_monitor_notification_engine::{NotificationConfig, NotificationEngine};
use ai_monitor_protocol::{
    AgentTask, AgentTaskEvent, DeliveryStatus, LiveMessage, NotificationDelivery, TaskDetail,
    TaskPriority, TaskSource, TaskStatus,
};
use ai_monitor_storage::{DeliveryListFilter, SqliteStore, TaskListFilter};
use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket},
        Path, Query, State, WebSocketUpgrade,
    },
    http::{
        header::{AUTHORIZATION, CONTENT_TYPE},
        HeaderName, Method, Request, StatusCode,
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{Duration as ChronoDuration, Utc};
use clap::Parser;
use privacy::{IgnoreRule, IngressDecision, PrivacyConfig, PrivacyFilter};
use security::{ApiConfig, ApiSecurity};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    net::SocketAddr,
    path::{Path as StdPath, PathBuf},
    sync::Arc,
    time::Duration as StdDuration,
};
use terminal::{build_terminal_event, TerminalEventRequest};
use thiserror::Error;
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tower_http::{
    cors::{AllowOrigin, CorsLayer},
    trace::TraceLayer,
};
use tracing::{error, info, warn};
use uuid::Uuid;

const DEFAULT_CONFIG: &str = include_str!("../../../config/default.toml");

#[derive(Debug, Parser)]
#[command(name = "ai-monitor-daemon")]
#[command(about = "Local AI Monitor daemon")]
struct Args {
    #[arg(long, default_value = "127.0.0.1:4318", env = "AI_MONITOR_BIND")]
    bind: SocketAddr,

    #[arg(long, default_value = "./ai-monitor.db", env = "AI_MONITOR_DATABASE")]
    database: PathBuf,

    #[arg(
        long,
        default_value = "./config/default.toml",
        env = "AI_MONITOR_CONFIG"
    )]
    config: PathBuf,

    #[arg(long, default_value_t = 21_600, env = "AI_MONITOR_STALE_AFTER_SECONDS")]
    stale_after_seconds: u64,

    #[arg(
        long,
        default_value_t = 60,
        env = "AI_MONITOR_STALE_SCAN_INTERVAL_SECONDS"
    )]
    stale_scan_interval_seconds: u64,

    #[arg(long, env = "AI_MONITOR_API_TOKEN")]
    api_token: Option<String>,

    #[arg(long, env = "AI_MONITOR_API_TOKEN_FILE")]
    api_token_file: Option<PathBuf>,

    #[arg(long, default_value_t = false, env = "AI_MONITOR_DISABLE_API_AUTH")]
    disable_api_auth: bool,
}

#[derive(Clone)]
struct AppState {
    store: SqliteStore,
    notifications: Arc<NotificationEngine>,
    privacy: Arc<PrivacyFilter>,
    api_security: Arc<ApiSecurity>,
    live_tx: broadcast::Sender<LiveMessage>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ai_monitor_daemon=info,tower_http=info".into()),
        )
        .init();

    let args = Args::parse();
    ensure_parent_dir(&args.database)?;

    let config_text = load_config_text(&args.config)?;
    let daemon_config = DaemonConfig::from_toml_str(&config_text)?;
    let store = SqliteStore::open(&args.database)?;
    let notification_config = NotificationConfig::from_toml_str(&config_text)?;
    let notifications = Arc::new(NotificationEngine::new(notification_config)?);
    let privacy = Arc::new(PrivacyFilter::new(
        daemon_config.privacy,
        daemon_config.ignore_rules,
    ));
    let api_security = Arc::new(ApiSecurity::load(
        &daemon_config.api,
        args.api_token,
        args.api_token_file,
        args.disable_api_auth,
    )?);
    let (live_tx, _) = broadcast::channel(256);

    let state = AppState {
        store,
        notifications,
        privacy,
        api_security,
        live_tx,
    };

    spawn_stale_task_gc(
        state.clone(),
        args.stale_after_seconds,
        args.stale_scan_interval_seconds,
    );

    let cors_allowed_origins = state.api_security.cors_allowed_origins.clone();
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::predicate(move |origin, _| {
            security::is_allowed_origin(origin, &cors_allowed_origins)
        }))
        .allow_methods([Method::GET, Method::POST, Method::DELETE, Method::OPTIONS])
        .allow_headers([
            CONTENT_TYPE,
            AUTHORIZATION,
            HeaderName::from_static("x-ai-monitor-token"),
        ]);

    let app = Router::new()
        .route("/events", post(post_event))
        .route("/terminal/events", post(post_terminal_event))
        .route("/live", get(live))
        .route("/tasks", get(list_tasks))
        .route("/tasks/{id}", get(get_task).delete(delete_task))
        .route("/notifications/providers", get(list_provider_health))
        .route("/notifications/deliveries", get(list_deliveries))
        .route("/notifications/deliveries/{id}/retry", post(retry_delivery))
        .route("/notifications/test", post(test_notification))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            require_api_auth,
        ))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = TcpListener::bind(args.bind).await?;
    info!(addr = %args.bind, database = %args.database.display(), "AI Monitor daemon listening");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn post_event(
    State(state): State<AppState>,
    Json(event): Json<AgentTaskEvent>,
) -> Result<Json<EventIngestResponse>, AppError> {
    ingest_event(&state, event).await
}

async fn post_terminal_event(
    State(state): State<AppState>,
    Json(request): Json<TerminalEventRequest>,
) -> Result<Json<EventIngestResponse>, AppError> {
    let event = build_terminal_event(request).map_err(AppError::BadRequest)?;
    ingest_event(&state, event).await
}

async fn ingest_event(
    state: &AppState,
    mut event: AgentTaskEvent,
) -> Result<Json<EventIngestResponse>, AppError> {
    if let IngressDecision::Ignored { rule_id } = state.privacy.apply_ingress(&mut event) {
        return Ok(Json(EventIngestResponse {
            task: None,
            deliveries: Vec::new(),
            ignored: true,
            ignore_rule_id: Some(rule_id),
        }));
    }

    validate_event(&event)?;
    let previous_task = state.store.get_task(&event.task_id)?;
    let replaced_task_ids = if previous_task.is_none() {
        delete_terminal_surface_peers(state, &event)?
    } else {
        Vec::new()
    };
    let task = state.store.record_event(&event)?;

    for task_id in replaced_task_ids {
        publish(state, LiveMessage::TaskDeleted { task_id });
    }

    publish(
        state,
        LiveMessage::TaskUpdated {
            event: Box::new(event.clone()),
            task: Box::new(task.clone()),
        },
    );

    let deliveries = dispatch_notifications(state, &event, &task, previous_task.as_ref()).await;
    Ok(Json(EventIngestResponse {
        task: Some(task),
        deliveries,
        ignored: false,
        ignore_rule_id: None,
    }))
}

fn delete_terminal_surface_peers(
    state: &AppState,
    event: &AgentTaskEvent,
) -> Result<Vec<String>, AppError> {
    if !is_terminal_task(event.app.as_deref(), event.source.as_str()) {
        return Ok(Vec::new());
    }

    let Some(surface) = terminal_surface_key(&event.metadata) else {
        return Ok(Vec::new());
    };

    let mut deleted_task_ids = Vec::new();
    for task in state.store.list_tasks(TaskListFilter::default())? {
        if task.task_id == event.task_id {
            continue;
        }
        if !is_terminal_task(task.app.as_deref(), task.source.as_str()) {
            continue;
        }
        if terminal_surface_key(&task.metadata).as_ref() != Some(&surface) {
            continue;
        }
        if state.store.delete_task(&task.task_id)? {
            deleted_task_ids.push(task.task_id);
        }
    }

    Ok(deleted_task_ids)
}

fn terminal_surface_key(metadata: &serde_json::Map<String, serde_json::Value>) -> Option<String> {
    for key in [
        "superset_pane_id",
        "superset_tab_id",
        "superset_terminal_id",
        "tmux_pane",
        "term_session_id",
    ] {
        if let Some(value) = metadata
            .get(key)
            .and_then(|value| value.as_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Some(format!("{key}:{value}"));
        }
    }
    None
}

fn is_terminal_task(app: Option<&str>, source: &str) -> bool {
    let normalized_source = source.to_ascii_lowercase();
    app.map(|value| value.eq_ignore_ascii_case("terminal"))
        .unwrap_or(false)
        || matches!(
            normalized_source.as_str(),
            "terminal" | "codex-cli" | "claude-code" | "gemini-cli" | "opencode" | "aider"
        )
}

fn spawn_stale_task_gc(
    state: AppState,
    stale_after_seconds: u64,
    stale_scan_interval_seconds: u64,
) {
    if stale_after_seconds == 0 {
        info!("stale task GC disabled");
        return;
    }

    let stale_after = ChronoDuration::seconds(stale_after_seconds.min(i64::MAX as u64) as i64);
    let scan_interval = StdDuration::from_secs(stale_scan_interval_seconds.max(1));

    tokio::spawn(async move {
        loop {
            match mark_stale_tasks(&state, stale_after, stale_after_seconds) {
                Ok(count) if count > 0 => {
                    info!(count, "marked stale AI Monitor tasks");
                }
                Ok(_) => {}
                Err(error) => {
                    warn!(%error, "failed to run stale task GC");
                }
            }
            tokio::time::sleep(scan_interval).await;
        }
    });
}

fn mark_stale_tasks(
    state: &AppState,
    stale_after: ChronoDuration,
    stale_after_seconds: u64,
) -> Result<usize, AppError> {
    let cutoff = Utc::now() - stale_after;
    let candidates = state.store.list_stale_candidate_tasks(cutoff)?;
    let mut stale_count = 0;

    for candidate in candidates {
        let Some(current) = state.store.get_task(&candidate.task_id)? else {
            continue;
        };
        if current.status != candidate.status
            || current.updated_at != candidate.updated_at
            || !current.status.is_stale_candidate()
            || current.updated_at >= cutoff
        {
            continue;
        }

        let event = stale_event_from_task(&current, stale_after_seconds);
        let task = state.store.record_event(&event)?;
        publish(
            state,
            LiveMessage::TaskUpdated {
                event: Box::new(event),
                task: Box::new(task),
            },
        );
        stale_count += 1;
    }

    Ok(stale_count)
}

fn stale_event_from_task(task: &AgentTask, stale_after_seconds: u64) -> AgentTaskEvent {
    let mut event = AgentTaskEvent::new(
        task.task_id.clone(),
        task.source.as_str().to_string(),
        task.title.clone(),
        TaskStatus::Stale,
    );
    event.app = task.app.clone();
    event.workspace = task.workspace.clone();
    event.session_name = task.session_name.clone();
    event.window_title = task.window_title.clone();
    event.step = Some("Marked stale".to_string());
    event.message = Some(format!(
        "No updates for at least {stale_after_seconds} seconds; marking task stale."
    ));
    event.confidence = task.confidence;
    event.priority = TaskPriority::P3;
    event.notify_desktop = false;
    event.notify_external = false;
    event.actions = task.actions.clone();
    event.metadata = task.metadata.clone();
    event
        .metadata
        .insert("stale_reason".to_string(), json!("no_updates"));
    event.metadata.insert(
        "stale_after_seconds".to_string(),
        json!(stale_after_seconds),
    );
    event.metadata.insert(
        "stale_original_status".to_string(),
        json!(task.status.as_wire_value()),
    );
    event
}

async fn list_tasks(
    State(state): State<AppState>,
    Query(query): Query<ListTasksQuery>,
) -> Result<Json<Vec<AgentTask>>, AppError> {
    let filter = TaskListFilter {
        active_only: query.active.unwrap_or(false),
        status: parse_query_enum(query.status.as_deref(), "status")?,
        source: query.source.map(TaskSource::new),
        workspace_contains: query.workspace_contains,
    };

    Ok(Json(state.store.list_tasks(filter)?))
}

async fn get_task(
    State(state): State<AppState>,
    Path(task_id): Path<String>,
) -> Result<Json<TaskDetail>, AppError> {
    let detail = state
        .store
        .get_task_detail(&task_id)?
        .ok_or(AppError::NotFound)?;
    Ok(Json(detail))
}

async fn delete_task(
    State(state): State<AppState>,
    Path(task_id): Path<String>,
) -> Result<StatusCode, AppError> {
    if state.store.delete_task(&task_id)? {
        publish(&state, LiveMessage::TaskDeleted { task_id });
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn live(State(state): State<AppState>, ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(move |socket| live_socket(socket, state.live_tx.subscribe()))
}

async fn require_api_auth(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if request.method() == Method::OPTIONS
        || security::request_is_authorized(&request, state.api_security.token.as_deref())
    {
        return next.run(request).await;
    }

    (
        StatusCode::UNAUTHORIZED,
        Json(json!({
            "error": "missing or invalid AI Monitor API token"
        })),
    )
        .into_response()
}

async fn live_socket(mut socket: WebSocket, mut rx: broadcast::Receiver<LiveMessage>) {
    while let Ok(message) = rx.recv().await {
        let Ok(text) = serde_json::to_string(&message) else {
            continue;
        };
        if socket.send(Message::Text(text.into())).await.is_err() {
            break;
        }
    }
}

async fn test_notification(
    State(state): State<AppState>,
    Json(request): Json<TestNotificationRequest>,
) -> Result<Json<TestNotificationResponse>, AppError> {
    let mut event = AgentTaskEvent::new(
        format!("task_test_{}", Uuid::new_v4()),
        request.source.unwrap_or_else(|| "ai-monitor".to_string()),
        request
            .title
            .unwrap_or_else(|| "AI Monitor test notification".to_string()),
        request.status.unwrap_or(TaskStatus::Completed),
    );
    event.event_id = format!("evt_test_{}", Uuid::new_v4());
    event.priority = request.priority.unwrap_or(TaskPriority::P1);
    event.workspace = request.workspace;
    event.message = request.message;
    event.updated_at = Utc::now();

    let task = AgentTask::from_event(&event);
    let provider_ids = request
        .provider_ids
        .or_else(|| request.provider_id.map(|provider_id| vec![provider_id]))
        .unwrap_or_else(|| state.notifications.provider_ids());

    let mut deliveries = Vec::new();
    for provider_id in provider_ids {
        deliveries.push(send_and_log(&state, &provider_id, &event, &task).await);
    }

    Ok(Json(TestNotificationResponse { deliveries }))
}

async fn list_provider_health(
    State(state): State<AppState>,
) -> Result<Json<Vec<ProviderHealth>>, AppError> {
    let mut providers = Vec::new();
    for provider_id in state.notifications.provider_ids() {
        match state.notifications.validate_provider(&provider_id).await {
            Ok(provider_type) => providers.push(ProviderHealth {
                provider_id,
                provider_type,
                status: "ok".to_string(),
                message: "provider configuration is valid".to_string(),
            }),
            Err(error) => {
                let provider_type = state
                    .notifications
                    .provider_kind(&provider_id)
                    .ok_or(AppError::NotFound)?;
                providers.push(ProviderHealth {
                    provider_id,
                    provider_type,
                    status: "failed".to_string(),
                    message: error.to_string(),
                });
            }
        }
    }
    Ok(Json(providers))
}

async fn list_deliveries(
    State(state): State<AppState>,
    Query(query): Query<ListDeliveriesQuery>,
) -> Result<Json<Vec<NotificationDelivery>>, AppError> {
    let filter = DeliveryListFilter {
        event_id: query.event_id,
        task_id: query.task_id,
        provider_id: query.provider_id,
        status: parse_query_enum(query.status.as_deref(), "status")?,
    };
    Ok(Json(state.store.list_notification_deliveries(filter)?))
}

async fn retry_delivery(
    State(state): State<AppState>,
    Path(delivery_id): Path<String>,
) -> Result<Json<RetryDeliveryResponse>, AppError> {
    let previous_delivery = state
        .store
        .get_notification_delivery(&delivery_id)?
        .ok_or(AppError::NotFound)?;
    let event = state
        .store
        .get_event(&previous_delivery.event_id)?
        .ok_or(AppError::NotFound)?;
    let task = state
        .store
        .get_task(&previous_delivery.task_id)?
        .ok_or(AppError::NotFound)?;
    let delivery = send_and_log(&state, &previous_delivery.provider_id, &event, &task).await;
    Ok(Json(RetryDeliveryResponse {
        previous_delivery,
        delivery,
    }))
}

async fn dispatch_notifications(
    state: &AppState,
    event: &AgentTaskEvent,
    task: &AgentTask,
    previous_task: Option<&AgentTask>,
) -> Vec<NotificationDelivery> {
    if previous_task
        .map(|previous| previous.status == event.status)
        .unwrap_or(false)
    {
        return Vec::new();
    }

    let provider_ids = state.notifications.notification_plan(event, task);
    let mut deliveries = Vec::new();

    for provider_id in provider_ids {
        deliveries.push(send_and_log(state, &provider_id, event, task).await);
    }

    deliveries
}

async fn send_and_log(
    state: &AppState,
    provider_id: &str,
    event: &AgentTaskEvent,
    task: &AgentTask,
) -> NotificationDelivery {
    let (send_event, send_task) = payload_for_provider(state, provider_id, event, task);
    let delivery =
        send_payload_and_log(state, provider_id, event, &send_event, &send_task, None).await;

    if should_alert_delivery_failure(state, provider_id, &delivery) {
        send_delivery_failure_alert(state, provider_id, &delivery, event, task).await;
    }

    delivery
}

fn payload_for_provider(
    state: &AppState,
    provider_id: &str,
    event: &AgentTaskEvent,
    task: &AgentTask,
) -> (AgentTaskEvent, AgentTask) {
    if is_external_provider(state, provider_id) {
        state.privacy.redact_for_external(event, task)
    } else {
        (event.clone(), task.clone())
    }
}

async fn send_payload_and_log(
    state: &AppState,
    provider_id: &str,
    log_event: &AgentTaskEvent,
    send_event: &AgentTaskEvent,
    send_task: &AgentTask,
    success_message: Option<String>,
) -> NotificationDelivery {
    let pending = match state.store.create_pending_delivery(log_event, provider_id) {
        Ok(delivery) => delivery,
        Err(error) => {
            error!(%provider_id, %error, "failed to create notification delivery log");
            return NotificationDelivery {
                delivery_id: format!("delivery_{}", Uuid::new_v4()),
                event_id: log_event.event_id.clone(),
                task_id: log_event.task_id.clone(),
                provider_id: provider_id.to_string(),
                status: DeliveryStatus::Failed,
                message: Some(format!("failed to create delivery log: {error}")),
                created_at: Utc::now(),
                completed_at: Some(Utc::now()),
            };
        }
    };

    let delivery = match state
        .notifications
        .send(provider_id, send_event, send_task)
        .await
    {
        Ok(result) => state
            .store
            .update_delivery(
                &pending.delivery_id,
                DeliveryStatus::Sent,
                Some(success_message.unwrap_or(result.message)),
            )
            .unwrap_or_else(|error| failed_delivery(&pending, error.to_string())),
        Err(error) => {
            let message =
                ai_monitor_notification_engine::redact_sensitive_error_message(error.to_string());
            state
                .store
                .update_delivery(&pending.delivery_id, DeliveryStatus::Failed, Some(message))
                .unwrap_or_else(|storage_error| {
                    failed_delivery(&pending, storage_error.to_string())
                })
        }
    };

    publish(
        state,
        LiveMessage::NotificationDelivered {
            delivery: delivery.clone(),
        },
    );
    delivery
}

fn is_external_provider(state: &AppState, provider_id: &str) -> bool {
    state
        .notifications
        .provider_kind(provider_id)
        .map(|kind| kind != ai_monitor_notification_engine::ProviderKind::Desktop)
        .unwrap_or(true)
}

fn should_alert_delivery_failure(
    state: &AppState,
    provider_id: &str,
    delivery: &NotificationDelivery,
) -> bool {
    should_alert_delivery_failure_for_kind(
        state.notifications.provider_kind(provider_id),
        state.notifications.provider_kind("desktop").is_some(),
        delivery.status,
    )
}

fn should_alert_delivery_failure_for_kind(
    failed_provider_kind: Option<ai_monitor_notification_engine::ProviderKind>,
    desktop_available: bool,
    delivery_status: DeliveryStatus,
) -> bool {
    delivery_status == DeliveryStatus::Failed
        && desktop_available
        && failed_provider_kind != Some(ai_monitor_notification_engine::ProviderKind::Desktop)
}

async fn send_delivery_failure_alert(
    state: &AppState,
    failed_provider_id: &str,
    delivery: &NotificationDelivery,
    event: &AgentTaskEvent,
    task: &AgentTask,
) {
    let (alert_event, alert_task) =
        delivery_failure_alert_payload(failed_provider_id, delivery, event, task);
    let alert_delivery = send_payload_and_log(
        state,
        "desktop",
        event,
        &alert_event,
        &alert_task,
        Some(format!(
            "provider failure alert sent for {failed_provider_id}"
        )),
    )
    .await;

    if alert_delivery.status == DeliveryStatus::Failed {
        warn!(
            provider_id = failed_provider_id,
            alert_delivery_id = %alert_delivery.delivery_id,
            message = alert_delivery.message.as_deref().unwrap_or("unknown error"),
            "failed to send provider failure alert"
        );
    }
}

fn delivery_failure_alert_payload(
    failed_provider_id: &str,
    delivery: &NotificationDelivery,
    event: &AgentTaskEvent,
    task: &AgentTask,
) -> (AgentTaskEvent, AgentTask) {
    let error_message = delivery
        .message
        .clone()
        .unwrap_or_else(|| "unknown provider error".to_string());
    let title = format!("Notification provider failed: {failed_provider_id}");
    let message = format!(
        "Delivery {} failed: {}",
        delivery.delivery_id, error_message
    );

    let mut alert_event = event.clone();
    alert_event.event_id = format!("evt_{}", Uuid::new_v4());
    alert_event.title = title.clone();
    alert_event.status = TaskStatus::Failed;
    alert_event.step = Some("Notification delivery failed".to_string());
    alert_event.message = Some(message.clone());
    alert_event.priority = TaskPriority::P0;
    alert_event.notify_desktop = true;
    alert_event.notify_external = false;
    alert_event.updated_at = Utc::now();
    alert_event
        .metadata
        .insert("failed_provider_id".to_string(), json!(failed_provider_id));
    alert_event.metadata.insert(
        "failed_delivery_id".to_string(),
        json!(delivery.delivery_id),
    );

    let mut alert_task = task.clone();
    alert_task.title = title;
    alert_task.status = TaskStatus::Failed;
    alert_task.step = Some("Notification delivery failed".to_string());
    alert_task.message = Some(message);
    alert_task.priority = TaskPriority::P0;
    alert_task.updated_at = alert_event.updated_at;
    alert_task
        .metadata
        .insert("failed_provider_id".to_string(), json!(failed_provider_id));
    alert_task.metadata.insert(
        "failed_delivery_id".to_string(),
        json!(delivery.delivery_id),
    );

    (alert_event, alert_task)
}

fn failed_delivery(pending: &NotificationDelivery, message: String) -> NotificationDelivery {
    let mut delivery = pending.clone();
    delivery.status = DeliveryStatus::Failed;
    delivery.message = Some(message);
    delivery.completed_at = Some(Utc::now());
    delivery
}

fn publish(state: &AppState, message: LiveMessage) {
    if let Err(error) = state.live_tx.send(message) {
        warn!(%error, "live broadcast had no active receivers");
    }
}

fn validate_event(event: &AgentTaskEvent) -> Result<(), AppError> {
    if event.event_id.trim().is_empty() {
        return Err(AppError::BadRequest("event_id is required".to_string()));
    }
    if event.task_id.trim().is_empty() {
        return Err(AppError::BadRequest("task_id is required".to_string()));
    }
    if event.title.trim().is_empty() {
        return Err(AppError::BadRequest("title is required".to_string()));
    }
    if !(0.0..=1.0).contains(&event.confidence) {
        return Err(AppError::BadRequest(
            "confidence must be between 0.0 and 1.0".to_string(),
        ));
    }
    Ok(())
}

fn load_config_text(path: &StdPath) -> anyhow::Result<String> {
    if path.exists() {
        Ok(std::fs::read_to_string(path)?)
    } else {
        Ok(DEFAULT_CONFIG.to_string())
    }
}

fn ensure_parent_dir(path: &StdPath) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    Ok(())
}

fn parse_query_enum<T: serde::de::DeserializeOwned>(
    value: Option<&str>,
    field_name: &str,
) -> Result<Option<T>, AppError> {
    let Some(value) = value else {
        return Ok(None);
    };
    serde_json::from_value(serde_json::Value::String(value.to_string()))
        .map(Some)
        .map_err(|_| AppError::BadRequest(format!("invalid {field_name}: {value}")))
}

#[derive(Debug, Deserialize)]
struct ListTasksQuery {
    active: Option<bool>,
    status: Option<String>,
    source: Option<String>,
    workspace_contains: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListDeliveriesQuery {
    event_id: Option<String>,
    task_id: Option<String>,
    provider_id: Option<String>,
    status: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct DaemonConfig {
    #[serde(default)]
    api: ApiConfig,
    #[serde(default)]
    privacy: PrivacyConfig,
    #[serde(default)]
    ignore_rules: Vec<IgnoreRule>,
}

impl DaemonConfig {
    fn from_toml_str(input: &str) -> anyhow::Result<Self> {
        Ok(toml::from_str(input)?)
    }
}

#[derive(Debug, Serialize)]
struct EventIngestResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    task: Option<AgentTask>,
    deliveries: Vec<NotificationDelivery>,
    #[serde(default)]
    ignored: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    ignore_rule_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TestNotificationRequest {
    provider_id: Option<String>,
    provider_ids: Option<Vec<String>>,
    title: Option<String>,
    message: Option<String>,
    source: Option<String>,
    workspace: Option<String>,
    status: Option<TaskStatus>,
    priority: Option<TaskPriority>,
}

#[derive(Debug, Serialize)]
struct TestNotificationResponse {
    deliveries: Vec<NotificationDelivery>,
}

#[derive(Debug, Serialize)]
struct ProviderHealth {
    provider_id: String,
    provider_type: ai_monitor_notification_engine::ProviderKind,
    status: String,
    message: String,
}

#[derive(Debug, Serialize)]
struct RetryDeliveryResponse {
    previous_delivery: NotificationDelivery,
    delivery: NotificationDelivery,
}

#[derive(Debug, Error)]
enum AppError {
    #[error("{0}")]
    BadRequest(String),
    #[error("not found")]
    NotFound,
    #[error("storage error: {0}")]
    Storage(#[from] ai_monitor_storage::StorageError),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = match self {
            AppError::BadRequest(_) => StatusCode::BAD_REQUEST,
            AppError::NotFound => StatusCode::NOT_FOUND,
            AppError::Storage(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };

        let body = Json(json!({
            "error": self.to_string()
        }));
        (status, body).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ai_monitor_notification_engine::ProviderKind;

    #[test]
    fn provider_failure_alert_payload_keeps_original_task_deeplink_context() {
        let mut event = AgentTaskEvent::new(
            "task_provider_failure",
            "codex-cli",
            "Original task",
            TaskStatus::Running,
        );
        event.workspace = Some("/workspace/project".to_string());
        let task = AgentTask::from_event(&event);
        let delivery = NotificationDelivery {
            delivery_id: "delivery_failed".to_string(),
            event_id: event.event_id.clone(),
            task_id: event.task_id.clone(),
            provider_id: "slack".to_string(),
            status: DeliveryStatus::Failed,
            message: Some("slack returned 500".to_string()),
            created_at: Utc::now(),
            completed_at: Some(Utc::now()),
        };

        let (alert_event, alert_task) =
            delivery_failure_alert_payload("slack", &delivery, &event, &task);

        assert_eq!(alert_event.task_id, event.task_id);
        assert_ne!(alert_event.event_id, event.event_id);
        assert_eq!(alert_event.status, TaskStatus::Failed);
        assert_eq!(alert_event.priority, TaskPriority::P0);
        assert!(alert_event.notify_desktop);
        assert!(!alert_event.notify_external);
        assert_eq!(alert_event.metadata["failed_provider_id"], json!("slack"));
        assert_eq!(
            alert_event.metadata["failed_delivery_id"],
            json!("delivery_failed")
        );
        assert_eq!(alert_task.task_id, task.task_id);
        assert_eq!(alert_task.title, "Notification provider failed: slack");
        assert_eq!(alert_task.status, TaskStatus::Failed);
        assert_eq!(alert_task.workspace, task.workspace);
    }

    #[test]
    fn provider_failure_alerts_skip_desktop_and_non_failures() {
        assert!(should_alert_delivery_failure_for_kind(
            Some(ProviderKind::Slack),
            true,
            DeliveryStatus::Failed
        ));
        assert!(should_alert_delivery_failure_for_kind(
            None,
            true,
            DeliveryStatus::Failed
        ));
        assert!(!should_alert_delivery_failure_for_kind(
            Some(ProviderKind::Desktop),
            true,
            DeliveryStatus::Failed
        ));
        assert!(!should_alert_delivery_failure_for_kind(
            Some(ProviderKind::Slack),
            false,
            DeliveryStatus::Failed
        ));
        assert!(!should_alert_delivery_failure_for_kind(
            Some(ProviderKind::Slack),
            true,
            DeliveryStatus::Sent
        ));
    }
}
