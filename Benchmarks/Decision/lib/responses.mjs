const decisionsByKind = {
  condition: ["matched", "notMatched", "uncertain"],
  interruptibility: ["interruptible", "notInterruptible", "uncertain"],
};

/** 构造与 AwaitCue 运行时等价的短输出、无 reasoning、严格结构化判断请求。 */
export function buildDecisionRequest(entry, evidence, configuration) {
  const decisions = decisionsByKind[entry.kind];
  if (!decisions) throw new Error(`unsupported decision kind: ${entry.kind}`);
  const instructions = entry.kind === "condition"
    ? configuration.conditionInstructions
    : configuration.interruptibilityInstructions;
  if (!instructions) throw new Error(`missing ${entry.kind} instructions`);
  const content = [{
    type: "input_text",
    text: inputText(entry, evidence.text),
  }];
  if (evidence.image) {
    content.push({
      type: "input_image",
      image_url: `data:${evidence.image.mediaType};base64,${evidence.image.data.toString("base64")}`,
    });
  }
  return {
    model: configuration.model,
    store: false,
    max_output_tokens: 64,
    instructions,
    reasoning: { effort: "none" },
    input: [{ role: "user", content }],
    text: {
      format: {
        type: "json_schema",
        name: entry.kind === "condition" ? "condition_evaluation" : "interruptibility_evaluation",
        strict: true,
        schema: {
          type: "object",
          properties: {
            decision: { type: "string", enum: decisions },
            confidence: { type: "number", minimum: 0, maximum: 1 },
          },
          required: ["decision", "confidence"],
          additionalProperties: false,
        },
      },
    },
  };
}

/** 把 Responses envelope 收敛为 benchmark 的稳定结果分类。 */
export function classifyResponse(response, kind) {
  const usage = normalizeUsage(response?.usage);
  if (response?.status === "incomplete") {
    return {
      outcome: "incomplete",
      reason: response.incomplete_details?.reason ?? null,
      usage,
    };
  }
  if (response?.error || response?.status === "failed") {
    return { outcome: "error", reason: response?.error?.message ?? "response failed", usage };
  }
  const outputText = response?.output
    ?.flatMap((item) => item.content ?? [])
    .find((content) => content.type === "output_text")
    ?.text;
  let parsed;
  try {
    parsed = JSON.parse(outputText);
  } catch {
    return { outcome: "invalid", reason: "missing or invalid output_text", usage };
  }
  const allowed = decisionsByKind[kind];
  if (!allowed?.includes(parsed.decision)
      || !Number.isFinite(parsed.confidence)
      || parsed.confidence < 0
      || parsed.confidence > 1) {
    return { outcome: "invalid", reason: "structured decision violates contract", usage };
  }
  return { outcome: parsed.decision, confidence: parsed.confidence, usage };
}

/** 创建真正调用外部 Responses endpoint 的 adapter；测试可以注入 fetch。 */
export function createDecisionClient({ endpoint, apiKey, model, fetchImpl = fetch }) {
  const responsesURL = endpoint.endsWith("/responses")
    ? endpoint
    : `${endpoint.replace(/\/$/, "")}/responses`;
  return {
    async evaluate(entry, evidence, instructions) {
      const body = buildDecisionRequest(entry, evidence, { model, ...instructions });
      const startedAt = performance.now();
      try {
        const response = await fetchImpl(responsesURL, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify(body),
        });
        const durationMs = performance.now() - startedAt;
        let envelope;
        try {
          envelope = await response.json();
        } catch {
          return { outcome: "invalid", reason: "response body is not JSON", durationMs };
        }
        if (!response.ok) {
          return {
            outcome: "error",
            reason: `HTTP ${response.status}`,
            durationMs,
            usage: normalizeUsage(envelope?.usage),
          };
        }
        return { ...classifyResponse(envelope, entry.kind), durationMs };
      } catch (error) {
        return {
          outcome: "error",
          reason: error instanceof Error ? error.message : String(error),
          durationMs: performance.now() - startedAt,
        };
      }
    },
  };
}

function inputText(entry, evidenceText) {
  const evidence = evidenceText?.trim() || "（没有文字证据）";
  return entry.kind === "condition"
    ? `已确认 Condition：${entry.condition}\n当前证据：\n${evidence}`
    : `当前活动证据：\n${evidence}`;
}

function normalizeUsage(usage) {
  return {
    inputTokens: finiteOrZero(usage?.input_tokens),
    outputTokens: finiteOrZero(usage?.output_tokens),
    reasoningTokens: finiteOrZero(usage?.output_tokens_details?.reasoning_tokens),
    cachedTokens: finiteOrZero(usage?.input_tokens_details?.cached_tokens),
    cacheWriteTokens: finiteOrZero(usage?.input_tokens_details?.cache_write_tokens),
  };
}

function finiteOrZero(value) {
  return Number.isFinite(value) ? value : 0;
}
