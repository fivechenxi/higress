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

# Higress ACK Prometheus metric allowlist

## Collection policy

The Helm-managed `higress-metrics-collector` keeps only the metric families
listed below and remote-writes them to the ACK-bound Prometheus V2 instance.
The ACK `metric-agent` and `cs-default` monitoring stack are deliberately not
installed. Priority is AI service quality first, Gateway capacity/errors
second, Terway/Cilium health third, and minimum control-plane health last. Do
not retain the complete Envoy endpoint.

Observed cardinality after the clean rebuild:

| State | Collector head series |
| --- | ---: |
| Higress + three Terway targets, before loadgen | 409 |
| After all bounded benchmark run labels/histograms | 3,056 |

The load-test series are temporary and bounded by fixed run IDs. Production
cardinality depends on normalized route/model/provider labels and must be
measured before enabling per-consumer labels. The collection configuration
uses an explicit `keep` action, not a drop list. Check the current Alibaba Cloud
price page before estimating production cost; do not rely on a static price in
this repository.

## AI Gateway: model service quality (highest priority)

Higress has AI-specific metrics, but they come from the `ai-statistics` WASM
plugin rather than Envoy core. The plugin must run after `ai-proxy` on every
measured AI route; without it these series do not exist.

Keep these metric families:

- `route_upstream_model_consumer_metric_llm_first_token_duration`
- `higress_ai_ttft_milliseconds_bucket` (10 cumulative buckets after collector relabeling)
- `route_upstream_model_consumer_metric_llm_stream_duration_count`
- `route_upstream_model_consumer_metric_llm_service_duration`
- `route_upstream_model_consumer_metric_llm_duration_count`
- `route_upstream_model_consumer_metric_llm_tpot_duration`
- `route_upstream_model_consumer_metric_llm_tpot_count`
- `higress_ai_tpot_milliseconds_bucket` (10 cumulative buckets after collector relabeling)
- `route_upstream_model_consumer_metric_llm_request_count`
- `route_upstream_model_consumer_metric_llm_failure_count`
- `route_upstream_model_consumer_metric_llm_rate_limited_count`
- `route_upstream_model_consumer_metric_llm_aborted_count`
- `route_upstream_model_consumer_metric_llm_inflight_request`
- `route_upstream_model_consumer_metric_input_token`
- `route_upstream_model_consumer_metric_output_token`
- `route_upstream_model_consumer_metric_total_token`
- `route_upstream_model_consumer_metric_cache_hit_token`
- `route_upstream_model_consumer_metric_cache_reported_request_count`
- `route_upstream_model_consumer_metric_cache_hit_request_count`

Keep the bounded `ai_route`, `ai_cluster`, and `ai_model` dimensions. The
collector copies `ai_cluster` to `ai_provider`, giving one reusable raw data
set for gateway-wide aggregation, model drill-down, and model/provider
drill-down. It does not emit three duplicate metric sets. TokenVolt cluster
names matching `tokenvolt-<provider>.dns` are normalized to `<provider>`; the
raw cluster value remains the fallback for unmatched clusters. Keep
`ai_consumer` only in the bounded one-hour in-cluster Prometheus so distinct
API-key series cannot collide. Recording rules aggregate it away, and remote
write drops every raw series that still carries the label. Per-customer
observability remains in SLS and has its own cardinality and cost budget.

TTFT buckets are `100,250,500,1000,2000,5000,10000,30000,60000,+Inf` ms. TPOT
buckets are `5,10,20,30,50,100,250,500,1000,+Inf` ms. The plugin emits fixed
cumulative counters because the current Proxy-Wasm SDK has counter and gauge
primitives but no histogram primitive; collector relabeling converts them into
canonical Prometheus bucket series. Helm recording rules calculate P50, P90,
and P99 at the retained route/model/provider aggregation level.

TPOT is the request-level mean inter-token time:
`(service duration - TTFT) / (output tokens - 1)`. It is emitted only for a
streaming response with at least two provider-reported output tokens. Using
the final usage count means multi-token frames and tool-call/function output
are not mistaken for one token per SSE chunk. It is not a per-token ITL
histogram. TTFT currently retains Higress 2.0.2 compatibility semantics: time
to the first upstream response chunk. A provider that emits a role/metadata-only
first SSE event can therefore report a lower value than time to first semantic
text/tool token; benchmark-side TTFT remains the acceptance source until that
protocol-specific distinction is implemented.

