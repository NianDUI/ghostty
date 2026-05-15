import { defineConfig, devices } from "@playwright/test";

// User's shell exports HTTP_PROXY=http://127.0.0.1:7890 (Clash etc.).
// Playwright's webServer probe uses node http, which routes through the
// proxy; the proxy returns 400 for any unreachable upstream, fooling
// Playwright into "server already up — skip starting" — and then the
// real browser hits ECONNREFUSED on 5173. Force loopback to bypass.
if (!process.env.NO_PROXY) {
  process.env.NO_PROXY = "localhost,127.0.0.1,::1";
}

// Playwright config for the session-sharing web client.
// Test target = local vite dev server (auto-started by webServer below).
// All backend (HTTP + WebSocket) is mocked via page.route / page.routeWebSocket
// inside each spec, so no relay/agent is required to run e2e tests.
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: "http://localhost:5173",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  webServer: {
    // Call vite directly to dodge npm's argv forwarding quirks under
    // child_process.spawn — `npm run dev -- --port 5173` silently
    // failed to bind in the Playwright runner, leaving every test
    // with ERR_CONNECTION_REFUSED.
    command: "npx vite --port 5173 --strictPort",
    url: "http://localhost:5173",
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
    stdout: "ignore",
    stderr: "pipe",
  },
  projects: [
    {
      name: "desktop-chromium",
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: "mobile-pixel5",
      use: { ...devices["Pixel 5"] },
    },
  ],
});
