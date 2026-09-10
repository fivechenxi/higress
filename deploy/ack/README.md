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

- Workers: `ecs.e-c1m2.xlarge`, pay-as-you-go, 1 configured minimum and 3
  maximum. ACK may temporarily scale to 2 because its two CoreDNS replicas use
  required hostname anti-affinity.
- Worker disk: 40 GiB ESSD Entry.
- Higress gateway: 2 replicas, HPA up to 4 replicas at 65% CPU.
- Gateway service: `ClusterIP`; there is no Higress public or internal CLB yet.
- Pod placement: soft hostname anti-affinity. Two replicas can run on one worker
  during cheap testing and spread when another worker is added.
- Network: Flannel; the existing NAT provides image-pull and upstream egress.
- Observability: no SLS, ARMS, or Nginx Ingress add-on is requested by this
  stack. ACK 1.36 installs its baseline CSI components even without persistent
  volumes. `metrics-server` is requested because the HPA needs it.
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
cluster_name          = "higress-ack-test"
worker_instance_types = ["ecs.e-c1m2.xlarge"]
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
