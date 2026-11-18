#!/usr/bin/env node

import {
  lstat,
  open,
  readFile,
  readdir,
  rename,
  unlink,
} from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import process from "node:process";

import {
  applyHumanReviewLabel,
  benchmarkOutcomeForLocalSample,
  compareHumanReview,
  createHumanReviewManifest,
  createPublicBenchmarkReport,
  createReviewedReplayPlan,
  createReviewedReplayReport,
  nextIncompleteHumanReviewSample,
  summarizeHumanReviewProgress,
} from "../Benchmarks/Decision/lib/local-review.mjs";
import { createDecisionClient } from "../Benchmarks/Decision/lib/responses.mjs";
import { createHash, randomUUID } from "node:crypto";

async function main() {
  const [command, ...argumentsList] = process.argv.slice(2);
  if (!["prepare", "status", "next", "label", "report", "replay", "replay-preflight",
    "public-report"]
    .includes(command)) {
    throw new Error(
      "first argument must be prepare, status, next, label, report, replay, replay-preflight, or public-report",
    );
  }
  const options = parseArguments(argumentsList);
  if (command === "public-report") {
    await createPublicReportFile(options);
    return;
  }
  if (command === "status") {
    if (!options.review) throw new Error("status requires --review");
    const reviewPath = path.resolve(options.review);
    await assertPrivateRegularFile(reviewPath, "human review");
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    process.stdout.write(`${JSON.stringify(summarizeHumanReviewProgress(review), null, 2)}\n`);
    return;
  }
  if (command === "next") {
    if (!options.review) throw new Error("next requires --review");
    const reviewPath = path.resolve(options.review);
    const reviewDirectory = path.dirname(reviewPath);
    await assertPrivateDirectory(reviewDirectory, "human review directory");
    await assertPrivateRegularFile(reviewPath, "human review");
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    const sample = nextIncompleteHumanReviewSample(review);
    if (sample === null) {
      process.stdout.write("null\n");
      return;
    }
    const imagePath = path.resolve(reviewDirectory, sample.imageFile);
    if (!imagePath.startsWith(`${reviewDirectory}${path.sep}`)) {
      throw new Error(`sample ${sample.id} image escapes human review directory`);
    }
    await assertPrivateRegularFile(imagePath, `sample ${sample.id} image`);
    const imageSHA256 = createHash("sha256").update(await readFile(imagePath)).digest("hex");
    if (imageSHA256 !== sample.imageSHA256) {
      throw new Error(`sample ${sample.id} image digest changed after review preparation`);
    }
    process.stdout.write(`${JSON.stringify({
      id: sample.id,
      capturedAt: sample.capturedAt,
      contextText: sample.contextText,
      imagePath,
    }, null, 2)}\n`);
    return;
  }
  if (command === "label") {
    if (!options.review || !options.id || !options.decision || !options.rationale) {
      throw new Error("label requires --review, --id, --decision, and --rationale");
    }
    const reviewPath = path.resolve(options.review);
    await assertPrivateDirectory(path.dirname(reviewPath), "human review directory");
    await assertPrivateRegularFile(reviewPath, "human review");
    const review = JSON.parse(await readFile(reviewPath, "utf8"));
    const labeled = applyHumanReviewLabel(review, {
      id: options.id,
      decision: options.decision,
      rationale: options.rationale,
    });
    await replacePrivateJSON(reviewPath, labeled);
    process.stdout.write(`Labeled ${options.id}.\n`);
    return;
  }
  if (!options.runDirectory || !options.output) {
    throw new Error("--run-directory and --output are required");
  }
  const { root, run, samples, inputPaths } = await loadCompletedRun(options.runDirectory);
  if (command === "prepare") {
    const review = createHumanReviewManifest(run, samples);
    assertReviewOutputLocation(options.output, root);
    assertDistinctOutputPath(options.output, inputPaths);
    // 独占创建防止自动化重跑时覆盖人工已经填写的判断。
    await writePrivateJSON(options.output, review, {
      exclusive: true,
      protectedInputPaths: inputPaths,
    });
    process.stdout.write(`Prepared ${review.samples.length} samples for human review.\n`);
    return;
  }
  assertReportOutputLocation(options.output, root);
  if (!options.review) throw new Error("report requires --review");
  const reviewPath = path.resolve(options.review);
  assertReviewOutputLocation(reviewPath, root);
  await assertPrivateRegularFile(reviewPath, "human review");
  const review = JSON.parse(await readFile(reviewPath, "utf8"));
  if (command === "replay-preflight") {
    await prepareReviewedReplay(options, {
      run,
      samples,
      review,
      inputPaths,
      reviewPath,
    });
    process.stdout.write("Replay preflight passed.\n");
    return;
  }
  if (command === "replay") {
    const {
      plan,
      promptPath,
      prompt,
      promptSHA256,
    } = await prepareReviewedReplay(options, {
      run,
      samples,
      review,
      inputPaths,
      reviewPath,
    });
    if (!options.baseURL || !options.model) {
      throw new Error("replay requires --base-url and --model");
    }
    const apiKey = process.env.AWAITCUE_API_KEY;
    if (!apiKey) throw new Error("replay requires AWAITCUE_API_KEY");
    const client = createDecisionClient({
      endpoint: options.baseURL,
      apiKey,
      model: options.model,
    });
    const results = [];
    for (const sample of plan.samples) {
      const imagePath = path.resolve(root, sample.imageFile);
      await assertPrivateRegularFile(imagePath, `sample ${sample.id} image`);
      const image = await readFile(imagePath);
      const currentDigest = createHash("sha256").update(image).digest("hex");
      if (currentDigest !== sample.imageSHA256) {
        throw new Error(`sample ${sample.id} image digest changed before replay`);
      }
      const result = await client.evaluate(
        {
          kind: "interruptibility",
          tags: ["active-window", "screen-evidence"],
        },
        {
          text: sample.contextText,
          image: { mediaType: "image/jpeg", data: image },
        },
        { interruptibilityInstructions: prompt },
      );
      results.push({ id: sample.id, ...result });
    }
    const report = createReviewedReplayReport(
      plan,
      results,
      {
        model: options.model,
        endpointHost: new URL(options.baseURL).host,
        promptSHA256,
      },
      samples.map((sample) => ({
        id: sample.id,
        outcome: benchmarkOutcomeForLocalSample(sample),
      })),
    );
    await writePrivateJSON(options.output, report, {
      exclusive: false,
      protectedInputPaths: [...inputPaths, reviewPath, promptPath],
    });
    process.stdout.write(`${JSON.stringify(summaryForConsole(report.summary), null, 2)}\n`);
    return;
  }
  const report = compareHumanReview(run, samples, review);
  assertDistinctOutputPath(options.output, [...inputPaths, reviewPath]);
  await writePrivateJSON(options.output, report, {
    exclusive: false,
    protectedInputPaths: [...inputPaths, reviewPath],
  });
  process.stdout.write(`${JSON.stringify(summaryForConsole(report.summary), null, 2)}\n`);
}

