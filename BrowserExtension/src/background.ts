import { CaptureSessionManager, type CaptureBackend, type CaptureStart } from "./captureSession";
import { tabIdentityMatches, uniqueFocusedActiveHost, uniqueMatchingWindow } from "./browserSelection";
import {
  nativeHostName,
  isNormalizedRegion,
  parseNativeCommand,
  type Evidence,
  type ExtensionEvent,
  type NativeCommand,
  type NormalizedRegion
} from "./protocol";

let nativePort: chrome.runtime.Port | null = null;
type HookBinding = Readonly<{
  tabID: number;
  expectedHost: string;
  expectedURL: string;
  region: NormalizedRegion;
  requirePixels: boolean;
}>;
const hookBindings = new Map<string, HookBinding>();
const pendingCaptures = new Map<string, { tabID: number; region: NormalizedRegion }>();
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let reconnectDelayMilliseconds = 1_000;
const installationIdentityPromise = installationIdentity();

const offscreenBackend: CaptureBackend = {
  async start(request) {
    await ensureOffscreenDocument();
    const response = await chrome.runtime.sendMessage({ type: "awaitcue.capture.start", request });
    if (!response?.ok) throw new Error(response?.message ?? "Unable to start tab capture");
  },
  async stop(hookID) {
    await chrome.runtime.sendMessage({ type: "awaitcue.capture.stop", hookID });
  }
};
const captureSessions = new CaptureSessionManager(offscreenBackend);

chrome.runtime.onInstalled.addListener(() => connectNative());
chrome.runtime.onStartup.addListener(() => connectNative());
chrome.action.onClicked.addListener((tab) => {
  connectNative();
  if (typeof tab.id === "number") {
    void postReady();
    for (const [hookID, pending] of pendingCaptures) {
      if (pending.tabID !== tab.id) continue;
      void startTabCapture(hookID, pending.tabID, pending.region).then(
        () => {
          pendingCaptures.delete(hookID);
          postEvent({ type: "captureAuthorized", hookID, tabID: pending.tabID });
        },
        (error: unknown) => {
          postEvent({
            type: "error",
            hookID,
            code: "capture_authorization_failed",
            message: error instanceof Error ? error.message : String(error)
          });
        }
      );
    }
  }
});

chrome.runtime.onMessage.addListener((message: unknown) => {
  if (!isRecord(message) || !nativePort) return;
  if (message.type === "awaitcue.evidence" && isEvidence(message.evidence)) {
    const evidence = message.evidence;
    void installationIdentityPromise.then((extensionInstallationID) => {
      postEvent({ type: "evidenceChanged", extensionInstallationID, evidence });
    });
  } else if (
    message.type === "awaitcue.capture.frame" &&
    typeof message.hookID === "string" &&
    typeof message.imageDataURL === "string" &&
    typeof message.fingerprint === "string"
  ) {
    const hookID = message.hookID;
    const imageDataURL = message.imageDataURL;
    const fingerprint = message.fingerprint;
    void installationIdentityPromise.then((extensionInstallationID) => {
      postEvent({
        type: "captureFrame",
        extensionInstallationID,
        hookID,
        imageDataURL,
        fingerprint
      });
    });
  }
});

chrome.tabs.onRemoved.addListener((tabID) => {
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
        void installContentBinding(hookID, binding).catch(() =>
          markTargetUnavailable(hookID, "content_rebind_failed")
        );
      }
    }
  }
});

// Manifest V3 worker 可能在浏览器仍运行时被回收并重新创建；这种冷启动不会再次触发 onStartup。
// 每次脚本求值都主动连接，connectNative 自身会阻止同一个 worker 内重复创建 native port。
connectNative();

function connectNative(): void {
  if (nativePort) return;
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  const port = chrome.runtime.connectNative(nativeHostName);
  nativePort = port;
  port.onMessage.addListener((message: unknown) => void handleNativeCommand(message));
  port.onDisconnect.addListener(() => {
    nativePort = null;
    void clearAllBindings();
    scheduleReconnect();
  });
  // service worker 重启会丢失内存中的 CaptureSessionManager；先让 offscreen 自行清理孤儿流。
  void stopOrphanedCaptures().finally(() => postReady());
}

