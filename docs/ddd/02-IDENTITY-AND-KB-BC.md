# 两个核心 BC 设计：Identity & Access (IAM) + Knowledge Base (KB)

每个 BC 的 DDD 四件套：

1. **Aggregate 聚合根清单（含 Entity 树）**
2. **Value Objects（值对象）**
3. **Repository 接口（domain 层，只有接口，实现在 infrastructure）**
4. **Domain Events（领域事件）**
5. **Domain Service（跨聚合规则）**
6. **Invariants（不变量/业务规则，写在 Aggregate 内部）**

---

## 一、BC 1：Identity & Access (IAM)

> 包路径重构目标：`com.yizhaoqi.smartpai.identity`
> 现有关联代码：`UserService` / `InviteCodeService` / `OrgTagCacheService` / `JwtUtils` / `CustomUserDetailsService` / `SecurityConfig` / `OrgTagAuthorizationFilter` / `UserRepository` / `OrganizationTagRepository` / `InviteCodeRepository`

### 1.1 Aggregate 结构（4 个 Aggregate Root，彼此通过 VO 引用，不做对象级强引用）

```
┌─ Aggregate: User ─────────────────────────────────────────────────┐
│  Aggregate Root: User (Entity)                                     │
│   - UserId                VO: SharedKernel.UserId                 │
│   - username              String  (唯一约束)                       │
│   - passwordHash          PasswordHash VO                         │
│   - role                  Role ENUM (USER / ADMIN)                │
│   - orgTags               OrgTagSet VO  (多个 OrgTagId + 去重)     │
│   - primaryOrg            OrgTagId VO (必须是 orgTags 的子集)     │
│   - createdAt / updatedAt Instant                                 │
│                                                                    │
│   内部 Entity: 无                                                  │
│                                                                    │
│   Invariants (不变量，写在 User 构造/setter 里)：                   │
│   • username 6~32 字符、字母数字下划线                              │
│   • orgTags 不能空（新用户至少分到 "default" 公共组织？视业务）     │
│   • primaryOrg 如果非空必须 ∈ orgTags                              │
│   • passwordHash 必须通过 PasswordUtil 强度校验                    │
│   • ADMIN 用户不能最后唯一一个被"降级为 USER"                      │
└────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: OrganizationTag ─────────────────────────────────────┐
│  AR: OrganizationTag (Entity, 层级树形)                           │
│   - OrgTagId              VO: SharedKernel.OrgTagId              │
│   - name                  String  (同层兄弟不重复)                 │
│   - parentTagId           OrgTagId? (null = 顶级组织)             │
│   - uploadMaxSizeBytes    Long   (上传文件最大字节数，可继承父)     │
│   - description           String?                                │
│                                                                    │
│   内部 Entity: 无                                                  │
│                                                                    │
│   Invariants：                                                     │
│   • 不能循环祖先（parentTagId 不能指向自己 / 后代）                │
│   • name 在同一父下必须唯一                                        │
│   • uploadMaxSizeBytes > 0；若未设则继承 parent 的值               │
│   • 删除 OrganizationTag 前：User.orgTags、FileUpload.orgTag 先迁移│
└────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: InviteCode ───────────────────────────────────────────┐
│  AR: InviteCode (Entity)                                           │
│   - code                  String (6~12, 唯一)                      │
│   - createdBy             UserId (谁生成的邀请码)                  │
│   - channel               InviteChannel ENUM (MARKETING / INTERNAL│
│                                                / PARTNER / DEFAULT)│
│   - usageLimit            Int (0=无限次, 1=一次性, N=多次)         │
│   - usedCount             Int                                     │
│   - bindQuota(可选)       LlmTokenAmount + EmbeddingTokenAmount   │
│                           (注册用户初始配额，渠道运营)              │
│   - expiresAt             Instant?                                │
│   - usedBy (关联非强一致性, 只存历史)  Set<UserId>                 │
│                                                                    │
│   Invariants：                                                     │
│   • usedCount ≤ usageLimit 或 usageLimit=0                        │
│   • expiresAt 未过期；过期代码 "redeem" 抛 DomainException         │
│   • code 必须 uppercase + 无歧义字符 (排除 0/O/1/I)               │
└────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: RegistrationPolicy (单例聚合) ───────────────────────┐
│  AR: RegistrationPolicy (全局一条记录; 当前是 model.RegistrationMode│
│                           + 应用配置，现抽成聚合)                   │
│   - mode                  RegistrationMode: OPEN / INVITE_ONLY /  │
│                                                  CLOSED            │
│   - defaultUserRole       Role                                    │
│   - defaultOrgTags        OrgTagSet (新注册用户默认进哪些组织)     │
│   - captchaRequired       boolean                                 │
│   - emailVerification     boolean                                 │
│                                                                    │
│   Invariants：                                                     │
│   • CLOSED 模式时所有 /api/auth/register 请求直接拒绝              │
│   • INVITE_ONLY 模式必须传有效 inviteCode 才能注册                │
└────────────────────────────────────────────────────────────────────┘
```

