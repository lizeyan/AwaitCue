import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import {
  access,
  chmod,
  link,
  mkdtemp,
  readFile,
  rm,
  stat,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  compareHumanReview,
  createHumanReviewManifest,
  createReviewedReplayPlan,
  createReviewedReplayReport,
} from "../lib/local-review.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

test("人工复核清单只在采样完成后生成且不泄露模型结论", () => {
  const running = benchmarkRun("running", 1);
  assert.throws(
    () => createHumanReviewManifest(running, [benchmarkSample("0001")]),
    /must be completed/,
  );

  const manifest = createHumanReviewManifest(
    benchmarkRun("completed", 1),
    [benchmarkSample("0001")],
  );
  const serialized = JSON.stringify(manifest);

  assert.deepEqual(manifest.samples, [{
    id: "0001",
    capturedAt: "2026-11-17T06:12:02Z",
    contextText: "前台应用：ChatGPT\n距最近输入约：1 秒",
    imageFile: "samples/0001.jpg",
    imageSHA256: "a".repeat(64),
    sampleRecordSHA256: "b".repeat(64),
    imageSHA256RecordedAtCapture: true,
    humanDecision: null,
    humanRationale: null,
  }]);
  assert.doesNotMatch(serialized, /modelDecision|modelConfidence|modelLatency|modelError/);
  assert.doesNotMatch(serialized, /notInterruptible|0\.98|3285/);
});

test("候选 prompt 回放只接受冻结标签且报告不复制原始证据", () => {
  const run = benchmarkRun("completed", 1);
  const samples = [benchmarkSample("0001")];
  const incompleteReview = createHumanReviewManifest(run, samples);

  assert.throws(
    () => createReviewedReplayPlan(run, samples, incompleteReview),
    /requires a valid humanDecision/,
  );

  const review = {
    ...incompleteReview,
    samples: [{
      ...incompleteReview.samples[0],
      humanDecision: "notInterruptible",
      humanRationale: "正在编辑技术内容，需要持续专注。",
    }],
  };
  const plan = createReviewedReplayPlan(run, samples, review);
  assert.equal(plan.samples[0].expected, "notInterruptible");
  assert.doesNotMatch(JSON.stringify(plan), /modelDecision|modelConfidence|modelLatency/);

  const report = createReviewedReplayReport(plan, [{
    id: "0001",
    outcome: "notInterruptible",
    confidence: 0.93,
    durationMs: 1200,
    usage: {
      inputTokens: 100,
      outputTokens: 20,
      reasoningTokens: 0,
      cachedTokens: 10,
      cacheWriteTokens: 0,
    },
  }], {
    model: "decision-model",
    endpointHost: "model.example",
    promptSHA256: "d".repeat(64),
  }, [{
    id: "0001",
    outcome: "interruptible",
  }]);
  assert.equal(report.summary.accuracy, 1);
  assert.equal(report.summary.meanCaseStability, null);
  assert.equal(report.summary.tokens.input, 100);
  assert.equal(report.samples[0].correct, true);
  assert.deepEqual(report.pairedComparison, {
    sampleCount: 1,
    bothCorrectCount: 0,
    bothIncorrectCount: 0,
    candidateFixedCount: 1,
    candidateRegressedCount: 0,
    transitions: {
      interruptible: { notInterruptible: 1 },
    },
    regressions: [],
  });
  assert.equal(report.sourceRun.baselinePromptSHA256, "a".repeat(64));
  assert.equal(report.sourceRun.baselinePromptValidFromSampleID, "0001");
  assert.equal(report.sourceRun.sampleCount, 1);
  assert.equal("runRecordSHA256" in report.sourceRun, false);
  assert.deepEqual(report.promptVerifiedPairedComparison, report.pairedComparison);
  assert.doesNotMatch(JSON.stringify(report), /contextText|imageFile|imageSHA256|ChatGPT/);
});

test("候选回放单独汇总生产 prompt 有效边界内的准确率", () => {
  const plan = {
    version: 1,
    kind: "interruptibility-reviewed-replay-plan",
    sourceRun: {
      runRecordSHA256: "c".repeat(64),
      sampleCount: 2,
      baselinePromptSHA256: "a".repeat(64),
      baselinePromptValidFromSampleID: "0002",
    },
    samples: [
      { id: "0001", expected: "interruptible", description: "被动阅读。" },
      { id: "0002", expected: "notInterruptible", description: "正在写作。" },
    ],
  };
  const report = createReviewedReplayReport(
    plan,
    [
      { id: "0001", outcome: "notInterruptible", confidence: 0.8, durationMs: 100 },
      { id: "0002", outcome: "notInterruptible", confidence: 0.9, durationMs: 120 },
    ],
    {
      model: "decision-model",
      endpointHost: "model.example",
      promptSHA256: "d".repeat(64),
    },
    [
      { id: "0001", outcome: "interruptible" },
      { id: "0002", outcome: "notInterruptible" },
    ],
  );

  assert.equal(report.summary.accuracy, 0.5);
  assert.equal(report.promptVerifiedSummary.caseCount, 1);
  assert.equal(report.promptVerifiedSummary.accuracy, 1);
  assert.equal(report.promptVerifiedSummary.cases[0].id, "0002");
  assert.deepEqual(report.confidenceSummary, {
    validDecisionCount: 2,
    correctDecisionCount: 1,
    incorrectDecisionCount: 1,
    mean: 0.85,
    meanCorrect: 0.9,
    meanIncorrect: 0.8,
  });
  assert.deepEqual(report.promptVerifiedConfidenceSummary, {
    validDecisionCount: 1,
    correctDecisionCount: 1,
    incorrectDecisionCount: 0,
    mean: 0.9,
    meanCorrect: 0.9,
    meanIncorrect: null,
  });
});

