# Search BC + Chat & Conversation BC 设计

Chat RAG = 检索 + 生成。读侧"搜索"和写侧"对话生成"是两个独立变更频率和团队，分两个 BC。

---

## 一、BC 3：Search（检索域 —— 纯读侧 CQRS）

> 包路径：`com.yizhaoqi.smartpai.search`
> 现有关联代码：`HybridSearchService` / `ElasticsearchService` (查询部分) / `SearchController` / `entity.EsDocument` / `entity.SearchRequest` / `entity.SearchResult` / `entity.TextChunk`
> **架构风格：CQRS 读模型**；Search BC 自己不维护事务源数据（事务源在 KnowledgeBase MySQL），直接消费 KB 的 `DocumentIndexedEvent / FileDeletedEvent` 写入 Elasticsearch 物化视图

### 1.1 Search 模型结构（只有"查询模型"，没有 Aggregate 事务边界，因为 Search BC 不做写入事务）

Search BC 内部是 **Read Model**，不强调 Aggregate。强调的是：

- 输入：`SearchQuery` DTO（含 ACL 上下文）
- 输出：`SearchHits` 集合
- 中间件：**Access Control Filter（ACL Filter）** 作为 Anti-Corruption Layer 从 Identity BC 拉策略
- 重排：可选 Reranker（后续加 Cohere rerank / 重排模型作为 Domain Service）

```
Search BC 模型层级：

  SearchQuery (DTO, 来自 Chat BC)
   ├─ rawQueryText                 String
   ├─ viewerUserId                  UserId (ACL 用)
   ├─ viewerOrgTags                 OrgTagSet
   ├─ semanticTopK                  Int (默认 8)
   ├─ lexicalTopK                   Int (默认 20)
   ├─ rerankTopK                    Int (默认 5~8)
   ├─ scopeFilter: FileMd5[]?       (限定只查某几个文档)
   ├─ orgTagScopeFilter: OrgTagId[]?(限定只查某几个组织)
   └─ includePublicOnly?            boolean (仅公开文档，管理后台搜索用)
           │
           ▼
  AccessControlFilter （ACL 防腐层）
   ├─ userIdClause:  term: {user_id: viewerUserId}
   ├─ isPublicClause: term: {is_public: true}
   └─ orgTagClause:  terms: {org_tag: viewerOrgTags.list}
   → 组合成 ES bool.should(minShouldMatch=1)
           │
           ▼
  HybridSearchResult (DTO)
   └─ List<RetrievedChunk>
        ├─ chunkId              ChunkId
        ├─ fileMd5              FileMd5
        ├─ fileName             String (展示引用)
        ├─ ownerUserId          UserId (再次 ACL 兜底检查)
        ├─ orgTag               OrgTagId?
        ├─ isPublic             boolean
        ├─ contentSnippet       String (高亮片段)
        ├─ pageNumber           PageNumber?
        ├─ anchorText           String? (引用跳转定位)
        ├─ semanticScore        float (余弦相似度)
        ├─ lexicalScore         float (BM25)
        └─ finalFusedScore      float (RRF 或加权融合后排序分数)
```

### 1.2 Search BC Domain Service（读侧服务）

```java
// com.yizhaoqi.smartpai.search.domain.service

/** 纯接口；KB 索引写入仍由 KnowledgeBase.KnowledgeIndexGateway 负责，Search 只负责查 */
public interface HybridSearchService {
    HybridSearchResult search(SearchQuery query);
}

/** ACL Filter Builder：**规则唯一定义点**，避免 Chat Controller / SearchController / DocumentController 三处各拼一套 */
public interface AccessControlFilterBuilder {
    /**
     * 给定当前用户，产出可访问文档的 ES DSL BoolQueryBuilder
     * 内部: 读 Identity BC 的 OrgTagAccessPolicy（通过 ACL Facade = 防腐层），绝不直接联 users 表
     */
    BoolQueryBuilder buildViewFilter(UserId viewer);

    /**
     * "给定用户 × 给定 ChunkId 列表"：二次校验每个 Chunk 是否真的可访问
     * (ES 过滤后仍做二次兜底；避免 ES index ACL 同步延迟带来越权)
     */
    void assertEveryChunkViewable(UserId viewer, Collection<RetrievedChunk> chunks) throws ForbiddenDomainException;
}

/** 混合检索融合策略：可切换 RRF(Reciprocal Rank Fusion) / 加权线性 / 学习排序 */
public interface RankFusionPolicy {
    List<RetrievedChunk> fuse(List<RetrievedChunk> semanticHits, List<RetrievedChunk> lexicalHits);
}

/** 重排策略接口（可选接入，默认 NOOP） */
public interface Reranker {
    List<RetrievedChunk> rerank(String query, List<RetrievedChunk> hits, int keepTopK);
}
```

