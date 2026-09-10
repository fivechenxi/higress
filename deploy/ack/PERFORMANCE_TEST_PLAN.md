# Higress AI gateway performance test plan

## Purpose and scope

This plan sizes the Higress data plane and control plane for a MaaS gateway that
exposes OpenAI- and Anthropic-compatible APIs and routes requests to both
self-hosted inference services and external providers. The expected model mix is
GLM 5.x, Kimi K3, and DeepSeek V4. Model inference is deliberately separated
from gateway capacity: every gateway result is paired with a direct-to-mock
baseline so that backend latency is not mistaken for Higress overhead.

The first baseline uses an in-cluster deterministic mock and HTTP. A production
qualification run must repeat the relevant cases through the real internal CLB,
TLS, authentication, AI proxy/statistics plugins, and a small controlled sample
of each real provider.

## What the two components do

### Gateway data plane

`higress-gateway` is Envoy. It owns client connections, TLS termination, HTTP
parsing, routing, upstream connection pools, retries/fallback, and Wasm plugin
execution. For AI traffic, capacity is driven by more than requests per second:

- concurrent streaming responses and their lifetime;
- input/output bytes and SSE event rate;
- TLS handshakes and connection reuse;
- enabled plugins, especially AI protocol conversion, authentication, token
  counting, rate limiting, logging, and statistics;
- retries, provider 429/5xx responses, and slow clients.

Long model generation time mostly holds connections and memory; it does not keep
a CPU core busy continuously. A high-QPS zero-latency benchmark and a
long-running streaming benchmark therefore answer different questions and both
are required.

### Controller and discovery control plane

Each `higress-controller` Pod contains the Higress reconciliation container and
the Pilot/discovery container. Kubernetes Ingress, Gateway API, Service,
Endpoint, ConfigMap, Secret, and Higress CRDs are the source of truth. Each
replica watches those objects, builds an in-memory view, and serves xDS to Envoy.
The deployment is not a stateful primary/standby database.

Adding replicas provides availability and spreads xDS connections. It does not
linearly reduce route-compilation work because every replica observes and
processes the configuration set. Route cardinality and update storms are
therefore primarily a vertical-sizing/sharding problem; proxy count and xDS
fan-out are the part that benefits most from horizontal scaling.

In practice, xDS uses long-lived connections. Kubernetes Service balancing
does not redistribute established connections when a new controller appears,
so a small gateway fleet can concentrate all xDS clients on one controller.
The other replica is still a valid failover target, but it must not be assumed
to share steady-state xDS work evenly.

## Test environment recorded with every result

Record the following before every run:

- Higress, Kubernetes, node image, and instance type versions;
- gateway/controller replica count, resource requests/limits, and Envoy worker
  concurrency;
- node placement and whether the load generator shares a node with the gateway;
- route count, endpoint count, provider count, plugin chain, request/response
  sizes, TLS mode, HTTP version, and connection reuse;
- mock TTFT, stream duration, chunk interval, injected error rate, and retry
  policy;
- HPA and node autoscaler events during the run.

Use at least three measured repetitions after a warm-up. Report the median run
and the worst p99. A run is invalid if the load generator reaches its own CPU or
network limit, nodes change during the steady-state measurement window, or the
mock cannot sustain the offered load directly.

## Data-plane matrix

Run every case directly against the mock and through Higress. The primary result
is the difference between those two paths.

| Case | Request/response profile | Concurrency ladder | Primary measurements |
| --- | --- | --- | --- |
| D1 non-stream control | 1 KiB JSON, 2 KiB JSON, 50 ms backend | 1, 10, 50, 100, 200 | sustainable RPS, added p50/p95/p99 latency, CPU/request |
| D2 OpenAI stream | 8 KiB prompt, 300 ms TTFT, 128 SSE chunks at 30 tokens/s | 50, 100, 250, 500, 1,000 | added TTFT, stream completion rate, active connections, RSS/connection |
| D3 Anthropic stream | 8 KiB prompt, Anthropic event framing, same timing as D2 | same as D2 | protocol-specific overhead and failures |
| D4 long context | 64 KiB request, 8 KiB streamed response | 20, 50, 100, 200 | request-size sensitivity, memory, p99 TTFT |
| D5 slow client | D2 response with client read throttling | 100, 250, 500 | downstream buffering and memory growth |
| D6 failure/fallback | 5% 429, 2% 5xx, 1% timeout | 50, 100, 250 | retry amplification, fallback success, upstream attempts/request |
| D7 production plugin chain | auth + AI proxy + statistics + token limit | D1-D4 subset | Wasm CPU/memory and latency delta |
| D8 soak | production traffic mix for 2-4 hours | expected peak and 1.5x peak | leaks, connection churn, HPA stability |

