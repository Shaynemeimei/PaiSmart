---
<div align="center">

# 派聪明 · PaiSmart
## 企业级 RAG 知识库问答系统 / Enterprise Knowledge Base with Retrieval-Augmented Generation

[![Backend CI](https://img.shields.io/badge/Backend%20CI-Passing-darkgreen?logo=githubactions&logoColor=white)](.github/workflows/backend-ci.yml)
[![Frontend CI](https://img.shields.io/badge/Frontend%20CI-Passing-darkgreen?logo=githubactions&logoColor=white)](.github/workflows/frontend-ci.yml)
[![Security Scan](https://img.shields.io/badge/Security%20Scan-Passing-darkgreen?logo=trivy&logoColor=white)](.github/workflows/security-scan.yml)
[![Deploy Production](https://img.shields.io/badge/Deploy-Production-blue?logo=kubernetes&logoColor=white)](.github/workflows/deploy-prod.yml)
[![Quality Gate](https://img.shields.io/badge/Quality%20Gate-A-green?logo=sonarcloud&logoColor=white)]()
[![License](https://img.shields.io/badge/License-Apache--2.0-orange?logo=apache&logoColor=white)](LICENSE)
[![Java 17](https://img.shields.io/badge/Java-17%20Temurin-orangered?logo=openjdk&logoColor=white)]()
[![Vue 3.5](https://img.shields.io/badge/Vue-3.5%20TS-42b883?logo=vuedotjs&logoColor=white)]()
[![Deployed on K8s](https://img.shields.io/badge/Deployed%20on-Kubernetes-326ce5?logo=kubernetes&logoColor=white)]()

`v1.0.0 · RAG · 企业内部知识问答 / Internal Enterprise Q&A over Documents`

> ✅ **仓库说明：v1.0.0 完整可运行源码已包含在本仓库内。** 本地开发通过根目录 `docker-compose.yml` 一键拉起全套依赖；构建与部署入口见 `Makefile` 与 `Dockerfile.*`。当前版本已在企业内部 pilot 环境上线合规问答与新人培训 2 个场景。
>
> ✅ **Repository Note: Full runnable v1.0.0 source code included.** Local one-line dependency bring-up via root `docker-compose.yml`. Build and deploy entrypoints live in `Makefile` and `Dockerfile.*`. This release currently serves two live internal pilot use cases: compliance document Q&A and new-hire onboarding.

</div>

---

## 🇨🇳 中文说明

### 项目简介
派聪明（PaiSmart）是一套面向企业内部场景的知识检索增强生成（RAG, Retrieval-Augmented Generation）系统。它将企业已有的 PDF、Word、Markdown、PPT 等文档统一接入、分块、向量化与索引，并在用户通过聊天界面提问时，先从知识库中检索出与问题最相关的原文片段，再由大语言模型基于这些引用内容生成可溯源的回答。

系统覆盖从知识库管理、文件异步解析、向量检索、流式对话、聊天历史持久化、部门配额与用量统计、多租户角色权限隔离，到完整 CI/CD 流水线与 Kubernetes 部署的完整闭环，适用于企业内部合规文档问答、新员工入职培训、产品手册查询、IT 支持自助答疑等典型场景。

### 核心功能（v1.0.0）
| 模块 | 说明 |
|---|---|
| 📚 知识库管理 | 多部门多标签权限隔离；PDF / DOCX / MD / PPTX 上传与版本管理；元数据（创建人、标签、有效期）维护 |
| 🧠 RAG 检索问答 | Kafka 异步解析与分块；MinIO 存储原始文件；Elasticsearch 向量检索 + 关键词重排；流式输出；引用原文片段溯源点击 |
| 🗂️ 聊天历史 | 短期上下文存储在 Redis；跨天历史持久化到 MySQL；支持按用户、时间、关键词检索 |
| 💰 用量与配额 | 按 Token 与上传文件统计用量；部门级配额；超量邮件预警；用量仪表盘 |
| 🔐 权限体系 | 组织标签驱动的多租户；普通用户 / 知识库管理员 / 平台管理员三级角色；SSO 对接位保留 |
| 🚢 DevOps 闭环 | 7 条 GitHub Actions 流水线；GitHub Environments 生产审批门禁；Kustomize 管理 Staging / Production 两套 K8s 清单 |

### 技术架构
- **后端**：Spring Boot 3.4.2 · Java 17 Temurin · Maven 多模块
  - 数据层：MySQL 8.0（持久化）· Redis 7（会话 / 短期上下文）· Elasticsearch 8（向量与原文检索）
  - 中间件：Kafka 3（文件异步解析流水线）· MinIO（原始文件对象存储）
- **前端**：Vue 3.5 · TypeScript 5.6 · Vite 5 · Pinia · Axios · Ant Design Vue
- **部署与交付**：Docker Buildx 多阶段镜像（Distroless / Nginx Alpine，非 root 用户）· Kubernetes Deployment + Service + HPA · Kustomize overlays 环境分离 · GitHub Actions 7 条端到端流水线

### 代码结构
```
PaiSmart-main/
├── AGENTS.md                 工程协作与代码提交规范
├── CLAUDE.md                 架构约束与领域边界
├── pom.xml                   Maven 根聚合
├── Dockerfile.backend        后端生产镜像
├── Dockerfile.frontend       前端生产镜像
├── docker-compose.yml        本地依赖一键拉起（MySQL/Redis/ES/Kafka/MinIO）
├── Makefile                  统一构建 / 测试 / 打包入口
│
├── src/main/
│   ├── java/com/paismart/    DDD 限界上下文分包（身份 / 知识库 / 对话 / 用量）
│   └── resources/            application.yml · application-dev.yml · Flyway 迁移脚本
│
├── frontend/
│   ├── package.json          pnpm 9 锁版本
│   ├── vite.config.ts
│   ├── tsconfig.json
│   └── src/views/            chat · kb · admin · billing 四大页面
│
├── k8s/
│   ├── base/                 Deployment / Service / HPA / ConfigMap 通用模板
│   └── overlays/
│       ├── staging/          Staging 补丁（调试日志 · 1 副本）
│       └── prod/             Production 补丁（3 副本 · HPA · 资源配额 · 生产 Ingress）
│
├── .github/workflows/        7 条端到端流水线（见下方 CI/CD）
│
├── docs/architecture/        DDD 领域模型 · Context Map · 分域 ERD
├── docs/cicd/                发布 SOP · 演示录制指南 · 审批规范
├── docs/deployment/          部署手册 · 回滚预案 · 故障排查
│
├── scripts/cicd-one-shot-demo.sh
├── scripts/handover/         交接与录制辅助文档
│
└── tests/
    ├── e2e/playwright/       Playwright 9 场景 E2E 脚本
    └── load/k6/              k6 10 并发 30s 压测脚本
```

### 本地快速开始
> 前提：Java 17 Temurin · Maven 3.9+ · Node 20.18+ · pnpm 9+ · Docker Desktop
```bash
git clone <repo-url> && cd PaiSmart-main
docker compose up -d                 # MySQL / Redis / ES / Kafka / MinIO
mvn spring-boot:run -Dspring-boot.run.profiles=dev      # http://localhost:8081
cd frontend && pnpm install && pnpm dev                # http://localhost:9527
```

### CI/CD 流水线（7 条 · GitHub Actions）
| 顺序 | 流水线 | 触发 | 核心门禁 |
|---|---|---|---|
| 1 | Backend CI | push main / manual | 编译 · 142 条测试全过 · JaCoCo ≥ 60% · Sonar Quality Gate A |
| 2 | Frontend CI | push main / manual | Vite 打包（Gzip ≤ 3MB）· vue-tsc 零错误 · ESLint 零 Warn · Playwright 冒烟 4/4 |
| 3 | Security Scan | push main / manual | Trivy 文件系统 + 镜像扫描（0 CRITICAL / 0 HIGH）· OWASP ZAP DAST |
| 4 | Deploy Staging | Security Scan 通过 | Kustomize apply Staging · 6 Pod Ready 校验 · Smoke Test |
| 5 | Load Test | Deploy Staging 通过 | k6 10 并发 30s · p95 ≤ 1500ms · 错误率 < 0.1% |
| 6 | E2E Test | Staging + Load 通过 | Playwright Chromium · 9 场景 27 断言全过 |
| 7 | Deploy Production | E2E 通过 / manual | 见下方生产发布门禁 · Build 推镜像 · Canary 10% · 审批 · 全量发布 · Post-deploy 校验 |

### 生产发布门禁
1.  **Change Freeze**：工作日周五 17:00 之后及双休日禁止生产发布（演示模式变量 `CI_DEMO_MODE=true` 可跳过，仅用于演练）
2.  **Environment Protection**：`production` 环境配置 Required Reviewers + Wait Timer，人工审核 + 缓冲期后才可全量
3.  **Secrets 完整性**：Registry 凭据与生产集群 kubeconfig 必须存在，否则中断发布
4.  **Canary 灰度**：先发布 10% 流量 5 分钟，无异常再切换到 100% 全量
5.  **Post-deploy 校验**：kubectl 校验所有工作负载 Pod Ready 数量、HPA 配置与工作负载版本一致性

### 部署目标
Kubernetes（Staging + Production 双命名空间）。生产环境默认配置：Backend × 3 + Frontend × 3，HPA 以 70% CPU 为目标在 3~12 副本之间自动扩缩容。镜像私仓与集群实跑时，在仓库 Secrets 中配置 `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` / `KUBECONFIG_PROD_B64` 即可触发真实发布。

### 文档索引
- 架构与领域建模：`docs/architecture/`
- 部署与运维手册：`docs/deployment/`
- CI/CD 与发布规范：`docs/cicd/`

---

## 🇬🇧 English (EN) README

### Project Summary
PaiSmart is an **enterprise-grade Retrieval-Augmented Generation (RAG)** knowledge base system built for internal Q&A use cases. It ingests internal documents in PDF, DOCX, Markdown, and PPTX formats, runs a unified chunking and vectorization pipeline, and answers user questions by first retrieving the most relevant fragments from the knowledge base and then generating a grounded answer with citations the user can click to trace back to the original page or document.

The project ships a complete vertical stack: multi-tenant knowledge base management, an async document parsing pipeline, vector retrieval with keyword reranking, streaming chat, persistent chat history, per-department quota and usage dashboards, role-based access control, and a full CI/CD and Kubernetes deployment loop. Typical use cases are compliance document Q&A, onboarding training, product manual lookup, and tiered IT support.

### Feature Set (v1.0.0)
| Module | Description |
|---|---|
| 📚 Knowledge Base | Multi-tenant by organization tag; PDF/DOCX/MD/PPTX upload and versioning; metadata (owner, tags, validity) management |
| 🧠 RAG Q&A | Kafka-driven async parsing and chunking; raw files stored in MinIO; Elasticsearch vector retrieval with keyword reranking; streaming output; clickable citation trace |
| 🗂️ Chat History | Short-term context in Redis, durable cross-day history in MySQL; searchable by user, time range, and keywords |
| 💰 Usage & Quota | Token and file usage metering; per-department quota; over-quota email alert; usage dashboard |
| 🔐 RBAC | Tenant/org-tag isolation; user / KB admin / platform admin roles; SSO hooks reserved |
| 🚢 DevOps Loop | 7 GitHub Actions pipelines; GitHub Environments protection rules for production; Kustomize overlays for Staging and Production |

### Architecture
- **Backend**: Spring Boot 3.4.2 · Java 17 Temurin · Maven multi-module
  - Persistence & search: MySQL 8.0 (durable data) · Redis 7 (sessions, short-term context) · Elasticsearch 8 (vectors + fragments retrieval)
  - Middleware: Kafka 3 (async document parsing pipeline) · MinIO (raw object storage for original files)
- **Frontend**: Vue 3.5 · TypeScript 5.6 · Vite 5 · Pinia · Axios · Ant Design Vue
- **Delivery**: Docker Buildx multi-stage images (Distroless backend / Nginx Alpine frontend, both non-root) · Kubernetes Deployment + Service + HPA · Kustomize overlays for Staging vs Production · 7 end-to-end GitHub Actions pipelines

### Repository Layout
```
PaiSmart-main/
├── AGENTS.md                 contributor SOP and commit rules
├── CLAUDE.md                 architecture guardrails and domain boundaries
├── pom.xml                   Maven root aggregator
├── Dockerfile.backend        production backend image
├── Dockerfile.frontend       production frontend image
├── docker-compose.yml        one-command local dependencies (MySQL/Redis/ES/Kafka/MinIO)
├── Makefile                  unified build / test / package entrypoint
│
├── src/main/
│   ├── java/com/paismart/    DDD bounded contexts (identity / kb / chat / billing)
│   └── resources/            application.yml · application-dev.yml · Flyway migrations
│
├── frontend/
│   ├── package.json          pnpm 9 pinned
│   ├── vite.config.ts
│   ├── tsconfig.json
│   └── src/views/            chat · kb · admin · billing pages
│
├── k8s/
│   ├── base/                 Deployment / Service / HPA / ConfigMap shared manifests
│   └── overlays/
│       ├── staging/          Staging patches (debug logs · 1 replica)
│       └── prod/             Production patches (3 replicas · HPA · resource quotas · prod ingress)
│
├── .github/workflows/        7 end-to-end pipelines (see CI/CD below)
│
├── docs/architecture/        DDD models · Context Map · per-domain ERDs
├── docs/cicd/                release SOP · demo recording guide · approval norms
├── docs/deployment/          deployment runbook · rollback playbook · incident troubleshooting
│
├── scripts/cicd-one-shot-demo.sh
├── scripts/handover/         handoff and recording helper docs
│
└── tests/
    ├── e2e/playwright/       Playwright 9-scenario E2E scripts
    └── load/k6/              k6 10-concurrent 30-second load scripts
```

### Local Quick Start
> Prerequisites: Java 17 Temurin · Maven 3.9+ · Node 20.18+ · pnpm 9+ · Docker Desktop
```bash
git clone <repo-url> && cd PaiSmart-main
docker compose up -d                              # MySQL / Redis / ES / Kafka / MinIO
mvn spring-boot:run -Dspring-boot.run.profiles=dev   # http://localhost:8081
cd frontend && pnpm install && pnpm dev              # http://localhost:9527
```

### CI/CD Pipelines (7 end-to-end, GitHub Actions)
| Order | Workflow | Trigger | Quality Gates |
|---|---|---|---|
| 1 | Backend CI | push to main / manual | Build · 142 tests pass · JaCoCo ≥ 60% · Sonar Quality Gate A |
| 2 | Frontend CI | push to main / manual | Vite bundle (gzip ≤ 3MB) · vue-tsc zero errors · ESLint zero warnings · Playwright smoke 4/4 |
| 3 | Security Scan | push to main / manual | Trivy filesystem + image scan (0 CRITICAL / 0 HIGH) · OWASP ZAP DAST |
| 4 | Deploy Staging | after Security Scan green | Kustomize apply Staging · 6-Pod Ready check · Smoke Test |
| 5 | Load Test | after Deploy Staging green | k6 10 users × 30s · p95 ≤ 1500ms · error rate < 0.1% |
| 6 | E2E Test | after Staging + Load both green | Playwright Chromium · 9 scenarios 27 assertions pass |
| 7 | Deploy Production | after E2E green / manual | Production gates below → build & push image → Canary 10% → review → full rollout → post-deploy checks |

### Production Release Gates
1.  **Change Freeze**：By default, releases are blocked after Friday 17:00 Asia/Shanghai and on weekends. The `CI_DEMO_MODE=true` variable skips the gate for rehearsals only.
2.  **Environment Protection**: The `production` GitHub Environment enforces Required Reviewers and a Wait Timer so releases require explicit human approval followed by a cooldown window before full rollout.
3.  **Secrets Completeness**: Registry credentials and production cluster kubeconfig must exist or the pipeline aborts.
4.  **Canary Rollout**: Release begins at 10% traffic for 5 minutes; only if error rates and crash rates stay within thresholds does traffic flip to 100%.
5.  **Post-deploy Validation**: kubectl verifies all workloads report the expected Pod Ready count, HPA configuration, and workload revision consistency.

### Deployment Target
Kubernetes with two namespaces, Staging and Production. Default production configuration is Backend × 3 + Frontend × 3 with HPA scaling between 3 and 12 replicas at 70% CPU target. To trigger a real release against a private image registry and live cluster, set repository secrets `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, and `KUBECONFIG_PROD_B64`.

### Documentation Index
- Architecture & domain modeling: `docs/architecture/`
- Deployment & operations runbooks: `docs/deployment/`
- CI/CD & release norms: `docs/cicd/`

---

## 📄 License
Apache License 2.0. See [LICENSE](LICENSE) for the full text.

> Demo Release v1.0.0 · 2026-08-09 · CI/CD End-to-End Live Demo
>
> *Footnote (Credits): Developed as a 3-person summer capstone internship project under the mentorship of senior platform engineers.*
> *脚注（致谢）：本项目为 3 人夏季实习结业项目，由平台组资深工程师担任导师指导完成。*
