#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..");
const CONTENT_SCRIPT = path.join(ROOT, "content.js");
const FIXTURES = [
  {
    file: "chatgpt-completed.html",
    url: "https://chatgpt.com/c/abc123",
    status: "completed",
    source: "chatgpt-web",
    titleIncludes: "Explain agent monitoring",
    assistantIncludes: "tracks each worker",
  },
  {
    file: "chatgpt-image-completed.html",
    url: "https://chatgpt.com/c/image123",
    status: "completed",
    source: "chatgpt-web",
    titleIncludes: "做成金色",
    mediaResultVisible: true,
  },
  {
    file: "claude-running.html",
    url: "https://claude.ai/chat/abc123",
    status: "running",
    source: "claude-web",
    titleIncludes: "Refactor daemon",
  },
  {
    file: "gemini-waiting.html",
    url: "https://gemini.google.com/app/abc123",
    status: "waiting_for_input",
    source: "gemini-web",
    titleIncludes: "Generate release notes",
  },
  {
    file: "perplexity-failed.html",
    url: "https://www.perplexity.ai/search/abc123",
    status: "failed",
    source: "perplexity-web",
    titleIncludes: "Research monitors",
  },
  {
    file: "grok-running.html",
    url: "https://grok.com/chat/abc123",
    status: "running",
    source: "grok-web",
    titleIncludes: "Explain vector indexes",
  },
  {
    file: "github-copilot-completed.html",
    url: "https://github.com/acme/widget/pull/42",
    status: "completed",
    source: "github-web",
    titleIncludes: "Review PR failure",
    assistantIncludes: "failing check is caused",
  },
];

const NEGATIVE_FIXTURES = [
  {
    file: "github-ordinary.html",
    url: "https://github.com/notracc1210",
  },
];

function main() {
  const source = fs.readFileSync(CONTENT_SCRIPT, "utf8");
  for (const fixture of FIXTURES) {
    runFixture(source, fixture);
  }
  for (const fixture of NEGATIVE_FIXTURES) {
    runNegativeFixture(source, fixture);
  }
  console.log(`browser detector fixtures passed: ${FIXTURES.length + NEGATIVE_FIXTURES.length}`);
}

function runFixture(contentScript, fixture) {
  const html = fs.readFileSync(path.join(__dirname, "fixtures", fixture.file), "utf8");
  const document = parseHtml(html);
  const location = new URL(fixture.url);
  const context = {
    console,
    URL,
    Date,
    __AI_MONITOR_TEST_MODE__: true,
    document,
    location,
    chrome: {
      runtime: {
        sendMessage() {},
      },
    },
    MutationObserver: class {
      observe() {}
    },
  };
  context.globalThis = context;
  context.window = {
    innerWidth: 1280,
    innerHeight: 800,
    setTimeout() {},
    setInterval() {},
    addEventListener() {},
    getComputedStyle(element) {
      return element.computedStyle();
    },
  };
  context.window.window = context.window;
  context.window.document = document;
  context.window.location = location;
  context.window.globalThis = context;

  vm.runInNewContext(contentScript, context, {
    filename: CONTENT_SCRIPT,
  });

  const api = context.__AI_MONITOR_TEST_API__;
  assert(api, fixture.file, "test API was not exposed");
  assert(api.isSupportedAiPage(fixture.url), fixture.file, "page should be supported");
  assertEqual(api.sourceForLocation(fixture.url), fixture.source, fixture.file, "source");

  const snapshot = api.captureSnapshot();
  const classified = api.classify(snapshot, fixture.context || {});
  const status =
    classified.status === "unknown" && api.hasConversationSnapshot(snapshot)
      ? "completed"
      : classified.status;
  assertEqual(status, fixture.status, fixture.file, "status");

  if (fixture.titleIncludes) {
    const titles = api.titlesForPage(snapshot.userText);
    assert(
      titles.taskTitle.includes(fixture.titleIncludes) ||
        titles.sessionName.includes(fixture.titleIncludes) ||
        titles.windowTitle.includes(fixture.titleIncludes),
      fixture.file,
      `title should include ${fixture.titleIncludes}; got ${JSON.stringify(titles)}`
    );
  }

  if (fixture.assistantIncludes) {
    assert(
      snapshot.assistantText.includes(fixture.assistantIncludes),
      fixture.file,
      `assistant text should include ${fixture.assistantIncludes}; got ${snapshot.assistantText}`
    );
  }

  if (fixture.mediaResultVisible) {
    assert(snapshot.mediaResultVisible, fixture.file, "media result should be visible");
  }
}

