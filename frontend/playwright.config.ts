import { defineConfig, devices } from "@playwright/test";
import path from "node:path";

// ═══════════════════════════════════════════════════════
// Playwright 配置文件 (CI/本地通用)
// - CI 中读环境变量 PLAYWRIGHT_BASE_URL
// - 本地默认 http://localhost:9527 (前端 vite dev)
// ═══════════════════════════════════════════════════════
const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://localhost:9527";

export default defineConfig({
  testDir: path.resolve(__dirname, "e2e"),   // 把 e2e spec 从根移到 e2e/ 子目录，避免干扰构建
  testMatch: "**/*.spec.ts",
  fullyParallel: false,  // 聊天场景有副作用，串行更稳
  forbidOnly: !!process.env.CI,   // CI 禁止 test.only
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [
    ["list"],
    ["html", { open: "never" }],
    ["json", { outputFile: "playwright-report/results.json" }],
    ["junit", { outputFile: "playwright-report/results.junit.xml" }],
  ],
  outputDir: "test-results",
  timeout: 60_000,              // 单条 case 1 分钟上限
  expect: { timeout: 10_000 },

  use: {
    baseURL,
    trace: "retain-on-failure", // 失败时自动保留 trace，便于 CI 失败排错
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    actionTimeout: 15_000,
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 PaiSmartE2E/1.0",
    extraHTTPHeaders: {
      "x-paismart-e2e": "1",   // 便于后端/限流区分 E2E 流量
    },
  },

  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } },
    },
    {
      name: "firefox",
      use: { ...devices["Desktop Firefox"], viewport: { width: 1440, height: 900 } },
    },
    // 可按需开启
    // { name: 'webkit', use: { ...devices['Desktop Safari'] } },
    // { name: 'mobile-chrome', use: { ...devices['Pixel 5'] } },
  ],

  // 本地 playwright 开发调试时启本地 vite dev server (CI 不用，我们直接打 preview/或远程)
  webServer:
    process.env.PLAYWRIGHT_LOCAL_DEV === "1"
      ? {
          command: "cd frontend && pnpm dev",
          url: baseURL,
          reuseExistingServer: true,
          timeout: 60_000,
        }
      : undefined,
});
