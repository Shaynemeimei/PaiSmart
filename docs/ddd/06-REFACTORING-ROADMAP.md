# PaiSmart 渐进式 DDD 代码重构路线（10 步，零宕机、每步可回滚）

> **目标**：把当前技术分层 `controller / service / repository / entity`（横切），改成按 BC 分包的 DDD 四层结构。
>
> **总原则**：每一步都**不改行为、只改包结构 + 引入 Facade/Adapter 桥接旧新**；先补测试、小步快跑、每步 CI 通过 + Playwright E2E 通过再合主干。任何一步出问题，`git revert` 就能回去（没有破坏性迁移）。

---

## 先决条件（Step 0）：先有"安全网"，否则别重构

### Step 0.1 —— 必须有回归测试

| 工件 | 最低标准 |
|------|---------|
| **后端单元测试** | 覆盖率：Service ≥ 40%；重点 `ChatHandler.handleChat` / `DocumentService.delete` / `RechargeService.deliverBenefits` / `RateLimitService.tryAcquire` 必须有 10+ 用例 |
| **后端集成测试** | H2 内存库跑通：登录 → 传 invite 码注册 → 上传文件 → 等 Kafka consumer Mock → 调 /search → 调 /chat 接口完整链路；至少 3 条集成测试 |
| **前端 Playwright E2E** | 覆盖 4 条核心路径：登录 → 知识库上传 PDF → 等待解析 → 聊天提问（检查返回引用 1 条+）→ 历史会话列表可见 → 退出登录 |
| **手动冒烟用例清单** | PDF / Word / 图片 OCR / 组织权限 / 公开文档 / 管理员限流 / 微信沙箱支付 8 条，每步合主干前 30 分钟手动跑完 |

### Step 0.2 —— CI 必须有质量门禁

在后面做的"CI/CD"条目中，backend-ci.yml 里开启：覆盖率 < 阈值、E2E 失败、SpotBugs CRITICAL 都**阻塞合并**。重构代码最怕"改包名导致漏掉类，运行时才报错"。

---

## 第一阶段：不动"功能代码"，先把 DDD 骨架架起来（Step 1~3，1~2 天）

### Step 1：新建 SharedKernel 包 + 标识符 VO（最安全第一步，零风险）

**做什么**：
1. 新建 `com.yizhaoqi.smartpai.sharedkernel` 包：
   - `domain.vo.identifiers.UserId(Long value)` — 所有 Long userId 参数全改成 `UserId userId`（IDE Refactor → Change Signature 批量改）
   - `OrgTagId(String)` / `FileMd5(String)` / `ChunkId(FileMd5 + Integer index)` / `ConversationId(UUID)` / `TokenAmount(Long value, Type enum LLM/EMB)`
2. 每个 VO 带 `@Value`（Lombok） + `public static Xxx of(原始类型)` 工厂方法 + 参数校验（`FileMd5.of(s)` 校验长度 32、hex 正则）。
3. 现有 `model.User.id: Long` 先**不变**（避免 JPA 立即炸）。在 Service 层第一行 `final UserId owner = UserId.of(userIdLong)` 用 VO 传递；之后在 Step 7 再替换 Entity 字段类型。

**验证方式**：
- 现有的单元测试 + Playwright E2E 通过；
- 注意：Jackson 序列化 VO 时加 `JsonValue` 注解返回原始 value（避免前端收到嵌套对象）。

**回滚**：删除 sharedkernel 包，把 `UserId.of(x).value()` 改回 `Long x`。

---

### Step 2：在每个 BC 下建立 DDD 四层空包结构（物理先到位）

包路径（**先空包 + package-info.java，里面还没有类**）：

