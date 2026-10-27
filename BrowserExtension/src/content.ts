import { collectEvidence, EvidenceObserver } from "./domEvidence";
import { normalizeSelectionToViewport } from "./browserSelection";
import type { NormalizedRegion, ScreenRect } from "./protocol";

type BindMessage = Readonly<{
  type: "awaitcue.bind";
  hookID: string;
  region: NormalizedRegion;
  selectionRegionExpanded?: boolean;
}>;
type UnbindMessage = Readonly<{ type: "awaitcue.unbind"; hookID: string }>;
type ResolveSelectionMessage = Readonly<{
  type: "awaitcue.resolveSelection";
  requestID: string;
  selectionRect: ScreenRect;
}>;

type AwaitCueContentState = {
  observers: Map<string, EvidenceObserver>;
  listenerInstalled: boolean;
};

const contentGlobal = globalThis as typeof globalThis & {
  __awaitCueContentState?: AwaitCueContentState;
};
const state = contentGlobal.__awaitCueContentState ?? {
  observers: new Map<string, EvidenceObserver>(),
  listenerInstalled: false
};
contentGlobal.__awaitCueContentState = state;

function publishFocusedTabIdentity(): void {
  if (document.visibilityState !== "visible" || !document.hasFocus()) return;
  void chrome.runtime.sendMessage({
    type: "awaitcue.focusedTab",
    windowFrame: {
      x: window.screenX,
      y: window.screenY,
      width: window.outerWidth,
      height: window.outerHeight
    }
  });
}

if (!state.listenerInstalled) {
  state.listenerInstalled = true;
  chrome.runtime.onMessage.addListener((message: unknown, _sender, sendResponse) => {
    if (isBindMessage(message)) {
      state.observers.get(message.hookID)?.stop();
      const observer = new EvidenceObserver(document, message.hookID, message.region, (evidence) => {
        void chrome.runtime.sendMessage({ type: "awaitcue.evidence", evidence });
      }, message.selectionRegionExpanded ?? false);
      state.observers.set(message.hookID, observer);
      const evidence = observer.start();
      sendResponse({ ok: true, evidence });
      return false;
    }
    if (isUnbindMessage(message)) {
      state.observers.get(message.hookID)?.stop();
      state.observers.delete(message.hookID);
      sendResponse({ ok: true });
    } else if (isResolveSelectionMessage(message)) {
      const region = normalizeSelectionToViewport(message.selectionRect, {
        screenX: window.screenX,
        screenY: window.screenY,
        outerWidth: window.outerWidth,
        outerHeight: window.outerHeight,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight
      });
      // 侧栏宽度的左右分配无法从页面读取；只比较 DOM 区域宽度与原始框选宽度，
      // 让后续模型知道证据为保证准确性被横向扩大，同时仍不采集浏览器 UI 像素。
      const selectionRegionExpanded = region !== null
        && (region.width * window.innerWidth - message.selectionRect.width) > 0.5;
      sendResponse({
        matched: region !== null,
        region,
        selectionRegionExpanded,
        url: document.location.href,
        title: document.title,
        evidence: region
          ? collectEvidence(document, message.requestID, region, selectionRegionExpanded)
          : null
      });
    }
    return false;
  });
  window.addEventListener("focus", publishFocusedTabIdentity, { passive: true });
  window.addEventListener("resize", publishFocusedTabIdentity, { passive: true });
  document.addEventListener("visibilitychange", publishFocusedTabIdentity, { passive: true });
  publishFocusedTabIdentity();
}

function isBindMessage(value: unknown): value is BindMessage {
  if (!isRecord(value) || value.type !== "awaitcue.bind") return false;
  return typeof value.hookID === "string"
    && isRecord(value.region)
    && (value.selectionRegionExpanded === undefined || typeof value.selectionRegionExpanded === "boolean");
}

function isUnbindMessage(value: unknown): value is UnbindMessage {
  return isRecord(value) && value.type === "awaitcue.unbind" && typeof value.hookID === "string";
}

function isResolveSelectionMessage(value: unknown): value is ResolveSelectionMessage {
  return isRecord(value)
    && value.type === "awaitcue.resolveSelection"
    && typeof value.requestID === "string"
    && isRecord(value.selectionRect);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
