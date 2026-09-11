# TokenVolt on ACK + Higress integration plan

Status: design baseline, 2026-09-11

## Goal and isolation boundary

Deploy an independent TokenVolt stack inside the disposable ACK cluster and
use the self-managed Higress release as both the Portal ingress and the model
data plane. The existing ECS deployment, Alibaba Cloud Serverless AI Gateway,
managed NLB, production databases, and public DNS remain unchanged.

The first ACK deployment uses a fresh managed RDS PostgreSQL database,
internal-only test hosts, test tenants and test credentials. It is a
production-shaped environment: after acceptance it is promoted by switching
traffic, not rebuilt or migrated. Production data is not copied and
`www.tokenvolt.net` / `api.tokenvolt.net` are not switched during validation.

## Data classification and durability boundary

PostgreSQL is the authoritative business store, not a cache. It contains
tenants, users, password hashes, encrypted MFA material, sessions, immutable
audit events, irreversible API-key verifiers and lifecycle state, model grants,
gateway publication history, hourly usage aggregates, reconciliation records,
billing periods and payment state, immutable usage-close snapshots, and the
OSS object key/version/checksum for each bill. Losing it revokes practical
access to existing customer keys and loses the accounting/audit chain, so it
must not share the ACK or Helm release lifecycle.

Raw request-level usage is retained in SLS. RDS stores the reconciled hourly
ledger by tenant/key/model, while bill file bytes are stored in a private OSS
bucket and RDS stores their indexes and checksums. Prometheus metrics are for
operations and autoscaling only; they are never billing evidence.

The current SLS query is still tied to Alibaba APIG fields (`consumer`,
`ai_log.*`) and only `/chat/completions`. Before acceptance, Higress access
logs must be delivered to SLS with a stable schema (or the adapter changed) for
OpenAI Chat/Responses and Anthropic Messages, including request ID, actual
provider/model, status, input/output/cache tokens and completeness markers.
High-cardinality exact usage belongs in SLS/RDS, not Prometheus.

Billing is currently operator-driven rather than scheduled. Although the
product convention is a monthly period, the API accepts any explicit period up
to 366 days. An administrator creates the draft, enters the contract amount,
uploads a PDF/XLSX/CSV, and publishes it; publication creates the immutable
usage-close snapshot. No timer automatically creates a monthly receivable.

SLS receives request records continuously, but the Portal reads hourly RDS
aggregates rather than a real-time request list. At minute 10 of every hour the
worker recalculates the most recent 48 complete hours, and at 02:30 Asia/Shanghai
it recalculates the previous business day. A restart automatically catches up
the 48-hour window; older hour-aligned ranges can be replayed manually while
the source logs remain in SLS.

This permits one control-plane replica initially. A brief outage delays the
Portal, key/model changes and aggregation, but it does not interrupt inference,
lose raw usage or miss an automatic billing deadline. RDS, SLS, OSS and the
Higress gateway carry the availability requirement. Before increasing the
control plane above one replica, serialize startup migrations; the usage worker
itself already uses PostgreSQL leases to prevent duplicate jobs.

## Verified current implementation

The TokenVolt control plane publishes policy by calling the Kubernetes API
directly over HTTPS with its pod ServiceAccount. It creates or updates one
Higress resource:

```text
extensions.higress.io/v1alpha1 / WasmPlugin
```

The update uses `metadata.resourceVersion` as a compare-and-swap token, retries
three conflicts, reads the resource back, and only then marks the policy
revision active in PostgreSQL. The published snapshot contains public model
IDs, irreversible SHA-256 API-key verifiers, consumer IDs and per-consumer
model grants. It contains no cleartext customer key or provider credential.

The custom `tokenvolt-policy` Wasm filter runs in `AUTHN` at priority 900. It
authenticates a customer key, serves the filtered OpenAI model catalog, checks
the requested model and writes trusted consumer/model headers. The inference
request does not call the Portal or PostgreSQL.

## Gaps that block a standalone ACK deployment

1. API-key create, rotate and revoke still require the Alibaba APIG adapter.
   When the APIG environment variables are absent, the Portal deliberately
   returns 503 for all key-management endpoints. A local/Higress credential
   adapter is required so that PostgreSQL is the desired state and the policy
   publisher is the data-plane reconciliation mechanism.
2. The publisher currently creates a global WasmPlugin with no `matchRules`.
   On a shared Higress gateway it would require a TokenVolt bearer key on the
   Portal and on unrelated routes. The plugin must be scoped to the model API
   ingress.
3. The policy filter authorizes only `/v1/chat/completions` and `/v1/responses`.
   Higress ai-proxy supports `/v1/messages`, but TokenVolt does not yet enforce
   tenant model grants for that Anthropic endpoint or accept the Anthropic
   `x-api-key` credential form.
4. `deploy/higress/production-route-gate.yaml` points at the placeholder
   `tokenvolt-ai-router` Service. There is no production implementation of that
   Service and no versioned manifest for the real provider services, model
   rewrites, primary/fallback policy or provider Secrets.
5. Database migrations use a check-then-run sequence without a global migration
   lock. Starting multiple fresh control-plane replicas concurrently can race
   on DDL. The test release starts one replica; multi-replica application rollout
   is gated on migration serialization.
6. The existing image workflow publishes GHCR images from a feature branch.
   ACK nodes have no public egress, so immutable control-plane and Wasm artifacts
   must be mirrored to an Alibaba Cloud registry reachable through the VPC.

## ACK target topology

