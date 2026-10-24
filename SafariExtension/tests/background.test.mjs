import assert from "node:assert/strict";
import { afterAll, beforeAll, beforeEach, test } from "vitest";

function eventHook() {
  const listeners = [];
  return {
    addListener(listener) {
      listeners.push(listener);
    },
    emit(...values) {
      for (const listener of listeners) listener(...values);
    }
  };
}

function makePort() {
  const messages = [];
  const onMessage = eventHook();
  const onDisconnect = eventHook();
  return {
    messages,
    onMessage,
    onDisconnect,
    postMessage(message) {
      messages.push(message);
    }
  };
}

function defaultTab(tabID = 42) {
  return {
    id: tabID,
    active: true,
    windowId: 7,
    url: "https://example.com/build/1",
    title: "Build 1"
  };
}

function defaultWindow() {
  return {
    id: 7,
    left: 20,
    top: 30,
    width: 900,
    height: 700,
    tabs: [defaultTab()]
  };
}

function makeResolvedSelection() {
  return {
    matched: true,
    title: "Build 1",
    region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
    evidence: {
      hookID: "preview",
      url: "https://example.com/build/1",
      title: "Build 1",
      text: "running",
      aria: [],
      availability: "sufficient",
      fingerprint: "fingerprint"
    }
  };
}

function makeFixture() {
  const ports = [];
  const tabMessages = [];
  const tabUpdates = [];
  const windowUpdates = [];
  const timers = [];
  const runtimeMessages = eventHook();
  const behavior = {};
  const hooks = {
    startup: eventHook(),
    installed: eventHook(),
    tabRemoved: eventHook(),
    tabUpdated: eventHook()
  };

  const fixture = {
    ports,
    tabMessages,
    tabUpdates,
    windowUpdates,
    timers,
    runtimeMessages,
    behavior,
    hooks,
    get port() {
      return ports.at(-1);
    },
    resetObservations() {
      if (fixture.port) fixture.port.messages.length = 0;
      tabMessages.length = 0;
      tabUpdates.length = 0;
      windowUpdates.length = 0;
      timers.splice(0, timers.length);
      behavior.getTab = async (tabID) => defaultTab(tabID);
      behavior.queryTabs = async () => [];
      behavior.sendTabMessage = async (_tabID, message) => (
        message.type === "awaitcue.resolveSelection" ? makeResolvedSelection() : {}
      );
      behavior.getWindows = async () => [defaultWindow()];
      behavior.updateTab = async () => {};
      behavior.updateWindow = async () => {};
    },
    schedule(callback, delay) {
      const timer = { callback, delay, cancelled: false };
      timers.push(timer);
      return timer;
    },
    cancel(timer) {
      timer.cancelled = true;
    },
    async runNextTimer() {
      const timer = timers.shift();
      assert.ok(timer, "expected a scheduled timer");
      if (!timer.cancelled) timer.callback();
      await flushAsyncWork();
      return timer;
    }
  };

  fixture.browser = {
    runtime: {
      onStartup: hooks.startup,
      onInstalled: hooks.installed,
      onMessage: runtimeMessages,
      connectNative() {
        const port = makePort();
        ports.push(port);
        return port;
      }
    },
    storage: {
      local: {
        async get() {
          return { awaitcueInstallationID: "installation-1" };
        },
        async set() {}
      }
    },
    tabs: {
      onRemoved: hooks.tabRemoved,
      onUpdated: hooks.tabUpdated,
      async get(tabID) {
        return behavior.getTab(tabID);
      },
      async query(query) {
        return behavior.queryTabs(query);
      },
      async sendMessage(tabID, message) {
        tabMessages.push({ tabID, message });
        return behavior.sendTabMessage(tabID, message);
      },
      async update(tabID, update) {
        tabUpdates.push({ tabID, update });
        return behavior.updateTab(tabID, update);
      }
    },
    windows: {
      async getAll(options) {
        return behavior.getWindows(options);
      },
      async update(windowID, update) {
        windowUpdates.push({ windowID, update });
        return behavior.updateWindow(windowID, update);
      }
    }
  };
  fixture.resetObservations();
  return fixture;
}

async function flushAsyncWork() {
  await Promise.resolve();
  await new Promise((resolve) => setImmediate(resolve));
}

