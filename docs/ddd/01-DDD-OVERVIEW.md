# PaiSmart DDD 总览（Bounded Contexts + Ubiquitous Language）

> 按 Platform Engineering Day 02 DDD 惯例，先划 **限界上下文（Bounded Context, BC）**，再给每个 BC 的 **通用语言（Ubiquitous Language, UL）**，然后定义 BC 之间的关系（Context Map，见 diagrams 目录）。

---

## 一、为什么这样划分 BC（划分原则）

DDD 中 BC 按"业务语义独立 + 团队可独立交付 + 数据变化边界 + 变更频率"划分，而不是按技术分层。PaiSmart 的 7 个 BC：

| 原则 | 解释 |
|------|------|
| 语义独立 | "用户登录注册"和"RAG 文档切块"业务语言完全不同，必须分 BC |
| 团队边界 | 身份团队 / 知识库团队 / 对话算法团队 / 计费财务团队 / 平台运维团队 可各管 1~2 个 BC |
| 数据一致性边界 | 一次"付款成功发 Token 权益"是 Billing BC 的事务，不跨到 Identity |
| 变更频率 | 模型 Provider 配置(SysAdmin) 可能每天改，Conversation Chat 核心 RAG 每周发版，User 注册月级改 |

---

## 二、7 个 Bounded Context 总表

| # | 限界上下文 (BC) | 中文名称 | 业务职责一句话 | 对应现有包（重构目标路径） | 核心 Entity/表 |
|---|----------------|---------|---------------|--------------------------|---------------|
| 1 | **Identity & Access (IAM)** | 身份与权限 | 用户生命周期 + 组织(租户) + 认证授权 + 邀请码 | `com.yizhaoqi.smartpai.identity` | `User`, `OrganizationTag`, `InviteCode`, `RegistrationMode` |
| 2 | **Knowledge Base (KB)** | 知识库 | 文档上传、解析、切块、向量、索引 整个入仓生命周期 | `com.yizhaoqi.smartpai.knowledgebase` | `FileUpload`, `ChunkInfo`, `DocumentVector`, `FileProcessingTask` |
| 3 | **Search** | 检索域 | 语义+关键词混合检索、ES 索引查询、Chunk 重排 | `com.yizhaoqi.smartpai.search` | `EsDocument`（ES 索引结构，非 MySQL）, `SearchRequest`, `SearchResult` |
| 4 | **Chat & Conversation** | 聊天与会话 | 会话/会话 Session、消息、RAG Prompt 组装、LLM 调用、生成状态、WS 连接、引用映射 | `com.yizhaoqi.smartpai.chat` | `Conversation`, `ConversationSession`, `Message`（ChatHandler 聚合编排） |
| 5 | **Billing & Quota** | 计费与配额 | Token 余额、每日配额、充值套餐、充值订单、微信支付、日消耗统计 | `com.yizhaoqi.smartpai.billing` | `RechargePackage`, `RechargeOrder`, `UserTokenRecord`, `UserDailyChatCount`, `DailyUsageStat`, `DailyReqCountStat` |
| 6 | **System Admin** | 系统管理域 | 限流配置、模型 Provider 配置（运行时 LLM/Embedding） | `com.yizhaoqi.smartpai.systemadmin` | `RateLimitConfig`, `ModelProviderConfig` |
| 7 | **Shared Kernel (SK)** | 共享内核 | 跨 BC 共享的值对象、基础类、领域事件基类、仓储接口 | `com.yizhaoqi.smartpai.sharedkernel` | `UserId`, `OrgTagId`, `FileMd5`, `TokenAmount`, `PageNumber`, `DomainEvent` 基类 |

> 说明：当前代码是技术分层（controller/service/repository/entity），**重构后包名按 BC 组织**，每个 BC 内部再用标准 DDD 四层：`domain / application / infrastructure / interfaces`。

---

## 三、Bounded Context × BC 关系（Context Map）