### 1.3 Search Infrastructure（读侧 Gateway）

```java
// com.yizhaoqi.smartpai.search.infrastructure
public interface ElasticsearchQueryGateway {
    /** 纯向量语义检索 */
    List<RetrievedChunk> semanticSearch(String queryEmbedding, BoolQueryBuilder aclFilter, int topK);
    /** BM25 关键词检索 */
    List<RetrievedChunk> lexicalSearch(String queryText, BoolQueryBuilder aclFilter, int topK);
}

/** ACL 防腐层：从 Identity BC 拿"用户属于哪些组织"的结果（缓存 30s），不直接依赖 Identity Repository */
public interface IdentityAclFacade {
    OrgTagSet getUserOrgTags(UserId userId);
    boolean isAdmin(UserId userId);
}
```

### 1.4 Search Domain Events（几乎无；Search 是事件消费者）

| 消费事件 | 来自哪个 BC | 动作 |
|---------|------------|------|
| `DocumentIndexedEvent` | KnowledgeBase | 校验：这个文档是否真的在 ES 中，否则同步修复（一致性检查） |
| `FileDeletedEvent` | KnowledgeBase | 再次从 ES 删除对应 Chunk，幂等 |
| `OrganizationTagDeletedEvent` | IAM | ES 中把命中 org_tag=X 的文档 ACL 标记修复（视业务：保留但改 owner，或删） |

Search BC 向外发的事件：目前**没有**。如果要做"搜索热词统计 / 点击率排序学习"，将来发 `SearchQueryIssuedEvent` + `ResultClickedEvent` 给分析域。

---

## 二、BC 4：Chat & Conversation（🔥 RAG 核心业务域）

> 包路径：`com.yizhaoqi.smartpai.chat`
> 现有关联代码：`ChatHandler`（核心编排，必须拆）/ `ChatWebSocketHandler`(interfaces 层) / `ConversationService` / `ChatGenerationStateService` / `ChatSessionRegistry` / `LlmProviderRouter` / `ModelProviderConfigService`(SysAdmin 接口) / `RechargeService`(Billing 接口) / `ConversationRepository` / `ConversationSessionRepository` / `RedisRepository`（短期聊天上下文）

### 2.1 Aggregate 结构（3 个聚合根 + 1 个内存非持久化 Registry）

