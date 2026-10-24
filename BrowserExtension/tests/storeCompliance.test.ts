import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

const extensionRoot = process.cwd();

describe("Chrome Web Store package", () => {
  it("declares only permissions required by the single purpose", () => {
    const manifest = JSON.parse(readFileSync(join(extensionRoot, "manifest.json"), "utf8"));

    expect(manifest.manifest_version).toBe(3);
    expect(manifest.permissions).toEqual([
      "nativeMessaging",
      "scripting",
      "storage"
    ]);
    expect(manifest.host_permissions).toEqual(["http://*/*", "https://*/*"]);
    expect(manifest.icons).toEqual({
      "16": "icons/icon-16.png",
      "32": "icons/icon-32.png",
      "48": "icons/icon-48.png",
      "128": "icons/icon-128.png"
    });
    for (const icon of Object.values(manifest.icons) as string[]) {
      expect(existsSync(join(extensionRoot, icon))).toBe(true);
    }
  });

  it("builds a self-contained package without source maps or remote code", () => {
    execFileSync("node", ["scripts/build.mjs"], { cwd: extensionRoot });

    const files = walk(join(extensionRoot, "dist"));
    expect(files).toEqual([
      "background.js",
      "content.js",
      "icons/icon-128.png",
      "icons/icon-16.png",
      "icons/icon-32.png",
      "icons/icon-48.png",
      "manifest.json"
    ]);
    const executableText = files
      .filter((file) => file.endsWith(".js") || file.endsWith(".html"))
      .map((file) => readFileSync(join(extensionRoot, "dist", file), "utf8"))
      .join("\n");
    expect(executableText).not.toMatch(/<script[^>]+src=["']https?:/i);
    expect(executableText).not.toMatch(/\beval\s*\(|\bnew\s+Function\s*\(/);
    expect(executableText).not.toMatch(/sourceMappingURL/);
  });

  it("creates the same store ZIP from the same source", () => {
    const firstPath = execFileSync("node", ["scripts/package-store.mjs"], {
      cwd: extensionRoot,
      encoding: "utf8"
    }).trim();
    const firstHash = sha256(firstPath);
    const secondPath = execFileSync("node", ["scripts/package-store.mjs"], {
      cwd: extensionRoot,
      encoding: "utf8"
    }).trim();

    expect(secondPath).toBe(firstPath);
    expect(sha256(secondPath)).toBe(firstHash);
    const entries = execFileSync("/usr/bin/unzip", ["-Z1", secondPath], {
      encoding: "utf8"
    }).trim().split("\n");
    expect(entries[0]).toBe("background.js");
    expect(entries).toContain("manifest.json");
    expect(entries).not.toContain("dist/manifest.json");
  });
});

function walk(root: string): string[] {
  const files: string[] = [];
  const visit = (directory: string) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) visit(path);
      else files.push(relative(root, path));
    }
  };
  visit(root);
  return files.sort();
}

function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}