### 1.2 IAM Value Objects（只在本 BC 用，跨 BC 的放 Shared Kernel）

| VO | 字段/校验 | 用途 |
|----|---------|------|
| **PasswordHash** | `String hash; PasswordHash of(String raw)` 用 BCrypt/Argon2 生成 | 存用户密码；永远不暴露明文 |
| **Username** | `String value; regex [A-Za-z0-9_]{6,32}` | 登录名强类型；避免空/非法字符 |
| **InviteChannel** | Enum；与 InviteCode.channel 对齐 | 渠道运营统计维度 |
| **JwtToken** | `String accessToken; Instant expiresAt; String refreshToken?` | JwtUtils 返回值强类型；不散落 String |

### 1.3 IAM Repository 接口（domain 层）

```java
// package: com.yizhaoqi.smartpai.identity.domain.repository
public interface UserRepository {
    Optional<User> findById(UserId id);
    Optional<User> findByUsername(Username username);
    boolean existsByUsername(Username username);
    void save(User user);                       // INSERT / UPDATE（Upsert 语义）
    List<User> findByOrgTag(OrgTagId tagId);   // 组织下成员列表
    long countByRole(Role role);                // 判断最后 ADMIN
}

public interface OrganizationTagRepository {
    Optional<OrganizationTag> findById(OrgTagId id);
    List<OrganizationTag> findByParent(OrgTagId parentId);
    List<OrganizationTag> findAncestorChain(OrgTagId id); // 用于"继承uploadMaxSize"
    void save(OrganizationTag tag);
    void delete(OrgTagId id);    // 调用前 invariant: 无 User/File 仍引用
    boolean existsChildren(OrgTagId id);
}

public interface InviteCodeRepository {
    Optional<InviteCode> findByCode(String code);
    void save(InviteCode inviteCode);
    Page<InviteCode> search(InviteChannel channel, String createdByLike, Pageable page);
}

public interface RegistrationPolicyRepository {
    RegistrationPolicy get();  // 单例
    void save(RegistrationPolicy policy);
}
```

> 注：`impl` 放在 `identity.infrastructure.persistence.jpa.JpaUserRepository`（代理当前 Spring Data JPA `UserRepository` 接口，适配器模式）—— 渐进式重构不破坏现有代码。

### 1.4 IAM Domain Service（跨聚合规则）

```java
// com.yizhaoqi.smartpai.identity.domain.service
// 不在 Service 技术分层里写 if；放到 Domain Service
public interface OrgTagAccessPolicy {
    /**
     * 核心 ACL 规则：判断 "当前 subjectUser 能不能访问 targetFile"
     * 返回 true 时下游（Chat RAG 检索 / 文档预览 / 下载）才放行
     * 规则优先级：FileUpload Owner > is_public=true > orgTag 成员交集
     */
    boolean canAccessFile(User subjectUser, FileUpload targetFile);

    /**
     * 搜索域 ACL 过滤：给定用户，返回 ES 查询里应该拼的 bool filter 条件 DSL
     * （避免 ACL 规则在 Chat / Search / Download 3 处各写一套 if）
     */
    AccessControlFilter buildSearchFilter(User subjectUser);
}

public interface RegistrationService {
    /**
     * 注册：按 RegistrationPolicy.mode 校验 inviteCode；创建 User 并分配默认 OrgTagSet；发领域事件
     */
    User register(RegisterCommand cmd);
}
```

