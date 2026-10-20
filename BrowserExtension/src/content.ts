import { EvidenceObserver } from "./domEvidence";
import type { NormalizedRegion } from "./protocol";

type BindMessage = Readonly<{ type: "awaitcue.bind"; hookID: string; region: NormalizedRegion }>;
type UnbindMessage = Readonly<{ type: "awaitcue.unbind"; hookID: string }>;

const observers = new Map<string, EvidenceObserver>();

chrome.runtime.onMessage.addListener((message: unknown, _sender, sendResponse) => {
  if (isBindMessage(message)) {
    observers.get(message.hookID)?.stop();
    const observer = new EvidenceObserver(document, message.hookID, message.region, (evidence) => {
      void chrome.runtime.sendMessage({ type: "awaitcue.evidence", evidence });
    });
    observers.set(message.hookID, observer);
    const evidence = observer.start();
    sendResponse({ ok: true, evidence });
    return false;
  }
  if (isUnbindMessage(message)) {
    observers.get(message.hookID)?.stop();
    observers.delete(message.hookID);
    sendResponse({ ok: true });
  }
  return false;
});

function isBindMessage(value: unknown): value is BindMessage {
  if (!isRecord(value) || value.type !== "awaitcue.bind") return false;
  return typeof value.hookID === "string" && isRecord(value.region);
}

function isUnbindMessage(value: unknown): value is UnbindMessage {
  return isRecord(value) && value.type === "awaitcue.unbind" && typeof value.hookID === "string";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
