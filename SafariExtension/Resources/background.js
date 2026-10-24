import {
  makeEvidenceChangedEvent,
  makePongEvent,
  makeReadyEvent,
  parseNativeCommand,
  parseNativeReply,
  tabIdentityMatches,
  uniqueMatchingWindow
} from "./protocol.js";

const nativeApplicationIdentifier = "org.awaitcue.AwaitCue.SafariExtension";
let nativePort = null;
let extensionInstallationID = null;
let reconnectAttempt = 0;
let readyRetryAttempt = 0;
let readyRetryTimer = null;
const bindings = new Map();

void connectNative();
browser.runtime.onStartup.addListener(() => void connectNative());
browser.runtime.onInstalled.addListener(() => void connectNative());
browser.tabs.onRemoved.addListener((tabID) => {
  for (const [hookID, binding] of bindings) {
    if (binding.tabID !== tabID) continue;
    bindings.delete(hookID);
    nativePort?.postMessage({
      type: "targetUnavailable",
      extensionInstallationID,
      hookID,
      reason: "tab_closed"
    });
  }
});
browser.tabs.onUpdated.addListener((tabID, changeInfo) => {
  if (typeof changeInfo.url !== "string") return;
  for (const [hookID, binding] of bindings) {
    if (
      binding.tabID !== tabID
      || tabIdentityMatches(changeInfo.url, binding.expectedURL, binding.expectedHost)
    ) continue;
    bindings.delete(hookID);
    nativePort?.postMessage({
      type: "targetUnavailable",
      extensionInstallationID,
      hookID,
      reason: "tab_navigated"
    });
  }
});
browser.runtime.onMessage.addListener((message) => {
  if (message?.type === "awaitcue.evidence" && nativePort !== null) {
    try {
      nativePort.postMessage(
        makeEvidenceChangedEvent(extensionInstallationID, message.evidence)
      );
    } catch {
      // DOM-only 契约失败时直接丢弃证据；不得删掉图片字段后伪装成一次成功观察。
    }
    return false;
  }
  // containing app 的 dispatchMessage 会进入同一 runtime listener；回复仍经已认证的 native port 返回。
  if (nativePort !== null && parseNativeCommand(message) !== null) {
    void handleNativeCommand(nativePort, message).catch(() => {
      handleCommandFailure(nativePort, message);
    });
  }
  return false;
});

/**
 * Safari 会忽略 nativeApplicationIdentifier 并路由到 containing app 的 native extension。
 * 这里仍传稳定 identifier，便于与 Chromium transport 保持相同调用形状。
 */
async function connectNative() {
  if (nativePort !== null) return;
  extensionInstallationID ??= await loadInstallationID();
  const port = browser.runtime.connectNative(nativeApplicationIdentifier);
  nativePort = port;
  port.onMessage.addListener((message) => void handleNativePortMessage(port, message));
  port.onDisconnect.addListener(() => {
    if (nativePort !== port) return;
    nativePort = null;
    cancelReadyRetry();
    void clearAllBindings();
    reconnectAttempt += 1;
    const delay = Math.min(10_000, 250 * (2 ** Math.min(reconnectAttempt, 5)));
    setTimeout(() => void connectNative(), delay);
  });
  port.postMessage(makeReadyEvent(extensionInstallationID));
}

/** native extension 的接收回复与主应用命令共用 port，必须先按协议分流。 */
async function handleNativePortMessage(port, message) {
  if (nativePort !== port) return;
  const reply = parseNativeReply(message);
  if (reply !== null) {
    if (reply.accepted) {
      reconnectAttempt = 0;
      readyRetryAttempt = 0;
      cancelReadyRetry();
    } else if (reply.error === "relay_unavailable") {
      // 菜单栏 App 已退出时立即停止观察，避免 Safari 在后台继续处理页面变化。
      await clearAllBindings();
      scheduleReadyRetry(port);
    }
    return;
  }
  await handleNativeCommand(port, message).catch(() => {
    handleCommandFailure(port, message);
  });
}

/** App 晚于 Safari 启动或重新打开时，在既有 port 上退避重发 ready。 */
function scheduleReadyRetry(port) {
  if (readyRetryTimer !== null || nativePort !== port) return;
  readyRetryAttempt += 1;
  const delay = Math.min(10_000, 250 * (2 ** Math.min(readyRetryAttempt - 1, 5)));
  readyRetryTimer = setTimeout(() => {
    readyRetryTimer = null;
    if (nativePort === port) port.postMessage(makeReadyEvent(extensionInstallationID));
  }, delay);
}