/** 读取同一私有 run 内的两份完整报告，并只把聚合字段写入可提交产物。 */
async function createPublicReportFile(options) {
  if (!options.comparisonReport || !options.candidateReport || !options.output) {
    throw new Error(
      "public-report requires --comparison-report, --candidate-report, and --output",
    );
  }
  const comparisonPath = path.resolve(options.comparisonReport);
  const candidatePath = path.resolve(options.candidateReport);
  const privateDirectory = path.dirname(comparisonPath);
  if (path.dirname(candidatePath) !== privateDirectory) {
    throw new Error("private benchmark reports must share one run directory");
  }
  await assertPrivateDirectory(privateDirectory, "benchmark report directory");
  await assertPrivateRegularFile(comparisonPath, "comparison report");
  await assertPrivateRegularFile(candidatePath, "candidate replay report");
  const comparison = JSON.parse(await readFile(comparisonPath, "utf8"));
  const candidate = JSON.parse(await readFile(candidatePath, "utf8"));
  const report = createPublicBenchmarkReport(comparison, candidate);
  const outputPath = path.resolve(options.output);
  if (path.dirname(outputPath) === privateDirectory) {
    throw new Error("public benchmark report must be stored outside the private run directory");
  }
  assertDistinctOutputPath(outputPath, [comparisonPath, candidatePath]);
  // 首次生成采用独占写入；人工确认后再将这份纯聚合 JSON 加入仓库。
  await writePrivateJSON(outputPath, report, {
    exclusive: true,
    protectedInputPaths: [comparisonPath, candidatePath],
  });
  process.stdout.write("Prepared sanitized public benchmark report.\n");
}

/**
 * 在读取模型配置与密钥前冻结回放输入；正式 replay 会再次执行同一校验，防止预检后替换。
 */
async function prepareReviewedReplay(
  options,
  { run, samples, review, inputPaths, reviewPath },
) {
  if (!options.prompt) throw new Error("replay requires --prompt");
  const plan = createReviewedReplayPlan(run, samples, review);
  const promptPath = path.resolve(options.prompt);
  await assertRegularSingleLinkFile(promptPath, "candidate prompt");
  const prompt = (await readFile(promptPath, "utf8")).trim();
  if (prompt === "") throw new Error("candidate prompt must not be empty");
  const promptSHA256 = createHash("sha256").update(prompt).digest("hex");
  assertDistinctOutputPath(options.output, [...inputPaths, reviewPath, promptPath]);
  return { plan, promptPath, prompt, promptSHA256 };
}

