# PaiSmart Kubernetes 集群规模设计（Architecture Sizing）

> 评审要问的：多少控制平面节点？多少 Worker？几个 Node Pool / Work Group？每个 Pool 跑什么服务？

本设计目标：**PaiSmart 生产上线 5 万 DAU 以内 / 峰值并发 500 用户聊天**。超规模再按比例水平扩展。

---

## 一、总体部署视图

**云厂商**：阿里云（国内默认）/ AWS（海外）。下文以阿里云 ACK（托管 K8s）为例，其他云同构。

**区域 & 可用区**：
- 主 Region：华东 1（杭州）
- 跨 3 个可用区 (AZ)：`cn-hangzhou-h / i / j`（满足 RDS/Redis/ES/Kafka 多 AZ 高可用要求）

---

## 二、集群节点规模

### 2.1 Control Plane（Infra / Master 节点）

ACK/EKS/GKE 均提供**托管控制平面**（用户看不到 master 节点），这里给出自建/非托管的参考配置：

| 角色 | 节点数 | 规格（阿里云） | vCPU | Mem(GiB) | 运行组件 |
|------|--------|---------------|------|----------|----------|
| etcd | **3（奇数强一致要求）** | ecs.c7.2xlarge | 8 | 16 | etcd 数据盘 200G SSD 云盘（PL1） |
| Control Plane (kube-apiserver/scheduler/controller-manager) | **3** | ecs.c7.2xlarge | 8 | 16 | kube-apiserver、kube-scheduler、kube-controller-manager、cloud-controller-manager |
| Load Balancer（公网 SLB/ALB） | HA 主备 | SLB 性能保障型 slb.s2.small | - | - | 80/443 入口，绑定 Ingress Nginx Service |

如果使用**托管版 ACK Pro**：只需关注 Worker Node，Control Plane 云厂商保证 SLA（ACK Pro SLA=99.95%）。

---

### 2.2 Worker Node（按 Node Pool / Work Group 拆分）

| Node Pool 名称 | 作用 | 节点数 | 单节点规格（ACK） | vCPU | Mem(GiB) | 本地盘 | Taints / Tolerations | 运行的主要 Pod 服务 |
|---------------|------|--------|-------------------|------|----------|--------|---------------------|--------------------|
| **`system-pool`** | 运行平台组件，不跑业务 | **2** (最小) → **3** (生产HA) | ecs.c7.xlarge | 4 | 8 | 40G ESSD | `dedicated=system:NoSchedule` | • Ingress-Nginx Controller (2 副本)<br>• cert-manager (3 副本)<br>• Prometheus Server + Alertmanager<br>• Grafana<br>• Loki / OTel Collector<br>• Sealed-Secrets Controller<br>• Reloader (ConfigMap/Secret 滚动刷新)<br>• metrics-server / kube-state-metrics<br>• (可选) ArgoCD |
| **`app-pool`** | 运行前后端业务（核心池） | **4**（起步，配合 HPA 水平扩到 8~12） | ecs.g7.2xlarge（计算通用型 + 足够内存跑 JVM） | 8 | 32 | 100G ESSD | `dedicated=app:NoSchedule` | • Backend Pod：2~10 (HPA，平均 4 个，每 Pod 4Gi/2vCPU)<br>• Frontend Pod：2~8 (HPA，平均 3 个)<br>合计≈**7 个 Pod**，4 节点每节点承载 2~3 个，跨 3 AZ |
| **`data-pool`**（可选 - 若你不想用云托管中间件） | 跑有状态中间件 Operator | **6**（3 Kafka + 3 ES 各自 StatefulSet，跨 3 AZ） | ecs.g7.4xlarge + 数据盘 | 16 | 64 | 2×1T ESSD PL0 + 本地 NVMe | `dedicated=data:NoSchedule` + topology.kubernetes.io/zone spread | • Strimzi Kafka Broker × 3<br>• Elasticsearch (ECK) Data × 3 / Master × 3 / Kibana × 1<br>• MinIO Tenant (4 节点纠删码)<br>⚠️ **生产强烈不建议**，直接用云托管下文推荐 |
| **`monitoring-pool`**（可选，分离大存储的监控） | 长期指标/日志/Trace | **2** | ecs.g7.2xlarge | 8 | 32 | 2T ESSD | `dedicated=monitoring:NoSchedule` | • VictoriaMetrics / Thanos (长期 Prometheus)<br>• Elasticsearch (日志专用，可选) |

### 2.3 生产推荐起步（极简 + 可扩展）