Do not use a real paid model for saturation testing. Real GLM/Kimi/DeepSeek
tests should be limited to protocol correctness and low-rate latency comparison;
provider inference latency, quotas, and Internet variance otherwise dominate the
gateway signal and create uncontrolled cost.

## Control-plane matrix

| Case | Method | Pass signal |
| --- | --- | --- |
| C1 steady cardinality | Pre-create 100, 1k, 5k, then 10k routes and restart one controller | both replicas Ready; memory reaches a stable plateau; no xDS rejects |
| C2 single update | At each cardinality, patch one canary route and poll through Envoy | p95 acceptance-to-serving convergence within the project SLO |
| C3 batch update | Create/patch 100 and 1k routes as a batch | bounded push queue; no errors; gateways converge to one version |
| C4 endpoint churn | Change 10%, 50%, and 100% of mock endpoints | EDS convergence remains bounded and existing streams survive |
| C5 failover | Delete one controller during continuous config updates and traffic | no data-plane request interruption; new config still converges |
| C6 reconnect storm | Restart gateway replicas together and separately | xDS clients reconnect without rejected/expired config growth |

Higress publishes a reference claim of 10,000 routes taking about three seconds
to become effective. Treat it as a comparison point, not an acceptance result:
the test hardware, API objects, plugins, and definition of start/end must match
before numbers are comparable.

## Metrics and expansion decisions

### Gateway HPA

Use ACK's native Kubernetes HPA with metrics-server for the initial policy.
CPU is the control metric because it responds to TLS, Envoy filters, JSON/SSE
processing, and Wasm work, and is available without a paid metrics pipeline.

Initial policy:

- minimum 2 replicas; maximum 4 in this test node pool;
- target average CPU utilization 65%;
- scale up immediately by up to 100% or two Pods per minute;
- stabilize scale-down for five minutes and remove at most 25% per minute.

Promote beyond CPU-only HPA when ACK Managed Service for Prometheus and the
Alibaba Cloud metrics adapter are enabled. The preferred custom signal is the
maximum of:

1. CPU desired replicas;
2. active downstream streams divided by the tested safe streams-per-Pod.

For this workload, streaming is the dominant path and active streams are the
primary capacity signal. CPU remains necessary for the minority non-stream
path and for TLS, JSON processing, Wasm plugins, logging, and token accounting.
Request rate remains useful for forecasting and test reports, but it is not
required as a third HPA signal while CPU tracks non-stream compute load.

The native Envoy gauges verified in this deployment are
`envoy_http_downstream_rq_active` and
`envoy_http_downstream_cx_active`, filtered to
`http_conn_manager_prefix="outbound_0.0.0.0_80"`. The first is the preferred
stream signal. Do not configure a numeric target from the current run. The raw
Envoy test held 250 streams per Pod without errors, but it did not find the
Gateway saturation knee: the mock/load generator reached its own latency knee
first. Therefore neither 250 nor a fraction of 250 is a scientifically valid
production target.

First measure `C`, the maximum concurrent streams per Pod that still pass
TTFT, completion, memory, connection-overflow, slow-client, and failover SLOs
with the production plugin chain. For a minimum replica count `R` and normal
headroom factor `H` (initially 0.7), set the per-Pod target no higher than:

```text
stream target = C * min(H, (R - 1) / R)
```

With two minimum replicas, failover is the stricter term and the target is at
most `0.5 * C`. This reserves aggregate capacity for new or retried streams
after one Pod disappears; it cannot preserve streams already terminated with
the failed Pod.

Scale before saturation when any of these holds for two consecutive 30-second
windows:

- average CPU is at least 65% or any Pod is above 80%;
- active streams exceed 70% of the validated per-Pod limit;
- gateway-added p99 TTFT exceeds 20 ms or exceeds 10% of direct TTFT;
- p99 non-stream gateway-added latency exceeds 10 ms;
- downstream/upstream connection overflow, pending requests, 5xx generated by
  the gateway, or Envoy worker saturation is non-zero.

The exact capacity values must come from the first saturation knee, not a
generic vendor number. For non-stream reporting, define normal safe capacity as
70% of the highest load at which all latency/error SLOs pass. For the stream
HPA target, use the stricter normal-headroom/failover formula above.

### Controller HPA and capacity

