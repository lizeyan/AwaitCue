import assert from "node:assert/strict";
import test from "node:test";

import {
  buildDecisionRequest,
  classifyResponse,
  createDecisionClient,
} from "../lib/responses.mjs";

test("builds bounded structured requests for both decision contracts", () => {
  const condition = buildDecisionRequest(
    {
      kind: "condition",
      condition: "构建完成",
      tags: ["browser", "dom-only"],
    },
    {
      text: "[10,20] Build succeeded",
    },
    { model: "decision-model", conditionInstructions: "condition rules" },
  );
  assert.equal(condition.model, "decision-model");
  assert.equal(condition.store, false);
  assert.equal(condition.max_output_tokens, 64);
  assert.deepEqual(condition.reasoning, { effort: "none" });
  assert.equal(condition.instructions, "condition rules");
  assert.deepEqual(
    condition.text.format.schema.properties.decision.enum,
    ["matched", "notMatched", "uncertain"],
  );
  assert.equal(condition.input[0].content.length, 1);

  const interruptibility = buildDecisionRequest(
    { kind: "interruptibility", tags: ["active-window", "screen-evidence"] },
    {
      text: "前台应用：Safari\n窗口标题：Article\n距最近输入约：18 秒",
      image: { mediaType: "image/png", data: Buffer.from([1, 2, 3]) },
    },
    { model: "decision-model", interruptibilityInstructions: "interrupt rules" },
  );
  assert.equal(interruptibility.instructions, "interrupt rules");
  assert.deepEqual(
    interruptibility.text.format.schema.properties.decision.enum,
    ["interruptible", "notInterruptible", "uncertain"],
  );
  assert.match(interruptibility.input[0].content[1].image_url, /^data:image\/png;base64,/);
});

test("rejects wrong Condition surfaces and DOM-only interruption evidence", () => {
  assert.throws(
    () => buildDecisionRequest(
      { kind: "condition", condition: "done", tags: ["browser"] },
      { text: "DOM", image: { mediaType: "image/png", data: Buffer.from([1]) } },
      { model: "decision-model", conditionInstructions: "rules" },
    ),
    /browser evidence must be DOM-only/,
  );
  assert.throws(
    () => buildDecisionRequest(
      { kind: "interruptibility", tags: ["active-window"] },
      { text: "Browser DOM" },
      { model: "decision-model", interruptibilityInstructions: "rules" },
    ),
    /interruptibility evidence must be an active-window image/,
  );
});

test("classifies completed, incomplete, malformed, and transport outcomes", () => {
  assert.deepEqual(
    classifyResponse({
      status: "completed",
      output: [{ content: [{ type: "output_text", text: '{"decision":"matched","confidence":0.9}' }] }],
      usage: usage(),
    }, "condition"),
    {
      outcome: "matched",
      confidence: 0.9,
      usage: normalizedUsage(),
    },
  );
  assert.equal(
    classifyResponse({ status: "incomplete", incomplete_details: { reason: "max_output_tokens" } }, "condition").outcome,
    "incomplete",
  );
  assert.equal(
    classifyResponse({ status: "completed", output: [{ content: [{ type: "output_text", text: "not-json" }] }] }, "condition").outcome,
    "invalid",
  );
  assert.equal(
    classifyResponse({ status: "completed", output: [{ content: [{ type: "output_text", text: '{"decision":"interruptible","confidence":2}' }] }] }, "interruptibility").outcome,
    "invalid",
  );
});

test("measures decision latency through response body decoding", async () => {
  let elapsedMilliseconds = 0;
  const client = createDecisionClient({
    endpoint: "https://provider.example/v1",
    apiKey: "test-key",
    model: "decision-model",
    now: () => elapsedMilliseconds,
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      async json() {
        // 响应头到达并不等于一次模型调用完成；计时必须覆盖响应体读取与 JSON 解码。
        elapsedMilliseconds = 25;
        return {
          status: "completed",
          output: [{
            content: [{
              type: "output_text",
              text: '{"decision":"matched","confidence":0.9}',
            }],
          }],
          usage: usage(),
        };
      },
    }),
  });

  const result = await client.evaluate(
    { kind: "condition", condition: "构建完成", tags: ["browser", "dom-only"] },
    { text: "Build succeeded" },
    { conditionInstructions: "condition rules" },
  );

  assert.equal(result.outcome, "matched");
  assert.equal(result.durationMs, 25);
});

function usage() {
  return {
    input_tokens: 100,
    output_tokens: 20,
    input_tokens_details: { cached_tokens: 30, cache_write_tokens: 70 },
    output_tokens_details: { reasoning_tokens: 4 },
  };
}

function normalizedUsage() {
  return {
    inputTokens: 100,
    outputTokens: 20,
    reasoningTokens: 4,
    cachedTokens: 30,
    cacheWriteTokens: 70,
  };
}
