import { execFile } from "node:child_process";
import { readFile, readdir, rm, stat, utimes } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { promisify } from "node:util";

const execute = promisify(execFile);
const extensionRoot = resolve(new URL("..", import.meta.url).pathname);
await execute("node", ["scripts/build.mjs"], { cwd: extensionRoot });

const manifest = JSON.parse(await readFile(join(extensionRoot, "manifest.json"), "utf8"));
const outputPath = join(extensionRoot, "dist", `awaitcue-chromium-${manifest.version}.zip`);
await rm(outputPath, { force: true });
const dist = join(extensionRoot, "dist");
const files = (await listFiles(dist))
  .filter((file) => !file.endsWith(".zip"))
  .sort();

// ZIP 会记录文件时间；统一时间戳与条目顺序，确保同一源码生成相同字节。
const fixedTime = new Date("2020-01-01T00:00:00Z");
for (const file of files) {
  await utimes(join(dist, file), fixedTime, fixedTime);
}
await execute("/usr/bin/zip", ["-X", "-q", outputPath, ...files], { cwd: dist });
console.log(outputPath);

async function listFiles(root) {
  const result = [];
  const visit = async (directory) => {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if ((await stat(path)).isFile()) result.push(relative(root, path));
    }
  };
  await visit(root);
  return result;
}
