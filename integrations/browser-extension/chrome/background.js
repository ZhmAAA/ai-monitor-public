const DEFAULT_DAEMON_URL = "http://127.0.0.1:4318";
const DEFAULT_WORKSPACE = "browser";
const ADAPTER_VERSION = chrome.runtime.getManifest().version;
const BROWSER_APP = browserAppIdentity();
const EXTENSION_ID = chrome.runtime.id;
const TAB_PRESENCE_ALARM = "ai-monitor:tab-presence";
const LEGACY_GROK_TAB_PRESENCE_ALARM = "ai-monitor:grok-tab-presence";
const TRACKED_TABS_KEY = "trackedBrowserTabs";
const AI_TAB_SCAN_PATTERNS = [
  "https://chatgpt.com/*",
  "https://chat.openai.com/*",
  "https://claude.ai/*",
  "https://gemini.google.com/*",
  "https://www.perplexity.ai/*",
  "https://perplexity.ai/*",
  "https://grok.com/*",
  "https://www.grok.com/*",
  "https://x.com/grok*",
  "https://x.com/i/grok*",
  "https://www.x.com/grok*",
  "https://www.x.com/i/grok*",
  "https://twitter.com/grok*",
  "https://twitter.com/i/grok*",
  "https://www.twitter.com/grok*",
  "https://www.twitter.com/i/grok*",
];
const observedTabs = new Map();
const fallbackTabs = new Map();

chrome.runtime.onInstalled.addListener(async () => {
  const existing = await chrome.storage.local.get(["daemonUrl", "apiToken", "workspace"]);
  await chrome.storage.local.set({
    daemonUrl: normalizeDaemonUrl(existing.daemonUrl),
    apiToken: existing.apiToken || "",
    workspace: existing.workspace || DEFAULT_WORKSPACE,
  });
  ensureTabPresenceAlarm();
  scanAiTabs().catch(() => {});
  reconcileTrackedTabs().catch(() => {});
  reconcileDaemonBrowserTasks().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  ensureTabPresenceAlarm();
  scanAiTabs().catch(() => {});
  reconcileTrackedTabs().catch(() => {});
  reconcileDaemonBrowserTasks().catch(() => {});
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== TAB_PRESENCE_ALARM) return;
  scanAiTabs()
    .then(() => reconcileTrackedTabs())
    .then(() => reconcileDaemonBrowserTasks())
    .catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "ai-monitor:event") {
    return false;
  }

  postAgentEvent(message.payload, sender)
    .then((result) => sendResponse({ ok: true, result }))
    .catch((error) => sendResponse({ ok: false, error: error.message }));

  return true;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  handleTabRemoved(tabId).catch(() => {});
});

async function handleTabRemoved(tabId) {
  const tab = observedTabs.get(tabId) || fallbackTabs.get(tabId) || await readTrackedTab(tabId);
  if (!tab) return;
  observedTabs.delete(tabId);
  fallbackTabs.delete(tabId);
  await forgetTrackedTab(tabId);
  await postTabClosedEvent(tabId, tab);
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const nextUrl = changeInfo.url || tab.url || "";
  if (!isSupportedAiTabLocation(nextUrl)) return;
  ensureContentScript(tab)
    .then(() => postTabPresence(tab))
    .catch(() => {});
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    if (isSupportedAiTabLocation(tab.url || "")) {
      await ensureContentScript(tab);
      await postTabPresence(tab);
    }
  } catch {
    // The tab may have closed before Chrome returned it.
  }
});

