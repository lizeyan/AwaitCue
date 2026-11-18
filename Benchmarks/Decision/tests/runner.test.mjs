import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

test("dry-run can validate only the interruptibility benchmark", () => {
  const result = spawnSync(
    process.execPath,
    ["Scripts/run-decision-benchmark.mjs", "--dry-run", "--kind", "interruptibility"],
    { cwd: repositoryRoot, encoding: "utf8" },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Validated 16 decision benchmark cases\./);
});

test("没有任何通知 positive 时不能通过 precision 门禁", async () => {
  const fixture = await startDecisionFixture(() => "notInterruptible");
  try {
    const result = await runBenchmark(fixture, [
      "--minimum-interruptibility-precision", "1",
    ]);

    assert.equal(result.code, 4, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.summary.interruptibleMetrics.predictedPositiveCount, 0);
    assert.equal(report.summary.interruptibleMetrics.precision, null);
  } finally {
    await fixture.close();
  }
});

test("任何通知误报都会触发零 FP 门禁", async () => {
  const fixture = await startDecisionFixture(() => "interruptible");
  try {
    const result = await runBenchmark(fixture, [
      "--maximum-interruptibility-false-positives", "0",
    ]);

    assert.equal(result.code, 6, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.summary.interruptibleMetrics.falsePositiveCount, 2);
  } finally {
    await fixture.close();
  }
});

test("零误报但 positive 召回不足时仍拒绝候选", async () => {
  const fixture = await startDecisionFixture((body) =>
    activityText(body).includes("positive one") ? "interruptible" : "notInterruptible");
  try {
    const result = await runBenchmark(fixture, [
      "--maximum-interruptibility-false-positives", "0",
      "--minimum-interruptibility-precision", "1",
      "--minimum-interruptibility-recall", "0.6",
    ]);

    assert.equal(result.code, 5, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.summary.interruptibleMetrics.precision, 1);
    assert.equal(report.summary.interruptibleMetrics.recall, 0.5);
  } finally {
    await fixture.close();
  }
});

test("零误报且 precision 和 recall 达标时通过通知门禁", async () => {
  const fixture = await startDecisionFixture((body) =>
    activityText(body).includes("positive") ? "interruptible" : "notInterruptible");
  try {
    const result = await runBenchmark(fixture, [
      "--maximum-interruptibility-false-positives", "0",
      "--minimum-interruptibility-precision", "1",
      "--minimum-interruptibility-recall", "0.3",
    ]);

    assert.equal(result.code, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.summary.interruptibleMetrics.precision, 1);
    assert.equal(report.summary.interruptibleMetrics.recall, 1);
  } finally {
    await fixture.close();
  }
});

/** 启动只返回三态决定的本地 Responses fixture，避免 CLI 测试访问真实模型。 */
async function startDecisionFixture(decide) {
  const directory = await mkdtemp(path.join(tmpdir(), "awaitcue-precision-gate-"));
  const manifestPath = path.join(directory, "benchmark.json");
  const imagePath = path.join(
    repositoryRoot,
    "Benchmarks/Decision/fixtures/images/interrupt-reading.png",
  );
  await writeFile(manifestPath, JSON.stringify({
    version: 1,
    repetitions: 1,
    cases: [
      benchmarkCase("positive-one", "interruptible", "positive one", imagePath),
      benchmarkCase("positive-two", "interruptible", "positive two", imagePath),
      benchmarkCase("negative", "notInterruptible", "negative evidence", imagePath),
      benchmarkCase("uncertain", "uncertain", "uncertain evidence", imagePath),
    ],
  }));
  const server = http.createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    const decision = decide(JSON.parse(body));
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      status: "completed",
      output: [{
        type: "message",
        content: [{
          type: "output_text",
          text: JSON.stringify({ decision, confidence: 0.9 }),
        }],
      }],
    }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  return {
    endpoint: `http://127.0.0.1:${address.port}`,
    manifestPath,
    async close() {
      server.close();
      await once(server, "close");
      await rm(directory, { recursive: true, force: true });
    },
  };
}

/** 通过真实 CLI 边界运行一个最小 benchmark，并收集退出码与报告。 */
async function runBenchmark(fixture, extraArguments) {
  const child = spawn(process.execPath, [
    "Scripts/run-decision-benchmark.mjs",
    "--manifest", fixture.manifestPath,
    "--kind", "interruptibility",
    ...extraArguments,
  ], {
    cwd: repositoryRoot,
    env: {
      ...process.env,
      AWAITCUE_BASE_URL: fixture.endpoint,
      AWAITCUE_API_KEY: "fixture-key",
      AWAITCUE_MODEL: "fixture-model",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const [code] = await once(child, "close");
  return { code, stdout, stderr };
}

/** 构造覆盖 positive、negative 与 uncertain 的最小忙闲样本。 */
function benchmarkCase(id, expected, text, image) {
  return {
    id,
    kind: "interruptibility",
    expected,
    tags: ["active-window"],
    evidence: { text, image },
  };
}

/** 从真实 Responses 请求中读取 benchmark 提供的当前活动文字。 */
function activityText(body) {
  return body.input?.[0]?.content?.find(({ type }) => type === "input_text")?.text ?? "";
}
