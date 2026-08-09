## 🧾 PaiSmart · Pull Request 模板

<!--
  开 PR 前请：
  1. 本地先跑 `make coverage sonar`（后端）+ `cd frontend && pnpm typecheck && pnpm lint`（前端）
  2. 涉及前后端接口变化的，请同时更新前后端代码 + E2E（frontend/e2e/*.spec.ts）
  3. 涉及 DDD 分层的，本地跑 `mvn test -Dtest=DddArchitectureGuardTest` 确保 ArchUnit 3 条规则不崩
-->

### 🎯 这个 PR 做了什么？（请用一句话说明 + 关联 Issue 编号）
- Resolves #<issue_id>
- 简述：...

---

### 🧪 测试（打 ✅ 代表完成）
- [ ] **后端 JUnit**：`mvn -q verify -P coverage` 全部通过；覆盖率 ≥ 当前基线（如果下降请说明原因）
- [ ] **前端 typecheck**：`pnpm typecheck` 0 errors
- [ ] **前端 lint**：`pnpm lint --max-warnings 0` 0 warnings
- [ ] **E2E Playwright**：本地 `pnpm e2e` 4 条核心路径通过（改动到登录/聊天/上传相关必须勾选）
- [ ] **DDD ArchUnit 守护**：ArchUnit 3 条规则都 pass（过渡期 allowEmptyShould=true，但请把新类放到对应 BC 包）

### 🔒 安全 & 合规（打 ✅ 代表完成）
- [ ] **Trivy FS 扫描**：本 PR 没有引入新的 CRITICAL/HIGH CVE（可在本地 `make trivy-fs`）
- [ ] **没有硬编码 Secret / API Key / Token**（违反此项 PR 直接打回）
- [ ] **接口鉴权**：新增的 REST Controller 都加了 `@PreAuthorize` 或在 SecurityWebFilterChain 里显式放白名单

### 🧱 工程化规范（DDD + 多租户）
- [ ] **Controller 不直连 Repository**：所有跨层调用都走 Service（ArchUnit 规则会自动查）
- [ ] **Domain 层无框架依赖**：`..domain..` 包下没有 import jakarta.persistence.* / org.springframework.stereotype.*
- [ ] **多租户过滤**：新增的 Query / Repository 方法都按 orgTag 过滤（除非是 SysAdmin 管理后台方法，需明确说明）

### 📷 截图 & 前后对比（UI / 前端改动必须贴）
| 模块 / 页面 | Before | After |
|-------------|--------|-------|
| （例）首页 Dashboard | 贴截图 | 贴截图 |
| | | |

### 📝 其它说明（可选）
- 需要评委特别关注的点：
- 可能的回滚方案（如果是大的重构 PR）：
