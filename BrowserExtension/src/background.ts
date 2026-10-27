import { tabIdentityMatches, uniqueFocusedActiveHost, uniqueMatchingWindow } from "./browserSelection";
import {
  chromiumProtocolVersion,
  nativeHostName,
  isNormalizedRegion,
  parseNativeCommand,
  type Evidence,
  type ExtensionEvent,
  type NativeCommand,
  type NormalizedRegion,
  type SelectionFailureReason
} from "./protocol";

let nativePort: chrome.runtime.Port | null = null;
type HookBinding = Readonly<{
  tabID: number;
  expectedHost: string;
  expectedURL: string;
  region: NormalizedRegion;
  selectionRegionExpanded?: boolean;
}>;
const hookBindings = new Map<string, HookBinding>();
let recentlyFocusedTab: Readonly<{
  tab: chrome.tabs.Tab;
  windowFrame: Readonly<{ x: number; y: number; width: number; height: number }>;
  observedAt: number;
}> | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelayMilliseconds = 1_000;
let disconnectCleanup: Promise<void> | null = null;
let connectRequestedDuringCleanup = false;
const installationIdentityPromise = installationIdentity();
const extensionVersion = chrome.runtime.getManifest().version;

chrome.runtime.onInstalled.addListener(() => connectNative());
chrome.runtime.onStartup.addListener(() => connectNative());
chrome.action.onClicked.addListener(() => {
  connectNative();
  void postReady();
});

chrome.runtime.onMessage.addListener((message: unknown, sender) => {
  if (!isRecord(message)) return;
  if (
    message.type === "awaitcue.focusedTab" &&
    sender.tab &&
    typeof sender.tab.id === "number" &&
    typeof sender.tab.windowId === "number" &&
    isRecord(message.windowFrame) &&
    isScreenFrame(message.windowFrame)
  ) {
    recentlyFocusedTab = {
      tab: sender.tab,
      windowFrame: message.windowFrame,
      observedAt: Date.now()
    };
    // 用户回到页面并开始框选时不能继续等待最长 30 秒退避；焦点事件是明确的即时连接意图。
    if (!nativePort) connectNative();
    return;
  }
  if (!nativePort) return;
  if (message.type === "awaitcue.evidence") {
    const evidence = normalizeEvidence(message.evidence);
    if (!evidence) return;
    postDOMEvidence(evidence);
  }
});

chrome.tabs.onRemoved.addListener((tabID) => {
  if (recentlyFocusedTab?.tab.id === tabID) recentlyFocusedTab = null;
  for (const [hookID, binding] of hookBindings) {
    if (binding.tabID !== tabID) continue;
    void markTargetUnavailable(hookID, "tab_closed");
  }
});

chrome.tabs.onReplaced.addListener((_addedTabID, removedTabID) => {
  for (const [hookID, binding] of hookBindings) {
    if (binding.tabID === removedTabID) void markTargetUnavailable(hookID, "tab_replaced");
  }
});

chrome.tabs.onUpdated.addListener((tabID, changeInfo, tab) => {
  for (const [hookID, binding] of hookBindings) {
    if (binding.tabID !== tabID) continue;
    if (changeInfo.url && !tabIdentityMatches(changeInfo.url, binding.expectedURL, binding.expectedHost)) {
      void markTargetUnavailable(hookID, "tab_navigated");
      continue;
    }
    if (changeInfo.status === "complete") {
      if (!tab.url || !tabIdentityMatches(tab.url, binding.expectedURL, binding.expectedHost)) {
        void markTargetUnavailable(hookID, "tab_navigated");
      } else {
        void installContentBinding(hookID, binding)
          .then((evidence) => postDOMEvidence(evidence))
          .catch(() => markTargetUnavailable(hookID, "content_rebind_failed"));
      }
    }
  }
});

// Manifest V3 worker 可能在浏览器仍运行时被回收并重新创建；这种冷启动不会再次触发 onStartup。
// 每次脚本求值都主动连接，connectNative 自身会阻止同一个 worker 内重复创建 native port。
connectNative();

