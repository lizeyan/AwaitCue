import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["tests/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text", "html", "lcov"],
      include: ["src/**/*.ts"],
      // Chrome API 入口只能在真实扩展环境执行；业务解析、几何和页面证据必须计入门禁。
      exclude: ["src/background.ts", "src/content.ts"],
      thresholds: {
        lines: 90,
        functions: 90,
        statements: 90,
        branches: 90
      }
    }
  }
});
