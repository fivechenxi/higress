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

# Higress on ACK (disposable test stack)

This directory creates a low-cost, single-zone ACK test environment and installs
the repository's `helm/core` chart. It deliberately does not install Higress
Console.

Shared deployments use an encrypted OSS remote State, TableStore locking, and
versioned tfvars synchronization. See
[`OSS_REMOTE_STATE.md`](./OSS_REMOTE_STATE.md) for the operator commands.

## Lifecycle boundary

OpenTofu creates and destroys only:

- one ACK Basic managed cluster (`ack.standard`);
- one two-node prepaid baseline worker pool;
- one pay-as-you-go elastic worker pool that scales from 0 to 10;
- one ECS SSH key pair shared by both node pools;
- one Higress Helm release and its Kubernetes objects.

It reuses these existing resources as read-only inputs:

- VPC `vpc-2ze8x9jglv9rug2n2a5z4`;
- vSwitch `vsw-2zex87nrlhukk0mlgricd` in `cn-beijing-k`;
- the existing NAT/SNAT path attached to that VPC.

The existing VPC, vSwitch, NAT, EIP, routes, security groups, and ECS instances
are not Terraform resources in this stack. `tofu destroy` cannot delete them.

There are two lifecycle levels:

- normal test start/stop retains the ACK control plane, both node pools, two
  prepaid baseline workers, the elastic ESS scaling group, and the key pair;
  it creates/releases only elastic workers and the Higress release;
- `tofu destroy` is the explicit final cleanup and removes the retained ACK
  resources as well.

## Test sizing and traffic

- Workers: two prepaid `ecs.u1-c1m2.xlarge` baseline nodes, plus a
  pay-as-you-go elastic pool configured for 0 to 10 nodes. The two controller
  replicas use required hostname anti-affinity. ACK creates elastic nodes only
  when Pods cannot be scheduled on the baseline capacity; 10 is a ceiling, not
  a reserved or pre-created node count.
- Worker disk: 40 GiB ESSD Entry.
- Higress gateway: 4 steady replicas during the customer acceptance window.
  The HPA remains the owner of the Deployment replica field and is pinned at
  4, so it cannot scale down while long requests are under test. Its 225 active
  HTTP requests per Pod signal remains configured for the later restoration of
  a scaling range. Gateway CPU is deliberately
  excluded: plugin initialization is not customer traffic. Controller CPU HPA
  is unchanged. The adapter is required; metric failures must alert rather than
  falling back to CPU. Helm does not write the external HPA's replica count.
- Gateway termination: Kubernetes removes terminating Service endpoints; preStop
  waits 15 seconds for propagation, drains listeners, and polls active business
  HTTP requests for up to 600 seconds. Once they reach zero it allows 2 seconds
  for the configured 1-second access-log flush. Only then does pilot-agent receive
  SIGTERM and drain remaining connections (minimum 5 seconds). This avoids losing
  the last usage log when exit-on-zero terminates Envoy. Pod grace is 660 seconds
  including preStop, a hard bound rather than a promise for unbounded streams.
  Rolling upgrades use maxUnavailable=0, maxSurge=1 and minReadySeconds=10.
  These settings protect ordinary Pod scale-down/rollout; forced deletion,
  node failure, OOM, and requests exceeding the grace are not lossless.
  Existing Pods must be drained before the first upgrade to these settings;
  changing a template cannot retroactively lengthen their termination grace.
  ACK node scale-down allows 900 seconds for Pod termination, longer than the
  gateway grace, so node reclamation does not cut that grace short.
- Higress controller: 2 replicas on different nodes, HPA up to 3 replicas at
  65% CPU. Controller and gateway each have a PDB with `minAvailable: 1`.
- Gateway service: `LoadBalancer`, reusing the persistent pay-by-traffic CLB on
  ports 80 and 443. `ack.tokenvolt.net` routes both the Portal and `/v1` model
  traffic through Higress; the CLB and DNS record are protected from destroy.
- Pod placement: controller replicas use required hostname anti-affinity;
  gateway replicas use hard hostname topology spread with `maxSkew: 1`.
- Network: Terway DataPath V2/eBPF without kube-proxy IPVS/iptables in the Pod
  Service path.
