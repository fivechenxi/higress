# Messages cache usage presence repair

## Evidence and scope

The October 7 successful Qianfan requests `as-y7t93z5kvz` and
`as-whf42xntt4` logged input/output/total 15/16/31. The October 9 request
`as-5wkpdze7ht` logged 31/81/112. All three used the customer Messages path,
completed normally, and logged null cache counts and input details.

The current matching production routes use an OpenAI provider with custom URL
`https://qianfan.baidubce.com/v2`, not Qianfan's native Messages endpoint.
The loaded ai-proxy digest `c8f75dda0a8560d62e3e375ea41d29b32527743f803b2e82f6a95545d0361f9b`
has OSS source commit metadata `5d0f21793016765c87fa182f67a4038fa1ac2d5e`.
That converter's integer cache fields with `omitempty` lose explicit zero.
The statistics cache builtin also only recognized the OpenAI `cached_tokens`
details key, not the Messages `cache_read_input_tokens` key.

These are gateway defects, not proof that the three historical upstream
responses explicitly reported zero. The access logs do not retain the original
upstream usage. Messages total usage can be reconstructed by the statistics
SDK. Even an original OpenAI total equal to prompt plus completion does not
prove a cache miss: prompt=100, completion=20, total=120, cached=60 is valid
because cached tokens are a subset of the OpenAI prompt count.

## Changes

- Preserve optional OpenAI cache read counts as pointers through non-streaming
  and streaming Messages conversion: explicit zero survives; absent/null
  remains absent. Keep existing cache-hit input subtraction and Bedrock behavior.
- Record Messages cache reads in `ai_log.cached_tokens` and cache-hit metrics,
  including explicit zero. Cache creation is not relabeled as cache reads.
- Recognize nested `message_start` cache counts and preserve them through a
  later delta without cache fields. Reject null, negative, fractional and
  nonnumeric Messages cache counts instead of accepting the SDK's zero coercion.
- Do not change control-plane classification, provider-specific parameters,
  customer prices, historical records or production plugin configuration.

## Verification

- Conversion regression first failed on a dropped explicit zero, then passed
  for zero, cache hit, absent, empty details, null details and null cache counts
  in both non-streaming and streaming modes.
- Statistics regressions first failed on missing zero/hit logs. The final
  regressions passed in both native Go and compiled-Wasm test hosts, including
  unknown/invalid counts and message_start cache retention.
- ai-proxy provider and util suites passed; both plugin modules' Go-mode tests
  passed with `go test ./... -run '/go' -count=1`.
- ai-statistics `go vet ./...` passed. ai-proxy vet reports pre-existing JSON
  tags on unexported fields in context/failover/provider/retry; these files are
  unchanged. Broad all-mode suites were stopped while CPU-bound, so a full
  all-Wasm suite pass is not claimed.
- No live inference probes, Envoy multi-filter-chain run, merge, release,
  deployment or historical billing backfill. No frontend interaction change.

Before deployment, review and publish immutable artifacts for both changed
plugins. Production confirmation must check the loaded digests and future
usage evidence; disappearance of a 48-hour alert is not historical repair.
