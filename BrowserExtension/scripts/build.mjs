import { cp, mkdir, rm } from "node:fs/promises";
import { build } from "esbuild";

const outdir = new URL("../dist/", import.meta.url);
await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });

await build({
  entryPoints: {
    background: new URL("../src/background.ts", import.meta.url).pathname,
    content: new URL("../src/content.ts", import.meta.url).pathname,
    offscreen: new URL("../src/offscreen.ts", import.meta.url).pathname
  },
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "chrome116",
  outdir: outdir.pathname,
  sourcemap: false
});

await cp(new URL("../manifest.json", import.meta.url), new URL("manifest.json", outdir));
await cp(new URL("../offscreen.html", import.meta.url), new URL("offscreen.html", outdir));
await cp(new URL("../icons/", import.meta.url), new URL("icons/", outdir), { recursive: true });
