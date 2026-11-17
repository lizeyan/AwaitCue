import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { validateBenchmarkManifest } from "../lib/manifest.mjs";

const benchmarkDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("canonical fixtures cover every decision and evidence surface without secrets", async () => {
  const manifestPath = path.join(benchmarkDirectory, "benchmark.v1.json");
  const source = await readFile(manifestPath, "utf8");
  assert.doesNotMatch(source, /(api[_-]?key|bearer\s+|bytedance\.net|aidp\.)/i);
  const manifest = validateBenchmarkManifest(JSON.parse(source), benchmarkDirectory);
  assert.equal(manifest.cases.length, 35);
  const requiredScenarios = new Set([
    "scenario:overall-failed-local-success",
    "scenario:duplicate-name-conflict",
    "scenario:expanded-region-conflict",
    "scenario:condition-text-not-fact",
    "scenario:explicit-failure",
    "scenario:queued",
    "scenario:pipeline-pending-html",
    "scenario:status-missing",
    "scenario:meeting",
    "scenario:presentation",
    "scenario:document-writing",
    "scenario:code-debugging",
    "scenario:article-reading",
    "scenario:chat-reading",
    "scenario:mixed-focus-unknown",
    "scenario:no-semantic-content",
    "scenario:build-waiting",
    "scenario:email-reading",
    "scenario:settings-browsing",
    "scenario:music-playing",
    "scenario:spreadsheet-editing",
    "scenario:chat-drafting",
    "scenario:form-filling",
    "scenario:video-watching",
    "scenario:all-in-one-mixed-activity",
  ]);
  const actualScenarios = new Set(
    manifest.cases.flatMap((entry) => entry.tags.filter((tag) => tag.startsWith("scenario:"))),
  );
  for (const scenario of requiredScenarios) {
    assert.ok(actualScenarios.has(scenario), `missing fixed benchmark ${scenario}`);
  }
  const expectedCases = new Set([
    "condition:matched:browser",
    "condition:matched:app",
    "condition:notMatched:browser",
    "condition:notMatched:app",
    "condition:uncertain:browser",
    "condition:uncertain:app",
    "interruptibility:interruptible:active-window",
    "interruptibility:notInterruptible:active-window",
    "interruptibility:uncertain:active-window",
  ]);
  const actualCases = new Set();
  for (const entry of manifest.cases) {
    const surface = entry.kind === "interruptibility"
      ? "active-window"
      : entry.tags.includes("browser") ? "browser" : "app";
    actualCases.add(`${entry.kind}:${entry.expected}:${surface}`);
    if (surface === "browser") {
      assert.ok(entry.evidence.textFile, `${entry.id} must include browser DOM evidence`);
      assert.ok((await readFile(entry.evidence.textFile, "utf8")).trim().length > 0);
      assert.equal(entry.evidence.image, undefined, `${entry.id} must not include browser pixels`);
    } else {
      assert.ok(entry.evidence.image.startsWith(benchmarkDirectory));
      const image = await readFile(entry.evidence.image);
      assert.deepEqual([...image.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
      assert.equal(entry.evidence.textFile, undefined);
      if (surface === "app") {
        assert.equal(entry.evidence.text, undefined);
      } else {
        assert.match(entry.evidence.text, /前台应用：/);
        assert.ok(entry.tags.includes("screen-evidence"));
      }
    }
  }
  assert.equal(
    manifest.cases.filter((entry) => entry.tags.includes("scenario:no-semantic-content")).length,
    1,
  );
  const pipelineCase = manifest.cases.find((entry) =>
    entry.tags.includes("scenario:pipeline-pending-html")
  );
  assert.ok(pipelineCase?.evidence.textFile, "pipeline HTML benchmark fixture must exist");
  const pipelineHTML = await readFile(pipelineCase.evidence.textFile, "utf8");
  assert.match(pipelineHTML, /^<section[\s>]/);
  assert.match(pipelineHTML, /data-awaitcue-rect="[^"]+"/);
  assert.match(pipelineHTML, /class="[^"]*atom-pipeline-icon-queuing-circle-fill[^"]*"/);
  assert.match(pipelineHTML, /aria-(?:label|hidden)="[^"]+"/);
  assert.doesNotMatch(pipelineHTML, /^\[[^\]]+\]\s+class:/m);
  assert.deepEqual(actualCases, expectedCases);
  const interruptionCases = manifest.cases.filter((entry) => entry.kind === "interruptibility");
  assert.equal(interruptionCases.length, 16);
  for (const entry of interruptionCases) {
    assert.ok(entry.description, `${entry.id} must preserve a human judgment rationale`);
  }
});
