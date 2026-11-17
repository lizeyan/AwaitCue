import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
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
