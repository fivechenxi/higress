<!--
  ~ Copyright 2026 alibaba
  ~
  ~ Licensed under the Apache License, Version 2.0 (the "License");
  ~ you may not use this file except in compliance with the License.
  ~ You may obtain a copy of the License at
  ~
  ~     http://www.apache.org/licenses/LICENSE-2.0
  ~
  ~ Unless required by applicable law or agreed to in writing, software
  ~ distributed under the License is distributed on an "AS IS" BASIS,
  ~ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  ~ See the License for the specific language governing permissions and
  ~ limitations under the License.
-->

# TokenVolt Higress 可观测性指标明细

本文档是指标从产生、采集、派生，到 Grafana 展示和告警的完整对照表。
当前方案有意排除 ACK 控制面和通用 Kubernetes 监控，只保留应用、Envoy、
Terway/Cilium 以及最低限度的 Higress Controller 指标。

## 标签与聚合边界

| 标签 | 含义 | 是否远程存储 |
| --- | --- | --- |
| `ai_route` | Higress 路由；在具备独立公共模型标签前，作为公共模型的稳定分组 | 是 |
| `ai_model` | 请求完成时优先使用厂商响应中的模型，否则回退到请求模型 | 是 |
| `ai_provider` | 从 `tokenvolt-<provider>.dns` 归一化得到的厂商 ID；未命中规则时保留原始集群名 | 是 |
| `ai_cluster` | Envoy 原始上游集群，用于故障排查 | 是 |
| `ai_consumer` | 客户或 API Key 维度 | 仅在 ACK 内的一小时临时 Prometheus 中保留，用于避免序列碰撞；不远程写入 |
| `pod`、`namespace` | Gateway 副本身份 | 仅在容量分析需要时保留 |

这里必须区分三类数据：逐请求用量事实源是 SLS；PostgreSQL 保存租户和 API Key
元数据，以及从 SLS 生成的 `usage_recent`、`usage_hourly` 分钟/小时汇总；Prometheus
远程 Prometheus 不保存租户或 API Key 维度。价格和实际金额由 TokenVolt 的版本化价格目录与用量
账本计算；Prometheus 只保存流量、Token 数量和服务质量信号。

ACK 内的一小时临时 Prometheus 以 `ai_consumer` 区分原始 AI 序列，避免不同 API Key
删除标签后发生碰撞；Recording Rules 跨 API Key 和 Pod 求和，生成
`route × model × provider` 的常用查询序列。只有聚合后的 AI 序列会写入 ARMS，
所有仍带 `ai_consumer` 的原始序列会在远程写入前丢弃。
因此可以继续聚合为网关整体、单模型、单厂商，也可以直接下钻到“模型 × 厂商”。
它不是租户维度；逐租户和 API Key 查询仍以 SLS 用量事实为准。

模型质量的区间统计使用不含 `ai_consumer` 的远端安全累计序列
`tokenvolt:ai_{requests,failures,input_tokens,output_tokens}_total` 和
`tokenvolt:ai_{ttft,tpot}_milliseconds_bucket`。这避免 Collector 或 Grafana 重启后
最近 15 分钟归零，同时保留可正确计算 P50/P90 的聚合直方图。

## AI 服务指标

除“可用条件”中特别说明的情况外，下列指标均会被采集并展示在随 Helm 提供的
Grafana 大盘中。