test("提前标记完成的 run 不能冒充完整 24 小时采样", () => {
  const premature = benchmarkRun("completed", 1);
  premature.completedAt = "2026-11-18T05:40:00Z";

  assert.throws(
    () => createHumanReviewManifest(premature, [benchmarkSample("0001")]),
    /intended end time/,
  );
});

test("计划时长不足 24 小时的 run 不能进入人工复核", () => {
  const shortRun = benchmarkRun("completed", 1);
  shortRun.intendedEndAt = "2026-11-17T06:48:37Z";
  shortRun.completedAt = "2026-11-17T06:48:38Z";

  assert.throws(
    () => createHumanReviewManifest(shortRun, [benchmarkSample("0001")]),
    /at least 24 hours/,
  );
});

test("样本编号必须从 0001 连续到 run.sampleCount", () => {
  const run = benchmarkRun("completed", 2);

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001"),
      benchmarkSample("9999"),
    ]),
    /continuous from 0001/,
  );
});

test("采样窗口之外的样本不能进入人工复核", () => {
  const run = benchmarkRun("completed", 1);

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", { capturedAt: "2026-11-17T05:48:36Z" }),
    ]),
    /outside the benchmark sampling window/,
  );
});

test("计划截止时间之后形成的样本不能进入人工复核", () => {
  const run = benchmarkRun("completed", 1);

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", { capturedAt: "2026-11-18T05:48:38Z" }),
    ]),
    /outside the benchmark sampling window/,
  );
});

test("样本时间必须按连续编号单调递增", () => {
  const run = benchmarkRun("completed", 2);

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", { capturedAt: "2026-11-17T06:10:00Z" }),
      benchmarkSample("0002", { capturedAt: "2026-11-17T06:05:00Z" }),
    ]),
    /capturedAt must be monotonic/,
  );
});

test("最后证据尝试不能早于最后样本或超出 run 窗口", () => {
  const run = benchmarkRun("completed", 1);
  run.lastEvidenceAttemptAt = "2026-11-17T06:00:00Z";

  assert.throws(
    () => createHumanReviewManifest(run, [benchmarkSample("0001")]),
    /last evidence attempt/,
  );
});

test("计划截止时间之后不能再开始屏幕证据尝试", () => {
  const run = benchmarkRun("completed", 1);
  run.lastEvidenceAttemptAt = "2026-11-18T05:48:38Z";

  assert.throws(
    () => createHumanReviewManifest(run, [benchmarkSample("0001")]),
    /last evidence attempt/,
  );
});

test("run 的模型失败计数必须与样本错误一致", () => {
  const run = benchmarkRun("completed", 1);
  run.modelFailureCount = 0;

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", {
        modelDecision: null,
        modelConfidence: null,
        modelError: "transport",
      }),
    ]),
    /model failure count/,
  );
});

test("模型失败样本不能同时声称存在判断或置信度", () => {
  const run = benchmarkRun("completed", 1);
  run.modelFailureCount = 1;

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", {
        modelDecision: "interruptible",
        modelConfidence: 0.99,
        modelError: "transport",
      }),
    ]),
    /model result is inconsistent/,
  );
});

test("无模型错误的样本必须包含合法决定和置信度", () => {
  const run = benchmarkRun("completed", 1);

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", { modelDecision: "unknown", modelConfidence: 1.2 }),
    ]),
    /model result is invalid/,
  );
});

test("模型端到端耗时必须是非负整数", () => {
  const run = benchmarkRun("completed", 1);

  assert.throws(
    () => createHumanReviewManifest(run, [
      benchmarkSample("0001", { modelLatencyMilliseconds: -1 }),
    ]),
    /model latency is invalid/,
  );
});

test("run 记录的忙闲 prompt 摘要必须是完整 SHA-256", () => {
  const run = benchmarkRun("completed", 1);
  run.interruptibilityPromptSHA256 = "not-a-digest";

  assert.throws(
    () => createHumanReviewManifest(run, [benchmarkSample("0001")]),
    /prompt SHA-256/,
  );
});

test("忙闲 prompt 摘要与有效样本边界必须成对且位于样本范围内", () => {
  const missingBoundary = benchmarkRun("completed", 1);
  missingBoundary.interruptibilityPromptValidFromSampleID = null;
  assert.throws(
    () => createHumanReviewManifest(missingBoundary, [benchmarkSample("0001")]),
    /prompt validity boundary/,
  );

  const impossibleBoundary = benchmarkRun("completed", 1);
  impossibleBoundary.interruptibilityPromptValidFromSampleID = "0003";
  assert.throws(
    () => createHumanReviewManifest(impossibleBoundary, [benchmarkSample("0001")]),
    /prompt validity boundary/,
  );
});