```
com/
└── yizhaoqi/
    └── smartpai/
        ├── sharedkernel/                          ← Step 1 已建好
        ├── identity/
        │   ├── domain/
        │   │   ├── model/        (Aggregate + Entity 将来放这里)
        │   │   ├── vo/
        │   │   ├── repository/   ← 放"Repository 接口"
        │   │   ├── service/      ← Domain Service 接口
        │   │   └── event/        ← Domain Event 类
        │   ├── application/      ← Application Service 编排
        │   ├── infrastructure/
        │   │   ├── persistence/  ← JPA Repository 实现 + JpaUserRepository 适配器
        │   │   └── acl/          ← 防腐层：调其他 BC
        │   └── interfaces/       ← REST Controller（原 controller/AuthController 将来搬这）
        ├── knowledgebase/
        │   └── {同样四层结构}
        ├── search/
        ├── chat/
        ├── billing/
        ├── systemadmin/
        ├── controller/           ← 原包（先不删，过渡期内放着，Step 8 才删）
        ├── service/              ← 原 service 包（先保留！）
        ├── repository/           ← 原 repository（先保留！）
        ├── entity/               ← 原 entity 包（先保留！）
        └── model/                ← 原 model（JPA @Entity 先保留，Step 7 才迁）
```

**验证**：`mvn compile` 通过 + 启动无 `ClassNotFoundException`。

---

### Step 3：先做"Repository 接口/实现分离"（DDD 规则最硬的一条：Repo 接口在 domain，实现在 infra）

**做什么（以 User 为例，一个 BC 入手）**：
1. 在 `identity.domain.repository` 下写接口：
```java
public interface UserRepository {
    Optional<User> findById(UserId id);
    Optional<User> findByUsername(Username username);
    boolean existsByUsername(Username username);
    void save(User user);
}
```
2. 在 `identity.infrastructure.persistence.jpa` 下写**适配器类**：
```java
@Repository
public class JpaUserRepositoryAdapter implements identity.domain.repository.UserRepository {
    // 桥接原有 Spring Data JPA 接口：com.yizhaoqi.smartpai.repository.UserRepository 先不改
    private final com.yizhaoqi.smartpai.repository.UserRepository jpaRepo;
    @Override
    public void save(User user) { jpaRepo.save(user); }  // 完全转发
    ...
}
```
3. **不要改现有类引用**。现在代码里两条路都能通：老 Service 调旧 `smartpai.repository.UserRepository`；新 Application Service 调新 `identity.domain.repository.UserRepository`。

**6 个 BC 全部按此套路：先写接口 + Adapter 转发，暂时 0 调用。**

**验证**：启动后端时 Spring 能扫描到 Adapter Bean（`@ComponentScan` 要覆盖 `com.yizhaoqi.smartpai`，当前已经是这个配置所以没问题）。

---

## 第二阶段：引入 DDD 分层调用（Step 4~6，1 周，开始替换老代码）

### Step 4：把 Controller → Service 双层调用 改成 Controller → ApplicationService → DomainService/Repository 三层

**选择一条最简单的用例先试水**：`POST /api/auth/profile (获取当前用户信息)`。

改造前：
```
UserController.getCurrentUser()
  → UserService.getCurrentUser(userId Long)
     → JPA UserRepository.findById(userId)  → return User Entity (带 password hash 字段直接给 Controller，危险！)
```

改造后：
```
(interfaces 包下) IdentityUserController.me()
  → (application) IdentityQueryApplicationService.getMe(UserId)
     → (domain.repository) UserRepository.findById  → return User
     → Mapper: User → MeResponse DTO (**不暴露 passwordHash / role 按需要脱敏**)
  → return ResponseEntity.ok(MeResponse)
```

关键点：**老 `UserService.getCurrentUser()` 先保留，只是被 `IdentityUserController.me()` 改为调用新 ApplicationService**。等 E2E 登录接口正常 2 周后，再删除老方法（Step 8）。

**完成标志**：所有 Controller 的 30 个接口一个一个地完成改造。完成后 Controller 里**没有业务 if**，只能有：
- 参数校验 `@Valid`
- 调用 Application Service 的一个方法
- 返回 HTTP 状态码 + DTO

---

### Step 5：提炼业务规则到 Domain Service / Aggregate 内部方法（⭐ DDD 核心）

