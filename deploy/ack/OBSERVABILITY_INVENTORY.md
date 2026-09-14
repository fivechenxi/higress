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

## AI 服务指标

除“可用条件”中特别说明的情况外，下列指标均会被采集并展示在随 Helm 提供的
Grafana 大盘中。

| 指标 | 原始指标 | 派生指标 | 告警 | 可用条件与口径 |
| --- | --- | --- | --- | --- |
| 逻辑 RPM | `...llm_request_count` | `tokenvolt:ai_rpm:rate5m` | 用作告警最小样本量限制 | 每个进入网关的逻辑请求计数一次 |
| 客户可见错误率 | `...llm_failure_count`、`...llm_request_count` | 由 `tokenvolt:ai_*_per_second:rate5m` 计算 | 警告 5%，严重 15% | 包含返回给客户的 429 和被中断的流；这是网关结果口径，不用于评价厂商质量 |
| 中断率 | `...llm_aborted_count`、`...llm_request_count` | 由已记录的速率计算 | 警告 1%，严重 5% | 包含本 fork 插件记录的响应中断 |
| 处理中请求数 | `...llm_inflight_request` | `tokenvolt:ai_inflight_requests` | 仅大盘展示 | 可按路由、响应模型和厂商拆分 |
| TTFT P50/P90/P99 | 固定 TTFT 累积计数器，采集时转换为 `higress_ai_ttft_milliseconds_bucket` | `tokenvolt:ai_ttft_milliseconds:p{50,90,99}_rate5m` | P90 超过 1 秒 | 当前是收到首个上游数据块的时间，并非首个有语义内容的 Token |
| TPOT P50/P90/P99 | 固定 TPOT 累积计数器，采集时转换为 `higress_ai_tpot_milliseconds_bucket` | `tokenvolt:ai_tpot_milliseconds:p{50,90,99}_rate5m` | 暂定 P90 超过 100 毫秒 | 单次请求平均值 `(总耗时-TTFT)/(输出 Token-1)`；依赖最终 usage |
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
| 模型 × 厂商非预期 HTTP 429 | `tokenvolt:provider_model_unexpected_429_rpm:rate5m` | 持续 2 分钟非零，严重 | 同一 5 分钟窗口内实际 RPM、TPM 均低于已配置承诺值，却收到厂商 429 |
| 厂商 HTTP 5xx | `tokenvolt:provider_5xx_rpm:rate5m` | 持续 5 分钟非零 | 厂商侧故障信号 |
| 模型 × 厂商成功率 | `tokenvolt:provider_model_success_ratio:rate5m` | 低于 99% 且样本量足够 | 只有实测 RPM 或 TPM 达到已配置承诺值时，才从质量失败中排除该窗口的 HTTP 429；低于承诺容量的 429 仍算厂商失败 |
| 模型 × 厂商 TTFT | `tokenvolt:provider_model_ttft_milliseconds:p{50,90,99}_rate5m` | P90 使用网关统一阈值 | 比较同一模型在不同厂商上的首包质量 |
| 模型 × 厂商 TPOT | `tokenvolt:provider_model_tpot_milliseconds:p{50,90,99}_rate5m` | P90 使用暂定阈值 | 比较同一模型在不同厂商上的生成速度 |
| 模型 × 厂商实际/承诺 RPM | 实际逻辑 RPM 与 `tokenvolt:provider_model_rpm_limit` | 大盘展示 | 承诺值必须从合同或厂商控制台填入 Helm，不能由流量推算 |
| 模型 × 厂商实际/承诺 TPM | 实际总 TPM 与 `tokenvolt:provider_model_tpm_limit` | 大盘展示 | 承诺值属于配置，不是测量指标 |
| 每 Pod 及总活跃流 | `envoy_http_downstream_rq_active` | 达到最大副本且超过每 Pod 225 条的等效容量时严重告警 | 与 Gateway HPA 使用同一个受控指标 |
| 可采集的 Gateway 副本数 | `up{job="higress-gateway"}` | 低于配置的最小副本数 | 判断可用性及服务发现是否正常 |
| 下游和上游连接数 | Envoy 活跃连接 Gauge | 仅大盘展示 | 长流连接和连接池分析 |
| 上游等待请求 | Envoy pending request Gauge | 持续 2 分钟非零 | 上游连接池或厂商容量压力 |
| 连接溢出 | Envoy Listener/Cluster overflow Counter | 任意增长 | 连接或资源达到硬限制 |
| 请求重置 | Envoy 下游和上游 reset Counter | 5 分钟内超过 3 次 | 客户端、网关、厂商或发布过程异常 |
| Envoy 内存 | `envoy_server_memory_allocated` | 当前 1 GiB 限额下达到 768 MiB | 不依赖 cAdvisor 的数据面内存压力指标 |

