import assert from "node:assert/strict";
import test from "node:test";

import { validateBenchmarkManifest } from "../lib/manifest.mjs";

test("normalizes a mixed condition and interruptibility manifest", () => {
  const manifest = validateBenchmarkManifest(
    {
      version: 1,
      repetitions: 5,
      cases: [
        {
          id: "build-complete",
          kind: "condition",
          expected: "matched",
          condition: "构建已经完成",
          tags: ["browser", "dom-only"],
          evidence: { text: "Build succeeded" },
        },
        {
          id: "reading-article",
          kind: "interruptibility",
          expected: "interruptible",
          tags: ["active-window", "screen-evidence"],
          evidence: {
            text: "前台应用：Safari\n窗口标题：Article\n距最近输入约：18 秒",
            image: "fixtures/article.png",
          },
          repetitions: 3,
        },
      ],
    },
    "/benchmark",
  );

  assert.equal(manifest.repetitions, 5);
  assert.equal(manifest.cases[0].repetitions, 5);
  assert.equal(manifest.cases[0].evidence.image, undefined);
  assert.equal(manifest.cases[1].repetitions, 3);
  assert.equal(manifest.cases[1].evidence.image, "/benchmark/fixtures/article.png");
  assert.match(manifest.cases[1].evidence.text, /Safari/);
});

test("enforces Condition target surfaces and active-window interruption screenshots", () => {
  assert.throws(
    () => validateBenchmarkManifest({
      version: 1,
      cases: [{
        ...fixtureCase(),
        tags: ["browser"],
        evidence: { text: "DOM", image: "fixtures/build.png" },
      }],
    }, "/tmp"),
    /browser evidence must be DOM-only/,
  );
  assert.throws(
    () => validateBenchmarkManifest({
      version: 1,
      cases: [{
        ...fixtureCase(),
        tags: ["app"],
        evidence: { text: "DOM" },
      }],
    }, "/tmp"),
    /app evidence must be image-only/,
  );
  assert.throws(
    () => validateBenchmarkManifest({
      version: 1,
      cases: [{
        id: "interrupt-reading",
        kind: "interruptibility",
        expected: "interruptible",
        tags: ["active-window"],
        evidence: { text: "Article text from DOM" },
      }],
    }, "/tmp"),
    /interruptibility evidence must be an active-window image/,
  );
});

test("rejects duplicate IDs, incompatible labels, and empty evidence", () => {
  assert.throws(
    () => validateBenchmarkManifest({ version: 1, cases: [fixtureCase(), fixtureCase()] }, "/tmp"),
    /duplicate case id: case-1/,
  );
  assert.throws(
    () => validateBenchmarkManifest({
      version: 1,
      cases: [{ ...fixtureCase(), expected: "interruptible" }],
    }, "/tmp"),
    /invalid expected decision for condition/,
  );
  assert.throws(
    () => validateBenchmarkManifest({
      version: 1,
      cases: [{ ...fixtureCase(), evidence: {} }],
    }, "/tmp"),
    /evidence must contain text, textFile, or image/,
  );
});

function fixtureCase() {
  return {
    id: "case-1",
    kind: "condition",
    expected: "matched",
    condition: "构建完成",
    tags: ["browser"],
    evidence: { text: "Build complete" },
  };
}