```text
client/test pod
    |
    v
Higress gateway (ClusterIP during the test)
    |-- portal.tokenvolt.internal/* --------> tokenvolt-control-plane:8000
    `-- api.tokenvolt.internal/v1/*
          |-- tokenvolt-policy Wasm (tenant auth/catalog/grants)
          |-- Higress model/provider routing and ai-proxy
          `-- HTTPS provider services

tokenvolt-control-plane (one replica initially)
    |-- private endpoint -> RDS PostgreSQL 16 High-availability Edition
    |-- SLS private endpoint -> raw gateway usage
    |-- OSS private endpoint -> immutable bill objects
    `-- ServiceAccount -> kubernetes.default.svc -> scoped WasmPlugin
```

ACK nodes and RDS are both placed in Beijing zone L and reuse the existing
`vs-bj-az-L` vSwitch. RDS starts at the lowest available 2-vCPU/4-GiB
high-availability specification with 20-GiB ESSD PL1, SSL enabled, 90-day
daily and log backups/PITR, 12 monthly archived backups, and deletion
protection. This intentionally
costs more than Serverless Basic: PostgreSQL Serverless in Beijing is Basic
Edition and is not an acceptable promotion target because it lacks the needed
log-backup/PITR guarantee. The primary and standby remain in one zone because
multi-zone disaster recovery is explicitly deferred.

The Portal and model API use separate Ingress objects so the policy plugin can
be attached only to the latter. Provider keys live in Kubernetes Secrets and
are injected into the appropriate provider plugin configuration; they are not
placed in Terraform values, Git, the policy snapshot or logs.

## Implementation sequence

### Phase 1: make TokenVolt self-contained

- Add an explicit `CREDENTIAL_PROVIDER=higress` mode backed by a local
  `GatewayControlPlane` adapter. Create/rotate/revoke remain transactional in
  PostgreSQL and become effective when the 10-second Higress publisher updates
  the policy CR.
- Add a required model-ingress selector to the Higress adapter and publish the
  snapshot under `spec.matchRules`; disable the global default configuration.
- Add `/v1/messages` model authorization and safe handling of `x-api-key`, with
  protocol-shaped errors and regression tests.
- Serialize migrations before allowing more than one control-plane replica.

### Phase 2: package the complete ACK application

- Add a TokenVolt Helm chart containing Namespace, control-plane
  Deployment/Service, ServiceAccount/RBAC, two Ingress objects,
  NetworkPolicies, PodDisruptionBudget and optional ServiceMonitor.
- Keep database and application Secret material external to the chart. RDS is
  managed by OpenTofu and accessed only through its VPC endpoint. Move long
  lived secrets from OpenTofu state to KMS/Secrets Manager plus RRSA before
  public traffic is enabled.
- Add the TokenVolt chart as an optional ACK release. `make start`, `make stop`
  and `make destroy` must cover TokenVolt in dependency order. The existing VPC
  and vSwitch remain outside lifecycle management.

### Phase 3: build the model data path

- Register Bailian, Suheai and Neutoken as DNS/static Higress services.
- When the database has never been initialized, mount a Helm-generated
  bootstrap document plus the existing provider credential Secret into the
  control plane. Seed PostgreSQL once through the normal encrypted gateway
  configuration service, then make PostgreSQL the sole desired-state source.
  Restarts must never overwrite administrator changes.
- Once the gateway publisher is enabled, stop rendering the legacy static
  route objects. The TokenVolt reconciler owns only resources labeled
  `tokenvolt.ai/managed=gateway-config`; Higress controller remains responsible
  for translating those resources into Envoy xDS.
- Attach immutable ai-proxy configuration per provider and keep public model
  IDs separate from provider model IDs (`glm-5.2` -> `GLM-5.2`, etc.).
- Reproduce the current primary/fallback intent: Kimi uses Neutoken then
  Suheai; GLM uses Suheai then Bailian; Qwen uses Bailian. Do not enable
  retries after streaming output has begun.
- Start with a deterministic fixture and fake provider Secrets. Add real
  provider credentials only after the authorization path passes.

### Phase 4: acceptance gates

- Bootstrap a test administrator and two tenants; create, rotate and revoke
  keys entirely without Alibaba APIG.
- Verify each tenant sees only its model subset through `/v1/models`; reject
  unknown, unauthorized, revoked and spoofed identities.
- Verify non-streaming and streaming OpenAI requests, then Anthropic Messages,
  including provider model rewrites and fallback-before-first-token behavior.
- Stop the control plane while retaining RDS and confirm already-published
  inference remains available.
- Confirm Portal routes are not subject to the model API Wasm filter and that
  logs/metrics contain no key, prompt or response body.
- Feed the existing Higress AI metrics into the ACK Prometheus allowlist and
  exercise gateway HPA with the established active-stream and CPU policies.

## Stop, destroy and production migration

Normal stop removes the TokenVolt and Higress releases before parking the node
pool at zero. RDS, SLS and OSS remain online because they contain authoritative
or accounting data. RDS deletion protection is enabled by default; deleting
the data layer requires an explicit, separately reviewed operation after a
verified backup/restore exercise. The reused VPC/vSwitch remain outside the
stack lifecycle.

Promotion is a later traffic operation, not a rebuild: add externally managed
Secrets, public TLS and a load-balancer overlay, then move traffic gradually
from the existing Serverless AI Gateway. Retain DNS rollback throughout the
canary and keep the old ECS/APIG stack unchanged until billing reconciliation
and recovery gates have passed.