test("复核清单自动隐藏修复前样本的错误输入活动秒数", () => {
  const run = benchmarkRun("completed", 2);
  run.activityEvidenceValidFromSampleID = "0002";
  const manifest = createHumanReviewManifest(run, [
    benchmarkSample("0001", {
      contextText: "前台应用：微信\n距最近输入约：127385 秒",
    }),
    benchmarkSample("0002", {
      contextText: "前台应用：飞书\n距最近输入约：1 秒",
    }),
  ]);

  assert.equal(
    manifest.samples[0].contextText,
    "前台应用：微信\n距最近输入：不可用（采集器旧版本）",
  );
  assert.equal(manifest.samples[1].contextText, "前台应用：飞书\n距最近输入约：1 秒");
});

test("人工标签完整后才比较准确率、混淆矩阵和延迟", () => {
  const run = benchmarkRun("completed", 3);
  run.captureFailureCount = 1;
  run.modelFailureCount = 1;
  run.unavailablePollCount = 4;
  run.activityEvidenceValidFromSampleID = "0002";
  run.lastEvidenceAttemptAt = "2026-11-17T06:12:02Z";
  run.availabilityClassificationValidFrom = "2026-11-17T06:09:00Z";
  run.lastCaptureFailureCode = "target_unavailable";
  run.lastCaptureFailureAt = "2026-11-17T06:10:00Z";
  const samples = [
    benchmarkSample("0001", {
      modelDecision: "notInterruptible",
      modelLatencyMilliseconds: 120,
    }),
    benchmarkSample("0002", {
      modelDecision: "uncertain",
      modelLatencyMilliseconds: 300,
    }),
    benchmarkSample("0003", {
      modelDecision: null,
      modelConfidence: null,
      modelError: "transport",
      modelLatencyMilliseconds: 500,
    }),
  ];
  const review = createHumanReviewManifest(run, samples);
  review.samples[0].humanDecision = "notInterruptible";
  review.samples[0].humanRationale = "正在编辑技术内容，需要持续专注。";
  review.samples[1].humanDecision = "interruptible";
  review.samples[1].humanRationale = "只是在阅读普通资讯，可以被打断。";
  review.samples[2].humanDecision = "interruptible";
  review.samples[2].humanRationale = "界面处于等待状态，没有进行输入。";

  const report = compareHumanReview(run, samples, review);

  assert.equal(report.summary.caseCount, 3);
  assert.equal(report.summary.runCount, 3);
  assert.equal(report.summary.correctRunCount, 1);
  assert.equal(report.summary.accuracy, 1 / 3);
  assert.equal(report.summary.errorRate, 1 / 3);
  assert.equal(report.summary.meanCaseStability, null);
  assert.equal(report.summary.fullyStableCaseRate, null);
  assert.equal(report.summary.tokens, null);
  assert.ok(report.summary.cases.every(({ stability }) => stability === null));
  assert.deepEqual(report.summary.latencyMs, { p50: 300, p95: 500, max: 500 });
  assert.deepEqual(report.summary.confusion.interruptibility.interruptible, {
    error: 1,
    uncertain: 1,
  });
  assert.deepEqual(report.summary.confusion.interruptibility.notInterruptible, {
    notInterruptible: 1,
  });
  assert.equal(report.samples[0].humanRationale, "正在编辑技术内容，需要持续专注。");
  assert.equal(report.samples[0].modelDecision, "notInterruptible");
  assert.equal(report.run.captureFailureCount, 1);
  assert.equal(report.run.unavailablePollCount, 4);
  assert.equal(report.run.lastEvidenceAttemptAt, "2026-11-17T06:12:02Z");
  assert.equal(report.run.interruptibilityPromptSHA256, "a".repeat(64));
  assert.equal(report.run.interruptibilityPromptValidFromSampleID, "0001");
  assert.equal(report.run.activityEvidenceValidFromSampleID, "0002");
  assert.equal(
    report.run.availabilityClassificationValidFrom,
    "2026-11-17T06:09:00Z",
  );
  assert.equal(report.run.lastCaptureFailureCode, "target_unavailable");
  assert.equal(report.run.lastCaptureFailureAt, "2026-11-17T06:10:00Z");
  assert.deepEqual(report.evidenceIntegrity, {
    sampleCount: 3,
    captureTimeDigestCount: 3,
    reviewPreparationDigestCount: 0,
    promptVerifiedSampleCount: 3,
  });
  const serializedReport = JSON.stringify(report);
  assert.doesNotMatch(
    serializedReport,
    /"(?:contextText|imageFile|imageSHA256|sampleRecordSHA256|runRecordSHA256)":/,
  );
});

