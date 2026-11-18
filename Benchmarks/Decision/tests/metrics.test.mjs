import assert from "node:assert/strict";
import test from "node:test";

import { aggregateBenchmark } from "../lib/metrics.mjs";

test("aggregates user-labeled decisions, stability, failures, latency, and token reuse", () => {
  const report = aggregateBenchmark([
    benchmarkCase("condition-ready", "condition", "matched", [
      sample("matched", 100, { cachedTokens: 0 }),
      sample("matched", 200, { cachedTokens: 50 }),
      sample("notMatched", 300, { cachedTokens: 100 }),
    ]),
    benchmarkCase("condition-pending", "condition", "notMatched", [
      sample("notMatched", 400),
      sample("incomplete", 500),
      sample("invalid", 600),
    ]),
    benchmarkCase("interruptible-reading", "interruptibility", "interruptible", [
      sample("interruptible", 700),
      sample("interruptible", 800),
      sample("interruptible", 900, { reasoningTokens: 2 }),
    ], "普通文章阅读可以被打断"),
  ]);

  assert.equal(report.caseCount, 3);
  assert.equal(report.runCount, 9);
  assert.equal(report.correctRunCount, 6);
  assert.equal(report.validDecisionCount, 7);
  assert.equal(report.accuracy, 6 / 9);
  assert.equal(report.validDecisionAccuracy, 6 / 7);
  assert.equal(report.incompleteRate, 1 / 9);
  assert.equal(report.invalidRate, 1 / 9);
  assert.equal(report.errorRate, 0);
  assert.equal(report.meanCaseStability, 2 / 3);
  assert.equal(report.fullyStableCaseRate, 1 / 3);
  assert.deepEqual(report.latencyMs, { p50: 500, p95: 900, max: 900 });
  assert.deepEqual(report.confusion.condition.matched, {
    matched: 2,
    notMatched: 1,
  });
  assert.deepEqual(report.confusion.condition.notMatched, {
    incomplete: 1,
    invalid: 1,
    notMatched: 1,
  });
  assert.deepEqual(report.confusion.interruptibility.interruptible, {
    interruptible: 3,
  });
  assert.deepEqual(report.tokens, {
    input: 900,
    output: 90,
    reasoning: 2,
    cachedInput: 150,
    cacheWrite: 750,
    tokenCacheHitRate: 1 / 6,
    requestCacheHitRate: 2 / 9,
  });
  assert.deepEqual(
    report.cases.map(({ id, stability, correctRuns, description }) => ({
      id,
      stability,
      correctRuns,
      description,
    })),
    [
      { id: "condition-ready", stability: 2 / 3, correctRuns: 2, description: undefined },
      { id: "condition-pending", stability: 1 / 3, correctRuns: 1, description: undefined },
      {
        id: "interruptible-reading",
        stability: 1,
        correctRuns: 3,
        description: "普通文章阅读可以被打断",
      },
    ],
  );
});

test("把 interruptible 作为通知 positive，并且不把零预测伪装成满 precision", () => {
  const report = aggregateBenchmark([
    benchmarkCase("obvious-break", "interruptibility", "interruptible", [
      sample("interruptible", 100),
      sample("notInterruptible", 100),
      sample("uncertain", 100),
      sample("error", 100),
    ]),
    benchmarkCase("focused-work", "interruptibility", "notInterruptible", [
      sample("interruptible", 100),
      sample("notInterruptible", 100),
      sample("uncertain", 100),
    ]),
    benchmarkCase("ambiguous-focus", "interruptibility", "uncertain", [
      sample("interruptible", 100),
      sample("uncertain", 100),
    ]),
  ]);

  assert.deepEqual(report.interruptibleMetrics, {
    truePositiveCount: 1,
    falsePositiveCount: 2,
    falseNegativeCount: 3,
    trueNegativeCount: 3,
    predictedPositiveCount: 3,
    actualPositiveCount: 4,
    precision: 1 / 3,
    recall: 1 / 4,
  });

  const noNotification = aggregateBenchmark([
    benchmarkCase("obvious-break", "interruptibility", "interruptible", [
      sample("notInterruptible", 100),
    ]),
    benchmarkCase("focused-work", "interruptibility", "notInterruptible", [
      sample("uncertain", 100),
    ]),
  ]);

  assert.deepEqual(noNotification.interruptibleMetrics, {
    truePositiveCount: 0,
    falsePositiveCount: 0,
    falseNegativeCount: 1,
    trueNegativeCount: 1,
    predictedPositiveCount: 0,
    actualPositiveCount: 1,
    precision: null,
    recall: 0,
  });
});

function benchmarkCase(id, kind, expected, samples, description) {
  return { id, kind, expected, samples, description };
}

function sample(outcome, durationMs, tokenOverrides = {}) {
  const cachedTokens = tokenOverrides.cachedTokens ?? 0;
  return {
    outcome,
    durationMs,
    usage: {
      inputTokens: 100,
      outputTokens: 10,
      reasoningTokens: 0,
      cachedTokens,
      cacheWriteTokens: 100 - cachedTokens,
      ...tokenOverrides,
    },
  };
}
