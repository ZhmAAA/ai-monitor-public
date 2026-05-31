use axum::{
    body::Body,
    http::{HeaderValue, Request},
};
use serde::Deserialize;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use uuid::Uuid;

const DEFAULT_ALLOWED_ORIGINS: &[&str] = &[
    "http://127.0.0.1:",
    "http://localhost:",
    "http://[::1]:",
    "chrome-extension://",
    "moz-extension://",
    "safari-web-extension://",
];

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ApiConfig {
    #[serde(default)]
    pub auth_enabled: Option<bool>,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub token_file: Option<PathBuf>,
    #[serde(default)]
    pub cors_allowed_origins: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ApiSecurity {
    pub token: Option<String>,
    pub cors_allowed_origins: Vec<String>,
}

impl ApiSecurity {
    pub fn load(
        config: &ApiConfig,
        cli_token: Option<String>,
        cli_token_file: Option<PathBuf>,
        disable_auth: bool,
    ) -> anyhow::Result<Self> {
        let auth_enabled = config.auth_enabled.unwrap_or(true) && !disable_auth;
        let token = if auth_enabled {
            Some(load_or_create_token(
                cli_token.or_else(|| clean_token(config.token.clone())),
                cli_token_file.or_else(|| config.token_file.clone()),
            )?)
        } else {
            None
        };

        let cors_allowed_origins = if config.cors_allowed_origins.is_empty() {
            DEFAULT_ALLOWED_ORIGINS
                .iter()
                .map(|value| value.to_string())
                .collect()
        } else {
            config.cors_allowed_origins.clone()
        };

        Ok(Self {
            token,
            cors_allowed_origins,
        })
    }
}

pub fn request_is_authorized(request: &Request<Body>, expected_token: Option<&str>) -> bool {
    let Some(expected_token) = expected_token else {
        return true;
    };
    request_token(request)
        .as_deref()
        .map(|token| constant_time_eq(token.as_bytes(), expected_token.as_bytes()))
        .unwrap_or(false)
}

pub fn is_allowed_origin(origin: &HeaderValue, allowed_origins: &[String]) -> bool {
    let Ok(origin) = origin.to_str() else {
        return false;
    };

    allowed_origins.iter().any(|allowed| {
        let allowed = allowed.trim();
        if allowed == "*" {
            return true;
        }
        if let Some(prefix) = allowed.strip_suffix('*') {
            return origin.starts_with(prefix);
        }
        if allowed.ends_with(':') || allowed.ends_with("://") {
            return origin.starts_with(allowed);
        }
        origin == allowed
    })
}

pub fn default_token_file() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home).join(".ai-monitor").join("api-token");
    }
    PathBuf::from(".ai-monitor-api-token")
}

fn load_or_create_token(
    explicit_token: Option<String>,
    token_file: Option<PathBuf>,
) -> anyhow::Result<String> {
    if let Some(token) = clean_token(explicit_token) {
        return Ok(token);
    }

    let token_file = token_file.unwrap_or_else(default_token_file);
    if let Some(token) = read_token_file(&token_file)? {
        return Ok(token);
    }

    let token = Uuid::new_v4().to_string();
    write_token_file(&token_file, &token)?;
    Ok(token)
}

fn read_token_file(path: &Path) -> anyhow::Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(contents) => {
            let token = clean_token(Some(contents));
            if token.is_some() {
                secure_token_file_permissions(path)?;
            }
            Ok(token)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn write_token_file(path: &Path, token: &str) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        writeln!(file, "{token}")?;
        secure_token_file_permissions(path)?;
    }

    #[cfg(not(unix))]
    {
        fs::write(path, format!("{token}\n"))?;
    }

    Ok(())
}

#[cfg(unix)]
fn secure_token_file_permissions(path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let metadata = fs::metadata(path)?;
    let mut permissions = metadata.permissions();
    if permissions.mode() & 0o777 != 0o600 {
        permissions.set_mode(0o600);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn secure_token_file_permissions(_path: &Path) -> anyhow::Result<()> {
    Ok(())
}

fn request_token(request: &Request<Body>) -> Option<String> {
    if let Some(token) = request
        .headers()
        .get("x-ai-monitor-token")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| clean_token(Some(value.to_string())))
    {
        return Some(token);
    }

    if let Some(token) = request
        .headers()
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(bearer_token)
    {
        return Some(token);
    }

    request.uri().query().and_then(query_token)
}

fn bearer_token(value: &str) -> Option<String> {
    let value = value.trim();
    let (kind, token) = value.split_once(' ')?;
    if kind.eq_ignore_ascii_case("bearer") {
        clean_token(Some(token.to_string()))
    } else {
        None
    }
}

fn query_token(query: &str) -> Option<String> {
    query.split('&').find_map(|part| {
        let (key, value) = part.split_once('=')?;
        if key == "token" {
            clean_token(Some(value.to_string()))
        } else {
            None
        }
    })
}

fn clean_token(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .filter(|value| !value.starts_with("${"))
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    let mut diff = 0u8;
    for (left, right) in left.iter().zip(right.iter()) {
        diff |= left ^ right;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::Request;

    #[test]
    fn authorizes_bearer_or_monitor_token_header() {
        let request = Request::builder()
            .header("authorization", "Bearer secret")
            .body(Body::empty())
            .unwrap();
        assert!(request_is_authorized(&request, Some("secret")));

        let request = Request::builder()
            .header("x-ai-monitor-token", "secret")
            .body(Body::empty())
            .unwrap();
        assert!(request_is_authorized(&request, Some("secret")));
    }

    #[test]
    fn rejects_wrong_token() {
        let request = Request::builder()
            .header("x-ai-monitor-token", "wrong")
            .body(Body::empty())
            .unwrap();
        assert!(!request_is_authorized(&request, Some("secret")));
    }

    #[test]
    fn allows_local_and_extension_origins_by_default() {
        let allowed = DEFAULT_ALLOWED_ORIGINS
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>();
        assert!(is_allowed_origin(
            &HeaderValue::from_static("http://127.0.0.1:3000"),
            &allowed
        ));
        assert!(is_allowed_origin(
            &HeaderValue::from_static("chrome-extension://abc"),
            &allowed
        ));
        assert!(!is_allowed_origin(
            &HeaderValue::from_static("https://example.com"),
            &allowed
        ));
    }

    #[cfg(unix)]
    #[test]
    fn existing_token_file_permissions_are_tightened() {
        use std::os::unix::fs::PermissionsExt;

        let dir = std::env::temp_dir().join(format!("ai-monitor-security-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let token_path = dir.join("api-token");
        fs::write(&token_path, "secret\n").unwrap();
        fs::set_permissions(&token_path, fs::Permissions::from_mode(0o644)).unwrap();

        let token = load_or_create_token(None, Some(token_path.clone())).unwrap();
        assert_eq!(token, "secret");
        assert_eq!(
            fs::metadata(&token_path).unwrap().permissions().mode() & 0o777,
            0o600
        );

        fs::remove_file(&token_path).ok();
        fs::remove_dir(&dir).ok();
    }
}
