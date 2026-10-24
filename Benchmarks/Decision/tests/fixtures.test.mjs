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
  const expectedCases = new Set([
    "condition:matched:browser",
    "condition:matched:app",
    "condition:notMatched:browser",
    "condition:notMatched:app",
    "condition:uncertain:browser",
    "condition:uncertain:app",
    "interruptibility:interruptible:browser",
    "interruptibility:interruptible:app",
    "interruptibility:notInterruptible:browser",
    "interruptibility:notInterruptible:app",
    "interruptibility:uncertain:browser",
    "interruptibility:uncertain:app",
  ]);
  const actualCases = new Set();
  for (const entry of manifest.cases) {
    const surface = entry.tags.includes("browser") ? "browser" : "app";
    actualCases.add(`${entry.kind}:${entry.expected}:${surface}`);
    assert.ok(entry.evidence.image.startsWith(benchmarkDirectory));
    const image = await readFile(entry.evidence.image);
    assert.deepEqual([...image.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    if (surface === "browser") {
      assert.ok(entry.evidence.textFile, `${entry.id} must include browser DOM evidence`);
      assert.ok((await readFile(entry.evidence.textFile, "utf8")).trim().length > 0);
    } else {
      assert.equal(entry.evidence.textFile, undefined);
      assert.equal(entry.evidence.text, undefined);
    }
  }
  assert.deepEqual(actualCases, expectedCases);
});
