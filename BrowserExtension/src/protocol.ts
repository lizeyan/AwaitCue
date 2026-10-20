export const nativeHostName = "org.awaitcue.native";

export type NormalizedRegion = Readonly<{
  x: number;
  y: number;
  width: number;
  height: number;
}>;

export type BindTargetCommand = Readonly<{
  type: "bindTarget";
  hookID: string;
  tabID: number;
  region: NormalizedRegion;
  requirePixels: boolean;
}>;

export type UnbindTargetCommand = Readonly<{
  type: "unbindTarget";
  hookID: string;
}>;

export type NativeCommand = BindTargetCommand | UnbindTargetCommand | Readonly<{ type: "ping" }>;

export type Evidence = Readonly<{
  hookID: string;
  url: string;
  title: string;
  text: string;
  aria: string[];
  fingerprint: string;
}>;

export type ExtensionEvent =
  | Readonly<{ type: "ready"; browser: string }>
  | Readonly<{ type: "pong" }>
  | Readonly<{ type: "targetBound"; hookID: string; tabID: number }>
  | Readonly<{ type: "targetUnavailable"; hookID: string; reason: string }>
  | Readonly<{ type: "evidenceChanged"; evidence: Evidence }>
  | Readonly<{ type: "captureFrame"; hookID: string; imageDataURL: string; fingerprint: string }>
  | Readonly<{ type: "error"; hookID?: string; code: string; message: string }>;

/**
 * 原生消息来自本机进程，但仍需做最小运行时验证，避免损坏的消息让 service worker 进入错误状态。
 */
export function parseNativeCommand(value: unknown): NativeCommand | null {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  if (value.type === "ping") return { type: "ping" };
  if (value.type === "unbindTarget" && typeof value.hookID === "string") {
    return { type: "unbindTarget", hookID: value.hookID };
  }
  if (
    value.type === "bindTarget" &&
    typeof value.hookID === "string" &&
    typeof value.tabID === "number" &&
    typeof value.requirePixels === "boolean" &&
    isNormalizedRegion(value.region)
  ) {
    return {
      type: "bindTarget",
      hookID: value.hookID,
      tabID: value.tabID,
      region: value.region,
      requirePixels: value.requirePixels
    };
  }
  return null;
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
