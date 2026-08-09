# Billing & Quota (计费与配额) + System Admin (运维配置) + Shared Kernel 设计

这三个 BC 都是"支撑域"，业务规则比 Chat 少，但数据一致性要求高（尤其是 Billing 的 Token 流水必须 100% 正确，一分钱不能错）。

---

## 一、BC 5：Billing & Quota

> 包路径：`com.yizhaoqi.smartpai.billing`
> 现有关联代码：`RechargeService` / `WxPayService` / `UserTokenService` / `UsageQuotaService` / `UsageBalanceQuotaService` / `UsageDashboardService` / `UsageBalanceDashboardService` / `TokenCacheService` / `RechargeOrderRepository` / `RechargePackageRepository` / `UserTokenRecordRepository` / `UserDailyChatCountRepository`
> **设计原则**：单一账本原则（Single Source of Truth）——**只有 `UserTokenRecord` 这一张流水表**是 Token 余额真相；Dashboard 统计表（DailyUsageStat / DailyReqCountStat / UserDailyChatCount）都是物化视图 / 读模型，只从流水事件聚合，永远不能反过来改流水。

### 1.1 Aggregate 结构（3 个 AR + 1 读模型）

```
┌─ Aggregate: RechargePackage (AR, 运营商品) ─────────────────────────────────┐
│   运营可上下架的"充值套餐"；价格/权益变更走"停用旧 + 建新"，尽量不 EDIT 历史   │
│                                                                              │
│   - packageId             Int PK (业务 ID，对外展示)                          │
│   - name                  String (例:"年卡 PRO 10 亿 token")                │
│   - displayOrder          Int (前端商品页排序)                               │
│   - priceCents            Long (人民币 分，必须 > 0)                         │
│   - currency              Currency: CNY (预留)                               │
│   - llmTokenGrant         LlmTokenAmount (正整数，发放到用户余额)             │
│   - embeddingTokenGrant   EmbeddingTokenAmount (正整数)                      │
│   - validDays             Int? (null = 永久，例 365=年卡)                    │
│   - isVisibleOnStore      boolean (前台是否展示)                             │
│   - tag                   PackageTag? Enum: NEW / HOT / RECOMMENDED / LIMIT  │
│   - perUserLimit          Int? (同一用户最多买 N 份，null 不限)              │
│   - description           String (富文本或 Markdown)                         │
│   - createdAt / updatedAt Instant                                           │
│   - publishedAt           Instant? (null = 草稿)                             │
│   - unpublishedAt         Instant?                                          │
│                                                                              │
│   Invariants：                                                               │
│   • priceCents > 0；llmTokenGrant + embeddingTokenGrant 至少一个 > 0        │
│   • publishedAt 非空 ↔ 已上架；unpublishedAt ≥ publishedAt                  │
│   • validDays 如果设置必须 ≥ 1                                               │
│   • 上架后 priceCents / tokenGrant **禁止直接修改**（改价格必须建新套餐）    │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: RechargeOrder (AR, 💰 订单事务核心) ─────────────────────────────┐
│   一次"购买套餐 → 微信支付 → 发放 Token 权益"的生命周期聚合；状态机是生命线    │
│                                                                              │
│   - orderId               Long DB PK (内部)                                  │
│   - tradeNo               String (业务单号，微信 V3 out_trade_no，全局唯一)  │
│   - buyerUserId           UserId                                             │
│   - packageId             Int? (购买的具体套餐；null = 管理员后台人工充值)    │
│   - priceCents            Long (快照：下单时套餐多少钱，后续改价不影响本单)  │
│   - llmTokenGrant         LlmTokenAmount (快照权益，后续改套餐不影响)        │
│   - embeddingTokenGrant   EmbeddingTokenAmount (快照)                        │
│   - validUntil            Instant? (套餐有效期快照；=下单时 + validDays)     │
│   - payChannel            PayChannelEnum: WECHAT_V3 / ALIPAY / BALANCE /    │
│                                                    ADMIN_MANUAL              │
│   - payTransactionId      String? (微信 wx_transaction_id)                  │
│   - status                OrderStatus (状态机，见 Invariants)                │
│     CREATED → PAID → DELIVERING → DELIVERED (终态成功)                      │
│       ↓        ↓                                                            │
│     EXPIRED  PAY_FAILED (终态失败)                                           │
│     CLOSED (用户主动取消)                                                    │
│   - statusHistory         List<StatusChange> (审计：谁、何时、因什么改状态)  │
│   - failureReason         String? (PAY_FAILED / DELIVERING → 失败原因)      │
│   - description           String?                                            │
│   - payCallbackRawBody    String? (微信回调原报文，审计保存；不可改)          │
│   - createdBy             UserId? (ADMIN 代充时记录管理员)                  │
│   - createdAt / payTime / deliveredAt Instant?                              │
│                                                                              │
│   Invariants (核心业务规则)：                                                │
│   • 状态转移必须严格按有限状态机；非法转移抛 `IllegalOrderStateDomainException`│
│   • PAID 时 priceCents 必须和微信回调的 cash_fee 一致；签名必须验证通过      │
│   • DELIVERING → DELIVERED 必须是一次原子事务：                               │
│     (写入 UserTokenRecord 两条 GRANT + 更新余额快照 + 发 PaymentSucceededEvent│
│     全部成功才算 DELIVERED；失败回到 DELIVERING 后台重试任务补偿)            │
│   • 同一个 tradeNo 绝不允许重复发放权益（幂等 Key）                          │
│   • 同一个 orderId，状态 = DELIVERED 后，任何字段只读                        │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: UserTokenAccount (AR, 🔮 新建：代替散落多处的 Token 计数器) ─────┐
│   ⚠️ 注意：这是一个"余额快照（Cache / Materialized View）"，它的唯一真相源头是│
│   追加式流水表 UserTokenRecord。任何"扣减/发放"操作必须以"写流水 + 更新快照" │
│   一个事务完成；并且 snapshotBalance 必须等于流水求和（有定时对账任务）       │
│                                                                              │
│   - ownerUserId           UserId PK                                          │
│   - llmTokenBalance       LlmTokenAmount >= 0                                │
│   - embeddingTokenBalance EmbeddingTokenAmount >= 0                          │
│   - grantTotalLlm         LlmTokenAmount (累计发放，只读统计)                │
│   - consumeTotalLlm       LlmTokenAmount (累计消耗)                          │
│   - balanceLastUpdatedAt  Instant                                            │
│   - version               Long @Version (JPA 乐观锁，防并发扣减超卖)         │
│                                                                              │
│   Domain Methods（只允许这几个方式变更；外部不能直接 setBalance）：          │
│   • grantFromOrder(RechargeOrder order, Instant at) → 返回要写入流水的列表   │
│   • consumeForChat(UserId, LlmTokenAmount used, String bizId)                │
│   • consumeForEmbedding(UserId, EmbeddingTokenAmount used, String bizId)     │
│   • refund(String bizId, LlmTokenAmount amount, String reason)               │
│                                                                              │
│   Invariants：                                                               │
│   • llmTokenBalance + consumeTotalLlm = grantTotalLlm (+ 初始 seed)          │
│     【日对账任务校验，不一致产生 Incident 告警】                              │
│   • 扣减时余额 ≥ 0；不足抛 `InsufficientBalanceDomainException`               │
│   • 并发扣减：JPA @Version 乐观锁 + DB 行级 `UPDATE ... WHERE balance >= x`  │
│     双层保证不超卖                                                           │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Read Model: 日统计视图（CQRS 读侧，非聚合） ────────────────────────────────┐
│   • UserDailyChatCount (users × date → chatCount, llmTokens, embeddingTokens)│
│     → 支撑 DailyQuota 模式判定                                              │
│   • DailyUsageStat  (date → totalLlmTokens, totalEmbTokens, totalChatTurns,  │
│                        activeUsers, paidUsers)                               │
│     → Usage Dashboard "系统总览"                                             │
│   • DailyReqCountStat (date × endpoint → reqCount, failCount, avgLatencyMs)  │
│     → Usage Dashboard "API 成功率"                                           │
│                                                                              │
│   写入方式：订阅 Billing / Chat Domain Events（ChatTurnCompletedEvent /      │
│   PaymentSucceededEvent / DocumentIndexedEvent） → 写入统计表；              │
│   绝不直接从 Controller / UI 改统计表。                                      │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Billing Value Objects

| VO | 内容 |
|----|------|
| **LlmTokenAmount** / **EmbeddingTokenAmount** (SK) | 分开两个强类型，`add/subtract/compareTo` 内部实现；避免把 embedding 扣到 llm 账户（之前代码中混用 tokens 字段的 bug 根治） |
| **PriceCents** | Long；必须正数；format 成 CNY ¥12.34 在 Application 层；**禁止用 float/double** 表示金额 |
| **TradeNo** | 26 位 `PAY{yyyyMMddHHmmssSSS}{rand6}`；可反解析下单时间 |
| **PackageId** | Int 值对象 |
| **OrderStatus** + 合法转移表 | 写在 VO 里的 `EnumMap<OrderStatus, EnumSet<OrderStatus>> allowedTransitions` |
| **TokenRecordType** | GRANT / CONSUME / REFUND / ADJUST / EXPIRE |
| **TokenBizType** | ORDER_GRANT / CHAT_CONSUME / EMBEDDING / ADMIN_ADJUST / SUBSCRIPTION_EXPIRE |

### 1.3 Billing Repository 接口

```java
// com.yizhaoqi.smartpai.billing.domain.repository
public interface RechargePackageRepository {
    Optional<RechargePackage> findById(int packageId);
    List<RechargePackage> findAllVisibleOnStore();  // 商品页
    void save(RechargePackage p);
    void publish(int packageId);
    void unpublish(int packageId);
}