完整 Mermaid 图见 [`diagrams/02-context-map.mmd`](file:///Users/bytedance/Desktop/PaiSmart-main/docs/ddd/diagrams/02-context-map.mmd)，文字总结：

```
                    ┌─────────── Shared Kernel (共享 VO/接口) ───────────┐
                    │  UserId, OrgTagId, FileMd5, TokenAmount, DomainEvent│
                    └───────┬─────────────────┬──────────────────┬───────┘
                            │                 │                  │
 ┌──────────────┐   C-S (Up) │       C-S(Up) │         C-S(Up) │
 │ Identity BC  │────────────┼───────────────┼──────────────────┤
 │ (User/Org)   │            ▼               ▼                  ▼
 └──────┬───────┘   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
        │           │ Knowledge    │ │    Chat      │ │   Billing    │
        │ACL 查询   │  Base BC     │─▶│ Conversation │◀─│  & Quota BC  │
        ▼           │ (文档/向量)  │   │  BC (RAG)    │  │ (扣费/充值)  │
 ┌──────────────┐   └──────┬───────┘   └───────┬──────┘ └──────┬───────┘
 │ System Admin │          │ Search BC         │ ACL 查询        │
 │   BC         │          │ (查询读侧 ← Upstream KB, ACL from IAM)│  ACL 查询
 │ (限流/模型)  │          └───────────────────┘               │
 └──────────────┘   ════════════════════════════════════════════╡
                        Domain Event:                          │
                 PaymentSucceededEvent → 发 Token 权益(Billing内部)
                 DocumentIndexedEvent → 前端推送 (Chat ← KB)
                 TokenConsumedEvent → 写流水 (Chat → Billing)
```

| 关系类型 | 上游(Upstream) → 下游(Downstream) | 说明 |
|---------|-----------------------------------|------|
| **C-S (Customer-Supplier)** | Identity → KnowledgeBase / Chat / Billing | 下游（聊天、计费）要查用户/组织，必须跟 Identity BC 接口稳定契约，Identity 作为 Supplier 要尊重下游需求 |
| **C-S** | KnowledgeBase → Search | KB 写入索引，Search 读索引，KB 要保证 ES Schema 变更通知 Search |
| **C-S** | KnowledgeBase → Chat | KB 完成 DocumentIndexedEvent 通知 Chat 前端刷新上传列表 |
| **C-S** | Billing → Chat | Chat 每次请求要查 Token 余额/限额，Billing 作为 Supplier 提供 `BalanceService` |
| **Shared Kernel** | IAM × KB × Chat × Billing ↔ SK | 所有 BC 共享 UserId/OrgTagId/TokenAmount 等 VO；共享 `DomainEvent` 基类 |
| **ACL (防腐层)** | Chat → IAM / Billing | Chat 要查"用户是否在某 org"不要直接依赖 Identity 的 Repository，通过 `IdentityFacade` / `OrgTagAccessPolicy` 接口（ACL）解耦，将来 Identity 重构不影响 Chat |
| **ACL** | Search → IAM / KB | 查询时要按 org tag 过滤权限，搜索域内部封装 `AccessControlFilter` 独立 ACL |
| **Domain Event Pub-Sub** | KB → Chat：`DocumentIndexedEvent`、`DocumentParseFailedEvent`；Chat → Billing：`TokenConsumedEvent`；Billing → Chat：`TokenBalanceChangedEvent` | 基于 Spring ApplicationEvent 或 Kafka 事件总线 |

---

## 四、通用语言（Ubiquitous Language）词汇表

> 评审 DDD 的"铁律"：**同一个单词在整个代码 + 文档 + DB 字段 + 产品 PRD 中只有一个精确含义**。如果发现同一个词有多个意思，必须拆分出不同的词并放到各自 BC 的 UL 里。

### 4.1 Identity & Access (IAM) UL

| 术语 | 精确定义（代码映射） |
|------|--------------------|
| **用户 (User)** | 拥有 `userId`（Long 主键）、`username`（唯一登录名）、`passwordHash`、`role: USER/ADMIN` 的账户实体 |
| **角色 (Role)** | 用户在系统内的全局权限等级：USER（普通用户）/ ADMIN（超管，可进 System Admin）。注意≠组织内角色 |
| **组织标签 (OrganizationTag / OrgTag)** | 多租户隔离单位；层级结构（`parent_tag`）；用户可以属于多个 OrgTag（users.org_tags 逗号分隔）；文件通过 `FileUpload.orgTag` 归属某个组织 |
| **主组织 (PrimaryOrg)** | 用户多个 OrgTag 中优先使用的一个（users.primary_org），新建文件默认归属主组织 |
| **邀请码 (InviteCode)** | 6~12 位字符串；RegistrationMode=INVITE_ONLY 时注册必填；绑定邀请渠道统计；一次性或可多次使用 |
| **注册模式 (RegistrationMode)** | OPEN（开放注册）/ INVITE_ONLY（仅持邀请码可注册）/ CLOSED（关闭注册，仅管理员创建） |
| **认证 (Authentication / Authenticated)** | 证明"你是谁"：JWT 签发 & 验证、Refresh Token 刷新、WebSocket JWT 握手 |
| **授权 (Authorization / Authorized)** | 证明"你能做什么"：Spring Security 角色判定 + OrgTagAuthorizationFilter 文件访问过滤（Owner / Public / OrgMember 三种权限） |

### 4.2 Knowledge Base (KB) UL

| 术语 | 精确定义 |
|------|---------|
| **文档 (Document / FileUpload)** | 用户上传的一个文件，唯一标识 `FileMd5 + UserId` 联合唯一（不同用户上传相同 MD5 算不同文档）。含：文件原始名、大小、权限(public/org/owner)、关联 orgTag |
| **文件 MD5 (FileMd5)** | 值对象，32 位小写 hex，文档内容的指纹 |
| **文档状态 (UploadStatus)** | 枚举：`UPLOADING / MERGING / COMPLETED`；不等于向量化状态 |
| **向量化状态 (VectorizationStatus)** | `PENDING / PROCESSING / COMPLETED / FAILED`；文档入库生命周期的关键状态机 |
| **上传分片 (ChunkInfo / UploadChunk)** | HTTP Range PUT 上传的一个 5MB 分片；`(fileMd5, chunkIndex)` 唯一；持久化存储路径；全部接收后合并成完整文件 |
| **解析 (Parse)** | 从文件提取文本/页码/图片文本的动作。实现：Apache Tika（Word/Execl/TXT）+ LiteParse（PDF）+ OCR（图片/PDF扫描件） |
| **切块 (Chunking / TextChunk)** | 语义切块，参数：`chunk_size=512 tokens`、`overlap=100 tokens`；每个 Chunk 属于且只属于 1 个 Document |
| **Chunk ID (ChunkId)** | 值对象：`{fileMd5}:{chunkIndex}` 全局唯一 |
| **锚点 (AnchorText)** | Chunk 在原文档中的定位信息（PDF 页码 + 页面 3~5 字上下文），用于"引用溯源"跳到具体页 |
| **文档向量 (DocumentVector / VectorChunk)** | Chunk 对应的 Embedding 向量（MySQL 持久化原文+元数据，ES dense_vector 索引存向量） |
| **入库 (Indexing / Indexed)** | Chunk 写入 Elasticsearch 索引，完成后 Document 的 vectorizationStatus=COMPLETED，此时文档可被搜索到 |
| **预览 (Preview)** | 前端查看原文件（PDF/Word/TXT 渲染），走 MinIO 签名 URL |
| **处理任务 (FileProcessingTask)** | Kafka 异步链路的跟踪记录：parse_status → chunk_status → vector_status → index_status，每步可重试 |

### 4.3 Search UL

| 术语 | 精确定义 |
|------|---------|
| **混合搜索 (HybridSearch)** | Dense Vector 语义检索 + BM25 关键词检索，`RRF(Reciprocal Rank Fusion)` 或加权融合得到最终排序 |
| **检索块 (RetrievedChunk / Hit)** | 搜索结果中的一项，含：Chunk 原文、相似度/分数、来源 DocumentId、FileMd5、PageNumber、AnchorText、权限标签 |
| **Top-K** | 语义检索取前 K 个块（Chat RAG 默认 K=8） |
| **访问控制过滤 (ACL Filter)** | 搜索阶段就按 `userId OR is_public=true OR org_tag IN 用户所属组织` 过滤，避免返回用户无权访问的块 |
| **可搜索域 (Searchable Field)** | ES 索引里的字段：content(text)、file_md5(keyword)、org_tag(keyword)、is_public(boolean)、user_id(keyword)、page_number(int)、vector(dense_vector dim=2048) |
| **语义召回 (Semantic Recall)** | Query → Embedding → ES `script_score cosineSimilarity` |
| **关键词召回 (Lexical Recall)** | Query → 分词 → ES BM25 `match/match_phrase` |

### 4.4 Chat & Conversation UL

| 术语 | 精确定义 |
|------|---------|
| **会话 (Conversation / Logical Conversation)** | 多个问答轮次的逻辑容器，`conversationId`（String UUID）为业务标识，用于历史列表；一个用户可拥有多个会话 |
| **会话 Session (ConversationSession / WS Session)** | 一次 WebSocket 连接；同一 conversationId 可以在多个 Session 中继续（断线重连）；由 `ChatSessionRegistry` 维护内存映射 |
| **轮次 / 问答 (Q&A Pair)** | 1 个用户消息 (question) + 1 个助手回复 (answer)，持久化到 conversations 表 1 行 = 1 轮 |
| **消息 (Message)** | 会话内最小单元；`role ∈ {USER/ASSISTANT/SYSTEM}`；流式输出时 Assistant Message 分多个 delta |
| **引用映射 (ReferenceMappings)** | 助手回答引用了哪些 Chunk；结构 JSON：`[{chunkId, fileMd5, fileName, pageNumber, anchorText, similarity}]` |
| **生成状态 (GenerationState)** | 对某一条用户消息的 LLM 生成跟踪：`GENERATING / STREAMING / COMPLETED / INTERRUPTED_BY_USER / FAILED / RETRYING` |
| **RAG 编排 (RAG Orchestration)** | `ChatHandler#handleChat` 全流程：查询上下文 → 组装 Prompt → 调用 LLM SSE → 流式 push → 记录 Usage → 持久化 |
| **Prompt 模板 (Prompt Template)** | System Prompt + 上下文占位 + Few Shot 示例；可由 SysAdmin 运行时修改（后续做） |
| **Token 用量 (TokenUsage)** | `{promptTokens, completionTokens, totalTokens, llmProvider, modelName}` 每次 LLM 调用返回，写入 Billing |
| **流式输出 (Streaming)** | WebSocket `type=delta` 增量推 token，前端打字机效果；结束时 `type=done` + `type=usage` + `type=reference` |
| **生成中断 (Interrupt)** | 用户点击停止 / WS 断开，`ChatGenerationStateService` 标记 `INTERRUPTED_BY_USER` 并释放 WebFlux sink |
| **引用点击 (ReferenceClick)** | 用户点击"引用 X"跳转 PDF 预览页，前端埋点用于 RAG 线上反馈 |

### 4.5 Billing & Quota UL

| 术语 | 精确定义 |
|------|---------|
| **Token** | LLM/Embedding 的计费最小单位；分两类：`llmToken` (聊天大模型输入+输出)、`embeddingToken` (向量化输入) |
| **Token 余额 (TokenBalance)** | 用户账户还可消耗的 Token 数量；两种模式：`DailyQuota(每日重置)` vs `UserTokenBalance(余额消耗, 可充值累积)`（系统可切） |
| **每日配额 (DailyQuota)** | 每日 0 点重置的免费额度，例：日 Chat 50 次、Embedding 100k tokens，超后再走余额扣费 |
| **充值套餐 (RechargePackage)** | 运营定义的商品：`packageId`、价格、`llmTokenAmount`、`embeddingTokenAmount`、有效天数、是否上架；例："￥99 月卡=500万 LLM Token+无限 Embedding" |
| **充值订单 (RechargeOrder)** | 用户购买套餐的一次交易；`tradeNo` 业务单号 + `wxTransactionId` 微信流水号；状态机：`CREATED → PAID → DELIVERED / CREATED → CLOSED` |
| **支付 (Payment / Pay)** | 微信支付 V3：商户下单 → 调起客户端支付 → 异步回调 `notify_url` → 验签 → 订单状态机 → 发 Token 权益 |
| **发放权益 (Deliver / Grant)** | 订单 PAID 后，把套餐的 LLM/Embedding Token 加到用户余额上，写入 `UserTokenRecord` |
| **扣减 (Deduct / Consume)** | 每次聊天或向量化完成后，从余额或日配额中扣掉对应数量，写入流水 |
| **Token 流水 (UserTokenRecord)** | 余额变动账本：`{userId, deltaSign(+/-), deltaAmount, recordType(GRANT/CONSUME/REFUND/ADJUST), bizType(ORDER/CHAT/EMBED/ADMIN), bizId, snapshotBalance, createdAt}`，不可变，只能追加 |
| **每日聊天数 (DailyChatCount)** | `users × date` 粒度，统计当日对话轮次，用于 DailyQuota 判定 |
| **日消耗统计 (DailyUsageStat / DailyReqCountStat)** | `date` 粒度总览：总 llmTokens、总 embeddingTokens、总请求数、活跃用户数，用于 Usage Monitor Dashboard（读优化汇总表，不做事务依据） |

### 4.6 System Admin UL

| 术语 | 精确定义 |
|------|---------|
| **限流配置 (RateLimitConfig)** | 动态限流规则；`key` 命名 `{resource}.{window}`；例：`auth.login.per_minute=5/IP`、`chat.request.per_day=200/USER`、`llm.api.per_second=200/全局`；存储：`(configKey, limit, windowSeconds, scopeType(IP/USER/GLOBAL), orgTag?)`，Redis 滑动窗口实现 |
| **模型 Provider 配置 (ModelProviderConfig)** | 运行时可切换的模型配置；`scope ∈ {LLM, EMBEDDING}`；`provider ∈ {DEEPSEEK, DOUBAO, OLLAMA, AZURE_OPENAI...}`；`apiBaseUrl`、`modelName`、`apiKey(加密存库)`、`enabled`、`priority`(路由优先级)、`weight`(权重 A/B) |
| **模型路由 (Model Router / LlmProviderRouter)** | 按 scope + priority / weight 选择具体 Provider；灰度 / A/B 时配置多个 enabled 并按权重切 |
| **API Key 加密 (Secret Crypto)** | `SecretCryptoService`：AES-256-GCM + 主密钥从环境变量注入，保存到 DB 的永远是密文 |

### 4.7 Shared Kernel UL（跨所有 BC）

| 术语 | 精确定义 |
|------|---------|
| **UserId (VO)** | Long；所有 BC 引用用户时只传 UserId，不耦合 User Entity；相等只按值 |
| **OrgTagId (VO)** | String；组织标签的业务 ID（DB 里主键 Long 是持久化细节，SK 不暴露） |
| **FileMd5 (VO)** | String 32 hex；文档指纹，KB / Chat 引用同一文档时用 |
| **TokenAmount (VO)** | Long，单位 token；不可变；算术运算在内部（add/subtract，溢出抛 DomainException）；保证"Billing 里所有地方存的都是正数 + sign"单一实现 |
| **PageNumber (VO)** | Integer；PDF 页码；>0；用于预览跳转 |
| **ConversationId (VO)** | UUID；Chat/UI/History 交互用，≠ Conversation 表 Long 自增 id |
| **ChunkId (VO)** | `{fileMd5}:{index}`；跨 KB/Search/Chat 传递 |
| **聚合根 (Aggregate Root, AR)** | 事务一致性边界；外部只允许持有 AR 的引用；典型 AR：User、FileUpload、Conversation、RechargeOrder、RechargePackage、RateLimitConfig、ModelProviderConfig、OrganizationTag |
| **实体 (Entity)** | 有唯一标识 + 生命周期可变；非 AR 的 Entity 必须挂载在某个 AR 下（例 ChunkInfo 属于 FileUpload；Message 属于 Conversation） |
| **值对象 (Value Object, VO)** | 无标识，不可变，按值相等；UserId/OrgTagId/PageNumber/TokenAmount 都是 VO |
| **仓储接口 (Repository Interface)** | 在 domain 层；只定义"集合语义"的方法签名；具体 JPA/Redis/ES 实现在 infrastructure |
| **领域服务 (Domain Service)** | 业务规则跨多聚合时用；例 `OrgTagAccessPolicy.canAccessFile(User, FileUpload)`、`TokenConsumptionConsistencyPolicy.consume()` |
| **应用服务 (Application Service)** | 编排（事务边界 + 协调多个 Repository/Domain Service）；不含业务规则；例 `ChatApplicationService.handleMessage(cmd)` |
| **基础设施服务 (Infrastructure Service)** | 技术细节实现；例 `JpaUserRepository`、`OssFileStorage`、`DeepSeekAiClient`、`KafkaDomainEventBus` |
| **领域事件 (Domain Event)** | "过去发生的事情"，不可变 + 有时间戳 + 有 aggregateId；例 `DocumentIndexedEvent(FileMd5)`、`PaymentSucceededEvent(OrderId)`、`TokenConsumedEvent(UserId, TokenAmount)` |

---

## 五、UL 反模式（当前代码中的"要改掉的多义性"）

| 当前多义词 | 出问题的地方 | DDD 后的改法 |
|-----------|------------|-------------|
| `conversationId` vs `Conversation.id` | Conversation.id 是 Long 自增 DB id；conversationId 列是逻辑 UUID 字符串 → 两个都叫"会话 id"必混 | 逻辑 ID 改为 `ConversationId` VO；DB 主键只在 Repository 内部使用，不出 domain |
| `chunk` 既指上传分片又指向量化文本块 | ChunkInfo 是"上传字节分片"；DocumentVector/TextChunk 是"语义切块"；两个名字完全不同含义 → 严重 | 前者改名为 **UploadChunk**；后者保留名为 **TextChunk / DocumentVectorChunk** |
| `tokens` 出现在多处但单位不同 | estimated_embedding_tokens（单文件）/ llmToken + embeddingToken（订单权益）/ UserTokenRecord.delta（没区分 llm/embedding？） | VO 拆成 `LlmTokenAmount` 和 `EmbeddingTokenAmount` 两个强类型，避免把 embedding 扣到 llm 账户里 |
| `org_tags` String 逗号分隔存 users 表 | 当集合用，失去强类型和校验 → 变更业务规则时容易出 bug | SK 里定义 `OrgTagSet` VO，封装解析、去重、判空、判断 contains |
| `ChatHandler` 里大量 if/else 业务规则散落 | 业务规则（如"余额充足吗？""用户能看到这个文件吗？""chunk 应该合并吗？"）应该在 Domain Service，而不是 Application / Handler | 抽 `RagCompositionPolicy` / `OrgTagAccessPolicy` / `TokenConsumptionPolicy` 三个 Domain Service |

下一文档 [02-IDENTITY-BC.md](./02-IDENTITY-BC.md) 逐个 BC 给出聚合、实体、VO、Repository 接口、Domain Event 的详细设计。