`cache_hit_token` includes OpenAI `cached_tokens`, Anthropic
`cache_read_input_tokens`, and Gemini `cached_content_token_count`. Anthropic
`cache_creation_input_tokens` is intentionally not a hit. The token hit ratio
uses the provider-reported input-token counter as its denominator. Request hit
ratio divides hit requests by
`cache_reported_request_count`, not all requests, so a provider that does not
report cache details is not silently treated as 0% hit rate.

The allowlist now contains 19 logical AI families. Due to the two fixed
histograms, this is 37 concrete exported series names per active
route/provider/model/consumer/Pod tuple: 17 scalar series and 20 bucket series.
The collector drops consumer before remote write. Cardinality must still be
measured with the real model/provider catalog before production rollout.

### Data availability

| KPI | Plugin can calculate | Required upstream/runtime data |
| --- | --- | --- |
| RPM, error ratio, aborted requests | Yes, independent of usage tokens | AI route must be bound to this plugin; response status/body or stream termination |
| Model/provider HTTP 429 | Yes, independent of usage tokens | Forked plugin build containing `llm_rate_limited_count`; all 429 responses are reported without contractual RPM/TPM classification |
| LLM in-flight requests | Yes | Request body must reach the plugin so model can be extracted |
| Input/output/total TPM | Yes, conditionally | Provider must return final usage fields; streaming APIs must include final usage |
| TTFT P50/P90 | Yes | Streaming response; current semantic is first upstream chunk |
| TPOT P50/P90 | Yes, conditionally | Streaming response, final output-token usage, at least two output tokens |
| Cache-hit tokens and token hit ratio | Yes, conditionally | OpenAI/Anthropic/Gemini cache-detail field returned by provider |
| Cache request hit ratio | Yes, conditionally | Same as above; coverage denominator prevents unsupported providers being counted as misses |
| Model dimension | Yes | Request or response model field |
| Provider dimension | Yes, as selected upstream cluster | One normalized provider per Envoy cluster; shared/opaque cluster names need catalog cleanup |

The stock `ai-statistics:2.0.2` image does not contain these additions. The ACK
deployment pins this fork's immutable HTTPS Wasm artifact through the TokenVolt
chart. No series are created while the plugin is unbound or its target AI
Ingress does not exist.

The newly added model/provider 429 counter is newer than the currently pinned
Wasm digest. Its Prometheus rule remains empty until a new immutable plugin
artifact is built, tested, and pinned; the existing Envoy provider-level 429
series remains available meanwhile.

Every raw 429 request is marked in SLS with
`ai_log.provider_rate_limit_event=true` and carries the gateway and upstream
request identifiers. The expected/unexpected decision is deliberately made by
the global five-minute recording rule, because a request-local Wasm instance
cannot see traffic handled by the other gateway replicas. Alert labels and the
alert time window are therefore the join key for retrieving the exact marked
requests from SLS.

Feature-specific additions are conditional:

- Keep `ai_endpoint_picker_decisions_total`,
  `ai_endpoint_picker_fallback_total`,
  `ai_endpoint_picker_missing_signal_total`,
  `ai_endpoint_picker_feedback_total`, and `ai_endpoint_picker_inflight` when
  the self-hosted MaaS endpoint picker is enabled.
- Keep `ai_sec_request_deny` and `ai_sec_response_deny` only when AI security
  guard is enabled.

Do not pre-collect every family offered by every AI plugin. Cache, quota,
rate-limit, security, and endpoint-picker metrics enter the allowlist together
with the corresponding feature rollout.

## TokenVolt control plane and usage pipeline

When TokenVolt is enabled by the ACK Terraform stack, the collector scrapes the
authenticated `/internal/metrics` endpoint and keeps only `tokenvolt_*` metric
families. The same generated bearer token is stored as one Secret in each of
the `tokenvolt-system` and `higress-system` namespaces; it is never rendered
into a ConfigMap. Terraform passes only its SHA-256 digest into the TokenVolt
Pod template, so rotating the Secret rolls the process that reads the token at
startup without exposing the token itself.

The retained low-cardinality gauges cover control-plane availability, database
readiness, operational queries, credential-operation backlog, the latest
successful usage watermark, failed/incomplete usage runs, and unknown-token
records. They do not contain tenant, API-key, request, prompt, or response
labels. Billing queue depth and RDS backup results are not exposed by this
endpoint and therefore are not represented by synthetic Prometheus rules.

`tokenvolt_usage_unknown_token_records_48h` counts every request that returned
without token fields, which includes failures and interruptions that have no
usage by definition, so a rule on it fires on ordinary errors. Billing integrity
is alerted on `tokenvolt_usage_success_without_usage_records_48h` instead, which
counts only **successful** requests whose token counts never arrived. Both come
from `usage_hourly`, where `token_unknown_success_count <= token_unknown_count`
is enforced by a check constraint. The success-scoped column and its metric only
exist once a control plane that writes them is deployed; until then the
expression has no series and the alert stays silent rather than erroring.