| 指标 | 原始指标 | 派生指标 | 告警 | 可用条件与口径 |
| --- | --- | --- | --- | --- |
| 逻辑 RPM | `...llm_request_count` | `tokenvolt:ai_rpm:rate5m` | 用作告警最小样本量限制 | 每个进入网关的逻辑请求计数一次 |
| 客户可见错误率 | `...llm_failure_count`、`...llm_request_count` | 由 `tokenvolt:ai_*_per_second:rate5m` 计算 | 警告 2%，严重 15% | 包含返回给客户的 429 和被中断的流；这是网关结果口径，不用于评价厂商质量 |
| 中断率 | `...llm_aborted_count`、`...llm_request_count` | 由已记录的速率计算 | 警告 1%，严重 5% | 包含本 fork 插件记录的响应中断 |
| 处理中请求数 | `...llm_inflight_request` | `tokenvolt:ai_inflight_requests` | 仅大盘展示 | 可按路由、响应模型和厂商拆分 |
| TTFT P50/P90 | 固定 TTFT 累积计数器，采集时转换为 `higress_ai_ttft_milliseconds_bucket` | `tokenvolt:ai_ttft_milliseconds:p{50,90}_rate5m` | P90 超过 25 秒警告、50 秒严重 | 当前是收到首个上游数据块的时间，并非首个有语义内容的 Token |
| TPOT P50/P90 | 固定 TPOT 累积计数器，采集时转换为 `higress_ai_tpot_milliseconds_bucket` | `tokenvolt:ai_tpot_milliseconds:p{50,90}_rate5m` | P90 超过 50 毫秒警告、70 毫秒严重 | 单次请求平均值 `(总耗时-TTFT)/(输出 Token-1)`；依赖最终 usage |
| 平均服务耗时 | `...llm_service_duration`、`...llm_duration_count` | `tokenvolt:ai_service_duration_milliseconds:avg_rate5m` | 仅大盘展示 | 请求平均值，不是分位数 |
| 输入、输出、总 TPM | `...input_token`、`...output_token`、`...total_token` | `tokenvolt:ai_{input,output,total}_tpm:rate5m` | 仅大盘展示 | 依赖厂商返回最终 usage 字段 |
| 缓存命中 TPM | `...cache_hit_token` | `tokenvolt:ai_cache_hit_tpm:rate5m` | 仅大盘展示 | 支持 OpenAI、Anthropic 和 Gemini 的缓存读取字段 |
| 缓存 Token 命中率 | 缓存命中 Token/输入 Token 计数器 | `tokenvolt:ai_cache_token_hit_ratio:rate5m` | 仅大盘展示 | 分母为厂商上报的输入 Token 数 |
| 缓存请求命中率 | 命中请求/上报缓存信息请求计数器 | `tokenvolt:ai_cache_request_hit_ratio:rate5m` | 仅大盘展示 | 不支持缓存信息的厂商不会被当成未命中 |
| 缓存信息上报覆盖率 | 上报缓存信息请求/总请求计数器 | `tokenvolt:ai_cache_reporting_ratio:rate5m` | 仅大盘展示 | 仅表示缓存字段覆盖率，不等于完整 usage 覆盖率 |

## 厂商与 Gateway 指标

| 指标 | 来源或派生指标 | 告警 | 用途 |
| --- | --- | --- | --- |
| 实际上游调用 RPM | `envoy_cluster_upstream_rq` → `tokenvolt:provider_attempt_rpm:rate5m` | 仅大盘展示 | 包含重试和降级调用，因此可能高于逻辑 RPM |
| 调用放大倍数 | 厂商调用 RPM/逻辑 RPM | 仅大盘展示 | 发现重试或降级造成的隐性成本和压力 |
| 厂商 HTTP 429 | `tokenvolt:provider_429_rpm:rate5m` | 持续 5 分钟非零 | 厂商配额或限速压力 |
| 厂商 HTTP 5xx | `tokenvolt:provider_5xx_rpm:rate5m` | 持续 5 分钟非零 | 厂商侧故障信号 |
| 模型 × 厂商成功率 | `tokenvolt:provider_model_success_ratio:rate5m` | 低于 99% 且样本量足够 | 成功响应/总请求；4xx 和 5xx 均不进入分子 |
| 模型整体成功率 | `tokenvolt:model_success_ratio:rate5m` | 低于 99% 且样本量足够 | 汇总该模型全部厂商，口径与模型 × 厂商一致 |
| 模型 × 厂商及模型整体 TTFT | `tokenvolt:{provider_model,model}_ttft_milliseconds:p90_rate5m` | P90 超过 25 秒警告、50 秒严重 | 同时发现单一厂商退化与整个模型池退化 |
| 模型 × 厂商及模型整体 TPOT | `tokenvolt:{provider_model,model}_tpot_milliseconds:p90_rate5m` | P90 超过 50 毫秒警告、70 毫秒严重 | 同时发现单一厂商退化与整个模型池退化 |
| 模型 × 厂商综合质量 | 成功率、TTFT P90、TPOT P90 | 任一指标越线且 5 分钟至少 20 请求，持续 5 分钟 | 飞书直接携带模型和厂商，可由运维下钻后手工调整权重 |
| 模型 × 厂商实际 RPM/TPM | `tokenvolt:provider_model_{logical_rpm,total_tpm}:rate5m` | 暂不做容量告警 | 当前厂商主要按授信额度管理，未配置合同 RPM/TPM 分母 |
| 每 Pod 及总活跃流 | `envoy_http_downstream_rq_active` | 达到最大副本且超过每 Pod 225 条的等效容量时严重告警 | 与 Gateway HPA 使用同一个受控指标 |
| 可采集的 Gateway 副本数 | `up{job="higress-gateway"}` | 低于配置的最小副本数 | 判断可用性及服务发现是否正常 |
| 下游和上游连接数 | Envoy 活跃连接 Gauge | 仅大盘展示 | 长流连接和连接池分析 |
| 下游/上游 HTTP 总耗时 P50/P90 | Envoy `*_rq_time_bucket` | 下游 P90 暂定超过 120 秒警告 | 单位毫秒；包含流式请求的完整存续时间，不替代模型 TTFT/TPOT |
| 上游等待请求 | Envoy pending request Gauge | 持续 2 分钟非零 | 上游连接池或厂商容量压力 |
| 连接溢出 | Envoy Listener/Cluster overflow Counter | 任意增长 | 连接或资源达到硬限制 |
| 模型流中断/厂商请求重置 | AI 流中断 Counter；仅 `tokenvolt-<provider>.dns` 上游 reset Counter | 合计 1 分钟内超过 3 次并持续 1 分钟 | 排除 Grafana、浏览器取消请求以及其他非模型路由的下游 reset |
| Envoy 内存 | `envoy_server_memory_allocated` | 当前 1 GiB 限额下达到 768 MiB | 不依赖 cAdvisor 的数据面内存压力指标 |