**目标**：老 Service 里散落的 200 个 `if/else` 按 UL 移到 Domain 层。

**3 个最该先拆的例子（ChatHandler/Billing 最多 if）**：

| 现有 if 所在位置 | 移到哪个 Domain Service / Aggregate 方法 | 方法签名建议 |
|-----------------|------------------------------------------|-------------|
| `ChatHandler` 第 150~180 行：`if (balance < estimated) throw 余额不足`（分散在三处） | `billing.domain.service.TokenConsumptionPolicy.reserve()` | `TokenReservation reserve(UserId userId, TokenType type, long estimatedAmount)` 一次性完成"余额校验 + 预扣占位" |
| `OrgTagAuthorizationFilter` + `SearchController` + `DocumentService` 三处各自拼 `userId == owner OR isPublic OR orgTag in ...` 条件 | `identity.domain.service.OrgTagAccessPolicy.buildEsFilter()` + `assertCanAccessFile()` | 一个地方维护规则，三处全部调这个 DS |
| `RechargeService` 微信回调中订单状态机 if 顺序散落不同方法 | `RechargeOrder.markAsPaid(txnId, time)` + `transitionTo(DELIVERING) / transitionTo(DELIVERED)` 聚合内部状态机；非法转移直接抛 DomainException | `order.markAsPaid(...)` 内部先检查 `status == CREATED`，否则抛 `IllegalOrderStateDomainException` |

**验收标准**：每写一个 Domain Service，把老 Service 里对应的所有 if 分支删掉。代码统计：**老 service 包总行数下降 40%+，domain.service 包 + Aggregate 内部方法总行数相应上升**。

---

### Step 6：引入 Domain Event 机制（跨 BC 解耦的最后一块）

**做什么**：
1. Shared Kernel 里加 `DomainEventPublisher` 接口：
```java
public interface DomainEventPublisher {
    void publish(DomainEvent event);
}
```
2. Infrastructure 实现：`SpringApplicationEventPublisher`（用 Spring `ApplicationEventPublisher.publishEvent`） + `KafkaDomainEventPublisher`（跨 BC 的事件走 Kafka，例如 Billing → KB 需要异步可靠投递）。
3. 用 `@TransactionalEventListener(phase = AFTER_COMMIT)` 保证"数据库事务提交成功后才发事件"（避免订单回滚但权益事件发出去了的双写不一致）。
4. **先替换 3 个最关键的跨 BC 调用**：
   - User 注册成功：Identity ApplicationService 发 `UserRegisteredEvent` → Billing BC Listener 初始化 UserTokenAccount seed + 发 `TokenBalanceChangedEvent`
   - 文档合并完成：KB ApplicationService 发 `FileUploadedAndMergedEvent` → FileProcessingConsumer 监听到后调 parse+chunk+vector（之前直接 new KafkaTemplate.send，改为 event→publisher→kafka）
   - Chat 完成：ChatApplicationService 发 `ChatTurnCompletedEvent` → Billing Listener 调 `TokenConsumptionPolicy.settleReservation(actualUsage)` 扣费

**重要**：先不要删掉老的直接调用代码，改为"Event + 双写观察 1 周，日志一致率 100% 后再删老调用"。

---

## 第三阶段：替换 Entity 字段 + 迁移持久化（Step 7~9，2~3 周，最需要小心）

### Step 7：把 JPA @Entity 注解从 Domain 中剥离（引入 Persistence DTO）

当前 `model.User` 同时是"领域模型"和"持久化映射"，违反 DDD（领域应该不依赖 JPA）。

