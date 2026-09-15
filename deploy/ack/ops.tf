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

resource "random_password" "grafana_admin" {
  count = var.grafana_enabled ? 1 : 0

  length           = 24
  special          = true
  override_special = "_%@-"
}

locals {
  grafana_public_host = var.tokenvolt_split_public_entry ? var.tokenvolt_data_public_host : var.tokenvolt_public_host
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = var.lifecycle_mode == "running" && var.grafana_enabled ? 1 : 0

  metadata {
    name      = "higress-grafana-admin"
    namespace = "higress-system"
  }

  data = {
    "admin-user"     = var.grafana_admin_user
    "admin-password" = random_password.grafana_admin[0].result
  }

  type = "Opaque"

  depends_on = [helm_release.higress]
}

resource "kubernetes_secret_v1" "grafana_sls" {
  count = var.lifecycle_mode == "running" && var.tokenvolt_enabled && var.grafana_enabled ? 1 : 0

  metadata {
    name      = "higress-grafana-sls"
    namespace = "higress-system"
  }

  data = {
    "access-key-id"     = alicloud_ram_access_key.grafana_sls[0].id
    "access-key-secret" = alicloud_ram_access_key.grafana_sls[0].secret
  }

  type = "Opaque"

  depends_on = [helm_release.higress]
}

resource "kubernetes_secret_v1" "feishu_alert_webhook" {
  count = var.lifecycle_mode == "running" && var.feishu_alert_webhook_url != "" ? 1 : 0

  metadata {
    name      = "higress-feishu-alert-webhook"
    namespace = "higress-system"
  }

  data = {
    "webhook-url" = var.feishu_alert_webhook_url
  }

  type       = "Opaque"
  depends_on = [helm_release.higress]
}

resource "helm_release" "higress_ack_ops" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name      = "higress-ack-ops"
  namespace = "higress-system"
  chart     = "${path.module}/charts/higress-ack-ops"
  version   = yamldecode(file("${path.module}/charts/higress-ack-ops/Chart.yaml")).version

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    yamlencode({
      # Helm does not notice edits below an unchanged local chart path.
      chartContentHash = sha256(join("", [for file in sort(fileset("${path.module}/charts/higress-ack-ops", "**")) : filesha256("${path.module}/charts/higress-ack-ops/${file}")]))
      monitoring = {
        remoteWriteUrl = local.prometheus_remote_write_url
        clusterId      = alicloud_cs_managed_kubernetes.this.id
        grafana = {
          enabled       = var.grafana_enabled
          prometheusUrl = var.prometheus_query_url
          prometheusAuth = {
            existingSecret = var.prometheus_query_url == "" ? "" : "higress-prometheus-query"
          }
          host           = local.grafana_public_host
          rootUrl        = "${var.tokenvolt_public_tls_enabled ? "https" : "http"}://${local.grafana_public_host}/grafana/"
          existingSecret = "higress-grafana-admin"
          sls = {
            enabled        = var.tokenvolt_enabled
            existingSecret = "higress-grafana-sls"
            endpoint       = "${var.region}-intranet.log.aliyuncs.com"
            project        = local.tokenvolt_sls_project
            logstore       = local.tokenvolt_sls_logstore
          }
        }
        alerting = {
          enabled = true
          feishu = {
            enabled        = var.feishu_alert_webhook_url != ""
            existingSecret = "higress-feishu-alert-webhook"
          }
        }
        quotaMetrics = {
          enabled = var.tokenvolt_enabled && var.tokenvolt_rate_limit_redis_enabled
        }
      }
    })
  ]

  depends_on = [
    terraform_data.prometheus_auth_free_write,
    terraform_data.prometheus_query_credentials,
    kubernetes_annotations.terway_cilium_metrics_rollout,
    kubernetes_secret_v1.grafana_admin,
    kubernetes_secret_v1.grafana_sls,
    kubernetes_secret_v1.feishu_alert_webhook,
    helm_release.higress,
  ]
}
