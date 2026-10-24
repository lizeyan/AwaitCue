const validOutcomes = {
  condition: new Set(["matched", "notMatched", "uncertain"]),
  interruptibility: new Set(["interruptible", "notInterruptible", "uncertain"]),
};

/**
 * 汇总固定人工标签与多次真实模型运行，失败运行会进入总体准确率而不会被过滤掉。
 */
export function aggregateBenchmark(caseResults) {
  const flattened = caseResults.flatMap((entry) =>
    entry.samples.map((sample) => ({ ...sample, case: entry })),
  );
  const runCount = flattened.length;
  const caseSummaries = caseResults.map(summarizeCase);
  const correctRunCount = flattened.filter(isCorrect).length;
  const validDecisionCount = flattened.filter(({ case: entry, outcome }) =>
    validOutcomes[entry.kind]?.has(outcome),
  ).length;
  const incompleteCount = flattened.filter(({ outcome }) => outcome === "incomplete").length;
  const invalidCount = flattened.filter(({ outcome }) => outcome === "invalid").length;
  const errorCount = flattened.filter(({ outcome }) => outcome === "error").length;
  const durations = flattened
    .map(({ durationMs }) => durationMs)
    .filter((value) => Number.isFinite(value))
    .sort((left, right) => left - right);

  return {
    caseCount: caseResults.length,
    runCount,
    correctRunCount,
    validDecisionCount,
    accuracy: divide(correctRunCount, runCount),
    validDecisionAccuracy: divide(correctRunCount, validDecisionCount),
    incompleteRate: divide(incompleteCount, runCount),
    invalidRate: divide(invalidCount, runCount),
    errorRate: divide(errorCount, runCount),
    meanCaseStability: mean(caseSummaries.map(({ stability }) => stability)),
    fullyStableCaseRate: divide(
      caseSummaries.filter(({ stability }) => stability === 1).length,
      caseSummaries.length,
    ),
    latencyMs: {
      p50: percentile(durations, 0.5),
      p95: percentile(durations, 0.95),
      max: durations.at(-1) ?? null,
    },
    confusion: confusionMatrix(flattened),
    tokens: tokenSummary(flattened),
    cases: caseSummaries,
  };
}

function summarizeCase(entry) {
  const counts = countBy(entry.samples.map(({ outcome }) => outcome));
  const modalCount = Math.max(0, ...Object.values(counts));
  return {
    id: entry.id,
    kind: entry.kind,
    expected: entry.expected,
    runs: entry.samples.length,
    correctRuns: entry.samples.filter((sample) => sample.outcome === entry.expected).length,
    stability: divide(modalCount, entry.samples.length),
    outcomes: counts,
  };
}

function confusionMatrix(flattened) {
  const matrix = {};
  for (const { case: entry, outcome } of flattened) {
    matrix[entry.kind] ??= {};
    matrix[entry.kind][entry.expected] ??= {};
    matrix[entry.kind][entry.expected][outcome] =
      (matrix[entry.kind][entry.expected][outcome] ?? 0) + 1;
  }
  return sortNestedObject(matrix);
}

function tokenSummary(flattened) {
  const totals = flattened.reduce(
    (result, { usage = {} }) => ({
      input: result.input + finiteOrZero(usage.inputTokens),
      output: result.output + finiteOrZero(usage.outputTokens),
      reasoning: result.reasoning + finiteOrZero(usage.reasoningTokens),
      cachedInput: result.cachedInput + finiteOrZero(usage.cachedTokens),
      cacheWrite: result.cacheWrite + finiteOrZero(usage.cacheWriteTokens),
      requestsWithCacheHit:
        result.requestsWithCacheHit + (finiteOrZero(usage.cachedTokens) > 0 ? 1 : 0),
    }),
    {
      input: 0,
      output: 0,
      reasoning: 0,
      cachedInput: 0,
      cacheWrite: 0,
      requestsWithCacheHit: 0,
    },
  );
  return {
    input: totals.input,
    output: totals.output,
    reasoning: totals.reasoning,
    cachedInput: totals.cachedInput,
    cacheWrite: totals.cacheWrite,
    tokenCacheHitRate: divide(totals.cachedInput, totals.input),
    requestCacheHitRate: divide(totals.requestsWithCacheHit, flattened.length),
  };
}

function isCorrect({ case: entry, outcome }) {
  return outcome === entry.expected;
}

function countBy(values) {
  const counts = {};
  for (const value of values) counts[value] = (counts[value] ?? 0) + 1;
  return Object.fromEntries(Object.entries(counts).sort(([left], [right]) => left.localeCompare(right)));
}

function sortNestedObject(value) {
  if (Array.isArray(value) || value === null || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, nested]) => [key, sortNestedObject(nested)]),
  );
}

function percentile(sortedValues, probability) {
  if (sortedValues.length === 0) return null;
  const index = Math.max(0, Math.ceil(probability * sortedValues.length) - 1);
  return sortedValues[index];
}

function mean(values) {
  return values.length === 0
    ? 0
    : values.reduce((sum, value) => sum + value, 0) / values.length;
}

function divide(numerator, denominator) {
  return denominator === 0 ? 0 : numerator / denominator;
}

function finiteOrZero(value) {
  return Number.isFinite(value) ? value : 0;
}
