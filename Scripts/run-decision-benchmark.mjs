#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { loadEvidence } from "../Benchmarks/Decision/lib/evidence.mjs";
import { validateBenchmarkManifest } from "../Benchmarks/Decision/lib/manifest.mjs";
import { aggregateBenchmark } from "../Benchmarks/Decision/lib/metrics.mjs";
import { createDecisionClient } from "../Benchmarks/Decision/lib/responses.mjs";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const manifestPath = path.resolve(options.manifest ?? path.join(
    repositoryRoot,
    "Benchmarks/Decision/benchmark.v1.json",
  ));
  const manifestSource = await readFile(manifestPath, "utf8");
  const manifest = validateBenchmarkManifest(
    JSON.parse(manifestSource),
    path.dirname(manifestPath),
  );
  if (options.dryRun) {
    for (const entry of manifest.cases) await loadEvidence(entry.evidence);
    console.log(`Validated ${manifest.cases.length} decision benchmark cases.`);
    return;
  }

  const endpoint = options.baseURL ?? process.env.AWAITCUE_BASE_URL;
  const apiKey = process.env.AWAITCUE_API_KEY;
  const model = options.model ?? process.env.AWAITCUE_MODEL;
  if (!endpoint || !apiKey || !model) {
    throw new Error("AWAITCUE_BASE_URL, AWAITCUE_API_KEY, and AWAITCUE_MODEL are required");
  }
  const instructions = {
    conditionInstructions: await readFile(
      path.resolve(options.conditionPrompt ?? path.join(
        repositoryRoot,
        "Benchmarks/Decision/prompts/condition.txt",
      )),
      "utf8",
    ),
    interruptibilityInstructions: await readFile(
      path.resolve(options.interruptibilityPrompt ?? path.join(
        repositoryRoot,
        "Benchmarks/Decision/prompts/interruptibility.txt",
      )),
      "utf8",
    ),
  };
  const client = createDecisionClient({ endpoint, apiKey, model });
  const results = [];
  for (const entry of manifest.cases) {
    const evidence = await loadEvidence(entry.evidence);
    const samples = [];
    const repetitions = options.repetitions ?? entry.repetitions;
    for (let index = 0; index < repetitions; index += 1) {
      samples.push(await client.evaluate(entry, evidence, instructions));
    }
    results.push({
      id: entry.id,
      kind: entry.kind,
      expected: entry.expected,
      samples,
    });
    const correct = samples.filter(({ outcome }) => outcome === entry.expected).length;
    console.error(`${entry.id}: ${correct}/${samples.length} expected ${entry.expected}`);
  }
  const summary = aggregateBenchmark(results);
  const report = {
    version: 1,
    generatedAt: new Date().toISOString(),
    manifest: path.relative(repositoryRoot, manifestPath),
    configuration: {
      model,
      endpointHost: new URL(endpoint).host,
      repetitionsOverride: options.repetitions ?? null,
    },
    summary,
  };
  const serialized = `${JSON.stringify(report, null, 2)}\n`;
  if (options.output) await writeFile(path.resolve(options.output), serialized, "utf8");
  process.stdout.write(serialized);
  if (options.minimumAccuracy !== undefined && summary.accuracy < options.minimumAccuracy) {
    process.exitCode = 2;
  }
  if (options.minimumStability !== undefined
      && summary.meanCaseStability < options.minimumStability) {
    process.exitCode = 3;
  }
}

function parseArguments(argumentsList) {
  const options = {};
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--dry-run") options.dryRun = true;
    else if (argument === "--manifest") options.manifest = nextValue(argumentsList, ++index, argument);
    else if (argument === "--output") options.output = nextValue(argumentsList, ++index, argument);
    else if (argument === "--base-url") options.baseURL = nextValue(argumentsList, ++index, argument);
    else if (argument === "--model") options.model = nextValue(argumentsList, ++index, argument);
    else if (argument === "--condition-prompt") options.conditionPrompt = nextValue(argumentsList, ++index, argument);
    else if (argument === "--interruptibility-prompt") options.interruptibilityPrompt = nextValue(argumentsList, ++index, argument);
    else if (argument === "--repetitions") options.repetitions = positiveNumber(nextValue(argumentsList, ++index, argument), argument);
    else if (argument === "--minimum-accuracy") options.minimumAccuracy = rate(nextValue(argumentsList, ++index, argument), argument);
    else if (argument === "--minimum-stability") options.minimumStability = rate(nextValue(argumentsList, ++index, argument), argument);
    else throw new Error(`unknown argument: ${argument}`);
  }
  return options;
}

function nextValue(argumentsList, index, option) {
  const value = argumentsList[index];
  if (!value || value.startsWith("--")) throw new Error(`${option} requires a value`);
  return value;
}

function positiveNumber(value, option) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${option} must be a positive integer`);
  return parsed;
}

function rate(value, option) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) {
    throw new Error(`${option} must be between 0 and 1`);
  }
  return parsed;
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
