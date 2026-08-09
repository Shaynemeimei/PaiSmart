# DDD 分域 ERD（5 张）

评审要求：**一个整体 ERD 拆成不同 ERD 对应不同 Domain**。下面是 5 张 Mermaid ERD，一张对应一个 BC（或合并两个高相关 BC）：

| 文件 | 域 | 包含表 |
|------|-----|--------|
| `10-erd-identity.mmd` | **Identity & Access (IAM)** | users / organization_tags (自引用树) / invite_codes / registration_policy |
| `11-erd-knowledge-base.mmd` | **Knowledge Base (KB)** | file_upload / upload_chunks (原 chunk_info) / document_vectors / file_processing_tasks |
| `12-erd-chat-conversation.mmd` | **Chat & Conversation** | conversations / conversation_sessions / conversation_turns (拆分自 conversations 一行 = 一轮，便于规范) / generation_tasks |
| `13-erd-billing-quota.mmd` | **Billing & Quota** | recharge_packages / recharge_orders / user_token_accounts / user_token_records 追加流水 / user_daily_chat_counts / daily_usage_stats / daily_req_count_stats |
| `14-erd-system-admin.mmd` | **System Admin** | rate_limit_configs / model_provider_configs / admin_audit_logs |

> 跨 BC 引用原则：DDD 推荐**不在数据库层建跨 BC 的 FOREIGN KEY**，因为跨聚合事务不允许。所以我们把跨 BC 的"逻辑外键"用 `comment "◆ SharedKernel VO: UserId / OrgTagId / ConversationId 逻辑引用, 无真实 DB FK"` 标记清楚，在 Service 层 / ACL 层保证一致性，而不是用 MySQL CASCADE。

渲染：VSCode Mermaid 插件 或 https://mermaid.live 粘贴对应 `.mmd` 文件内容即可出图；评审时导出 PNG 做 Artifact。