public interface RechargeOrderRepository {
    Optional<RechargeOrder> findByTradeNo(String tradeNo);
    Optional<RechargeOrder> findById(Long orderId);
    Page<RechargeOrder> findByUserId(UserId buyer, Pageable page); // "我的订单"
    void save(RechargeOrder order);
    /** 终态补偿扫描：DELIVERING 超过 5 min 的订单做幂等重试发放 */
    List<RechargeOrder> findStuckDelivering(Duration stuckTime);
}

public interface UserTokenAccountRepository {
    Optional<UserTokenAccount> findByUserId(UserId userId);
    void save(UserTokenAccount account); // 必须带 version 乐观锁
    /** 给新用户初始化 0 余额 / 或初始 seed（InviteCode 有绑定时） */
    UserTokenAccount initializeForUser(UserId userId, LlmTokenAmount seedLlm, EmbeddingTokenAmount seedEmb);
}

/** 🔑 追加式流水：不提供 UPDATE / DELETE 方法，只允许 INSERT（Single Source of Truth） */
public interface UserTokenRecordLedger {
    void append(UserTokenRecord record); // 唯一键 (userId, bizType, bizId) 防止重复记账
    long sumLlmDelta(UserId userId, TokenRecordType type); // 可选，对账用
    Page<UserTokenRecord> findByUserId(UserId userId, Pageable page); // "消费明细"
}

