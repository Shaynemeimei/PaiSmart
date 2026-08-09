# PaiSmart Kubernetes 部署指南（P0 落地篇）

本目录包含 PaiSmart 全部 K8s 部署工件：

- `Dockerfile.backend` / `Dockerfile.frontend`：前后端多阶段 Docker 构建
- `k8s/base/`：基础资源（Namespace / SA / Quota / NetPol / Backend / Frontend）
- `k8s/overlays/dev`：开发环境差异（更低资源 / debug 日志 / dev 域名）
- `k8s/overlays/prod`：生产环境差异（多 AZ / 强制 TLS / ModSecurity WAF / HPA）
- `k8s/docs/CLUSTER-SIZING.md`：**集群规模设计（infra / worker / node pool 明细表）** — 评审用
- `k8s/infrastructure/README.md`：**云托管 vs K8s Operator 中间件决策 + 部署占位** — 评审用

---

## 一、目录结构速览

```
PaiSmart-main/
├── Dockerfile.backend                 ← ✅ 后端 Spring Boot 多阶段分层镜像
├── Dockerfile.frontend                ← ✅ 前端 Vite→Nginx 预压缩
├── .dockerignore.backend
├── .dockerignore.frontend
└── k8s/
    ├── base/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml             # paismart
    │   ├── serviceaccounts-and-quotas.yaml  # SA + ResourceQuota + LimitRange
    │   ├── networkpolicy.yaml         # Zero-Trust：默认拒绝 + 按组件放行
    │   ├── backend/
    │   │   ├── configmap.yaml         # 非敏感 env
    │   │   ├── secret-example.yaml    # 🔐 示例 Secret（真实用 SealedSecret）
    │   │   ├── secret-example.env     # 🔐 对应 env 文件
    │   │   ├── deployment.yaml        # Deploy + probes + init-container + affinity + securityContext
    │   │   ├── service.yaml           # ClusterIP + prometheus annotations
    │   │   ├── hpa.yaml               # HPA 2→10 CPU70 / Mem75
    │   │   └── pdb.yaml               # minAvailable 1
    │   └── frontend/
    │       ├── nginx.conf             # SPA + /api + /ws + 安全响应头 + 预压缩
    │       ├── configmap-placeholder.yaml  # （由 kustomization 的 configMapGenerator 真正生成）
    │       ├── deployment.yaml        # 只读根 FS + 资源 + 探针
    │       ├── service.yaml
    │       ├── hpa.yaml               # HPA 2→8
    │       └── pdb.yaml
    ├── overlays/
    │   ├── dev/
    │   │   ├── kustomization.yaml     # 引用 ../../base + patches
    │   │   ├── namespace.yaml         # paismart-dev
    │   │   ├── ingress.yaml           # dev-smart.paicoding.com
    │   │   ├── backend-patch.yaml     # replicas=2, 较小资源
    │   │   ├── frontend-patch.yaml    # replicas=1
    │   │   ├── hpa-patch.yaml         # min/max 减小
    │   │   └── secrets.backend.env.example  # 🔐 示例
    │   └── prod/
    │       ├── kustomization.yaml
    │       ├── namespace.yaml         # paismart-prod (restricted PSA)
    │       ├── ingress.yaml           # 强制 TLS + HSTS + ModSecurity + RPS 限流
    │       ├── backend-patch.yaml     # replicas=3, topologySpreadConstraints, OTel agent
    │       ├── frontend-patch.yaml    # replicas=3, 跨 AZ
    │       ├── hpa-backend-patch.yaml # min=3/max=10, scaleDown 10min
    │       ├── hpa-frontend-patch.yaml
    │       └── pdb-patch.yaml         # minAvailable=2
    ├── docs/
    │   └── CLUSTER-SIZING.md          ← ✅ 集群/节点池/规格/网络/CIDR 设计表
    └── infrastructure/
        └── README.md                  ← ✅ 中间件选型云托管 vs Operator 决策
```

---

## 二、前置准备（在你开始 `kubectl apply` 之前）

### 2.1 后端 POM 补 Actuator + Prometheus（Dockerfile 探针要用到）

在 `pom.xml` `<dependencies>` 里补 3 个 starter（当前缺失）：

```xml
<!-- Actuator: k8s readiness/liveness + Prometheus scrape -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-registry-prometheus</artifactId>
  <scope>runtime</scope>
</dependency>
<!-- 分布式 Tracing（配合 OTel Agent / OTel Collector） -->
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>
<dependency>
  <groupId>io.opentelemetry</groupId>
  <artifactId>opentelemetry-exporter-otlp</artifactId>
  <scope>runtime</scope>
</dependency>
```

