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
    command: "PORT=3100 node server/index.js",
    url: "http://127.0.0.1:3100/api/info",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }]
});
