const params = new URLSearchParams(location.search);
const tabId = numberParam("tab_id");
const windowId = numberParam("window_id");
const target = params.get("target") || "";

activateOriginalTab().catch(() => {}).finally(closeHelperTab);

function numberParam(name) {
  const value = Number(params.get(name));
  return Number.isFinite(value) ? value : null;
}

async function activateOriginalTab() {
  if (windowId !== null) {
    await chrome.windows.update(windowId, { focused: true }).catch(() => {});
  }

  if (tabId !== null) {
    const tab = await chrome.tabs.update(tabId, { active: true }).catch(() => null);
    if (tab?.windowId !== undefined) {
      await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
      return;
    }
  }

  const tab = await findTabByUrl(target);
  if (tab?.id !== undefined) {
    await chrome.tabs.update(tab.id, { active: true }).catch(() => {});
    if (tab.windowId !== undefined) {
      await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
    }
    return;
  }

  if (target) {
    await chrome.tabs.create({ url: target, active: true }).catch(() => {});
  }
}

async function findTabByUrl(url) {
  if (!url) return null;

  const targetPrefix = withoutHash(url);
  const tabs = await chrome.tabs.query({}).catch(() => []);
  return tabs.find((tab) => {
    const candidate = tab.url || "";
    return candidate === url || withoutHash(candidate) === targetPrefix;
  }) || null;
}

function withoutHash(url) {
  try {
    const parsed = new URL(url);
    parsed.hash = "";
    return parsed.toString();
  } catch {
    return url.split("#")[0];
  }
}

async function closeHelperTab() {
  const current = await chrome.tabs.getCurrent().catch(() => null);
  if (current?.id !== undefined) {
    await chrome.tabs.remove(current.id).catch(() => {});
  }
}