function connectNative(): void {
  if (nativePort) return;
  if (disconnectCleanup !== null) {
    // onStartup/onInstalled/action 可能在旧 observer 清理期间到达；只登记一次后续连接意图。
    connectRequestedDuringCleanup = true;
    return;
  }
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  const port = chrome.runtime.connectNative(nativeHostName);
  nativePort = port;
  let receivedNativeMessage = false;
  port.onMessage.addListener((message: unknown) => {
    // 断线重连后旧 port 仍可能排队投递消息，不能让它借新 port 回包并污染新连接状态。
    if (nativePort !== port) return;
    if (!receivedNativeMessage) {
      // `connectNative` 成功返回并不代表 native host 可用；只有收到首条回包才结束本轮退避。
      receivedNativeMessage = true;
      reconnectDelayMilliseconds = 1_000;
    }
    void handleNativeCommand(message);
  });
  port.onDisconnect.addListener(() => {
    void handleNativeDisconnect(port);
  });
  void postReady();
}

/** 旧页面 observer 全部停止后才能建立新 port，避免迟到 unbind 与恢复绑定交错。 */
async function handleNativeDisconnect(port: chrome.runtime.Port): Promise<void> {
  if (nativePort !== port) return;
  nativePort = null;
  const cleanup = clearAllBindings();
  disconnectCleanup = cleanup;
  await cleanup;
  if (disconnectCleanup !== cleanup) return;
  disconnectCleanup = null;
  if (connectRequestedDuringCleanup) {
    connectRequestedDuringCleanup = false;
    connectNative();
  } else if (nativePort === null) {
    scheduleReconnect();
  }
}

async function handleNativeCommand(value: unknown): Promise<void> {
  const command = parseNativeCommand(value);
  if (!command) {
    postEvent({ type: "error", code: "invalid_command", message: "Invalid native command" });
    return;
  }
  try {
    if (
      (command.type === "bindTarget" || command.type === "unbindTarget" || command.type === "focusTarget" || command.type === "validateTarget") &&
      command.extensionInstallationID !== (await installationIdentityPromise)
    ) {
      return;
    }
    if (command.type === "ping") {
      // 广播会抵达所有浏览器 profile；只有 ready 对应的 installation 才能完成这次双向检查。
      if (command.extensionInstallationID !== (await installationIdentityPromise)) return;
      postEvent({
        type: "pong",
        requestID: command.requestID,
        protocolVersion: chromiumProtocolVersion,
        extensionVersion,
        extensionInstallationID: command.extensionInstallationID
      });
    } else if (command.type === "resolveActiveHost") {
      await resolveActiveHost(command.requestID);
    } else if (command.type === "resolveSelection") {
      await resolveSelection(command);
    } else if (command.type === "unbindTarget") {
      await unbind(command);
    } else if (command.type === "focusTarget") {
      await focusTarget(command);
    } else if (command.type === "validateTarget") {
      await validateTarget(command);
    } else {
      await bind(command);
    }
  } catch (error) {
    if (command.type === "resolveSelection") {
      postSelectionFailure(command.requestID, "page_access_unavailable");
      return;
    }
    if (command.type === "bindTarget") {
      await markTargetUnavailable(command.hookID, "content_bind_failed", command.requestID);
      return;
    }
    if (command.type === "focusTarget") {
      await markTargetUnavailable(command.hookID, "focus_failed", command.requestID);
      return;
    }
    if (command.type === "validateTarget") {
      await markTargetUnavailable(command.hookID, "validation_failed", command.requestID);
      return;
    }
    const event: ExtensionEvent = {
      type: "error",
      code: "command_failed",
      message: error instanceof Error ? error.message : String(error)
    };
    postEvent("hookID" in command ? { ...event, hookID: command.hookID } : event);
  }
}

async function resolveActiveHost(requestID: string): Promise<void> {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const focusedWindow: chrome.windows.Window | null = typeof tab?.windowId === "number"
    ? await chrome.windows.get(tab.windowId)
    : null;
  const context = uniqueFocusedActiveHost([{
    ...(focusedWindow ?? {}),
    focused: true,
    tabs: tab ? [tab] : []
  }]);
  if (!context) {
    postEvent({
      type: "activeHostResolved",
      requestID,
      matched: false,
      extensionInstallationID: await installationIdentityPromise
    });
    return;
  }
  postEvent({
    type: "activeHostResolved",
    requestID,
    matched: true,
    extensionInstallationID: await installationIdentityPromise,
    host: context.host,
    tabID: context.tabID,
    browserWindowID: context.browserWindowID
  });
}

