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
        outcome: benchmarkOutcomeForLocalSample(sample),
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
    sampling: localSamplingDescription(),
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
    promptVerifiedConfidenceSummary:
      run.interruptibilityPromptValidFromSampleID == null
        ? null
        : summarizeConfidence(
          reviewedSamples.filter(
            (sample) => sample.id >= run.interruptibilityPromptValidFromSampleID,
          ),
          samplesByID,
        ),
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
      baselinePromptSHA256: run.interruptibilityPromptSHA256 ?? null,
      baselinePromptValidFromSampleID:
        run.interruptibilityPromptValidFromSampleID ?? null,
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
export function createReviewedReplayReport(plan, results, configuration, baselineResults) {
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
  const baselineByID = validateBaselineReplayResults(plan.samples, baselineResults);
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
  const promptVerifiedCases = plan.sourceRun.baselinePromptValidFromSampleID == null
    ? null
    : benchmarkCases.filter(
      (entry) => entry.id >= plan.sourceRun.baselinePromptValidFromSampleID,
    );
  const promptVerifiedSummary = promptVerifiedCases == null
    ? null
    : aggregateBenchmark(promptVerifiedCases);
  return {
    version: 1,
    kind: "interruptibility-reviewed-replay-report",
    generatedAt: new Date().toISOString(),
    sampling: localSamplingDescription(),
    sourceRun: {
      sampleCount: plan.sourceRun.sampleCount,
      baselinePromptSHA256: plan.sourceRun.baselinePromptSHA256,
      baselinePromptValidFromSampleID:
        plan.sourceRun.baselinePromptValidFromSampleID,
    },
    configuration: {
      model: configuration.model,
      endpointHost: configuration.endpointHost,
      promptSHA256: configuration.promptSHA256,
    },
    summary: replaySummary,
    promptVerifiedSummary: promptVerifiedSummary == null
      ? null
      : {
        ...promptVerifiedSummary,
        meanCaseStability: null,
        fullyStableCaseRate: null,
        cases: promptVerifiedSummary.cases.map(
          (entry) => ({ ...entry, stability: null }),
        ),
      },
    confidenceSummary: summarizeReplayConfidence(plan.samples, resultsByID),
    promptVerifiedConfidenceSummary: promptVerifiedCases == null
      ? null
      : summarizeReplayConfidence(
        plan.samples.filter(
          (sample) => sample.id >= plan.sourceRun.baselinePromptValidFromSampleID,
        ),
        resultsByID,
      ),
    pairedComparison: summarizePairedReplay(plan.samples, baselineByID, resultsByID),
    promptVerifiedPairedComparison:
      plan.sourceRun.baselinePromptValidFromSampleID == null
        ? null
        : summarizePairedReplay(
          plan.samples.filter(
            (sample) => sample.id >= plan.sourceRun.baselinePromptValidFromSampleID,
          ),
          baselineByID,
          resultsByID,
        ),
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

/**
 * 从同一批盲审证据的生产与候选报告生成可提交的脱敏汇总。
 * 只复制聚合指标；逐样本理由、模型答案、路径、时间线和服务地址都不能进入公开产物。
 */
export function createPublicBenchmarkReport(comparison, replay) {
  if (comparison?.version !== 1 || typeof comparison.run !== "object") {
    throw new Error("invalid local comparison report");
  }
  if (replay?.version !== 1
      || replay.kind !== "interruptibility-reviewed-replay-report") {
    throw new Error("invalid reviewed replay report");
  }
  if (comparison.run.sampleCount !== replay.sourceRun?.sampleCount) {
    throw new Error("public report inputs must describe the same reviewed run");
  }
  if (comparison.run.interruptibilityPromptSHA256
        !== replay.sourceRun.baselinePromptSHA256
      || comparison.run.interruptibilityPromptValidFromSampleID
        !== replay.sourceRun.baselinePromptValidFromSampleID) {
    throw new Error("public report inputs must use the same baseline prompt");
  }

  const report = {
    version: 1,
    kind: "interruptibility-public-benchmark-report",
    generatedAt: new Date().toISOString(),
    dataset: {
      sampleCount: comparison.run.sampleCount,
      promptVerifiedSampleCount:
        comparison.evidenceIntegrity?.promptVerifiedSampleCount ?? null,
      sampling: publicSampling(comparison.sampling),
      reliability: {
        lockedPollCount: comparison.run.lockedPollCount,
        excludedPollCount: comparison.run.excludedPollCount,
        unavailablePollCount: comparison.run.unavailablePollCount,
        captureFailureCount: comparison.run.captureFailureCount,
        modelFailureCount: comparison.run.modelFailureCount,
      },
    },
    baseline: {
      promptSHA256: comparison.run.interruptibilityPromptSHA256,
      overall: publicAggregate(comparison.summary),
      promptVerified: publicAggregate(comparison.promptVerifiedSummary),
      confidence: publicConfidence(comparison.confidenceSummary),
      promptVerifiedConfidence:
        publicConfidence(comparison.promptVerifiedConfidenceSummary),
    },
    candidate: {
      promptSHA256: replay.configuration?.promptSHA256 ?? null,
      overall: publicAggregate(replay.summary),
      promptVerified: publicAggregate(replay.promptVerifiedSummary),
      confidence: publicConfidence(replay.confidenceSummary),
      promptVerifiedConfidence:
        publicConfidence(replay.promptVerifiedConfidenceSummary),
    },
    paired: publicPairedComparison(replay.pairedComparison),
    promptVerifiedPaired:
      publicPairedComparison(replay.promptVerifiedPairedComparison),
  };
  validatePublicBenchmarkReport(report);
  return report;
}

/**
 * 校验准备提交的公开报告只含既定聚合字段。
 * CI 对仓库内报告调用此函数，手工增加字段不能绕过生成器的隐私白名单。
 */
export function validatePublicBenchmarkReport(report) {
  assertExactObject(report, [
    "version",
    "kind",
    "generatedAt",
    "dataset",
    "baseline",
    "candidate",
    "paired",
    "promptVerifiedPaired",
  ], "public report");
  if (report.version !== 1
      || report.kind !== "interruptibility-public-benchmark-report"
      || !Number.isFinite(Date.parse(report.generatedAt))) {
    throw new Error("public report identity is invalid");
  }
  validatePublicDataset(report.dataset);
  validatePublicModelSummary(report.baseline, "baseline");
  validatePublicModelSummary(report.candidate, "candidate");
  validatePublicPaired(report.paired, "paired");
  validatePublicPaired(report.promptVerifiedPaired, "promptVerifiedPaired", true);
  return report;
}

/** 校验公开数据集元信息；这里不允许出现样本路径、时间线或逐样本证据。 */
function validatePublicDataset(dataset) {
  assertExactObject(dataset, [
    "sampleCount",
    "promptVerifiedSampleCount",
    "sampling",
    "reliability",
  ], "public dataset");
  assertNonnegativeInteger(dataset.sampleCount, "public dataset sampleCount");
  if (dataset.promptVerifiedSampleCount !== null) {
    assertNonnegativeInteger(
      dataset.promptVerifiedSampleCount,
      "public dataset promptVerifiedSampleCount",
    );
    if (dataset.promptVerifiedSampleCount > dataset.sampleCount) {
      throw new Error("public dataset promptVerifiedSampleCount exceeds sampleCount");
    }
  }
  assertExactObject(dataset.sampling, [
    "timeWeighted",
    "consecutiveIdenticalImagesIncluded",
  ], "public sampling");
  if (dataset.sampling.timeWeighted !== false
      || dataset.sampling.consecutiveIdenticalImagesIncluded !== false) {
    throw new Error("public sampling semantics are invalid");
  }
  assertExactObject(dataset.reliability, [
    "lockedPollCount",
    "excludedPollCount",
    "unavailablePollCount",
    "captureFailureCount",
    "modelFailureCount",
  ], "public reliability");
  for (const [name, value] of Object.entries(dataset.reliability)) {
    assertNonnegativeInteger(value, `public reliability ${name}`);
  }
}

/** 校验一个模型版本的公开摘要，并保持基线与候选使用同一结构。 */
function validatePublicModelSummary(summary, label) {
  assertExactObject(summary, [
    "promptSHA256",
    "overall",
    "promptVerified",
    "confidence",
    "promptVerifiedConfidence",
  ], `public ${label}`);
  if (!/^[0-9a-f]{64}$/.test(summary.promptSHA256 ?? "")) {
    throw new Error(`public ${label} prompt SHA-256 is invalid`);
  }
  validatePublicAggregate(summary.overall, `${label} overall`);
  validatePublicAggregate(summary.promptVerified, `${label} promptVerified`, true);
  validatePublicConfidence(summary.confidence, `${label} confidence`);
  validatePublicConfidence(
    summary.promptVerifiedConfidence,
    `${label} promptVerifiedConfidence`,
    true,
  );
}

/** 校验准确率、失败率、延迟与 token 等聚合指标，不接受逐样本明细。 */
function validatePublicAggregate(summary, label, nullable = false) {
  if (nullable && summary === null) return;
  assertExactObject(summary, [
    "caseCount",
    "runCount",
    "correctRunCount",
    "validDecisionCount",
    "accuracy",
    "validDecisionAccuracy",
    "incompleteRate",
    "invalidRate",
    "errorRate",
    "meanCaseStability",
    "fullyStableCaseRate",
    "latencyMs",
    "confusion",
    "tokens",
  ], `public ${label}`);
  for (const field of ["caseCount", "runCount", "correctRunCount", "validDecisionCount"]) {
    assertNonnegativeInteger(summary[field], `public ${label} ${field}`);
  }
  for (const field of [
    "accuracy",
    "validDecisionAccuracy",
    "incompleteRate",
    "invalidRate",
    "errorRate",
  ]) {
    assertRate(summary[field], `public ${label} ${field}`);
  }
  if (summary.meanCaseStability !== null || summary.fullyStableCaseRate !== null) {
    throw new Error(`public ${label} stability must be null for single-observation samples`);
  }
  assertExactObject(summary.latencyMs, ["p50", "p95", "max"], `public ${label} latency`);
  for (const [name, value] of Object.entries(summary.latencyMs)) {
    if (value !== null && (!Number.isFinite(value) || value < 0)) {
      throw new Error(`public ${label} latency ${name} is invalid`);
    }
  }
  assertExactObject(summary.confusion, ["interruptibility"], `public ${label} confusion`);
  validatePublicOutcomeMatrix(summary.confusion.interruptibility, `${label} confusion`);
  if (summary.tokens !== null) validatePublicTokens(summary.tokens, `${label} tokens`);
}

/** 校验置信度聚合；无可用样本时平均值可以为 null。 */
function validatePublicConfidence(confidence, label, nullable = false) {
  if (nullable && confidence === null) return;
  assertExactObject(confidence, [
    "validDecisionCount",
    "correctDecisionCount",
    "incorrectDecisionCount",
    "mean",
    "meanCorrect",
    "meanIncorrect",
  ], `public ${label}`);
  for (const field of [
    "validDecisionCount",
    "correctDecisionCount",
    "incorrectDecisionCount",
  ]) {
    assertNonnegativeInteger(confidence[field], `public ${label} ${field}`);
  }
  for (const field of ["mean", "meanCorrect", "meanIncorrect"]) {
    if (confidence[field] !== null) assertRate(confidence[field], `public ${label} ${field}`);
  }
}

/** 校验 token 与缓存命中率聚合，禁止未知服务端字段进入公开报告。 */
function validatePublicTokens(tokens, label) {
  assertExactObject(tokens, [
    "input",
    "output",
    "reasoning",
    "cachedInput",
    "cacheWrite",
    "tokenCacheHitRate",
    "requestCacheHitRate",
  ], `public ${label}`);
  for (const field of ["input", "output", "reasoning", "cachedInput", "cacheWrite"]) {
    assertNonnegativeInteger(tokens[field], `public ${label} ${field}`);
  }
  assertRate(tokens.tokenCacheHitRate, `public ${label} tokenCacheHitRate`);
  assertRate(tokens.requestCacheHitRate, `public ${label} requestCacheHitRate`);
}

/** 校验基线与候选的配对结果；回归样本 ID 只能留在私有报告。 */
function validatePublicPaired(comparison, label, nullable = false) {
  if (nullable && comparison === null) return;
  assertExactObject(comparison, [
    "sampleCount",
    "bothCorrectCount",
    "bothIncorrectCount",
    "candidateFixedCount",
    "candidateRegressedCount",
    "transitions",
  ], `public ${label}`);
  for (const field of [
    "sampleCount",
    "bothCorrectCount",
    "bothIncorrectCount",
    "candidateFixedCount",
    "candidateRegressedCount",
  ]) {
    assertNonnegativeInteger(comparison[field], `public ${label} ${field}`);
  }
  validatePublicOutcomeMatrix(comparison.transitions, `${label} transitions`, true);
}

/** 校验混淆矩阵或迁移矩阵，只允许产品已经定义的判断结果。 */
function validatePublicOutcomeMatrix(matrix, label, allowFailureRows = false) {
  assertPlainObject(matrix, `public ${label}`);
  const allowedRows = allowFailureRows ? publicOutcomes() : [...validHumanDecisions];
  for (const [row, counts] of Object.entries(matrix)) {
    if (!allowedRows.includes(row)) throw new Error(`public ${label} has unexpected field ${row}`);
    assertPlainObject(counts, `public ${label} ${row}`);
    for (const [outcome, count] of Object.entries(counts)) {
      if (!publicOutcomes().includes(outcome)) {
        throw new Error(`public ${label} ${row} has unexpected field ${outcome}`);
      }
      assertNonnegativeInteger(count, `public ${label} ${row} ${outcome}`);
    }
  }
}

/** 要求对象字段与白名单完全一致，避免新增字段未经审查自动公开。 */
function assertExactObject(value, expectedKeys, label) {
  assertPlainObject(value, label);
  const expected = [...expectedKeys].sort();
  const actual = Object.keys(value).sort();
  const unexpected = actual.find((key) => !expected.includes(key));
  if (unexpected) throw new Error(`${label} has unexpected field ${unexpected}`);
  const missing = expected.find((key) => !actual.includes(key));
  if (missing) throw new Error(`${label} is missing field ${missing}`);
}

/** 排除 null、数组和标量，确保后续字段检查不会被类型强制转换绕过。 */
function assertPlainObject(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
}

/** 计数类公开指标必须是非负整数。 */
function assertNonnegativeInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) throw new Error(`${label} is invalid`);
}