`backend/configmap.yaml` 已经写好 `MANAGEMENT_*` 暴露 endpoints。

### 2.2 集群与客户端

```bash
# 必需
kubectl >= 1.30
kustomize >= 5.3  (kubectl apply -k 内置够用，单独装也可)
helm 3            # 安装 Operator / Ingress
kubeseal          # 加密 Secret（强烈推荐）

# 建议
kubectx / kubens
stern (多 Pod 日志 tail)
```

### 2.3 一次性安装平台组件（见 infrastructure/README.md）

```bash
# Ingress-Nginx (必须，前后端 Ingress 入口)
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# cert-manager (自动签发 TLS)
helm upgrade --install cert-manager jetstack/cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  --version v1.16.1 --set installCRDs=true

# Sealed-Secrets (加密 Secret 入 Git)
helm upgrade --install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --namespace sealed-secrets --create-namespace

# Reloader (ConfigMap/Secret 变更自动滚动 Pod)
helm upgrade --install reloader stakater-reloader \
  --repo https://stakater.github.io/stakater-charts \
  --namespace reloader --create-namespace

# Prometheus/Grafana (监控栈)
helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --namespace monitoring --create-namespace
```

---

## 三、构建与推送镜像

> 把 `registry.paicoding.com/paismart` 改成你自己的镜像仓库地址（阿里云 ACR / AWS ECR / Docker Hub / Harbor）。

```bash
# === Backend ===
docker build -f Dockerfile.backend \
  --ignorefile .dockerignore.backend \
  -t registry.paicoding.com/paismart/backend:1.3.13 .
docker push registry.paicoding.com/paismart/backend:1.3.13

# === Frontend ===
docker build -f Dockerfile.frontend \
  --ignorefile .dockerignore.frontend \
  -t registry.paicoding.com/paismart/frontend:1.3.13 .
docker push registry.paicoding.com/paismart/frontend:1.3.13

# === 私有仓库 pull secret ===
kubectl -n paismart-dev create secret docker-registry paismart-registry-secret \
  --docker-server=registry.paicoding.com \
  --docker-username=<robot-user> \
  --docker-password=<robot-pass> \
  --dry-run=client -o yaml | kubeseal --format yaml > k8s/overlays/dev/registry-secret.yaml
# 然后把这个 SealedSecret 加入 overlays/dev/kustomization.yaml resources 列表
```

---

## 四、部署到 DEV 环境

```bash
# 4.1 拷贝密钥示例并填入真实值（不提交到 Git！）
cp k8s/overlays/dev/secrets.backend.env.example k8s/overlays/dev/secrets.backend.env
# 手动填入 DEV 环境真实 MYSQL_PWD / JWT / API_KEY

# 4.2 用 kubeseal 生成真正的 SealedSecret（可提交 Git）
kubectl -n paismart-dev create secret generic paismart-backend-secrets \
  --from-env-file=k8s/overlays/dev/secrets.backend.env \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets \
             --controller-namespace=sealed-secrets \
             --format yaml > k8s/overlays/dev/sealedsecret-backend.yaml

# 4.3 把 dev/kustomization.yaml 的 secretGenerator 替换 / 追加上面的 sealedsecret yaml
# (可选简单做法：dev 环境直接 kubectl apply secret，不进 Git)

# 4.4 预览 + 应用
kubectl apply -k k8s/overlays/dev --dry-run=client -o yaml | less
kubectl apply -k k8s/overlays/dev

# 4.5 检查 Pod / 探针
kubens paismart-dev
kubectl get pods -o wide -w
kubectl describe pod <backend-pod-name> | tail -30
kubectl logs -f deploy/paismart-backend-dev
kubectl port-forward svc/paismart-backend-dev 8081:8080
curl http://127.0.0.1:8081/actuator/health/readiness | jq .

# 4.6 配置 /etc/hosts 后访问
# 先获取 ingress-nginx external-ip
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
# 然后加：<EXTERNAL-IP> dev-smart.paicoding.com → 浏览器打开
```

---

## 五、部署到 PROD 环境