async function resolveSelection(command: Extract<NativeCommand, { type: "resolveSelection" }>): Promise<void> {
  const cachedMatch = recentlyFocusedTab
    && Date.now() - recentlyFocusedTab.observedAt <= 30_000
    ? uniqueMatchingWindow(command.windowFrame, [{
        ...recentlyFocusedTab.windowFrame,
        tab: recentlyFocusedTab.tab
      }])
    : null;
  let tab = cachedMatch?.tab;
  let focusedWindow: chrome.windows.Window | null = null;
  if (!tab) {
    [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    focusedWindow = typeof tab?.windowId === "number"
      ? await chrome.windows.get(tab.windowId)
      : null;
  }
  const matchingWindow = cachedMatch ?? uniqueMatchingWindow(
    command.windowFrame,
    [focusedWindow].flatMap((candidate) => {
      if (
        candidate === null ||
        typeof candidate.left !== "number" ||
        typeof candidate.top !== "number" ||
        typeof candidate.width !== "number" ||
        typeof candidate.height !== "number"
      ) {
        return [];
      }
      return [{
        x: candidate.left,
        y: candidate.top,
        width: candidate.width,
        height: candidate.height
      }];
    })
  );
  if (!matchingWindow) {
    postSelectionFailure(command.requestID, "window_not_matched");
    return;
  }
  if (typeof tab?.id !== "number" || typeof tab.url !== "string") {
    postSelectionFailure(command.requestID, "active_tab_unavailable");
    return;
  }
  const tabURL = tab.url;
  let url: URL;
  try {
    url = new URL(tabURL);
  } catch {
    postSelectionFailure(command.requestID, "active_tab_unavailable");
    return;
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || !url.host) {
    postSelectionFailure(command.requestID, "active_tab_unavailable");
    return;
  }

  if (!cachedMatch) {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  }
  const rawResponse: unknown = await chrome.tabs.sendMessage(tab.id, {
    type: "awaitcue.resolveSelection",
    requestID: command.requestID,
    selectionRect: command.selectionRect
  });
  const response = normalizeResolvedSelectionResponse(rawResponse);
  if (!response) {
    postSelectionFailure(command.requestID, "invalid_page_response");
    return;
  }
  if (!response.matched || !response.region) {
    postSelectionFailure(command.requestID, "selection_outside_viewport");
    return;
  }
  postEvent({
    type: "selectionResolved",
    requestID: command.requestID,
    matched: true,
    target: {
      extensionInstallationID: await installationIdentityPromise,
      tabID: tab.id,
      host: url.host,
      url: tabURL,
      title: response.title || tab.title || url.host,
      region: response.region,
      ...(typeof response.selectionRegionExpanded === "boolean"
        ? { selectionRegionExpanded: response.selectionRegionExpanded }
        : {}),
      ...(response.evidence ? { evidence: response.evidence } : {})
    }
  });
}

function isScreenFrame(value: Record<string, unknown>): value is {
  x: number;
  y: number;
  width: number;
  height: number;
} {
  return [value.x, value.y, value.width, value.height].every(
    (entry) => typeof entry === "number" && Number.isFinite(entry)
  ) && (value.width as number) > 0 && (value.height as number) > 0;
}

function postSelectionFailure(requestID: string, reason: SelectionFailureReason): void {
  postEvent({ type: "selectionResolved", requestID, matched: false, reason });
}

async function postReady(): Promise<void> {
  nativePort?.postMessage({
    type: "ready",
    browser: navigator.userAgent,
    protocolVersion: chromiumProtocolVersion,
    extensionVersion,
    extensionInstallationID: await installationIdentityPromise
  } satisfies ExtensionEvent);
}

function scheduleReconnect(): void {
  if (reconnectTimer !== null) return;
  reconnectTimer = globalThis.setTimeout(() => {
    reconnectTimer = null;
    connectNative();
  }, reconnectDelayMilliseconds);
  reconnectDelayMilliseconds = Math.min(reconnectDelayMilliseconds * 2, 30_000);
}

async function installationIdentity(): Promise<string> {
  const stored = await chrome.storage.local.get("awaitcueInstallationID");
  if (typeof stored.awaitcueInstallationID === "string") return stored.awaitcueInstallationID;
  const identity = `${chrome.runtime.id}:${crypto.randomUUID()}`;
  await chrome.storage.local.set({ awaitcueInstallationID: identity });
  return identity;
}

async function bind(command: Extract<NativeCommand, { type: "bindTarget" }>): Promise<void> {
  let tab: chrome.tabs.Tab;
  try {
    tab = await chrome.tabs.get(command.tabID);
  } catch {
    // 重新启动浏览器后持久化 tab ID 不会自动指向同 URL 的新 tab；必须把原 Target 标成不可用。
    await markTargetUnavailable(command.hookID, "tab_closed", command.requestID);
    return;
  }
  if (!tab.url) throw new Error("Target tab has no URL");
  if (!tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)) {
    await markTargetUnavailable(command.hookID, "tab_identity_mismatch", command.requestID);
    return;
  }
  const binding: HookBinding = {
    tabID: command.tabID,
    expectedHost: command.expectedHost,
    expectedURL: command.expectedURL,
    region: command.region,
    ...(typeof command.selectionRegionExpanded === "boolean"
      ? { selectionRegionExpanded: command.selectionRegionExpanded }
      : {})
  };
  const initialEvidence = await installContentBinding(command.hookID, binding);
  hookBindings.set(command.hookID, binding);

  postEvent({
    type: "targetBound",
    requestID: command.requestID,
    extensionInstallationID: await installationIdentityPromise,
    hookID: command.hookID,
    tabID: command.tabID
  });
  if (initialEvidence) {
    postDOMEvidence(initialEvidence);
  }
}