### 1.5 IAM Domain Events

| 事件名 | 触发时机 | 载荷字段 | 下游订阅方（其他 BC） |
|--------|---------|---------|---------------------|
| `UserRegisteredEvent` | 用户注册成功 | `userId, username, orgTags, invitedBy?, channel` | Billing BC → 初始化日配额 / 初始 Token 余额 |
| `UserRoleChangedEvent` | ADMIN ↔ USER 变更 | `userId, fromRole, toRole, operatorUserId` | SysAdmin BC → 改限流规则 |
| `OrganizationTagCreatedEvent` / `DeletedEvent` | 组织新建/删除 | `orgTagId, name` | KB BC → 刷新 OrgTagCache；Search BC → 重建 ACL 缓存 |
| `InviteCodeRedeemedEvent` | 邀请码被使用 | `code, redeemedByUserId, channel` | Billing BC → 发放邀请渠道绑定的初始 Token |

---

## 二、BC 2：Knowledge Base (知识库入仓生命周期)

> 包路径：`com.yizhaoqi.smartpai.knowledgebase`
> 现有关联代码：`DocumentService` / `UploadService` / `ParseService` / `VectorizationService` / `ElasticsearchService` (写入部分) / `FileUploadRepository` / `ChunkInfoRepository` / `DocumentVectorRepository` / Kafka `FileProcessingConsumer`

### 2.1 Aggregate 结构（⚠️ 当前"Chunk"一词多义的关键拆分）