async function handleNativeCommand(value: unknown): Promise<void> {
  const command = parseNativeCommand(value);
  if (!command) {
    postEvent({ type: "error", code: "invalid_command", message: "Invalid native command" });
    return;
  }
  try {
    if (
      (command.type === "bindTarget" || command.type === "unbindTarget" || command.type === "focusTarget") &&
      command.extensionInstallationID !== (await installationIdentityPromise)
    ) {
      return;
    }
    if (command.type === "ping") {
      postEvent({ type: "pong" });
    } else if (command.type === "resolveActiveHost") {
      await resolveActiveHost(command.requestID);
    } else if (command.type === "resolveSelection") {
      await resolveSelection(command);
    } else if (command.type === "unbindTarget") {
      await unbind(command.hookID);
    } else if (command.type === "focusTarget") {
      await focusTarget(command);
    } else {
      await bind(command);
    }
  } catch (error) {
    const event: ExtensionEvent = {
      type: "error",
      code: "command_failed",
      message: error instanceof Error ? error.message : String(error)
    };
    postEvent("hookID" in command ? { ...event, hookID: command.hookID } : event);
  }
}

async function resolveActiveHost(requestID: string): Promise<void> {
  const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
  const context = uniqueFocusedActiveHost(windows);
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
  const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
  const matchingWindow = uniqueMatchingWindow(
    command.windowFrame,
    windows.flatMap((candidate) => {
      if (
        typeof candidate.left !== "number" ||
        typeof candidate.top !== "number" ||
        typeof candidate.width !== "number" ||
        typeof candidate.height !== "number"
      ) {
        return [];
      }
      return [{
        window: candidate,
        x: candidate.left,
        y: candidate.top,
        width: candidate.width,
        height: candidate.height
      }];
    })
  );
  if (!matchingWindow) {
    postEvent({ type: "selectionResolved", requestID: command.requestID, matched: false });
    return;
  }
  const tab = matchingWindow.window.tabs?.find((candidate) => candidate.active && typeof candidate.id === "number");
  if (!tab?.id) {
    postEvent({ type: "selectionResolved", requestID: command.requestID, matched: false });
    return;
  }

  await ensureHostPermission(tab.id);
  await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  const response: unknown = await chrome.tabs.sendMessage(tab.id, {
    type: "awaitcue.resolveSelection",
    selectionRect: command.selectionRect
  });
  if (!isResolvedSelectionResponse(response) || !response.matched || !response.region || !tab.url) {
    postEvent({ type: "selectionResolved", requestID: command.requestID, matched: false });
    return;
  }
  const url = new URL(tab.url);
  postEvent({
    type: "selectionResolved",
    requestID: command.requestID,
    matched: true,
    target: {
      extensionInstallationID: await installationIdentityPromise,
      tabID: tab.id,
      host: url.host,
      url: tab.url,
      title: response.title || tab.title || url.host,
      region: response.region
    }
  });
}

