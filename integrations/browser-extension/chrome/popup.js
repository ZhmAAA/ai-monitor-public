const daemonUrl = document.querySelector("#daemonUrl");
const apiToken = document.querySelector("#apiToken");
const workspace = document.querySelector("#workspace");
const statusText = document.querySelector("#status");
const lastDelivery = document.querySelector("#lastDelivery");
const helpText = document.querySelector("#helpText");
const version = document.querySelector("#version");
const openSettingsButton = document.querySelector("#openSettings");
const DEFAULT_DAEMON_URL = "http://127.0.0.1:4318";
const DEFAULT_WORKSPACE = "browser";

document.querySelector("#save").addEventListener("click", save);
document.querySelector("#test").addEventListener("click", sendTestEvent);
document.querySelector("#clearToken").addEventListener("click", clearToken);
openSettingsButton.addEventListener("click", openAIMonitorSettings);

load();

async function load() {
  const settings = await chrome.storage.local.get(["daemonUrl", "apiToken", "workspace", "lastDelivery"]);
  daemonUrl.value = settings.daemonUrl || DEFAULT_DAEMON_URL;
  apiToken.value = settings.apiToken || "";
  workspace.value = settings.workspace || DEFAULT_WORKSPACE;
  version.textContent = `Adapter v${chrome.runtime.getManifest().version}`;
  renderLastDelivery(settings.lastDelivery);
  await checkDaemon();
}

async function save() {
  const settings = currentSettings();
  await chrome.storage.local.set({
    daemonUrl: settings.daemonUrl,
    apiToken: settings.apiToken,
    workspace: settings.workspace,
  });
  if (settings.apiToken) {
    // Clear the error badge now that the user has set a token.
    chrome.action.setBadgeText({ text: "" });
    setStatus("Saved", "Settings saved. Click Test to send a sample browser event.");
  } else {
    setStatus("Needs token", "Copy API token in AI Monitor Settings, paste it here, then click Test.");
  }
}

async function sendTestEvent() {
  await save();
  if (!apiToken.value.trim()) {
    return;
  }

  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const response = await chrome.runtime.sendMessage({
      type: "ai-monitor:event",
      payload: {
        source: "browser-test",
        status: "running",
        step: "Floating window test",
        message: "Chrome extension reached AI Monitor",
        confidence: 1,
        title: "Browser adapter test",
        sessionName: "Floating window test",
        windowTitle: tab?.title ? `${tab.title} - Chrome` : "Chrome",
        url: tab?.url || "",
        detector: "popup-test",
        notifyExternal: false,
      },
    });

    if (!response?.ok) {
      throw new Error(response?.error || "Test failed");
    }

    statusText.textContent = "Sent";
    lastDelivery.textContent = `Floating test sent · v${chrome.runtime.getManifest().version}`;
    helpText.textContent = "The extension can reach AI Monitor. Supported AI tabs will report automatically.";
  } catch (error) {
    setStatus("Failed", friendlyErrorMessage(error));
  }
}

async function clearToken() {
  await chrome.storage.local.remove("apiToken");
  apiToken.value = "";
  statusText.textContent = "Token cleared";
  await checkDaemon();
}

async function openAIMonitorSettings() {
  setStatus("Opening", "If your browser asks, allow it to open AI Monitor Settings.");
  try {
    // Update current tab instead of creating a new one to avoid a flash of
    // "can't open page" before macOS routes the custom URL scheme to the app.
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (tab?.id !== undefined) {
      await chrome.tabs.update(tab.id, { url: "ai-monitor://settings" });
    } else {
      await chrome.tabs.create({ url: "ai-monitor://settings", active: true });
    }
  } catch {
    setStatus("Open failed", "Open AI Monitor from Applications, then choose Settings from the menu bar.");
  }
}

async function checkDaemon() {
  try {
    const settings = currentSettings();
    const headers = settings.apiToken ? { "x-ai-monitor-token": settings.apiToken } : {};
    const response = await fetch(`${settings.daemonUrl}/tasks`, { headers });
    if (response.ok) {
      setStatus("Online", "AI Monitor is reachable. Supported AI tabs will report automatically.");
    } else if (response.status === 401) {
      setStatus("Needs token", "Copy API token in AI Monitor Settings, paste it here, then click Test.");
    } else {
      setStatus(`HTTP ${response.status}`, "Open AI Monitor Settings and click Test connection, then retry this extension.");
    }
  } catch (error) {
    setStatus("Offline", friendlyErrorMessage(error));
  }
}

function renderLastDelivery(delivery) {
  if (!delivery) {
    lastDelivery.textContent = "";
    return;
  }
  if (delivery.ok === false) {
    lastDelivery.textContent = `⚠ ${delivery.error || "Delivery failed"} · ${delivery.updatedAt || ""}`;
    lastDelivery.style.color = "#cc3333";
    return;
  }
  lastDelivery.style.color = "";
  const debug = delivery.debug ? ` · ${delivery.debug}` : "";
  const adapter = delivery.adapterVersion ? ` · v${delivery.adapterVersion}` : "";
  lastDelivery.textContent = `${delivery.status} · ${delivery.sessionName}${debug}${adapter} · ${delivery.updatedAt}`;
}

function currentSettings() {
  return {
    daemonUrl: normalizedDaemonUrl(),
    apiToken: apiToken.value.trim(),
    workspace: workspace.value.trim() || DEFAULT_WORKSPACE,
  };
}

function normalizedDaemonUrl() {
  const raw = daemonUrl.value.trim() || DEFAULT_DAEMON_URL;
  try {
    const url = new URL(raw);
    if (url.protocol !== "http:" || !isLoopbackHost(url.hostname)) {
      throw new Error("daemon URL must be local");
    }
    return url.href.replace(/\/$/, "");
  } catch {
    daemonUrl.value = DEFAULT_DAEMON_URL;
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

function setStatus(status, message) {
  statusText.textContent = status;
  lastDelivery.textContent = message;
  helpText.textContent = message;
}

function friendlyErrorMessage(error) {
  const message = error?.message || "";
  if (message.includes("401")) {
    return "Copy API token in AI Monitor Settings, paste it here, then click Test.";
  }
  if (message.includes("Failed to fetch") || message.includes("NetworkError")) {
    return "Open AI Monitor from Applications, click Test connection or Start daemon, then retry.";
  }
  if (message.includes("Invalid URL")) {
    return "Keep Daemon URL on local HTTP loopback, such as http://127.0.0.1:4318.";
  }
  return message || "Test failed. Open AI Monitor Settings and click Test connection, then retry.";
}
