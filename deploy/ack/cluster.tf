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

resource "alicloud_cs_managed_kubernetes" "this" {
  name         = var.cluster_name
  cluster_spec = var.cluster_spec
  profile      = "Default"
  version      = var.kubernetes_version

  vswitch_ids     = [var.vswitch_id]
  pod_vswitch_ids = [var.vswitch_id]
  service_cidr    = var.service_cidr
  node_cidr_mask  = 24

  new_nat_gateway      = false
  slb_internet_enabled = var.enable_public_api
  deletion_protection  = false
  enable_rrsa          = true
  timezone             = "Asia/Shanghai"

  addons {
    name = "terway-eniip"
    config = jsonencode({
      # ACK retains IPVlan as the cluster-creation compatibility switch for
      # shared-ENI acceleration. Terway >= 1.8 materializes it as DataPath V2,
      # not the retired IPvlan datapath.
      IPVlan        = "true"
      NetworkPolicy = "true"
      CiliumArgs    = local.terway_cilium_args
    })
  }

  addons {
    name   = "metrics-server"
    config = ""
  }

  dynamic "addons" {
    for_each = var.tokenvolt_enabled ? [1] : []
    content {
      name = "logtail-ds"
      config = jsonencode({
        IngressDashboardEnabled = "false"
        sls_project_name        = alicloud_log_project.tokenvolt[0].project_name
      })
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.base_node_count >= 2 && var.node_min_size >= 0 && var.node_max_size > var.node_min_size
      error_message = "The stack needs at least two prepaid baseline workers, and elastic node_max_size must be greater than node_min_size."
    }
  }

  depends_on = [data.alicloud_vswitches.selected]
}

# Manage this post-creation addon independently. Putting it in the cluster's
# creation-time addons set makes an existing cluster credential unknown during
# planning, which also prevents the Kubernetes and Helm providers from reading
# their current resources.
resource "alicloud_cs_kubernetes_addon" "pod_identity" {
  count      = var.tokenvolt_enabled ? 1 : 0
  cluster_id = alicloud_cs_managed_kubernetes.this.id
  name       = "ack-pod-identity-webhook"
  version    = "0.4.4"
  config = jsonencode({
    AutoInjectSTSEnvVars = true
  })
}

# ACK's kube-eventer persists HPA and workload Events in the K8s Event Center.
# Manage it after cluster creation so adding event history to an existing ACK
# cluster cannot broaden the cluster-create addons diff or replace the cluster.
# This component is independent from the disabled cs-default metric jobs.
resource "alicloud_cs_kubernetes_addon" "event_center" {
  count      = var.tokenvolt_enabled && var.hpa_event_center_enabled ? 1 : 0
  cluster_id = alicloud_cs_managed_kubernetes.this.id
  name       = "ack-node-problem-detector"
  config = jsonencode({
    sls_project_name = alicloud_log_project.tokenvolt[0].project_name
  })
}

# Keep the ALB control loop ACK-managed. The addon installs the controller and
# AlbConfig CRD; Helm owns only the workload-specific AlbConfig/Ingress objects.
resource "alicloud_cs_kubernetes_addon" "alb_ingress" {
  count      = var.ack_alb_ingress_controller_enabled ? 1 : 0
  cluster_id = alicloud_cs_managed_kubernetes.this.id
  name       = "alb-ingress-controller"
  version    = "v3.1.1"
  config     = ""

  lifecycle {
    prevent_destroy = true
  }
}

# The addon API can complete before its Kubernetes objects are observable.
# Do not let Helm submit AlbConfig until the CRD and controller are ready.
resource "terraform_data" "alb_ingress_ready" {
  count = var.ack_alb_ingress_controller_enabled ? 1 : 0

  triggers_replace = [
    alicloud_cs_kubernetes_addon.alb_ingress[0].id,
    alicloud_cs_kubernetes_addon.alb_ingress[0].version,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      set -eu
      kubeconfig_file=$(mktemp)
      trap 'rm -f "$kubeconfig_file"' EXIT HUP INT TERM
      printf '%s' "$KUBECONFIG_CONTENT" > "$kubeconfig_file"
      deadline=$(( $(date +%s) + 600 ))
      until kubectl --kubeconfig "$kubeconfig_file" get crd albconfigs.alibabacloud.com >/dev/null 2>&1; do
        test "$(date +%s)" -lt "$deadline"
        sleep 5
      done
      kubectl --kubeconfig "$kubeconfig_file" wait --for=condition=Established crd/albconfigs.alibabacloud.com --timeout=10m
      controller=""
      until test -n "$controller"; do
        test "$(date +%s)" -lt "$deadline"
        controller=$(kubectl --kubeconfig "$kubeconfig_file" -n kube-system get deployment -o name | awk '/alb-ingress-controller/ {print; exit}')
        test -n "$controller" || sleep 5
      done
      test -n "$controller"
      kubectl --kubeconfig "$kubeconfig_file" -n kube-system rollout status "$controller" --timeout=10m
    EOT
    environment = {
      KUBECONFIG_CONTENT = data.alicloud_cs_cluster_credential.this.kube_config
    }
  }

  depends_on = [alicloud_cs_kubernetes_addon.alb_ingress]
}

resource "alicloud_key_pair" "workers" {
  key_pair_name = "${var.cluster_name}-workers"
  tags          = var.tags
}
