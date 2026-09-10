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
- `route_upstream_model_consumer_metric_llm_stream_duration_count`
- `route_upstream_model_consumer_metric_llm_service_duration`
- `route_upstream_model_consumer_metric_llm_duration_count`
- `route_upstream_model_consumer_metric_llm_failure_count`
- `route_upstream_model_consumer_metric_input_token`
- `route_upstream_model_consumer_metric_output_token`
- `route_upstream_model_consumer_metric_total_token`

Keep the bounded `ai_route`, `ai_cluster`, and `ai_model` dimensions. Model and
provider values must be normalized against the configured catalog (for
example, the approved GLM/Kimi/DeepSeek aliases). Drop `ai_consumer` from this
infrastructure-capacity scrape for now; per-customer observability needs its
own cardinality and cost budget.

The duration metrics are cumulative sums plus counts. They calculate average
TTFT and average service duration, not p95/p99. The load generator's histogram
therefore remains the source of truth for p99 TTFT and the one-second
Gateway-added-latency requirement.

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

- `envoy_cluster_upstream_cx_connect_fail`
- `envoy_cluster_upstream_cx_connect_timeout`
- `envoy_cluster_upstream_cx_overflow`
- `envoy_cluster_upstream_cx_pool_overflow`
- `envoy_cluster_upstream_rq_pending_overflow`
- `envoy_cluster_upstream_rq_retry_overflow`
- `envoy_cluster_upstream_rq_timeout`
- `envoy_cluster_upstream_rq_per_try_timeout`
- `envoy_cluster_upstream_rq_per_try_idle_timeout`
- `envoy_cluster_upstream_rq_rx_reset`
- `envoy_cluster_upstream_rq_tx_reset`

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
- `pilot_eds_no_instances`

Keep bucket, sum, and count for these two bounded histograms:

- `pilot_xds_push_time`
- `pilot_proxy_convergence_time`

The dashboard must calculate p95/p99 from histogram buckets instead of
averaging already aggregated quantiles.

## ACK resource and host network evidence

Do not remote-write apiserver, etcd, kubelet/cAdvisor, kube-state-metrics,
CoreDNS, or node-exporter metrics from this application-owned collector. ACK
operates the managed control plane, and the project does not accept the cost of
full Kubernetes monitoring. Native HPA continues to read CPU from
`metrics-server`; `kubectl top` and HPA events are captured as test evidence but
are not stored in the application Prometheus instance.

The application collector feeds upstream `prometheus-adapter`, exposing the
filtered outbound request gauge as `higress_active_streams`. Gateway HPA uses
225 streams per Pod together with 65% CPU; adapter availability is alerted for
manual handling.

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

## Billing references

- [ACK observability billing](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/observable-billing-description)
- [Prometheus pay-as-you-go pricing](https://help.aliyun.com/zh/arms/prometheus-monitoring/product-overview/pay-as-you-go/)
- [Alibaba Cloud billing examples](https://help.aliyun.com/zh/arms/prometheus-monitoring/product-overview/billing-examples)
- [ACK Prometheus setup](https://help.aliyun.com/zh/arms/prometheus-monitoring/getting-started/container-observable)