## 网络、Controller 与采集链路

| 范围 | 指标 | 告警 |
| --- | --- | --- |
| Terway/Cilium | CT Map 压力、Map 更新失败 | 70% 警告、90% 严重；任何 Map 更新失败均告警 |
| Higress Controller | xDS、过期 Nonce、Endpoint 未就绪、EDS 无实例、推送与收敛直方图 | Endpoint 未就绪；EDS 发布空实例 |
| Prometheus Adapter | Adapter `up`、请求数和进程指标 | 不可用 2 分钟；Gateway HPA 没有 CPU 兜底 |
| HPA 边缘状态 | 当前/目标 Metric、当前/期望/最大副本数 | Metric 达目标 80% 为提示；等待缩容为提示；副本达上限 80% 为警告 |
| HPA 状态 | 当前/期望/最小/最大副本，当前/目标指标，Scaling 条件 | 无法伸缩；期望副本持续 10 分钟未收敛 |
| HPA 事件 | ACK 官方 K8s Event Center（SLS） | 保存扩缩容决策、取指标失败、达到上下限和调度失败等事件 |
| TokenVolt 控制面 | `up`、数据库就绪、业务查询、凭据发布积压/失败 | 端点不可达或数据库/查询异常为严重；凭据发布积压/失败为警告 |
| TokenVolt 用量管线 | 最近成功水位、失败/不完整任务、48 小时未知 Token 记录 | 两小时无成功或启动后 90 分钟从未成功为严重；任务失败及未知 Token 积压为警告 |
| Collector | Remote Write 失败、丢弃、积压、重试、最新时间戳，规则失败、序列数、进程 CPU/内存 | 写入失败或积压；规则计算失败 |
| Collector 消失 | ARMS 侧 `absent(up{job="higress-metrics-collector"})` | 独立严重告警，不依赖 Collector 自己存活 |

集群内 Prometheus 负责计算详细且基数受控的规则，并将生成的 `ALERTS` 序列
Remote Write 到 ARMS，同时把 firing/resolved 事件发送到集群内 Alertmanager。
Alertmanager 按告警名、组件、模型、厂商和 HPA 分组，经小型转换器发送到独立飞书
告警群。严重告警使用 30 分钟重复周期；飞书 relay 默认双副本，并可配置第二个
升级 Webhook。Webhook 只存在本地 `terraform.tfvars`、敏感 State 和 Kubernetes
Secret，不进入 Helm ConfigMap 或 Git。ARMS 仍保留远端查询与独立检测 Collector
消失的能力。

### 两条基线规则的已知陷阱（2026-09-18 首次部署后实测）

- `node_filesystem_readonly` 反映的是**采集侧看到的挂载标志**，不是磁盘本身的健康。
  node-exporter 把宿主根 `hostPath: /` 以只读方式挂到 `/host/root`，`--path.rootfs`
  又把该前缀从 `mountpoint` 标签里剥掉，于是**我们自己的只读绑定**会被读成"宿主根盘
  只读"，两个节点各产生 3 条常驻 critical。因此该规则按**设备**判断：只有同一块设备的
  所有挂载点都只读才告警。有意整盘只读的磁盘要加进
  `--collector.filesystem.mount-points-exclude`。