test("比较报告展示真实采样时间范围和间隔分布", () => {
  const run = benchmarkRun("completed", 3);
  const samples = [
    benchmarkSample("0001", { capturedAt: "2026-11-17T05:50:00Z" }),
    benchmarkSample("0002", { capturedAt: "2026-11-17T05:55:00Z" }),
    benchmarkSample("0003", { capturedAt: "2026-11-17T06:05:00Z" }),
  ];
  const review = createHumanReviewManifest(run, samples);
  for (const sample of review.samples) {
    sample.humanDecision = "notInterruptible";
    sample.humanRationale = "正在编辑技术内容，需要持续专注。";
  }

  const report = compareHumanReview(run, samples, review);

  assert.deepEqual(report.samplingTimeline, {
    firstCapturedAt: "2026-11-17T05:50:00Z",
    lastCapturedAt: "2026-11-17T06:05:00Z",
    startDelayMilliseconds: 83_000,
    endGapMilliseconds: 85_417_000,
    observedSpanMilliseconds: 900_000,
    gapMilliseconds: {
      p50: 300_000,
      p95: 600_000,
      max: 600_000,
    },
  });
});

test("比较报告单独汇总已记录 prompt 范围内的准确率", () => {
  const run = benchmarkRun("completed", 3);
  run.interruptibilityPromptValidFromSampleID = "0002";
  run.modelFailureCount = 1;
  const samples = [
    benchmarkSample("0001", { modelDecision: "notInterruptible" }),
    benchmarkSample("0002", { modelDecision: "interruptible" }),
    benchmarkSample("0003", {
      modelDecision: null,
      modelConfidence: null,
      modelError: "transport",
    }),
  ];
  const review = createHumanReviewManifest(run, samples);
  for (const sample of review.samples) {
    sample.humanDecision = sample.id === "0001" ? "notInterruptible" : "interruptible";
    sample.humanRationale = "依据可见活动独立完成的人工判断。";
  }

  const report = compareHumanReview(run, samples, review);

  assert.equal(report.summary.caseCount, 3);
  assert.equal(report.promptVerifiedSummary.caseCount, 2);
  assert.equal(report.promptVerifiedSummary.correctRunCount, 1);
  assert.equal(report.promptVerifiedSummary.accuracy, 0.5);
  assert.equal(report.promptVerifiedSummary.errorRate, 0.5);
  assert.equal(report.promptVerifiedSummary.meanCaseStability, null);
  assert.equal(report.promptVerifiedSummary.tokens, null);
  assert.deepEqual(report.promptVerifiedConfidenceSummary, {
    validDecisionCount: 1,
    correctDecisionCount: 1,
    incorrectDecisionCount: 0,
    mean: 0.98,
    meanCorrect: 0.98,
    meanIncorrect: null,
  });
});

test("比较报告分别汇总正确与错误判断的平均置信度", () => {
  const run = benchmarkRun("completed", 3);
  const samples = [
    benchmarkSample("0001", {
      modelDecision: "notInterruptible",
      modelConfidence: 0.9,
    }),
    benchmarkSample("0002", {
      modelDecision: "interruptible",
      modelConfidence: 0.8,
    }),
    benchmarkSample("0003", {
      modelDecision: "uncertain",
      modelConfidence: 0.6,
    }),
  ];
  const review = createHumanReviewManifest(run, samples);
  review.samples[0].humanDecision = "notInterruptible";
  review.samples[1].humanDecision = "notInterruptible";
  review.samples[2].humanDecision = "uncertain";
  for (const sample of review.samples) {
    sample.humanRationale = "依据可见活动独立完成的人工判断。";
  }

  const report = compareHumanReview(run, samples, review);

  assert.deepEqual(report.confidenceSummary, {
    validDecisionCount: 3,
    correctDecisionCount: 2,
    incorrectDecisionCount: 1,
    mean: 0.766666666667,
    meanCorrect: (0.9 + 0.6) / 2,
    meanIncorrect: 0.8,
  });
});

test("比较报告不会复制旧样本中的服务端错误 reason", () => {
  const run = benchmarkRun("completed", 1);
  run.modelFailureCount = 1;
  const samples = [benchmarkSample("0001", {
    modelDecision: null,
    modelConfidence: null,
    modelError: 'incompleteResponse(Optional("sensitive-server-reason"))',
  })];
  const review = createHumanReviewManifest(run, samples);
  review.samples[0].humanDecision = "interruptible";
  review.samples[0].humanRationale = "界面处于等待状态，可以被打断。";

  const report = compareHumanReview(run, samples, review);

  assert.equal(report.samples[0].modelError, "incomplete_response");
  assert.doesNotMatch(JSON.stringify(report), /sensitive-server-reason/);
  assert.equal(report.summary.errorRate, 1);
});

test("缺失人工标签或样本集合不一致时拒绝生成比较报告", () => {
  const run = benchmarkRun("completed", 1);
  const samples = [benchmarkSample("0001")];
  const incomplete = createHumanReviewManifest(run, samples);
  assert.throws(
    () => compareHumanReview(run, samples, incomplete),
    /humanDecision/,
  );

  const extra = createHumanReviewManifest(run, samples);
  extra.samples[0].humanDecision = "interruptible";
  extra.samples[0].humanRationale = "普通阅读，可以被打断。";
  extra.samples.push({ ...extra.samples[0], id: "9999" });
  assert.throws(
    () => compareHumanReview(run, samples, extra),
    /sample IDs/,
  );
});

