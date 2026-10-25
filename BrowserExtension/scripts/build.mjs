import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const extensionRoot = fileURLToPath(new URL("..", import.meta.url));
const outdir = join(extensionRoot, "dist");
const manifestPath = join(extensionRoot, "manifest.json");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const version = process.env.VERSION ?? manifest.version;
if (!isChromeExtensionVersion(version)) {
  throw new Error(`Invalid Chrome extension version: ${version}`);
}
manifest.version = version;

await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });

await build({
  entryPoints: {
    background: join(extensionRoot, "src", "background.ts"),
    content: join(extensionRoot, "src", "content.ts")
  },
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "chrome116",
  outdir,
  sourcemap: false
});

await writeFile(
  join(outdir, "manifest.json"),
  `${JSON.stringify(manifest, null, 2)}\n`
);
await cp(join(extensionRoot, "icons"), join(outdir, "icons"), { recursive: true });

/** Chrome Web Store 只接受 1-4 段、每段 0...65535 且整体不全为 0 的十进制版本。 */
function isChromeExtensionVersion(value) {
  const parts = value.split(".");
  return parts.length >= 1 &&
    parts.length <= 4 &&
    parts.some((part) => Number(part) !== 0) &&
    parts.every((part) => /^(0|[1-9]\d*)$/.test(part) && Number(part) <= 65_535);
}
