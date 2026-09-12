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

## Lifecycle boundary

OpenTofu creates and destroys only:

- one ACK Basic managed cluster (`ack.standard`);
- one pay-as-you-go elastic worker node pool;
- one ECS SSH key pair used by that node pool;
- one Higress Helm release and its Kubernetes objects.

It reuses these existing resources as read-only inputs:

- VPC `vpc-2ze8x9jglv9rug2n2a5z4`;
- vSwitch `vsw-2zex87nrlhukk0mlgricd` in `cn-beijing-k`;
- the existing NAT/SNAT path attached to that VPC.

The existing VPC, vSwitch, NAT, EIP, routes, security groups, and ECS instances
are not Terraform resources in this stack. `tofu destroy` cannot delete them.

There are two lifecycle levels:

- normal test start/stop retains the ACK control plane, node pool, ESS scaling
  group, and key pair, and only creates/releases the billable workers and the
  Higress release;
- `tofu destroy` is the explicit final cleanup and removes the retained ACK
  resources as well.

## Test sizing and traffic

- Workers: `ecs.u1-c1m2.xlarge`, pay-as-you-go, 1 configured minimum and 3
  maximum. A running Higress installation requires at least 2 because the two
  controller replicas use required hostname anti-affinity. Controller HPA,
  failover, or a rolling update can temporarily request the third worker.
- Worker disk: 40 GiB ESSD Entry.
- Higress gateway: 2 replicas minimum, HPA up to 4 using 225 active HTTP
  requests per Pod (normal and streaming requests). Gateway CPU is deliberately
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
  `metrics-server` supplies CPU HPA and a Helm-managed upstream Prometheus
  Adapter supplies `higress_active_streams`; adapter failure is alerted for
  manual handling.
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

The apply is the complete pull-up operation: ACK, the worker node pool, and
Higress are reconciled in dependency order. Provider versions are pinned in
`.terraform.lock.hcl`.

To use a different cluster name or sizing, create an untracked
`terraform.tfvars` file. For example:

```hcl
cluster_name          = "higress-ack"
worker_instance_types = ["ecs.u1-c1m2.xlarge"]
node_min_size         = 1
node_max_size         = 3
```

## Stop without deleting the free control resources

For normal test shutdown, remove the Higress Helm release and park the retained
node pool at a manual desired size of zero:

```shell
make stop
```

This keeps the ACK cluster, node pool, empty ESS scaling group, and key pair for
reuse while releasing the pay-as-you-go workers. The ACK API server's public
endpoint may still have a small load-balancer-related cost; disable it and run
OpenTofu inside the VPC if a completely internal management path is available.

Resume with:

```shell
make start
```

ACK runs both CoreDNS and `cluster-autoscaler` on worker nodes in this topology.
The live ACK configuration keeps `skip_nodes_with_system_pods` and
`scale_up_from_zero` enabled, so the only automatic node pool cannot remain at
zero: its own system Pods either prevent scale-down or wake it again. No CoreDNS
maintenance is required from this stack, but parking all workers therefore
requires temporarily disabling node auto scaling.

ACK also rejects disabling node auto scaling and setting desired size zero in
one request. `make stop` performs two normal OpenTofu applies: first uninstall
Higress and disable automatic scaling, then set desired size zero. `make start`
first restores the base worker, then enables automatic scaling and installs
Higress. No direct cloud API mutation is hidden in the Makefile.

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

## Final cleanup

```shell
tofu plan -destroy
make destroy
```

OpenTofu removes the Helm release before the node pool and cluster. The node
pool enables `force_delete` because this is a disposable environment and ACK's
normal pod-drain path can take more than ten minutes when deleting the only
node pool. In live testing, ACK still took about eleven minutes to delete the
node pool because whole-pool deletion follows a separate asynchronous cloud
workflow; the 5-minute autoscaler trigger delay does not shorten it. Afterward,
verify the state is empty:

```shell
tofu state list
```

The VPC/vSwitch/NAT remain by design. A local `terraform.tfstate` contains a
short-lived kubeconfig and must be treated as sensitive; state files are ignored
by Git. Use a remote encrypted backend before this becomes a shared environment.
