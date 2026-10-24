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
    const tags = Array.isArray(entry.tags) ? entry.tags.map(String) : [];
    const surface = evidenceSurface(kind, tags, id);
    return {
      id,
      kind,
      expected: entry.expected,
      ...(kind === "condition" ? { condition: entry.condition.trim() } : {}),
      repetitions: positiveInteger(entry.repetitions ?? repetitions, `${id} repetitions`),
      evidence: normalizeEvidence(entry.evidence, baseDirectory, id, surface),
      ...(typeof entry.description === "string" ? { description: entry.description } : {}),
      tags,
    };
  });
  return { version: 1, repetitions, cases };
}

function normalizeEvidence(value, baseDirectory, id, surface) {
  assertRecord(value, `${id} evidence must be an object`);
  const text = typeof value.text === "string" && value.text.trim() ? value.text : undefined;
  const textFile = localPath(value.textFile, baseDirectory);
  const image = localPath(value.image, baseDirectory);
  if (!text && !textFile && !image) {
    throw new Error(`${id} evidence must contain text, textFile, or image`);
  }
  if (surface === "browser" && (image || (!text && !textFile))) {
    throw new Error(`${id} browser evidence must be DOM-only`);
  }
  if (surface === "app" && (!image || text || textFile)) {
    throw new Error(`${id} app evidence must be image-only`);
  }
  if (surface === "active-window" && (!image || textFile)) {
    throw new Error(`${id} interruptibility evidence must be an active-window image`);
  }
  return {
    ...(text ? { text } : {}),
    ...(textFile ? { textFile } : {}),
    ...(image ? { image } : {}),
  };
}

function evidenceSurface(kind, tags, id) {
  if (kind === "interruptibility") {
    if (!tags.includes("active-window") || tags.includes("browser") || tags.includes("app")) {
      throw new Error(`${id} interruptibility evidence must use the active-window surface`);
    }
    return "active-window";
  }
  const surfaces = ["browser", "app"].filter((surface) => tags.includes(surface));
  if (surfaces.length !== 1) {
    throw new Error(`${id} must declare exactly one evidence surface: browser or app`);
  }
  return surfaces[0];
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
