import { beforeEach, describe, expect, it, vi } from "vitest";

function eventStub() {
  const listeners: unknown[] = [];
  return {
    listeners,
    addListener: vi.fn((listener: unknown) => {
      listeners.push(listener);
    })
  };
}

function makeBackgroundFixture() {
  const nativeMessages = eventStub();
  const nativePort = {
    onMessage: nativeMessages,
    onDisconnect: eventStub(),
    postMessage: vi.fn()
  };
  const connectNative = vi.fn(() => nativePort);
  const windowsGetAll = vi.fn().mockResolvedValue([]);
  const tabsGet = vi.fn().mockResolvedValue({
    id: 7,
    active: true,
    url: "https://build.example/job",
    title: "Build"
  });
  const tabsSendMessage = vi.fn().mockResolvedValue({
    matched: true,
    region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
    title: "Build"
  });
  const scriptingExecuteScript = vi.fn().mockResolvedValue([]);
  const chromeStub = {
    runtime: {
      connectNative,
      onInstalled: eventStub(),
      onStartup: eventStub(),
      onMessage: eventStub(),
      sendMessage: vi.fn().mockRejectedValue(new Error("No offscreen receiver"))
    },
    action: { onClicked: eventStub() },
    windows: { getAll: windowsGetAll },
    tabs: {
      get: tabsGet,
      sendMessage: tabsSendMessage,
      onRemoved: eventStub(),
      onReplaced: eventStub(),
      onUpdated: eventStub()
    },
    scripting: { executeScript: scriptingExecuteScript },
    permissions: { contains: vi.fn().mockResolvedValue(true) },
    storage: {
      local: {
        get: vi.fn().mockResolvedValue({ awaitcueInstallationID: "installation-1" }),
        set: vi.fn().mockResolvedValue(undefined)
      }
    }
  };
  vi.stubGlobal("chrome", chromeStub as unknown as typeof chrome);
  return {
    chromeStub,
    connectNative,
    nativeMessages,
    nativePort,
    scriptingExecuteScript,
    tabsSendMessage,
    windowsGetAll
  };
}

async function resolveSelection(
  fixture: ReturnType<typeof makeBackgroundFixture>
): Promise<Record<string, unknown>> {
  await import("../src/background");
  const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;
  listener({
    type: "resolveSelection",
    requestID: "request-1",
    windowFrame: { x: 100, y: 50, width: 1_200, height: 800 },
    selectionRect: { x: 200, y: 300, width: 300, height: 200 }
  });
  await vi.waitFor(() => {
    expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
      expect.objectContaining({ type: "selectionResolved", requestID: "request-1" })
    );
  });
  return fixture.nativePort.postMessage.mock.calls
    .map(([event]) => event as Record<string, unknown>)
    .find((event) => event.type === "selectionResolved" && event.requestID === "request-1")!;
}

describe("background service worker startup", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.unstubAllGlobals();
  });

  it("connects the native host whenever a fresh worker starts", async () => {
    const fixture = makeBackgroundFixture();

    await import("../src/background");

    expect(fixture.connectNative).toHaveBeenCalledTimes(1);
    expect(fixture.connectNative).toHaveBeenCalledWith("org.awaitcue.native");
  });

  it("reports when no Chromium window matches the native frame", async () => {
    const event = await resolveSelection(makeBackgroundFixture());

    expect(event).toMatchObject({ matched: false, reason: "window_not_matched" });
  });

  it("reports selections outside the webpage viewport", async () => {
    const fixture = makeBackgroundFixture();
    fixture.windowsGetAll.mockResolvedValue([{
      left: 100,
      top: 50,
      width: 1_200,
      height: 800,
      tabs: [{ id: 7, active: true, url: "https://build.example/job", title: "Build" }]
    }]);
    fixture.tabsSendMessage.mockResolvedValue({ matched: false, region: null, title: "Build" });

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({ matched: false, reason: "selection_outside_viewport" });
  });

  it("forwards the selected region DOM evidence with the resolved tab", async () => {
    const fixture = makeBackgroundFixture();
    fixture.windowsGetAll.mockResolvedValue([{
      left: 100,
      top: 50,
      width: 1_200,
      height: 800,
      tabs: [{ id: 7, active: true, url: "https://build.example/job", title: "Build" }]
    }]);
    fixture.tabsSendMessage.mockResolvedValue({
      matched: true,
      region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
      title: "Build",
      evidence: {
        hookID: "request-1",
        url: "https://build.example/job",
        title: "Build",
        text: "[10,20] Build succeeded",
        aria: ["class:status-success"],
        fingerprint: "12345678"
      }
    });

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({
      matched: true,
      target: {
        evidence: {
          text: "[10,20] Build succeeded",
          aria: ["class:status-success"]
        }
      }
    });
  });

  it("keeps the request identity when page access fails", async () => {
    const fixture = makeBackgroundFixture();
    fixture.windowsGetAll.mockResolvedValue([{
      left: 100,
      top: 50,
      width: 1_200,
      height: 800,
      tabs: [{ id: 7, active: true, url: "https://build.example/job", title: "Build" }]
    }]);
    fixture.scriptingExecuteScript.mockRejectedValue(new Error("Cannot access page"));

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({ matched: false, reason: "page_access_unavailable" });
  });
});