```
┌─ Aggregate: Conversation (AR) ──────────────────────────────────────────────┐
│ 逻辑会话（跨 WebSocket 断线重连，长期持久化在 MySQL + Redis）                  │
│                                                                              │
│   - conversationId        SharedKernel.ConversationId (UUID 业务 ID)        │
│   - persistenceId(DB PK) Long? (DDD 里 Repository 内部用，不暴露 domain)     │
│   - ownerUserId           UserId VO                                         │
│   - title                 String (AI 自动取首条问题前 30 字，用户可改)        │
│   - orgTag                OrgTagId? (用于"组织共享会话"，可选扩展)           │
│   - tags                  List<String> (用户给会话打标签)                    │
│   - visibility            Visibility: PRIVATE / ORG_VISIBLE / PUBLIC_LINK   │
│   - createdAt             Instant                                          │
│   - lastActiveAt          Instant (新消息/用户重新打开均刷新，用于排序)      │
│   - isArchived            boolean (软删除)                                  │
│                                                                              │
│   └── 内部集合 Entity: ConversationTurn (⬅️ = conversations 表 1 行)         │
│         • turnId          Long                                              │
│         • indexInSession  Int (轮次序号 1..N)                               │
│         • userMessage     UserMessage (role=USER)                           │
│         • assistantMessage AssistantMessage (role=ASSISTANT)                │
│         • references      ReferenceMappings (对应 UI "引用 1/2/3")         │
│         • usage           TokenUsage (单次 LLM 调用用量，写入 Billing 扣减)  │
│         • latencyMs       Long (用户首 token 延迟，性能优化指标)             │
│         • rating          UserRating? Enum(👍LIKE / 👎DISLIKE) + comment    │
│         • generationState GenerationState: GENERATING/COMPLETED/            │
│                                         INTERRUPTED/FAILED                   │
│         • createdAt       Instant                                          │
│                                                                              │
│   Invariants：                                                               │
│   • turn.userMessage.createdAt ≤ turn.assistantMessage.createdAt （时序）    │
│   • conversationId + indexInSession 唯一                                    │
│   • assistantMessage.content 非空 ↔ generationState ∈ {COMPLETED, FAILED}   │
│   • references 里的每个 ChunkId 都必须通过 AccessControlFilter(读 Search BC) │
│   • visibility ≠ PRIVATE 时必须属于 orgTag 或开启链接令牌                    │
│   • rating 仅允许对 COMPLETED 的 turn；每个 turn 最多 rating 1 次；可改 1 次 │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: ConversationSession (AR) ───────────────────────────────────────┐
│   一次真实的 WebSocket 连接。用户同一个 ConversationId 在 3 台设备 = 3 Session │
│                                                                              │
│   - sessionId             UUID (WS 握手生成)                                 │
│   - conversationId        ConversationId (会话逻辑容器)                      │
│   - ownerUserId           UserId (必须和 Conversation.ownerUserId 一致)     │
│   - clientInfo            ClientInfo VO {userAgent, ip, platform}           │
│   - connectedAt           Instant                                          │
│   - lastHeartbeatAt       Instant (心跳超时强制断开)                         │
│   - status                SessionStatus: CONNECTED / HEARTBEAT_TIMEOUT /    │
│                                                   USER_DISCONNECTED / SERVER_SHUTDOWN
│   - activeGeneration?     GenerationHandle (用于 "用户点停止按钮 → 中断")    │
│                                                                              │
│   Invariants：                                                               │
│   • connectedAt ≤ lastHeartbeatAt ≤ now                                     │
│   • 超过 90s 无心跳 → 自动改为 TIMEOUT，调用 ChatSessionRegistry 清理         │
│   • 同一 UserId 最大并发 Session 数 ≤ 10（防刷）                             │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: GenerationTask (🔮 新建：Chat Generation 细粒度跟踪聚合) ───────┐
│   当前 ChatGenerationStateService 是 Map<String, State> 内存结构；DDD 化为聚合 │
│   并在 Redis 持久化（中断/重试用）                                             │
│                                                                              │
│   - generationId          UUID (每次对 1 条用户消息 生成 1 次=1 个 Task)      │
│   - conversationId / sessionId / turnId     (关联)                          │
│   - ownerUserId           UserId                                             │
│   - promptTokens          Int (最后记录)                                     │
│   - completionTokens      Int (流式 delta 累加)                              │
│   - llmProvider           ProviderName + modelName (SysAdmin 路由选定)       │
│   - state                 GenerationState: QUEUED → CONTEXT_RETRIEVED →      │
│                                    PROMPT_BUILT → STREAMING → COMPLETED /    │
│                                    INTERRUPTED_BY_USER / LLM_ERROR           │
│   - lastServerSentEvent   String? (断点续传从这个 id 继续)                   │
│   - errorMessage          String? (LLM 错误时记录，Chat UI 展示"生成失败…")  │
│   - startedAt / endedAt   Instant                                            │
│                                                                              │
│   Domain Method：                                                            │
│   `userInterrupts(sessionId)` → 如果 state 是 STREAMING/QUEUED，改            │
│     INTERRUPTED_BY_USER，并通过 SSE sink 对下游发中断信号（业务规则在聚合内）   │
│                                                                              │
│   Invariants：                                                               │
│   • state=COMPLETED → completionTokens > 0                                  │
│   • 同一 turnId 只允许 1 个 active GenerationTask (用户再次提交需要先中断)    │
└──────────────────────────────────────────────────────────────────────────────┘

内存注册中心 (非持久化，Singleton，放在 application 层)：
┌─ ChatSessionRegistry ───────────────────────────────────────────────────┐
│ Map<SessionId, WebSocketSession> + Map<UserId, Set<SessionId>>          │
│ 方法：register / unregister / kickAllSessionsOfUser(UserId) / broadcast  │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Chat BC Value Objects

| VO | 说明 |
|----|------|
| **ConversationId** (SK) | UUID；跨 UI/History/API 作为业务主键，≠ DB 自增 Long |
| **ClientInfo** | `{ip(String), userAgent(String), platformEnum(IOS/ANDROID/WEB/DESKTOP)}` |
| **UserMessage / AssistantMessage** | role + content + createdAt + messageId（UUID）；Assistant 流式时在 Application 层增量 update，聚合内只接受"最终持久化消息" |
| **ReferenceMapping** / **ReferenceMappings** | `chunkId + fileName + pageNumber + anchorText + similarityScore`；聚合 invariant：每一项必须通过 ACL |
| **TokenUsage** (与 Billing 共享 SK) | `promptTokens + completionTokens + llmProvider + model + requestId`；每次 LLM 返回一个 |
| **GenerationState** | 状态机枚举；合法转移用 EnumSet<Enum> 表写在 VO 内部，非法转移直接抛 `IllegalStateDomainException` |
| **Visibility** | PRIVATE / ORG_VISIBLE / PUBLIC_LINK（会话分享权限） |

### 2.3 Chat BC Repository 接口

```java
// com.yizhaoqi.smartpai.chat.domain.repository
public interface ConversationRepository {
    Optional<Conversation> findByConversationId(ConversationId id);
    Page<ConversationSummary> listForUser(UserId user, boolean includeArchived, Pageable page); // /chat-history
    void save(Conversation conv);        // 含 Turn 集合（事务边界 = 1 个 Conversation + 它的 Turn）
    void archive(ConversationId id);
    void setTitle(ConversationId id, String newTitle);
}

