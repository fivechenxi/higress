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

resource "helm_release" "higress" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name             = "higress"
  namespace        = "higress-system"
  create_namespace = true
  chart            = "${path.module}/../../helm/core"

  values = [
    file("${path.module}/values/higress-test.yaml"),
    yamlencode({
      gateway = {
        service = {
          annotations = {
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-id"                       = alicloud_slb_load_balancer.higress_public.id
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners" = "true"
          }
        }
      }
    })
  ]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  depends_on = [
    alicloud_cs_kubernetes_node_pool.gateway,
    alicloud_slb_load_balancer.higress_public,
  ]
}
