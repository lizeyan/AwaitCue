const forbiddenImageKeys = new Set(["image", "imagedataurl", "pixels", "screenshot"]);

/**
 * Safari Browser Target 只允许页面语义内容；发现任何图片字段时必须失败，不能静默丢弃后继续判断。
 */
export function makeEvidenceChangedEvent(extensionInstallationID, evidence) {
  if (typeof extensionInstallationID !== "string" || extensionInstallationID.length === 0) {
    throw new TypeError("extensionInstallationID is required");
  }
  if (!isRecord(evidence) || containsForbiddenImageKey(evidence)) {
    throw new TypeError("Safari Browser Target evidence must be DOM-only");
  }
  return {
    type: "evidenceChanged",
    extensionInstallationID,
    evidence
  };
}

export function makeReadyEvent(extensionInstallationID) {
  return {
    type: "ready",
    browser: "safari",
    extensionInstallationID
  };
}

export function makePongEvent(requestID, extensionInstallationID) {
  return {
    type: "pong",
    requestID,
    extensionInstallationID
  };
}

/**
 * Safari native extension 会对每条 browser.runtime.connectNative 消息返回接收结果。
 * 该回复不是主应用命令，必须先识别并从命令分发路径中剥离。
 */
export function parseNativeReply(value) {
  if (!isRecord(value) || typeof value.accepted !== "boolean") return null;
  if (value.accepted) return { accepted: true };
  return typeof value.error === "string"
    ? { accepted: false, error: value.error }
    : null;
}

/** 持久化 tab ID 只有在完整 URL 和 host 仍一致时才可恢复。 */
export function tabIdentityMatches(currentURL, expectedURL, expectedHost) {
  try {
    const current = new URL(currentURL);
    return (current.protocol === "http:" || current.protocol === "https:")
      && current.host === expectedHost
      && currentURL === expectedURL;
  } catch {
    return false;
  }
}

/** 原生窗口边框和 WebExtension bounds 允许少量系统阴影偏差。 */
export function windowFrameMatches(nativeFrame, browserFrame, tolerance = 12) {
  return Math.abs(nativeFrame.x - browserFrame.x) <= tolerance
    && Math.abs(nativeFrame.y - browserFrame.y) <= tolerance
    && Math.abs(nativeFrame.width - browserFrame.width) <= tolerance
    && Math.abs(nativeFrame.height - browserFrame.height) <= tolerance;
}

/** 只在恰好一个 Safari 窗口匹配时返回，避免多窗口下静默绑定错误标签页。 */
export function uniqueMatchingWindow(nativeFrame, candidates) {
  const matches = candidates.filter((candidate) => windowFrameMatches(nativeFrame, candidate));
  return matches.length === 1 ? matches[0] : null;
}

/**
 * 主应用命令必须经过运行时校验；Safari 不接受 Chromium 的 requirePixels 兼容字段。
 */
export function parseNativeCommand(value) {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  if (value.type === "stopAllBindings") {
    return { type: "stopAllBindings" };
  }
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
    value.type === "bindTarget" &&
    !("requirePixels" in value) &&
    typeof value.requestID === "string" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string" &&
    Number.isInteger(value.tabID) &&
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
    value.type === "focusTarget" &&
    typeof value.requestID === "string" &&
    typeof value.extensionInstallationID === "string" &&
    typeof value.hookID === "string" &&
    Number.isInteger(value.tabID) &&
    typeof value.expectedHost === "string" &&
    typeof value.expectedURL === "string"
  ) {
    return {
      type: "focusTarget",
      requestID: value.requestID,
      extensionInstallationID: value.extensionInstallationID,
      hookID: value.hookID,
      tabID: value.tabID,
      expectedHost: value.expectedHost,
      expectedURL: value.expectedURL
    };
  }
  return null;
}

function containsForbiddenImageKey(value) {
  if (Array.isArray(value)) return value.some(containsForbiddenImageKey);
  if (!isRecord(value)) return false;
  return Object.entries(value).some(([key, child]) => (
    forbiddenImageKeys.has(key.toLowerCase()) || containsForbiddenImageKey(child)
  ));
}

function isScreenRect(value) {
  if (!isRecord(value)) return false;
  return [value.x, value.y, value.width, value.height].every(Number.isFinite)
    && value.width > 0
    && value.height > 0;
}

function isNormalizedRegion(value) {
  if (!isRecord(value)) return false;
  const numbers = [value.x, value.y, value.width, value.height];
  return numbers.every(Number.isFinite)
    && value.x >= 0
    && value.y >= 0
    && value.width > 0
    && value.height > 0
    && value.x + value.width <= 1
    && value.y + value.height <= 1;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