- Observability: a narrow collector remote-writes only allowlisted application
  metrics to ARMS. ACK's full metric-agent/cs-default jobs are not installed.
  `metrics-server` supplies controller CPU HPA; a Helm-managed Prometheus
  Adapter supplies Gateway `higress_active_streams`. Local recording/alerting
  rules, ARMS bridge alerts, an HPA-only state watcher, ACK K8s Event Center,
  and an importable Grafana dashboard are included. Event Center is separate
  from the disabled cs-default metric collection.
  See [OBSERVABILITY_INVENTORY.md](OBSERVABILITY_INVENTORY.md) for the exact
  metric, alert, cardinality, and known-gap boundary.
- ACK automatic scale-down is explicitly configured with a 5-minute trigger
  delay. This affects autoscaler decisions, not deletion of an entire node pool.

The ACK API server is Internet-facing by default so a developer machine can run
the Helm provider during the same `tofu apply`. This endpoint is for Kubernetes
management only; the Higress data-plane service remains cluster-internal. Set
`enable_public_api = false` only when OpenTofu runs from inside the VPC.

## One-time account prerequisite

For an account that has never used ACK, complete ACK **Quick Authorization** in
the Alibaba Cloud console. Node auto scaling additionally needs
`AliyunCSManagedAutoScalerRole` and `AliyunOOSLifecycleHook4CSRole`. These are
account-level, non-billable service roles and intentionally live outside this
disposable stack, so destroying a test cluster does not remove them.

The local CLI profile must be logged in:

```shell
aliyun sts GetCallerIdentity --profile tokenvolt --region cn-beijing
```

## First create or resume

From this directory:

```shell
make init
make plan
make start
```

The encrypted OSS `terraform.tfvars` object is the deployment source of truth.
`make plan`, lifecycle targets, and direct `scripts/tofu.sh plan/apply/destroy`
refuse a locally changed file. Publish an intentional baseline change with
`make config-push`, or discard it with `make config-pull`, before deployment.
The same object records `deployment_baseline_tag`; deployment refuses to run
unless the current Git HEAD resolves to that exact immutable tag. If the tag is
missing or differs, fetch tags and check out the tag printed by the command.

The apply is the complete pull-up operation: ACK, the worker node pools, and
Higress are reconciled in dependency order. Provider versions are pinned in
`.terraform.lock.hcl`.

TokenVolt rate-limit and quota counters use a private pay-as-you-go Alibaba
Cloud Redis instance by default (`redis.master.small.default`, Redis 7). It is
kept while the Kubernetes workloads are stopped. The in-cluster Redis remains
available only as an explicit fallback and must not be enabled together with
managed Redis.

To use a different cluster name or sizing, create an untracked
`terraform.tfvars` file. For example:

```hcl
cluster_name          = "higress-ack"
worker_instance_types = ["ecs.u1-c1m2.xlarge"]
base_node_count       = 2
base_node_period      = 1
base_node_auto_renew  = true
node_min_size         = 0
node_max_size         = 10
```

The baseline pool contains two prepaid, automatically renewed workers. The
elastic pool remains pay-as-you-go and scales from zero to ten. The maximum is
only a ceiling: ACK creates elastic workers only when Pods cannot be scheduled
on the baseline capacity.

## Stop without deleting retained resources

For normal shutdown, remove the Higress Helm release and park the retained
pay-as-you-go elastic pool at a manual desired size of zero:

```shell
make stop
```

This keeps the ACK cluster, the two prepaid baseline workers, the empty elastic
ESS scaling group, and the key pair for reuse while releasing pay-as-you-go
workers. Because prepaid workers remain online, `make stop` is no longer a
zero-compute-cost state.

Resume with:

```shell
make start
```

ACK runs CoreDNS and `cluster-autoscaler` on the prepaid baseline workers. The
elastic pool can therefore remain at zero while `scale_up_from_zero` stays
enabled; no CoreDNS maintenance is required from this stack.

ACK rejects disabling node auto scaling and setting desired size zero in one
request. `make stop` therefore performs two normal OpenTofu applies for the
elastic pool. `make start` re-enables elastic scaling and installs Higress; the
prepaid baseline pool remains present throughout. No direct cloud API mutation
is hidden in the Makefile.