function runNegativeFixture(contentScript, fixture) {
  const html = fs.readFileSync(path.join(__dirname, "fixtures", fixture.file), "utf8");
  const document = parseHtml(html);
  const location = new URL(fixture.url);
  const context = {
    console,
    URL,
    Date,
    __AI_MONITOR_TEST_MODE__: true,
    document,
    location,
    chrome: {
      runtime: {
        sendMessage() {},
      },
    },
    MutationObserver: class {
      observe() {}
    },
  };
  context.globalThis = context;
  context.window = {
    innerWidth: 1280,
    innerHeight: 800,
    setTimeout() {},
    setInterval() {},
    addEventListener() {},
    getComputedStyle(element) {
      return element.computedStyle();
    },
  };
  context.window.window = context.window;
  context.window.document = document;
  context.window.location = location;
  context.window.globalThis = context;

  vm.runInNewContext(contentScript, context, {
    filename: CONTENT_SCRIPT,
  });

  const api = context.__AI_MONITOR_TEST_API__;
  assert(api, fixture.file, "test API was not exposed");
  assert(!api.isSupportedAiPage(fixture.url), fixture.file, "ordinary GitHub page should not be supported");
}

class TestNode {
  constructor(tagName, attrs = {}) {
    this.tagName = tagName.toUpperCase();
    this.localName = tagName.toLowerCase();
    this.attributes = attrs;
    this.children = [];
    this.parentElement = null;
    this.ownText = "";
    this.complete = true;
    this.naturalWidth = Number(attrs["data-natural-width"] || attrs.width || 240);
    this.naturalHeight = Number(attrs["data-natural-height"] || attrs.height || 160);
    this.videoWidth = Number(attrs["data-video-width"] || attrs.width || 0);
    this.videoHeight = Number(attrs["data-video-height"] || attrs.height || 0);
  }

  appendChild(child) {
    child.parentElement = this;
    this.children.push(child);
  }

  get textContent() {
    return [this.ownText, ...this.children.map((child) => child.textContent)].join("");
  }

  get innerText() {
    return this.textContent;
  }

  get href() {
    return this.attributes.href || "";
  }

  get src() {
    return this.attributes.src || "";
  }

  get currentSrc() {
    return this.attributes.src || "";
  }

  get poster() {
    return this.attributes.poster || "";
  }

  getAttribute(name) {
    return this.attributes[name] ?? null;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  querySelectorAll(selector) {
    return querySelectorAll(this, selector);
  }

  closest(selector) {
    let current = this;
    while (current) {
      if (matchesSelectorList(current, selector)) return current;
      current = current.parentElement;
    }
    return null;
  }

  getBoundingClientRect() {
    if (this.attributes["data-hidden"] === "true") {
      return rect(0, 0, 0, 0);
    }
    return rect(
      Number(this.attributes["data-left"] || 80),
      Number(this.attributes["data-top"] || 100),
      Number(this.attributes["data-width"] || this.attributes.width || 320),
      Number(this.attributes["data-height"] || this.attributes.height || 28)
    );
  }

  computedStyle() {
    const style = parseStyle(this.attributes.style || "");
    return {
      visibility: style.visibility || "visible",
      display: style.display || "block",
      opacity: style.opacity || "1",
      animationName: style["animation-name"] || ((this.attributes.class || "").includes("animate-spin") ? "spin" : "none"),
      animationDuration: style["animation-duration"] || ((this.attributes.class || "").includes("animate-spin") ? "1s" : "0s"),
      color: style.color || "",
      fill: style.fill || "",
      stroke: style.stroke || "",
    };
  }
}

class TestDocument {
  constructor(root) {
    this.documentElement = root;
    this.body = root.querySelector("body") || root;
    this.title = cleanText(root.querySelector("title")?.textContent || "");
  }

  querySelector(selector) {
    return this.documentElement.querySelector(selector);
  }