/** 终端只显示聚合指标；逐样本人工理由只留在 0600 私有报告中。 */
function summaryForConsole(summary) {
  const { cases: _cases, ...aggregate } = summary;
  return aggregate;
}

/** 相对图片路径以 run 目录为根；复核清单必须同目录保存，避免 next 展示错误文件。 */
function assertReviewOutputLocation(outputPath, runDirectory) {
  if (path.dirname(path.resolve(outputPath)) !== path.resolve(runDirectory)) {
    throw new Error("human review must be stored in the benchmark run directory");
  }
}

/** 逐样本报告只能留在私有 run 目录，避免误写进仓库或其他共享位置。 */
function assertReportOutputLocation(outputPath, runDirectory) {
  if (path.dirname(path.resolve(outputPath)) !== path.resolve(runDirectory)) {
    throw new Error("benchmark report must be stored in the benchmark run directory");
  }
}

/** 输出不得与本次读取的输入文件相同，避免一次参数错误销毁人工复核结果。 */
function assertDistinctOutputPath(outputPath, inputPaths) {
  const resolvedOutput = path.resolve(outputPath);
  if (inputPaths.some((inputPath) => resolvedOutput === path.resolve(inputPath))) {
    throw new Error("output path conflicts with an input file");
  }
}

/** 读取采样器落盘的完整 run，并确认每个复核图片仍位于该私有目录内。 */
async function loadCompletedRun(runDirectory) {
  const root = path.resolve(runDirectory);
  await assertPrivateDirectory(root, "benchmark run directory");
  const runPath = path.join(root, "run.json");
  await assertPrivateRegularFile(runPath, "benchmark run");
  const runRecord = await readFile(runPath);
  const run = {
    ...JSON.parse(runRecord.toString("utf8")),
    runRecordSHA256: createHash("sha256").update(runRecord).digest("hex"),
  };
  const samplesDirectory = path.join(root, "samples");
  await assertPrivateDirectory(samplesDirectory, "benchmark samples directory");
  const entries = await readdir(samplesDirectory, { withFileTypes: true });
  const sampleFiles = entries
    .filter((entry) => entry.isFile() && /^\d+\.json$/.test(entry.name))
    .map((entry) => entry.name)
    .sort();
  const samples = [];
  const inputPaths = [runPath];
  for (const sampleFile of sampleFiles) {
    const samplePath = path.join(samplesDirectory, sampleFile);
    inputPaths.push(samplePath);
    await assertPrivateRegularFile(samplePath, `sample ${sampleFile}`);
    const sampleRecord = await readFile(samplePath);
    const sample = JSON.parse(sampleRecord.toString("utf8"));
    const sampleRecordSHA256 = createHash("sha256").update(sampleRecord).digest("hex");
    const identifier = path.basename(sampleFile, ".json");
    const expectedImageFile = `samples/${identifier}.jpg`;
    if (sample.id !== identifier || sample.imageFile !== expectedImageFile) {
      throw new Error(`sample ${identifier} does not use its canonical sample identity`);
    }
    const imagePath = path.resolve(root, sample.imageFile);
    if (!imagePath.startsWith(`${root}${path.sep}`)) {
      throw new Error(`sample ${sample.id} image escapes benchmark directory`);
    }
    if (!(await lstat(imagePath)).isFile()) {
      throw new Error(`sample ${sample.id} image is unavailable`);
    }
    await assertPrivateRegularFile(imagePath, `sample ${sample.id} image`);
    inputPaths.push(imagePath);
    const imageSHA256 = createHash("sha256")
      .update(await readFile(imagePath))
      .digest("hex");
    const imageSHA256RecordedAtCapture = typeof sample.imageSHA256 === "string";
    if (imageSHA256RecordedAtCapture && sample.imageSHA256 !== imageSHA256) {
      throw new Error(`sample ${sample.id} image digest changed after capture`);
    }
    samples.push({
      ...sample,
      sampleRecordSHA256,
      imageSHA256,
      imageSHA256RecordedAtCapture,
    });
  }
  return { root, run, samples, inputPaths };
}

/** 目录需要保持 0700 语义，避免其他本机用户枚举样本文件名和运行结构。 */
async function assertPrivateDirectory(directoryPath, label) {
  const attributes = await lstat(directoryPath);
  if (!attributes.isDirectory()) {
    throw new Error(`${label} must be a directory`);
  }
  if ((attributes.mode & 0o077) !== 0) {
    throw new Error(`${label} must use private directory permissions`);
  }
}