**改造方案（零停机双轨）**：
1. 新建 `identity.infrastructure.persistence.jpa.UserJpaDO`（Data Object，把原来 model.User 上所有 `@Entity/@Table/@Column` 挪到这个类里；字段名和列完全保持一致以兼容现有 SQL）。
2. 新建 `UserJpaDOMapper`：`User domain <-> UserJpaDO`（手写或 MapStruct 生成）。
3. 把刚才 Step 3 写的 `JpaUserRepositoryAdapter` 里的转发改成：`jpaDO = jpaRepo.findById() → mapper.toDomain(dO)` 返回，保存时 `toDO(user) → jpaRepo.save(DO)`。
4. 现在可以**把 `identity.domain.model.User` 上所有 Jakarta Persistence 注解删掉**，User 变成纯粹的 POJO Domain Aggregate（只含业务规则，没有框架依赖）✅。

对所有 14 个 Entity 做一次；之后就可以直接写测试 User Aggregate 的纯 Java 单元测试（不需要 Spring/H2）。

---

### Step 8：删除旧技术分层里所有空壳类（Controller / Service / Repository / Entity）

**检查清单**：
- 所有 Controller 接口调用的 ApplicationService 均已在 `bc.interfaces` 下实现 & Playwright 通过 → 可删旧 `smartpai.controller.*`
- 所有老 Service 类中 if 已经全部移动到 DomainService / Aggregate → 可删旧 `smartpai.service.*`
- 所有 Spring Data JPA `Repository` 接口都被 `bc.infrastructure.persistence.jpa.*RepositoryAdapter` 持有 → 可以把旧接口移到 `infra.persistence.jpa` package 下，`smartpai.repository` 包删空后删掉
- 旧 `smartpai.model` 包：JPA DO 都已迁 `bc.infra.persistence.jpa.*JpaDO` → 删 `model` 包

**注意**：这一步**可以分 BC 逐个删**（先删 Identity 两周没问题，再删 KB、Chat...），不要一口气全删。

---

### Step 9：数据库 Schema 变更——DDD 后 ERD 的小改动（通过 Flyway/Liquibase 版本化迁移）

5 张分域 ERD 中有 3 处结构变化必须改数据库，使用 Flyway `V3__ddd_schema_migrations.sql` 迁移脚本：

| # | 迁移 | SQL | 风险控制 |
|---|------|-----|---------|
| 9.1 | 新增 join 表 `users_org_tags_join`（把 users.org_tags CSV 拆成关系表，便于 org 内成员查询） | ① 建表 → ② 读所有 users.org_tags，一行一个 orgTagId 用 WHILE 循环插进去 → ③ 加 UK → ④ 代码先双写（新增 join+CSV，读 join 表）→ ⑤ 2 周后删 CSV 列 | **灰度双写 2 周**；不要直接删 CSV 列 |
| 9.2 | `conversations` 拆表成 `conversations + conversation_turns`（DDD 改进：现有 1 行=1 轮，将来 1 行=1 容器 + N 轮） | ① 新建 `conversation_turns` 表 → ② 用 `INSERT INTO turns (...) SELECT turn 字段 FROM conversations ORDER BY conversation_id, timestamp` 回填；**回填时按 conversation_id 分组生成 turn_index 1..N** → ③ 代码双写两周：写 conversation_turns + 老 conversations；读优先读 turns，fallback 老表 → ④ 2 周后老 conversations 表改成 `conversations_old_archive` 保留 3 个月再删 | **备份 + 读 fallback**；迁移脚本在 staging 先跑真实数据 1000 条回归 |
| 9.3 | `chunk_info` 重命名为 `upload_chunks`（UL 中澄清"Chunk=两种：UploadChunk vs TextChunk/DocumentVectorChunk"） | `RENAME TABLE chunk_info TO upload_chunks;` 加上注释和对应 Java 类重命名（Step 7 已做） | 风险低，改完立刻回归断点续传 |

所有 Flyway 迁移先在 Staging 用生产备份数据跑一次，检查：
- `SELECT COUNT(*) FROM old_table` vs `new_table` 行数一致
- 随机抽 20 条对话、20 个文档、20 个用户组织关系，前端显示一致

---

## 第四阶段：收尾 & 合规（Step 10）

### Step 10：DDD 架构守护（防止"新代码又写回 Controller"）