async function postAgentEvent(payload, sender) {
  const { daemonUrl, workspace } = await readSettings();
  const tab = sender.tab || {};
  const source = payload.source || inferSource(tab.url || payload.url || "");
  const sessionName = normalizeSessionName(payload.sessionName || tab.title || payload.title);
  const windowTitle = payload.windowTitle || buildWindowTitle(tab.title || payload.title);
  const now = new Date().toISOString();
  const event = {
    event_id: `evt_browser_${Date.now()}_${randomId()}`,
    task_id: stableTaskId(source, tab.id, payload.url || tab.url),
    source,
    app: BROWSER_APP.app,
    workspace,
    session_name: sessionName,
    window_title: windowTitle,
    title: payload.title || sessionName || "AI browser task",
    status: payload.status,
    step: payload.step,
    message: payload.message,
    confidence: payload.confidence ?? 0.82,
    priority: payload.priority || priorityForStatus(payload.status),
    notify_desktop: payload.notifyDesktop ?? true,
    notify_external: payload.notifyExternal ?? true,
    created_at: now,
    updated_at: now,
    actions: [
      {
        label: "Open Tab",
        type: "open_browser_tab",
        target: payload.url || tab.url || "",
        app_bundle_id: BROWSER_APP.bundleId,
        metadata: {
          tab_id: tab.id,
          window_id: tab.windowId,
          browser_app: BROWSER_APP.label,
          browser_bundle_id: BROWSER_APP.bundleId,
          extension_id: EXTENSION_ID,
        },
      },
    ],
    metadata: {
      browser_tab_id: tab.id,
      browser_window_id: tab.windowId,
      browser_app: BROWSER_APP.label,
      browser_bundle_id: BROWSER_APP.bundleId,
      extension_id: EXTENSION_ID,
      url: payload.url || tab.url,
      favicon_url: tab.favIconUrl,
      detector: payload.detector || "browser-content-script",
      detector_debug: payload.debug,
      prompt: payload.prompt,
      adapter_version: ADAPTER_VERSION,
    },
  };

  const result = await deliverAgentEvent(daemonUrl, event);

  if (tab.id !== undefined && tab.id !== null && isTabPresenceSource(source)) {
    fallbackTabs.delete(tab.id);
    const trackedTab = {
      source,
      url: payload.url || tab.url || "",
      title: event.title,
      sessionName,
      windowTitle,
      workspace,
      browserApp: BROWSER_APP.label,
      browserBundleId: BROWSER_APP.bundleId,
      extensionId: EXTENSION_ID,
    };
    observedTabs.set(tab.id, trackedTab);
    await rememberTrackedTab(tab.id, trackedTab);
  }

  await chrome.storage.local.set({
    lastDelivery: {
      ok: true,
      daemonUrl,
      status: event.status,
      sessionName,
      debug: payload.debug,
      adapterVersion: ADAPTER_VERSION,
      updatedAt: now,
    },
  });

  return result;
}

async function scanAiTabs() {
  const tabs = await chrome.tabs.query({ url: AI_TAB_SCAN_PATTERNS });
  await Promise.all(
    tabs
      .filter((tab) => isSupportedAiTabLocation(tab.url || ""))
      .map(async (tab) => {
        await ensureContentScript(tab);
        return postTabPresence(tab);
      })
  );
}

async function reconcileTrackedTabs() {
  const trackedTabs = await readTrackedTabs();
  await Promise.all(
    Object.entries(trackedTabs).map(async ([tabId, trackedTab]) => {
      try {
        const tab = await chrome.tabs.get(Number(tabId));
        if (tab?.url) {
          return;
        }
      } catch {
        // Missing tab means Chrome no longer has this session.
      }

      observedTabs.delete(Number(tabId));
      fallbackTabs.delete(Number(tabId));
      await forgetTrackedTab(tabId);
      await postTabClosedEvent(Number(tabId), trackedTab);
    })
  );
}

async function reconcileDaemonBrowserTasks() {
  const { daemonUrl, apiToken } = await readSettings();
  const response = await fetch(`${daemonUrl.replace(/\/$/, "")}/tasks`, {
    headers: authHeaders(apiToken),
  });
  if (!response.ok) return;

  const tasks = await response.json();
  await Promise.all(
    tasks
      .filter((task) => task && isTabPresenceSource(task.source) && task.status !== "cancelled")
      .map(async (task) => {
        const tabId = task.metadata?.browser_tab_id;
        if (tabId === undefined || tabId === null) return;

        try {
          const tab = await chrome.tabs.get(Number(tabId));
          if (tab?.url) return;
        } catch {
          // Missing tab means the daemon still has a stale browser row.
        }

        await postTabClosedEvent(Number(tabId), {
          taskId: task.task_id,
          source: task.source,
          url: task.metadata?.url || task.actions?.[0]?.target || "",
          title: task.title,
          sessionName: task.session_name,
          windowTitle: task.window_title,
          workspace: task.workspace,
        });
      })
  );
}