/** 原始本机证据必须保持仅当前用户可访问；复核工具不能默许一次意外的权限放宽。 */
async function assertPrivateRegularFile(filePath, label) {
  const attributes = await lstat(filePath);
  if (!attributes.isFile()) {
    throw new Error(`${label} must be a regular file`);
  }
  if ((attributes.mode & 0o077) !== 0) {
    throw new Error(`${label} must use private file permissions`);
  }
  if (attributes.nlink !== 1) {
    throw new Error(`${label} must not have additional hard links`);
  }
}

/** 候选 prompt 可以来自仓库资源，但也必须是无别名的普通文件，避免路径替换。 */
async function assertRegularSingleLinkFile(filePath, label) {
  const attributes = await lstat(filePath);
  if (!attributes.isFile()) {
    throw new Error(`${label} must be a regular file`);
  }
  if (attributes.nlink !== 1) {
    throw new Error(`${label} must not have additional hard links`);
  }
}

/** JSON 复核产物可能包含本机活动摘要，因此无论新建或覆盖都强制仅当前用户可读。 */
async function writePrivateJSON(outputPath, value, { exclusive, protectedInputPaths }) {
  const resolved = path.resolve(outputPath);
  const flags = constants.O_WRONLY
    | constants.O_CREAT
    | constants.O_NOFOLLOW
    | (exclusive ? constants.O_EXCL : 0);
  let output;
  try {
    // O_NOFOLLOW 在打开这一原子边界拒绝符号链接，避免先检查后替换的竞态。
    output = await open(resolved, flags, 0o600);
  } catch (error) {
    if (error?.code === "ELOOP") {
      throw new Error("output path must not be a symbolic link");
    }
    throw error;
  }
  try {
    const outputAttributes = await output.stat();
    // 必须检查已经打开的 FD；预先按路径 lstat 仍可能在打开前被换成硬链接。
    if (outputAttributes.nlink !== 1) {
      throw new Error("output file must not have additional hard links");
    }
    for (const inputPath of protectedInputPaths) {
      const inputAttributes = await lstat(inputPath);
      if (outputAttributes.dev === inputAttributes.dev
          && outputAttributes.ino === inputAttributes.ino) {
        throw new Error("output file conflicts with an input file");
      }
    }
    // 非独占输出先通过已打开的 FD 校验 inode，再截断，硬链接别名不能借路径差异覆盖输入。
    if (!exclusive) await output.truncate(0);
    await output.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
    await output.chmod(0o600);
  } finally {
    await output.close();
  }
}

/**
 * 通过同目录私有临时文件原子替换人工复核清单。
 * 这样进程在写入中途退出时，原清单仍保持完整；0700 父目录也限制了同机竞态范围。
 */
async function replacePrivateJSON(filePath, value) {
  const resolved = path.resolve(filePath);
  const parent = path.dirname(resolved);
  await assertPrivateDirectory(parent, "human review directory");
  const originalAttributes = await lstat(resolved);
  const temporaryPath = path.join(
    parent,
    `.${path.basename(resolved)}.${process.pid}.${randomUUID()}.tmp`,
  );
  let temporaryCreated = false;
  let replaced = false;
  let temporary;
  try {
    temporary = await open(
      temporaryPath,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600,
    );
    temporaryCreated = true;
    await temporary.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
    await temporary.chmod(0o600);
    await temporary.sync();
    await temporary.close();
    temporary = null;

    // 替换前再次确认路径仍指向刚才读取的文件，避免覆盖同目录中被换入的另一份复核结果。
    const currentAttributes = await lstat(resolved);
    if (currentAttributes.dev !== originalAttributes.dev
        || currentAttributes.ino !== originalAttributes.ino) {
      throw new Error("human review changed while applying label");
    }
    await rename(temporaryPath, resolved);
    replaced = true;
  } finally {
    if (temporary) await temporary.close();
    if (temporaryCreated && !replaced) {
      await unlink(temporaryPath).catch(() => {});
    }
  }
}

function parseArguments(argumentsList) {
  const options = {};
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--run-directory") {
      options.runDirectory = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--output") {
      options.output = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--review") {
      options.review = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--id") {
      options.id = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--decision") {
      options.decision = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--rationale") {
      options.rationale = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--prompt") {
      options.prompt = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--base-url") {
      options.baseURL = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--model") {
      options.model = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--comparison-report") {
      options.comparisonReport = nextValue(argumentsList, ++index, argument);
    } else if (argument === "--candidate-report") {
      options.candidateReport = nextValue(argumentsList, ++index, argument);
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  return options;
}

function nextValue(argumentsList, index, option) {
  const value = argumentsList[index];
  if (!value || value.startsWith("--")) throw new Error(`${option} requires a value`);
  return value;
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