## 网络、Controller 与采集链路

| 范围 | 指标 | 告警 |
| --- | --- | --- |
| Terway/Cilium | CT Map 压力、Map 更新失败 | 70% 警告、90% 严重；任何 Map 更新失败均告警 |
| Higress Controller | xDS、过期 Nonce、Endpoint 未就绪、EDS 无实例、推送与收敛直方图 | Endpoint 未就绪；EDS 发布空实例 |
| Prometheus Adapter | Adapter `up`、请求数和进程指标 | 不可用 2 分钟；Gateway HPA 没有 CPU 兜底 |
| HPA 状态 | 当前/期望/最小/最大副本，当前/目标指标，Scaling 条件 | 无法伸缩；期望副本持续 10 分钟未收敛 |
| HPA 事件 | ACK 官方 K8s Event Center（SLS） | 保存扩缩容决策、取指标失败、达到上下限和调度失败等事件 |
| Collector | Remote Write 失败、丢弃、积压、重试、最新时间戳，规则失败、序列数、进程 CPU/内存 | 写入失败或积压；规则计算失败 |
| Collector 消失 | ARMS 侧 `absent(up{job="higress-metrics-collector"})` | 独立严重告警，不依赖 Collector 自己存活 |

集群内 Prometheus 负责计算详细且基数受控的规则，并将生成的 `ALERTS` 序列
Remote Write 到 ARMS。ARMS 中有一条桥接规则转发处于 firing 状态的警告和严重
告警，另有一条规则独立检测 Collector 消失。设置
`prometheus_alert_dispatch_rule_id` 可接入指定通知策略；留空则使用账号默认的
AlertManager 路径。

## 明确不采集的内容

- 不 Remote Write apiserver、etcd、kubelet/cAdvisor、node-exporter、CoreDNS
  或通用 kube-state-metrics 指标。只运行一个限定到 `higress-system` HPA 资源的
  精简 kube-state-metrics。
- 不使用 Linux 原生 `nf_conntrack` 作为判断依据。ACK 使用 Terway DataPath V2，
  对应容量指标是 Cilium eBPF CT Map 压力。
- 不把租户、API Key、提示词、响应内容、请求 ID、任意 Path 或时间戳放入指标标签。
- 不在 ACK 中安装 Grafana Server 或 Sidecar。大盘以 ConfigMap 和可导入 JSON
  的形式提供。

## 仍然存在的缺口

| 缺口 | 当前替代方案 | 后续工作 |
| --- | --- | --- |
| 成功请求未返回任何厂商 usage 的比例 | 使用 SLS 的 `usage_status`；缓存覆盖率只能反映缓存字段 | 在 `ai-statistics` 中增加低基数的 `usage_reported_request_count` |
| 严格的流式请求开始/完成比例 | 使用中断、失败指标及 SLS 的 `response_completed` | 增加低基数的流开始和流完成 Counter |
| 首个有语义内容的 Token 延迟 | 使用压测客户端；现有 TTFT 是首个上游数据块 | 插件按协议识别 SSE 中的实际内容 |
| 真实逐 Token 延迟分布 | 当前 TPOT 是单请求平均值 | 确有运营价值时，再增加客户端或插件 Token 事件直方图 |
| 不受厂商响应影响的稳定公共模型标签 | 暂时使用 `ai_route`，`ai_model` 保留响应模型语义 | 增加可信且低基数的公共模型标签 |
| Pod CPU、容器内存历史 | 压测时使用 `kubectl top`；HPA 自身状态和事件已经持久化 | 确有长期存储价值时再增加窄范围采集，不能打开全量 kubelet/cAdvisor |
| 厂商集群标签归一化 | Collector 正则并保留原始 `ai_cluster` | 启动环境后用一次真实 Scrape 验证 |
| Envoy 上游调用指标的响应码标签 | 静态配置按 Envoy 标准标签编写 | 启动环境后用一次真实 Scrape 验证 429/5xx 查询 |

前两个是目前 Prometheus 中真正缺少的基础 AI 记账质量指标。它们需要发布新的
Wasm 产物，应作为独立的数据面改动，通过 Mock 和真实流式请求验证。