async function focusTarget(command: Extract<NativeCommand, { type: "focusTarget" }>): Promise<void> {
  let tab: chrome.tabs.Tab;
  try {
    tab = await chrome.tabs.get(command.tabID);
  } catch {
    await markTargetUnavailable(command.hookID, "tab_closed", command.requestID);
    return;
  }
  if (!tab.url || !tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)) {
    await markTargetUnavailable(command.hookID, "tab_identity_mismatch", command.requestID);
    return;
  }
  await chrome.tabs.update(command.tabID, { active: true });
  if (typeof tab.windowId === "number") {
    await chrome.windows.update(tab.windowId, { focused: true });
  }
  postEvent({
    type: "targetFocused",
    requestID: command.requestID,
    extensionInstallationID: await installationIdentityPromise,
    hookID: command.hookID,
    tabID: command.tabID
  });
}

/** 只验证持久化 tab 身份，不激活窗口，也不安装页面 observer。 */
async function validateTarget(
  command: Extract<NativeCommand, { type: "validateTarget" }>
): Promise<void> {
  let tab: chrome.tabs.Tab;
  try {
    tab = await chrome.tabs.get(command.tabID);
  } catch {
    await markTargetUnavailable(command.hookID, "tab_closed", command.requestID);
    return;
  }
  if (!tab.url || !tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)) {
    await markTargetUnavailable(command.hookID, "tab_identity_mismatch", command.requestID);
    return;
  }
  postEvent({
    type: "targetValidated",
    requestID: command.requestID,
    extensionInstallationID: await installationIdentityPromise,
    hookID: command.hookID,
    tabID: command.tabID
  });
}

async function unbind(command: Extract<NativeCommand, { type: "unbindTarget" }>): Promise<void> {
  const binding = hookBindings.get(command.hookID);
  if (binding) {
    try {
      await chrome.tabs.sendMessage(binding.tabID, {
        type: "awaitcue.unbind",
        hookID: command.hookID
      });
    } catch {
      // 标签页可能在解绑前已经关闭；清理本地状态仍然必须完成。
    }
  }
  hookBindings.delete(command.hookID);
  postEvent({
    type: "targetUnbound",
    requestID: command.requestID,
    extensionInstallationID: await installationIdentityPromise,
    hookID: command.hookID
  });
}

