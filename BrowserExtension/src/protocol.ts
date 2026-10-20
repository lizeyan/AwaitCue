export const nativeHostName = "org.awaitcue.native";

export type NormalizedRegion = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

export type BindTargetCommand = Readonly<{
  type: "bindTarget";
  extensionInstallationID: string;
  hookID: string;
  tabID: number;
  expectedHost: string;
  expectedURL: string;
  region: NormalizedRegion;
  requirePixels: boolean;
}>;

export type UnbindTargetCommand = Readonly<{
  type: "unbindTarget";
  extensionInstallationID: string;
  hookID: string;
}>;

export type FocusTargetCommand = Readonly<{
  type: "focusTarget";
  extensionInstallationID: string;
  hookID: string;
  tabID: number;
  expectedHost: string;
  expectedURL: string;
}>;

export type ScreenRect = Readonly<{ x: number; y: number; width: number; height: number }>;

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

export type NativeCommand =
  | BindTargetCommand
  | UnbindTargetCommand
  | FocusTargetCommand
  | ResolveSelectionCommand
  | ResolveActiveHostCommand
  | Readonly<{ type: "ping" }>;

export type Evidence = Readonly<{
  hookID: string;
  url: string;
  title: string;
  text: string;
  aria: string[];
  fingerprint: string;
}>;

export type ExtensionEvent =
  | Readonly<{ type: "ready"; browser: string; extensionInstallationID: string }>
  | Readonly<{ type: "pong" }>
  | Readonly<{ type: "targetBound"; hookID: string; tabID: number }>
  | Readonly<{ type: "targetUnavailable"; extensionInstallationID: string; hookID: string; reason: string }>
  | Readonly<{ type: "evidenceChanged"; extensionInstallationID: string; evidence: Evidence }>
  | Readonly<{
      type: "captureFrame";
      extensionInstallationID: string;
      hookID: string;
      imageDataURL: string;
      fingerprint: string;
    }>
  | Readonly<{ type: "captureAuthorizationRequired"; hookID: string; tabID: number }>
  | Readonly<{ type: "captureAuthorized"; hookID: string; tabID: number }>
  | Readonly<{
      type: "activeHostResolved";
      requestID: string;
      matched: boolean;
      extensionInstallationID: string;
      host?: string;
    }>
  | Readonly<{
      type: "selectionResolved";
      requestID: string;
      matched: boolean;
      target?: Readonly<{
        extensionInstallationID: string;
        tabID: number;
        host: string;
        url: string;
        title: string;
        region: NormalizedRegion;
      }>;
    }>
  | Readonly<{ type: "error"; hookID?: string; code: string; message: string }>;

/**
 * 原生消息来自本机进程，但仍需做最小运行时验证，避免损坏的消息让 service worker 进入错误状态。
 */
export function parseNativeCommand(value: unknown): NativeCommand | null {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  if (value.type === "ping") return { type: "ping" };
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
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string"
  ) {
    return {
      type: "unbindTarget",
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID
    };
  }
  if (
    value.type === "focusTarget" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string" &&
    typeof value.tabID === "number" &&
    typeof value.expectedHost === "string" &&
    typeof value.expectedURL === "string"
  ) {
    return {
      type: "focusTarget",
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID,
      tabID: value.tabID,
      expectedHost: value.expectedHost,
      expectedURL: value.expectedURL
    };
  }
  if (
    value.type === "bindTarget" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string" &&
    typeof value.tabID === "number" &&
    typeof value.expectedHost === "string" &&
    typeof value.expectedURL === "string" &&
    typeof value.requirePixels === "boolean" &&
    isNormalizedRegion(value.region)
  ) {
    return {
      type: "bindTarget",
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID,
      tabID: value.tabID,
      expectedHost: value.expectedHost,
      expectedURL: value.expectedURL,
      region: value.region,
      requirePixels: value.requirePixels
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
