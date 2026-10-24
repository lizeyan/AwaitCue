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
          evidence: { text: "Build succeeded", image: "fixtures/build.png" },
        },
        {
          id: "reading-article",
          kind: "interruptibility",
          expected: "interruptible",
          evidence: { textFile: "fixtures/article.txt" },
          repetitions: 3,
        },
      ],
    },
    "/benchmark",
  );

  assert.equal(manifest.repetitions, 5);
  assert.equal(manifest.cases[0].repetitions, 5);
  assert.equal(manifest.cases[0].evidence.image, "/benchmark/fixtures/build.png");
  assert.equal(manifest.cases[1].repetitions, 3);
  assert.equal(manifest.cases[1].evidence.textFile, "/benchmark/fixtures/article.txt");
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
    evidence: { text: "Build complete" },
  };
}