test("人工复核期间不能修改截图对应的活动上下文", () => {
  const run = benchmarkRun("completed", 1);
  const samples = [benchmarkSample("0001")];
  const review = createHumanReviewManifest(run, samples);
  review.samples[0].contextText = "前台应用：已被修改\n距最近输入约：999 秒";
  review.samples[0].humanDecision = "interruptible";
  review.samples[0].humanRationale = "普通阅读，可以被打断。";

  assert.throws(
    () => compareHumanReview(run, samples, review),
    /review context changed/,
  );
});

test("复核命令拒绝权限过宽的本机证据文件", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-private-review-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o644);

    const outputPath = path.join(directory, "human-review.json");
    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        outputPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /private file permissions/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("复核命令拒绝存在额外硬链接的本机证据文件", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-linked-evidence-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o600);
    await link(imagePath, path.join(directory, "linked-image.jpg"));

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        path.join(directory, "human-review.json"),
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not have additional hard links/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("复核命令拒绝权限过宽的本机证据目录", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-private-directory-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o600);
    await chmod(samplesDirectory, 0o700);
    await chmod(directory, 0o755);

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        path.join(directory, "human-review.json"),
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /private directory permissions/);
  } finally {
    await chmod(directory, 0o700);
    await rm(directory, { recursive: true, force: true });
  }
});

test("人工复核清单必须与 run.json 保存在同一私有目录", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-review-root-"));
  const outsideDirectory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-review-outside-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(directory, 0o700);
    await chmod(samplesDirectory, 0o700);
    await chmod(outsideDirectory, 0o700);
    await writeFile(
      path.join(directory, "run.json"),
      JSON.stringify(benchmarkRun("completed", 1)),
    );
    await writeFile(
      path.join(samplesDirectory, "0001.json"),
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(path.join(directory, "run.json"), 0o600);
    await chmod(path.join(samplesDirectory, "0001.json"), 0o600);
    await chmod(path.join(samplesDirectory, "0001.jpg"), 0o600);
    const outputPath = path.join(outsideDirectory, "human-review.json");

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        outputPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must be stored in the benchmark run directory/);
    assert.equal(await access(outputPath).then(() => true, () => false), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
    await rm(outsideDirectory, { recursive: true, force: true });
  }
});

test("比较与回放报告必须保存在私有 run 目录", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-report-root-"));
  const outsideDirectory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-report-outside-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(directory, 0o700);
    await chmod(samplesDirectory, 0o700);
    await chmod(outsideDirectory, 0o700);
    await writeFile(
      path.join(directory, "run.json"),
      JSON.stringify(benchmarkRun("completed", 1)),
    );
    await writeFile(
      path.join(samplesDirectory, "0001.json"),
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(path.join(directory, "run.json"), 0o600);
    await chmod(path.join(samplesDirectory, "0001.json"), 0o600);
    await chmod(path.join(samplesDirectory, "0001.jpg"), 0o600);
    const reviewPath = path.join(directory, "human-review.json");
    const prepare = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(prepare.status, 0, prepare.stderr);
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    review.samples[0].humanDecision = "notInterruptible";
    review.samples[0].humanRationale = "正在编辑内容，需要持续专注。";
    await writeFile(reviewPath, JSON.stringify(review));
    await chmod(reviewPath, 0o600);

    const reportPath = path.join(outsideDirectory, "comparison-report.json");
    const report = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        reportPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(report.status, 0);
    assert.match(report.stderr, /must be stored in the benchmark run directory/);
    assert.equal(await access(reportPath).then(() => true, () => false), false);

    const promptPath = path.join(directory, "candidate-prompt.txt");
    await writeFile(promptPath, "只判断是否适合打断。\n", { mode: 0o600 });
    const replayPath = path.join(outsideDirectory, "candidate-replay.json");
    const replay = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "replay",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--prompt",
        promptPath,
        "--output",
        replayPath,
        "--base-url",
        "https://model.example/v1",
        "--model",
        "decision-model",
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(replay.status, 0);
    assert.match(replay.stderr, /must be stored in the benchmark run directory/);
    assert.doesNotMatch(replay.stderr, /AWAITCUE_API_KEY/);
    assert.equal(await access(replayPath).then(() => true, () => false), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
    await rm(outsideDirectory, { recursive: true, force: true });
  }
});