/** DailyQuota 模式接口（与 UserTokenAccount 二选一；系统通过开关切） */
public interface DailyQuotaRepository {
    boolean hasRemainingChatQuota(UserId userId, LocalDate date, int dailyLimit);
    boolean hasRemainingEmbeddingQuota(UserId userId, LocalDate date, long dailyLimit);
    void incrementChatUsed(UserId userId, LocalDate date);
}
```

### 1.4 Billing Domain Service

```java
/** 幂等发放权益：保证 RechargeOrder → GRANT 流水 → Account snapshot 三者一致；微信回调重复通知只生效 1 次 */
public interface TokenGrantService {
    void deliverOrderBenefitsIdempotent(String tradeNo);
}

/** 扣减策略：余额模式 / 日配额模式 / 混合模式（先配额，再余额） */
public interface TokenConsumptionPolicy {
    /** 预扣费（RAG 开始时扣一点余量兜底） */
    TokenReservation reserve(UserId userId, TokenType type, long estimatedAmount);
    /** 实际结算（多退少补） */
    void settleReservation(TokenReservation reservation, long actualUsedAmount, String bizId, String reason);
}

/** 对账服务：每日 02:00 跑；sum(流水) vs UserTokenAccount.snapshotBalance；不一致产生对账工单 */
public interface TokenLedgerReconciliationService {
    ReconciliationResult reconcileUser(UserId userId, LocalDate upToDate);
}