function cancelReadyRetry() {
  if (readyRetryTimer === null) return;
  clearTimeout(readyRetryTimer);
  readyRetryTimer = null;
}

async function handleNativeCommand(port, rawCommand) {
  // 旧 port 的迟到命令不能借新连接回包，否则多次重连会污染 request 关联。
  if (nativePort !== port) return;
  const command = parseNativeCommand(rawCommand);
  if (command === null) return;
  if (command.type === "stopAllBindings") {
    await clearAllBindings();
    return;
  }
  if (command.type === "ping") {
    if (command.extensionInstallationID === extensionInstallationID) {
      port.postMessage(makePongEvent(command.requestID, extensionInstallationID));
    }
    return;
  }
  if (command.type === "resolveActiveHost") {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    port.postMessage({
      type: "activeHostResolved",
      requestID: command.requestID,
      matched: tab?.id !== undefined && typeof tab.url === "string",
      extensionInstallationID,
      host: tab?.url ? new URL(tab.url).host : undefined,
      tabID: tab?.id,
      browserWindowID: tab?.windowId
    });
    return;
  }
  if (command.type === "resolveSelection") {
    await resolveSelection(port, command);
    return;
  }
  if (command.type === "bindTarget") {
    if (command.extensionInstallationID !== extensionInstallationID) return;
    let tab;
    try {
      tab = await browser.tabs.get(command.tabID);
    } catch {
      postTargetUnavailable(port, command, "tab_closed");
      return;
    }
    if (
      typeof tab.url !== "string"
      || !tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)
    ) {
      postTargetUnavailable(port, command, "tab_identity_mismatch");
      return;
    }
    const response = await browser.tabs.sendMessage(command.tabID, {
      type: "awaitcue.bind",
      hookID: command.hookID,
      region: command.region
    });
    bindings.set(command.hookID, {
      tabID: command.tabID,
      expectedHost: command.expectedHost,
      expectedURL: command.expectedURL
    });
    port.postMessage({
      type: "targetBound",
      requestID: command.requestID,
      extensionInstallationID,
      hookID: command.hookID,
      tabID: command.tabID
    });
    if (response?.evidence) {
      port.postMessage(makeEvidenceChangedEvent(extensionInstallationID, response.evidence));
    }
    return;
  }
  if (command.type === "unbindTarget") {
    if (command.extensionInstallationID !== extensionInstallationID) return;
    bindings.delete(command.hookID);
    const tabs = await browser.tabs.query({});
    await Promise.allSettled(tabs.map((tab) => (
      tab.id === undefined
        ? Promise.resolve()
        : browser.tabs.sendMessage(tab.id, { type: "awaitcue.unbind", hookID: command.hookID })
    )));
    port.postMessage({
      type: "targetUnbound",
      requestID: command.requestID,
      extensionInstallationID,
      hookID: command.hookID
    });
    return;
  }
  if (command.type === "focusTarget") {
    if (command.extensionInstallationID !== extensionInstallationID) return;
    let tab;
    try {
      tab = await browser.tabs.get(command.tabID);
    } catch {
      postTargetUnavailable(port, command, "tab_closed");
      return;
    }
    if (
      typeof tab.url !== "string"
      || !tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)
    ) {
      postTargetUnavailable(port, command, "tab_identity_mismatch");
      return;
    }
    await browser.tabs.update(command.tabID, { active: true });
    if (tab.windowId !== undefined) await browser.windows.update(tab.windowId, { focused: true });
    port.postMessage({
      type: "targetFocused",
      requestID: command.requestID,
      extensionInstallationID,
      hookID: command.hookID,
      tabID: command.tabID
    });
  }
}

