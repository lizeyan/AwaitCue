import { describe, expect, it } from "vitest";
import {
  normalizeSelectionToViewport,
  tabIdentityMatches,
  uniqueFocusedActiveHost,
  uniqueMatchingWindow,
  windowFrameMatches
} from "../src/browserSelection";

describe("browser selection mapping", () => {
  it("maps a screen selection into the page viewport", () => {
    expect(
      normalizeSelectionToViewport(
        { x: 150, y: 200, width: 300, height: 200 },
        { screenX: 100, screenY: 100, outerWidth: 1_000, outerHeight: 800, innerWidth: 980, innerHeight: 700 }
      )
    ).toEqual({
      x: 40 / 980,
      y: 10 / 700,
      width: 300 / 980,
      height: 200 / 700
    });
  });

  it("rejects browser chrome, outside regions, and invalid metrics", () => {
    const metrics = { screenX: 100, screenY: 100, outerWidth: 1_000, outerHeight: 800, innerWidth: 980, innerHeight: 700 };
    expect(normalizeSelectionToViewport({ x: 120, y: 110, width: 50, height: 20 }, metrics)).toBeNull();
    expect(normalizeSelectionToViewport({ x: 1_000, y: 700, width: 200, height: 200 }, metrics)).toBeNull();
    expect(normalizeSelectionToViewport({ x: 0, y: 0, width: 1, height: 1 }, { ...metrics, innerWidth: 0 })).toBeNull();
    expect(normalizeSelectionToViewport({ x: 0, y: 0, width: 1, height: 1 }, { ...metrics, screenX: Number.NaN })).toBeNull();
    expect(
      normalizeSelectionToViewport(
        { x: 300, y: 200, width: 100, height: 100 },
        { ...metrics, innerWidth: 700 }
      )
    ).toBeNull();
  });

  it("matches native and browser window bounds with a small system-border tolerance", () => {
    const native = { x: 100, y: 50, width: 1_200, height: 800 };
    expect(windowFrameMatches(native, { x: 108, y: 43, width: 1_192, height: 808 })).toBe(true);
    expect(windowFrameMatches(native, { x: 140, y: 50, width: 1_200, height: 800 })).toBe(false);
  });

  it("rejects ambiguous same-installation windows instead of taking the first", () => {
    const native = { x: 100, y: 50, width: 1_200, height: 800 };
    const first = { id: 1, x: 100, y: 50, width: 1_200, height: 800 };
    const second = { id: 2, x: 108, y: 43, width: 1_192, height: 808 };

    expect(uniqueMatchingWindow(native, [first])).toEqual(first);
    expect(uniqueMatchingWindow(native, [first, second])).toBeNull();
    expect(uniqueMatchingWindow(native, [{ ...first, x: 200 }])).toBeNull();
  });

  it("returns an active host only for one focused browser window", () => {
    const focused = { focused: true, tabs: [{ active: true, url: "https://build.example/job" }] };
    expect(uniqueFocusedActiveHost([focused])).toBe("build.example");
    expect(uniqueFocusedActiveHost([focused, { ...focused, tabs: [{ active: true, url: "https://mail.example" }] }])).toBeNull();
    expect(uniqueFocusedActiveHost([{ focused: true, tabs: [{ active: true, url: "chrome://settings" }] }])).toBeNull();
    expect(uniqueFocusedActiveHost([{ focused: false, tabs: focused.tabs }])).toBeNull();
  });

  it("requires persisted tab URL and host to match before restoring a binding", () => {
    expect(tabIdentityMatches(
      "https://build.example/job/1",
      "https://build.example/job/1",
      "build.example"
    )).toBe(true);
    expect(tabIdentityMatches(
      "https://mail.example/inbox",
      "https://build.example/job/1",
      "build.example"
    )).toBe(false);
    expect(tabIdentityMatches(
      "https://build.example/job/2",
      "https://build.example/job/1",
      "build.example"
    )).toBe(false);
    expect(tabIdentityMatches("chrome://settings", "chrome://settings", "")).toBe(false);
  });
});
