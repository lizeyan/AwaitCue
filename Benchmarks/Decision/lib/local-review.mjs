import { aggregateBenchmark } from "./metrics.mjs";

const validHumanDecisions = new Set([
  "interruptible",
  "notInterruptible",
  "uncertain",
]);

/**
 * 在采样完成后生成不含任何模型答案的人工复核清单。
 * 复核者只能看到当时的截图、有限上下文和空白人工字段，避免被模型结论锚定。
 */
export function createHumanReviewManifest(run, samples) {
  validateCompletedRun(run, samples);
  return {
    version: 1,
    kind: "interruptibility-human-review",
    sourceRun: {
      startedAt: run.startedAt,
      intendedEndAt: run.intendedEndAt,
      completedAt: run.completedAt,
      sampleCount: run.sampleCount,
      runRecordSHA256: run.runRecordSHA256,
    },
    samples: [...samples]
      .sort((left, right) => left.id.localeCompare(right.id))
      .map((sample) => ({
        id: sample.id,
        capturedAt: sample.capturedAt,
        contextText: contextTextForReview(
          sample,
          run.activityEvidenceValidFromSampleID,
        ),
        imageFile: sample.imageFile,
        imageSHA256: sample.imageSHA256,
        sampleRecordSHA256: sample.sampleRecordSHA256,
        imageSHA256RecordedAtCapture: sample.imageSHA256RecordedAtCapture,
        humanDecision: null,
        humanRationale: null,
      })),
  };
}

/** 汇总盲审填写进度；只读取人工字段，不暴露活动内容、图片路径或模型答案。 */
export function summarizeHumanReviewProgress(review) {
  if (review?.kind !== "interruptibility-human-review" || !Array.isArray(review.samples)) {
    throw new Error("invalid human review manifest");
  }
  const samples = [...review.samples].sort((left, right) => left.id.localeCompare(right.id));
  const labelCounts = {
    interruptible: 0,
    notInterruptible: 0,
    uncertain: 0,
  };
  let completedSampleCount = 0;
  let nextIncompleteSampleID = null;
  for (const sample of samples) {
    const complete = validHumanDecisions.has(sample.humanDecision)
      && typeof sample.humanRationale === "string"
      && sample.humanRationale.trim() !== "";
    if (complete) {
      completedSampleCount += 1;
      labelCounts[sample.humanDecision] += 1;
    } else if (nextIncompleteSampleID === null) {
      nextIncompleteSampleID = sample.id;
    }
  }
  return {
    totalSampleCount: samples.length,
    completedSampleCount,
    remainingSampleCount: samples.length - completedSampleCount,
    labelCounts,
    nextIncompleteSampleID,
  };
}

/** 返回按样本编号排序的下一条未完成人工判断；不读取或推导任何模型字段。 */
export function nextIncompleteHumanReviewSample(review) {
  if (review?.kind !== "interruptibility-human-review" || !Array.isArray(review.samples)) {
    throw new Error("invalid human review manifest");
  }
  return [...review.samples]
    .sort((left, right) => left.id.localeCompare(right.id))
    .find((sample) => !(validHumanDecisions.has(sample.humanDecision)
      && typeof sample.humanRationale === "string"
      && sample.humanRationale.trim() !== "")) ?? null;
}

/**
 * 为一条盲审样本写入人工判断；已经填写或部分填写的样本都不能被静默覆盖。
 * 返回新对象，便于命令行先完整校验，再通过原子替换一次性落盘。
 */
export function applyHumanReviewLabel(review, { id, decision, rationale }) {
  if (review?.kind !== "interruptibility-human-review" || !Array.isArray(review.samples)) {
    throw new Error("invalid human review manifest");
  }
  if (typeof id !== "string" || !/^\d{4}$/.test(id)) {
    throw new Error("human review sample ID must use four digits");
  }
  if (!validHumanDecisions.has(decision)) {
    throw new Error("human decision must be interruptible, notInterruptible, or uncertain");
  }
  if (typeof rationale !== "string" || rationale.trim() === "") {
    throw new Error("human rationale must not be empty");
  }
  const matchingSamples = review.samples.filter((sample) => sample.id === id);
  if (matchingSamples.length !== 1) {
    throw new Error(`human review sample ${id} must exist exactly once`);
  }
  const sample = matchingSamples[0];
  if (sample.humanDecision !== null || sample.humanRationale !== null) {
    throw new Error(`human review sample ${id} is already labeled`);
  }
  return {
    ...review,
    samples: review.samples.map((entry) => entry.id === id
      ? {
        ...entry,
        humanDecision: decision,
        humanRationale: rationale.trim(),
      }
      : entry),
  };
}