ACK HPA can use the aggregate CPU request of both containers in the Pod. Start
with 2-3 replicas at 65% CPU, immediate scale-up, and five-minute scale-down
stabilization. The maximum is three because strict hostname anti-affinity and
this test node pool's maximum of three workers would leave a fourth replica
Pending.

CPU HPA is only a safety valve. Alert and plan vertical scaling/sharding when:

- `pilot_xds_push_time` p99 exceeds 1 second for five minutes;
- canary configuration convergence p95 exceeds 3 seconds or the agreed SLO;
- `pilot_xds_write_timeout`, xDS reject counters, or expired nonces increase;
- a controller exceeds 75% of its memory limit or restarts/OOMs;
- Kubernetes API throttling or work-queue depth remains non-zero;
- connected xDS clients per controller exceed the tested safe value.

Standard resource HPA averages utilization over controller Pods. It can miss a
single hot controller when all xDS connections land there, and adding a Pod
does not move established xDS connections. Prefer per-container and maximum-Pod
alerts plus the Pilot metrics above; keep the HPA as burst protection, not as
the primary controller capacity mechanism.

For a short configuration burst, adding replicas after CPU rises is usually too
late and every replica must still rebuild the configuration. Prefer adequate
minimum replicas, CPU/memory headroom, debounced updates, and namespace/Ingress
class sharding if route cardinality becomes the limiting factor.

## Acceptance gates

The initial production gate is:

- zero gateway-generated errors at expected peak and less than 0.1% at 1.5x
  peak, excluding deliberately injected failures;
- gateway-added p99 latency at most 10 ms for non-stream requests;
- gateway-added p99 TTFT at most 20 ms and at most 10% of direct TTFT for
  streaming requests;
- no stream truncation; completed stream count equals successful request count;
- one gateway or controller Pod can be deleted without breaching the above;
- C2 convergence p95 at most 3 seconds at the accepted route cardinality;
- steady-state CPU below 65% average and below 80% per Pod, memory below 75% of
  limit, with 30% tested failover headroom.

These are starting SLOs. Replace them with measured customer requirements once
expected tenant count, peak concurrent generations, prompt distribution, and
plugin chain are known.

## Sources

