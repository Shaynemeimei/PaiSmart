# ════════════════════════════════════════════════════════
# PaiSmart Makefile — 统一入口 (本地 + CI 都能用)
# 命令：make <target>
# 环境变量覆盖：TZ=Asia/Shanghai JAVA_HOME=/... make backend-build
# ════════════════════════════════════════════════════════
SHELL := /bin/bash
.DEFAULT_GOAL := help

TZ            ?= Asia/Shanghai
export TZ

# ======== Help (默认目标) ========
.PHONY: help
help: ## 显示所有可用目标（按类别分组）
	@awk 'BEGIN {FS = ":.*## "; printf "\n\033[1mPaiSmart Makefile —— 分类命令清单\033[0m\n\n\033[36m分类\033[0m        \033[32m目标\033[0m                     \033[0m说明\033[0m\n──────────────────────────────────────────────────────────────────────\n"} \
	/^##@/ { section=$$0; sub(/^##@ /, "", section); } \
	/^[a-zA-Z_-]+:.*## / { \
		name=$$1; desc=$$2; \
		printf "  \033[36m%-10s\033[0m  \033[32m%-24s\033[0m %s\n", section, name, desc; \
	}' $(MAKEFILE_LIST)
	@echo

##@  本地启动
.PHONY: dev dev-backend dev-frontend
dev: dev-backend dev-frontend ## (后台启动) 本地 IDE 通常分别启动，这里仅做提醒
	@echo "💡 推荐：后端用 IDE 启动 SmartPaiApplication (热部署)；前端 cd frontend && pnpm dev :9527"
dev-backend: ## mvn spring-boot:run (非热部署，少用)
	mvn -q spring-boot:run -Dspring-boot.run.profiles=dev
dev-frontend: ## pnpm dev :9527
	cd frontend && corepack enable && pnpm install && pnpm dev

##@  构建
.PHONY: backend-build frontend-build all-build
backend-build: ## 后端：mvn 编译(跳过测试)
	mvn -q -DskipTests compile
frontend-build: ## 前端：pnpm install 后 build --mode prod
	cd frontend && corepack enable && pnpm install --frozen-lockfile --prefer-offline && pnpm build
all-build: backend-build frontend-build ## 前后端都构建

##@  测试
.PHONY: backend-test backend-coverage backend-sonar-local
backend-test: ## 后端：H2 跑所有单元/集成测试
	mvn -B test -Duser.timezone=Asia/Shanghai
backend-coverage: ## 后端：JaCoCo 覆盖率 (CI 门禁用)
	mvn -B verify -P coverage -Duser.timezone=Asia/Shanghai
backend-sonar-local: ## 本地 mvn SonarQube 上送 (需要 SONAR_TOKEN + SONAR_HOST_URL env)
	@if [ -z "$$SONAR_TOKEN" ] || [ -z "$$SONAR_HOST_URL" ]; then \
		echo "::error::需要先 export SONAR_TOKEN=... SONAR_HOST_URL=... SONAR_PROJECT_KEY=..."; exit 1; fi
	mvn -B verify -P coverage sonar:sonar \
		-Dsonar.projectKey=$${SONAR_PROJECT_KEY:-PaiSmart-backend} \
		-Dsonar.host.url=$$SONAR_HOST_URL \
		-Dsonar.login=$$SONAR_TOKEN

.PHONY: frontend-typecheck frontend-lint frontend-e2e
frontend-typecheck:
	cd frontend && corepack enable && pnpm typecheck
frontend-lint:
	cd frontend && corepack enable && pnpm exec eslint . --max-warnings 0
frontend-e2e: ## 前端 Playwright E2E (首次先 make e2e-install)
	cd frontend && pnpm e2e
e2e-install:
	cd frontend && pnpm e2e:install

