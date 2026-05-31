(() => {
const previousRuntime = globalThis.__AI_MONITOR_CONTENT_SCRIPT_RUNTIME__;
if (previousRuntime?.cleanup) {
  try {
    previousRuntime.cleanup();
  } catch {
    // A stale extension context should not prevent the fresh content script from taking over.
  }
}
const RUNTIME = {
  destroyed: false,
  intervals: [],
  listeners: [],
  observer: null,
  cleanup() {
    this.destroyed = true;
    this.observer?.disconnect?.();
    this.intervals.forEach((id) => window.clearInterval(id));
    this.listeners.forEach(([target, type, handler]) => {
      target.removeEventListener?.(type, handler);
    });
  },
};
globalThis.__AI_MONITOR_CONTENT_SCRIPT_RUNTIME__ = RUNTIME;
const TEST_MODE = Boolean(globalThis.__AI_MONITOR_TEST_MODE__);

const STATE = {
  initialized: false,
  lastObservedStatus: "unknown",
  lastSentStatus: "unknown",
  lastUserText: "",
  lastAssistantText: "",
  lastMediaSignature: "",
  lastTextChangeAt: Date.now(),
  runningStartedAt: 0,
  assistantChangedDuringRun: false,
  mediaResultSeenDuringRun: false,
  completedSentForRun: false,
  lastRunSignalAt: 0,
  lastPresenceAt: 0,
};

const DETECT_INTERVAL_MS = 1500;
const STABLE_COMPLETION_MS = 3500;
const MIN_COMPLETION_AFTER_PROMPT_MS = 15000;
const RUNNING_HEARTBEAT_MS = 10000;
const PRESENCE_HEARTBEAT_MS = 15000;

if (!TEST_MODE) {
  RUNTIME.observer = new MutationObserver(() => scheduleDetect());
  RUNTIME.observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    characterData: true,
  });
}

let pendingDetection = false;
function scheduleDetect() {
  if (RUNTIME.destroyed || pendingDetection) return;
  pendingDetection = true;
  window.setTimeout(() => {
    if (RUNTIME.destroyed) return;
    pendingDetection = false;
    detectAndReport();
  }, 250);
}

if (!TEST_MODE) {
  managedSetInterval(detectAndReport, DETECT_INTERVAL_MS);
  managedAddEventListener(window, "focus", detectAndReport);
  managedAddEventListener(window, "visibilitychange", detectAndReport);
  detectAndReport();
}

