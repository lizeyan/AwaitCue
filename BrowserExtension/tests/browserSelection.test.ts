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
        { x: 50, y: 200, width: 100, height: 100 },
        { ...metrics, innerWidth: 700 }
      )
    ).toBeNull();
  });

  it("keeps a precise mapping when the selection reaches an outer window edge", () => {
    const metrics = {
      screenX: 100,
      screenY: 100,
      outerWidth: 1_000,
      outerHeight: 800,
      innerWidth: 760,
      innerHeight: 740
    };

    const rightEdgeRegion = normalizeSelectionToViewport(
      { x: 700, y: 250, width: 400, height: 200 },
      metrics
    );
    expect(rightEdgeRegion?.x).toBeCloseTo(360 / 760);
    expect(rightEdgeRegion?.y).toBeCloseTo(90 / 740);
    expect(rightEdgeRegion?.width).toBeCloseTo(400 / 760);
    expect(rightEdgeRegion?.height).toBeCloseTo(200 / 740);
    expect(
      normalizeSelectionToViewport(
        { x: 100, y: 250, width: 300, height: 200 },
        metrics
      )
    ).toEqual({
      x: 0,
      y: 90 / 740,
      width: 300 / 760,
      height: 200 / 740
    });
  });

  it("expands a partially disambiguated sidebar selection instead of guessing one side", () => {
    const region = normalizeSelectionToViewport(
      { x: 700, y: 250, width: 300, height: 200 },
      {
        screenX: 100,
        screenY: 100,
        outerWidth: 1_000,
        outerHeight: 800,
        innerWidth: 760,
        innerHeight: 740
      }
    );

    expect(region?.x).toBeCloseTo(360 / 760);
    expect(region?.width).toBeCloseTo(400 / 760);
  });

  it("expands a wide-sidebar selection to cover every plausible page mapping", () => {
    const metrics = {
      screenX: 100,
      screenY: 100,
      outerWidth: 1_000,
      outerHeight: 800,
      innerWidth: 760,
      innerHeight: 740
    };

    const region = normalizeSelectionToViewport(
      { x: 450, y: 250, width: 200, height: 200 },
      metrics
    );
    expect(region?.x).toBeCloseTo(110 / 760);
    expect(region?.y).toBeCloseTo(90 / 740);
    expect(region?.width).toBeCloseTo(440 / 760);
    expect(region?.height).toBeCloseTo(200 / 740);
  });

  it("accepts a selection that only an intermediate left-right sidebar split can contain", () => {
    const region = normalizeSelectionToViewport(
      { x: 250, y: 250, width: 700, height: 200 },
      {
        screenX: 100,
        screenY: 100,
        outerWidth: 1_000,
        outerHeight: 800,
        innerWidth: 760,
        innerHeight: 740
      }
    );

    expect(region?.x).toBeCloseTo(0);
    expect(region?.width).toBeCloseTo(1);
  });

  it("rejects a selection wider than every possible page viewport", () => {
    expect(
      normalizeSelectionToViewport(
        { x: 200, y: 250, width: 800, height: 200 },
        {
          screenX: 100,
          screenY: 100,
          outerWidth: 1_000,
          outerHeight: 800,
          innerWidth: 760,
          innerHeight: 740
        }
      )
    ).toBeNull();
  });

  it("keeps the conservative region normalized on a negative-origin display and extreme sidebars", () => {
    const region = normalizeSelectionToViewport(
      { x: -750, y: 250, width: 300, height: 200 },
      {
        screenX: -1_200,
        screenY: 100,
        outerWidth: 1_200,
        outerHeight: 800,
        innerWidth: 400,
        innerHeight: 740
      }
    );

    expect(region).not.toBeNull();
    expect(region!.x).toBeGreaterThanOrEqual(0);
    expect(region!.x + region!.width).toBeLessThanOrEqual(1);
  });

  it.each([
    ["右侧栏", 0],
    ["左右双侧栏", 120],
    ["左侧栏", 240]
  ])("accepts a webpage-middle selection with %s and covers its real DOM position", (_layout, actualViewportOffset) => {
    const innerWidth = 760;
    const actualDOMLeft = 300;
    const selectionWidth = 200;
    const region = normalizeSelectionToViewport(
      {
        x: 100 + actualViewportOffset + actualDOMLeft,
        y: 250,
        width: selectionWidth,
        height: 200
      },
      {
        screenX: 100,
        screenY: 100,
        outerWidth: 1_000,
        outerHeight: 800,
        innerWidth,
        innerHeight: 740
      }
    );

    expect(region).not.toBeNull();
    expect(region!.x).toBeLessThanOrEqual(actualDOMLeft / innerWidth);
    expect(region!.x + region!.width).toBeGreaterThanOrEqual(
      (actualDOMLeft + selectionWidth) / innerWidth
    );
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
    const focused = { id: 9, focused: true, tabs: [{ id: 7, active: true, url: "https://build.example/job" }] };
    expect(uniqueFocusedActiveHost([focused])).toEqual({ host: "build.example", tabID: 7, browserWindowID: 9 });
    expect(uniqueFocusedActiveHost([focused, { ...focused, id: 10, tabs: [{ id: 8, active: true, url: "https://mail.example" }] }])).toBeNull();
    expect(uniqueFocusedActiveHost([{ id: 9, focused: true, tabs: [{ id: 7, active: true, url: "chrome://settings" }] }])).toBeNull();
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
