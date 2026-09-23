<!--
Copyright 2026 alibaba

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Optional ACK ALB ingress for Higress

This is a separate, opt-in edge for the Higress Gateway HTTP Service. The chart's default `albIngress.enabled=false` renders no ALB resources. Enabling it creates a new `AlbConfig` without an existing ALB ID, a matching `IngressClass`, and an `Ingress` whose backend is the `higress-gateway` Service on port 80. Applying those resources is what asks the ACK ALB Ingress Controller to **provision a new pay-as-you-go ALB**, create its listeners and an ALB server group for the Ingress backend, and keep that group synchronized with the Service's ready backend Pods. Helm rendering alone creates nothing in Alibaba Cloud. The existing CLB-backed `LoadBalancer` Service, its annotations, shared listener, DNS records, and certificates remain as they are during Helm installation.

The ALB server group is a separate cloud resource. A CLB virtual server group cannot be attached to an ALB. The ALB Ingress refers to the Kubernetes Service, **not** the CLB ID or its group: there is no ALB-to-CLB hop. Neither an ALB server-group ID nor a Pod/ENI IP is pinned in values. The ACK ALB Ingress Controller reconciles ALB membership as Gateway endpoints change; ACK CCM continues reconciling the existing CLB group independently. During rollout, compare both cloud groups with the Gateway EndpointSlices after scaling and verify health before changing DNS.

## Public host boundary

| Host | Current public route | This PR |
| --- | --- | --- |
| `api.tokenvolt.net` | Shared CLB → Higress Gateway Service:80 | Only host prepared for the optional ALB Ingress; ACK overlay sets `albIngress.host` to this name. |
| `ack.tokenvolt.net` | Shared CLB → TokenVolt control-plane Service:8000 | Remains on CLB; this Gateway chart must not claim the control-plane host. |
| `www.tokenvolt.net` | Shared CLB → TokenVolt control-plane Service:8000 | Remains on CLB; it shares the control-plane backend with `ack`. |

See [the existing shared edge contract](SHARED_PUBLIC_EDGE.md). Routing `ack` or `www` through ALB would require a separately designed control-plane backend and certificates. This issue covers the Higress Gateway only.

## Prerequisites and activation

1. Confirm the ACK ALB Ingress Controller and `alibabacloud.com/v1` AlbConfig CRD are installed. Confirm the chosen AlbConfig and IngressClass names are unused, and the controller has the required permissions. The default new name is `higress-gateway-alb`; the chart intentionally omits `spec.config.id` so the controller creates a new ALB. If the controller installation already created a default `alb` instance, account for that separately; this chart does not adopt or change it.
2. Obtain two distinct ALB-supported vSwitch IDs in different availability zones of the cluster VPC, with adequate free addresses and connectivity to Gateway Pods. Beijing supports multiple ALB zones and requires at least two vSwitches for a **new ALB instance**. The existing ACK workers and CLB being in one zone does not remove this ALB creation requirement. A single vSwitch is allowed by Alibaba Cloud only in a single-zone ALB region; the two-ID chart contract is intentional for this Beijing deployment. ALB `zoneMappings` are creation-only, so verify IDs before enabling.
3. Obtain a valid ALB Certificate Management Service ID covering `api.tokenvolt.net`. The certificate is bound in `AlbConfig.spec.listeners[HTTPS:443]`, and the Ingress declares the same TLS host. Do not assume the existing CLB certificate ID can be used as the ALB certificate ID; verify the certificate is present and bindable in the ALB region. No certificate private key is placed in Helm values. Confirm renewal ownership before cutover. The CLB certificates for `api`, `ack`, and `www` remain bound throughout the migration.
4. Obtain **both** ALB listener request-timeout and idle-timeout quota increases to at least 900 seconds. The usual maximum is 600 seconds; the 900-second values in `values/higress-test.yaml` will not become usable merely because Helm accepts them. Check other proxies, clients, upstreams, and any WAF in the request chain as well.
5. Review an isolated Helm diff and the current CLB/OpenTofu plan before any deployment. The ACK overlay already specifies `host: api.tokenvolt.net`, `requestTimeout: 900`, and `idleTimeout: 900`, while keeping `enabled: false`. Supply the real vSwitch and certificate IDs through approved deployment configuration and set `enabled=true` only after prerequisites are confirmed. These are desired listener settings, **not proof of a live 900-second ALB**. Do not replace the Gateway Service type, remove its CLB annotations, or alter existing public DNS during Helm installation.

Example **render only** with fictitious values:

```sh
helm template higress helm/core --namespace higress-system \
  -f deploy/ack/values/higress-test.yaml \
  --set albIngress.enabled=true \
  --set albIngress.host=api.example.com \
  --set-json 'albIngress.vSwitchIds=["vsw-zone-a","vsw-zone-b"]' \
  --set albIngress.certificateId=cert-example
```

The ALB listeners are HTTP:80 and HTTPS:443 with configurable `requestTimeout` and `idleTimeout`; the ACK overlay sets both to 900 seconds. HTTP redirects to HTTPS. The ACK overlay configures ALB health checks against each Gateway Pod agent at port 15020, GET `/healthz/ready`, matching the existing CLB data-rule check, rather than probing a model route on port 80. Confirm actual ALB backend health before cutover. These listener timeouts apply to every route on this new ALB listener.

