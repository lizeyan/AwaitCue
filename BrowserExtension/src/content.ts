import { collectEvidence, EvidenceObserver } from "./domEvidence";
import { normalizeSelectionToViewport } from "./browserSelection";
import type { NormalizedRegion, ScreenRect } from "./protocol";

type BindMessage = Readonly<{ type: "awaitcue.bind"; hookID: string; region: NormalizedRegion }>;
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

if (!state.listenerInstalled) {
  state.listenerInstalled = true;
  chrome.runtime.onMessage.addListener((message: unknown, _sender, sendResponse) => {
    if (isBindMessage(message)) {
      state.observers.get(message.hookID)?.stop();
      const observer = new EvidenceObserver(document, message.hookID, message.region, (evidence) => {
        void chrome.runtime.sendMessage({ type: "awaitcue.evidence", evidence });
      });
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
      sendResponse({
        matched: region !== null,
        region,
        url: document.location.href,
        title: document.title,
        evidence: region ? collectEvidence(document, message.requestID, region) : null
      });
    }
    return false;
  });
}

function isBindMessage(value: unknown): value is BindMessage {
  if (!isRecord(value) || value.type !== "awaitcue.bind") return false;
  return typeof value.hookID === "string" && isRecord(value.region);
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
