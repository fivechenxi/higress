# Interrupted response metadata and accounting repair

The TokenVolt owner reported that the Higress maintainer confirmed these changes may proceed directly and explicitly requested merge, release, and a 100-request test using another model. This user authorization resolves the previously pending implementation gate for this TokenVolt fork. Codex assisted implementation and validation; this is not an assertion of independent upstream issue-spec approval or a credential-based maintainer exception.

## Behavior

- Persist `requested_model` and the fallback `model` when the request body arrives. Keep prompts and output bodies out of lightweight logs.
- Extract `chat_id` and response `model` from complete framed SSE events, including IDs split over callbacks. Preserve `upstream_request_id` from response headers when available.
- Track `response_completed` from explicit protocol completion events; persist `response_error` for SSE/application errors. A downstream disconnect after protocol completion does not itself make the model response incomplete.
- Preserve independently reported scalar usage; absent/null/invalid values do not become invented zeros. A total is derived only when both input/output dimensions are known. Retain cache details without summing repeated usage snapshots.
- `usage_status` describes available dimensions (`missing`, `partial`, `complete`), while `response_completed` separately describes response completion. It does not claim that upstream usage exists when generation was cancelled.
- Persist metadata/available usage on callbacks and stream teardown. Finalization shares an idempotent metric guard, including aborted-request token/cache counters.
- Control-plane SLS aggregation ignores DC as a failure only when the response was explicitly completed and no other failure flag/error is present. Historical logs without new metadata retain conservative classification.

## Verification

`go test -run 'TestInterrupted|TestUsageThenDone' -count=1 ./...` first failed for missing model/ID, fabricated output zero and missing completion marker. The fixes pass these tests in both Go and Wasm host execution. `go test -count=1 ./...` passed (96.932s), including existing SSE fragmentation/panic passthrough, cache and error cases. Control-plane completed-stream SQL regression first failed before the completed/error-aware predicates were added.

An upstream that never supplies usage before cancellation still cannot yield exact tokens from these logs. No tokenizer estimation, delayed artificial generation, or response-body logging is introduced. The deployment and 100-request provider reconciliation are recorded separately after runtime validation.
