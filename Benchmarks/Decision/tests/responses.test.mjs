import assert from "node:assert/strict";
import test from "node:test";

import { buildDecisionRequest, classifyResponse } from "../lib/responses.mjs";

test("builds bounded structured requests for both decision contracts", () => {
  const condition = buildDecisionRequest(
    {
      kind: "condition",
      condition: "构建完成",
    },
    {
      text: "[10,20] Build succeeded",
      image: { mediaType: "image/png", data: Buffer.from([1, 2, 3]) },
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
  assert.match(condition.input[0].content[1].image_url, /^data:image\/png;base64,/);

  const interruptibility = buildDecisionRequest(
    { kind: "interruptibility" },
    { text: "User is reading an article" },
    { model: "decision-model", interruptibilityInstructions: "interrupt rules" },
  );
  assert.equal(interruptibility.instructions, "interrupt rules");
  assert.deepEqual(
    interruptibility.text.format.schema.properties.decision.enum,
    ["interruptible", "notInterruptible", "uncertain"],
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
