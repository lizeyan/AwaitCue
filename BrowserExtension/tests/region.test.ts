import { describe, expect, it } from "vitest";
import { denormalizeRegion, intersects } from "../src/region";

describe("region geometry", () => {
  it("maps normalized coordinates to stable integer pixels", () => {
    expect(denormalizeRegion({ x: 0.1, y: 0.2, width: 0.3, height: 0.4 }, 1_000, 500)).toEqual({
      x: 100,
      y: 100,
      width: 300,
      height: 200
    });
    expect(denormalizeRegion({ x: 0, y: 0, width: 0.001, height: 0.001 }, 10, 10)).toEqual({
      x: 0,
      y: 0,
      width: 1,
      height: 1
    });
  });

  it("rejects containers without drawable area", () => {
    expect(() => denormalizeRegion({ x: 0, y: 0, width: 1, height: 1 }, 0, 100)).toThrow(RangeError);
    expect(() => denormalizeRegion({ x: 0, y: 0, width: 1, height: 1 }, 100, -1)).toThrow(RangeError);
  });

  it("detects strict rectangle intersections", () => {
    const selected = { x: 10, y: 10, width: 20, height: 20 };
    expect(intersects({ left: 5, top: 5, right: 15, bottom: 15 }, selected)).toBe(true);
    expect(intersects({ left: 30, top: 10, right: 40, bottom: 20 }, selected)).toBe(false);
    expect(intersects({ left: 0, top: 30, right: 10, bottom: 40 }, selected)).toBe(false);
  });
});
