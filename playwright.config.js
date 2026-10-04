import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 240_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [["list"]],
  use: { baseURL: "http://127.0.0.1:3100", trace: "off" },
  webServer: {
    command: "node scripts/make-config.mjs && PORT=3100 node scripts/dev-server.mjs",
    url: "http://127.0.0.1:3100/",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }]
});
