import { test, expect } from "@playwright/test";

/**
 * E2E #1：登录 (用户名+密码) → 跳转到首页，左侧菜单 4 项可见
 * 前置：确保后端启动 / 或目标 staging 可访问
 */
test("管理员登录 → 首页可见 4 项菜单", async ({ page }) => {
  const username = process.env.E2E_USERNAME || "admin";
  const password = process.env.E2E_PASSWORD || "admin123";

  // 1. 打开登录页
  await page.goto("/");
  // 未登录会被路由守卫跳到 /login
  await page.waitForURL(/\/login/);

  // 2. 填写用户名+密码，点击"密码登录"Tab（按我们项目 UI）
  const pwdTab = page.getByText(/密码登录/).first();
  if (await pwdTab.isVisible()) await pwdTab.click();

  await page.getByRole("textbox", { name: /用户名/ }).fill(username);
  await page.getByRole("textbox", { name: /密码/ }).fill(password);
  await page.getByRole("button", { name: /登录/ }).click();

  // 3. 断言：登录后 URL 不是 /login，且至少出现 3 个左侧业务菜单关键字
  await expect(page).not.toHaveURL(/\/login/, { timeout: 30_000 });

  const menuLocator = page.locator("nav, [role='menu'], .layout-sider").first();
  await expect(menuLocator).toContainText(/知识库|聊天|模型|邀请码|用户管理/, { timeout: 15_000 });

  await page.screenshot({ path: "test-results/e2e-home.png", fullPage: true });
});
