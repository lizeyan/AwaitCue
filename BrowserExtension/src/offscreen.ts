import { denormalizeRegion } from "./region";
import { fingerprint } from "./domEvidence";
import type { CaptureStart } from "./captureSession";

type ActiveCapture = Readonly<{
  stream: MediaStream;
  timer: number;
  video: HTMLVideoElement;
  lastFingerprint: string | null;
}>;

const captures = new Map<string, ActiveCapture>();

chrome.runtime.onMessage.addListener((message: unknown, _sender, sendResponse) => {
  if (!isRecord(message)) return false;
  if (message.type === "awaitcue.capture.start" && isCaptureStart(message.request)) {
    void startCapture(message.request).then(
      () => sendResponse({ ok: true }),
      (error: unknown) => sendResponse({ ok: false, message: String(error) })
    );
    return true;
  }
  if (message.type === "awaitcue.capture.stop" && typeof message.hookID === "string") {
    stopCapture(message.hookID);
    sendResponse({ ok: true });
  }
  return false;
});

async function startCapture(request: CaptureStart): Promise<void> {
  stopCapture(request.hookID);
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: "tab",
        chromeMediaSourceId: request.streamID
      }
    } as MediaTrackConstraints
  });
  const video = document.createElement("video");
  video.muted = true;
  video.srcObject = stream;
  await video.play();

  // tabCapture 是持续视频流；这里主动降为五秒抽一帧，避免把视频帧率放大成模型调用频率。
  const active: ActiveCapture = {
    stream,
    video,
    lastFingerprint: null,
    timer: window.setInterval(() => sampleFrame(request, video), 5_000)
  };
  captures.set(request.hookID, active);
  sampleFrame(request, video);
}

function stopCapture(hookID: string): void {
  const active = captures.get(hookID);
  if (!active) return;
  window.clearInterval(active.timer);
  for (const track of active.stream.getTracks()) track.stop();
  active.video.srcObject = null;
  captures.delete(hookID);
}

function sampleFrame(request: CaptureStart, video: HTMLVideoElement): void {
  if (video.videoWidth <= 0 || video.videoHeight <= 0) return;
  const region = denormalizeRegion(request.region, video.videoWidth, video.videoHeight);
  const canvas = document.createElement("canvas");
  canvas.width = region.width;
  canvas.height = region.height;
  const context = canvas.getContext("2d", { alpha: false });
  if (!context) return;
  context.drawImage(
    video,
    region.x,
    region.y,
    region.width,
    region.height,
    0,
    0,
    region.width,
    region.height
  );
  const imageDataURL = canvas.toDataURL("image/jpeg", 0.72);
  const nextFingerprint = fingerprint(imageDataURL);
  const active = captures.get(request.hookID);
  if (!active || active.lastFingerprint === nextFingerprint) return;
  captures.set(request.hookID, { ...active, lastFingerprint: nextFingerprint });
  void chrome.runtime.sendMessage({
    type: "awaitcue.capture.frame",
    hookID: request.hookID,
    imageDataURL,
    fingerprint: nextFingerprint
  });
}

function isCaptureStart(value: unknown): value is CaptureStart {
  return (
    isRecord(value) &&
    typeof value.hookID === "string" &&
    typeof value.streamID === "string" &&
    isRecord(value.region)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