function bindCommand(overrides = {}) {
  return {
    type: "bindTarget",
    requestID: "bind-1",
    extensionInstallationID: "installation-1",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com/build/1",
    region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
    ...overrides
  };
}

function selectionCommand(overrides = {}) {
  return {
    type: "resolveSelection",
    requestID: "selection-1",
    windowFrame: { x: 20, y: 30, width: 900, height: 700 },
    selectionRect: { x: 120, y: 150, width: 300, height: 200 },
    ...overrides
  };
}

let fixture;
let previousBrowser;
let previousSetTimeout;
let previousClearTimeout;

beforeAll(async () => {
  fixture = makeFixture();
  previousBrowser = globalThis.browser;
  previousSetTimeout = globalThis.setTimeout;
  previousClearTimeout = globalThis.clearTimeout;
  globalThis.browser = fixture.browser;
  globalThis.setTimeout = (callback, delay) => fixture.schedule(callback, delay);
  globalThis.clearTimeout = (timer) => fixture.cancel(timer);
  await import("../Resources/background.js");
  await flushAsyncWork();
});

beforeEach(() => {
  fixture.resetObservations();
});

afterAll(() => {
  globalThis.browser = previousBrowser;
  globalThis.setTimeout = previousSetTimeout;
  globalThis.clearTimeout = previousClearTimeout;
});

test("relay 不可用时停止 DOM 观察并在同一 native port 上重发 ready", async () => {
  fixture.port.onMessage.emit(bindCommand());
  await flushAsyncWork();
  assert.equal(fixture.port.messages.some((message) => message.type === "targetBound"), true);

  fixture.port.onMessage.emit({ accepted: false, error: "relay_unavailable" });
  await flushAsyncWork();
  assert.equal(
    fixture.tabMessages.some(({ message }) => message.type === "awaitcue.unbind"),
    true
  );
  assert.equal(fixture.timers.length, 1);

  // 同一失败回复在 timer 未触发前不能堆积更多重试；App 恢复后必须取消旧 timer。
  fixture.port.onMessage.emit({ accepted: false, error: "relay_unavailable" });
  await flushAsyncWork();
  assert.equal(fixture.timers.length, 1);
  fixture.port.onMessage.emit({ accepted: true });
  assert.equal(fixture.timers[0].cancelled, true);

  fixture.port.onMessage.emit({ accepted: false, error: "relay_unavailable" });
  await flushAsyncWork();
  assert.equal(fixture.timers.length, 2);
  await fixture.runNextTimer();

  const retry = await fixture.runNextTimer();
  assert.equal(retry.delay, 250);
  assert.equal(fixture.port.messages.filter((message) => message.type === "ready").length, 1);

  fixture.port.onMessage.emit({ accepted: true });
  fixture.port.onMessage.emit({ accepted: false, error: "invalid_message" });
  fixture.port.onMessage.emit({ accepted: false });
  fixture.port.onMessage.emit({ type: "unknown" });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.filter((message) => message.type === "error").length, 0);
});

test("containing app 退出前可以主动停止全部 Safari DOM 观察", async () => {
  fixture.port.onMessage.emit(bindCommand({ hookID: "quit-hook" }));
  await flushAsyncWork();
  fixture.resetObservations();

  fixture.port.onMessage.emit({ type: "stopAllBindings" });
  await flushAsyncWork();

  assert.equal(
    fixture.tabMessages.some(({ message }) => (
      message.type === "awaitcue.unbind" && message.hookID === "quit-hook"
    )),
    true
  );
});