/** 微信支付签名 & 验签（纯业务规则，与 HTTP Controller 解耦） */
public interface WechatPaySignatureVerifier {
    boolean verifyCallback(String rawBody, String signatureHeader, String nonce, String timestamp);
}
```

### 1.5 Billing Domain Events（🔥 事件是 Billing 的核心传输层）

| 事件 | 触发 | 载荷 | 下游订阅 |
|------|------|------|---------|
| **RechargeOrderCreatedEvent** | 用户下单（还没付） | `tradeNo, userId, packageId, priceCents` | 优惠券域（未来）、日志 |
| **PaymentSucceededEvent** 💰 | 微信回调验签成功，order=PAID | `tradeNo, userId, llmGrant, embGrant, wxTransactionId, payTime` | **本 BC 内部 → 触发 deliverOrderBenefitsIdempotent**；前端推送"充值成功" |
| **TokenBalanceChangedEvent** | 任何 GRANT / CONSUME 流水落库后 | `userId, llmDelta, embDelta, newBalance, bizType, bizId, balanceRemainingDays?` | **Chat BC → 前端刷新顶栏"剩余 token"显示**；SysAdmin → 限流阈值调整；反欺诈服务 |
| **DailyQuotaExhaustedEvent** | 日配额用光 | `userId, quotaType, date` | Chat BC → 前端提示"今日额度已满，可充值余额" |
| **ReconciliationDiscrepancyFoundEvent** ⚠️ | 对账发现异常 | `userId, snapshotLlm, ledgerSumLlm, diffAmount, operator=SYSTEM` | 平台告警→飞书/短信→运营人工复核 |
| **ChatTokenConsumedEvent**（Chat→Billing 的入站事件，不是发布） | ChatTurnCompletedEvent 触发 Billing 扣减 | **消费侧事件**，写入 UserTokenRecord CONSUME 类型 | - |

---

## 二、BC 6：System Admin（运维管理域）

> 包路径：`com.yizhaoqi.smartpai.systemadmin`
> 现有关联代码：`RateLimitService` / `RateLimitConfigService` / `ModelProviderConfigService` / `LlmProviderRouter` / `FileTypeValidationService` / `AdminController`
> 这个 BC 配置即代码（Config as Code），所有变更都要 AuditLog。

### 2.1 Aggregate 结构（2 个 AR + 1 审计日志聚合）

```
┌─ Aggregate: RateLimitConfig (AR) ──────────────────────────────────────────┐
│   动态限流规则：管理员后台可视化编辑，不需要重发应用                            │
│                                                                              │
│   - configKey             RateLimitKey VO (命名规则：resource.scope.window) │
│     例：auth.login.ip.per_minute, chat.request.user.per_day,                │
│         llm.api.global.per_second                                            │
│   - limit                 Long (>0, 允许的次数)                              │
│   - windowSeconds         Long (窗口，s)                                     │
│   - scopeType             ScopeType: GLOBAL / BY_IP / BY_USER / BY_ORG_TAG   │
│   - scopeTarget           String? (当 scopeType=BY_ORG_TAG 时，具体哪个 org) │
│   - isEnabled             boolean (可一键关停某条限流，用于发版/活动瞬时放开) │
│   - priority              Int (相同 configKey 按 priority 取最严的)          │
│   - description           String                                             │
│   - updatedBy             UserId (最后改的 ADMIN，审计)                      │
│   - updatedAt             Instant                                           │
│                                                                              │
│   Invariants：                                                               │
│   • 同一 configKey + scopeType + scopeTarget 唯一                           │
│   • limit > 0；windowSeconds ≥ 1                                             │
│   • 修改必须是 ADMIN 用户；必须写入 AdminAuditLog                            │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: ModelProviderConfig (AR, AI 模型路由表) ─────────────────────────┐
│   - configId              Long PK                                            │
│   - scope                 ModelScope: LLM / EMBEDDING                        │
│   - provider              ProviderName: DEEPSEEK / DOUBAO / OLLAMA /         │
│                                               AZURE_OPENAI / QIANFAN         │
│   - modelName             String (例 "deepseek-chat", "doubao-embedding-256s")│
│   - priority              Int (1 = 最高优先级；路由时按 scope 选最高优先级    │
│                               且 enabled 的配置；同 priority 按 weight A/B)  │
│   - weight                Int (默认 100；同 priority 按权重切流量灰度)       │
│   - enabled               boolean (一键下线某个模型)                          │
│   - apiBaseUrl            String (兼容 Ollama 本地 / vLLM 私有部署)          │
│   - apiKey                EncryptedApiKey VO (密文存 DB；SecretCryptoService)│
│   - maxContextWindow      Int (4096 / 8192 / 128k；TokenBudgetPolicy 要参考) │
│   - defaultTemperature    BigDecimal (0..2；Chat BC 用，可调 Prompt 的创造力)│
│   - rpmLimit / tpmLimit   Long? (可选：模型级速率限制；结合 RateLimitConfig) │
│   - updatedBy             UserId (ADMIN)                                     │
│   - updatedAt             Instant                                           │
│                                                                              │
│   Invariants：                                                               │
│   • LLM 至少 1 条 enabled；EMBEDDING 至少 1 条 enabled（否则全系统不可用）   │
│   • apiKey 必须加密（长度符合 AES-256-GCM 特征）                             │
│   • weight > 0；priority ≥ 1                                                │
│   • 修改 ADMIN 且写审计日志                                                  │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: AdminAuditLog (AR, 审计日志，只追加不删改) ──────────────────────┐
│   • logId                 Long PK                                            │
│   • operatorUserId        UserId (ADMIN id)                                  │
│   • actionType            AuditAction: CONFIG_CHANGED / USER_BANNED /        │
│                                   ORG_DELETED / ORDER_REFUNDED / LOGIN       │
│   • targetType            String: RateLimitConfig / ModelProviderConfig /    │
│                                                   User / RechargeOrder       │
│   • targetId              String                                            │
│   • beforeSnapshot        JSON? (变更前快照，便于回滚)                       │
│   • afterSnapshot         JSON? (变更后快照)                                 │
│   • operatorIp            String?                                            │
│   • happenedAt            Instant                                           │
│                                                                              │
│   Invariants：管理员操作 SysAdmin / Billing 任何修改性接口 → 必须写一条日志  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 SysAdmin Value Objects

