# 中间件选型：云托管 vs K8s Operator

PaiSmart 依赖 5 个有状态中间件 + OCR/AI API。**生产强烈推荐走"云托管 + VPC 内网访问"路线**，MySQL/Redis/ES/Kafka 自己运维的复杂度非常高（备份、故障切换、扩容、补丁、跨区域容灾）。下面给两条路的部署占位文档。

---

## 一、推荐方案：云托管（评审 Artifact 给控制台截图即可）

### 1.1 选型对照表

| 中间件 | 阿里云（国内） | AWS（海外） | 规格起步（5万DAU） |
|--------|---------------|-------------|-------------------|
| **主数据库 MySQL 8.0** | ADB PolarDB MySQL 版 (一写多读) / RDS 高可用版 | Amazon RDS for MySQL Multi-AZ | 8C / 32G，2 节点 HA，1×只读节点（报表/检索分流），存储 500G ESSD PL1 |
| **缓存 Redis 7** | 云数据库 Tair（企业内存版 集群） | Amazon ElastiCache for Redis (Cluster Mode, 3 shards, 2 replicas) | 3 分片 × 2 副本 = 6 节点，8G/分片 = 24G 总容量 |
| **Elasticsearch 8.10** | 阿里云 Elasticsearch 版 (兼容版或商业版) | Amazon OpenSearch Service | 3 专用主节点（2C 4G）+ 3 数据节点（8C 32G，热盘 1T ESSD），冷数据 Tier 到 OSS |
| **Kafka 3.x** | 阿里云消息队列 for Kafka 标准版 | Amazon MSK (Managed Streaming for Kafka) | 3 Broker / 3 副本 / 12 Partition 起步；消息保留 7 天 / 1T 存储 |
| **对象存储（原 MinIO）** | **阿里云 OSS**（标准存储 + 低频访问 + 归档，生命周期自动下沉） | Amazon S3 | 标准 - Infrequent Access - Glacier 三层；版本控制开启；WORM 合规保留；跨区域复制 |
| **LiteParse OCR** | 阿里云 OCR（RecognizeAllText 高精版，已在代码 `AliyunOcrService` 接入） | Amazon Textract | 直接用 PaaS，不用自己跑 |
| **AI Provider** | DeepSeek API + 豆包 Embedding（或自建 Ollama + vLLM 专有云部署） | Bedrock / OpenAI | 走 VPC Endpoint / PrivateLink 通道调用，不暴露公网 API Key |

### 1.2 连接方式

- **内网 VPC 访问**：所有中间件开通 VPC 内网 Endpoint，与 ACK 集群放在同一个 VPC 的 data-subnet，**完全不暴露公网**
- **私网 DNS**：PrivateZone 自定义域名（例 `mysql-vpc.paicoding.private`），解耦具体 VIP / Hostname，将来迁移不影响应用
- **网络 ACL / 白名单**：仅允许 app-pool Worker 的安全组访问中间件端口（MySQL 3306、Redis 6379、ES 9200、Kafka 9092/9093），禁止从公网访问

### 1.3 配置占位（让上面的 backend/configmap.yaml 生效）

把 `k8s/base/backend/configmap.yaml` 中的中间件地址替换成你的真实内网 DNS：

```
SPRING_DATASOURCE_URL=jdbc:mysql://rm-xxxx.mysql.rds.aliyuncs.com:3306/PaiSmart?...
SPRING_DATA_REDIS_HOST=r-xxxx.redis.rds.aliyuncs.com
SPRING_KAFKA_BOOTSTRAP_SERVERS=alikafka-xxxx-kafka-internal-vpc.cn-hangzhou.aliyuncs.com:9092,...
MINIO_ENDPOINT=http://oss-cn-hangzhou-internal.aliyuncs.com (或 S3 兼容 SDK 直接改)
ELASTICSEARCH_HOST=es-xxxx.elasticsearch.aliyuncs.com
```

### 1.4 评审 Artifact

给以下控制台页面的截图（脱敏后）：

- RDS 实例列表页：显示 "高可用版"、节点规格、存储空间、主备可用区
- Redis 集群拓扑页：显示分片 + 副本分布
- ES 集群：节点规格 + 磁盘大小 + 版本号
- Kafka Topic 列表：`file-processing-topic1` 的分区数=6、副本=3
- OSS Bucket：版本控制=ON、跨区域复制=OK、服务端加密=OSS-KMS

---

## 二、备选方案：K8s 内用 Operator（完全自托管，不推荐 Prod 但可以展示工程能力）

目录 `k8s/infrastructure/operators/` 给 Helm/Kustomize 部署各 Operator 的最小占位 YAML，**仅用于 Dev / Showcase**。

### 2.1 Operator 选型