/**
 * 所有人工标签完成后才把它们与原始生产模型结果合并，并复用固定 benchmark 的计分规则。
 */
export function compareHumanReview(run, samples, review) {
  validateCompletedRun(run, samples);
  const samplesByID = new Map(samples.map((sample) => [sample.id, sample]));
  const reviewedSamples = validateReview(
    review,
    samplesByID,
    run.activityEvidenceValidFromSampleID,
    run.runRecordSHA256,
  );
  const benchmarkCases = reviewedSamples.map((reviewed) => {
    const sample = samplesByID.get(reviewed.id);
    return {
      id: sample.id,
      kind: "interruptibility",
      expected: reviewed.humanDecision,
      description: reviewed.humanRationale,
      samples: [{
        outcome: modelOutcome(sample),
        durationMs: sample.modelLatencyMilliseconds,
      }],
    };
  });
  const captureTimeDigestCount = samples.filter(
    (sample) => sample.imageSHA256RecordedAtCapture === true,
  ).length;
  const promptVerifiedSampleCount = run.interruptibilityPromptValidFromSampleID == null
    ? 0
    : samples.filter(
      (sample) => sample.id >= run.interruptibilityPromptValidFromSampleID,
    ).length;

  return {
    version: 1,
    generatedAt: new Date().toISOString(),
    run: {
      startedAt: run.startedAt,
      intendedEndAt: run.intendedEndAt,
      completedAt: run.completedAt,
      modelName: run.modelName,
      endpointHost: run.endpointHost,
      interruptibilityPromptSHA256: run.interruptibilityPromptSHA256 ?? null,
      interruptibilityPromptValidFromSampleID:
        run.interruptibilityPromptValidFromSampleID ?? null,
      sampleCount: run.sampleCount,
      activityEvidenceValidFromSampleID:
        run.activityEvidenceValidFromSampleID ?? "0001",
      lastEvidenceAttemptAt: run.lastEvidenceAttemptAt ?? null,
      lockedPollCount: run.lockedPollCount,
      excludedPollCount: run.excludedPollCount,
      unavailablePollCount: run.unavailablePollCount ?? 0,
      availabilityClassificationValidFrom:
        run.availabilityClassificationValidFrom ?? null,
      captureFailureCount: run.captureFailureCount,
      lastCaptureFailureCode: run.lastCaptureFailureCode ?? null,
      lastCaptureFailureAt: run.lastCaptureFailureAt ?? null,
      modelFailureCount: run.modelFailureCount,
    },
    evidenceIntegrity: {
      sampleCount: samples.length,
      captureTimeDigestCount,
      reviewPreparationDigestCount: samples.length - captureTimeDigestCount,
      promptVerifiedSampleCount,
    },
    samplingTimeline: summarizeSamplingTimeline(run, samples),
    summary: aggregateLocalBenchmark(benchmarkCases),
    promptVerifiedSummary: run.interruptibilityPromptValidFromSampleID == null
      ? null
      : aggregateLocalBenchmark(benchmarkCases.filter(
        (entry) => entry.id >= run.interruptibilityPromptValidFromSampleID,
      )),
    confidenceSummary: summarizeConfidence(reviewedSamples, samplesByID),
    samples: reviewedSamples.map((reviewed) => {
      const sample = samplesByID.get(reviewed.id);
      return {
        id: reviewed.id,
        capturedAt: sample.capturedAt,
        humanDecision: reviewed.humanDecision,
        humanRationale: reviewed.humanRationale,
        modelDecision: sample.modelDecision ?? null,
        modelConfidence: sample.modelConfidence ?? null,
        modelLatencyMilliseconds: sample.modelLatencyMilliseconds,
        modelError: stableModelError(sample.modelError),
        imageSHA256RecordedAtCapture: sample.imageSHA256RecordedAtCapture,
        correct: sample.modelDecision === reviewed.humanDecision,
      };
    }),
  };
}