| VO | 说明 |
|----|------|
| **RateLimitKey** | `String` + 校验正则；`{resource}.{scope-type}.{time-window}` |
| **EncryptedApiKey** | `ciphertext: String` + `version: Int`（密钥轮换支持：v2 key 加密的密文，不与 v1 混用） |
| **ProviderName** / **ModelScope** / **AuditAction** | 强类型枚举 |

### 2.3 SysAdmin Repository 接口 & Domain Service

```java
// Repository
public interface RateLimitConfigRepository {
    /** 按 key 查询所有启用的规则；RateLimitService 再按最严 / scopeTarget 是否命中组合最终 limit */
    List<RateLimitConfig> findActiveByKey(RateLimitKey key);
    void save(RateLimitConfig config);
    Page<RateLimitConfig> search(String keyPart, Pageable page);
}

public interface ModelProviderConfigRepository {
    /** Chat BC 的 LlmProviderGateway 会反复调用，缓存 10s（Redis / Caffeine） */
    List<ModelProviderConfig> findActiveByScope(ModelScope scope); // 按 priority desc, weight
    Optional<ModelProviderConfig> findById(Long configId);
    void save(ModelProviderConfig c);
    void setEnabled(Long configId, boolean enabled);
}

// Domain Service
public interface RateLimitEnforcer {
    /** 判断 "这次请求能不能过"；底层 Redis 滑动窗口。返回 false = 抛 RateLimitExceededException */
    boolean tryAcquire(RateLimitKey key, String scopeTarget, long requestedTokens);
}

public interface LlmModelRouter {
    /** Chat BC 选模型：选 scope=LLM，enabled，最高 priority；同 priority 按 weight 随机 */
    ModelProviderConfig selectForLlm(String preferProviderHint);
    ModelProviderConfig selectForEmbedding();
}
```

---

## 三、BC 7：Shared Kernel（共享内核，跨所有 BC 共享）

> 包路径：`com.yizhaoqi.smartpai.sharedkernel`
> 规则：Shared Kernel 可以被任何 BC 的 domain 层引用；**反向禁止：Shared Kernel 绝不引用任何 BC 的类**。否则循环依赖。

### 3.1 Value Objects（所有 SK 都是强类型不可变 VO）

