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
  const horizontalOffsets = hasWideAsymmetricChrome
    ? [0, horizontalDifference]
    : [horizontalDifference / 2];
  const borderInset = hasWideAsymmetricChrome ? 0 : horizontalDifference / 2;
  const verticalChrome = Math.max(0, metrics.outerHeight - metrics.innerHeight - borderInset);
  const selectionRight = selection.x + selection.width;
  const selectionBottom = selection.y + selection.height;
  const matchingViewports = horizontalOffsets.map((horizontalOffset) => ({
    x: metrics.screenX + horizontalOffset,
    y: metrics.screenY + verticalChrome,
    width: metrics.innerWidth,
    height: metrics.innerHeight
  })).filter((viewport) => (
    selection.x >= viewport.x &&
    selection.y >= viewport.y &&
    selectionRight <= viewport.x + viewport.width &&
    selectionBottom <= viewport.y + viewport.height
  ));
  // 浏览器没有 API 直接暴露宽侧栏在左还是右；只有选区本身能唯一排除一侧时才接受。
  // 落在两个候选重叠区时继续拒绝，不能为了兼容垂直标签栏而猜测 DOM 坐标。
  if (matchingViewports.length !== 1) return null;
  const viewport = matchingViewports[0]!;

  return {
    x: (selection.x - viewport.x) / viewport.width,
    y: (selection.y - viewport.y) / viewport.height,
    width: selection.width / viewport.width,
    height: selection.height / viewport.height
  };
}
