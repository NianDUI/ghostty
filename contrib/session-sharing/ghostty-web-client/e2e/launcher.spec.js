import { expect, test } from "@playwright/test";

// Reset localStorage before every page load — addInitScript runs before
// any user script on the page, so main.js reads a clean store on boot.
test.beforeEach(async ({ context }) => {
  await context.addInitScript(() => {
    try {
      window.localStorage.clear();
    } catch {}
  });
});

const mockSessions = [
  {
    id: "demo-1",
    name: "demo-session",
    online: true,
    last_seen_at: new Date().toISOString(),
    client_token: "client-token-1",
  },
];

async function mockSessionsAPI(page, sessions = mockSessions) {
  await page.route("**/api/sessions", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(sessions),
    }),
  );
}

test.describe("launcher routing", () => {
  test("first visit without token lands on settings page", async ({ page }) => {
    await mockSessionsAPI(page);
    await page.goto("/");

    await expect(page.locator("#launcherSettingsView")).toBeVisible();
    await expect(page.locator("#launcherHomeView")).toBeHidden();
    // Back button is disabled until a token is filled in — otherwise the
    // user could escape to an empty session list.
    await expect(page.locator("#closeSettings")).toBeDisabled();
  });

  test("saving a token jumps to the home view and renders sessions", async ({
    page,
  }) => {
    await mockSessionsAPI(page);
    await page.goto("/");

    await page.locator("#token").fill("test-token");
    await page.locator("#saveToken").click();

    await expect(page.locator("#launcherHomeView")).toBeVisible();
    await expect(page.locator("#launcherSettingsView")).toBeHidden();
    await expect(page.locator("#sessionMeta")).toContainText("1 在线");
    await expect(page.locator("#sessionList .session")).toHaveCount(1);
  });

  test("returning user lands on home, gear opens settings, back returns home", async ({
    page,
    context,
  }) => {
    await mockSessionsAPI(page);
    await context.addInitScript(() => {
      window.localStorage.setItem("ghostty-sharing-token", "seeded-token");
    });
    await page.goto("/");

    await expect(page.locator("#launcherHomeView")).toBeVisible();

    await page.locator("#openSettings").click();
    await expect(page.locator("#launcherSettingsView")).toBeVisible();
    await expect(page.locator("#closeSettings")).toBeEnabled();

    await page.locator("#closeSettings").click();
    await expect(page.locator("#launcherHomeView")).toBeVisible();
  });

  test("clearing the token disables the back button while on settings", async ({
    page,
    context,
  }) => {
    await mockSessionsAPI(page);
    await context.addInitScript(() => {
      window.localStorage.setItem("ghostty-sharing-token", "seeded-token");
    });
    await page.goto("/");

    await page.locator("#openSettings").click();
    await expect(page.locator("#closeSettings")).toBeEnabled();

    await page.locator("#token").fill("");
    await expect(page.locator("#closeSettings")).toBeDisabled();

    await page.locator("#token").fill("recovered");
    await expect(page.locator("#closeSettings")).toBeEnabled();
  });
});
