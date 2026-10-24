import { readFile } from "node:fs/promises";
import path from "node:path";

/** 只从本地读取固定证据；原始图片与文字不会进入 benchmark 报告。 */
export async function loadEvidence(definition) {
  const textParts = [];
  if (definition.text) textParts.push(definition.text);
  if (definition.textFile) textParts.push(await readFile(definition.textFile, "utf8"));
  const image = definition.image
    ? {
        mediaType: mediaTypeForPath(definition.image),
        data: await readFile(definition.image),
      }
    : undefined;
  return {
    ...(textParts.length > 0 ? { text: textParts.join("\n").trim() } : {}),
    ...(image ? { image } : {}),
  };
}

function mediaTypeForPath(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
    case ".png": return "image/png";
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".webp": return "image/webp";
    case ".gif": return "image/gif";
    default: throw new Error(`unsupported benchmark image type: ${filePath}`);
  }
}