```
┌─ Aggregate: FileUpload (🔥 核心聚合) ───────────────────────────────┐
│  AR: FileUpload                                                     │
│   - FileId(内部持久化) Long PK                                       │
│   - fileMd5                SharedKernel.FileMd5 VO                 │
│   - fileName               String (原始文件名, 非唯一)              │
│   - fileSizeBytes          Long (>0)                                │
│   - fileType               FileType? VO: PDF/DOCX/XLSX/PPTX/TXT/   │
│                                             MD/CSV/IMAGE/OTHER     │
│   - ownerUserId            UserId VO                                │
│   - orgTag                 OrgTagId VO? (可为空=个人私有)           │
│   - isPublic               boolean                                 │
│   - uploadStatus           UploadStatus ENUM:                      │
│                              UPLOADING / MERGING / COMPLETED       │
│   - vectorizationStatus    VectorizationStatus: PENDING /          │
│                                   PROCESSING / COMPLETED / FAILED  │
│   - estimatedEmbeddingTokens Long? (预估 chunk 消耗)               │
│   - actualEmbeddingTokens    Long? (实际解析+向量化后)              │
│   - storagePath            MinioObjectPath VO (bucket/objectKey)   │
│   - failureReason          String? (vectorizationStatus=FAILED 时) │
│   - createdAt / updatedAt  Instant                                 │
│                                                                      │
│   ├── 内部 Child Entity(集合): UploadChunk (⬅️ 原 ChunkInfo)        │
│   │     • chunkIndex        Int (0..N-1)                           │
│   │     • storagePath       MinioObjectPath VO                     │
│   │     • sizeBytes         Long                                   │
│   │     Invariants: 0 ≤ chunkIndex < ceil(totalSize/chunkSizeBytes)│
│   │                所有 UploadChunk sizeBytes 之和 = fileSizeBytes  │
│   │                  当且仅当 uploadStatus=COMPLETED                │
│   └── 内部 Child Entity(集合): TextChunk (⬅️ DocumentVector 原文+元)│
│         • chunkId         SharedKernel.ChunkId VO                  │
│         • content         String (原文)                            │
│         • contentTokens   Int                                      │
│         • pageNumber      PageNumber VO?                           │
│         • anchorText      String? (PDF 页上下文定位)               │
│         • sourceOffset    IntRange? (字符级 offset 区间)            │
│         • createdAt       Instant                                  │
│                                                                      │
│   Invariants:                                                        │
│   • fileMd5 + ownerUserId 联合唯一 (DB UK 已对)                     │
│   • uploadStatus = COMPLETED → UploadChunks 集非空且和 = fileSize   │
│   • vectorizationStatus = COMPLETED → TextChunks 集非空 & 已索引   │
│   • orgTag 为空时 isPublic 必须是 false (个人私有文档)              │
│   • isPublic=true 时，所有 User 可 read，但仅 Owner/Admin 可 delete │
│   • TRANSITION 状态机（方法级变更，禁止直接改字段）：                │
│     UPLOADING → MERGING → COMPLETED → PENDING → PROCESSING         │
│                                                    ↓         ↓      │
│                                              COMPLETED    FAILED    │
└──────────────────────────────────────────────────────────────────────┘

┌─ Aggregate: FileProcessingTask (Kafka 跟踪) ──────────────────────┐
│  AR: FileProcessingTask (单独聚合，避免 FileUpload 状态变更过于频繁) │
│   - taskId                String (Kafka key)                       │
│   - fileMd5 + ownerUserId  外键引用 FileUpload                     │
│   - parseStatus           StepStatus PENDING/RUNNING/DONE/FAILED   │
│   - chunkStatus           StepStatus                               │
│   - vectorStatus          StepStatus                               │
│   - indexStatus           StepStatus                               │
│   - retryCount            Int                                      │
│   - lastError             String?                                  │
│   - processingStartedAt   Instant?                                 │
│   - processingFinishedAt  Instant?                                 │
│                                                                     │
│   Domain Method: `retryIfEligible(maxRetries=3)` → 每 FAILED 步骤  │
│                   回到 PENDING + 发 Kafka 消息；>maxRetries 标记终态│
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 KB Value Objects

| VO | 内容 |
|----|------|
| **FileMd5** (SK) | 32 hex；equals/hashCode 仅按值 |
| **ChunkId** (SK) | `FileMd5:Int`；全局唯一 Chunk 标识 |
| **FileType** | Enum PDF/DOCX/XLSX/PPTX/TXT/MD/CSV/IMAGE(JPEG/PNG/TIFF)/OTHER；每个类型映射不同解析策略（Tika/LiteParse/OCR） |
| **MinioObjectPath** | `bucket:key`；解析成 MinIO SDK `GetObjectArgs` 只在 infrastructure |
| **UploadStatus** / **VectorizationStatus** / **StepStatus** | 强类型枚举（代替 FileUpload 中 static int STATUS_COMPLETED 这种魔法数） |
| **PageNumber** (SK) | Integer，1..N |
| **IntRange** | `{startInclusive, endExclusive}` 用于记录 chunk 在原文的字符级偏移（调试/溯源） |
| **ParseStrategy** | 根据 FileType 计算得到的解析链路：Tika / LiteParse + OCR? / 图片 AliyunOCR? |

### 2.3 KB Repository 接口

```java
// com.yizhaoqi.smartpai.knowledgebase.domain.repository
public interface FileUploadRepository {
    Optional<FileUpload> findByFileMd5AndOwnerUserId(FileMd5 md5, UserId owner);
    Optional<FileUpload> findById(Long fileId);

    /** 权限查询: "Owner OR Public OR OrgMember" 三并集（Chat/Search 都要用到，统一入口） */
    Page<FileUpload> findAccessibleForUser(UserId viewer, AccessQuery query, Pageable page);

    void save(FileUpload file);              // 连同 UploadChunks / TextChunks 一个事务
    void delete(FileUpload file);             // 级联删 MinIO + ES + MySQL 三位置
    void updateVectorizationStatus(FileMd5 md5, UserId owner, VectorizationStatus status);
}