function handleCommandFailure(port, rawCommand) {
  const command = parseNativeCommand(rawCommand);
  if (command === null) return;
  if (command.type === "resolveSelection") {
    port.postMessage({
      type: "selectionResolved",
      requestID: command.requestID,
      matched: false,
      reason: "page_access_unavailable"
    });
    return;
  }
  if (command.type === "resolveActiveHost") {
    port.postMessage({
      type: "activeHostResolved",
      requestID: command.requestID,
      matched: false,
      extensionInstallationID
    });
    return;
  }
  if (command.type === "bindTarget") {
    bindings.delete(command.hookID);
    port.postMessage({
      type: "targetUnavailable",
      requestID: command.requestID,
      extensionInstallationID,
      hookID: command.hookID,
      reason: "content_bind_failed"
    });
    return;
  }
  if (command.type === "focusTarget") {
    port.postMessage({
      type: "targetUnavailable",
      requestID: command.requestID,
      extensionInstallationID,
      hookID: command.hookID,
      reason: "tab_unavailable"
    });
    return;
  }
  if (command.type === "unbindTarget") {
    port.postMessage({
      type: "error",
      requestID: command.requestID,
      extensionInstallationID,
      hookID: command.hookID,
      code: "unbind_failed",
      message: "Unable to stop Safari target observation"
    });
  }
}

async function resolveSelection(port, command) {
  const windows = await browser.windows.getAll({ populate: true });
  const candidates = windows.flatMap((window) => {
    if (
      typeof window.left !== "number"
      || typeof window.top !== "number"
      || typeof window.width !== "number"
      || typeof window.height !== "number"
    ) return [];
    return [{
      ...window,
      x: window.left,
      y: window.top,
      width: window.width,
      height: window.height
    }];
  });
  const matchedWindow = uniqueMatchingWindow(command.windowFrame, candidates);
  if (matchedWindow === null) {
    postSelectionFailure(port, command.requestID, "window_not_matched");
    return;
  }
  let activeTabs = Array.isArray(matchedWindow.tabs)
    ? matchedWindow.tabs.filter((tab) => tab.active === true)
    : [];
  if (activeTabs.length === 0 && typeof matchedWindow.id === "number") {
    activeTabs = await browser.tabs.query({ active: true, windowId: matchedWindow.id });
  }
  const tab = activeTabs.length === 1 ? activeTabs[0] : undefined;
  if (tab?.id === undefined || typeof tab.url !== "string") {
    postSelectionFailure(port, command.requestID, "active_tab_unavailable");
    return;
  }
  try {
    const url = new URL(tab.url);
    if ((url.protocol !== "http:" && url.protocol !== "https:") || !url.host) {
      postSelectionFailure(port, command.requestID, "active_tab_unavailable");
      return;
    }
    const response = await browser.tabs.sendMessage(tab.id, {
      type: "awaitcue.resolveSelection",
      requestID: command.requestID,
      selectionRect: command.selectionRect
    });
    if (!response?.matched) {
      port.postMessage({
        type: "selectionResolved",
        requestID: command.requestID,
        matched: false,
        reason: response?.reason ?? "selection_outside_viewport"
      });
      return;
    }
    port.postMessage({
      type: "selectionResolved",
      requestID: command.requestID,
      matched: true,
      target: {
        extensionInstallationID,
        tabID: tab.id,
        host: url.host,
        url: tab.url,
        title: response.title || tab.title || "",
        region: response.region,
        evidence: response.evidence
      }
    });
  } catch {
    port.postMessage({
      type: "selectionResolved",
      requestID: command.requestID,
      matched: false,
      reason: "page_access_unavailable"
    });
  }
}

function postSelectionFailure(port, requestID, reason) {
  port.postMessage({
    type: "selectionResolved",
    requestID,
    matched: false,
    reason
  });
}

function postTargetUnavailable(port, command, reason) {
  bindings.delete(command.hookID);
  port.postMessage({
    type: "targetUnavailable",
    requestID: command.requestID,
    extensionInstallationID,
    hookID: command.hookID,
    reason
  });
}

/** Native relay 断开或 App 不可用时停止当前 worker 里的全部页面观察。 */
async function clearAllBindings() {
  const currentBindings = [...bindings.entries()];
  bindings.clear();
  await Promise.allSettled(currentBindings.map(([hookID, binding]) => (
    browser.tabs.sendMessage(binding.tabID, { type: "awaitcue.unbind", hookID })
  )));
}

async function loadInstallationID() {
  const stored = await browser.storage.local.get("awaitcueInstallationID");
  if (typeof stored.awaitcueInstallationID === "string") return stored.awaitcueInstallationID;
  const identifier = crypto.randomUUID();
  await browser.storage.local.set({ awaitcueInstallationID: identifier });
  return identifier;
}
