# Gateway scaling and termination regression

Run the policy contracts from the repository root:

```sh
uv run --with pyyaml python deploy/ack/tests/test_gateway_policy.py
```

The runtime test uses a dedicated ingress class and namespace. It creates no
public LoadBalancer, has no customer credentials, and never calls a model vendor.
The fixture returns a delayed normal response and SSE stream with exactly
20 input / 20 output / 40 total tokens. The pinned ai-statistics plugin checks
that each complete response produces exactly one final usage log.

Use a test cluster and an explicitly selected kubeconfig:

```sh
export KUBECONFIG=/path/to/test-kubeconfig
helm upgrade --install higress-drain-test helm/core \
  --namespace higress-drain-test --create-namespace \
  -f deploy/ack/tests/canary-values.yaml --wait --timeout 180s
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
  -o /tmp/drain-fixture deploy/ack/tests/drain_fixture.go
kubectl apply -f deploy/ack/tests/drain-fixture.yaml
kubectl -n higress-drain-test wait --for=condition=Ready pod/drain-fixture --timeout=90s
kubectl -n higress-drain-test cp /tmp/drain-fixture drain-fixture:/tmp/drain-fixture
python3 deploy/ack/tests/drain_runtime.py --kubeconfig "$KUBECONFIG" \
  --case scale --seconds 40 --output /tmp/drain-scale
kubectl -n higress-drain-test scale deployment/higress-gateway --replicas=2
python3 deploy/ack/tests/drain_runtime.py --kubeconfig "$KUBECONFIG" \
  --case rollout --seconds 60 --output /tmp/drain-rollout
helm uninstall higress-drain-test -n higress-drain-test --wait
kubectl delete namespace higress-drain-test
```

For ARM nodes build GOARCH=arm64 instead. Allow the statistics plugin to finish
loading before running the test. The test waits for both requests to actually
reach the upstream before it scales down or restarts the Deployment. Clients run
inside the cluster and target the chosen Pod directly, so terminating a kubectl
port-forward cannot create a false truncation failure. Scale-down uses the same
Deployment/ReplicaSet Pod termination path as HPA. It does not simulate an HPA
threshold crossing or a physical node failure.

On 2026-09-12 the unchanged chart truncated both 20-second requests at ~5.9s;
pilot-agent logged `Graceful termination period is 5s`. After the fix, both
40-second scale-down requests and both 60-second rolling-upgrade requests
completed and emitted exactly one complete usage log each. The agent explicitly
waited for two active connections and exited only after they reached zero.
Sanitized structured evidence is in `../evidence/drain-evidence-20260912.json`. No Qianfan
usage is involved in this fixture test.

## First production migration

Old Pods retain their old grace/lifecycle. Do not simply update the template and
assume existing requests are protected. Back up Helm values and infrastructure
state, switch the gateway HPA to business requests, and bring up two temporary
gateway replicas with the new drain settings and the same gateway/service labels.
Verify readiness and auth behavior before removing old Pods from traffic.

Temporarily add the bridge label to the Service selector, and verify its ready
endpoints contain only bridge Pods. The current pilot-agent readiness probe may
keep returning 200 after `/healthcheck/fail`; do not rely on it for this manual
migration. For each old Pod, POST `/healthcheck/fail` and
`/drain_listeners?graceful&skip_exit` on localhost port 15000, then verify business
`envoy_http_downstream_rq_active` is zero and allow access logs to flush. Keep the
bridge serving until the managed Helm release has two updated, available replicas.
Select only the updated managed Pod template hash in the Service and verify two
ready endpoints. Drain the bridge explicitly, wait for zero requests and log
flush, then delete it. Restore the original Service selector after bridge Pods
are gone. This also protects a bridge created before the final drain policy.
If draining or upgrade fails, retain the healthy bridge while investigating.

Normal future scale-down and rollouts use Kubernetes terminating endpoints plus
preStop: allow 15 seconds for propagation, drain listeners and wait for business
requests to reach zero, then allow 2 seconds for the default 1-second log flush.
The subsequent pilot-agent minimum drain is another 5 seconds. Waiting only in
pilot-agent with EXIT_ON_ZERO_ACTIVE_CONNECTIONS was insufficient: a repeated
60-second test returned both responses but lost one buffered usage log. The
preStop request drain and flush window fixes that separately reproduced race.

The infrastructure plan must be limited to the Higress and ACK-ops Helm releases
and the ACK autoscaler termination timeout. Tenant grants, API keys, and billing
state are outside this migration. Rollback should retain the new graceful
termination envelope; restoring the previous five-second policy recreates the
original defect. Force deletion, OOM/node failure, and requests longer than the
660-second Pod grace remain outside the graceful termination guarantee.