public interface ConversationSessionRepository {
    // WS 连接时注册；断线持久化到 Redis 短 TTL 以便 "刚刚谁断开了" 排查
    void register(ConversationSession session);
    Optional<ConversationSession> findBySessionId(UUID sessionId);
    void updateHeartbeat(UUID sessionId, Instant at);
    void markDisconnected(UUID sessionId, SessionStatus reason);
    int countActiveSessions(UserId userId);
}

public interface GenerationTaskRepository {
    // Redis 存储，TTL = 7 天
    void save(GenerationTask task);
    Optional<GenerationTask> findById(UUID generationId);
    void updateState(UUID generationId, GenerationState newState);
    void appendDeltaTokens(UUID id, int newTokens);
}
```

### 2.4 Chat BC Domain Service（业务规则核心！⭐ 把 ChatHandler 中 80% if/else 移到这里）

```java
// com.yizhaoqi.smartpai.chat.domain.service

/** 🔴 ACL ："当前用户能不能继续这个对话" = 会话 owner，且会话未被删除 */
public interface ConversationOwnershipPolicy {
    void assertCanContinue(UserId subject, ConversationId conversationId);
    void assertCanView(UserId viewer, ConversationId conversationId); // 分享链接用
}

/** 🔴 检索上下文选择 + 组装 Prompt（RAG 编排的核心） */
public interface RagCompositionPolicy {
    /** 1. 选"要从哪些文档检索"（自动选当前组织全部 + 最近访问 N 个文档 / 用户手动 pin） */
    SearchQuery buildSearchQuery(Conversation context, UserMessage newMsg, RagOptions opts);
    /** 2. 拼 System Prompt + Context 段落 + 多轮历史（截断策略：最近 N 轮 + 预算剩余填历史） */
    LlmPrompt buildLlmPrompt(SearchHits hits, List<ConversationTurn> historyWindow, UserMessage newMsg,
                              int promptTokenBudget);
}

