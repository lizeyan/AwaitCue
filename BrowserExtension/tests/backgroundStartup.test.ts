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
  const windowsUpdate = vi.fn().mockResolvedValue({});
  const runtimeMessages = eventStub();
  const tabsGet = vi.fn().mockResolvedValue({
    id: 7,
    active: true,
    url: "https://build.example/job",
    title: "Build"
  });
  const tabsQuery = vi.fn().mockResolvedValue([]);
  const tabsUpdate = vi.fn().mockResolvedValue({});
  const tabsSendMessage = vi.fn().mockResolvedValue({
    matched: true,
    region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
    title: "Build"
  });
  const scriptingExecuteScript = vi.fn().mockResolvedValue([]);
  const chromeStub = {
    runtime: {
      connectNative,
      getManifest: vi.fn(() => ({ version: "0.1.0" })),
      onInstalled: eventStub(),
      onStartup: eventStub(),
      onMessage: runtimeMessages
    },
    action: { onClicked: eventStub() },
    windows: { get: windowsGet, update: windowsUpdate },
    tabs: {
      get: tabsGet,
      query: tabsQuery,
      update: tabsUpdate,
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
    tabsUpdate,
    windowsGet,
    windowsUpdate
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

  it("announces the public protocol and extension version on every ready", async () => {
    const fixture = makeBackgroundFixture();

    await import("../src/background");

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "ready",
        browser: navigator.userAgent,
        protocolVersion: 1,
        extensionVersion: "0.1.0",
        extensionInstallationID: "installation-1"
      });
    });
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

  it("reconnects immediately when a page regains focus during native-host backoff", async () => {
    vi.useFakeTimers();
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const disconnect = fixture.nativePort.onDisconnect.listeners[0] as () => void;
    const runtimeListener = fixture.runtimeMessages.listeners[0] as (
      message: unknown,
      sender: chrome.runtime.MessageSender
    ) => void;

    disconnect();
    await Promise.resolve();
    runtimeListener({
      type: "awaitcue.focusedTab",
      windowFrame: { x: 100, y: 100, width: 1_000, height: 800 }
    }, {
      tab: {
        id: 7,
        windowId: 9,
        url: "https://build.example/job"
      } as chrome.tabs.Tab
    });

    await vi.waitFor(() => expect(fixture.connectNative).toHaveBeenCalledTimes(2));
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fixture.connectNative).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });

  it("backs off consecutive native-host failures until the current port receives a message", async () => {
    vi.useFakeTimers();
    const fixture = makeBackgroundFixture();
    await import("../src/background");

    const disconnectCurrentPort = async () => {
      const port = fixture.nativePorts[fixture.connectNative.mock.calls.length - 1]!;
      const disconnect = port.onDisconnect.listeners[0] as () => void;
      disconnect();
      await Promise.resolve();
    };

    await disconnectCurrentPort();
    await vi.advanceTimersByTimeAsync(999);
    expect(fixture.connectNative).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fixture.connectNative).toHaveBeenCalledTimes(2);

    await disconnectCurrentPort();
    await vi.advanceTimersByTimeAsync(1_999);
    expect(fixture.connectNative).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(fixture.connectNative).toHaveBeenCalledTimes(3);

    await disconnectCurrentPort();
    await vi.advanceTimersByTimeAsync(3_999);
    expect(fixture.connectNative).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(fixture.connectNative).toHaveBeenCalledTimes(4);

    const currentPort = fixture.nativePorts[3]!;
    const currentListener = currentPort.onMessage.listeners[0] as (message: unknown) => void;
    currentListener({ type: "unknown" });
    await Promise.resolve();
    const currentDisconnect = currentPort.onDisconnect.listeners[0] as () => void;
    currentDisconnect();
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(999);
    expect(fixture.connectNative).toHaveBeenCalledTimes(4);
    await vi.advanceTimersByTimeAsync(1);
    expect(fixture.connectNative).toHaveBeenCalledTimes(5);
    vi.useRealTimers();
  });

  it("finishes unbinding old pages before scheduling the next native port", async () => {
    vi.useFakeTimers();
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;
    listener({
      type: "bindTarget",
      requestID: "bind-before-disconnect",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job",
      region: { x: 0, y: 0, width: 1, height: 1 }
    });
    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({ type: "targetBound", hookID: "hook-1" })
      );
    });

    let releaseUnbind: (() => void) | undefined;
    fixture.tabsSendMessage.mockImplementation((_tabID, message) => (
      message.type === "awaitcue.unbind"
        ? new Promise((resolve) => { releaseUnbind = () => resolve({ ok: true }); })
        : Promise.resolve({})
    ));
    const disconnect = fixture.nativePort.onDisconnect.listeners[0] as () => void;
    disconnect();
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(fixture.connectNative).toHaveBeenCalledTimes(1);

    releaseUnbind?.();
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(999);
    expect(fixture.connectNative).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(fixture.connectNative).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });

  it("queues an external connect trigger behind disconnect cleanup without a duplicate timer", async () => {
    vi.useFakeTimers();
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;
    listener({
      type: "bindTarget",
      requestID: "bind-before-external-trigger",
      extensionInstallationID: "installation-1",
      hookID: "hook-external-trigger",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job",
      region: { x: 0, y: 0, width: 1, height: 1 }
    });
    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({ type: "targetBound", hookID: "hook-external-trigger" })
      );
    });

    let releaseUnbind: (() => void) | undefined;
    fixture.tabsSendMessage.mockImplementation((_tabID, message) => (
      message.type === "awaitcue.unbind"
        ? new Promise((resolve) => { releaseUnbind = () => resolve({ ok: true }); })
        : Promise.resolve({})
    ));
    const disconnect = fixture.nativePort.onDisconnect.listeners[0] as () => void;
    disconnect();
    await Promise.resolve();

    const startup = fixture.chromeStub.runtime.onStartup.listeners[0] as () => void;
    startup();
    expect(fixture.connectNative).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(fixture.connectNative).toHaveBeenCalledTimes(1);

    releaseUnbind?.();
    await vi.advanceTimersByTimeAsync(0);
    expect(fixture.connectNative).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(5_000);
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
        protocolVersion: 1,
        extensionVersion: "0.1.0",
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

  it("acknowledges focus and unbind only after the requested action completes", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "focusTarget",
      requestID: "focus-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job"
    });
    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "targetFocused",
        requestID: "focus-1",
        extensionInstallationID: "installation-1",
        hookID: "hook-1",
        tabID: 7
      });
    });
    expect(fixture.tabsUpdate).toHaveBeenCalledWith(7, { active: true });

    listener({
      type: "unbindTarget",
      requestID: "unbind-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1"
    });
    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "targetUnbound",
        requestID: "unbind-1",
        extensionInstallationID: "installation-1",
        hookID: "hook-1"
      });
    });
  });

  it("correlates focus failures instead of reporting silent success", async () => {
    const fixture = makeBackgroundFixture();
    fixture.tabsGet.mockRejectedValue(new Error("No tab with id: 7"));
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "focusTarget",
      requestID: "focus-closed",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job"
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          type: "targetUnavailable",
          requestID: "focus-closed",
          hookID: "hook-1",
          reason: "tab_closed"
        })
      );
    });
  });

  it("validates a persisted tab identity without focusing or binding it", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;

    listener({
      type: "validateTarget",
      requestID: "validate-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-delay",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job"
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "targetValidated",
        requestID: "validate-1",
        extensionInstallationID: "installation-1",
        hookID: "hook-delay",
        tabID: 7
      });
    });
    expect(fixture.tabsUpdate).not.toHaveBeenCalled();
    expect(fixture.tabsSendMessage).not.toHaveBeenCalled();

    fixture.nativePort.postMessage.mockClear();
    fixture.tabsGet.mockRejectedValue(new Error("No tab with id: 7"));
    listener({
      type: "validateTarget",
      requestID: "validate-closed",
      extensionInstallationID: "installation-1",
      hookID: "hook-delay",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job"
    });
    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          type: "targetUnavailable",
          requestID: "validate-closed",
          hookID: "hook-delay",
          reason: "tab_closed"
        })
      );
    });
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

  it("forwards the content script's initial evidence as part of a successful bind", async () => {
    const fixture = makeBackgroundFixture();
    fixture.tabsSendMessage.mockResolvedValue({
      ok: true,
      evidence: {
        hookID: "hook-static",
        url: "https://build.example/job",
        title: "Build",
        text: "[10,20] Waiting",
        aria: ["class:status-pending"],
        availability: "sufficient",
        selectionRegionExpanded: true,
        fingerprint: "12345678"
      }
    });
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;
    listener({
      type: "bindTarget",
      requestID: "bind-static",
      extensionInstallationID: "installation-1",
      hookID: "hook-static",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job",
      region: { x: 0, y: 0, width: 1, height: 1 },
      selectionRegionExpanded: true
    });

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "evidenceChanged",
        extensionInstallationID: "installation-1",
        evidence: expect.objectContaining({
          hookID: "hook-static",
          text: "[10,20] Waiting",
          availability: "sufficient",
          selectionRegionExpanded: true
        })
      });
    });
    expect(fixture.tabsSendMessage).toHaveBeenCalledWith(7, {
      type: "awaitcue.bind",
      hookID: "hook-static",
      region: { x: 0, y: 0, width: 1, height: 1 },
      selectionRegionExpanded: true
    });
    const evidenceEvent = fixture.nativePort.postMessage.mock.calls
      .map(([event]) => event)
      .find((event) => event.type === "evidenceChanged");
    expect(evidenceEvent?.evidence).not.toHaveProperty("imageDataURL");
  });

  it("forwards fresh initial evidence after the bound page reloads", async () => {
    const fixture = makeBackgroundFixture();
    await import("../src/background");
    const listener = fixture.nativeMessages.listeners[0] as (message: unknown) => void;
    listener({
      type: "bindTarget",
      requestID: "bind-reload",
      extensionInstallationID: "installation-1",
      hookID: "hook-reload",
      tabID: 7,
      expectedHost: "build.example",
      expectedURL: "https://build.example/job",
      region: { x: 0, y: 0, width: 1, height: 1 },
      selectionRegionExpanded: true
    });
    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith(
        expect.objectContaining({ type: "targetBound", hookID: "hook-reload" })
      );
    });
    fixture.nativePort.postMessage.mockClear();
    fixture.tabsSendMessage.mockResolvedValue({
      evidence: {
        hookID: "hook-reload",
        url: "https://build.example/job",
        title: "Build",
        text: "[10,20] Reloaded",
        aria: [],
        availability: "sufficient",
        selectionRegionExpanded: true,
        fingerprint: "87654321"
      }
    });

    const updated = fixture.chromeStub.tabs.onUpdated.listeners[0] as (
      tabID: number,
      changeInfo: { status?: "loading" | "complete" },
      tab: chrome.tabs.Tab
    ) => void;
    updated(7, { status: "complete" }, {
      id: 7,
      url: "https://build.example/job"
    } as chrome.tabs.Tab);

    await vi.waitFor(() => {
      expect(fixture.nativePort.postMessage).toHaveBeenCalledWith({
        type: "evidenceChanged",
        extensionInstallationID: "installation-1",
        evidence: expect.objectContaining({
          hookID: "hook-reload",
          text: "[10,20] Reloaded",
          selectionRegionExpanded: true
        })
      });
    });
    expect(fixture.tabsSendMessage).toHaveBeenLastCalledWith(7, {
      type: "awaitcue.bind",
      hookID: "hook-reload",
      region: { x: 0, y: 0, width: 1, height: 1 },
      selectionRegionExpanded: true
    });
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

    fixture.nativePort.postMessage.mockClear();
    listener({
      type: "awaitcue.evidence",
      evidence: {
        hookID: "hook-invalid-expansion",
        url: "https://build.example/job",
        title: "Build",
        text: "[10,20] Build succeeded",
        aria: [],
        selectionRegionExpanded: "yes",
        fingerprint: "87654321"
      }
    });
    await Promise.resolve();
    expect(fixture.nativePort.postMessage).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: "evidenceChanged" })
    );
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
      selectionRegionExpanded: true,
      title: "Build",
      evidence: {
        hookID: "request-1",
        url: "https://build.example/job",
        title: "Build",
        text: "[10,20] Build succeeded",
        aria: ["class:status-success"],
        availability: "sufficient",
        selectionRegionExpanded: true,
        fingerprint: "12345678"
      }
    });

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({
      matched: true,
      target: {
        selectionRegionExpanded: true,
        evidence: {
          text: "[10,20] Build succeeded",
          aria: ["class:status-success"],
          availability: "sufficient",
          selectionRegionExpanded: true
        }
      }
    });
    expect((event.target as Record<string, unknown>).evidence).not.toHaveProperty("imageDataURL");
  });

  it("rejects a non-boolean selection expansion marker from page responses", async () => {
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
      selectionRegionExpanded: "yes",
      title: "Build"
    });

    const event = await resolveSelection(fixture);

    expect(event).toMatchObject({ matched: false, reason: "invalid_page_response" });
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