- 托管 ACK 的 apiserver 证书 SAN 覆盖 Service 地址与部分 master IP，但**不覆盖
  endpoints 角色发现的 master ENI 地址**，直接抓 `https://<eni>:6443/metrics` 必然
  `x509` 失败。该 job 因此必须 `insecure_skip_verify: true`；否则
  `ACKAPIServerUnavailable` 永久 firing，而 `ACKAPIServerErrorRatioHigh` 因为
  `apiserver_request_total` 一直没有数据而**静默失效**。

## 明确不采集的内容

- 以 60 秒白名单采集 Pod/Deployment、Node、APIServer 和 CoreDNS；不采集托管
  ETCD，也不采集 kubelet/cAdvisor 的容器级指标。
- 不使用 Linux 原生 `nf_conntrack` 作为判断依据。ACK 使用 Terway DataPath V2，
  对应容量指标是 Cilium eBPF CT Map 压力。
- 不把租户、API Key、提示词、响应内容、请求 ID、任意 Path 或时间戳放入指标标签。
- Grafana 只安装声明式大盘和数据源，不运行通用 Dashboard Sidecar；Pod 重建时从
  Git/ConfigMap 恢复，不把页面手工修改作为正式配置。

## 仍然存在的缺口

| 缺口 | 当前替代方案 | 后续工作 |
| --- | --- | --- |
| 成功请求未返回任何厂商 usage 的比例 | 使用 SLS 的 `usage_status`；缓存覆盖率只能反映缓存字段 | 在 `ai-statistics` 中增加低基数的 `usage_reported_request_count` |
| 严格的流式请求开始/完成比例 | 使用中断、失败指标及 SLS 的 `response_completed` | 增加低基数的流开始和流完成 Counter |
| 首个有语义内容的 Token 延迟 | 使用压测客户端；现有 TTFT 是首个上游数据块 | 插件按协议识别 SSE 中的实际内容 |
| 真实逐 Token 延迟分布 | 当前 TPOT 是单请求平均值 | 确有运营价值时，再增加客户端或插件 Token 事件直方图 |
| 不受厂商响应影响的稳定公共模型标签 | 暂时使用 `ai_route`，`ai_model` 保留响应模型语义 | 增加可信且低基数的公共模型标签 |
| Pod CPU、容器内存历史 | 压测时使用 `kubectl top`；HPA 自身状态和事件已经持久化 | 不打开全量 kubelet/cAdvisor |
| 厂商集群标签归一化 | Collector 正则并保留原始 `ai_cluster` | 启动环境后用一次真实 Scrape 验证 |
| Envoy 上游调用指标的响应码标签 | 已按真实 Scrape 修正为 `cluster_name`、`response_code_class`；精确 429 使用固定指标 `envoy_cluster_upstream_rq_429` | 已验证，禁止使用不存在的 `envoy_cluster_name`/`envoy_response_code` 标签 |

前两个是目前 Prometheus 中真正缺少的基础 AI 记账质量指标。它们需要发布新的
Wasm 产物，应作为独立的数据面改动，通过 Mock 和真实流式请求验证。

模型 × 厂商 429 使用本 fork 新增的 `llm_rate_limited_count`；所有 429 统一作为
厂商响应事实展示和告警，不再依赖未配置的厂商合同 RPM/TPM 做预期性分类。

每条 HTTP 429 请求同时在 SLS `ai_log` 中写入
`provider_rate_limit_event=true` 和
`rate_limit_evaluation=provider_model_capacity_window`。429 告警发生后，可按告警的
`ai_model`、`ai_provider` 和时间范围使用以下 SLS SQL 提取请求证据：

```sql
* | SELECT start_time, request_id, "ai_log.upstream_request_id",
           "ai_log.model", upstream_cluster, response_code, response_flags
    WHERE "ai_log.provider_rate_limit_event" = 'true'
    ORDER BY start_time ASC
```

该查询只读取请求标识和诊断元数据，不读取 API Key、Prompt 或模型回答。

## Grafana 使用方式

`higress-ack-ops` 在运行阶段部署单副本 Grafana，通过 Higress 的 `/grafana/`
子路由访问，并自动加载四个独立页面：模型质量、实时运行、请求明细和基础监控。启用控制面/模型
API 公网分流时，该路由自动挂到进入
Higress 的模型 API 域名（当前为 `api.tokenvolt.net/grafana/`），不会挂到绕过
Higress、直达 TokenVolt 控制面的 `ack.tokenvolt.net`。
指标数据源读取 ACK 托管 Prometheus/ARMS 的内网查询 API，因此 Collector 或 Grafana
重启不会清空大盘历史。查询 API Token 由 Terraform 写入 Kubernetes Secret，Grafana
通过 `Authorization` Header 使用，不写入 ConfigMap 或 Git。请求明细通过阿里云官方
SLS 插件读取 `model-access`，使用独立 RAM 用户，
权限只包含指定 Logstore 查询以及插件健康检查所需的 Project 元数据读取。