/** 🔴 Token 预算策略：4K / 8K / 128K 模型下分别给 history / context / user question / system prompt 分配多少 token */
public interface TokenBudgetPolicy {
    TokenBudget allocate(String modelName, int ctxWindowSize);
}

/** 🔴 引用构建 + ACL 兜底（保证用户看不到不该看的 chunkId 引用） */
public interface ReferenceBuilder {
    ReferenceMappings buildAndValidate(UserId viewer, SearchHits hits);
}

/** 🔴 LLM 选择路由：SysAdmin BC 的 ModelProviderConfigService 作为 Supplier，Chat 只消费接口（ACL 防腐） */
public interface LlmProviderGateway {
    /** SSE 流式生成，返回 Flux<ServerSentEvent>（含 usage / delta / done） */
    Flux<LlmStreamEvent> streamChatCompletion(LlmPrompt prompt, String providerHint, GenerationTask task);
}

/** 🔴 RAG 反馈（👍👎 rating 校验 + 事件） */
public interface RagFeedbackPolicy {
    void rateTurn(UserId rater, ConversationId convId, int turnIndex, UserRating rating, String? comment);
}
```

### 2.5 Chat BC Application Service（编排层，"先做 A，再做 B，出了问题回滚 X"——**不含业务规则**）

```java
// com.yizhaoqi.smartpai.chat.application
@Transactional
public class ChatApplicationService {

    // 1. ConversationOwnershipPolicy 校验权限
    // 2. 查 historyWindow (最近 N turns，Redis 缓存优先 MySQL 兜底)
    // 3. RagCompositionPolicy.buildSearchQuery
    // 4. Search BC HybridSearchService.search()
    // 5. ReferenceBuilder.buildAndValidate
    // 6. TokenBudgetPolicy.allocate + RagCompositionPolicy.buildLlmPrompt
    // 7. GenerationTaskRepository.newTask(state=QUEUED)
    // 8. Billing BC："用户还有钱吗？"预扣费
    // 9. LlmProviderGateway.streamChatCompletion → 订阅并：
    //    a. 每 N 个 delta 写 GenerationTask.appendTokens
    //    b. 结束 → Conversation.addTurn(assistantMessage, references, usage)
    //    c. ConversationRepository.save
    //    d. 发 ChatTurnCompletedEvent (→ Billing 扣费结算)
    // 10. Billing BC：实际 tokens vs 预扣费差额结算
    // 11. WebSocket 推送 type=usage + reference 给前端
}
```

### 2.6 Chat BC Domain Events

| 事件 | 触发 | 载荷 | 下游 |
|------|------|------|------|
| **ConversationCreatedEvent** | 用户新建会话 | `convId, ownerUserId, firstQuestion` | Usage Dashboard、前端会话列表新增 |
| **ChatTurnCompletedEvent** 🔥 | LLM 返回 type=done | `convId, turnIndex, userId, usage, references[], latencyMs, rating=null` | Billing BC → 扣除对话 Token；KB BC → 记录 chunk 被引用次数（将来重排权重）；SysAdmin → 日统计；**必存审计日志** |
| **GenerationInterruptedEvent** | 用户点停止 / WS 断 | `generationId, reason, consumedTokensSoFar` | Billing BC → 按实际用量扣；不写入 conversations |
| **ChatTurnRatedEvent** (RAG 反馈闭环⭐) | 用户点👍/👎 | `convId, turnIndex, rating, comment?, ratedByUserId` | 将来：LlamaIndex / Ragas 离线评测集自动增长；RAG A/B 实验线上指标 |
| **ConversationArchivedEvent** / **DeletedEvent** | 用户删会话 | `convId, userId` | Usage Dashboard 不减少计数，仅会话列表不展示 |

---

下一份：[Billing & Quota BC + System Admin BC + Shared Kernel](./04-BILLING-AND-ADMIN-BC.md)