public interface FileProcessingTaskRepository {
    Optional<FileProcessingTask> findByTaskId(String taskId);
    void save(FileProcessingTask task);
    List<FileProcessingTask> findStuckRunningForMoreThan(Duration timeout); // 兜底巡检 & 自动重试
}

/** 只负责 ES 写入；读取查询放 Search BC 的接口 */
public interface KnowledgeIndexGateway {   // infrastructure → ElasticsearchService 实现
    void indexChunk(FileUpload file, TextChunk chunk, float[] vector);
    void deleteAllByFile(FileMd5 md5, UserId owner);
    void refresh();
}

/** 对象存储网关；infrastructure → MinIO 实现 */
public interface ObjectStorageGateway {
    void putChunk(MinioObjectPath path, InputStream data, long length);
    InputStream get(MinioObjectPath path);
    void delete(MinioObjectPath path);
    String generateSignedDownloadUrl(MinioObjectPath path, Duration ttl); // 预览 URL
}
```

### 2.4 KB Domain Service

```java
// com.yizhaoqi.smartpai.knowledgebase.domain.service

/** Chunking 策略接口：可切换固定窗口 / 语义切块 / 递归字符切块 (LangChain 风格) */
public interface ChunkingPolicy {
    List<TextChunk> chunk(FileUpload file, String parsedPlainText, ParsedStructure structure);
}

/** 解析策略：根据 FileType 选择 Tika / LiteParse / 图片 OCR + 表格处理 */
public interface DocumentParserPolicy {
    ParseResult parse(FileUpload file, byte[] fileBytes);
}

/** 上传权限校验 + 组织限额校验（Upload Service 的业务规则下沉） */
public interface KnowledgeOwnershipPolicy {
    void assertCanUpload(UserId uploader, OrgTagId? targetOrgTag, long fileSizeBytes, FileType type);
    void assertCanDelete(UserId operator, FileUpload file); // Owner + ADMIN
}
```

### 2.5 KB Domain Events

| 事件 | 触发点 | 载荷 | 下游 |
|------|--------|------|------|
| **FileUploadedAndMergedEvent** | UploadService → uploadStatus=COMPLETED | `fileMd5, ownerUserId, orgTag, isPublic, storagePath, fileType` | KB 内部：触发 Kafka 发送到 file-processing-topic |
| **DocumentParseCompletedEvent** | ParseService 成功解析出文本 | `fileMd5, ownerUserId, totalPages, plainTextLength, ocrUsed?` | KB 内部：进入 Chunking |
| **DocumentChunkedEvent** | ChunkingPolicy 完成切块 | `fileMd5, chunkCount, totalTokens` | KB 内部：进入向量化 |
| **ChunkVectorizedEvent** | 单个 Chunk 生成向量 | `chunkId, vectorDim=2048` | KB 内部：索引 ES |
| **DocumentIndexedEvent** 🔥 | **整个文档向量化 + 索引完成，vectorizationStatus=COMPLETED** | `fileMd5, ownerUserId, chunkCount, totalEmbeddingTokens, elapsedMs` | **Chat BC → 前端推送上传完成通知**；Billing BC → 扣除 Embedding Token；SysAdmin → 日统计 |
| **DocumentParseFailedEvent** / **DocumentIndexFailedEvent** | 任一阶段终态失败 | `fileMd5, reason, step, retryCount` | 给 Owner 用户发站内信（将来）+ 前端 Toast 失败提示 |
| **FileDeletedEvent** | 用户删除文档 | `fileMd5, ownerUserId` | Search BC → ES 清理；Billing → 统计回退？（按业务决定不退） |

---

## 三、Aggregate 间关系 Mermaid 图

见 `diagrams/04-aggregate-relationships.mmd`（IAM + KB 聚合关系）与每个 BC 的 ERD 放在分域 ERD 中。

继续下一份：[Search BC + Chat BC](./03-SEARCH-AND-CHAT-BC.md)。