async function postTabPresence(tab) {
  if (tab.id === undefined || tab.id === null) return null;
  const source = inferSource(tab.url || "");
  const taskId = stableTaskId(source, tab.id, tab.url);
  const observedTab = observedTabs.get(tab.id);
  if (observedTab) {
    const observedUrl = observedTab.url || "";
    if (observedTab.source === source && isSupportedAiTabLocation(observedUrl)) {
      return null;
    }
    observedTabs.delete(tab.id);
  }

  const { daemonUrl, apiToken, workspace } = await readSettings();
  const currentTask = await readCurrentTask(daemonUrl, apiToken, taskId);
  const currentStatus = reusableTaskStatus(currentTask);
  const now = new Date().toISOString();
  const rawTitle = tab.title || "";
  const sessionName = currentTask?.session_name || tabSessionName(rawTitle, source);
  const windowTitle = currentTask?.window_title || buildWindowTitle(rawTitle || sessionName);
  const event = {
    event_id: `evt_browser_${Date.now()}_${randomId()}`,
    task_id: taskId,
    source,
    app: BROWSER_APP.app,
    workspace,
    session_name: sessionName,
    window_title: windowTitle,
    title: currentTask?.title || sessionName,
    status: currentStatus,
    step: currentTask?.step || "Tab open",
    message: currentTask?.message || "AI web tab is open",
    confidence: currentTask?.confidence ?? 0.5,
    priority: currentTask?.priority || priorityForStatus(currentStatus),
    notify_desktop: false,
    notify_external: false,
    created_at: now,
    updated_at: now,
    actions: [
      {
        label: "Open Tab",
        type: "open_browser_tab",
        target: tab.url || "",
        app_bundle_id: BROWSER_APP.bundleId,
        metadata: {
          tab_id: tab.id,
          window_id: tab.windowId,
          browser_app: BROWSER_APP.label,
          browser_bundle_id: BROWSER_APP.bundleId,
          extension_id: EXTENSION_ID,
        },
      },
    ],
    metadata: {
      browser_tab_id: tab.id,
      browser_window_id: tab.windowId,
      browser_app: BROWSER_APP.label,
      browser_bundle_id: BROWSER_APP.bundleId,
      extension_id: EXTENSION_ID,
      url: tab.url,
      favicon_url: tab.favIconUrl,
      detector: "browser-tab-presence",
      detector_debug: currentTask
        ? `background tab scan · preserving ${currentStatus}`
        : "background tab scan",
      adapter_version: ADAPTER_VERSION,
    },
  };

  const result = await deliverAgentEvent(daemonUrl, event);
  const trackedTab = {
    source,
    url: tab.url || "",
    faviconUrl: tab.favIconUrl,
    title: event.title,
    sessionName,
    windowTitle: event.window_title,
    workspace,
    browserApp: BROWSER_APP.label,
    browserBundleId: BROWSER_APP.bundleId,
    extensionId: EXTENSION_ID,
  };
  fallbackTabs.set(tab.id, trackedTab);
  await rememberTrackedTab(tab.id, trackedTab);
  return result;
}

async function ensureContentScript(tab) {
  if (tab.id === undefined || tab.id === null) return;
  try {
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["content.js"],
    });
  } catch {
    // Some Chrome pages or loading tabs are not injectable; presence still works.
  }
}

async function readCurrentTask(daemonUrl, apiToken, taskId) {
  try {
    const response = await fetch(`${daemonUrl.replace(/\/$/, "")}/tasks/${encodeURIComponent(taskId)}`, {
      headers: authHeaders(apiToken),
    });
    if (!response.ok) return null;
    const detail = await response.json();
    return detail?.task || null;
  } catch {
    return null;
  }
}

function reusableTaskStatus(task) {
  if (!task || !task.status || task.status === "cancelled") {
    return "unknown";
  }
  return task.status;
}

async function postTabClosedEvent(tabId, tab) {
  const { daemonUrl, workspace } = await readSettings();
  const now = new Date().toISOString();
  const event = {
    event_id: `evt_browser_${Date.now()}_${randomId()}`,
    task_id: tab.taskId || stableTaskId(tab.source, tabId, tab.url),
    source: tab.source,
    app: BROWSER_APP.app,
    workspace: tab.workspace || workspace,
    session_name: tab.sessionName,
    window_title: tab.windowTitle,
    title: tab.title || tab.sessionName || "AI browser task",
    status: "cancelled",
    step: "Tab closed",
    message: "The browser tab was closed",
    confidence: 1,
    priority: "P2",
    notify_desktop: false,
    notify_external: false,
    created_at: now,
    updated_at: now,
    actions: [
      {
        label: "Open Tab",
        type: "open_browser_tab",
        target: tab.url || "",
        app_bundle_id: tab.browserBundleId || BROWSER_APP.bundleId,
        metadata: {
          tab_id: tabId,
          browser_app: tab.browserApp || BROWSER_APP.label,
          browser_bundle_id: tab.browserBundleId || BROWSER_APP.bundleId,
          extension_id: tab.extensionId || EXTENSION_ID,
        },
      },
    ],
    metadata: {
      browser_tab_id: tabId,
      browser_app: tab.browserApp || BROWSER_APP.label,
      browser_bundle_id: tab.browserBundleId || BROWSER_APP.bundleId,
      extension_id: tab.extensionId || EXTENSION_ID,
      url: tab.url,
      favicon_url: tab.faviconUrl,
      detector: "browser-tab-lifecycle",
      adapter_version: ADAPTER_VERSION,
    },
  };

  return deliverAgentEvent(daemonUrl, event);
}