function detectAndReport() {
  if (RUNTIME.destroyed) {
    return;
  }
  if (!isSupportedAiPage(location.href)) {
    return;
  }

  const snapshot = captureSnapshot();
  if (!STATE.initialized) {
    STATE.initialized = true;
    STATE.lastUserText = snapshot.userText;
    STATE.lastAssistantText = snapshot.assistantText;
    STATE.lastMediaSignature = snapshot.mediaSignature;
    STATE.lastTextChangeAt = Date.now();
    const observed = classify(snapshot, {
      textChanged: false,
      userPromptChanged: false,
      activeRunOpen: false,
    });
    if (observed.status === "running") {
      STATE.runningStartedAt = Date.now();
      STATE.assistantChangedDuringRun = false;
      STATE.mediaResultSeenDuringRun = false;
      STATE.completedSentForRun = false;
      STATE.lastObservedStatus = "running";
      sendTransition(observed, { force: true });
    } else if (hasConversationSnapshot(snapshot)) {
      STATE.completedSentForRun = true;
      STATE.lastObservedStatus = "completed";
      sendTransition({
        ...observed,
        status: "completed",
        step: "Conversation observed",
        message: "AI web response is present",
        confidence: 0.65,
        debug: "initial completed observation",
        notify: false,
        userText: snapshot.userText,
      }, { force: true });
    } else {
      const presence = tabPresenceObservation(snapshot);
      STATE.lastObservedStatus = presence.status;
      sendTransition(presence, { force: true });
    }
    return;
  }

  const userPromptChanged = Boolean(
    snapshot.userText &&
      snapshot.userText !== STATE.lastUserText &&
      snapshot.userText.length >= 2
  );
  const previousAssistantText = STATE.lastAssistantText;
  const textChanged = Boolean(
    snapshot.assistantText &&
      snapshot.assistantText !== previousAssistantText
  );
  const activeRunOpen = STATE.runningStartedAt > 0 && !STATE.completedSentForRun;
  const mediaChanged = Boolean(
    snapshot.mediaSignature &&
      snapshot.mediaSignature !== STATE.lastMediaSignature
  );
  const assistantStartedWithoutRun = Boolean(
    textChanged &&
      !activeRunOpen &&
      !STATE.completedSentForRun &&
      (snapshot.userText || STATE.lastUserText)
  );
  const observed = classify(snapshot, {
    textChanged,
    userPromptChanged,
    activeRunOpen,
    assistantStartedWithoutRun,
    mediaChangedDuringRun: mediaChanged && activeRunOpen,
    mediaResultSeenDuringRun: STATE.mediaResultSeenDuringRun || (mediaChanged && activeRunOpen),
  });
  let nextObservedStatus = observed.status;

  if (userPromptChanged) {
    STATE.lastUserText = snapshot.userText;
    STATE.runningStartedAt = Date.now();
    STATE.assistantChangedDuringRun = false;
    STATE.mediaResultSeenDuringRun = false;
    STATE.completedSentForRun = false;
  }

  if (snapshot.assistantText && snapshot.assistantText !== previousAssistantText) {
    STATE.lastAssistantText = snapshot.assistantText;
    STATE.lastTextChangeAt = Date.now();
    if (STATE.runningStartedAt > 0) {
      STATE.assistantChangedDuringRun = true;
    }
  }

  if (mediaChanged) {
    STATE.lastMediaSignature = snapshot.mediaSignature;
    if (STATE.runningStartedAt > 0 && !STATE.completedSentForRun) {
      STATE.mediaResultSeenDuringRun = true;
      STATE.assistantChangedDuringRun = true;
      STATE.lastTextChangeAt = Date.now();
    }
  }

  if (observed.status === "running") {
    if (STATE.lastObservedStatus !== "running") {
      STATE.runningStartedAt = Date.now();
      STATE.assistantChangedDuringRun = textChanged || assistantStartedWithoutRun;
      STATE.mediaResultSeenDuringRun = false;
      STATE.completedSentForRun = false;
    }
    sendTransition(observed, { allowHeartbeat: true });
  } else if ((STATE.lastObservedStatus === "running" || activeRunOpen) && !STATE.completedSentForRun) {
    const stableFor = Date.now() - STATE.lastTextChangeAt;
    const runAge = Date.now() - STATE.runningStartedAt;
    const hasEnoughEvidence =
      STATE.assistantChangedDuringRun || observed.resultVisible || runAge >= MIN_COMPLETION_AFTER_PROMPT_MS;
    if (hasEnoughEvidence && stableFor >= STABLE_COMPLETION_MS) {
      STATE.completedSentForRun = true;
      const completed = {
        ...observed,
        status: "completed",
        step: "Generation completed",
        message: "AI web response stopped changing",
        confidence: Math.max(0.78, observed.confidence),
        notify: true,
      };
      nextObservedStatus = completed.status;
      sendTransition(completed, { force: true });
    }
  } else if (["failed", "waiting_for_input"].includes(observed.status)) {
    sendTransition(observed);
  } else {
    const presenceStatus = maybeSendPresence(snapshot);
    if (presenceStatus) {
      nextObservedStatus = presenceStatus;
    }
  }

  STATE.lastObservedStatus = nextObservedStatus;
}

function sendTransition(observed, options = {}) {
  if (RUNTIME.destroyed) {
    return false;
  }

  const now = Date.now();
  if (!options.force && observed.status === STATE.lastSentStatus && observed.status !== "running") {
    return false;
  }

  if (!options.force && observed.status === "running" && STATE.lastSentStatus === "running") {
    if (now - STATE.lastRunSignalAt < RUNNING_HEARTBEAT_MS) {
      return false;
    }
  }

  const titles = titlesForPage(observed.userText);
  const debug = [observed.debug, titles.debug].filter(Boolean).join(" · ");
  const message = {
    type: "ai-monitor:event",
    payload: {
      source: sourceForLocation(location.href),
      status: observed.status,
      step: observed.step,
      message: observed.message,
      confidence: observed.confidence,
      debug,
      title: titles.taskTitle,
      sessionName: titles.sessionName,
      windowTitle: `${titles.windowTitle} - Chrome`,
      url: location.href,
      prompt: observed.userText || "",
      detector: "ai-webpage-heuristics",
      notifyDesktop: observed.notify ?? true,
      notifyExternal: observed.notify ?? true,
    },
  };

  try {
    chrome.runtime.sendMessage(message);
  } catch {
    return false;
  }

  STATE.lastSentStatus = observed.status;
  if (observed.status === "running") {
    STATE.lastRunSignalAt = now;
  }
  STATE.lastPresenceAt = now;
  return true;
}