test("bindTarget 拒绝关闭的 tab 和被不同 URL 复用的 tab ID", async () => {
  fixture.port.onMessage.emit(bindCommand({
    requestID: "bind-other-installation",
    extensionInstallationID: "other-installation"
  }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.length, 0);

  fixture.behavior.getTab = async () => {
    throw new Error("missing");
  };
  fixture.port.onMessage.emit(bindCommand());
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "tab_closed");
  assert.equal(fixture.port.messages.at(-1).requestID, "bind-1");

  fixture.behavior.getTab = async () => ({
    id: 42,
    windowId: 7,
    url: "https://example.com.evil.test/build/1"
  });
  fixture.port.onMessage.emit(bindCommand({ requestID: "bind-2" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "tab_identity_mismatch");
  assert.equal(fixture.port.messages.at(-1).requestID, "bind-2");

  fixture.behavior.getTab = async (tabID) => defaultTab(tabID);
  fixture.behavior.sendTabMessage = async () => {
    throw new Error("content unavailable");
  };
  fixture.port.onMessage.emit(bindCommand({ requestID: "bind-3" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "content_bind_failed");

  fixture.behavior.sendTabMessage = async () => ({ evidence: makeResolvedSelection().evidence });
  fixture.port.onMessage.emit(bindCommand({ requestID: "bind-with-evidence" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).type, "evidenceChanged");
});

test("resolveSelection 只读取与原生 windowFrame 唯一匹配窗口的 active tab", async () => {
  fixture.port.onMessage.emit(selectionCommand());
  await flushAsyncWork();
  assert.equal(fixture.tabMessages.at(-1).tabID, 42);
  assert.equal(fixture.port.messages.at(-1).target.tabID, 42);

  fixture.behavior.getWindows = async () => [
    { ...defaultWindow(), tabs: [] },
    { ...defaultWindow(), id: 8, tabs: [] }
  ];
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-ambiguous" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "window_not_matched");

  fixture.behavior.getWindows = async () => [{ id: 9, left: 20, top: 30, width: undefined, height: 700 }];
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-invalid-window" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "window_not_matched");

  fixture.behavior.getWindows = async () => [{
    id: 7,
    left: 20,
    top: 30,
    width: 900,
    height: 700
  }];
  fixture.behavior.queryTabs = async () => [];
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-no-tab" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "active_tab_unavailable");

  fixture.behavior.getWindows = async () => [{
    ...defaultWindow(),
    tabs: [defaultTab(), { ...defaultTab(43), active: true }]
  }];
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-multiple-tabs" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "active_tab_unavailable");

  fixture.behavior.getWindows = async () => [{ ...defaultWindow(), tabs: [] }];
  fixture.behavior.queryTabs = async () => [{ ...defaultTab(), url: "safari://settings" }];
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-internal" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "active_tab_unavailable");

  fixture.behavior.queryTabs = async () => [defaultTab()];
  fixture.behavior.sendTabMessage = async () => ({ matched: false, reason: "selection_outside_viewport" });
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-outside" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "selection_outside_viewport");

  fixture.behavior.sendTabMessage = async () => undefined;
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-empty-response" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "selection_outside_viewport");

  fixture.behavior.sendTabMessage = async () => {
    throw new Error("permission denied");
  };
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-no-access" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "page_access_unavailable");

  fixture.behavior.getWindows = async () => {
    throw new Error("Safari API unavailable");
  };
  fixture.port.onMessage.emit(selectionCommand({ requestID: "selection-api-error" }));
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "page_access_unavailable");
});

test("focusTarget 与 unbindTarget 只有执行完成后才发送关联 ACK", async () => {
  fixture.port.onMessage.emit({
    type: "focusTarget",
    requestID: "focus-other-installation",
    extensionInstallationID: "other-installation",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com/build/1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.length, 0);

  fixture.behavior.queryTabs = async () => [{}, { id: 42 }];
  fixture.port.onMessage.emit({
    type: "focusTarget",
    requestID: "focus-1",
    extensionInstallationID: "installation-1",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com/build/1"
  });
  await flushAsyncWork();
  assert.equal(fixture.tabUpdates.length, 1);
  assert.equal(fixture.windowUpdates.length, 1);
  assert.equal(fixture.port.messages.at(-1).type, "targetFocused");
  assert.equal(fixture.port.messages.at(-1).requestID, "focus-1");

  fixture.port.onMessage.emit({
    type: "unbindTarget",
    requestID: "unbind-1",
    extensionInstallationID: "installation-1",
    hookID: "hook-1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).type, "targetUnbound");
  assert.equal(fixture.port.messages.at(-1).requestID, "unbind-1");

  fixture.port.onMessage.emit({
    type: "unbindTarget",
    requestID: "unbind-other-installation",
    extensionInstallationID: "other-installation",
    hookID: "hook-1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).requestID, "unbind-1");

  fixture.behavior.getTab = async () => {
    throw new Error("missing");
  };
  fixture.port.onMessage.emit({
    type: "focusTarget",
    requestID: "focus-closed",
    extensionInstallationID: "installation-1",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com/build/1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "tab_closed");

  fixture.behavior.getTab = async () => ({ ...defaultTab(), url: "https://example.net/" });
  fixture.port.onMessage.emit({
    type: "focusTarget",
    requestID: "focus-mismatch",
    extensionInstallationID: "installation-1",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com/build/1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "tab_identity_mismatch");

  fixture.behavior.getTab = async (tabID) => defaultTab(tabID);
  fixture.behavior.updateTab = async () => {
    throw new Error("focus denied");
  };
  fixture.port.onMessage.emit({
    type: "focusTarget",
    requestID: "focus-error",
    extensionInstallationID: "installation-1",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com/build/1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).reason, "tab_unavailable");

  fixture.behavior.queryTabs = async () => {
    throw new Error("query denied");
  };
  fixture.port.onMessage.emit({
    type: "unbindTarget",
    requestID: "unbind-error",
    extensionInstallationID: "installation-1",
    hookID: "hook-1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).code, "unbind_failed");
});

test("运行时事件覆盖证据、活动 host、导航和 tab 关闭", async () => {
  fixture.hooks.startup.emit();
  fixture.hooks.installed.emit();
  fixture.runtimeMessages.emit({
    type: "awaitcue.evidence",
    evidence: makeResolvedSelection().evidence
  });
  fixture.runtimeMessages.emit({ type: "not-an-awaitcue-message" });
  fixture.runtimeMessages.emit({
    type: "ping",
    requestID: "wrong-installation-ping",
    extensionInstallationID: "other-installation"
  });
  fixture.runtimeMessages.emit({
    type: "awaitcue.evidence",
    evidence: { ...makeResolvedSelection().evidence, screenshot: "forbidden" }
  });
  fixture.runtimeMessages.emit({
    type: "ping",
    requestID: "runtime-ping",
    extensionInstallationID: "installation-1"
  });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.filter((message) => message.type === "evidenceChanged").length, 1);
  assert.equal(fixture.port.messages.some((message) => message.requestID === "runtime-ping"), true);

  fixture.behavior.queryTabs = async () => [defaultTab()];
  fixture.port.onMessage.emit({ type: "resolveActiveHost", requestID: "active-1" });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).matched, true);

  fixture.behavior.queryTabs = async () => [];
  fixture.port.onMessage.emit({ type: "resolveActiveHost", requestID: "active-empty" });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).matched, false);

  fixture.behavior.queryTabs = async () => {
    throw new Error("query failed");
  };
  fixture.port.onMessage.emit({ type: "resolveActiveHost", requestID: "active-error" });
  await flushAsyncWork();
  assert.equal(fixture.port.messages.at(-1).matched, false);

  fixture.behavior.queryTabs = async () => [];
  fixture.port.onMessage.emit(bindCommand({ hookID: "navigate-hook" }));
  await flushAsyncWork();
  fixture.hooks.tabUpdated.emit(42, {});
  fixture.hooks.tabRemoved.emit(99);
  fixture.hooks.tabUpdated.emit(42, { url: "https://example.com/build/1" });
  fixture.hooks.tabUpdated.emit(42, { url: "https://example.com/build/2" });
  assert.equal(fixture.port.messages.at(-1).reason, "tab_navigated");

  fixture.port.onMessage.emit(bindCommand({ hookID: "close-hook" }));
  await flushAsyncWork();
  fixture.hooks.tabRemoved.emit(42);
  assert.equal(fixture.port.messages.at(-1).reason, "tab_closed");
});

test("native port 断开时停止观察并通过新 port 恢复 ready", async () => {
  fixture.port.onMessage.emit(bindCommand({ hookID: "disconnect-hook" }));
  await flushAsyncWork();
  const disconnectedPort = fixture.port;
  disconnectedPort.onDisconnect.emit();
  await flushAsyncWork();
  assert.equal(
    fixture.tabMessages.some(({ message }) => message.type === "awaitcue.unbind"),
    true
  );
  const reconnect = await fixture.runNextTimer();
  assert.equal(reconnect.delay, 500);
  assert.notEqual(fixture.port, disconnectedPort);
  assert.equal(fixture.port.messages.at(-1).type, "ready");

  // 旧 port 的迟到事件不能污染重连后的 installation。
  disconnectedPort.onMessage.emit({
    type: "ping",
    requestID: "stale-ping",
    extensionInstallationID: "installation-1"
  });
  disconnectedPort.onDisconnect.emit();
  await flushAsyncWork();
  assert.equal(disconnectedPort.messages.some((message) => message.requestID === "stale-ping"), false);
});