- [Higress overview and AI long-connection design](https://higress.cn/docs/latest/overview/what-is-higress)
- [Higress published comparison, including the 10k-route reference](https://higress.cn/advantage/)
- [Higress operational parameters](https://higress.cn/docs/latest/user/configurations/)
- [ACK HPA with CPU, memory, and custom metrics](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/horizontal-pod-autoscaling)
- [ACK HPA behavior tuning](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/adjust-the-sensitivity-of-hpa-expansion-and-contraction)
- [ACK metrics-server](https://help.aliyun.com/en/ack/product-overview/metrics-server)
- [Istio Pilot metrics](https://istio.io/latest/docs/reference/commands/pilot-discovery/)

## Measured results

### Environment and validity

Measured on 2026-09-10 in ACK Basic Kubernetes 1.36.2 with Higress 2.2.4,
`ecs.e-c1m2.xlarge` workers, two 250m/512Mi gateway replicas, and two
controller replicas. The gateway used plain HTTP and a raw Ingress route; TLS,
AI proxy/protocol conversion, authentication, token accounting, rate limiting,
and provider fallback were not enabled. The deterministic backend used 50 ms
non-stream latency or 300 ms TTFT plus 32 SSE chunks at 30 ms intervals.

The load generator and mock shared a worker that was separate from the gateway
worker. These are single exploratory runs unless stated otherwise; they size
the next test and validate metrics/HPA behavior, but do not satisfy the
three-repetition production sign-off rule above.

### Non-stream OpenAI-compatible route

| Concurrency | Direct RPS | Gateway RPS | Direct p99 (ms) | Gateway p99 (ms) | p99 delta (ms) | Errors |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 19.19 | 18.76 | 54.50 | 58.83 | +4.33 | 0 |
| 10 | 190.10 | 187.85 | 59.23 | 57.66 | -1.57 | 0 |
| 20 | 374.32 | 361.20 | 66.56 | 66.33 | -0.23 | 0 |
| 30 | 571.74 | 544.89 | 61.28 | 76.46 | +15.18 | 0 |
| 50 | 966.60 | 894.77 | 56.16 | 81.75 | +25.60 | 0 |
| 100 | 1866.51 | 1717.18 | 88.88 | 94.54 | +5.66 | 0 |

The concurrency-100 Gateway run lasted 90 seconds and included HPA expansion,
so it is not directly comparable to the 20-second direct run. Before expansion,
the two gateway Pods consumed 370m and 379m CPU, or about 148% and 152% of their
250m requests. ACK HPA expanded first to three and then four Pods, and returned
to two after the five-minute stabilization window. This validates CPU at 65%
as a useful compute-load trigger.

For the unchanged two-Pod state, concurrency 20 was the highest measured point
that passed the provisional 10 ms p99-delta gate, at about 361 aggregate RPS.
Applying the plan's 70% rule gives a provisional CPU-path planning estimate of
about 125 RPS per Pod, not an additional HPA metric. This is
deliberately conservative and must be replaced after three repeated runs with
the production plugins enabled.

### Streaming routes

| Protocol | Concurrency | Direct p50 TTFT | Gateway p50 TTFT | Direct p99 TTFT | Gateway p99 TTFT | Errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| OpenAI | 10 | 301.64 ms | 303.05 ms | 317.21 ms | 342.71 ms | 0 |
| OpenAI | 50 | 302.32 ms | 304.87 ms | 335.03 ms | 447.00 ms | 0 |
| OpenAI | 100 | 302.81 ms | 303.41 ms | 351.90 ms | 380.20 ms | 0 |
| Anthropic | 50 | 302.25 ms | 304.18 ms | 310.69 ms | 356.84 ms | 0 |
| OpenAI | 500 | 304.12 ms | 304.54 ms | 636.83 ms | 474.49 ms | 0 |

Median TTFT overhead stayed near 0.4-2.6 ms, but tail latency was variable and
breached the provisional 20 ms p99-delta gate. At concurrency 500, direct TTFT
also degraded sharply, invalidating that row for gateway latency attribution.
It remains useful as a connection-holding test: all 16,000 Gateway streams
completed, and each Gateway held 250 active streams.

With 100 active streams, the two Gateway Pods reported 50 active requests each
but only 3m and 17m CPU; HPA remained at two replicas with 4% average CPU. With
500 streams, each Pod reported 250 active requests while HPA still saw only 8%
CPU. This proves that CPU-only HPA cannot protect long-lived MaaS streams. Add
the active-request custom metric before production traffic, after a dedicated
stream test establishes `C` without saturating the mock or load generator.

### Controller and failover

| Test | Result |
| --- | --- |
| 100 host rules | API apply 4.25 s; mean incremental RDS push 50.9 ms and 10.5 ms on the two replicas; final route served |
| 1,000 host rules | API apply 4.85 s; mean incremental RDS push 933 ms and 823 ms; controller Pods reached 239m/159Mi and 145m/154Mi |
| Delete non-serving replica | 10,964/10,964 requests succeeded; replacement became Ready and remained on a different node |
| Delete controller carrying both xDS clients | 10,896/10,896 requests succeeded; a newly added route became available 2.467 s after the post-apply probe began; replacement became Ready |

At 1,000 rules, RDS push duration is already close to the one-second alert
threshold with the current CPU request. Controller minimum two replicas and
PDB `minAvailable: 1` are justified for availability, but horizontal replicas
must not be presented as linear configuration throughput. Increase discovery
CPU first when push latency grows, then shard by ingress class/tenant boundary
if route cardinality continues to grow.

After one failover, both Gateway xDS connections were observed on one
controller (`pilot_xds=2`) and zero on the other. Deleting that active replica
caused no data-plane errors and forced successful reconnection. Strict hostname
anti-affinity also caused ACK to add a third worker during replacement because
the terminating Pod temporarily occupied its old topology domain. This is an
availability/cost tradeoff to include in production node-pool sizing. ACK
automatically reclaimed that third worker after the replacement settled; the
cluster returned to two workers without manual node or scaling-group changes.

### Decision from this baseline

- Keep Gateway HPA at 2-4 replicas and 65% CPU for the current test pool.
- Before production, expose Envoy metrics through ACK Managed Service for
  Prometheus/metrics adapter. Run an isolated streaming saturation test to
  establish `C`, then add the active-request target using the formula above.
  Do not promote the current CPU-only policy to the stream-heavy production
  workload.
- Keep Controller at 2-3 replicas with required hostname anti-affinity and PDB
  `minAvailable: 1`. Treat CPU HPA as a safety valve; alert on the busiest Pod,
  RDS push time, convergence, memory, rejects/timeouts, and xDS connections.
- The current run does not qualify the AI plugin chain or protocol conversion.
  Repeat D2-D7 with the exact OpenAI/Anthropic AI-proxy configuration before
  exposing customer traffic.
