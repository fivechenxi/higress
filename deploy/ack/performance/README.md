# ACK performance harness

`llm-bench` is a standard-library-only Go binary with four commands:

- `server`: deterministic OpenAI and Anthropic JSON/SSE mock;
- `load`: closed-loop load with total-latency and TTFB percentiles;
- `routes`: one Ingress containing a configurable number of host rules;
- `probe`: poll a newly added route and report convergence time.

The committed manifest uses only internal `ClusterIP` Services and the Alibaba
Cloud busybox image. It creates the isolated `higress-performance` namespace.

Build the ACK binary and create the harness:

```shell
GOCACHE=/tmp/higress-go-cache CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o /tmp/llm-bench ./deploy/ack/performance/cmd/llm-bench
kubectl apply -f deploy/ack/performance/ack-manifest.yaml
kubectl -n higress-performance rollout status deploy/llm-mock
kubectl -n higress-performance rollout status deploy/load-generator
```

Copy `/tmp/llm-bench` into both Pods, make it executable, and start the mock:

```shell
kubectl -n higress-performance cp /tmp/llm-bench POD_NAME:/tmp/llm-bench
kubectl -n higress-performance exec POD_NAME -- chmod +x /tmp/llm-bench
kubectl -n higress-performance exec MOCK_POD -- /tmp/llm-bench server
```

Use `http://llm-mock:8080` for the direct baseline. Use
`http://higress-gateway.higress-system.svc.cluster.local` with
`-host=llm-perf.internal` for the Gateway path. Example:

```shell
/tmp/llm-bench load \
  -url=http://higress-gateway.higress-system.svc.cluster.local/v1/chat/completions \
  -host=llm-perf.internal -protocol=openai -stream \
  -concurrency=100 -duration=60s
```

Remove every temporary object without stopping Higress or ACK:

```shell
kubectl delete namespace higress-performance
```

See [`../PERFORMANCE_TEST_PLAN.md`](../PERFORMANCE_TEST_PLAN.md) for the full
matrix, validity rules, measured baseline, and HPA decisions.