##@  安全扫描（本地也能跑，不必等 CI）
.PHONY: trivy-fs trivy-image-backend trivy-image-frontend security-local
TRIVY ?= trivy
trivy-fs: ## 本地 Trivy FS 扫 CRITICAL+HIGH（跳过已修复）
	@command -v $(TRIVY) >/dev/null 2>&1 || { echo "请先 brew install aquasecurity/trivy/trivy"; exit 1; }
	$(TRIVY fs --severity CRITICAL,HIGH --ignore-unfixed --exit-code 0 .
trivy-image-backend:
	@docker image inspect paismart-backend:local >/dev/null 2>&1 || { echo "先 make docker-build-backend TAG=local"; exit 2; }
	$(TRIVY image --severity CRITICAL,HIGH --ignore-unfixed paismart-backend:local
trivy-image-frontend:
	@docker image inspect paismart-frontend:local >/dev/null 2>&1 || { echo "先 make docker-build-frontend TAG=local"; exit 2; }
	$(TRIVY image --severity CRITICAL,HIGH --ignore-unfixed paismart-frontend:local
security-local: backend-coverage trivy-fs ## 一键：本地质量 + 安全门禁

##@  Docker
TAG ?= local
IMG_NS ?= paismart
.PHONY: docker-build-backend docker-build-frontend docker-build-all
docker-build-backend:  ## 构建后端镜像，TAG 默认 local
	docker buildx build -f Dockerfile.backend -t $(IMG_NS)/paismart-backend:$(TAG) --load .
docker-build-frontend:
	docker buildx build -f Dockerfile.frontend -t $(IMG_NS)/paismart-frontend:$(TAG) --load ./frontend
docker-build-all: docker-build-backend docker-build-frontend

##@  K8s 部署
K8S_CTX ?= kubernetes-admin@cluster.local
NS_DEV    ?= paismart-dev
NS_PROD   ?= paismart-prod
.PHONY: k8s-apply-dev k8s-apply-prod k8s-status k8s-logs-backend k8s-logs-frontend k8s-hpa k8s-top
k8s-apply-dev: ## kubectl apply -k overlays/dev
	kubectl --context=$(K8S_CTX) apply -k k8s/overlays/dev
k8s-apply-prod:
	kubectl --context=$(K8S_CTX) apply -k k8s/overlays/prod
k8s-status: ## 查看所有 pod / deploy / hpa / ingress (dev)
	@echo "── Pods (dev) ──"; kubectl --context=$(K8S_CTX) -n $(NS_DEV) get pods -o wide
	@echo -e "\n── HPA ──";   kubectl --context=$(K8S_CTX) -n $(NS_DEV) get hpa
	@echo -e "\n── Ingress ──"; kubectl --context=$(K8S_CTX) -n $(NS_DEV) get ingress
k8s-logs-backend: ## 跟随 backend 最新一个 pod 的日志
	kubectl --context=$(K8S_CTX) -n $(NS_DEV) logs -f deploy/paismart-backend
k8s-logs-frontend:
	kubectl --context=$(K8S_CTX) -n $(NS_DEV) logs -f deploy/paismart-frontend
k8s-hpa: ## 持续观察 HPA (watch)
	watch -n 5 kubectl --context=$(K8S_CTX) -n $(NS_DEV) get hpa
k8s-top:
	kubectl --context=$(K8S_CTX) -n $(NS_DEV) top pods

##@  CI/CD 本地复现（评审前手动跑一遍，确保流水线能过）
.PHONY: ci-replay-all ci-replay-backend ci-replay-frontend
ci-replay-backend: backend-test backend-coverage trivy-fs
ci-replay-frontend: frontend-typecheck frontend-lint frontend-build
ci-replay-all:      ci-replay-backend ci-replay-frontend
	@echo ""
	@echo "✅ 本地复现完成。若全部通过，推到主干大概率 CI 全绿。"
	@echo "   下一步 → 到 GitHub Actions 打开 security-scan / load-test / e2e-test 手动跑一遍拿到 Artifact 截图。"