| 中间件 | Operator 名称 | Helm Chart / YAML 入口 |
|--------|--------------|----------------------|
| Kafka | **Strimzi Kafka Operator** (CNCF) | `operators/kafka/kafka-cluster.yaml` (3 broker KRaft mode) |
| Elasticsearch | **ECK** (Elastic Cloud on Kubernetes, 官方) | `operators/elasticsearch/elasticsearch-cluster.yaml` |
| MinIO | **MinIO Operator + Tenant** (官方) | `operators/minio/minio-tenant.yaml` (4 server, EC:4) |
| MySQL | **Percona XtraDB Cluster Operator** 或 **Mydumper** 主从 | `operators/mysql/mysql-cluster.yaml` (3 node HA, async replica) |
| Redis | **Redis Operator (OT-CONTAINER-KIT)** 或 Bitnami Redis Cluster Helm | `operators/redis/redis-cluster.yaml` (6 node, 3 shards × 2) |
| PostgreSQL (可选代替 MySQL) | **CloudNativePG** (CNCF) | - |

### 2.2 目录占位

```
k8s/infrastructure/
├── operators/
│   ├── README.md                    ← ✅ 本文件
│   ├── install-operators.sh         ← 一键安装 Operator 到 cluster
│   ├── kafka/
│   │   ├── strimzi-operator.yaml    ← Operator Subscription / HelmValues
│   │   └── kafka-cluster.yaml       ← Kafka CR: 3 broker + kraft + topics
│   ├── elasticsearch/
│   │   ├── eck-operator.yaml
│   │   └── elasticsearch-cluster.yaml  ← Elasticsearch CR: masters+nordata+kibana
│   ├── minio/
│   │   ├── minio-operator.yaml
│   │   └── minio-tenant.yaml           ← Tenant CR: 4 servers + 1 bucket
│   ├── mysql/
│   │   └── percona-xtradb-cluster.yaml
│   └── redis/
│       └── redis-cluster.yaml
├── monitoring/
│   ├── kube-prometheus-stack.yaml   ← Prometheus + Grafana + Alertmanager CR (Prom CRD)
│   ├── loki-stack.yaml              ← Loki (日志)
│   └── tempo.yaml                   ← Tempo (Trace)
└── security/
    ├── sealed-secrets-controller.yaml
    ├── cert-manager-clusterissuer.yaml   ← Let's Encrypt staging + prod
    └── reloader.yaml                ← ConfigMap/Secret 变更滚动更新
```

### 2.3 安装流程（在上面 `install-operators.sh` 里体现）

```bash
#!/usr/bin/env bash
set -euo pipefail
# 1) CRDs + Operators (Helm 3)
helm repo add strimzi https://strimzi.io/charts/
helm repo add elastic https://helm.elastic.co
helm repo add minio-operator https://operator.min.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jetstack https://charts.jetstack.io
helm repo update

# 2) Install (namespace: middleware)
kubectl create namespace middleware --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace middleware --create-namespace --version 0.43.0
helm upgrade --install elastic-operator elastic/eck-operator \
  --namespace middleware --create-namespace --version 2.14.0
helm upgrade --install minio-operator minio-operator/tenant \
  --namespace middleware --create-namespace  # 参考最新官方文档修正 chart name

# 3) Prometheus / Grafana / Alertmanager + node-exporter + kube-state-metrics
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --version 65.2.0 \
  --set grafana.adminPassword=change-me \
  --set prometheus.prometheusSpec.serviceMonitorNamespaceSelector.matchLabels.release=kube-prometheus-stack \
  --set grafana.persistence.enabled=true --set grafana.persistence.size=20Gi

# 4) cert-manager
helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager \
  --create-namespace --version v1.16.1 --set installCRDs=true

# 5) 应用实例 CR (Strimzi Kafka CRD / ECK Elasticsearch CRD / MinIO Tenant CRD)
kubectl apply -k k8s/infrastructure/operators/
```

---

## 三、最终决策建议（写到评审文档里）

| 中间件 | 部署模式 | 理由 |
|--------|---------|------|
| PaiSmart Backend / Frontend | ✅ **K8s Deployment + HPA** | 无状态、水平扩缩方便，K8s 探针/滚动/PDB 优势明显 |
| MySQL / Redis / ES / Kafka | ✅ **云托管（PaaS）** | 生产需要强一致 / 故障自动切换 / 备份合规，自己运维成本远大于省下的钱 |
| 对象存储 (MinIO→OSS) | ✅ **云对象存储** | 11 个 9 耐久度，跨区域复制零运维 |
| 平台组件 (Ingress/Prom/Grafana/cert-manager/OTel) | ✅ **K8s 内 Helm 部署** | 业界标准做法 |

**评审时这样讲**："我们保持应用层完全容器化 + K8s 编排，享受其自动扩缩容、零宕机发布、声明式资源的优势；而把有状态、数据一致性要求高的中间件交给云厂商托管，这样把 SRE 的精力集中在 RAG 业务和可观测性上，不会半夜被叫起来修 Kafka 脑裂或 MySQL 主从断连。"