```
sharedkernel.domain.vo/
├── identifiers/
│   ├── UserId.java               (Long value，包装 users.id)
│   ├── ConversationId.java       (UUID value，聊天业务主键)
│   ├── OrgTagId.java             (String value，组织业务 ID，不是 DB Long)
│   ├── FileMd5.java              (32 hex，正则校验)
│   ├── ChunkId.java              (FileMd5 + ":" + Integer index)
│   ├── PackageId.java / OrderId.java / TaskId.java (各自强类型)
│   └── RateLimitKey.java         (命名规则校验)
├── money/
│   ├── PriceCents.java           (非负 Long，toCNYDecimal())
│   ├── Currency.java             (Enum)
│   └── TradeNo.java              (26位，解析出时间)
├── tokens/
│   ├── LlmTokenAmount.java       (non-negative Long; add/subtract/multiply)
│   ├── EmbeddingTokenAmount.java (同上，两个不同类，不允许互转除非显式)
│   ├── TokenReservation.java     (预扣费句柄，结算用)
│   └── TokenUsage.java           (LLM 单次调用用量 = LlmProvider 返回 + provider + model)
├── content/
│   ├── PageNumber.java           (1..N Int)
│   ├── IntRange.java             (startInclusive, endExclusive)
│   └── Username.java             (正则 6..32 alnum_)
├── time/
│   └── InstantRange.java         (创建对话窗口、统计日范围)
├── access/
│   └── OrgTagSet.java            (解析 users.org_tags 逗号字符串；去重；contains 交集)
└── crypto/
    ├── PasswordHash.java         (由 PasswordUtil 在 Domain Primitive 工厂方法创建)
    ├── JwtToken.java             (access + refresh + expiresAt)
    └── EncryptedApiKey.java      (密文 + keyVersion)
```

### 3.2 基类 & 基础设施契约

```
sharedkernel.domain/
├── base/
│   ├── AggregateRoot.java         (marker interface + List<DomainEvent> events)
│   ├── Entity.java                (marker interface + equals/hashCode by id)
│   ├── ValueObject.java           (marker interface；所有 VO 必须 final + immutable)
│   ├── DomainService.java         (marker interface)
│   └── ApplicationService.java    (marker interface)
├── events/
│   ├── DomainEvent.java           (基类：eventId(UUID) + occurredAt(Instant) +
│   │                                aggregateType + aggregateId + causationEventId)
│   ├── DomainEventPublisher.java  (接口：发布事件；infrastructure 用 Spring AppEvent
│   │                                或 KafkaEventBus 实现)
│   └── domain events 具体类也按 BC 放自己 BC 的 events/ 包
├── exceptions/
│   ├── DomainException.java       (所有领域规则异常基类)
│   ├── IllegalStateDomainException.java
│   ├── InsufficientBalanceDomainException.java
│   ├── AccessDeniedDomainException.java (ACL)
│   └── NotFoundDomainException.java
└── repository/
    ├── ReadRepository<AR, ID>     (findById/findAll/Page)
    └── WriteRepository<AR, ID>    (save/delete；禁止读方法)
```

### 3.3 Shared Kernel 防腐规则

- ❌ 禁止任何 BC 的 domain 层引用其他 BC 的 `repository` 或 `entity`。跨 BC 访问必须用 **Facade 接口（放在 caller BC 的 infrastructure.acl 包下）** 或 **Domain Event**。
- ✅ 允许：`chat.domain.service.ConversationOwnershipPolicy.assertCanContinue(UserId subject, ConversationId convId)` → 这里 UserId / ConversationId 都是 SK VO，没问题。
- ❌ 禁止：`Chat` 直接 `import com.yizhaoqi.smartpai.identity.domain.model.User` 强耦合 → 正确做法：通过 `IdentityAclFacade.findById(UserId)` 返回 `UserView DTO`（名字/角色/OrgTagSet），DTO 字段全是 SK VO。

---

全部 7 个 BC 设计完成。下一文档：[DDD 图表（Context Map / 分层架构 / Aggregate 关系 Mermaid）](./diagrams/01-README-DIAGRAMS.md) 然后是 [5 张分域 ERD](./05-DOMAIN-ERDS.md) 最后是 [渐进式重构路线](./06-REFACTORING-ROADMAP.md)。
