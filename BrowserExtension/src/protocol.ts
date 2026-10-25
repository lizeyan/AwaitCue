export const nativeHostName = "org.awaitcue.native";
// App 与扩展公开协议独立于产品版本；不兼容变更时必须显式递增。
export const chromiumProtocolVersion = 1;

export type NormalizedRegion = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

export type BindTargetCommand = Readonly<{
  type: "bindTarget";
  requestID: string;
  extensionInstallationID: string;
  hookID: string;
  tabID: number;
  expectedHost: string;
  expectedURL: string;
  region: NormalizedRegion;
}>;

export type UnbindTargetCommand = Readonly<{
  type: "unbindTarget";
  requestID: string;
  extensionInstallationID: string;
  hookID: string;
}>;

export type FocusTargetCommand = Readonly<{
  type: "focusTarget";
  requestID: string;
  extensionInstallationID: string;
  hookID: string;
  tabID: number;
  expectedHost: string;
  expectedURL: string;
}>;

export type ValidateTargetCommand = Readonly<{
  type: "validateTarget";
  requestID: string;
  extensionInstallationID: string;
  hookID: string;
  tabID: number;
  expectedHost: string;
  expectedURL: string;
}>;

export type ScreenRect = Readonly<{ x: number; y: number; width: number; height: number }>;

export type SelectionFailureReason =
  | "window_not_matched"
  | "active_tab_unavailable"
  | "selection_outside_viewport"
  | "page_access_unavailable"
  | "invalid_page_response";

export type ResolveSelectionCommand = Readonly<{
  type: "resolveSelection";
  requestID: string;
  windowFrame: ScreenRect;
  selectionRect: ScreenRect;
}>;

export type ResolveActiveHostCommand = Readonly<{
  type: "resolveActiveHost";
  requestID: string;
}>;

export type PingCommand = Readonly<{
  type: "ping";
  requestID: string;
  extensionInstallationID: string;
}>;

export type NativeCommand =
  | BindTargetCommand
  | UnbindTargetCommand
  | FocusTargetCommand
  | ValidateTargetCommand
  | ResolveSelectionCommand
  | ResolveActiveHostCommand
  | PingCommand;

export type Evidence = Readonly<{
  hookID: string;
  url: string;
  title: string;
  text: string;
  aria: string[];
  availability: "sufficient" | "insufficient";
  insufficiencyReason?: "no_semantic_content";
  fingerprint: string;
}>;

export type ExtensionEvent =
  | Readonly<{
      type: "ready";
      browser: string;
      protocolVersion: number;
      extensionVersion: string;
      extensionInstallationID: string;
    }>
  | Readonly<{
      type: "pong";
      requestID: string;
      protocolVersion: number;
      extensionVersion: string;
      extensionInstallationID: string;
    }>
  | Readonly<{
      type: "targetBound";
      requestID: string;
      extensionInstallationID: string;
      hookID: string;
      tabID: number;
    }>
  | Readonly<{
      type: "targetUnavailable";
      requestID?: string;
      extensionInstallationID: string;
      hookID: string;
      reason: string;
    }>
  | Readonly<{
      type: "targetFocused";
      requestID: string;
      extensionInstallationID: string;
      hookID: string;
      tabID: number;
    }>
  | Readonly<{
      type: "targetUnbound";
      requestID: string;
      extensionInstallationID: string;
      hookID: string;
    }>
  | Readonly<{
      type: "targetValidated";
      requestID: string;
      extensionInstallationID: string;
      hookID: string;
      tabID: number;
    }>
  | Readonly<{ type: "evidenceChanged"; extensionInstallationID: string; evidence: Evidence }>
  | Readonly<{
      type: "activeHostResolved";
      requestID: string;
      matched: boolean;
      extensionInstallationID: string;
      host?: string;
      tabID?: number;
      browserWindowID?: number;
    }>
  | Readonly<{
      type: "selectionResolved";
      requestID: string;
      matched: true;
      target: Readonly<{
        extensionInstallationID: string;
        tabID: number;
        host: string;
        url: string;
        title: string;
        region: NormalizedRegion;
        evidence?: Evidence;
      }>;
    }>
  | Readonly<{
      type: "selectionResolved";
      requestID: string;
      matched: false;
      reason: SelectionFailureReason;
    }>
  | Readonly<{ type: "error"; hookID?: string; code: string; message: string }>;

/**
 * 原生消息来自本机进程，但仍需做最小运行时验证，避免损坏的消息让 service worker 进入错误状态。
 */
export function parseNativeCommand(value: unknown): NativeCommand | null {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  if (
    value.type === "ping" &&
    typeof value.requestID === "string" &&
    typeof value.extensionInstallationID === "string"
  ) {
    return {
      type: "ping",
      requestID: value.requestID,
      extensionInstallationID: value.extensionInstallationID
    };
  }
  if (value.type === "resolveActiveHost" && typeof value.requestID === "string") {
    return { type: "resolveActiveHost", requestID: value.requestID };
  }
  if (
    value.type === "resolveSelection" &&
    typeof value.requestID === "string" &&
    isScreenRect(value.windowFrame) &&
    isScreenRect(value.selectionRect)
  ) {
    return {
      type: "resolveSelection",
      requestID: value.requestID,
      windowFrame: value.windowFrame,
      selectionRect: value.selectionRect
    };
  }
  if (
    value.type === "unbindTarget" &&
    typeof value.requestID === "string" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string"
  ) {
    return {
      type: "unbindTarget",
      requestID: value.requestID,
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID
    };
  }
  if (
    (value.type === "focusTarget" || value.type === "validateTarget") &&
    typeof value.requestID === "string" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string" &&
    typeof value.tabID === "number" &&
    typeof value.expectedHost === "string" &&
    typeof value.expectedURL === "string"
  ) {
    return {
      type: value.type,
      requestID: value.requestID,
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID,
      tabID: value.tabID,
      expectedHost: value.expectedHost,
      expectedURL: value.expectedURL
    };
  }
  if (
    value.type === "bindTarget" &&
    typeof value.requestID === "string" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string" &&
    typeof value.tabID === "number" &&
    typeof value.expectedHost === "string" &&
    typeof value.expectedURL === "string" &&
    isNormalizedRegion(value.region)
  ) {
    return {
      type: "bindTarget",
      requestID: value.requestID,
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID,
      tabID: value.tabID,
      expectedHost: value.expectedHost,
      expectedURL: value.expectedURL,
      region: value.region
    };
  }
  return null;
}

export function isScreenRect(value: unknown): value is ScreenRect {
  if (!isRecord(value)) return false;
  return [value.x, value.y, value.width, value.height].every(
    (entry) => typeof entry === "number" && Number.isFinite(entry)
  ) && (value.width as number) > 0 && (value.height as number) > 0;
}

export function isNormalizedRegion(value: unknown): value is NormalizedRegion {
  if (!isRecord(value)) return false;
  const numbers = [value.x, value.y, value.width, value.height];
  if (!numbers.every((entry) => typeof entry === "number" && Number.isFinite(entry))) return false;
  const { x, y, width, height } = value as Record<"x" | "y" | "width" | "height", number>;
  return x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