| Pool | 节点 | 说明 |
|------|------|------|
| system-pool | **3** × ecs.c7.xlarge | 3 AZ 每 AZ 1 个 |
| app-pool | **4** × ecs.g7.2xlarge | 3 AZ 里 h / i 区各 2，j 区 0（HPA 扩 pod 时自动补 j），保证跨 2 AZ；有预算再 6 节点均衡 |
| data-pool | **0**（用云托管，见下方 "中间件选型" 文档） | 降低运维负担 |
| **总计** | **7 台 Worker** + 3 Control Plane（托管） | 生产起步成本可控 |

---

## 三、每个 Work Group 部署的服务映射表（评审想看的 "Work Group Running Which Services"）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              system-pool (3 节点, AZ h/i/j)                   │
│                                                                              │
│  ┌───────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐   │
│  │ Ingress-Nginx │ │ cert-manager │ │ Prometheus   │ │ Grafana / Loki   │   │
│  │ (2 replicas)  │ │   (3)        │ │   +AlertMgr  │ │   / OTel Coll.   │   │
│  └───────────────┘ └──────────────┘ └──────────────┘ └──────────────────┘   │
│  ┌───────────────┐ ┌──────────────┐ ┌────────────────────┐                  │
│  │ SealedSecret  │ │ metrics-server│ │ (可选) ArgoCD      │                  │
│  │ Controller    │ │ kube-state-m. │ │ (可选) Reloader    │                  │
│  └───────────────┘ └──────────────┘ └────────────────────┘                  │
└──────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│                               app-pool (4 节点, AZ h/i)                      │
│                                                                              │
│  ┌─────────────────────────────────┐   ┌──────────────────────────────────┐ │
│  │   paismart-backend (HPA 2~10)   │   │  paismart-frontend (HPA 2~8)     │ │
│  │   - WebFlux + JWT + RAG Chat    │   │  - Nginx + SPA                   │ │
│  │   - 连接 MySQL/Redis/ES/Kafka   │   │  - 反代 /api /ws 到 backend      │ │
│  │   - Actuator Prometheus 端点    │   │  - gzip/brotli 预压缩            │ │
│  └─────────────────────────────────┘   └──────────────────────────────────┘ │
│           │ 直接反代 / Internal LB            ↑ Ingress 转发                 │
└───────────┼──────────────────────────────────┼──────────────────────────────┘
            │ VPC PrivateLink / 内网 DNS        │
            ▼                                  │
┌──────────────────────────────────────────────────────────────────────────────┐
│                    Cloud MANAGED Middleware (非 K8, 不需 Node Pool)          │
│                                                                              │
│  阿里云 RDS MySQL 8.0 (高可用版 2 节点 跨 AZ)         8C32G × 2 + 只读 × 1  │
│  阿里云 Tair / Redis 7.0 (集群版 3 分片 2 副本)        读写分离               │
│  阿里云 Elasticsearch (8.10, 3 数据 + 3 专用主节点)   热盘 + 冷盘分层存储    │
│  阿里云消息队列 Kafka (标准版 3 Broker, 3 副本)        消息保留 7d           │
│  阿里云 OSS 替代 MinIO（生命周期 + 版本控制 + WORM）   存储上传文件         │
│  阿里云 OCR / VPC Endpoint                         内部调用 OCR API         │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 四、存储规划

| 组件 | 存储类（StorageClass） | 容量起步 | 备份策略 |
|------|-----------------------|---------|---------|
| Prometheus | `alicloud-disk-essd-pl1` (性能级 1) | 500G × 2 PV (双副本冗余) | 15d 本地 + 每日快照到 OSS |
| Grafana SQLite (推荐改 PostgreSQL) | `alicloud-disk-efficiency` | 50G | 每日快照 |
| Loki / Tempo | 对象存储 OSS S3 Gateway | 按日志量 1T+/月 | 生命周期归档到冷存储 |
| (如果自建 ES on K8) ECK Data 节点 | Local NVMe / `alicloud-disk-essd-pl0` × 每个节点 1T | 3T | 自动快照 + 跨区域复制 |
| (如果自建 MinIO on K8) | 纠删码 4 节点 `alicloud-disk-essd` | 每节点 2T = 4T 可用 | mc mirror 到 OSS |

---

## 五、网络与安全分区（简化版，对应评审"非 K8 要给 VNet/Subnet/CIDR"）

虽然是 K8s，云厂商底层仍在 VPC/VSwitch 里，必须规划好：