test("比较报告拒绝权限过宽的人工复核文件", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-private-report-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o600);
    const reviewPath = path.join(directory, "human-review.json");
    const prepare = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(prepare.status, 0, prepare.stderr);
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    review.samples[0].humanDecision = "notInterruptible";
    review.samples[0].humanRationale = "正在编辑内容，需要持续专注。";
    await writeFile(reviewPath, JSON.stringify(review));
    await chmod(reviewPath, 0o644);

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        path.join(directory, "comparison-report.json"),
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /human review must use private file permissions/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("比较报告不能覆盖人工复核或采样输入文件", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-output-conflict-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o600);
    const reviewPath = path.join(directory, "human-review.json");
    const prepare = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(prepare.status, 0, prepare.stderr);
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    review.samples[0].humanDecision = "notInterruptible";
    review.samples[0].humanRationale = "正在编辑内容，需要持续专注。";
    const originalReview = JSON.stringify(review);
    await writeFile(reviewPath, originalReview);
    await chmod(reviewPath, 0o600);

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /output path conflicts with an input file/);
    assert.equal(await readFile(reviewPath, "utf8"), originalReview);

    const originalRun = await readFile(runPath, "utf8");
    const runConflict = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        runPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(runConflict.status, 0);
    assert.match(runConflict.stderr, /output path conflicts with an input file/);
    assert.equal(await readFile(runPath, "utf8"), originalRun);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("比较报告拒绝人工复核文件的硬链接别名且不覆盖原文件", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-hardlink-conflict-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o600);
    const reviewPath = path.join(directory, "human-review.json");
    const prepare = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(prepare.status, 0, prepare.stderr);
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    review.samples[0].humanDecision = "notInterruptible";
    review.samples[0].humanRationale = "正在编辑内容，需要持续专注。";
    const originalReview = JSON.stringify(review);
    await writeFile(reviewPath, originalReview);
    await chmod(reviewPath, 0o600);
    const hardLinkOutput = path.join(directory, "comparison-report.json");
    await link(reviewPath, hardLinkOutput);

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        hardLinkOutput,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /human review must not have additional hard links/);
    assert.equal(await readFile(reviewPath, "utf8"), originalReview);

    await unlink(hardLinkOutput);
    const unrelatedVictim = path.join(directory, "unrelated-victim.txt");
    await writeFile(unrelatedVictim, "必须保留的无关内容", { mode: 0o600 });
    await link(unrelatedVictim, hardLinkOutput);
    const unrelatedHardLink = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        hardLinkOutput,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(unrelatedHardLink.status, 0);
    assert.match(unrelatedHardLink.stderr, /output file must not have additional hard links/);
    assert.equal(await readFile(unrelatedVictim, "utf8"), "必须保留的无关内容");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("比较报告拒绝 prepare 后变化的 run 元数据", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-run-anchor-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    const runPath = path.join(directory, "run.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const imagePath = path.join(samplesDirectory, "0001.jpg");
    await writeFile(runPath, JSON.stringify(benchmarkRun("completed", 1)));
    await writeFile(
      samplePath,
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    await writeFile(imagePath, Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(runPath, 0o600);
    await chmod(samplePath, 0o600);
    await chmod(imagePath, 0o600);
    const reviewPath = path.join(directory, "human-review.json");
    const prepare = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(prepare.status, 0, prepare.stderr);
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    review.samples[0].humanDecision = "notInterruptible";
    review.samples[0].humanRationale = "正在编辑内容，需要持续专注。";
    await writeFile(reviewPath, JSON.stringify(review));
    await chmod(reviewPath, 0o600);
    const changedRun = JSON.parse(await readFile(runPath, "utf8"));
    changedRun.lockedPollCount = 999;
    await writeFile(runPath, JSON.stringify(changedRun));
    await chmod(runPath, 0o600);

    const result = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        path.join(directory, "comparison-report.json"),
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );

    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /run record changed after review preparation/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("命令行从真实采样目录生成私有复核清单并在填写后输出报告", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-local-review-"));
  try {
    const samplesDirectory = path.join(directory, "samples");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(samplesDirectory));
    await chmod(samplesDirectory, 0o700);
    await writeFile(
      path.join(directory, "run.json"),
      JSON.stringify(benchmarkRun("completed", 1)),
    );
    await writeFile(
      path.join(samplesDirectory, "0001.json"),
      JSON.stringify(benchmarkSample("0001", {
        imageFile: "samples/other.jpg",
        imageSHA256: undefined,
      })),
    );
    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0xff]));
    await writeFile(path.join(samplesDirectory, "other.jpg"), Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(path.join(directory, "run.json"), 0o600);
    await chmod(path.join(samplesDirectory, "0001.json"), 0o600);
    await chmod(path.join(samplesDirectory, "0001.jpg"), 0o600);
    await chmod(path.join(samplesDirectory, "other.jpg"), 0o600);
    const mismatchedReviewPath = path.join(directory, "mismatched-review.json");
    const mismatchedEvidence = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        mismatchedReviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(mismatchedEvidence.status, 0);
    assert.match(mismatchedEvidence.stderr, /canonical sample identity/);

    await writeFile(
      path.join(samplesDirectory, "0001.json"),
      JSON.stringify(benchmarkSample("0001", { imageSHA256: undefined })),
    );
    const reviewPath = path.join(directory, "human-review.json");
    const prepare = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "prepare",
        "--run-directory",
        directory,
        "--output",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(prepare.status, 0, prepare.stderr);
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    assert.equal(review.samples[0].humanDecision, null);
    assert.match(review.samples[0].imageSHA256, /^[0-9a-f]{64}$/);
    assert.match(review.samples[0].sampleRecordSHA256, /^[0-9a-f]{64}$/);
    assert.equal(review.samples[0].imageSHA256RecordedAtCapture, false);
    assert.doesNotMatch(JSON.stringify(review), /modelDecision/);
    assert.equal((await stat(reviewPath)).mode & 0o777, 0o600);

    const emptyStatus = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "status",
        "--review",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(emptyStatus.status, 0, emptyStatus.stderr);
    assert.deepEqual(JSON.parse(emptyStatus.stdout), {
      totalSampleCount: 1,
      completedSampleCount: 0,
      remainingSampleCount: 1,
      labelCounts: {
        interruptible: 0,
        notInterruptible: 0,
        uncertain: 0,
      },
      nextIncompleteSampleID: "0001",
    });
    assert.doesNotMatch(emptyStatus.stdout, /model|contextText|imageFile/);

    const replayPromptPath = path.join(directory, "candidate-prompt.txt");
    const replayReportPath = path.join(directory, "candidate-replay.json");
    await writeFile(replayPromptPath, "只判断是否适合打断。\n", { mode: 0o600 });
    const prematureReplay = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "replay",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--prompt",
        replayPromptPath,
        "--output",
        replayReportPath,
        "--base-url",
        "https://model.example/v1",
        "--model",
        "decision-model",
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(prematureReplay.status, 0);
    assert.match(prematureReplay.stderr, /requires a valid humanDecision/);
    await assert.rejects(access(replayReportPath));

    const next = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "next",
        "--review",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(next.status, 0, next.stderr);
    assert.deepEqual(JSON.parse(next.stdout), {
      id: "0001",
      capturedAt: "2026-11-17T06:12:02Z",
      contextText: "前台应用：ChatGPT\n距最近输入约：1 秒",
      imagePath: path.join(directory, "samples/0001.jpg"),
    });
    assert.doesNotMatch(
      next.stdout,
      /modelDecision|modelConfidence|modelLatency|modelError|sampleRecordSHA256|runRecordSHA256/,
    );
    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0x00]));
    const changedNextEvidence = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "next",
        "--review",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(changedNextEvidence.status, 0);
    assert.match(changedNextEvidence.stderr, /image digest changed/);
    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0xff]));
    await chmod(path.join(samplesDirectory, "0001.jpg"), 0o600);

    const label = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "label",
        "--review",
        reviewPath,
        "--id",
        "0001",
        "--decision",
        "notInterruptible",
        "--rationale",
        "正在编辑技术内容，需要持续专注。",
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(label.status, 0, label.stderr);
    assert.equal(label.stdout, "Labeled 0001.\n");
    assert.doesNotMatch(label.stdout, /model|contextText|imageFile|正在编辑/);
    const labeledReview = JSON.parse(await readFile(reviewPath, "utf8"));
    assert.deepEqual(labeledReview, {
      ...review,
      samples: [{
        ...review.samples[0],
        humanDecision: "notInterruptible",
        humanRationale: "正在编辑技术内容，需要持续专注。",
      }],
    });
    assert.equal((await stat(reviewPath)).mode & 0o777, 0o600);

    const labeledBytes = await readFile(reviewPath);
    const duplicateLabel = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "label",
        "--review",
        reviewPath,
        "--id",
        "0001",
        "--decision",
        "interruptible",
        "--rationale",
        "重复判断不应覆盖已有人工结果。",
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(duplicateLabel.status, 0);
    assert.match(duplicateLabel.stderr, /already labeled/);
    assert.deepEqual(await readFile(reviewPath), labeledBytes);

    const completeStatus = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "status",
        "--review",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(completeStatus.status, 0, completeStatus.stderr);
    assert.deepEqual(JSON.parse(completeStatus.stdout), {
      totalSampleCount: 1,
      completedSampleCount: 1,
      remainingSampleCount: 0,
      labelCounts: {
        interruptible: 0,
        notInterruptible: 1,
        uncertain: 0,
      },
      nextIncompleteSampleID: null,
    });
    const completedNext = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "next",
        "--review",
        reviewPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(completedNext.status, 0, completedNext.stderr);
    assert.equal(completedNext.stdout, "null\n");

    const replayServer = await startResponsesServer();
    try {
      const replayResult = spawnSync(
        process.execPath,
        [
          "Scripts/review-local-interruptibility-benchmark.mjs",
          "replay",
          "--run-directory",
          directory,
          "--review",
          reviewPath,
          "--prompt",
          replayPromptPath,
          "--output",
          replayReportPath,
          "--base-url",
          `http://127.0.0.1:${replayServer.port}/v1`,
          "--model",
          "decision-model",
        ],
        {
          cwd: repositoryRoot,
          encoding: "utf8",
          env: { ...process.env, AWAITCUE_API_KEY: "test-key" },
        },
      );
      assert.equal(replayResult.status, 0, replayResult.stderr);
      assert.doesNotMatch(
        replayResult.stdout,
        /contextText|imageFile|imageSHA256|ChatGPT|正在编辑技术内容|"cases"|"description"/,
      );
      const replayReport = JSON.parse(await readFile(replayReportPath, "utf8"));
      assert.equal(replayReport.summary.accuracy, 1);
      assert.equal(replayReport.summary.tokens.input, 123);
      assert.equal(replayReport.pairedComparison.bothCorrectCount, 1);
      assert.equal(replayReport.pairedComparison.candidateRegressedCount, 0);
      assert.deepEqual(
        replayReport.promptVerifiedPairedComparison,
        replayReport.pairedComparison,
      );
      assert.equal(replayReport.samples[0].modelDecision, "notInterruptible");
      assert.equal(replayReport.samples[0].correct, true);
      assert.match(replayReport.configuration.promptSHA256, /^[0-9a-f]{64}$/);
      assert.doesNotMatch(
        JSON.stringify(replayReport),
        /contextText|imageFile|imageSHA256|前台应用：ChatGPT/,
      );
      assert.equal((await stat(replayReportPath)).mode & 0o777, 0o600);
    } finally {
      replayServer.process.kill("SIGTERM");
      await once(replayServer.process, "exit");
    }

    const reportPath = path.join(directory, "comparison-report.json");
    const samplePath = path.join(samplesDirectory, "0001.json");
    const originalSampleRecord = await readFile(samplePath, "utf8");
    const changedSample = JSON.parse(originalSampleRecord);
    changedSample.modelDecision = "interruptible";
    changedSample.modelConfidence = 0.75;
    await writeFile(samplePath, JSON.stringify(changedSample));
    await chmod(samplePath, 0o600);
    const changedModelRecord = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        reportPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(changedModelRecord.status, 0);
    assert.match(changedModelRecord.stderr, /sample record changed after review preparation/);
    await writeFile(samplePath, originalSampleRecord);
    await chmod(samplePath, 0o600);

    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0x00]));
    const changedEvidence = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        reportPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(changedEvidence.status, 0);
    assert.match(changedEvidence.stderr, /image digest changed/);

    await writeFile(path.join(samplesDirectory, "0001.jpg"), Buffer.from([0xff, 0xd8, 0xff]));
    const victimPath = path.join(directory, "must-not-be-overwritten.txt");
    await writeFile(victimPath, "保留原内容");
    await symlink(victimPath, reportPath);
    const linkedOutput = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        reportPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.notEqual(linkedOutput.status, 0);
    assert.match(linkedOutput.stderr, /symbolic link/);
    assert.equal(await readFile(victimPath, "utf8"), "保留原内容");
    await unlink(reportPath);

    const reportResult = spawnSync(
      process.execPath,
      [
        "Scripts/review-local-interruptibility-benchmark.mjs",
        "report",
        "--run-directory",
        directory,
        "--review",
        reviewPath,
        "--output",
        reportPath,
      ],
      { cwd: repositoryRoot, encoding: "utf8" },
    );
    assert.equal(reportResult.status, 0, reportResult.stderr);
    assert.doesNotMatch(
      reportResult.stdout,
      /正在编辑技术内容|"cases"|"description"/,
    );
    const report = JSON.parse(await readFile(reportPath, "utf8"));
    assert.equal(report.summary.accuracy, 1);
    assert.equal((await stat(reportPath)).mode & 0o777, 0o600);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