/** Native app 离线时停止 DOM observer；重连后由 app 从持久化 Hook 重新绑定。 */
async function clearAllBindings(): Promise<void> {
  const bindings = [...hookBindings.entries()];
  hookBindings.clear();
  await Promise.allSettled(
    bindings.map(([hookID, binding]) =>
      chrome.tabs.sendMessage(binding.tabID, { type: "awaitcue.unbind", hookID })
    )
  );
}

async function installContentBinding(hookID: string, binding: HookBinding): Promise<Evidence | null> {
  await chrome.scripting.executeScript({ target: { tabId: binding.tabID }, files: ["content.js"] });
  const response: unknown = await chrome.tabs.sendMessage(binding.tabID, {
    type: "awaitcue.bind",
    hookID,
    region: binding.region,
    ...(typeof binding.selectionRegionExpanded === "boolean"
      ? { selectionRegionExpanded: binding.selectionRegionExpanded }
      : {})
  });
  return isRecord(response) ? normalizeEvidence(response.evidence) : null;
}

async function markTargetUnavailable(
  hookID: string,
  reason: string,
  requestID?: string
): Promise<void> {
  hookBindings.delete(hookID);
  postEvent({
    type: "targetUnavailable",
    extensionInstallationID: await installationIdentityPromise,
    hookID,
    reason,
    ...(requestID ? { requestID } : {})
  });
}

function postEvent(event: ExtensionEvent): void {
  nativePort?.postMessage(event);
}

function postDOMEvidence(evidence: Evidence | null): void {
  if (!evidence) return;
  void installationIdentityPromise.then((extensionInstallationID) => {
    postEvent({ type: "evidenceChanged", extensionInstallationID, evidence });
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeEvidence(value: unknown): Evidence | null {
  if (
    !isRecord(value) ||
    typeof value.hookID !== "string" ||
    typeof value.url !== "string" ||
    typeof value.title !== "string" ||
    typeof value.text !== "string" ||
    !Array.isArray(value.aria) ||
    !value.aria.every((entry) => typeof entry === "string") ||
    !(value.html === undefined || typeof value.html === "string") ||
    !(value.selectionRegionExpanded === undefined || typeof value.selectionRegionExpanded === "boolean") ||
    typeof value.fingerprint !== "string"
  ) {
    return null;
  }
  // 是否足够只能由实际页面证据决定，不能信任跨进程消息里自报的状态。
  const availability = value.text || value.aria.length > 0 || value.html ? "sufficient" : "insufficient";
  const insufficiencyReason = availability === "insufficient" ? "no_semantic_content" : undefined;
  return {
    hookID: value.hookID,
    url: value.url,
    title: value.title,
    text: value.text,
    aria: value.aria,
    ...(typeof value.html === "string" ? { html: value.html } : {}),
    availability,
    ...(insufficiencyReason ? { insufficiencyReason } : {}),
    ...(typeof value.selectionRegionExpanded === "boolean"
      ? { selectionRegionExpanded: value.selectionRegionExpanded }
      : {}),
    fingerprint: value.fingerprint
  };
}

function normalizeResolvedSelectionResponse(value: unknown): {
  matched: boolean;
  region?: NormalizedRegion;
  selectionRegionExpanded?: boolean;
  title: string;
  evidence?: Evidence;
} | null {
  if (
    !isRecord(value) ||
    typeof value.matched !== "boolean" ||
    typeof value.title !== "string" ||
    !(value.selectionRegionExpanded === undefined || typeof value.selectionRegionExpanded === "boolean") ||
    !(value.region === null || value.region === undefined || isNormalizedRegion(value.region))
  ) {
    return null;
  }
  const evidence = value.evidence === null || value.evidence === undefined
    ? undefined
    : normalizeEvidence(value.evidence);
  if (value.evidence !== null && value.evidence !== undefined && !evidence) return null;
  return {
    matched: value.matched,
    ...(isNormalizedRegion(value.region) ? { region: value.region } : {}),
    ...(typeof value.selectionRegionExpanded === "boolean"
      ? { selectionRegionExpanded: value.selectionRegionExpanded }
      : {}),
    title: value.title,
    ...(evidence ? { evidence } : {})
  };
}