| VPC CIDR | `10.0.0.0/16` | 华北2（北京）/华东1（杭州）二选一 |
|---------|---------------|---------------------------------|
| VSwitch-AZ-h (app-public) | `10.0.1.0/24` | 放 SLB + Bastion 堡垒机 + NAT Gateway |
| VSwitch-AZ-h (app- worker) | `10.0.11.0/24` | app-pool Worker ENI 主网卡 |
| VSwitch-AZ-i (app-worker) | `10.0.12.0/24` | app-pool Worker ENI |
| VSwitch-AZ-j (app-worker) | `10.0.13.0/24` | app-pool Worker ENI |
| VSwitch-AZ-h (data-middleware) | `10.0.21.0/24` | RDS / Redis / ES / Kafka / OSS Endpoint |
| VSwitch-AZ-i (data-middleware) | `10.0.22.0/24` | 同上，多 AZ 高可用 |
| VSwitch-AZ-j (data-middleware) | `10.0.23.0/24` | 同上 |
| VSwitch-mgmt | `10.0.99.0/24` | Prometheus 远程采集 + VPN 拨入 + Jump Server |

DNS：
- 集群内 Service：`*.svc.cluster.local`（K8s CoreDNS）
- 云托管中间件：PrivateZone 私网解析：`mysql-vpc.paicoding.private` → RDS VIP
- 公网：`smart.paicoding.com` → WAF → SLB → Ingress Nginx Pod IPs
- 证书：cert-manager + Let's Encrypt 自动化签发 / 国密证书按需

---

## 六、Pod 数量 & 资源占用汇总（Prod 起步 + HPA 上限）

| Deployment | Replicas 起始 | HPA 最大 | 每 Pod requests (CPU/ Mem) | 起始占用 CPU / Mem | 最大占用 CPU / Mem |
|-----------|---------------|---------|--------------------------|--------------------|--------------------|
| Backend | 3 | 10 | 2 / 4Gi | 6 / 12Gi | 20 / 40Gi |
| Frontend | 3 | 8 | 500m / 512Mi | 1.5 / 1.5Gi | 4 / 4Gi |
| **合计** | 6 | 18 | - | 7.5 CPU / 13.5Gi | 24 CPU / 44Gi |

加上 system-pool 组件（Ingress Nginx 2、Prom 2、Grafana 1、cert-manager 3、Loki 1、OTel 1…）≈ 额外 8 CPU / 16Gi。

对应 **app-pool = 4 × (8C/32G) = 32C/128G**，起步利用率 ≈ `(7.5/32)=23%`，给 HPA 充足弹性空间。

---

## 七、自动扩缩容 & 成本优化

1. **HPA**：按 CPU 70% / Memory 75% 扩；WS 聊天高峰还可对接 **KEDA Kafka Topic Lag Scaler**（消费延迟 > 1000 条时多加 backend Pod）
2. **Cluster Autoscaler（CA）**：app-pool 配置 CA，当 Pod 因资源不足 Pending 时自动增加 Worker 节点（单节点 8C32G），最多加到 12 节点
3. **Spot / 抢占式实例**：非核心 Dev/Staging 环境用抢占式实例（便宜 80%），Prod 全用按量 + 1 年预留实例（RI 或 SUP）省 30~50%
4. **CronHPA**：凌晨 2~8 点自动把 backend minReplicas 降到 1

---

## 八、高可用 & 容灾

- 控制平面：托管 ACK Pro（SLA 99.95%）
- 应用 Pod：PodAntiAffinity + topologySpreadConstraints（跨节点 + 跨 AZ）
- PDB：前后端 `minAvailable=2`，保证节点维护 / K8s 版本升级时业务不中断
- 数据：RDS 高可用 + 只读；ES 副本 1；Kafka 副本 3，min.insync.replicas=2
- **灾难恢复（DR）**：定时 OSS 跨区域复制 + RDS 跨地域备份（RPO 1h，RTO 4h）
- **Chaos Mesh**：建议部署定期演练 Pod-Kill、AZ-Down、Network-Partition

---

## 九、上线 Checklist（评审需要 Artifact 时截图这里）

- [ ] ACK Pro 集群创建完成，3 AZ 均有 Worker
- [ ] 命名空间 paismart-prod / monitoring / ingress-nginx / cert-manager 建完
- [ ] Ingress-Nginx Controller：`kubectl get svc -n ingress-nginx` 拿到公网 SLB IP
- [ ] 域名 DNS 解析指向 SLB；cert-manager ClusterIssuer 签发成功证书（`kubectl get cert -n paismart-prod` Ready=True）
- [ ] Sealed-Secrets Controller 工作正常，`kubeseal` 解密钥对匹配
- [ ] Prometheus Targets `up=1`：backend、frontend、kube-state-metrics、node-exporter、cAdvisor
- [ ] Grafana 导入 Dashboard：K8s Cluster / Node / POD / PaiSmart Business（在后面"可观测性"条目里补 JSON）
- [ ] Alertmanager 飞书 Webhook 告警通道测试成功
- [ ] OTel → Jaeger / Tempo 能看到一次 RAG 聊天完整 trace
- [ ] 蓝绿/金丝雀发布流程（Argo Rollouts or Flagger）演练通过
