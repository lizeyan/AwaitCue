import { beforeEach, describe, expect, it, vi } from "vitest";

function eventStub() {
  const listeners: unknown[] = [];
  return {
    listeners,
    addListener: vi.fn((listener: unknown) => listeners.push(listener))
  };
}

function makeContentFixture() {
  const runtimeMessages = eventStub();
  const sendMessage = vi.fn().mockResolvedValue(undefined);
  vi.stubGlobal("chrome", {
    runtime: {
      onMessage: runtimeMessages,
      sendMessage
    }
  } as unknown as typeof chrome);
  return { runtimeMessages, sendMessage };
}

function setWindowMetrics(metrics: {
  screenX: number;
  screenY: number;
  outerWidth: number;
  outerHeight: number;
  innerWidth: number;
  innerHeight: number;
}): void {
  Object.defineProperties(window, Object.fromEntries(
    Object.entries(metrics).map(([key, value]) => [key, { configurable: true, value }])
  ));
  Object.defineProperties(document.documentElement, {
    clientWidth: { configurable: true, value: metrics.innerWidth },
    clientHeight: { configurable: true, value: metrics.innerHeight }
  });
}

describe("content script messages", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.unstubAllGlobals();
    delete (globalThis as typeof globalThis & { __awaitCueContentState?: unknown })
      .__awaitCueContentState;
    document.documentElement.innerHTML = "<head><title>Build</title></head><body></body>";
  });

  it("marks a conservatively expanded DOM selection without adding browser pixels", async () => {
    const fixture = makeContentFixture();
    setWindowMetrics({
      screenX: 100,
      screenY: 50,
      outerWidth: 1_000,
      outerHeight: 800,
      innerWidth: 760,
      innerHeight: 740
    });
    await import("../src/content");
    const listener = fixture.runtimeMessages.listeners[0] as (
      message: unknown,
      sender: chrome.runtime.MessageSender,
      sendResponse: (response: unknown) => void
    ) => void;
    const sendResponse = vi.fn();

    listener({
      type: "awaitcue.resolveSelection",
      requestID: "request-expanded",
      selectionRect: { x: 450, y: 200, width: 200, height: 100 }
    }, {}, sendResponse);

    expect(sendResponse).toHaveBeenCalledWith(expect.objectContaining({
      matched: true,
      selectionRegionExpanded: true,
      evidence: expect.objectContaining({ selectionRegionExpanded: true })
    }));
    const response = sendResponse.mock.calls[0]?.[0];
    expect(response).not.toHaveProperty("imageDataURL");
    expect(response.evidence).not.toHaveProperty("imageDataURL");
  });

  it("marks an exact viewport mapping as not expanded", async () => {
    const fixture = makeContentFixture();
    setWindowMetrics({
      screenX: 100,
      screenY: 50,
      outerWidth: 1_000,
      outerHeight: 800,
      innerWidth: 980,
      innerHeight: 780
    });
    await import("../src/content");
    const listener = fixture.runtimeMessages.listeners[0] as (
      message: unknown,
      sender: chrome.runtime.MessageSender,
      sendResponse: (response: unknown) => void
    ) => void;
    const sendResponse = vi.fn();

    listener({
      type: "awaitcue.resolveSelection",
      requestID: "request-exact",
      selectionRect: { x: 200, y: 100, width: 300, height: 100 }
    }, {}, sendResponse);

    expect(sendResponse).toHaveBeenCalledWith(expect.objectContaining({
      matched: true,
      selectionRegionExpanded: false,
      evidence: expect.objectContaining({ selectionRegionExpanded: false })
    }));
  });

  it("keeps the expansion marker on initial and changed evidence after binding", async () => {
    vi.useFakeTimers();
    document.body.innerHTML = '<span id="status">Waiting</span>';
    setWindowMetrics({
      screenX: 100,
      screenY: 50,
      outerWidth: 1_000,
      outerHeight: 800,
      innerWidth: 760,
      innerHeight: 740
    });
    const status = document.querySelector<HTMLElement>("#status")!;
    vi.spyOn(status, "getBoundingClientRect").mockReturnValue(rect(100, 100, 200, 30));
    vi.spyOn(document, "createRange").mockImplementation(() => ({
      selectNodeContents() {},
      getClientRects: () => [rect(100, 100, 200, 30)] as unknown as DOMRectList,
      detach() {}
    }) as unknown as Range);
    const fixture = makeContentFixture();
    await import("../src/content");
    const listener = fixture.runtimeMessages.listeners[0] as (
      message: unknown,
      sender: chrome.runtime.MessageSender,
      sendResponse: (response: unknown) => void
    ) => void;
    const sendResponse = vi.fn();

    listener({
      type: "awaitcue.bind",
      hookID: "hook-expanded",
      region: { x: 0, y: 0, width: 1, height: 1 },
      selectionRegionExpanded: true
    }, {}, sendResponse);

    expect(sendResponse).toHaveBeenCalledWith({
      ok: true,
      evidence: expect.objectContaining({
        selectionRegionExpanded: true,
        html: expect.stringContaining("Waiting")
      })
    });
    expect(sendResponse.mock.calls[0]?.[0].evidence).not.toHaveProperty("imageDataURL");

    status.textContent = "Succeeded";
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(300);

    const evidenceMessages = fixture.sendMessage.mock.calls
      .map(([message]) => message)
      .filter((message) => message.type === "awaitcue.evidence");
    expect(evidenceMessages).toHaveLength(1);
    expect(evidenceMessages[0].evidence).toMatchObject({ selectionRegionExpanded: true });
    expect(evidenceMessages[0].evidence.html).toContain("Succeeded");
    expect(evidenceMessages[0].evidence).not.toHaveProperty("imageDataURL");
    vi.useRealTimers();
  });
});

function rect(x: number, y: number, width: number, height: number): DOMRect {
  return {
    x,
    y,
    width,
    height,
    top: y,
    right: x + width,
    bottom: y + height,
    left: x,
    toJSON: () => ({})
  };
}