```bash
# 与 dev 类似，但必须全部用 SealedSecret，不要有任何明文 Secret
# 1) 建生产专属机器人账号(ACR/ECR) → pull secret → SealedSecret
# 2) JWT_SECRET_KEY 单独用 Vault / AWS Secrets Manager 生成并注入 ExternalSecret
# 3) 先 apply staging → smoke test → prod canary 10% → 全量

kubectl apply -k k8s/overlays/prod
kubectl get pods -n paismart-prod -o wide --show-labels
# 确认跨 3 AZ：
kubectl get pods -n paismart-prod -o=custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,AZ:.metadata.labels.topology\.kubernetes\.io/zone

# 检查 Ingress + 证书
kubectl get ingress -n paismart-prod
kubectl get certificates -n paismart-prod  # READY=True
kubectl describe certificaterequest -n paismart-prod | tail -50

# 最后访问：
# https://smart.paicoding.com → 登录 + 上传文档 + 聊天全链路冒烟
```

---

## 六、Kustomize 常用命令

```bash
# 渲染 YAML 不 apply（调试）
kubectl kustomize k8s/overlays/dev  > /tmp/dev-all.yaml
kubectl kustomize k8s/overlays/prod > /tmp/prod-all.yaml

# 一键删除整个环境（Dev 收尾）
kubectl delete -k k8s/overlays/dev
```

---

## 七、常见故障排查

| 现象 | 可能原因 | 处理 |
|------|---------|------|
| Backend Pod CrashLoopBackOff | init 容器连不上 MySQL/Redis | 检查 `base/backend/configmap.yaml` 地址是否通；加 kubectl logs -c wait-for-deps |
| Backend Readiness 一直 503 | Actuator 没启用 | 补 pom.xml 三个 starter + ConfigMap 中 MANAGEMENT_* 键 |
| WebSocket 426/握手失败 | Ingress/nginx 没传 Upgrade/Connection header | `ingress.yaml` annotations 中 `configuration-snippet` 和 `proxy-read-timeout` 已加；检查 ingress-nginx 版本是否支持 |
| 前端 502 Bad Gateway | 反代 upstream 名拼错 / backend Service 端口错 | frontend Pod 里 `curl -v http://paismart-backend.paismart.svc.cluster.local:8080/actuator/health/readiness` 检查 |
| HPA unknown / <unknown> | Metrics-server 没装 / Prometheus Adapter 没对接自定义指标 | 先 `kubectl top nodes/pods`；再装 k8s-prometheus-adapter 对接自定义 (Kafka lag / WS 连接数) |
| Rollout 中流量断 10s | maxUnavailable 没设成 0，或 readinessProbe 太严 | backend deployment strategy `maxUnavailable=0` 已配；确认 readiness 正常 |

---

## 八、下一步 P1/P2（K8s 落地后的完善项）

- [ ] ArgoCD / Flux GitOps：把上面 `kubectl apply -k` 改成 Git 自动同步 + App of Apps
- [ ] Argo Rollouts：蓝绿 / 金丝雀发布 + 自动回滚（Prometheus 成功率下降 1% → abort）
- [ ] KEDA：`ScaledObject` 对接 Kafka Topic Lag / Prometheus `chat_requests_per_second`，比默认 HPA 更贴合 AI 业务
- [ ] Vertical Pod Autoscaler (VPA)：跑 2 周后给 backend 推荐更合理的 requests/limits
- [ ] Pod Security Admission（PSA）enforce=restricted（prod namespace.yaml 已写，需验证所有 Pod 通过）
- [ ] Kyverno 策略：禁止 latest 镜像、禁止 no limits、要求 runAsNonRoot
- [ ] Velero / Kasten K10：集群资源 + PV 备份到 OSS，定期做 restore 演练
- [ ] Gatekeeper + OPA：组织策略（跨 NS Ingress、跨 NS Service 访问等）

---

## 九、给评审员的"Artifact 清单截图"

1. `kubectl get nodes -o wide --show-labels` — 展示 node pool / AZ 分布
2. `kubectl get pods -A -o wide | sort` — 展示各 NS 的 Pod 跑在哪个 pool 的 node 上
3. `kubectl top nodes` + `kubectl top pods -n paismart-prod` — 资源利用率
4. ArgoCD 应用列表页：paismart-dev / paismart-prod 显示 Synced & Healthy
5. Prometheus Targets：所有 backend/frontend Pods 显示 UP（绿色）
6. Grafana "K8s Cluster / Node / Pod Resources" Dashboard 截图
7. `kubectl get hpa -n paismart-prod` 显示 TARGETS/MINPODS/MAXPODS/REPLICAS
8. `kubectl get certificate -n paismart-prod` 显示 READY=True
9. ModSecurity 拦截日志（WAF 演示一次 SQLi 被拦截截图）
10. `kubectl get sealedsecrets -A` 显示已 Sealed 加密的 secret 列表，证明 Git 中无明文密钥

完成以上，"Physical Architecture + K8s Node Pool + Services Mapping + Artifacts"这一项就算全部闭环。