function ensureTabPresenceAlarm() {
  chrome.alarms.clear(LEGACY_GROK_TAB_PRESENCE_ALARM);
  chrome.alarms.create(TAB_PRESENCE_ALARM, {
    periodInMinutes: 0.5,
  });
}

async function deliverAgentEvent(daemonUrl, event) {
  const { apiToken } = await readSettings();
  const response = await fetch(`${daemonUrl.replace(/\/$/, "")}/events`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...authHeaders(apiToken),
    },
    body: JSON.stringify(event),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`AI Monitor daemon returned ${response.status}: ${text}`);
  }

  return response.json();
}

async function readSettings() {
  const settings = await chrome.storage.local.get(["daemonUrl", "apiToken", "workspace"]);
  const daemonUrl = normalizeDaemonUrl(settings.daemonUrl);
  if (settings.daemonUrl && settings.daemonUrl !== daemonUrl) {
    await chrome.storage.local.set({ daemonUrl });
  }
  return {
    daemonUrl,
    apiToken: settings.apiToken || "",
    workspace: settings.workspace || DEFAULT_WORKSPACE,
  };
}

function authHeaders(apiToken) {
  return apiToken ? { "x-ai-monitor-token": apiToken } : {};
}

async function rememberTrackedTab(tabId, tab) {
  const trackedTabs = await readTrackedTabs();
  trackedTabs[String(tabId)] = {
    ...tab,
    updatedAt: new Date().toISOString(),
    adapterVersion: ADAPTER_VERSION,
  };
  await chrome.storage.local.set({ [TRACKED_TABS_KEY]: trackedTabs });
}

async function readTrackedTab(tabId) {
  const trackedTabs = await readTrackedTabs();
  return trackedTabs[String(tabId)] || null;
}

async function forgetTrackedTab(tabId) {
  const trackedTabs = await readTrackedTabs();
  delete trackedTabs[String(tabId)];
  await chrome.storage.local.set({ [TRACKED_TABS_KEY]: trackedTabs });
}

async function readTrackedTabs() {
  const settings = await chrome.storage.local.get([TRACKED_TABS_KEY]);
  return settings[TRACKED_TABS_KEY] || {};
}

function stableTaskId(source, tabId, url) {
  if (tabId !== undefined && tabId !== null) {
    return `browser_${source}_tab_${tabId}`;
  }
  return `browser_${source}_${hashString(url || "unknown")}`;
}

function priorityForStatus(status) {
  if (["needs_permission", "waiting_for_input", "blocked", "failed", "idle_but_not_done"].includes(status)) {
    return "P0";
  }
  if (status === "completed") {
    return "P1";
  }
  return "P2";
}

function inferSource(url) {
  if (isGrokLocation(url)) return "grok-web";

  const host = safeUrl(url)?.hostname || "";
  if (host.includes("chatgpt.com") || host.includes("chat.openai.com")) return "chatgpt-web";
  if (host.includes("claude.ai")) return "claude-web";
  if (host.includes("gemini.google.com")) return "gemini-web";
  if (host.includes("perplexity.ai")) return "perplexity-web";
  if (isGitHubAiLocation(url)) return "github-web";
  return "browser";
}

function isGrokLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed) return false;

  if (parsed.hostname === "grok.com" || parsed.hostname === "www.grok.com") {
    return true;
  }

  if (["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(parsed.hostname)) {
    return parsed.pathname === "/grok" || parsed.pathname.startsWith("/grok/") ||
      parsed.pathname === "/i/grok" || parsed.pathname.startsWith("/i/grok/");
  }

  return false;
}

function isSupportedAiTabLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed) return false;

  const host = parsed.hostname;
  return (
    host.includes("chatgpt.com") ||
    host.includes("chat.openai.com") ||
    host.includes("claude.ai") ||
    host.includes("gemini.google.com") ||
    host.includes("perplexity.ai") ||
    isGitHubAiLocation(url) ||
    parsed.hostname === "grok.com" ||
    parsed.hostname === "www.grok.com" ||
    isXGrokLocation(url)
  );
}

function isGitHubAiLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed) return false;
  const host = parsed.hostname;
  if (host !== "github.com" && !host.endsWith(".github.com")) return false;

  const path = parsed.pathname.toLowerCase();
  return path.includes("/copilot") ||
    path.includes("/github-copilot") ||
    path.includes("/coding-agent") ||
    path.includes("/copilot-coding-agent");
}

function isXGrokLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed) return false;

  return ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(parsed.hostname) &&
    (parsed.pathname === "/grok" || parsed.pathname.startsWith("/grok/") ||
      parsed.pathname === "/i/grok" || parsed.pathname.startsWith("/i/grok/"));
}

function isTabPresenceSource(source) {
  return source === "browser" || source.endsWith("-web");
}

function normalizeSessionName(title) {
  if (!title) return "AI browser task";
  return title
    .replace(/\s*[-|]\s*ChatGPT\s*$/i, "")
    .replace(/\s*[-|]\s*Claude\s*$/i, "")
    .replace(/\s*[-|]\s*Gemini\s*$/i, "")
    .replace(/\s*[-|]\s*Perplexity\s*$/i, "")
    .replace(/\s*[-|]\s*Grok\s*$/i, "")
    .replace(/\s*\/\s*X\s*$/i, "")
    .replace(/\s*[-|]\s*X\s*$/i, "")
    .replace(/\s*[-|]\s*Google Chrome\s*$/i, "")
    .trim() || title;
}

function tabSessionName(title, source) {
  const normalized = normalizeSessionName(title);
  const fallback = appNameForSource(source);
  if (!normalized || ["x", "grok / x"].includes(normalized.toLowerCase())) {
    return fallback;
  }
  return normalized;
}

function appNameForSource(source) {
  if (source === "chatgpt-web") return "ChatGPT";
  if (source === "claude-web") return "Claude";
  if (source === "gemini-web") return "Gemini";
  if (source === "perplexity-web") return "Perplexity";
  if (source === "grok-web") {
    return "Grok";
  }
  return "AI browser task";
}

function browserAppIdentity() {
  const userAgent = navigator.userAgent || "";
  if (/\bEdg\//.test(userAgent)) {
    return { app: "edge", label: "Microsoft Edge", bundleId: "com.microsoft.edgemac" };
  }
  if (/\bOPR\//.test(userAgent)) {
    return { app: "opera", label: "Opera", bundleId: "com.operasoftware.Opera" };
  }
  if (/\bFirefox\//.test(userAgent)) {
    return { app: "firefox", label: "Firefox", bundleId: "org.mozilla.firefox" };
  }
  return { app: "chrome", label: "Google Chrome", bundleId: "com.google.Chrome" };
}

function buildWindowTitle(title) {
  return title ? `${title} - ${BROWSER_APP.label}` : BROWSER_APP.label;
}

function randomId() {
  return Math.random().toString(36).slice(2, 10);
}

function hashString(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash << 5) - hash + value.charCodeAt(index);
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}

function safeUrl(value) {
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

function normalizeDaemonUrl(value) {
  const raw = String(value || DEFAULT_DAEMON_URL).trim() || DEFAULT_DAEMON_URL;
  try {
    const url = new URL(raw);
    if (url.protocol !== "http:" || !isLoopbackHost(url.hostname)) {
      throw new Error("daemon URL must be local");
    }
    return url.href.replace(/\/$/, "");
  } catch {
    return DEFAULT_DAEMON_URL;
  }
}

function isLoopbackHost(hostname) {
  const host = String(hostname || "").toLowerCase();
  if (host === "localhost" || host === "::1" || host === "[::1]") {
    return true;
  }
  const match = /^127(?:\.(\d{1,3})){3}$/.exec(host);
  if (!match) {
    return false;
  }
  return host.split(".").every((part) => {
    const value = Number(part);
    return Number.isInteger(value) && value >= 0 && value <= 255;
  });
}
