import assert from "node:assert/strict";
import { test } from "vitest";

import {
  makeEvidenceChangedEvent,
  makePongEvent,
  makeReadyEvent,
  parseNativeCommand,
  parseNativeReply,
  tabIdentityMatches,
  uniqueMatchingWindow
} from "../Resources/protocol.js";

test("Safari evidence 只允许页面内容，不接受任何图片字段", () => {
  const evidence = {
    hookID: "hook-1",
    url: "https://example.com/build/1",
    title: "Build 1",
    text: "CN 全流量部署完成",
    aria: ["status success"],
    stateClasses: ["status-success"],
    fingerprint: "dom-fingerprint"
  };

  const event = makeEvidenceChangedEvent("installation-1", evidence);
  assert.deepEqual(event.evidence, evidence);
  assert.equal(JSON.stringify(event).includes("image"), false);

  assert.throws(
    () => makeEvidenceChangedEvent("installation-1", { ...evidence, imageDataURL: "data:image/png;base64,AA==" }),
    /DOM-only/
  );
});

test("Safari ready 和 ping 使用与主应用相同的关联字段", () => {
  assert.deepEqual(makeReadyEvent("installation-1"), {
    type: "ready",
    browser: "safari",
    extensionInstallationID: "installation-1"
  });
  assert.deepEqual(
    parseNativeCommand({
      type: "ping",
      requestID: "request-1",
      extensionInstallationID: "installation-1"
    }),
    {
      type: "ping",
      requestID: "request-1",
      extensionInstallationID: "installation-1"
    }
  );
});

test("Safari 正确区分 native 接收回复、tab 身份和唯一窗口", () => {
  assert.deepEqual(parseNativeReply({ accepted: true }), { accepted: true });
  assert.deepEqual(parseNativeReply({ accepted: false, error: "relay_unavailable" }), {
    accepted: false,
    error: "relay_unavailable"
  });
  assert.equal(parseNativeReply({ accepted: false }), null);
  assert.equal(parseNativeReply({ type: "ping" }), null);

  assert.equal(
    tabIdentityMatches(
      "https://example.com/build/1",
      "https://example.com/build/1",
      "example.com"
    ),
    true
  );
  assert.equal(
    tabIdentityMatches(
      "https://example.com.evil.test/build/1",
      "https://example.com/build/1",
      "example.com"
    ),
    false
  );
  assert.equal(tabIdentityMatches("not a URL", "not a URL", "example.com"), false);

  const nativeFrame = { x: 20, y: 30, width: 900, height: 700 };
  const matching = { id: 7, x: 24, y: 34, width: 904, height: 704 };
  assert.equal(uniqueMatchingWindow(nativeFrame, [matching]), matching);
  assert.equal(uniqueMatchingWindow(nativeFrame, [matching, { ...matching, id: 8 }]), null);
  assert.equal(uniqueMatchingWindow(nativeFrame, [{ ...matching, x: 100 }]), null);
});

test("Safari bindTarget 不再接受 requirePixels", () => {
  assert.deepEqual(
    parseNativeCommand({
      type: "bindTarget",
      requestID: "bind-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 42,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build/1",
      region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 }
    }),
    {
      type: "bindTarget",
      requestID: "bind-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 42,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build/1",
      region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 }
    }
  );
  assert.equal(
    parseNativeCommand({
      type: "bindTarget",
      requestID: "bind-2",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 42,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build/1",
      region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
      requirePixels: true
    }),
    null
  );
});

test("Safari 所有原生命令都保留 request 与 Target 身份", () => {
  assert.deepEqual(makePongEvent("request-1", "installation-1"), {
    type: "pong",
    requestID: "request-1",
    extensionInstallationID: "installation-1"
  });
  assert.deepEqual(
    parseNativeCommand({ type: "resolveActiveHost", requestID: "active-1" }),
    { type: "resolveActiveHost", requestID: "active-1" }
  );
  assert.deepEqual(
    parseNativeCommand({ type: "stopAllBindings" }),
    { type: "stopAllBindings" }
  );
  const windowFrame = { x: 10, y: 20, width: 1_000, height: 700 };
  const selectionRect = { x: 100, y: 120, width: 300, height: 200 };
  assert.deepEqual(
    parseNativeCommand({
      type: "resolveSelection",
      requestID: "selection-1",
      windowFrame,
      selectionRect
    }),
    { type: "resolveSelection", requestID: "selection-1", windowFrame, selectionRect }
  );
  assert.deepEqual(
    parseNativeCommand({
      type: "unbindTarget",
      requestID: "unbind-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1"
    }),
    {
      type: "unbindTarget",
      requestID: "unbind-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1"
    }
  );
  assert.deepEqual(
    parseNativeCommand({
      type: "focusTarget",
      requestID: "focus-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 42,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build/1"
    }),
    {
      type: "focusTarget",
      requestID: "focus-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 42,
      expectedHost: "example.com",
      expectedURL: "https://example.com/build/1"
    }
  );
});

test("Safari 协议拒绝缺字段、越界区域和递归图片字段", () => {
  assert.throws(
    () => makeEvidenceChangedEvent("", { hookID: "hook-1" }),
    /extensionInstallationID/
  );
  assert.throws(
    () => makeEvidenceChangedEvent("installation-1", null),
    /DOM-only/
  );
  assert.throws(
    () => makeEvidenceChangedEvent("installation-1", {
      hookID: "hook-1",
      children: [{ nested: { SCREENSHOT: "forbidden" } }]
    }),
    /DOM-only/
  );

  for (const malformed of [
    null,
    [],
    {},
    { type: 42 },
    { type: "unknown" },
    { type: "ping", requestID: 1, extensionInstallationID: "installation-1" },
    { type: "resolveActiveHost", requestID: 1 },
    {
      type: "resolveSelection",
      requestID: "selection-1",
      windowFrame: null,
      selectionRect: { x: 0, y: 0, width: 1, height: 1 }
    },
    {
      type: "resolveSelection",
      requestID: "selection-1",
      windowFrame: { x: 0, y: 0, width: 0, height: 1 },
      selectionRect: { x: 0, y: 0, width: 1, height: 1 }
    },
    {
      type: "bindTarget",
      requestID: "bind-3",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: 42,
      expectedHost: "example.com",
      expectedURL: "https://example.com",
      region: { x: 0.8, y: 0.8, width: 0.5, height: 0.5 }
    },
    { type: "unbindTarget", requestID: "unbind-1", extensionInstallationID: "installation-1" },
    {
      type: "focusTarget",
      requestID: "focus-1",
      extensionInstallationID: "installation-1",
      hookID: "hook-1",
      tabID: "42",
      expectedHost: "example.com",
      expectedURL: "https://example.com"
    }
  ]) {
    assert.equal(parseNativeCommand(malformed), null);
  }

  assert.equal(parseNativeCommand({
    type: "unbindTarget",
    extensionInstallationID: "installation-1",
    hookID: "hook-1"
  }), null);
  assert.equal(parseNativeCommand({
    type: "focusTarget",
    extensionInstallationID: "installation-1",
    hookID: "hook-1",
    tabID: 42,
    expectedHost: "example.com",
    expectedURL: "https://example.com"
  }), null);
});