1. **写 3 个 ArchUnit 测试**（backend-ci 里每次跑，违反直接 FAIL）：
```java
// 1. Domain 层不允许引用 Jakarta Persistence / Spring Framework 任何注解包
noClasses().that().resideInAPackage("..domain..").should()
  .dependOnClassesThat().resideInAnyPackage("jakarta.persistence..", "org.springframework..")
  .because("DDD 规则：Domain 层不得依赖框架");

// 2. Controller 不允许直接 import Repository
noClasses().that().resideInAPackage("..interfaces..").should()
  .accessClassesThat().resideInAPackage("..repository..")
  .because("必须走 ApplicationService 编排，不能接口直连持久化");

// 3. 跨 BC 不允许直接 import 对方 domain model（必须通过 ACL Facade 接口）
noClasses().that().resideInAPackage("com.yizhaoqi.smartpai.chat.domain..").should()
  .dependOnClassesThat().resideInAPackage("com.yizhaoqi.smartpai.identity.domain.model..")
  .because("Chat 不能直接持有 User Entity；必须通过 IdentityAclFacade 解耦");
```

2. **代码评审模板加入 DDD 三项检查清单**（每个 PR Reviewer 必须确认）：
   - [ ] 改动的规则是否放在 Domain Service / Aggregate 内部？（不是 Application / Controller / Infra）
   - [ ] 跨 BC 调用是否通过 Domain Event 或 ACL Facade 接口？（没有直接 import 对方 domain class）
   - [ ] 新增的类有没有归属到正确的 BC 包 + DDD 层？（不允许再往 `smartpai.service` 老包塞类）

3. **补一份 DDD 快速入门 onboarding 文档**：`docs/ddd/HOW-TO-ADD-NEW-FEATURE.md`，新成员 30 分钟学会"我要加 XX 功能，代码应该写在哪层、哪个 BC"。

---

## 里程碑时间估算（按 2 名后端全栈 + 1 名资深 Dev 带队）

| 阶段 | Step | 工作量 | 日历时间 |
|------|------|--------|---------|
| 安全网 | 0.1+0.2 | 写 Playwright E2E 4 条 + ArchUnit | 3 天 |
| 骨架搭建 | 1+2+3 | SharedKernel + 空包结构 + 所有 Repository 接口+Adapter | 2 天 |
| 分层调用 | 4+5+6 | 30 个接口迁 Application + if 下沉 Domain Service + 3 个核心 Event | 10 天 |
| 迁移持久化 | 7+8+9 | JPA DO 映射 + 拆包删除旧类 + 3 个 Flyway 迁移 | 10 天 |
| 收尾守护 | 10 | ArchUnit 3 条 + CODEOWNERS + onboarding 文档 | 2 天 |
| **合计** | - | - | **约 27 个工作日 = 5~6 周** |

> 经验：**第一阶段骨架 + 第二阶段调用分层（前 15 天）完成时，项目已经是"名义 DDD"了，评审已经能展示 7 个 BC + Context Map + Aggregate 图**。Step 7~9（剥离 JPA + DB 迁移）是深度改善、可以放到 P1 迭代里继续做，不阻塞 DDD 评审交付。

---

## 每步合主干前的"门禁 6 条"

重构最怕"越重构 bug 越多"。每步合之前必须签：

1. [ ] `mvn test` 全部通过（新增/修改的单测覆盖率 ≥ 70%）
2. [ ] `mvn -q -DskipTests compile` 通过（无弃用警告新增）
3. [ ] SpotBugs / OWASP Dependency Check 无新 CRITICAL / HIGH
4. [ ] Playwright E2E 4 条主路径**全部绿**（截图留存）
5. [ ] 手动冒烟 8 条通过（30 分钟 / 2 人交叉点）
6. [ ] `kubectl apply -k k8s/overlays/dev` 启动后烟雾 `/actuator/health/readiness` + `/api/auth/me` + `/api/search?keyword=测试` + `/chat` 一问一答 OK

6 条全通过 → 合并主干；有任何一条挂 → 先修再合，绝不带病上路。
