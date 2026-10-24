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
  const makeNativePort = () => ({
    onMessage: eventStub(),
    onDisconnect: eventStub(),
    postMessage: vi.fn()
  });
  const nativePorts = [makeNativePort()];
  let connectionCount = 0;
  const connectNative = vi.fn(() => {
    if (!nativePorts[connectionCount]) nativePorts.push(makeNativePort());
    return nativePorts[connectionCount++];
  });
  const nativePort = nativePorts[0]!;
  const nativeMessages = nativePort.onMessage;
  const windowsGet = vi.fn().mockResolvedValue({});
  const runtimeMessages = eventStub();
  const tabsGet = vi.fn().mockResolvedValue({
    id: 7,
    active: true,
    url: "https://build.example/job",
    title: "Build"
  });
  const tabsQuery = vi.fn().mockResolvedValue([]);
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
      onMessage: runtimeMessages
    },
    action: { onClicked: eventStub() },
    windows: { get: windowsGet },
    tabs: {
      get: tabsGet,
      query: tabsQuery,
      sendMessage: tabsSendMessage,
      onRemoved: eventStub(),
      onReplaced: eventStub(),
      onUpdated: eventStub()
    },
    scripting: { executeScript: scriptingExecuteScript },
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
    nativePorts,
    runtimeMessages,
    scriptingExecuteScript,
    tabsGet,
    tabsQuery,
    tabsSendMessage,
    windowsGet
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

  it("reconnects after the native host disconnects", async () => {
    vi.useFakeTimers();
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const disconnect = fixture.nativePort.onDisconnect.listeners[0] as () => void;

    disconnect();
    await vi.advanceTimersByTimeAsync(1_000);

    expect(fixture.connectNative).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });

  it("ignores late commands from a disconnected native port", async () => {
    vi.useFakeTimers();
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const oldMessageListener = fixture.nativePorts[0]!.onMessage.listeners[0] as
      (message: unknown) => void;
    const disconnect = fixture.nativePorts[0]!.onDisconnect.listeners[0] as () => void;

    disconnect();
    await vi.advanceTimersByTimeAsync(1_000);
    const currentPort = fixture.nativePorts[1]!;

    oldMessageListener({
      type: "ping",
      requestID: "stale-ping",
      extensionInstallationID: "installation-1"
    });
    await Promise.resolve();

    expect(currentPort.postMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: "pong", requestID: "stale-ping" })
    );
    vi.useRealTimers();
  });

  it("returns a correlated pong only for its own installation", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "ping",
      requestID: "ping-1",
      extensionInstallationID: "installation-1"
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "pong",
        requestID: "ping-1",
        extensionInstallationID: "installation-1"
      });
    });

    fixture.nativePort.postMessage.mockClear();
    listener({
      type: "ping",
      requestID: "ping-2",
      extensionInstallationID: "another-installation"
    });
    await Promise.resolve();
    expect(fixture.nativePort.postMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: "pong", requestID: "ping-2" })
    );
  });

  it("marks a restored Hook unavailable when its exact tab no longer exists", async () => {
    const fixture = makeBackgroundFixture();
    fixture.tabsGet.mockRejectedValue(new Error("No tab with id: 7"));
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "bindTarget",
      requestID: "bind-missing-tab",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job",
      region: { x: 0, y: 0, width: 1, height: 1 },
      requirePixels: false
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({ type: "targetUnavailable", hookID: "hook-1" })
      );
    });
  });

  it("binds a DOM-only Hook without requesting or emitting browser pixels", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "bindTarget",
      requestID: "bind-dom-only",
      extensionInstallationID: "installation-1",
      hookID: "hook-dom-only",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job",
      region: { x: 0, y: 0, width: 1, height: 1 },
      requirePixels: true
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "targetBound",
        requestID: "bind-dom-only",
        extensionInstallationID: "installation-1",
        hookID: "hook-dom-only",
        tabID: 7
      });
    });
    const eventTypes = fixture.nativePort.postMessage.mock.calls.map(([event]) => event.type);
    expect(eventTypes).not.toContain("captureAuthorizationRequired");
    expect(eventTypes).not.toContain("captureAuthorized");
    expect(eventTypes).not.toContain("captureFrame");
  });

  it("normalizes evidence from a tab that still runs the previous content schema", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.runtimeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "awaitcue.evidence",
      evidence: {
        hookID: "hook-upgrade",
        url: "https://build.example/job",
        title: "Build",
        text: "[10,20] Build succeeded",
        aria: ["class:status-success"],
        fingerprint: "12345678"
      }
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "evidenceChanged",
        extensionInstallationID: "installation-1",
        evidence: expect.objectContaining({
          hookID: "hook-upgrade",
          availability: "sufficient"
        })
      });
    });
  });

  it("reports when no Chromium window matches the native frame", async () => {
    const event = await resolveSelection(makeBackgroundFixture());

    expect(event).toMatchObject({ matched: false, reason: "window_not_matched" });
  });

  it("uses the recently focused content tab without enumerating browser windows", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const runtimeListener = fixture.runtimeMessages.listeners[0] as (
      message: unknown,
      sender: chrome.runtime.MessageSender
    ) => void;
    runtimeListener({
      type: "awaitcue.focusedTab",
      windowFrame: { x: 100, y: 50, width: 1_200, height: 800 }
    }, {
      tab: {
        id: 7,
        windowId: 5,
        active: true,
        url: "https://build.example/job",
        title: "Build"
      } as chrome.tabs.Tab
    });

    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;
    listener({
      type: "resolveSelection",
      requestID: "request-cached",
      windowFrame: { x: 100, y: 50, width: 1_200, height: 800 },
      selectionRect: { x: 200, y: 300, width: 300, height: 200 }
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({ type: "selectionResolved", requestID: "request-cached" })
      );
    });
    expect(fixture.tabsQuery).not.toHaveBeenCalled();
    expect(fixture.windowsGet).not.toHaveBeenCalled();
    expect(fixture.scriptingExecuteScript).not.toHaveBeenCalled();
  });

  it("reports selections outside the webpage viewport", async () => {
    const fixture = makeBackgroundFixture();
    fixture.windowsGet.mockResolvedValue({
      id: 5,
      left: 100,
      top: 50,
      width: 1_200,
      height: 800,
    });
    fixture.tabsQuery.mockResolvedValue([
      { id: 7, windowId: 5, active: true, url: "https://build.example/job", title: "Build" }
    ]);
    fixture.tabsSendMessage.mockResolvedValue({ matched: false, region: null, title: "Build" });

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({ matched: false, reason: "selection_outside_viewport" });
  });

  it("forwards the selected region DOM evidence with the resolved tab", async () => {
    const fixture = makeBackgroundFixture();
    fixture.windowsGet.mockResolvedValue({
      id: 5,
      left: 100,
      top: 50,
      width: 1_200,
      height: 800,
    });
    fixture.tabsQuery.mockResolvedValue([
      { id: 7, windowId: 5, active: true, url: "https://build.example/job", title: "Build" }
    ]);
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
        availability: "sufficient",
        fingerprint: "12345678"
      }
    });

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({
      matched: true,
      target: {
        evidence: {
          text: "[10,20] Build succeeded",
          aria: ["class:status-success"],
          availability: "sufficient"
        }
      }
    });
  });

  it("keeps the request identity when page access fails", async () => {
    const fixture = makeBackgroundFixture();
    fixture.windowsGet.mockResolvedValue({
      id: 5,
      left: 100,
      top: 50,
      width: 1_200,
      height: 800,
    });
    fixture.tabsQuery.mockResolvedValue([
      { id: 7, windowId: 5, active: true, url: "https://build.example/job", title: "Build" }
    ]);
    fixture.scriptingExecuteScript.mockRejectedValue(new Error("Cannot access page"));

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({ matched: false, reason: "page_access_unavailable" });
  });
});