模型 × 厂商 429 使用本 fork 新增的 `llm_rate_limited_count`。当前固定的 Wasm
摘要尚未包含该计数器；代码和规则已经准备好，但在发布并固定新产物以前，只有
Envoy 的厂商级 429 可见，按承诺容量调整后的成功率不会产生数据。

每条 HTTP 429 请求同时在 SLS `ai_log` 中写入
`provider_rate_limit_event=true` 和
`rate_limit_evaluation=provider_model_capacity_window`。是否“非预期”必须使用所有
Gateway 副本汇总后的 5 分钟 RPM/TPM 判断，不能由单个 Envoy Pod 在请求结束时
可靠决定。因此告警以模型、厂商和时间窗定位异常，再使用上述标记以及
`request_id`、`ai_log.upstream_request_id` 检索请求证据；日志不会伪造一个不可靠的
请求级 expected/unexpected 布尔值。

非预期 429 告警发生后，在告警时间范围内可用以下 SLS SQL 提取向厂商核对的证据；
再按告警的 `ai_model`、`ai_provider` 对应模型和 `upstream_cluster` 缩小范围：

```sql
* | SELECT start_time, request_id, "ai_log.upstream_request_id",
           "ai_log.model", upstream_cluster, response_code, response_flags
    WHERE "ai_log.provider_rate_limit_event" = 'true'
    ORDER BY start_time ASC
```

该查询只读取请求标识和诊断元数据，不读取 API Key、Prompt 或模型回答。

## Grafana 使用方式

`higress-ack-ops` 在运行阶段部署单副本 Grafana，通过 Higress 的 `/grafana/`
子路由访问，并自动加载
`charts/higress-ack-ops/dashboards/tokenvolt-higress-ai-gateway.json`。启用控制面/模型
API 公网分流时，该路由自动挂到进入
Higress 的模型 API 域名（当前为 `api.tokenvolt.net/grafana/`），不会挂到绕过
Higress、直达 TokenVolt 控制面的 `ack.tokenvolt.net`。
数据源直接读取集群内受控的 `higress-metrics-collector`，无需在 Grafana 中保存
ARMS 凭证。

### 大盘信息架构

主大盘按 OpenRouter 的模型页思路组织，而不是把所有基础设施指标混成一组：

1. 先选择一个模型，顶部展示该模型经过整个网关后的成功率、TTFT P50/P90、
   TPOT P50/P90 和 RPM；这是客户实际感受到的网关整体质量。
2. 紧接着用“模型 × 厂商”表比较成功率、TTFT、TPOT、RPM 和 TPM。表格可按任意
   列排序；不额外制造一个权重不透明的综合分数。
3. 时序趋势、Token、缓存和合同容量用于解释排名变化。
4. Envoy、Terway/Cilium、HPA、采集器和 Controller 属于基础设施诊断区，不参与
   厂商质量排名。

价格尚未进入 Prometheus；后续厂商表需要从版本化价格目录补充输入、输出和缓存
单价。价格是配置事实，不能从流量指标推断。

### 请求明细边界

逐请求明细来自 SLS `model-access`，不进入 Prometheus。Grafana 需要安装阿里云官方
SLS 数据源插件并使用仅允许读取该 Logstore 的身份后，才能内嵌以下三类表：

- TTFT 超过当前时间窗 P90 的请求，按 TTFT 降序；
- TPOT 超过当前时间窗 P90 的流式请求，按 TPOT 降序；
- HTTP 5xx 和非预期 429 的请求证据。

每行只展示时间、网关请求 ID、厂商请求 ID、模型、上游集群、状态码、TTFT、TPOT
和 Token 数，不展示 API Key、Prompt 或模型回答。TPOT 由单请求字段计算：
`(llm_service_duration - llm_first_token_duration) / (output_token - 1)`，仅对
`output_token > 1` 且 usage 完整的流式请求有效。

“非预期 429”不是单 Pod 能在请求结束时独立判断的布尔值：先由 Prometheus 使用
全部 Gateway 副本的模型 × 厂商五分钟 RPM/TPM 与合同容量判定异常窗口，再在该
窗口用 `provider_rate_limit_event=true` 下钻到 SLS 请求列表。这样列表中的每条
429 都是告警窗口证据，不会伪造错误的逐请求归因。

管理员密码由 OpenTofu 生成，保存在 `higress-grafana-admin` Secret 和敏感 State
中，不写入 Git。使用 `tofu output -json grafana_admin_credentials` 单独读取 URL、
用户名和密码。Grafana 使用临时 SQLite；大盘由 Git/ConfigMap 声明式恢复，页面中
手工创建的用户、数据源或大盘在 Pod 重建后不保证保留。
