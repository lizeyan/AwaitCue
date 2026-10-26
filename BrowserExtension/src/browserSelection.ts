import type { NormalizedRegion, ScreenRect } from "./protocol";

export type BrowserViewportMetrics = Readonly<{
  screenX: number;
  screenY: number;
  outerWidth: number;
  outerHeight: number;
  innerWidth: number;
  innerHeight: number;
}>;

/** 比较原生窗口与 Chromium window bounds，容忍阴影和系统边框造成的小偏差。 */
export function windowFrameMatches(
  nativeFrame: ScreenRect,
  browserFrame: ScreenRect,
  tolerance = 12
): boolean {
  return (
    Math.abs(nativeFrame.x - browserFrame.x) <= tolerance &&
    Math.abs(nativeFrame.y - browserFrame.y) <= tolerance &&
    Math.abs(nativeFrame.width - browserFrame.width) <= tolerance &&
    Math.abs(nativeFrame.height - browserFrame.height) <= tolerance
  );
}

/** 只有恰好一个窗口 frame 匹配时才返回候选，避免在同一 installation 内静默选错窗口。 */
export function uniqueMatchingWindow<T extends ScreenRect>(
  nativeFrame: ScreenRect,
  candidates: readonly T[]
): T | null {
  const matches = candidates.filter((candidate) => windowFrameMatches(nativeFrame, candidate));
  return matches.length === 1 ? (matches[0] ?? null) : null;
}

type BrowserWindowState = Readonly<{
  id?: number | undefined;
  focused?: boolean | undefined;
  tabs?: readonly Readonly<{
    id?: number | undefined;
    active?: boolean | undefined;
    url?: string | undefined;
  }>[] | undefined;
}>;

export type FocusedActiveBrowserContext = Readonly<{
  host: string;
  tabID: number;
  browserWindowID: number;
}>;

/** 仅当一个 installation 内恰好一个 focused 窗口拥有一个 HTTP(S) active tab 时返回稳定身份。 */
export function uniqueFocusedActiveHost(
  windows: readonly BrowserWindowState[]
): FocusedActiveBrowserContext | null {
  const focusedWindows = windows.filter((candidate) => candidate.focused === true);
  if (focusedWindows.length !== 1) return null;
  const focusedWindow = focusedWindows[0];
  if (typeof focusedWindow?.id !== "number") return null;
  const activeTabs = (focusedWindows[0]?.tabs ?? []).filter(
    (candidate) => candidate.active === true && typeof candidate.id === "number" && typeof candidate.url === "string"
  );
  if (activeTabs.length !== 1) return null;
  try {
    const url = new URL(activeTabs[0]!.url!);
    return (url.protocol === "http:" || url.protocol === "https:") && url.host
      ? { host: url.host, tabID: activeTabs[0]!.id!, browserWindowID: focusedWindow.id }
      : null;
  } catch {
    return null;
  }
}

/** 持久化 tab ID 只能在 URL 和 host 仍完全一致时恢复，避免浏览器重启后的 ID 复用。 */
export function tabIdentityMatches(
  currentURL: string,
  expectedURL: string,
  expectedHost: string
): boolean {
  try {
    const current = new URL(currentURL);
    return (current.protocol === "http:" || current.protocol === "https:")
      && current.host === expectedHost
      && currentURL === expectedURL;
  } catch {
    return false;
  }
}

/** 将全局左上原点选区转换为当前标签页 viewport 内的比例区域。 */
export function normalizeSelectionToViewport(
  selection: ScreenRect,
  metrics: BrowserViewportMetrics
): NormalizedRegion | null {
  if ([...Object.values(metrics)].some((value) => !Number.isFinite(value))) return null;
  if (metrics.innerWidth <= 0 || metrics.innerHeight <= 0) return null;

  const horizontalDifference = Math.max(0, metrics.outerWidth - metrics.innerWidth);
  const hasWideAsymmetricChrome = horizontalDifference > 64;
  const borderInset = hasWideAsymmetricChrome ? 0 : horizontalDifference / 2;
  const verticalChrome = Math.max(0, metrics.outerHeight - metrics.innerHeight - borderInset);
  const selectionRight = selection.x + selection.width;
  const selectionBottom = selection.y + selection.height;
  const viewportY = metrics.screenY + verticalChrome;
  if (selection.y < viewportY || selectionBottom > viewportY + metrics.innerHeight) return null;

  if (!hasWideAsymmetricChrome) {
    const viewportX = metrics.screenX + horizontalDifference / 2;
    if (selection.x < viewportX || selectionRight > viewportX + metrics.innerWidth) return null;
    return {
      x: (selection.x - viewportX) / metrics.innerWidth,
      y: (selection.y - viewportY) / metrics.innerHeight,
      width: selection.width / metrics.innerWidth,
      height: selection.height / metrics.innerHeight
    };
  }

  const relativeLeft = selection.x - metrics.screenX;
  const relativeRight = selectionRight - metrics.screenX;
  const minimumPossibleOffset = Math.max(0, relativeRight - metrics.innerWidth);
  const maximumPossibleOffset = Math.min(horizontalDifference, relativeLeft);
  if (minimumPossibleOffset > maximumPossibleOffset) return null;

  // Chromium 只暴露浏览器 UI 占用的总宽度，不暴露左、右侧栏各自的宽度。
  // 因此使用所有能容纳用户选区的 viewport 偏移，并返回其页面 DOM 映射的并集；
  // 这个保守范围可能横向扩大，但始终限制在网页 viewport 内，不会读取浏览器 UI。
  const left = (relativeLeft - maximumPossibleOffset) / metrics.innerWidth;
  const right = (relativeRight - minimumPossibleOffset) / metrics.innerWidth;
  return {
    x: left,
    y: (selection.y - viewportY) / metrics.innerHeight,
    width: right - left,
    height: selection.height / metrics.innerHeight
  };
}