/** 启动独立子进程中的最小 Responses 服务，让同步 CLI 调用也能完成真实 HTTP 往返。 */
async function startResponsesServer() {
  const source = String.raw`
    const http = require("node:http");
    const response = JSON.stringify({
      status: "completed",
      output: [{
        content: [{
          type: "output_text",
          text: JSON.stringify({ decision: "notInterruptible", confidence: 0.94 }),
        }],
      }],
      usage: {
        input_tokens: 123,
        output_tokens: 22,
        input_tokens_details: { cached_tokens: 10, cache_write_tokens: 0 },
        output_tokens_details: { reasoning_tokens: 0 },
      },
    });
    const server = http.createServer((request, reply) => {
      request.resume();
      request.on("end", () => {
        reply.writeHead(200, { "content-type": "application/json" });
        reply.end(response);
      });
    });
    process.on("SIGTERM", () => server.close(() => process.exit(0)));
    server.listen(0, "127.0.0.1", () => {
      process.stdout.write(String(server.address().port) + "\n");
    });
  `;
  const server = spawn(process.execPath, ["-e", source], {
    stdio: ["ignore", "pipe", "inherit"],
  });
  const [chunk] = await once(server.stdout, "data");
  return { process: server, port: Number(String(chunk).trim()) };
}

function benchmarkRun(status, sampleCount) {
  return {
    startedAt: "2026-11-17T05:48:37Z",
    intendedEndAt: "2026-11-18T05:48:37Z",
    completedAt: status === "completed" ? "2026-11-18T05:48:38Z" : null,
    status,
    modelName: "gpt-6-luna",
    endpointHost: "model.example",
    runRecordSHA256: "c".repeat(64),
    interruptibilityPromptSHA256: "a".repeat(64),
    interruptibilityPromptValidFromSampleID: "0001",
    sampleCount,
    lockedPollCount: 0,
    excludedPollCount: 0,
    captureFailureCount: 0,
    modelFailureCount: 0,
  };
}

function benchmarkSample(id, overrides = {}) {
  return {
    id,
    capturedAt: "2026-11-17T06:12:02Z",
    contextText: "前台应用：ChatGPT\n距最近输入约：1 秒",
    imageFile: `samples/${id}.jpg`,
    imageSHA256: "a".repeat(64),
    sampleRecordSHA256: "b".repeat(64),
    imageSHA256RecordedAtCapture: true,
    modelDecision: "notInterruptible",
    modelConfidence: 0.98,
    modelLatencyMilliseconds: 3285,
    modelError: null,
    humanDecision: null,
    humanRationale: null,
    ...overrides,
  };
}