  querySelectorAll(selector) {
    return this.documentElement.querySelectorAll(selector);
  }
}

function parseHtml(html) {
  const root = new TestNode("document");
  const stack = [root];
  const tokenPattern = /<!--[\s\S]*?-->|<!doctype[\s\S]*?>|<\/?[^>]+>|[^<]+/gi;
  let match;
  while ((match = tokenPattern.exec(html))) {
    const token = match[0];
    if (token.startsWith("<!--") || /^<!doctype/i.test(token)) continue;
    if (token.startsWith("</")) {
      if (stack.length > 1) stack.pop();
      continue;
    }
    if (token.startsWith("<")) {
      const parsed = parseTag(token);
      if (!parsed) continue;
      const node = new TestNode(parsed.tagName, parsed.attrs);
      stack[stack.length - 1].appendChild(node);
      if (!parsed.selfClosing && !VOID_TAGS.has(parsed.tagName)) {
        stack.push(node);
      }
      continue;
    }
    stack[stack.length - 1].ownText += token;
  }
  return new TestDocument(root);
}

const VOID_TAGS = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);

function parseTag(token) {
  const match = /^<\s*([a-zA-Z0-9-]+)([\s\S]*?)(\/?)>$/.exec(token);
  if (!match) return null;
  const attrs = {};
  const attrPattern = /([:@\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  let attrMatch;
  while ((attrMatch = attrPattern.exec(match[2]))) {
    attrs[attrMatch[1]] = attrMatch[2] ?? attrMatch[3] ?? attrMatch[4] ?? "";
  }
  return {
    tagName: match[1].toLowerCase(),
    attrs,
    selfClosing: Boolean(match[3]),
  };
}

function querySelectorAll(root, selector) {
  const selectors = splitSelectorList(selector);
  const descendants = allDescendants(root);
  const matches = [];
  for (const element of descendants) {
    if (selectors.some((part) => matchesComplexSelector(element, part))) {
      matches.push(element);
    }
  }
  return matches;
}

function allDescendants(root) {
  const output = [];
  for (const child of root.children || []) {
    output.push(child, ...allDescendants(child));
  }
  return output;
}

function splitSelectorList(selector) {
  return selector.split(",").map((part) => part.trim()).filter(Boolean);
}

function matchesSelectorList(element, selector) {
  return splitSelectorList(selector).some((part) => matchesComplexSelector(element, part));
}

function matchesComplexSelector(element, selector) {
  const parts = selector.split(/\s+/).filter(Boolean);
  if (!parts.length || !matchesSimpleSelector(element, parts[parts.length - 1])) {
    return false;
  }
  let ancestor = element.parentElement;
  for (let index = parts.length - 2; index >= 0; index -= 1) {
    while (ancestor && !matchesSimpleSelector(ancestor, parts[index])) {
      ancestor = ancestor.parentElement;
    }
    if (!ancestor) return false;
    ancestor = ancestor.parentElement;
  }
  return true;
}

function matchesSimpleSelector(element, selector) {
  if (!selector || selector === "*") return true;
  let remaining = selector;
  const tag = /^[a-zA-Z][a-zA-Z0-9-]*/.exec(remaining)?.[0];
  if (tag) {
    if (element.localName !== tag.toLowerCase()) return false;
    remaining = remaining.slice(tag.length);
  }

  const classMatches = remaining.match(/\.[\w-]+/g) || [];
  for (const classSelector of classMatches) {
    const className = classSelector.slice(1);
    const classes = (element.getAttribute("class") || "").split(/\s+/);
    if (!classes.includes(className)) return false;
  }
  remaining = remaining.replace(/\.[\w-]+/g, "");

  const attrPattern = /\[([^\]=*~^$|]+)([*^$|~]?=)?(?:"([^"]*)"|'([^']*)'|([^\]]+))?\]/g;
  let match;
  while ((match = attrPattern.exec(remaining))) {
    const attr = match[1].trim();
    const operator = match[2];
    const expected = (match[3] ?? match[4] ?? match[5] ?? "").trim();
    const actual = element.getAttribute(attr);
    if (actual === null) return false;
    if (!operator) continue;
    if (operator === "=" && actual !== expected) return false;
    if (operator === "*=" && !actual.includes(expected)) return false;
    if (operator === "^=" && !actual.startsWith(expected)) return false;
    if (operator === "$=" && !actual.endsWith(expected)) return false;
  }

  return true;
}

function parseStyle(value) {
  return Object.fromEntries(
    value
      .split(";")
      .map((part) => part.split(":").map((item) => item.trim()))
      .filter(([key, val]) => key && val)
  );
}

function rect(left, top, width, height) {
  return {
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height,
  };
}

function cleanText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function assert(condition, fixture, message) {
  if (!condition) {
    throw new Error(`${fixture}: ${message}`);
  }
}

function assertEqual(actual, expected, fixture, field) {
  if (actual !== expected) {
    throw new Error(`${fixture}: expected ${field} ${expected}, got ${actual}`);
  }
}

main();
