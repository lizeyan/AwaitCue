import { beforeEach, describe, expect, it, vi } from "vitest";

function eventStub() {
  return { addListener: vi.fn() };
}

describe("background service worker startup", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.unstubAllGlobals();
  });

  it("connects the native host whenever a fresh worker starts", async () => {
    const nativePort = {
      onMessage: eventStub(),
      onDisconnect: eventStub(),
      postMessage: vi.fn()
    };
    const connectNative = vi.fn(() => nativePort);
    const chromeStub = {
      runtime: {
        connectNative,
        onInstalled: eventStub(),
        onStartup: eventStub(),
        onMessage: eventStub(),
        sendMessage: vi.fn().mockRejectedValue(new Error("No offscreen receiver"))
      },
      action: { onClicked: eventStub() },
      tabs: {
        onRemoved: eventStub(),
        onReplaced: eventStub(),
        onUpdated: eventStub()
      },
      storage: {
        local: {
          get: vi.fn().mockResolvedValue({ awaitcueInstallationID: "installation-1" }),
          set: vi.fn().mockResolvedValue(undefined)
        }
      }
    };
    vi.stubGlobal("chrome", chromeStub as unknown as typeof chrome);

    await import("../src/background");

    expect(connectNative).toHaveBeenCalledTimes(1);
    expect(connectNative).toHaveBeenCalledWith("org.awaitcue.native");
  });
});
