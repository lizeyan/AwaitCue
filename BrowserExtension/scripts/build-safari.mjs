import { build } from "esbuild";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";

const outdir = new URL("../../SafariExtension/dist/", import.meta.url);
await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });

await build({
  entryPoints: {
    background: new URL("../../SafariExtension/Resources/background.js", import.meta.url).pathname
  },
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "safari17",
  outdir: outdir.pathname,
  sourcemap: false
});

// Safari 与 Chromium 共用同一份 DOM/ARIA/状态属性提取实现，避免两个浏览器的判断证据逐渐漂移。
await build({
  entryPoints: {
    content: new URL("../src/content.ts", import.meta.url).pathname
  },
  bundle: true,
  define: { chrome: "browser" },
  format: "iife",
  platform: "browser",
  target: "safari17",
  outdir: outdir.pathname,
  sourcemap: false
});

const manifest = JSON.parse(
  await readFile(
    new URL("../../SafariExtension/Resources/manifest.json", import.meta.url),
    "utf8"
  )
);
manifest.version = process.env.VERSION ?? manifest.version;
await writeFile(
  new URL("manifest.json", outdir),
  `${JSON.stringify(manifest, null, 2)}\n`
);
await cp(new URL("../icons/", import.meta.url), new URL("icons/", outdir), {
  recursive: true
});