function managedSetInterval(handler, interval) {
  const id = window.setInterval(handler, interval);
  RUNTIME.intervals.push(id);
  return id;
}

function managedAddEventListener(target, type, handler) {
  target.addEventListener(type, handler);
  RUNTIME.listeners.push([target, type, handler]);
}

function captureSnapshot() {
  const mediaSignature = visibleGeneratedMediaSignature();
  return {
    host: location.hostname,
    title: document.title || "",
    bodyText: (document.body?.innerText || "").slice(-5000),
    errorText: visibleErrorText(),
    runningText: visibleRunningText(),
    mainText: visibleMainText(),
    mediaResultVisible: Boolean(mediaSignature),
    mediaSignature,
    userText: latestUserText(),
    assistantText: latestAssistantText(),
    buttons: Array.from(document.querySelectorAll("button, [role='button']"))
      .map((element) => textOf(element))
      .filter(Boolean),
  };
}

function classify(snapshot, context = {}) {
  const buttons = snapshot.buttons.map((value) => value.toLowerCase());
  const errorText = snapshot.errorText.toLowerCase();
  const pageShowsRunningText = Boolean(snapshot.runningText);
  const stopControlVisible = hasVisibleStopControl();
  const streamingMarkerVisible = hasVisibleStreamingMarker();
  const spinnerVisible = hasVisibleSpinner();
  const mediaResultVisible = snapshot.mediaResultVisible;

  if (
    hasAny(errorText, errorNeedles()) ||
    buttons.some((button) => ["retry", "try again", "重试"].includes(button))
  ) {
    return {
      status: "failed",
      step: "Page shows error or retry",
      message: "The AI web task appears to have failed",
      confidence: 0.76,
      userText: snapshot.userText,
    };
  }

  if (buttons.some((button) => hasAny(button, continueNeedles()))) {
    return {
      status: "waiting_for_input",
      step: "Waiting for user action",
      message: "The AI web page is asking the user to continue or respond",
      confidence: 0.82,
      userText: snapshot.userText,
    };
  }

  if (
    context.userPromptChanged ||
    context.assistantStartedWithoutRun ||
    (context.textChanged && context.activeRunOpen)
  ) {
    const signal = context.userPromptChanged
      ? "new user prompt"
      : context.assistantStartedWithoutRun
        ? "assistant response appeared"
      : context.textChanged && context.activeRunOpen
        ? "assistant text changed"
        : pageShowsRunningText
          ? "page activity text"
          : stopControlVisible
            ? "visible stop control"
            : spinnerVisible
              ? "visible spinner"
              : "visible streaming marker";
    return {
      status: "running",
      step: "Generating response",
      message: context.userPromptChanged
        ? "A new prompt was submitted"
        : context.assistantStartedWithoutRun
        ? "AI response text appeared"
        : context.textChanged && context.activeRunOpen
        ? "AI response text is changing"
        : pageShowsRunningText
          ? "The AI web page shows active generation text"
          : "The AI web page is generating",
      confidence: context.userPromptChanged ? 0.74 : context.textChanged ? 0.72 : 0.86,
      debug: signal,
      userText: snapshot.userText,
    };
  }

  if (
    mediaResultVisible &&
    (!context.activeRunOpen || context.mediaResultSeenDuringRun || context.mediaChangedDuringRun)
  ) {
    return {
      status: "unknown",
      step: "Result visible",
      message: "A generated media result is visible",
      confidence: 0.78,
      debug: context.mediaChangedDuringRun ? "new generated media" : "visible generated media",
      resultVisible: true,
      userText: snapshot.userText,
    };
  }

  if (
    stopControlVisible ||
    streamingMarkerVisible ||
    spinnerVisible ||
    pageShowsRunningText
  ) {
    const signal = pageShowsRunningText
      ? "page activity text"
      : stopControlVisible
        ? "visible stop control"
        : spinnerVisible
          ? "visible spinner"
          : "visible streaming marker";
    return {
      status: "running",
      step: "Generating response",
      message: pageShowsRunningText
        ? "The AI web page shows active generation text"
        : "The AI web page is generating",
      confidence: 0.86,
      debug: signal,
      userText: snapshot.userText,
    };
  }

  return {
    status: "unknown",
    step: "Idle",
    message: "No active generation detected",
    confidence: 0.55,
    userText: snapshot.userText,
  };
}

