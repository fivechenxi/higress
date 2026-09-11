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

The deployed dual-signal HPA selects the maximum desired replica count from:

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
stream signal.

The 2026-09-10 clean-cluster run found the first repeatable system knee between
1,000 and 1,500 concurrent OpenAI streams with four Gateway Pods. At 1,000,
all requests completed and worst-shard Gateway-added p99 TTFT was about 88 ms.
At 1,500, throughput was already about 20% below the direct-path capacity and
Gateway p99 TTFT reached 816 ms. At 2,000 it reached 1,228 ms while throughput
was about 26% below direct. No reset, overflow, or Cilium map exhaustion was
observed. This makes 250 concurrent streams per Pod the highest validated point
below the measured knee for this exact test topology and plugin chain; it is
not a universal Higress limit.

First measure `C`, the maximum concurrent streams per Pod that still pass the
production SLOs, then select an explicit operating headroom factor `H`:

```text
stream target = C * H
```

Use `H <= (R - 1) / R` only when full N-1 spare capacity is required at the
minimum replica count. The current test choice is `H=0.9` because long streams
change slowly and cost efficiency was selected over full N-1 reserve.

The selected test target is 225 streams per Pod, 90% of the measured `C=250`.
This favors cost efficiency for slow-changing long streams and does not reserve
full N-1 capacity at the two-Pod minimum. The ACK addon catalog exposes no
managed custom-metrics adapter, so the ops Chart owns upstream
`prometheus-adapter` v0.12.0. CPU remains an independent scale-up fallback;
adapter unavailability raises `HigressPrometheusAdapterDown` for manual repair.

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

Measured on 2026-09-10 in a clean ACK Basic Kubernetes 1.36.2 cluster with
Higress 2.2.4, `ecs.u1-c1m2.xlarge` workers, a 2-4 Pod Gateway CPU HPA, and two
controller replicas. The gateway used plain HTTP and an Ingress route with the
`ai-statistics` 2.0.2 plugin. TLS, authentication, AI-proxy protocol conversion,
rate limiting, and provider fallback were not enabled. The deterministic
backend used 300 ms TTFT plus 32 SSE chunks at 30 ms intervals and emitted
OpenAI/Anthropic usage data for model/token metrics.

Four mock Pods and four load generators were isolated from the Gateway by
hostname anti-affinity. ACK used three workers: all Gateway replicas were on
one worker, mocks on another, and generators on the third. The Gateway HPA
expanded from two to four Pods, but Pod expansion did not add Gateway node CPU
because all four remained co-located. These are single exploratory runs unless
stated otherwise; they locate the next test range and validate metrics/HPA
behavior, but do not satisfy the three-repetition production sign-off rule.

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

### Streaming routes on the clean cluster

The table sums throughput across four load generators and reports the worst
p99 shard so tail degradation is not hidden by averaging percentiles.

| Protocol/path | Concurrency | RPS | p99 TTFT | Worst added p99 | Requests | Errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| OpenAI direct | 100 | 79.6 | 303 ms | - | 1,690 | 0 |
| OpenAI Gateway | 100 | 77.8 | 315 ms | 12 ms | 1,606 | 0 |
| OpenAI direct | 250 | 199.2 | 309 ms | - | 4,000 | 0 |
| OpenAI Gateway | 250 | 196.7 | 356 ms | 47 ms | 4,000 | 0 |
| OpenAI direct | 500 | 388.6 | 321 ms | - | 8,022 | 0 |
| OpenAI Gateway | 500 | 378.7 | 419 ms | 98 ms | 8,000 | 0 |
| OpenAI direct | 1,000 | 787.2 | 333 ms | - | 16,020 | 0 |
| OpenAI Gateway | 1,000 | 746.0 | 421 ms | 88 ms | 15,855 | 0 |
| OpenAI Gateway | 1,500 | 942.1 | 816 ms | not paired | 29,313 | 0 |
| OpenAI direct | 2,000 | 1,593.5 | 348 ms | - | 32,000 | 0 |
| OpenAI Gateway | 2,000 | 1,186.1 | 1,228 ms | 880 ms | 24,969 | 0 |
| Anthropic Gateway | 1,000 | 774.7 | 404 ms | not paired | 16,000 | 0 |

The 225-target qualification started with two Gateway Pods and 1,000 OpenAI
streaming clients. The adapter reported 501 and 499 active streams; HPA first
scaled 2 to 3 with reason `pods metric higress_active_streams above target`,
then CPU completed the scale to 4. The run completed 31,943 requests with zero
errors at 690.5 RPS; worst-shard p99 TTFT was 572 ms.

The clean direct path remained close to the configured 300 ms TTFT through
2,000 streams, so the high-concurrency Gateway degradation can be attributed
to the Gateway side of the topology rather than to the mock. At 1,500 active
streams a scrape observed an uneven per-Pod split of 201, 369, 238, and 362.
At 2,000, all streams still completed, but throughput and tail TTFT showed a
clear knee. Listener overflow and downstream reset counters remained zero.
Terway/Cilium `ct4_global` map pressure peaked at about 10.6%, far below the
70% warning threshold; connection-map exhaustion was not the cause.

The AI metrics were verified with real samples and bounded labels for route,
upstream cluster, and model: first-token duration, stream/service duration,
input/output/total tokens, and request count. Remote write sent more than
88,000 samples with zero failures during this run.

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
- Keep the provisional measured safe point at 250 active streams per Gateway
  Pod and use the selected economic operating target of 225 per Pod. The
  committed self-managed adapter and CPU fallback are both active. Reconsider
  this headroom if production requires N-1 capacity at minimum replicas.
- Keep Controller at 2-3 replicas with required hostname anti-affinity and PDB
  `minAvailable: 1`. Treat CPU HPA as a safety valve; alert on the busiest Pod,
  RDS push time, convergence, memory, rejects/timeouts, and xDS connections.
- The current run qualifies `ai-statistics` collection and raw OpenAI/Anthropic
  framing only. Repeat D2-D7 with the exact authentication, AI-proxy conversion,
  rate-limit, logging, TLS, and provider configuration before customer traffic.