### 大盘信息架构

“模型质量”页按 OpenRouter 的模型页思路组织，而不是把所有基础设施指标混成一组：

1. 只选择模型，不暴露属于网关实现细节的 route 筛选。顶部展示该模型经过整个网关
   后的成功率、TTFT P50/P90、TPOT P50/P90 和样本量；这是客户实际感受到的整体质量。
2. 紧接着用“模型 × 厂商”表比较成功率、TTFT、TPOT、RPM 和 TPM。表格可按任意
   列排序；不额外制造一个权重不透明的综合分数。
3. “实时运行”页把同一模型 × 厂商的 RPM、TPM、成功率、TTFT 和 TPOT 合并为一行；
   RPM、TPM、TTFT P90、TPOT P90 使用四张独立趋势图，避免不同单位和数量级互相压扁。
4. “基础监控”页单独承载 Envoy、Terway/Cilium、HPA、采集器和 Controller；顶部
   先展示活跃请求、Inbound/Outbound 连接、上游 pending/熔断压力，随后展示 Envoy
   下游/上游 HTTP 总耗时 P50/P90、下游异常、上游异常以及 HTTP/2/高内存保护事件。
   admin、stats、readiness、xDS 和 Prometheus 内部流量在采集时即被过滤，不参与
   厂商质量排名，也不污染数据面连接数。
5. “请求明细”页直接查询 SLS，包含最近请求、TTFT Top 100、TPOT Top 100、5xx 和
   429 证据五张表，可按模型、上游表达式、租户和请求 ID 筛选。所有查询统一排除
   空模型、`dashboard-mock` 以及非 `tokenvolt-<provider>.dns` 的内部上游。

模型和厂商筛选目录不是写死在大盘里的枚举。限定范围的 kube-state-metrics 从
`tokenvolt-system` Ingress 注解读取当前已发布 CR，生成
`tokenvolt:configured_provider_model:info`；模型质量和实时运行页面都以它作为当前
数据面目录。数据库中尚未发布或已停用的组合不会出现在实时目录中。

三个页面都不展示 P99。当前样本量不足以让 P99 稳定，P50 表示常态，P90 用于慢请求
和服务质量边缘判断。

价格尚未进入 Prometheus；后续厂商表需要从版本化价格目录补充输入、输出和缓存
单价。价格是配置事实，不能从流量指标推断。

### 请求明细边界

逐请求明细来自 SLS `model-access`，不进入 Prometheus。Grafana 固定安装阿里云官方
SLS 数据源插件 2.39.2，并使用只允许读取该 Logstore 的身份内嵌以下表：

- 最近请求，按时间倒序；
- TTFT 和 TPOT 最慢的 Top 100 请求；
- HTTP 5xx 和所有 429 的请求证据。

每行只展示时间、网关请求 ID、厂商请求 ID、模型、上游集群、状态码、TTFT、TPOT
和 Token 数，不展示 API Key、Prompt 或模型回答。TPOT 由单请求字段计算：
`(llm_service_duration - llm_first_token_duration) / (output_token - 1)`，仅对
`output_token > 1` 且 usage 完整的流式请求有效。

所有 429 请求都可通过 `provider_rate_limit_event=true` 下钻，不再标注
expected/unexpected。

客户限额指标由 Collector Pod 内的轻量 exporter 读取 Helm 管理的三个 WasmPlugin
CR，并查询同一 Redis 中的实际计数。租户及租户 × 模型 RPM 达到配置值 90% 时告警；
试用 Key 到期或累计 Token 用完、正式租户周期 Token 用完时分别告警。租户和
consumer 标签只留在集群内的一小时 Prometheus 和飞书告警中，remote write 会丢弃。

管理员密码由 OpenTofu 生成，保存在 `higress-grafana-admin` Secret 和敏感 State
中，不写入 Git。使用 `tofu output -json grafana_admin_credentials` 单独读取 URL、
用户名和密码。Grafana 使用临时 SQLite；大盘由 Git/ConfigMap 声明式恢复，页面中
手工创建的用户、数据源或大盘在 Pod 重建后不保证保留。