function hasConversationSnapshot(snapshot) {
  return Boolean(
    (conversationSnapshotText(snapshot) || snapshot.mediaResultVisible) &&
      (snapshot.userText || conversationTitleFromPage() || snapshot.title)
  );
}

function maybeSendPresence(snapshot) {
  if (Date.now() - STATE.lastPresenceAt < PRESENCE_HEARTBEAT_MS) {
    return null;
  }
  const presence = tabPresenceObservation(snapshot);
  return sendTransition(presence, { force: true }) ? presence.status : null;
}

function tabPresenceObservation(snapshot) {
  if (hasConversationSnapshot(snapshot)) {
    return {
      status: "completed",
      step: "Tab open",
      message: "AI web tab is open with a completed response",
      confidence: 0.62,
      debug: `tab presence heartbeat · completed:${conversationSnapshotReason(snapshot)}`,
      notify: false,
      userText: snapshot.userText,
    };
  }

  return {
    status: "unknown",
    step: "Tab open",
    message: "AI web tab is open",
    confidence: 0.58,
    debug: "tab presence heartbeat",
    notify: false,
    userText: snapshot.userText,
  };
}

function latestAssistantText() {
  const selectors = [
    "[data-message-author-role='assistant']",
    "[data-testid*='assistant']",
    "[data-testid*='message-content']",
    "[class*='font-claude-message']",
    "[class*='prose']",
    ".markdown",
    "article",
    "main p",
  ];
  for (const selector of selectors) {
    const nodes = Array.from(document.querySelectorAll(selector)).filter((element) =>
      isElementVisible(element) && !element.closest("aside, nav, form, textarea, [contenteditable='true'], button, [role='button']")
    );
    for (let index = nodes.length - 1; index >= 0; index -= 1) {
      const text = cleanConversationText(textOf(nodes[index]));
      if (text) return text;
    }
  }
  return "";
}

function conversationSnapshotText(snapshot) {
  const assistantText = cleanConversationText(snapshot.assistantText);
  if (assistantText) return assistantText;
  return readableMainConversationText(snapshot);
}

function conversationSnapshotReason(snapshot) {
  if (cleanConversationText(snapshot.assistantText)) return "assistant_text";
  if (snapshot.mediaResultVisible) return "media_result";
  if (readableMainConversationText(snapshot)) return "main_text";
  return "none";
}

function visibleGeneratedMediaSignature() {
  const root =
    document.querySelector("main") ||
    document.querySelector("[role='main']") ||
    document.body;

  const media = Array.from(root.querySelectorAll("img, video"))
    .filter((element) => {
      if (!isElementVisible(element)) return false;
      if (element.closest("aside, nav, form, textarea, [contenteditable='true']")) {
        return false;
      }
      if (element.closest("[data-message-author-role='user'], [data-testid*='user']")) {
        return false;
      }

      const rect = element.getBoundingClientRect();
      if (rect.width < 180 || rect.height < 120) return false;

      if (element.tagName.toLowerCase() === "img") {
        return element.complete !== false &&
          (element.naturalWidth || 0) >= 180 &&
          (element.naturalHeight || 0) >= 120;
      }

      return true;
    })
    .map((element) => {
      const rect = element.getBoundingClientRect();
      const source = element.currentSrc || element.src || element.poster || "";
      return [
        element.tagName.toLowerCase(),
        source.slice(0, 180),
        Math.round(rect.width),
        Math.round(rect.height),
        element.naturalWidth || element.videoWidth || 0,
        element.naturalHeight || element.videoHeight || 0,
      ].join(":");
    });

  return media.join("|");
}

function readableMainConversationText(snapshot) {
  const text = stripUiText(`${snapshot.mainText || ""} ${snapshot.bodyText || ""}`);
  if (!text) return "";

  const withoutPrompt = snapshot.userText ? text.replace(snapshot.userText, " ") : text;
  const normalized = cleanTitleFragment(withoutPrompt);
  if (normalized.length < 80) return "";

  return normalized;
}