/** 比率类公开指标必须位于闭区间 0 到 1。 */
function assertRate(value, label) {
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`${label} is invalid`);
  }
}

/** 聚合摘要中的 cases 含人工理由，公开报告只能保留汇总数字。 */
function publicAggregate(summary) {
  if (summary == null) return null;
  return {
    caseCount: summary.caseCount,
    runCount: summary.runCount,
    correctRunCount: summary.correctRunCount,
    validDecisionCount: summary.validDecisionCount,
    accuracy: summary.accuracy,
    validDecisionAccuracy: summary.validDecisionAccuracy,
    incompleteRate: summary.incompleteRate,
    invalidRate: summary.invalidRate,
    errorRate: summary.errorRate,
    meanCaseStability: summary.meanCaseStability,
    fullyStableCaseRate: summary.fullyStableCaseRate,
    latencyMs: publicLatency(summary.latencyMs),
    confusion: publicConfusion(summary.confusion),
    tokens: publicTokens(summary.tokens),
  };
}

/** 回归样本 ID 留在私有报告；公开版本只保留数量和三态迁移。 */
function publicPairedComparison(comparison) {
  if (comparison == null) return null;
  return {
    sampleCount: comparison.sampleCount,
    bothCorrectCount: comparison.bothCorrectCount,
    bothIncorrectCount: comparison.bothIncorrectCount,
    candidateFixedCount: comparison.candidateFixedCount,
    candidateRegressedCount: comparison.candidateRegressedCount,
    transitions: publicTransitions(comparison.transitions),
  };
}