/**
 * 人工标签全部冻结后，生成候选 prompt 回放所需的最小证据计划。
 * 计划不读取或复制采样时的模型判断，避免候选结果被旧答案锚定。
 */
export function createReviewedReplayPlan(run, samples, review) {
  validateCompletedRun(run, samples);
  const samplesByID = new Map(samples.map((sample) => [sample.id, sample]));
  const reviewedSamples = validateReview(
    review,
    samplesByID,
    run.activityEvidenceValidFromSampleID,
    run.runRecordSHA256,
  );
  return {
    version: 1,
    kind: "interruptibility-reviewed-replay-plan",
    sourceRun: {
      runRecordSHA256: run.runRecordSHA256,
      sampleCount: run.sampleCount,
    },
    samples: reviewedSamples.map((reviewed) => ({
      id: reviewed.id,
      expected: reviewed.humanDecision,
      description: reviewed.humanRationale,
      contextText: reviewed.contextText,
      imageFile: reviewed.imageFile,
      imageSHA256: reviewed.imageSHA256,
    })),
  };
}

/**
 * 汇总同一批人工标签上的候选 prompt 结果。
 * 每张真实画面只回放一次，因此不把单次结果伪装成稳定性；Responses usage 仍可如实汇总。
 */
export function createReviewedReplayReport(plan, results, configuration) {
  if (plan?.kind !== "interruptibility-reviewed-replay-plan"
      || !Array.isArray(plan.samples)) {
    throw new Error("invalid reviewed replay plan");
  }
  if (!/^[0-9a-f]{64}$/.test(configuration?.promptSHA256 ?? "")) {
    throw new Error("reviewed replay prompt SHA-256 is invalid");
  }
  if (typeof configuration?.model !== "string" || configuration.model === ""
      || typeof configuration?.endpointHost !== "string"
      || configuration.endpointHost === "") {
    throw new Error("reviewed replay model configuration is invalid");
  }
  const resultIDs = results.map(({ id }) => id);
  const expectedIDs = plan.samples.map(({ id }) => id);
  if (new Set(resultIDs).size !== resultIDs.length
      || resultIDs.length !== expectedIDs.length
      || [...resultIDs].sort().some((id, index) => id !== [...expectedIDs].sort()[index])) {
    throw new Error("reviewed replay result IDs do not match the frozen plan");
  }
  const resultsByID = new Map(results.map((result) => [result.id, result]));
  const benchmarkCases = plan.samples.map((sample) => {
    const result = resultsByID.get(sample.id);
    validateReplayResult(sample.id, result);
    return {
      id: sample.id,
      kind: "interruptibility",
      expected: sample.expected,
      description: sample.description,
      samples: [result],
    };
  });
  const summary = aggregateBenchmark(benchmarkCases);
  const replaySummary = {
    ...summary,
    meanCaseStability: null,
    fullyStableCaseRate: null,
    cases: summary.cases.map((entry) => ({ ...entry, stability: null })),
  };
  return {
    version: 1,
    kind: "interruptibility-reviewed-replay-report",
    generatedAt: new Date().toISOString(),
    sourceRun: plan.sourceRun,
    configuration: {
      model: configuration.model,
      endpointHost: configuration.endpointHost,
      promptSHA256: configuration.promptSHA256,
    },
    summary: replaySummary,
    samples: plan.samples.map((sample) => {
      const result = resultsByID.get(sample.id);
      const hasDecision = validHumanDecisions.has(result.outcome);
      return {
        id: sample.id,
        humanDecision: sample.expected,
        humanRationale: sample.description,
        modelDecision: hasDecision ? result.outcome : null,
        modelConfidence: hasDecision ? result.confidence : null,
        modelLatencyMilliseconds: result.durationMs,
        modelError: stableReplayError(result),
        correct: result.outcome === sample.expected,
      };
    }),
  };
}

/** 候选回放的单次结果也必须遵循生产三态与可比较耗时契约。 */
function validateReplayResult(id, result) {
  if (!result || !Number.isFinite(result.durationMs) || result.durationMs < 0) {
    throw new Error(`reviewed replay sample ${id} latency is invalid`);
  }
  if (validHumanDecisions.has(result.outcome)) {
    if (!Number.isFinite(result.confidence)
        || result.confidence < 0
        || result.confidence > 1) {
      throw new Error(`reviewed replay sample ${id} confidence is invalid`);
    }
    return;
  }
  if (!["incomplete", "invalid", "error"].includes(result.outcome)) {
    throw new Error(`reviewed replay sample ${id} outcome is invalid`);
  }
}