## Gateway: stream capacity and resource pressure

Keep these gauges:

| Metric | Purpose |
| --- | --- |
| `envoy_http_downstream_rq_active` | Primary count of in-flight HTTP requests; an SSE generation remains active for its lifetime |
| `envoy_http_downstream_cx_active` | Active downstream TCP/HTTP connections; compare with active requests and HTTP/2 multiplexing |
| `envoy_listener_downstream_cx_active` | Listener-level active connections, filtered to listener `0.0.0.0_80` |
| `envoy_cluster_upstream_rq_active` | Requests currently active toward each MaaS/provider cluster |
| `envoy_cluster_upstream_cx_active` | Active upstream connections by provider cluster |
| `envoy_cluster_upstream_rq_pending_active` | Requests waiting for an upstream connection/capacity |
| `envoy_cluster_membership_total` | Endpoints currently assigned to each provider cluster; `== 0` on a `tokenvolt-*.dns` cluster is the attributable form of "published without endpoints" |
| `envoy_server_memory_allocated` | Envoy allocated memory; used for memory per active stream |
| `envoy_server_memory_heap_size` | Envoy heap reservation and fragmentation context |

Keep these counters for offered/completed traffic and provider response
distribution:

- `envoy_http_downstream_rq`
- `envoy_cluster_upstream_rq`
- `envoy_cluster_external_upstream_rq`

Retain only bounded labels such as Pod, listener, provider cluster, response
code, and response-code class. Outside the normalized AI-statistics dimensions
above, do not promote model, tenant, API key, request ID, path, or arbitrary
host values into metric labels.

## Gateway: exhaustion, reset, and timeout signals

Every non-zero increase in the following families is recorded during a test:

### Downstream/listener

- `envoy_listener_downstream_cx_overflow`
- `envoy_listener_downstream_global_cx_overflow`
- `envoy_listener_downstream_cx_transport_socket_connect_timeout`
- `envoy_listener_downstream_pre_cx_timeout`
- `envoy_http_downstream_rq_timeout`
- `envoy_http_downstream_rq_rx_reset`
- `envoy_http_downstream_rq_tx_reset`
- `envoy_http_downstream_rq_too_many_premature_resets`
- `envoy_http_rq_reset_after_downstream_response_started`
- `envoy_http_downstream_cx_delayed_close_timeout`
- `envoy_http_downstream_cx_idle_timeout`

### Upstream/provider

- `envoy_cluster_upstream_cx_total`
- `envoy_cluster_upstream_cx_connect_fail`
- `envoy_cluster_upstream_cx_connect_timeout`
- `envoy_cluster_upstream_cx_destroy_remote`
- `envoy_cluster_upstream_cx_destroy_remote_with_active_rq`
- `envoy_cluster_upstream_cx_destroy_local_with_active_rq`
- `envoy_cluster_upstream_cx_idle_timeout`
- `envoy_cluster_upstream_cx_overflow`
- `envoy_cluster_upstream_cx_pool_overflow`
- `envoy_cluster_upstream_rq_pending_overflow`
- `envoy_cluster_upstream_rq_retry_overflow`
- `envoy_cluster_upstream_rq_timeout`
- `envoy_cluster_upstream_rq_per_try_timeout`
- `envoy_cluster_upstream_rq_per_try_idle_timeout`
- `envoy_cluster_upstream_rq_rx_reset`
- `envoy_cluster_upstream_rq_tx_reset`

`upstream_cx_destroy_remote_with_active_rq` is the primary connection-level
correlate for an access-log `UC`: it proves that the remote side destroyed a
connection while Envoy still had an active request. Compare it with
`upstream_cx_total`, `upstream_cx_idle_timeout`, and the local/remote destroy
counters to distinguish connection churn, proactive local idle reclamation,
and provider-side termination. These counters do not by themselves prove the
age of the affected connection; proving stale-pool reuse still requires a
time-correlated counter delta, connection debug log, or packet capture.

### HTTP/2 and overload protection

- `envoy_cluster_http2_header_overflow`
- `envoy_cluster_http2_rx_reset`
- `envoy_cluster_http2_tx_reset`
- `envoy_cluster_http2_keepalive_timeout`
- `envoy_cluster_http2_tx_flush_timeout`
- `envoy_envoy_overload_actions_reset_high_memory_stream_count`