function latestUserText() {
  const selectors = [
    "[data-message-author-role='user'] .whitespace-pre-wrap",
    "[data-message-author-role='user'] [class*='whitespace-pre-wrap']",
    "[data-message-author-role='user'] [dir='auto']",
    "[data-message-author-role='user']",
    "[data-testid*='user']",
  ];
  for (const selector of selectors) {
    const nodes = Array.from(document.querySelectorAll(selector)).filter((element) =>
      isElementVisible(element)
    );
    for (let index = nodes.length - 1; index >= 0; index -= 1) {
      const text = cleanPromptText(textOf(nodes[index]));
      if (text) return text;
    }
  }
  return latestRightAlignedPromptText();
}

function latestRightAlignedPromptText() {
  const root =
    document.querySelector("main") ||
    document.querySelector("[role='main']") ||
    document.body;
  const candidates = Array.from(root.querySelectorAll("div, p, span"))
    .filter((element) => isElementVisible(element))
    .filter((element) => !element.closest("aside, nav, form, textarea, [contenteditable='true'], button, [role='button']"))
    .map((element) => ({
      element,
      text: cleanPromptText(textOf(element)),
      rect: element.getBoundingClientRect(),
    }))
    .filter(({ text, rect }) => {
      if (text.length < 2 || text.length > 240) return false;
      if (rect.top > window.innerHeight - 140) return false;
      if (rect.left < window.innerWidth * 0.48) return false;
      if (rect.width > window.innerWidth * 0.45) return false;
      return !ignoredPromptCandidate(text);
    })
    .sort((left, right) => right.rect.bottom - left.rect.bottom);

  return candidates[0]?.text || "";
}

function ignoredPromptCandidate(text) {
  const lower = text.toLowerCase();
  if (["chatgpt", "new chat", "temporary chat"].includes(lower)) {
    return true;
  }
  return [
    "share",
    "ask anything",
    "chatgpt can make mistakes",
    "thought for",
    "copy",
    "good response",
    "bad response",
    "read aloud",
  ].some((needle) => lower.includes(needle));
}

function hasVisibleStopControl() {
  return visibleSignalElements().some((element) => {
    const label = elementLabel(element);
    const testId = (element.getAttribute("data-testid") || "").toLowerCase();

    return (
      testId === "stop-button" ||
      testId === "stop-generating" ||
      testId === "stop-streaming" ||
      label === "stop" ||
      label === "停止" ||
      label.includes("stop generating") ||
      label.includes("stop streaming") ||
      label.includes("停止生成") ||
      label.includes("停止回答")
    );
  });
}

function hasVisibleStreamingMarker() {
  return visibleSignalElements().some((element) => {
    const role = (element.getAttribute("role") || "").toLowerCase();
    const testId = (element.getAttribute("data-testid") || "").toLowerCase();
    const label = elementLabel(element);

    return (
      role === "progressbar" ||
      testId === "generating" ||
      testId === "thinking" ||
      testId === "loading-response" ||
      testId === "streaming-response" ||
      label.includes("generating response") ||
      label.includes("streaming response")
    );
  });
}

function hasVisibleSpinner() {
  return Array.from(
    document.querySelectorAll("[class*='animate-spin'], svg, [role='progressbar'], [data-testid*='spinner'], [data-testid*='loading']")
  ).some((element) => {
    if (!isElementVisible(element)) return false;
    if (element.closest("aside, nav, form, button, [role='button'], pre, code")) return false;

    const rect = element.getBoundingClientRect();
    if (rect.width < 8 || rect.height < 8 || rect.width > 96 || rect.height > 96) {
      return false;
    }

    return hasActiveAnimation(element) || isClaudeResponseSpinner(element);
  });
}

function hasActiveAnimation(element) {
  const elements = [element, ...Array.from(element.querySelectorAll("*")).slice(0, 12)];
  return elements.some((node) => {
    const style = window.getComputedStyle(node);
    return style.animationName !== "none" && !["0s", "0ms"].includes(style.animationDuration);
  });
}