/** 外部服务错误只进入稳定类别，不能把服务端 reason 或传输文本复制进报告。 */
function stableReplayError(result) {
  if (validHumanDecisions.has(result.outcome)) return null;
  if (result.outcome === "incomplete") return "incomplete_response";
  if (result.outcome === "invalid") return "invalid_response";
  return typeof result.reason === "string" && /^HTTP \d{3}$/.test(result.reason)
    ? "http_status"
    : "transport";
}

/**
 * 本机长期采样对每个屏幕状态只判断一次，且当前样本未记录 token usage。
 * 因此保留准确率、失败率、混淆和延迟，但明确把不可测指标设为 null，避免把单次观察伪装成稳定性 100%。
 */
function aggregateLocalBenchmark(benchmarkCases) {
  const summary = aggregateBenchmark(benchmarkCases);
  return {
    ...summary,
    meanCaseStability: null,
    fullyStableCaseRate: null,
    tokens: null,
    cases: summary.cases.map((entry) => ({ ...entry, stability: null })),
  };
}

/**
 * 汇总真实样本覆盖的时间范围与相邻采样间隔，便于识别长时间断档。
 * 按样本编号而不是时间重新排序，避免时间倒退被排序操作静默掩盖。
 */
function summarizeSamplingTimeline(run, samples) {
  const captured = [...samples]
    .sort((left, right) => left.id.localeCompare(right.id))
    .map((sample) => ({
      capturedAt: sample.capturedAt,
      timestamp: Date.parse(sample.capturedAt),
    }));
  if (captured.some(({ timestamp }) => !Number.isFinite(timestamp))) {
    throw new Error("benchmark sample capturedAt must be a valid timestamp");
  }
  if (captured.length === 0) {
    return {
      firstCapturedAt: null,
      lastCapturedAt: null,
      startDelayMilliseconds: null,
      endGapMilliseconds: null,
      observedSpanMilliseconds: 0,
      gapMilliseconds: { p50: null, p95: null, max: null },
    };
  }

  const gaps = captured.slice(1).map(({ timestamp }, index) => {
    const gap = timestamp - captured[index].timestamp;
    if (gap < 0) throw new Error("benchmark sample capturedAt must be monotonic");
    return gap;
  }).sort((left, right) => left - right);
  const first = captured[0];
  const last = captured.at(-1);

  return {
    firstCapturedAt: first.capturedAt,
    lastCapturedAt: last.capturedAt,
    startDelayMilliseconds: first.timestamp - Date.parse(run.startedAt),
    endGapMilliseconds: Math.max(0, Date.parse(run.intendedEndAt) - last.timestamp),
    observedSpanMilliseconds: last.timestamp - first.timestamp,
    gapMilliseconds: {
      p50: timelinePercentile(gaps, 0.5),
      p95: timelinePercentile(gaps, 0.95),
      max: gaps.at(-1) ?? null,
    },
  };
}

function timelinePercentile(sortedValues, probability) {
  if (sortedValues.length === 0) return null;
  return sortedValues[Math.max(0, Math.ceil(probability * sortedValues.length) - 1)];
}

/** 分开汇总正确和错误决定的置信度，不用任意阈值掩盖过度自信的错误。 */
function summarizeConfidence(reviewedSamples, samplesByID) {
  const decisions = reviewedSamples.flatMap((reviewed) => {
    const sample = samplesByID.get(reviewed.id);
    if (!validHumanDecisions.has(sample.modelDecision)) return [];
    return [{
      confidence: sample.modelConfidence,
      correct: sample.modelDecision === reviewed.humanDecision,
    }];
  });
  const correct = decisions.filter(({ correct: isCorrect }) => isCorrect);
  const incorrect = decisions.filter(({ correct: isCorrect }) => !isCorrect);
  return {
    validDecisionCount: decisions.length,
    correctDecisionCount: correct.length,
    incorrectDecisionCount: incorrect.length,
    mean: confidenceMean(decisions),
    meanCorrect: confidenceMean(correct),
    meanIncorrect: confidenceMean(incorrect),
  };
}