## Controller/Pilot (minimum health only)

Keep these direct gauges/counters:

- `pilot_xds`
- `pilot_xds_expired_nonce`
- `pilot_endpoint_not_ready`
- `pilot_eds_no_instances` — a gauge ("number of clusters without instances"), so rules must read it as a gauge (`> 0` for the condition); `increase()` on it fires on the recovery edge too and duplicates every incident

Keep bucket, sum, and count for these two bounded histograms:

- `pilot_xds_push_time`
- `pilot_proxy_convergence_time`

The dashboard must calculate p95/p99 from histogram buckets instead of
averaging already aggregated quantiles.

## ACK resource and host network evidence

Do not remote-write managed etcd or kubelet/cAdvisor container metrics from
this application-owned collector. A 60-second allowlist keeps only workload
availability/restarts, node CPU/memory/root-disk, API server availability/error
rate, and CoreDNS availability/SERVFAIL metrics. `metrics-server` remains
installed for controller CPU HPA and `kubectl top`.

The application collector feeds upstream `prometheus-adapter`, exposing the
filtered outbound request gauge as `higress_active_streams`. Gateway HPA uses
only 225 active streams per Pod. It deliberately has no CPU fallback; adapter
availability is therefore a critical alert.

ACK's official K8s Event Center persists HPA decisions and failures in SLS.
This is independent from the disabled cs-default Prometheus jobs. Under the
published Event Center policy, the default 90-day retention remains free while
daily event ingestion stays below 256 MB; verify current pricing before rollout.

The disposable cluster must use Terway DataPath V2. This removes kube-proxy
IPVS/iptables and Linux Netfilter `nf_conntrack` from the Pod Service datapath,
so do **not** collect `node_nf_conntrack_*` as a test verdict signal.

DataPath V2 is not stateless: it implements connection tracking in eBPF maps.
Collect these Cilium/Terway families from port 9962 instead:

- `cilium_bpf_map_pressure`
- `cilium_bpf_map_capacity`
- `cilium_bpf_map_ops_total`
- `cilium_bpf_maps_virtual_memory_max_bytes`

For connection exhaustion, inspect
`map_name=~"ct(4|6|_any4|_any6)_global"`. A failed
map update is a test failure. Sustained pressure above 0.7 is a capacity warning,
above 0.8 requires tuning, and above 0.95 is an emergency. Also inspect the
Service maps `cilium_lb[46]_services_v2`. The test must confirm at runtime that
no `kube-proxy` Pod exists before accepting results.

Capture `/proc/net/snmp`, socket summaries, and file-descriptor counts before
and after qualification runs as explicit test artifacts instead of continuously
shipping all host metrics. The current Gateway file-descriptor limit is
1,048,576; record open descriptors and active downstream/upstream connections
together.

## Load-generator metrics

The test harness exports a bounded run label and these metrics while a test is
active:

- in-flight requests;
- started, completed, and failed requests;
- response status counts;
- TTFB histogram;
- complete-stream latency histogram;
- response bytes;
- configured concurrency and run start time.

Run labels are fixed test IDs such as `stream-gw-c10000-r1`. Never use request
IDs, prompts, tenants, model response text, or timestamps as labels.

## Dashboard pass/fail panels

The load step is valid only when all are visible on the same time axis:

1. configured and observed active streams;
2. direct versus Gateway TTFB histogram and Gateway-added p99 TTFT;
3. stream completion/error/reset counts;
4. Gateway open connections, pending requests, and collector health; correlate
   CPU/memory and replica count from metrics-server/HPA events;
5. sampled TCP retransmission evidence and Terway eBPF CT/LB map pressure;
6. sampled mock and load-generator CPU/memory, proving they did not saturate;
7. AI-statistics average TTFT/service duration, token throughput, failures,
   and model/provider split;
8. Controller xDS connection count and push/convergence only during a
   concurrent configuration change.

The complete raw-to-derived-to-dashboard-to-alert mapping and known gaps are in
[OBSERVABILITY_INVENTORY.md](OBSERVABILITY_INVENTORY.md).

## Billing references

- [ACK observability billing](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/observable-billing-description)
- [Prometheus pay-as-you-go pricing](https://help.aliyun.com/zh/arms/prometheus-monitoring/product-overview/pay-as-you-go/)
- [Alibaba Cloud billing examples](https://help.aliyun.com/zh/arms/prometheus-monitoring/product-overview/billing-examples)
- [ACK Prometheus setup](https://help.aliyun.com/zh/arms/prometheus-monitoring/getting-started/container-observable)