function isClaudeResponseSpinner(element) {
  if (!location.hostname.includes("claude.ai")) return false;

  const rect = element.getBoundingClientRect();
  if (rect.top < window.innerHeight * 0.35) return false;

  const style = window.getComputedStyle(element);
  const colorText = [
    style.color,
    style.fill,
    style.stroke,
    element.getAttribute("fill"),
    element.getAttribute("stroke"),
    element.getAttribute("class"),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  return /orange|accent|rgb\(2[0-9]{2},\s*9[0-9],\s*[5-9][0-9]\)|#d977|#da7756|#cc785c/.test(colorText);
}

function visibleSignalElements() {
  return Array.from(
    document.querySelectorAll("button, [role='button'], [role='status'], [role='progressbar'], [aria-label], [title], [data-testid]")
  ).filter((element) => isElementVisible(element));
}

function visibleRunningText() {
  const selectors = [
    "[data-testid*='thinking']",
    "[data-testid*='Thinking']",
    "[data-testid*='generating']",
    "[data-testid*='Generating']",
    "[aria-live]",
    "[role='status']",
    ".animate-pulse",
    "main div",
    "main span",
    "main p",
  ];

  const seen = new Set();
  return selectors
    .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
    .filter((element) => {
      if (seen.has(element)) return false;
      seen.add(element);
      if (!isElementVisible(element)) return false;
      if (element.closest("aside, nav, form, textarea, [contenteditable='true'], button, [role='button'], pre, code") ||
          isInsideInputComposer(element)) {
        return false;
      }
      if (element.querySelector?.("pre, code")) {
        return false;
      }
      return true;
    })
    .map((element) => cleanTitleFragment(textOf(element)))
    .filter((text) => isRunningActivityText(text))
    .join(" ");
}

function isRunningActivityText(value) {
  const text = cleanTitleFragment(value);
  const lower = text.toLowerCase();
  if (!lower || lower.length > 180) return false;
  if (lower.includes("thought for")) return false;
  if (lower === "thinking") return false;

  if (
    lower.includes("hang tight") ||
    lower.includes("grok is thinking") ||
    lower.includes("grok is responding") ||
    lower.includes("正在思考") ||
    lower.includes("思考中") ||
    lower.includes("正在生成") ||
    lower.includes("生成中") ||
    lower.includes("请稍候")
  ) {
    return true;
  }

  return /^(thinking|generating|creating|working on)(?:[\s.:：,，—-]|$)/i.test(text);
}

function visibleMainText() {
  const root =
    document.querySelector("main") ||
    document.querySelector("[role='main']") ||
    document.body;

  return textOf(root).slice(-5000);
}

function visibleErrorText() {
  const selectors = [
    "[role='alert']",
    "[data-testid*='error']",
    "[data-testid*='Error']",
    ".text-token-text-error",
    ".text-red-500",
    ".text-red-600",
  ];

  return selectors
    .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
    .filter((element) => isElementVisible(element))
    .map((element) => textOf(element))
    .filter(Boolean)
    .join(" ");
}

function titlesForPage(userText) {
  const prompt = concisePrompt(userText || latestUserText());
  const conversation = conversationTitleFromPage();
  const documentName = cleanConversationTitle(document.title || "");
  const appName = appNameForLocation();
  const taskTitle =
    firstMeaningfulTitle([prompt, conversation, documentName]) || `${appName} web task`;
  const sessionName =
    firstMeaningfulTitle([conversation, documentName, prompt]) || appName;
  const windowTitle = firstMeaningfulTitle([documentName, conversation, prompt]) || appName;
  const debug = `title:${titleSource(taskTitle, { prompt, conversation, documentName })}/session:${titleSource(sessionName, { prompt, conversation, documentName })}`;

  return { taskTitle, sessionName, windowTitle, debug };
}

function cleanConversationTitle(title) {
  return cleanTitleFragment(title)
    .replace(/^ChatGPT\s*[-|:]\s*/i, "")
    .replace(/^Claude\s*[-|:]\s*/i, "")
    .replace(/^Gemini\s*[-|:]\s*/i, "")
    .replace(/^Perplexity\s*[-|:]\s*/i, "")
    .replace(/^Grok\s*[-|:]\s*/i, "")
    .replace(/\s*[-|]\s*ChatGPT\s*$/i, "")
    .replace(/\s*[-|]\s*Claude\s*$/i, "")
    .replace(/\s*[-|]\s*Gemini\s*$/i, "")
    .replace(/\s*[-|]\s*Perplexity\s*$/i, "")
    .replace(/\s*[-|]\s*Grok\s*$/i, "")
    .trim();
}

function conversationTitleFromPage() {
  const matchingLink = currentConversationLinkTitle();
  if (matchingLink) return matchingLink;

  const currentLink = Array.from(document.querySelectorAll("a[aria-current='page'], [aria-current='page']"))
    .filter((element) => isElementVisible(element))
    .map((element) => cleanConversationTitle(textOf(element)))
    .find((title) => isMeaningfulTitle(title));
  if (currentLink) return currentLink;

  const metaTitle = cleanConversationTitle(
    document.querySelector("meta[property='og:title']")?.getAttribute("content") || ""
  );
  if (isMeaningfulTitle(metaTitle)) return metaTitle;

  return "";
}

function currentConversationLinkTitle() {
  const currentPath = normalizePath(location.pathname);
  if (!currentPath || currentPath === "/") return "";

  const links = Array.from(document.querySelectorAll("a[href]")).filter((element) =>
    isElementVisible(element)
  );
  for (let index = links.length - 1; index >= 0; index -= 1) {
    const link = links[index];
    const url = safeUrl(link.href);
    if (!url || url.origin !== location.origin) continue;
    if (normalizePath(url.pathname) !== currentPath) continue;

    const title = cleanConversationTitle(textOf(link));
    if (isMeaningfulTitle(title)) return title;
  }
  return "";
}

function appNameForLocation() {
  const host = location.hostname;
  if (host.includes("chatgpt.com") || host.includes("chat.openai.com")) return "ChatGPT";
  if (host.includes("claude.ai")) return "Claude";
  if (host.includes("gemini.google.com")) return "Gemini";
  if (host.includes("perplexity.ai")) return "Perplexity";
  if (isGrokLocation(location.href)) return "Grok";
  if (host === "github.com" || host.endsWith(".github.com")) return "GitHub";
  return "AI browser";
}

function firstMeaningfulTitle(values) {
  return values.map((value) => cleanTitleFragment(value)).find((value) => isMeaningfulTitle(value)) || "";
}

function titleSource(value, sources) {
  if (!value) return "fallback";
  if (value === cleanTitleFragment(sources.prompt)) return "prompt";
  if (value === cleanTitleFragment(sources.conversation)) return "conversation";
  if (value === cleanTitleFragment(sources.documentName)) return "document";
  return "fallback";
}

function isMeaningfulTitle(value) {
  const title = cleanTitleFragment(value);
  if (!title) return false;
  const lower = title.toLowerCase();
  return ![
    "chatgpt",
    "claude",
    "gemini",
    "perplexity",
    "grok",
    "new chat",
    "temporary chat",
    "untitled",
    "ai browser",
    "ai browser task",
  ].includes(lower);
}

function concisePrompt(value) {
  const prompt = cleanPromptText(value || "");
  if (!prompt) return "";
  return prompt.length > 36 ? `${prompt.slice(0, 35)}...` : prompt;
}

function cleanPromptText(value) {
  const text = cleanTitleFragment(value);
  if (!text || ignoredPromptCandidate(text)) return "";
  return text;
}

function cleanConversationText(value) {
  const text = stripVolatileResponseText(cleanTitleFragment(value));
  if (!text || ignoredConversationCandidate(text)) return "";
  return text;
}

function stripVolatileResponseText(value) {
  return cleanTitleFragment(value)
    .replace(/\bThought for (?:a second|a few seconds|a couple of seconds|\d+\s*m(?:in)?\s*\d+\s*s(?:ec(?:ond)?s?)?|\d+\s*s(?:ec(?:ond)?s?)?)\s*>?/gi, " ")
    .replace(/\bThinking\b\.?/gi, " ")
    .replace(/\bGenerating a more detailed image\s*[—-]\s*hang tight\.?/gi, " ")
    .replace(/\bStop generating\b/gi, " ")
    .replace(/\bCopy(?: code)?\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function stripUiText(value) {
  return cleanTitleFragment(value)
    .replace(/\bShare\b/gi, " ")
    .replace(/\bWrite a message\b/gi, " ")
    .replace(/\bWant to be notified when Claude responds\?/gi, " ")
    .replace(/\bClaude can make mistakes\. Please double-check responses\./gi, " ")
    .replace(/\bChatGPT can make mistakes\. Check important info\./gi, " ")
    .replace(/\bSonnet\s+\d+(?:\.\d+)?\b/gi, " ")
    .replace(/\bAdaptive\b/gi, " ")
    .replace(/\bCopy\b|\bRetry\b|\bGood response\b|\bBad response\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function ignoredConversationCandidate(text) {
  const lower = text.toLowerCase();
  return [
    "share",
    "write a message",
    "want to be notified when claude responds",
    "claude can make mistakes",
    "chatgpt can make mistakes",
    "sonnet",
    "adaptive",
  ].some((needle) => lower.includes(needle));
}

function cleanTitleFragment(value) {
  return (value || "")
    .replace(/\s+/g, " ")
    .replace(/^\s*["“”'‘’]+|["“”'‘’]+\s*$/g, "")
    .trim();
}

function sourceForLocation(url) {
  if (isGrokLocation(url)) return "grok-web";

  const host = new URL(url).hostname;
  if (host.includes("chatgpt.com") || host.includes("chat.openai.com")) return "chatgpt-web";
  if (host.includes("claude.ai")) return "claude-web";
  if (host.includes("gemini.google.com")) return "gemini-web";
  if (host.includes("perplexity.ai")) return "perplexity-web";
  if (isGitHubLocation(url)) return "github-web";
  return "browser";
}

function isSupportedAiLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed) return false;

  const host = parsed.hostname;
  return (
    host.includes("chatgpt.com") ||
    host.includes("chat.openai.com") ||
    host.includes("claude.ai") ||
    host.includes("gemini.google.com") ||
    host.includes("perplexity.ai") ||
    isGrokLocation(url)
  );
}

function isSupportedAiPage(url) {
  return isSupportedAiLocation(url) || isGitHubAiPage(url);
}

function isGitHubAiPage(url) {
  if (!isGitHubLocation(url)) return false;
  if (isGitHubAiLocation(url)) return true;

  if (document.querySelector('[data-testid*="copilot"], [aria-label*="Copilot"], [class*="copilot"]')) {
    return true;
  }

  const pageText = `${document.title || ""} ${document.body?.innerText || ""}`.toLowerCase();
  return [
    "github copilot",
    "copilot coding agent",
    "coding agent",
  ].some((needle) => pageText.includes(needle));
}

function isGitHubLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed) return false;
  return parsed.hostname === "github.com" || parsed.hostname.endsWith(".github.com");
}

function isGitHubAiLocation(url) {
  const parsed = safeUrl(url);
  if (!parsed || !isGitHubLocation(url)) return false;
  const path = parsed.pathname.toLowerCase();
  return path.includes("/copilot") ||
    path.includes("/github-copilot") ||
    path.includes("/coding-agent") ||
    path.includes("/copilot-coding-agent");
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

function textOf(element) {
  return (element?.innerText || element?.textContent || element?.getAttribute?.("aria-label") || "")
    .replace(/\s+/g, " ")
    .trim();
}

function elementLabel(element) {
  return [
    element.getAttribute?.("aria-label"),
    element.getAttribute?.("title"),
    element.textContent,
  ]
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function isElementVisible(element) {
  if (!element || element.getAttribute?.("aria-hidden") === "true") return false;
  const rect = element.getBoundingClientRect?.();
  if (!rect || rect.width === 0 || rect.height === 0) return false;
  const style = window.getComputedStyle(element);
  return style.visibility !== "hidden" && style.display !== "none" && Number(style.opacity || "1") > 0;
}

function isInsideInputComposer(element) {
  return Boolean(element?.closest?.(
    [
      "form",
      "textarea",
      "[contenteditable='true']",
      "[data-lexical-editor='true']",
      "[data-testid*='composer']",
      "[data-testid*='prompt-textarea']",
      "[id*='composer']",
      "[class*='composer']",
      "[class*='prompt-textarea']",
    ].join(", ")
  ));
}

function hasAny(value, needles) {
  return needles.some((needle) => value.includes(needle));
}

function normalizePath(value) {
  return (value || "").replace(/\/+$/, "") || "/";
}

function safeUrl(value) {
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

function continueNeedles() {
  return [
    "continue generating",
    "continue",
    "resume",
    "继续生成",
    "继续",
  ];
}

function errorNeedles() {
  return [
    "something went wrong",
    "there was an error",
    "network error",
    "try again",
    "出了点问题",
    "网络错误",
    "重试",
  ];
}

if (TEST_MODE) {
  globalThis.__AI_MONITOR_TEST_API__ = {
    captureSnapshot,
    classify,
    hasConversationSnapshot,
    sourceForLocation,
    isSupportedAiLocation,
    isSupportedAiPage,
    isGitHubAiPage,
    titlesForPage,
  };
}
})();