function publicSampling(sampling) {
  if (sampling == null) return null;
  return {
    timeWeighted: sampling.timeWeighted,
    consecutiveIdenticalImagesIncluded: sampling.consecutiveIdenticalImagesIncluded,
  };
}

function publicConfidence(confidence) {
  if (confidence == null) return null;
  return {
    validDecisionCount: confidence.validDecisionCount,
    correctDecisionCount: confidence.correctDecisionCount,
    incorrectDecisionCount: confidence.incorrectDecisionCount,
    mean: confidence.mean,
    meanCorrect: confidence.meanCorrect,
    meanIncorrect: confidence.meanIncorrect,
  };
}

function publicLatency(latency) {
  if (latency == null) return null;
  return { p50: latency.p50, p95: latency.p95, max: latency.max };
}

function publicTokens(tokens) {
  if (tokens == null) return null;
  return {
    input: tokens.input,
    output: tokens.output,
    reasoning: tokens.reasoning,
    cachedInput: tokens.cachedInput,
    cacheWrite: tokens.cacheWrite,
    tokenCacheHitRate: tokens.tokenCacheHitRate,
    requestCacheHitRate: tokens.requestCacheHitRate,
  };
}

function publicConfusion(confusion) {
  if (confusion == null) return null;
  const source = confusion.interruptibility ?? {};
  return {
    interruptibility: Object.fromEntries([...validHumanDecisions].flatMap((expected) => {
      const outcomes = publicOutcomeCounts(source[expected]);
      return Object.keys(outcomes).length === 0 ? [] : [[expected, outcomes]];
    })),
  };
}

