import { describe, expect, it, vi } from "vitest";
import { CaptureSessionManager, type CaptureBackend, type CaptureStart } from "../src/captureSession";

describe("capture session manager", () => {
  it("starts, replaces, and stops one capture per hook", async () => {
    const backend = fakeBackend();
    const manager = new CaptureSessionManager(backend);
    const first = request("hook", "stream-1");
    const second = request("hook", "stream-2");

    await manager.start(first);
    expect(manager.isActive("hook")).toBe(true);
    await manager.start(second);

    expect(backend.stop).toHaveBeenCalledWith("hook");
    expect(backend.start).toHaveBeenLastCalledWith(second);

    await manager.stop("hook");
    expect(manager.isActive("hook")).toBe(false);
    await manager.stop("missing");
    expect(backend.stop).toHaveBeenCalledTimes(2);
  });

  it("stops every active capture", async () => {
    const backend = fakeBackend();
    const manager = new CaptureSessionManager(backend);
    await manager.start(request("one", "stream-1"));
    await manager.start(request("two", "stream-2"));

    await manager.stopAll();

    expect(manager.isActive("one")).toBe(false);
    expect(manager.isActive("two")).toBe(false);
    expect(backend.stop).toHaveBeenCalledTimes(2);
  });
});

function request(hookID: string, streamID: string): CaptureStart {
  return { hookID, streamID, region: { x: 0, y: 0, width: 1, height: 1 } };
}

function fakeBackend(): CaptureBackend & { start: ReturnType<typeof vi.fn>; stop: ReturnType<typeof vi.fn> } {
  return {
    start: vi.fn(async () => undefined),
    stop: vi.fn(async () => undefined)
  };
}