function confidenceMean(entries) {
  if (entries.length === 0) return null;
  return entries.reduce((sum, entry) => sum + entry.confidence, 0) / entries.length;
}

function validateCompletedRun(run, samples) {
  if (run?.status !== "completed") {
    throw new Error("benchmark run must be completed before human review");
  }
  const completedAt = Date.parse(run.completedAt);
  const startedAt = Date.parse(run.startedAt);
  const intendedEndAt = Date.parse(run.intendedEndAt);
  if (!Number.isFinite(startedAt)
      || !Number.isFinite(completedAt)
      || !Number.isFinite(intendedEndAt)
      || completedAt < intendedEndAt) {
    throw new Error("benchmark run completed before its intended end time");
  }
  if (intendedEndAt - startedAt < 86_400_000) {
    throw new Error("benchmark run must span at least 24 hours");
  }
  if (run.interruptibilityPromptSHA256 != null
      && !/^[0-9a-f]{64}$/.test(run.interruptibilityPromptSHA256)) {
    throw new Error("benchmark run prompt SHA-256 is invalid");
  }
  const promptBoundary = run.interruptibilityPromptValidFromSampleID;
  if ((run.interruptibilityPromptSHA256 == null) !== (promptBoundary == null)) {
    throw new Error("benchmark run prompt validity boundary is inconsistent");
  }
  if (promptBoundary != null) {
    const maximumBoundary = String(run.sampleCount + 1).padStart(4, "0");
    if (!/^\d{4}$/.test(promptBoundary)
        || promptBoundary === "0000"
        || promptBoundary > maximumBoundary) {
      throw new Error("benchmark run prompt validity boundary is invalid");
    }
  }
  if (!Array.isArray(samples) || samples.length !== run.sampleCount) {
    throw new Error("sample count does not match completed run");
  }
  const identifiers = samples.map(({ id }) => id);
  if (new Set(identifiers).size !== identifiers.length) {
    throw new Error("benchmark sample IDs must be unique");
  }
  const sortedIdentifiers = [...identifiers].sort();
  const expectedIdentifiers = Array.from(
    { length: run.sampleCount },
    (_, index) => String(index + 1).padStart(4, "0"),
  );
  if (sortedIdentifiers.some((id, index) => id !== expectedIdentifiers[index])) {
    throw new Error("benchmark sample IDs must be continuous from 0001");
  }
  let previousCapturedAt = null;
  for (const sample of [...samples].sort((left, right) => left.id.localeCompare(right.id))) {
    const capturedAt = Date.parse(sample.capturedAt);
    if (!Number.isFinite(capturedAt)
        || capturedAt < startedAt
        || capturedAt > intendedEndAt) {
      throw new Error(`sample ${sample.id} is outside the benchmark sampling window`);
    }
    if (previousCapturedAt !== null && capturedAt < previousCapturedAt) {
      throw new Error("benchmark sample capturedAt must be monotonic");
    }
    previousCapturedAt = capturedAt;
  }
  if (run.lastEvidenceAttemptAt != null) {
    const lastEvidenceAttemptAt = Date.parse(run.lastEvidenceAttemptAt);
    if (!Number.isFinite(lastEvidenceAttemptAt)
        || lastEvidenceAttemptAt < startedAt
        || lastEvidenceAttemptAt > intendedEndAt
        || (previousCapturedAt !== null && lastEvidenceAttemptAt < previousCapturedAt)) {
      throw new Error("benchmark run last evidence attempt is inconsistent");
    }
  }
  const modelFailureCount = samples.filter(
    (sample) => typeof sample.modelError === "string" && sample.modelError.length > 0,
  ).length;
  if (run.modelFailureCount !== modelFailureCount) {
    throw new Error("benchmark run model failure count does not match samples");
  }
  for (const sample of samples) {
    if (!Number.isInteger(sample.modelLatencyMilliseconds)
        || sample.modelLatencyMilliseconds < 0) {
      throw new Error(`sample ${sample.id} model latency is invalid`);
    }
    const hasModelError = typeof sample.modelError === "string"
      && sample.modelError.length > 0;
    if (hasModelError
        && (sample.modelDecision != null || sample.modelConfidence != null)) {
      throw new Error(`sample ${sample.id} model result is inconsistent with model error`);
    }
    if (!hasModelError
        && (!validHumanDecisions.has(sample.modelDecision)
          || !Number.isFinite(sample.modelConfidence)
          || sample.modelConfidence < 0
          || sample.modelConfidence > 1)) {
      throw new Error(`sample ${sample.id} model result is invalid`);
    }
  }
}

