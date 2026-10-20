import { CaptureSessionManager, type CaptureBackend, type CaptureStart } from "./captureSession";
import {
  nativeHostName,
  parseNativeCommand,
  type Evidence,
  type ExtensionEvent,
  type NativeCommand,
  type NormalizedRegion
} from "./protocol";

let nativePort: chrome.runtime.Port | null = null;
const hookTabs = new Map<string, number>();

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
    nativePort?.postMessage({ type: "ready", browser: navigator.userAgent } satisfies ExtensionEvent);
  }
});

chrome.runtime.onMessage.addListener((message: unknown) => {
  if (!isRecord(message) || !nativePort) return;
  if (message.type === "awaitcue.evidence" && isEvidence(message.evidence)) {
    nativePort.postMessage({ type: "evidenceChanged", evidence: message.evidence } satisfies ExtensionEvent);
  } else if (
    message.type === "awaitcue.capture.frame" &&
    typeof message.hookID === "string" &&
    typeof message.imageDataURL === "string" &&
    typeof message.fingerprint === "string"
  ) {
    nativePort.postMessage({
      type: "captureFrame",
      hookID: message.hookID,
      imageDataURL: message.imageDataURL,
      fingerprint: message.fingerprint
    } satisfies ExtensionEvent);
  }
});

chrome.tabs.onRemoved.addListener((tabID) => {
  for (const [hookID, boundTabID] of hookTabs) {
    if (boundTabID !== tabID) continue;
    hookTabs.delete(hookID);
    void captureSessions.stop(hookID);
    nativePort?.postMessage({ type: "targetUnavailable", hookID, reason: "tab_closed" } satisfies ExtensionEvent);
  }
});

function connectNative(): void {
  if (nativePort) return;
  const port = chrome.runtime.connectNative(nativeHostName);
  nativePort = port;
  port.onMessage.addListener((message: unknown) => void handleNativeCommand(message));
  port.onDisconnect.addListener(() => {
    nativePort = null;
    void captureSessions.stopAll();
  });
  port.postMessage({ type: "ready", browser: navigator.userAgent } satisfies ExtensionEvent);
}

async function handleNativeCommand(value: unknown): Promise<void> {
  const command = parseNativeCommand(value);
  if (!command) {
    postEvent({ type: "error", code: "invalid_command", message: "Invalid native command" });
    return;
  }
  try {
    if (command.type === "ping") {
      postEvent({ type: "pong" });
    } else if (command.type === "unbindTarget") {
      await unbind(command.hookID);
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

async function bind(command: Extract<NativeCommand, { type: "bindTarget" }>): Promise<void> {
  await ensureHostPermission(command.tabID);
  await chrome.scripting.executeScript({ target: { tabId: command.tabID }, files: ["content.js"] });
  await chrome.tabs.sendMessage(command.tabID, {
    type: "awaitcue.bind",
    hookID: command.hookID,
    region: command.region
  });
  hookTabs.set(command.hookID, command.tabID);

  if (command.requirePixels) await startTabCapture(command.hookID, command.tabID, command.region);
  postEvent({ type: "targetBound", hookID: command.hookID, tabID: command.tabID });
}

async function unbind(hookID: string): Promise<void> {
  const tabID = hookTabs.get(hookID);
  if (typeof tabID === "number") {
    try {
      await chrome.tabs.sendMessage(tabID, { type: "awaitcue.unbind", hookID });
    } catch {
      // 标签页可能在解绑前已经关闭；清理本地状态仍然必须完成。
    }
  }
  hookTabs.delete(hookID);
  await captureSessions.stop(hookID);
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
  const granted = await chrome.permissions.request({ origins: [origin] });
  if (!granted) throw new Error("Host permission was not granted");
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