function publicTransitions(transitions) {
  if (transitions == null) return null;
  return Object.fromEntries(publicOutcomes().flatMap((baseline) => {
    const outcomes = publicOutcomeCounts(transitions[baseline]);
    return Object.keys(outcomes).length === 0 ? [] : [[baseline, outcomes]];
  }));
}

function publicOutcomeCounts(counts) {
  if (counts == null) return {};
  return Object.fromEntries(publicOutcomes().flatMap((outcome) =>
    Number.isInteger(counts[outcome]) && counts[outcome] >= 0
      ? [[outcome, counts[outcome]]]
      : [],
  ));
}

function publicOutcomes() {
  return [...validHumanDecisions, "incomplete", "invalid", "error"];
}

/** 真实采样只保留连续变化后的画面，因此准确率不能解释成用户时间占比分布。 */
function localSamplingDescription() {
  return {
    timeWeighted: false,
    consecutiveIdenticalImagesIncluded: false,
  };
}

/** 与生产比较报告采用同一置信度口径，模型失败不进入平均值。 */
function summarizeReplayConfidence(samples, resultsByID) {
  const decisions = samples.flatMap((sample) => {
    const result = resultsByID.get(sample.id);
    if (!validHumanDecisions.has(result.outcome)) return [];
    return [{
      confidence: result.confidence,
      correct: result.outcome === sample.expected,
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

/** 基线只保留稳定 outcome；候选请求永远不会看到采样时模型的答案。 */
function validateBaselineReplayResults(samples, results) {
  if (!Array.isArray(results)) {
    throw new Error("reviewed replay requires baseline results");
  }
  const resultIDs = results.map(({ id }) => id);
  const expectedIDs = samples.map(({ id }) => id);
  if (new Set(resultIDs).size !== resultIDs.length
      || resultIDs.length !== expectedIDs.length
      || [...resultIDs].sort().some((id, index) => id !== [...expectedIDs].sort()[index])) {
    throw new Error("reviewed replay baseline IDs do not match the frozen plan");
  }
  const validOutcomes = new Set([
    ...validHumanDecisions,
    "incomplete",
    "invalid",
    "error",
  ]);
  for (const result of results) {
    if (!validOutcomes.has(result.outcome)) {
      throw new Error(`reviewed replay baseline ${result.id} outcome is invalid`);
    }
  }
  return new Map(results.map((result) => [result.id, result]));
}

/** 配对比较揭示总准确率背后的修复与回归，避免一增一减被汇总数字抵消。 */
function summarizePairedReplay(samples, baselineByID, candidateByID) {
  const comparison = {
    sampleCount: samples.length,
    bothCorrectCount: 0,
    bothIncorrectCount: 0,
    candidateFixedCount: 0,
    candidateRegressedCount: 0,
    transitions: {},
    regressions: [],
  };
  for (const sample of samples) {
    const baseline = baselineByID.get(sample.id).outcome;
    const candidate = candidateByID.get(sample.id).outcome;
    const baselineCorrect = baseline === sample.expected;
    const candidateCorrect = candidate === sample.expected;
    if (baselineCorrect && candidateCorrect) comparison.bothCorrectCount += 1;
    else if (!baselineCorrect && !candidateCorrect) comparison.bothIncorrectCount += 1;
    else if (!baselineCorrect && candidateCorrect) comparison.candidateFixedCount += 1;
    else {
      comparison.candidateRegressedCount += 1;
      comparison.regressions.push({
        id: sample.id,
        humanDecision: sample.expected,
        baselineDecision: baseline,
        candidateDecision: candidate,
      });
    }
    comparison.transitions[baseline] ??= {};
    comparison.transitions[baseline][candidate] =
      (comparison.transitions[baseline][candidate] ?? 0) + 1;
  }
  comparison.transitions = Object.fromEntries(
    Object.entries(comparison.transitions)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([baseline, candidates]) => [baseline, Object.fromEntries(
        Object.entries(candidates).sort(([left], [right]) => left.localeCompare(right)),
      )]),
  );
  return comparison;
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
  const mean = entries.reduce((sum, entry) => sum + entry.confidence, 0) / entries.length;
  // JSON 报告用于稳定回归比较；消除二进制浮点噪声，但保留模型置信度的有效精度。
  return Number(mean.toFixed(12));
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

/**
 * 将生产采样器的稳定错误类别映射为固定 benchmark 的三类失败 outcome。
 * 生产报告和候选回放基线必须共用这一口径，否则两份失败率无法直接比较。
 */
export function benchmarkOutcomeForLocalSample(sample) {
  if (validHumanDecisions.has(sample.modelDecision)) return sample.modelDecision;
  const stableError = stableModelError(sample.modelError);
  if (stableError === "incomplete_response") return "incomplete";
  if (["invalid_response", "invalid_structured_output"].includes(stableError)) {
    return "invalid";
  }
  return stableError === null ? "invalid" : "error";
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
