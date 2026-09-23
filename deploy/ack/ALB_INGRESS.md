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

This is a separate, opt-in edge for the Higress Gateway HTTP Service. The chart's default `albIngress.enabled=false` renders no ALB resources. Enabling it renders a new `AlbConfig`, matching `IngressClass`, and an `Ingress` whose backend is the `higress-gateway` Service on port 80. The ACK ALB Ingress Controller owns backend synchronization from that Service and its changing endpoints. No Pod address is configured in the chart. The existing CLB-backed `LoadBalancer` Service, its annotations, shared listener, DNS records, and certificates remain as they are during installation.

## Prerequisites and activation

1. Confirm the ACK ALB Ingress Controller and `alibabacloud.com/v1` AlbConfig CRD are installed. Confirm the chosen AlbConfig and IngressClass names are unused, and the controller has the required permissions. The default new name is `higress-gateway-alb`; do not reuse an existing ALB's AlbConfig because Helm would then own its listeners.
2. Obtain two distinct ALB-supported vSwitch IDs in different availability zones of the cluster VPC. Confirm the new ALB's Internet address and capacity are appropriate.
3. Obtain a valid ALB certificate ID for the public host. The certificate is bound in `AlbConfig.spec.listeners[HTTPS:443]`, and the Ingress declares the same TLS host. No certificate private key is placed in Helm values. Confirm renewal ownership before cutover.
4. Obtain **both** ALB listener request-timeout and idle-timeout quota increases to at least 900 seconds. The usual maximum is 600 seconds; the 900-second values in `values/higress-test.yaml` will not become usable merely because Helm accepts them. Check other proxies, clients, upstreams, and any WAF in the request chain as well.
5. Review an isolated Helm diff and the current CLB/OpenTofu plan before any deployment. Fill `albIngress.host`, `albIngress.vSwitchIds`, and `albIngress.certificateId` through the approved deployment configuration. Set `albIngress.enabled=true` only after the prerequisites are confirmed. Do not replace the Gateway Service type, remove its CLB annotations, or alter existing public DNS during Helm installation.

Example **render only** with fictitious values:

```sh
helm template higress helm/core --namespace higress-system \
  -f deploy/ack/values/higress-test.yaml \
  --set albIngress.enabled=true \
  --set albIngress.host=api.example.com \
  --set-json 'albIngress.vSwitchIds=["vsw-zone-a","vsw-zone-b"]' \
  --set albIngress.certificateId=cert-example
```

The ALB listeners are HTTP:80 and HTTPS:443 with configurable `requestTimeout` and `idleTimeout`; the ACK overlay sets both to 900 seconds. HTTP redirects to HTTPS. The Ingress uses GET `/healthz` and accepts 2xx for backend health. Confirm the path on the selected Gateway image before cutover. These listener timeouts apply to every route on this new ALB listener.

## Post-deployment validation before DNS cutover

Keep the CLB and public DNS unchanged while testing the new ALB address with a test host or `curl --resolve`. Record the AlbConfig/controller status, ALB listener configuration and quotas, Ingress address, Gateway Service and EndpointSlice membership, and ALB backend health. Do not count a successful Helm release as proof that the controller accepted 900 seconds.

| Scenario | Required observation |
| --- | --- |
| Normal response | HTTPS and certificate chain valid; authorized model request returns expected status/body; unauthenticated request is rejected by Higress, not bypassed. HTTP redirects to HTTPS. |
| SSE | Stream stays open with expected events and final event; record time to first event, last event, and any disconnect. Test an inter-event gap near the intended idle bound if the upstream can provide one. |
| Long non-streaming | A controlled authorized request lasting more than 180 seconds and less than 900 seconds completes without ALB 504; compare request ID, upstream, Higress and ALB logs. A 900-second ALB setting alone does not guarantee the upstream or Gateway permits this duration. |
| Health check | ALB reports healthy backends for GET `/healthz`; intentionally unavailable Gateway endpoints become unhealthy without routing user traffic to them. |
| Gateway scaling | Scale up and down under controlled traffic; compare EndpointSlices and ALB backend membership before/after, and confirm new requests succeed with no fixed Pod IP. Existing in-flight requests may still end when a Pod terminates: the current Gateway drain/grace budget is 660 seconds, shorter than 900 seconds. Validate that limitation separately before promising uninterrupted 900-second requests during scale-down. |

After all checks, make any DNS cutover as a separately reviewed operation. Preserve the CLB path until business acceptance and rollback readiness are confirmed.

## Rollback

If the ALB path fails after DNS cutover, first restore the prior DNS target to the unchanged CLB and confirm normal requests, SSE, and health through CLB. Its 180-second request ceiling still applies. Then disable `albIngress.enabled` in an approved Helm release to remove only the new ALB Ingress, IngressClass, and AlbConfig; verify the existing Gateway Service, CLB listener, backend group, and unrelated DNS are unchanged. Do not remove the existing public Service or edit the shared CLB listeners to roll back this feature. Record ALB controller events and status before cleanup for diagnosis.

ACK references: [create and expose ALB Ingress](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/create-and-use-alb-ingress-to-expose-services-to-the-public), [configure listener and request timeout](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/configure-the-alb-listener-through-the-albconfig), [ALB configuration fields and health annotations](https://www.alibabacloud.com/help/en/ack/ack-managed-and-ack-dedicated/user-guide/alb-ingress-configuration-dictionary).
