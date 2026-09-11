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

resource "helm_release" "higress_ack_ops" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name      = "higress-ack-ops"
  namespace = "higress-system"
  chart     = "${path.module}/charts/higress-ack-ops"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    yamlencode({
      monitoring = {
        remoteWriteUrl = local.prometheus_remote_write_url
        clusterId      = alicloud_cs_managed_kubernetes.this.id
      }
    })
  ]

  depends_on = [
    terraform_data.prometheus_auth_free_write,
    kubernetes_annotations.terway_cilium_metrics_rollout,
    helm_release.higress,
  ]
}