async function postReady(): Promise<void> {
  reconnectDelayMilliseconds = 1_000;
  nativePort?.postMessage({
    type: "ready",
    browser: navigator.userAgent,
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
  await ensureHostPermission(command.tabID);
  const tab = await chrome.tabs.get(command.tabID);
  if (!tab.url) throw new Error("Target tab has no URL");
  if (!tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)) {
    await markTargetUnavailable(command.hookID, "tab_identity_mismatch");
    return;
  }
  const binding: HookBinding = {
    tabID: command.tabID,
    expectedHost: command.expectedHost,
    expectedURL: command.expectedURL,
    region: command.region,
    requirePixels: command.requirePixels
  };
  await installContentBinding(command.hookID, binding);
  hookBindings.set(command.hookID, binding);

  if (command.requirePixels) {
    pendingCaptures.set(command.hookID, { tabID: command.tabID, region: command.region });
    postEvent({ type: "captureAuthorizationRequired", hookID: command.hookID, tabID: command.tabID });
  }
  postEvent({ type: "targetBound", hookID: command.hookID, tabID: command.tabID });
}

async function focusTarget(command: Extract<NativeCommand, { type: "focusTarget" }>): Promise<void> {
  const tab = await chrome.tabs.get(command.tabID);
  if (!tab.url || !tabIdentityMatches(tab.url, command.expectedURL, command.expectedHost)) {
    await markTargetUnavailable(command.hookID, "tab_identity_mismatch");
    return;
  }
  await chrome.tabs.update(command.tabID, { active: true });
  if (typeof tab.windowId === "number") {
    await chrome.windows.update(tab.windowId, { focused: true });
  }
}

async function unbind(hookID: string): Promise<void> {
  const binding = hookBindings.get(hookID);
  if (binding) {
    try {
      await chrome.tabs.sendMessage(binding.tabID, { type: "awaitcue.unbind", hookID });
    } catch {
      // 标签页可能在解绑前已经关闭；清理本地状态仍然必须完成。
    }
  }
  hookBindings.delete(hookID);
  pendingCaptures.delete(hookID);
  await captureSessions.stop(hookID);
}

/** Native app 离线时停止 DOM observer 和像素捕获；重连后由 app 从持久化 Hook 重新绑定。 */
async function clearAllBindings(): Promise<void> {
  const bindings = [...hookBindings.entries()];
  hookBindings.clear();
  pendingCaptures.clear();
  await Promise.allSettled(
    bindings.map(([hookID, binding]) =>
      chrome.tabs.sendMessage(binding.tabID, { type: "awaitcue.unbind", hookID })
    )
  );
  await captureSessions.stopAll();
  await stopOrphanedCaptures();
}

async function stopOrphanedCaptures(): Promise<void> {
  try {
    await chrome.runtime.sendMessage({ type: "awaitcue.capture.stopAll" });
  } catch {
    // offscreen document 尚未创建时没有接收方，等价于没有需要清理的流。
  }
}

async function installContentBinding(hookID: string, binding: HookBinding): Promise<void> {
  await chrome.scripting.executeScript({ target: { tabId: binding.tabID }, files: ["content.js"] });
  await chrome.tabs.sendMessage(binding.tabID, {
    type: "awaitcue.bind",
    hookID,
    region: binding.region
  });
}

async function markTargetUnavailable(hookID: string, reason: string): Promise<void> {
  hookBindings.delete(hookID);
  pendingCaptures.delete(hookID);
  await captureSessions.stop(hookID);
  postEvent({
    type: "targetUnavailable",
    extensionInstallationID: await installationIdentityPromise,
    hookID,
    reason
  });
}

async function startTabCapture(hookID: string, tabID: number, region: NormalizedRegion): Promise<void> {
  const streamID = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabID });
  const request: CaptureStart = { hookID, streamID, region };
  await captureSessions.start(request);
}

async function ensureHostPermission(tabID: number): Promise<void> {
  const tab = await chrome.tabs.get(tabID);
  if (!tab.url) throw new Error("Target tab has no URL");
  const url = new URL(tab.url);
  const origin = `${url.protocol}//${url.host}/*`;
  if (await chrome.permissions.contains({ origins: [origin] })) return;
  throw new Error("The extension does not have install-time permission for the target host");
}

async function ensureOffscreenDocument(): Promise<void> {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: "offscreen.html",
    reasons: [chrome.offscreen.Reason.USER_MEDIA],
    justification: "Capture the user-approved AwaitCue tab region while the tab is in the background."
  });
}

function postEvent(event: ExtensionEvent): void {
  nativePort?.postMessage(event);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isEvidence(value: unknown): value is Evidence {
  return (
    isRecord(value) &&
    typeof value.hookID === "string" &&
    typeof value.url === "string" &&
    typeof value.title === "string" &&
    typeof value.text === "string" &&
    Array.isArray(value.aria) &&
    value.aria.every((entry) => typeof entry === "string") &&
    typeof value.fingerprint === "string"
  );
}

function isResolvedSelectionResponse(value: unknown): value is {
  matched: boolean;
  region?: NormalizedRegion;
  title: string;
} {
  return (
    isRecord(value) &&
    typeof value.matched === "boolean" &&
    typeof value.title === "string" &&
    (value.region === null || value.region === undefined || isNormalizedRegion(value.region))
  );
}
