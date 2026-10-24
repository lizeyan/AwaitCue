import { describe, expect, it } from "vitest";
import { isNormalizedRegion, parseNativeCommand } from "../src/protocol";

describe("native protocol", () => {
  it("parses supported commands", () => {
    expect(parseNativeCommand({
      type: "ping",
      requestID: "ping-1",
      extensionInstallationID: "installation-1"
    })).toEqual({
      type: "ping",
      requestID: "ping-1",
      extensionInstallationID: "installation-1"
    });
    expect(parseNativeCommand({
      type: "resolveActiveHost",
      requestID: "active-host-1"
    })).toEqual({
      type: "resolveActiveHost",
      requestID: "active-host-1"
    });
    expect(
      parseNativeCommand({
        type: "resolveSelection",
        requestID: "request-1",
        windowFrame: { x: 0, y: 0, width: 1_000, height: 800 },
        selectionRect: { x: 100, y: 200, width: 300, height: 200 }
      })
    ).toEqual({
      type: "resolveSelection",
      requestID: "request-1",
      windowFrame: { x: 0, y: 0, width: 1_000, height: 800 },
      selectionRect: { x: 100, y: 200, width: 300, height: 200 }
    });
    expect(parseNativeCommand({
      type: "unbindTarget",
      extensionInstallationID: "installation-1",
      hookID: "hook-1"
    })).toEqual({
      type: "unbindTarget",
      extensionInstallationID: "installation-1",
      hookID: "hook-1"
    });
    expect(parseNativeCommand({
      type: "focusTarget",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build"
    })).toEqual({
      type: "focusTarget",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build"
    });
    expect(
      parseNativeCommand({
        type: "bindTarget",
        requestID: "bind-1",
        extensionInstallationID: "installation-1",
        hookID: "hook-1",
        tabID: 7,
        expectedHost: "example.com",
        expectedURL: "https://example.com/build",
        region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
        requirePixels: true
      })
    ).toEqual({
      type: "bindTarget",
      requestID: "bind-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 7,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build",
      region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 }
    });
  });

  it("rejects malformed and out-of-bounds commands", () => {
    expect(parseNativeCommand(null)).toBeNull();
    expect(parseNativeCommand([])).toBeNull();
    expect(parseNativeCommand({ type: "unknown" })).toBeNull();
    expect(parseNativeCommand({ type: "resolveSelection", requestID: "missing-rects" })).toBeNull();
    expect(parseNativeCommand({ type: "unbindTarget" })).toBeNull();
    expect(
      parseNativeCommand({
        type: "bindTarget",
        hookID: "hook-1",
        tabID: "7",
        region: { x: 0, y: 0, width: 1, height: 1 },
        requirePixels: false
      })
    ).toBeNull();
    expect(isNormalizedRegion({ x: 0.8, y: 0.8, width: 0.5, height: 0.5 })).toBe(false);
    expect(isNormalizedRegion({ x: Number.NaN, y: 0, width: 1, height: 1 })).toBe(false);
    expect(isNormalizedRegion("region")).toBe(false);
  });
});
