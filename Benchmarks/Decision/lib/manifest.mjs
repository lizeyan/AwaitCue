import path from "node:path";

const expectedByKind = {
  condition: new Set(["matched", "notMatched", "uncertain"]),
  interruptibility: new Set(["interruptible", "notInterruptible", "uncertain"]),
};

/**
 * 验证人工标注 benchmark 的公开格式，并把本地证据路径解析为 manifest 相对路径。
 */
export function validateBenchmarkManifest(value, baseDirectory) {
  assertRecord(value, "manifest must be an object");
  if (value.version !== 1) throw new Error("manifest version must be 1");
  if (!Array.isArray(value.cases) || value.cases.length === 0) {
    throw new Error("manifest cases must be a non-empty array");
  }
  const repetitions = positiveInteger(value.repetitions ?? 3, "manifest repetitions");
  const seenIDs = new Set();
  const cases = value.cases.map((entry, index) => {
    assertRecord(entry, `case ${index} must be an object`);
    const id = nonEmptyString(entry.id, `case ${index} id`);
    if (seenIDs.has(id)) throw new Error(`duplicate case id: ${id}`);
    seenIDs.add(id);
    const kind = nonEmptyString(entry.kind, `${id} kind`);
    const allowedExpected = expectedByKind[kind];
    if (!allowedExpected) throw new Error(`invalid kind for ${id}: ${kind}`);
    if (!allowedExpected.has(entry.expected)) {
      throw new Error(`invalid expected decision for ${kind}: ${entry.expected}`);
    }
    if (kind === "condition") nonEmptyString(entry.condition, `${id} condition`);
    return {
      id,
      kind,
      expected: entry.expected,
      ...(kind === "condition" ? { condition: entry.condition.trim() } : {}),
      repetitions: positiveInteger(entry.repetitions ?? repetitions, `${id} repetitions`),
      evidence: normalizeEvidence(entry.evidence, baseDirectory, id),
      ...(typeof entry.description === "string" ? { description: entry.description } : {}),
      ...(Array.isArray(entry.tags) ? { tags: entry.tags.map(String) } : {}),
    };
  });
  return { version: 1, repetitions, cases };
}

function normalizeEvidence(value, baseDirectory, id) {
  assertRecord(value, `${id} evidence must be an object`);
  const text = typeof value.text === "string" && value.text.trim() ? value.text : undefined;
  const textFile = localPath(value.textFile, baseDirectory);
  const image = localPath(value.image, baseDirectory);
  if (!text && !textFile && !image) {
    throw new Error(`${id} evidence must contain text, textFile, or image`);
  }
  return {
    ...(text ? { text } : {}),
    ...(textFile ? { textFile } : {}),
    ...(image ? { image } : {}),
  };
}

function localPath(value, baseDirectory) {
  if (typeof value !== "string" || !value.trim()) return undefined;
  return path.resolve(baseDirectory, value);
}

function positiveInteger(value, name) {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`);
  return value;
}

function nonEmptyString(value, name) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} must be non-empty`);
  return value.trim();
}

function assertRecord(value, message) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(message);
}