## Staged creation and DNS cutover

No cloud creation or DNS change is authorized by this PR. For a separately approved rollout:

1. Record current `api.tokenvolt.net` A-record ID, answer, and TTL; OpenTofu currently declares `alicloud_alidns_record.model_api` as an A record pointing to CLB with TTL **600 seconds**. Back up the current OSS-synchronized configuration/state by the existing ACK workflow and review plans. Do not modify the public record while installing Helm.
2. After quota, network, certificate, and controller checks, enable the ALB values in an isolated reviewed release. Confirm `AlbConfig.status` reports the new ALB ID and DNS name, both listeners really report 900-second request and idle timeouts, and the controller-created ALB server group has healthy Gateway backends matching EndpointSlices. The CLB group must remain healthy independently. If the cloud API rejects 900, leave DNS on CLB; do not lower the requested timeout silently.
3. Before live cutover, test HTTPS with `api.tokenvolt.net` Host/SNI against the ALB endpoint using a controlled resolver or `curl --connect-to`; run the response, SSE, long-request, health, and scaling checks below. Verify the ALB's `api` certificate chain. Keep `ack` and `www` on CLB and smoke-test them separately.
4. Plan the `api` DNS switch **separately** from Helm. The current OpenTofu resource owns an A record, while Alibaba Cloud recommends a CNAME to the ALB DNS name. The DNS change must update or safely replace that managed record without a duplicate A/CNAME, respect its `prevent_destroy` guard, and have its own reviewed plan and rollback. Do not make an untracked console edit that a later OpenTofu apply would reverse. If a 60-second TTL is desired, change the old CLB record's TTL in a separate approved step, then wait at least its **previous 600-second TTL** before switching the answer. Otherwise plan for at least 600 seconds of mixed old/new resolution after cutover. Some resolvers cache longer, so keep both edges healthy until observed propagation is complete; a fixed 600-second wait is not proof for every client.
5. Change only `api.tokenvolt.net` to the ALB DNS target after validation. Check authoritative and several recursive resolvers, real client request IDs, and both ALB and CLB traffic during the cache window. Keep CLB listeners, API group, and its certificate serving while old cached A answers exist. Do not change `ack` or `www` DNS.

## Post-deployment validation before DNS cutover

Keep the CLB and public DNS unchanged while testing the new ALB address with a test host or `curl --resolve`. Record the AlbConfig/controller status, ALB listener configuration and quotas, Ingress address, Gateway Service and EndpointSlice membership, and ALB backend health. Do not count a successful Helm release as proof that the controller accepted 900 seconds.

| Scenario | Required observation |
| --- | --- |
| Normal response | HTTPS and certificate chain valid; authorized model request returns expected status/body; unauthenticated request is rejected by Higress, not bypassed. HTTP redirects to HTTPS. |
| SSE | Stream stays open with expected events and final event; record time to first event, last event, and any disconnect. Test an inter-event gap near the intended idle bound if the upstream can provide one. |
| Long non-streaming | A controlled authorized request lasting more than 180 seconds and less than 900 seconds completes without ALB 504; compare request ID, upstream, Higress and ALB logs. A 900-second ALB setting alone does not guarantee the upstream or Gateway permits this duration. |
| Health check | ALB reports healthy backends for GET `/healthz`; intentionally unavailable Gateway endpoints become unhealthy without routing user traffic to them. |
| Gateway scaling | Scale up and down under controlled traffic; compare EndpointSlices and ALB backend membership before/after, and confirm new requests succeed with no fixed Pod IP. Existing in-flight requests may still end when a Pod terminates: the current Gateway drain/grace budget is 660 seconds, shorter than 900 seconds. Validate that limitation separately before promising uninterrupted 900-second requests during scale-down. |

The ALB certificate must be attached and tested **before** DNS cutover. A later ALB certificate rotation updates `albIngress.certificateId` through a reviewed Helm release and is validated on the ALB address before retiring the old ALB certificate. This does not rotate the separate CLB certificates.

## Rollback

If the ALB path fails after DNS cutover, restore the prior managed DNS target to the unchanged CLB through a reviewed DNS change and confirm normal requests, SSE, and health through CLB. Its 180-second request ceiling still applies. Keep the ALB and CLB working through the rollback cache window; some clients may continue to use the old ALB answer until their resolver cache expires. Record ALB controller events and status. Only after DNS no longer directs clients to ALB, disable `albIngress.enabled` in an approved Helm release and confirm the new ALB resources are removed or reconcile their deletion protection separately; verify the existing Gateway Service, CLB listener, backend group, and unrelated DNS are unchanged. Do not remove the existing public Service or edit the shared CLB listeners to roll back this feature.

ACK references: [create and expose ALB Ingress](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/create-and-use-alb-ingress-to-expose-services-to-the-public), [AlbConfig zone requirements](https://www.alibabacloud.com/help/en/ack/serverless-kubernetes/user-guide/use-albconfigs-to-configure-alb-instances), [ALB supported Beijing zones](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/regions-and-zones-supported-by-alb), [configure listener and request timeout](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/configure-the-alb-listener-through-the-albconfig), [ALB configuration fields and health annotations](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/alb-ingress-configuration-dictionary), [DNS propagation and TTL](https://www.alibabacloud.com/help/en/dns/pubz-parse-effective-time-faq).
