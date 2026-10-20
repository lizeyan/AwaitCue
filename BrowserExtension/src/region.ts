import type { NormalizedRegion } from "./protocol";

export type PixelRegion = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

/** 将归一化区域转换成当前 viewport 或视频帧中的整数像素区域。 */
export function denormalizeRegion(
  region: NormalizedRegion,
  containerWidth: number,
  containerHeight: number
): PixelRegion {
  if (containerWidth <= 0 || containerHeight <= 0) {
    throw new RangeError("Container dimensions must be positive");
  }
  return {
    x: Math.floor(region.x * containerWidth),
    y: Math.floor(region.y * containerHeight),
    width: Math.max(1, Math.ceil(region.width * containerWidth)),
    height: Math.max(1, Math.ceil(region.height * containerHeight))
  };
}

/** 判断两个 DOMRect 是否相交。 */
export function intersects(a: Pick<DOMRect, "left" | "top" | "right" | "bottom">, b: PixelRegion): boolean {
  const bRight = b.x + b.width;
  const bBottom = b.y + b.height;
  return a.left < bRight && a.right > b.x && a.top < bBottom && a.bottom > b.y;
}
