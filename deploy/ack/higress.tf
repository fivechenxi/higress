# Copyright 2026 alibaba
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This namespace and plugin credentials outlive Helm releases. Retained CRs
# may reference private Wasm modules before the control plane has restarted.
resource "kubernetes_namespace_v1" "higress" {
  metadata { name = "higress-system" }
  lifecycle { prevent_destroy = true }
}

resource "helm_release" "higress" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name             = "higress"
  namespace        = kubernetes_namespace_v1.higress.metadata[0].name
  create_namespace = false
  chart            = "${path.module}/../../helm/core"

  values = [
    file("${path.module}/values/higress-test.yaml"),
    yamlencode({
      albIngress = {
        enabled        = var.higress_alb_ingress_enabled
        host           = var.tokenvolt_data_public_host
        vSwitchIds     = var.higress_alb_vswitch_ids
        certificateId  = var.higress_alb_certificate_id
        requestTimeout = var.higress_alb_request_timeout
        idleTimeout    = var.higress_alb_idle_timeout
      }
      gateway = {
        service = {
          # Shared mode terminates TLS at CLB and forwards HTTP to Higress.
          # Explicit group reuse lets CCM track autoscaling without owning 80/443.
          ports = local.shared_public_edge ? [
            { name = "http2", port = 80, protocol = "TCP", targetPort = 80 }
            ] : [
            { name = "http2", port = 80, protocol = "TCP", targetPort = 80 },
            { name = "https", port = 443, protocol = "TCP", targetPort = 443 }
          ]
          annotations = merge({
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-id"                       = alicloud_slb_load_balancer.higress_public.id
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners" = local.shared_public_edge ? "false" : "true"
            }, local.shared_public_edge ? {
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-vgroup-port" = "${alicloud_slb_server_group.ack_http[0].id}:80"
          } : {})
        }
      }
    })
  ]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  lifecycle {
    precondition {
      condition = !var.higress_alb_ingress_enabled || (
        var.ack_alb_ingress_controller_enabled &&
        length(var.higress_alb_vswitch_ids) == 2 &&
        length(distinct(var.higress_alb_vswitch_ids)) == 2 &&
        trimspace(var.higress_alb_certificate_id) != ""
      )
      error_message = "Higress ALB ingress requires the managed controller, two distinct vSwitch IDs, and a Certificate Management Service CertIdentifier."
    }
  }

  depends_on = [
    alicloud_cs_kubernetes_node_pool.baseline,
    alicloud_cs_kubernetes_node_pool.gateway,
    alicloud_slb_load_balancer.higress_public,
    kubernetes_secret_v1.tokenvolt_registry_higress,
    terraform_data.alb_ingress_ready,
  ]
}