The OpenTofu default lifecycle mode is `running`. While stopped, use `make plan`
only for review and `make start` to resume; a plain `tofu apply` would also
request the running state.

## Verify

`helm_release.higress` waits for the workloads and fails atomically if they do
not become ready. After apply, use an ACK kubeconfig to check:

```shell
kubectl -n higress-system get deploy,pod,svc,hpa
```

Higress creates its port 80 listener only after a matching route exists. The
following disposable route verifies the full in-cluster request path using an
Alibaba Cloud-hosted test image:

```shell
kubectl -n higress-system create ingress gateway-smoke \
  --class=higress \
  --rule='smoke.internal/ready=higress-controller:8888'

kubectl -n higress-system run gateway-smoke --restart=Never \
  --image=registry.cn-hangzhou.aliyuncs.com/acs/busybox:v1.29.2 \
  --command -- wget -S -O /dev/null --header='Host: smoke.internal' \
  http://higress-gateway.higress-system.svc.cluster.local/ready

kubectl -n higress-system wait \
  --for=jsonpath='{.status.phase}'=Succeeded pod/gateway-smoke --timeout=120s
kubectl -n higress-system logs gateway-smoke
kubectl -n higress-system delete pod gateway-smoke
kubectl -n higress-system delete ingress gateway-smoke
```

The expected result is `HTTP/1.1 200 OK` with `server: istio-envoy`.

## Temporary HTTPS certificate

Set `tokenvolt_public_tls_enabled = true` to have OpenTofu create a test-only CA,
issue a 90-day certificate for `tokenvolt_public_host`, store the TLS keypair in
the `tokenvolt-public-tls` Kubernetes Secret, and configure both TokenVolt
Ingresses to terminate TLS in Higress. The CA is valid for one year and the leaf
certificate for 90 days. Private keys live only in sensitive OpenTofu state and
the Kubernetes Secret, never in Helm values or Git.

To trust the public CA on the current macOS user account:

```shell
tofu output -raw tokenvolt_test_ca_certificate > /tmp/tokenvolt-ack-test-ca.pem
security add-trusted-cert -r trustRoot \
  -k /Users/fivechen/Library/Keychains/login.keychain-db \
  /tmp/tokenvolt-ack-test-ca.pem
curl https://ack.tokenvolt.net/healthz
```

This CA is for development only. Replace the Secret with an Alibaba Cloud or
public-CA certificate before exposing production traffic. To remove local trust
later, use Keychain Access to delete `TokenVolt ACK Test CA`.

The MaaS-oriented Gateway/Controller test matrix, measured ACK baseline, and
derived scaling signals are in
[`PERFORMANCE_TEST_PLAN.md`](./PERFORMANCE_TEST_PLAN.md). The reproducible mock
and load generator live under [`performance/`](./performance/).

## T07 upstream connection mitigation

`tokenvolt_neutoken_single_use_clusters` is opt-in and defaults to empty. Set it
only to the exact published McpBridge cluster names whose domain has been
verified as `neutoken.net`. The TokenVolt chart then applies a gateway
EnvoyFilter with `max_requests_per_connection: 1` to those clusters. It leaves
other providers unchanged and does not retry POST requests. Fresh TLS
connections add latency and connection load; monitor the affected routes.

The cluster names contain a hash of the published provider connection. After
republishing a connection, compare the live McpBridge and Envoy `config_dump`
with this list and update the shared OSS tfvars if names changed. Remove the
list to remove the mitigation after the upstream issue is resolved. As with
other ACK changes, sync tfvars from OSS and review the OpenTofu plan before
applying; do not treat local tfvars as the source of truth.

## Final cleanup

```shell
tofu plan -destroy
make destroy
```

OpenTofu removes the Helm release before the node pools and cluster. Both pools
enable `force_delete` because final cluster cleanup uses ACK's separate
asynchronous whole-pool deletion workflow. Deleting prepaid workers does not
refund their remaining subscription term; normal `make stop` therefore retains
the baseline pool. After an explicit final destroy, verify the state is empty:

```shell
tofu state list
```

The VPC/vSwitch/NAT and the separate OSS/TableStore State backend remain by
design. State is stored in the private encrypted OSS backend; any pre-migration
local recovery copy still contains a short-lived kubeconfig and must be treated
as sensitive. State files are ignored by Git.
