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

locals {
  terway_cilium_args = "--prometheus-serve-addr=:9962"
  prometheus_remote_write_url = format(
    "https://workspace-default-cms-%s-%s.%s-intranet.log.aliyuncs.com/prometheus/workspace-default-cms-%s-%s/aliyun-prom-%s/api/v1/write",
    data.alicloud_account.current.id,
    var.region,
    var.region,
    data.alicloud_account.current.id,
    var.region,
    alicloud_cs_managed_kubernetes.this.id,
  )
  terway_cni_config = merge(
    jsondecode(data.kubernetes_config_map_v1.terway.data["10-terway.conf"]),
    { cilium_args = local.terway_cilium_args },
  )
}

data "alicloud_account" "current" {}

# Create only the managed ARMS storage/query environment. Do not install the
# metric-agent feature: the feature always enables ACK's non-discardable base
# collection jobs (API server, etcd, kubelet/cAdvisor, node-exporter, KSM and
# CoreDNS), even when the cs-default add-on release itself is absent.
resource "alicloud_arms_environment" "prometheus" {
  bind_resource_id     = alicloud_cs_managed_kubernetes.this.id
  environment_name     = var.cluster_name
  environment_type     = "CS"
  environment_sub_type = "ManagedKubernetes"
  managed_type         = "none"
  aliyun_lang          = "zh"
  tags                 = var.tags

  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}

# Detailed rules are evaluated by the bounded in-cluster collector and their
# ALERTS series is remote-written with the application metrics. ARMS owns two
# bridge rules: one forwards every firing application alert, while the second
# remains evaluable when the collector itself disappears.
locals {
  prometheus_bridge_alerts = {
    application = {
      duration   = 1
      expression = "ALERTS{ack_cluster=\"${alicloud_cs_managed_kubernetes.this.id}\",alertstate=\"firing\",severity=~\"warning|critical\"} == 1"
      message    = "A TokenVolt Higress application alert is firing. Inspect the alertname, component, model and provider labels."
    }
    collector_missing = {
      duration   = 5
      expression = "absent(up{ack_cluster=\"${alicloud_cs_managed_kubernetes.this.id}\",job=\"higress-metrics-collector\"} == 1)"
      message    = "The Higress metrics collector has not remote-written its own health series for five minutes. Gateway HPA metrics may be unavailable."
    }
  }
}

resource "alicloud_arms_prometheus_alert_rule" "higress" {
  for_each = var.lifecycle_mode == "running" && var.prometheus_alerts_enabled ? local.prometheus_bridge_alerts : {}

  cluster_id                 = alicloud_cs_managed_kubernetes.this.id
  duration                   = each.value.duration
  expression                 = each.value.expression
  message                    = each.value.message
  prometheus_alert_rule_name = "tokenvolt-higress-${replace(each.key, "_", "-")}"
  notify_type                = var.prometheus_alert_dispatch_rule_id == "" ? "ALERT_MANAGER" : "DISPATCH_RULE"
  dispatch_rule_id           = var.prometheus_alert_dispatch_rule_id == "" ? null : var.prometheus_alert_dispatch_rule_id

  depends_on = [alicloud_arms_environment.prometheus]
}

# ARMS V2 supports password-free Remote Write from a CIDR allowlist. The
# provider does not yet expose these UpdatePrometheusInstance fields, so keep
# this one API call inside the OpenTofu graph. The allowlist is the reused VPC
# CIDR, never 0.0.0.0/0. No AK/SK is stored in Kubernetes or Terraform state.
resource "terraform_data" "prometheus_auth_free_write" {
  triggers_replace = [
    alicloud_cs_managed_kubernetes.this.id,
    data.alicloud_vpcs.selected.vpcs[0].cidr_block,
    var.vpc_id,
  ]

  provisioner "local-exec" {
    command = "aliyun cms update-prometheus-instance --api-version 2024-03-30 --prometheus-instance-id $PROM_CLUSTER_ID --enable-auth-free-write true --auth-free-write-policy $PROM_WRITE_POLICY --region $PROM_REGION --profile $ALICLOUD_PROFILE"
    environment = {
      PROM_REGION     = var.region
      PROM_CLUSTER_ID = alicloud_cs_managed_kubernetes.this.id
      PROM_WRITE_POLICY = jsonencode({
        SourceIp  = [data.alicloud_vpcs.selected.vpcs[0].cidr_block]
        SourceVpc = [var.vpc_id]
      })
      ALICLOUD_PROFILE = var.alicloud_profile
    }
  }

  depends_on = [alicloud_arms_environment.prometheus]
}

# The ACK cluster-create API records CiliumArgs in the add-on metadata but does
# not materialize it in the CNI configuration consumed by terway-cli. Terway
# reads cilium_args from the JSON stored in 10-terway.conf (not from a top-level
# ConfigMap key), so read ACK's generated JSON, preserve all of its fields and
# merge only the metrics argument into that document.
data "kubernetes_config_map_v1" "terway" {
  metadata {
    name      = "eni-config"
    namespace = "kube-system"
  }

  depends_on = [alicloud_cs_kubernetes_node_pool.gateway]
}

resource "kubernetes_config_map_v1_data" "terway_cilium_metrics" {
  metadata {
    name      = "eni-config"
    namespace = "kube-system"
  }

  data = {
    "10-terway.conf" = jsonencode(local.terway_cni_config)
  }

  field_manager = "higress-ack-opentofu"
  force         = true

  depends_on = [alicloud_cs_kubernetes_node_pool.gateway]
}

# Terway reads cilium_args only at process start. A deterministic pod-template
# annotation gives initial installs and later argument changes one declarative
# rolling restart without replacing the ACK-managed DaemonSet.
resource "kubernetes_annotations" "terway_cilium_metrics_rollout" {
  api_version = "apps/v1"
  kind        = "DaemonSet"

  metadata {
    name      = "terway-eniip"
    namespace = "kube-system"
  }

  template_annotations = {
    "higress.io/cilium-config-sha256" = sha256(jsonencode(local.terway_cni_config))
  }

  field_manager = "higress-ack-opentofu"
  force         = true

  depends_on = [kubernetes_config_map_v1_data.terway_cilium_metrics]
}