function validateReview(
  review,
  samplesByID,
  activityEvidenceValidFromSampleID,
  runRecordSHA256,
) {
  if (review?.kind !== "interruptibility-human-review" || !Array.isArray(review.samples)) {
    throw new Error("invalid human review manifest");
  }
  if (review.sourceRun?.runRecordSHA256 !== runRecordSHA256) {
    throw new Error("run record changed after review preparation");
  }
  const reviewedIDs = review.samples.map(({ id }) => id);
  const sourceIDs = [...samplesByID.keys()];
  if (new Set(reviewedIDs).size !== reviewedIDs.length
      || reviewedIDs.length !== sourceIDs.length
      || [...reviewedIDs].sort().some((id, index) => id !== [...sourceIDs].sort()[index])) {
    throw new Error("human review sample IDs do not match benchmark sample IDs");
  }
  for (const reviewed of review.samples) {
    const source = samplesByID.get(reviewed.id);
    if (reviewed.capturedAt !== source.capturedAt || reviewed.imageFile !== source.imageFile) {
      throw new Error(`human review evidence identity changed for sample ${reviewed.id}`);
    }
    if (reviewed.imageSHA256 !== source.imageSHA256) {
      throw new Error(`human review image digest changed for sample ${reviewed.id}`);
    }
    if (reviewed.sampleRecordSHA256 !== source.sampleRecordSHA256) {
      throw new Error(`sample record changed after review preparation for ${reviewed.id}`);
    }
    if (reviewed.imageSHA256RecordedAtCapture !== source.imageSHA256RecordedAtCapture) {
      throw new Error(`human review image digest origin changed for sample ${reviewed.id}`);
    }
    if (reviewed.contextText
        !== contextTextForReview(source, activityEvidenceValidFromSampleID)) {
      throw new Error(`human review context changed for sample ${reviewed.id}`);
    }
    if (!validHumanDecisions.has(reviewed.humanDecision)) {
      throw new Error(`sample ${reviewed.id} requires a valid humanDecision`);
    }
    if (typeof reviewed.humanRationale !== "string" || reviewed.humanRationale.trim() === "") {
      throw new Error(`sample ${reviewed.id} requires a humanRationale`);
    }
  }
  return [...review.samples].sort((left, right) => left.id.localeCompare(right.id));
}

function modelOutcome(sample) {
  if (validHumanDecisions.has(sample.modelDecision)) return sample.modelDecision;
  return sample.modelError ? "error" : "invalid";
}

/**
 * 旧采样器曾持久化 Swift enum 的完整描述，其中关联值可能来自服务端 reason。
 * 报告只保留可比较的稳定类别；未知历史字符串不能原样进入最终产物。
 */
function stableModelError(value) {
  if (typeof value !== "string" || value === "") return null;
  const currentValues = new Set([
    "invalid_configuration",
    "invalid_request",
    "transport",
    "http_status",
    "invalid_response",
    "invalid_structured_output",
    "incomplete_response",
    "model_failed",
  ]);
  if (currentValues.has(value)) return value;
  const legacyPrefixes = [
    ["invalidConfiguration", "invalid_configuration"],
    ["invalidRequest", "invalid_request"],
    ["transport", "transport"],
    ["httpStatus", "http_status"],
    ["invalidResponse", "invalid_response"],
    ["invalidStructuredOutput", "invalid_structured_output"],
    ["incompleteResponse", "incomplete_response"],
  ];
  return legacyPrefixes.find(([prefix]) => value.startsWith(prefix))?.[1] ?? "model_failed";
}

function contextTextForReview(sample, validFromSampleID) {
  const contextText = sample.contextText ?? null;
  if (contextText === null || !validFromSampleID || sample.id >= validFromSampleID) {
    return contextText;
  }
  const retainedLines = contextText
    .split("\n")
    .filter((line) => !line.startsWith("距最近输入约：") && !line.startsWith("距最近输入："));
  retainedLines.push("距最近输入：不可用（采集器旧版本）");
  return retainedLines.join("\n");
}
