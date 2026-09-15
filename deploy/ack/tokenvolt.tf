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

resource "random_password" "tokenvolt_database" {
  count = var.tokenvolt_enabled ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "tokenvolt_totp_master_key" {
  count   = var.tokenvolt_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "tokenvolt_api_key_pepper" {
  count   = var.tokenvolt_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "tokenvolt_rate_limit_redis" {
  count       = var.tokenvolt_enabled && var.tokenvolt_managed_redis_enabled ? 1 : 0
  length      = 32
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

locals {
  tokenvolt_sls_project  = "tokenvolt-gateway-${data.alicloud_account.current.id}"
  tokenvolt_sls_logstore = "model-access"
  tokenvolt_oss_bucket   = "tokenvolt-billing-${data.alicloud_account.current.id}-${var.region}"
  tokenvolt_rrsa_role    = "tokenvolt-control-plane-${var.cluster_name}"
  tokenvolt_rate_limit_enabled = (
    var.tokenvolt_enabled &&
    (var.tokenvolt_managed_redis_enabled || var.tokenvolt_rate_limit_redis_enabled)
  )
  tokenvolt_rate_limit_redis_host     = var.tokenvolt_managed_redis_enabled ? alicloud_kvstore_instance.tokenvolt_rate_limit[0].connection_domain : "tokenvolt-rate-limit-redis.${var.tokenvolt_namespace}.svc.cluster.local"
  tokenvolt_rate_limit_service_name   = var.tokenvolt_managed_redis_enabled ? "${local.tokenvolt_rate_limit_redis_host}.dns" : local.tokenvolt_rate_limit_redis_host
  tokenvolt_rate_limit_redis_port     = var.tokenvolt_managed_redis_enabled ? alicloud_kvstore_instance.tokenvolt_rate_limit[0].port : 6379
  tokenvolt_rate_limit_redis_password = var.tokenvolt_managed_redis_enabled ? random_password.tokenvolt_rate_limit_redis[0].result : ""
}

resource "alicloud_kvstore_instance" "tokenvolt_rate_limit" {
  count = var.tokenvolt_enabled && var.tokenvolt_managed_redis_enabled ? 1 : 0

  db_instance_name = "tokenvolt-rate-limit-${var.cluster_name}"
  instance_type    = "Redis"
  instance_class   = var.tokenvolt_managed_redis_class
  # redis.master.small.default is the smallest postpaid master-replica class
  # available in the selected zone. It is a local-disk class and supports 5.0.
  engine_version = "5.0"
  payment_type   = "PostPaid"
  zone_id        = var.availability_zone
  vswitch_id     = var.vswitch_id
  password       = random_password.tokenvolt_rate_limit_redis[0].result
  security_ips   = [data.alicloud_vpcs.selected.vpcs[0].cidr_block]
  ssl_enable     = "Disable"
  tags           = merge(var.tags, { Component = "tokenvolt-rate-limit" })
}

check "tokenvolt_redis_mode" {
  assert {
    condition     = !(var.tokenvolt_managed_redis_enabled && var.tokenvolt_rate_limit_redis_enabled)
    error_message = "Enable either managed Redis or the in-cluster Redis fallback, not both."
  }
}

resource "alicloud_log_project" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  project_name = local.tokenvolt_sls_project
  description  = "Authoritative raw model access records for TokenVolt usage reconciliation"
  tags         = merge(var.tags, { Component = "tokenvolt-usage" })

  lifecycle {
    # ACK's logtail add-on adds its cluster ownership tag to this project.
    # Preserve that provider-managed tag instead of removing it on every apply.
    ignore_changes = [tags]
  }
}

resource "alicloud_log_store" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  project_name          = alicloud_log_project.tokenvolt[0].project_name
  logstore_name         = local.tokenvolt_sls_logstore
  retention_period      = 180
  shard_count           = 2
  auto_split            = true
  max_split_shard_count = 16
  append_meta           = true
  hot_ttl               = 30
  infrequent_access_ttl = 30
}

resource "alicloud_log_store_index" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  project  = alicloud_log_project.tokenvolt[0].project_name
  logstore = alicloud_log_store.tokenvolt[0].logstore_name

  dynamic "field_search" {
    for_each = {
      "consumer"                         = "text"
      "path"                             = "text"
      "request_id"                       = "text"
      "route_name"                       = "text"
      "start_time"                       = "text"
      "upstream_cluster"                 = "text"
      "ai_log.model"                     = "text"
      "ai_log.requested_model"           = "text"
      "ai_log.chat_id"                   = "text"
      "ai_log.upstream_request_id"       = "text"
      "ai_log.response_completed"        = "text"
      "ai_log.response_error"            = "text"
      "ai_log.usage_status"              = "text"
      "ai_log.provider_rate_limit_event" = "text"
      "ai_log.rate_limit_evaluation"     = "text"
      "response_code"                    = "long"
      "response_flags"                   = "text"
      "ai_log.input_token"               = "long"
      "ai_log.output_token"              = "long"
      "ai_log.total_token"               = "long"
      "ai_log.cached_tokens"             = "long"
      "ai_log.llm_first_token_duration"  = "double"
      "ai_log.llm_service_duration"      = "double"
    }
    content {
      name             = field_search.key
      type             = field_search.value
      enable_analytics = true
      case_sensitive   = true
    }
  }
}

resource "alicloud_oss_bucket" "tokenvolt_billing" {
  count = var.tokenvolt_enabled ? 1 : 0

  bucket          = local.tokenvolt_oss_bucket
  storage_class   = "Standard"
  redundancy_type = "ZRS"
  force_destroy   = false
  tags            = merge(var.tags, { Component = "tokenvolt-billing" })

  versioning {
    status = "Enabled"
  }

  server_side_encryption_rule {
    sse_algorithm = "AES256"
  }
}

resource "alicloud_oss_bucket_acl" "tokenvolt_billing" {
  count = var.tokenvolt_enabled ? 1 : 0

  bucket = alicloud_oss_bucket.tokenvolt_billing[0].bucket
  acl    = "private"
}

resource "alicloud_oss_bucket_worm" "tokenvolt_billing" {
  count = var.tokenvolt_enabled && var.tokenvolt_oss_worm_enabled ? 1 : 0

  bucket                   = alicloud_oss_bucket.tokenvolt_billing[0].bucket
  retention_period_in_days = 3650
}

resource "alicloud_ram_role" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  role_name   = local.tokenvolt_rrsa_role
  description = "RRSA role for TokenVolt SLS usage reads and OSS billing objects"
  force       = true
  tags        = var.tags
  assume_role_policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Federated = [alicloud_cs_managed_kubernetes.this.rrsa_metadata[0].ram_oidc_provider_arn]
      }
      Condition = {
        StringEquals = {
          "oidc:iss" = alicloud_cs_managed_kubernetes.this.rrsa_metadata[0].rrsa_oidc_issuer_url
          "oidc:aud" = "sts.aliyuncs.com"
          "oidc:sub" = "system:serviceaccount:${var.tokenvolt_namespace}:tokenvolt-control-plane"
        }
      }
    }]
  })
}

resource "alicloud_ram_policy" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  policy_name = "tokenvolt-data-${var.cluster_name}"
  description = "Least privilege access to TokenVolt usage Logstore and billing bucket"
  force       = true
  policy_document = jsonencode({
    Version = "1"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["log:GetLogStoreLogs", "log:GetHistograms"]
        Resource = ["acs:log:${var.region}:${data.alicloud_account.current.id}:project/${local.tokenvolt_sls_project}/logstore/${local.tokenvolt_sls_logstore}"]
      },
      {
        Effect   = "Allow"
        Action   = ["oss:ListObjects"]
        Resource = ["acs:oss:*:${data.alicloud_account.current.id}:${local.tokenvolt_oss_bucket}"]
      },
      {
        Effect   = "Allow"
        Action   = ["oss:GetObject", "oss:PutObject"]
        Resource = ["acs:oss:*:${data.alicloud_account.current.id}:${local.tokenvolt_oss_bucket}/*"]
      }
    ]
  })
}

resource "alicloud_ram_role_policy_attachment" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  role_name   = alicloud_ram_role.tokenvolt[0].role_name
  policy_name = alicloud_ram_policy.tokenvolt[0].policy_name
  policy_type = "Custom"
}

# The upstream Grafana SLS datasource does not support ACK RRSA credentials.
# Give Grafana a dedicated read-only RAM user instead of reusing the control
# plane role or any operator credential. The AK is stored only in Terraform
# state and a Kubernetes Secret and is never rendered into a ConfigMap.
resource "alicloud_ram_user" "grafana_sls" {
  count = var.tokenvolt_enabled && var.grafana_enabled ? 1 : 0

  name         = "tokenvolt-grafana-sls-${var.cluster_name}"
  display_name = "TokenVolt Grafana SLS reader"
  comments     = "Read-only model-access dashboard credential"
  force        = true
}

resource "alicloud_ram_access_key" "grafana_sls" {
  count = var.tokenvolt_enabled && var.grafana_enabled ? 1 : 0

  user_name = alicloud_ram_user.grafana_sls[0].name
}

resource "alicloud_ram_policy" "grafana_sls" {
  count = var.tokenvolt_enabled && var.grafana_enabled ? 1 : 0

  policy_name = "tokenvolt-grafana-sls-${var.cluster_name}"
  description = "Read-only access to the TokenVolt request detail Logstore"
  force       = true
  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect   = "Allow"
      Action   = ["log:GetLogStoreLogs", "log:GetHistograms"]
      Resource = ["acs:log:${var.region}:${data.alicloud_account.current.id}:project/${local.tokenvolt_sls_project}/logstore/${local.tokenvolt_sls_logstore}"]
      },
      {
        Effect   = "Allow"
        Action   = ["log:GetProject", "log:ListLogStores"]
        Resource = ["acs:log:${var.region}:${data.alicloud_account.current.id}:project/${local.tokenvolt_sls_project}"]
    }]
  })
}

resource "alicloud_ram_user_policy_attachment" "grafana_sls" {
  count = var.tokenvolt_enabled && var.grafana_enabled ? 1 : 0

  user_name   = alicloud_ram_user.grafana_sls[0].name
  policy_name = alicloud_ram_policy.grafana_sls[0].policy_name
  policy_type = "Custom"
}

resource "alicloud_db_instance" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  engine                   = "PostgreSQL"
  engine_version           = "16.0"
  category                 = "HighAvailability"
  instance_type            = "pg.n2m.2c.2m"
  instance_charge_type     = "Postpaid"
  instance_storage         = 20
  db_instance_storage_type = "cloud_essd"
  instance_name            = "tokenvolt-ack"
  vpc_id                   = var.vpc_id
  vswitch_id               = var.tokenvolt_rds_vswitch_id
  zone_id                  = data.alicloud_vswitches.tokenvolt_rds[0].vswitches[0].zone_id
  security_ips             = [data.alicloud_vpcs.selected.vpcs[0].cidr_block]
  deletion_protection      = var.tokenvolt_rds_deletion_protection
  ssl_action               = "Open"
  tags                     = merge(var.tags, { Component = "tokenvolt-database" })

}

resource "alicloud_rds_account" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  db_instance_id      = alicloud_db_instance.tokenvolt[0].id
  account_name        = "tokenvolt"
  account_password    = random_password.tokenvolt_database[0].result
  account_type        = "Normal"
  account_description = "TokenVolt application account"
}

resource "alicloud_db_database" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  instance_id    = alicloud_db_instance.tokenvolt[0].id
  data_base_name = "tokenvolt"
  character_set  = "UTF8"
  description    = "TokenVolt authoritative application database"
}

resource "alicloud_db_account_privilege" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  instance_id  = alicloud_db_instance.tokenvolt[0].id
  account_name = alicloud_rds_account.tokenvolt[0].account_name
  db_names     = [alicloud_db_database.tokenvolt[0].data_base_name]
  privilege    = "DBOwner"
}

resource "alicloud_db_backup_policy" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  instance_id                 = alicloud_db_instance.tokenvolt[0].id
  backup_retention_period     = 90
  enable_backup_log           = true
  enable_pitr_protection      = true
  log_backup_retention_period = 90
  archive_backup_keep_policy  = "ByMonth"
  released_keep_policy        = "Lastest"
  preferred_backup_period     = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
  preferred_backup_time       = "18:00Z-19:00Z"
}

resource "kubernetes_namespace_v1" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  metadata {
    name = var.tokenvolt_namespace
    labels = {
      "app.kubernetes.io/part-of"               = "tokenvolt"
      "app.kubernetes.io/managed-by"            = "opentofu"
      "pod-identity.alibabacloud.com/injection" = "on"
    }
  }

  depends_on = [alicloud_cs_kubernetes_node_pool.gateway]
}

resource "kubernetes_secret_v1" "tokenvolt_database" {
  count = var.tokenvolt_enabled ? 1 : 0

  metadata {
    name      = "tokenvolt-database"
    namespace = kubernetes_namespace_v1.tokenvolt[0].metadata[0].name
  }

  data = {
    username = "tokenvolt"
    password = random_password.tokenvolt_database[0].result
    database = "tokenvolt"
    url      = "postgres://tokenvolt:${random_password.tokenvolt_database[0].result}@${alicloud_db_instance.tokenvolt[0].connection_string}:${alicloud_db_instance.tokenvolt[0].port}/tokenvolt?sslmode=require"
  }
}

resource "kubernetes_secret_v1" "tokenvolt_app" {
  count = var.tokenvolt_enabled ? 1 : 0

  metadata {
    name      = "tokenvolt-app"
    namespace = kubernetes_namespace_v1.tokenvolt[0].metadata[0].name
  }

  data = {
    totpMasterKeyB64 = base64encode(random_password.tokenvolt_totp_master_key[0].result)
    apiKeyPepperB64  = base64encode(random_password.tokenvolt_api_key_pepper[0].result)
  }
}

resource "kubernetes_secret_v1" "tokenvolt_registry" {
  count = var.tokenvolt_enabled ? 1 : 0

  metadata {
    name      = "tokenvolt-ghcr"
    namespace = kubernetes_namespace_v1.tokenvolt[0].metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = var.tokenvolt_ghcr_username
          password = var.tokenvolt_ghcr_token
          auth     = base64encode("${var.tokenvolt_ghcr_username}:${var.tokenvolt_ghcr_token}")
        }
      }
    })
  }

  lifecycle {
    precondition {
      condition     = var.tokenvolt_ghcr_token != ""
      error_message = "tokenvolt_ghcr_token is required when TokenVolt private GHCR images are enabled."
    }
  }
}

# Higress converts WasmPlugin CRs only from the controller namespace. Keep a
# registry credential there for private TokenVolt plugin images.
resource "kubernetes_secret_v1" "tokenvolt_registry_higress" {
  count = var.tokenvolt_enabled ? 1 : 0

  metadata {
    name      = "tokenvolt-ghcr"
    namespace = kubernetes_namespace_v1.higress.metadata[0].name
  }
  type = kubernetes_secret_v1.tokenvolt_registry[0].type
  data = kubernetes_secret_v1.tokenvolt_registry[0].data

}

resource "helm_release" "tokenvolt" {
  count = var.tokenvolt_enabled && var.lifecycle_mode == "running" ? 1 : 0

  name      = "tokenvolt"
  namespace = kubernetes_namespace_v1.tokenvolt[0].metadata[0].name
  chart     = "${path.module}/charts/tokenvolt"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    yamlencode({
      # The Helm provider does not detect edits beneath an unchanged chart path.
      chartContentHash = sha256(join("", [for file in sort(fileset("${path.module}/charts/tokenvolt", "**")) : filesha256("${path.module}/charts/tokenvolt/${file}")]))
      controlPlane = {
        image = var.tokenvolt_control_plane_image
        publicService = {
          enabled = var.tokenvolt_split_public_entry
          annotations = var.tokenvolt_split_public_entry ? {
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-id"                       = alicloud_slb_load_balancer.higress_public.id
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners" = "false"
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-vgroup-port"              = "${try(alicloud_slb_server_group.portal_http[0].id, "")}:8000"
            "service.beta.kubernetes.io/backend-type"                                        = "eni"
          } : {}
        }
        rrsaRoleName               = alicloud_ram_role.tokenvolt[0].role_name
        allowedOrigin              = var.tokenvolt_public_host != "" ? "${var.tokenvolt_public_tls_enabled ? "https" : "http"}://${var.tokenvolt_public_host}" : ""
        allowInsecureSessionCookie = var.tokenvolt_public_host != "" && !var.tokenvolt_public_tls_enabled
        cloud = {
          slsRegionId = var.region
          slsEndpoint = "${var.region}-intranet.log.aliyuncs.com"
          slsProject  = alicloud_log_project.tokenvolt[0].project_name
          slsLogstore = alicloud_log_store.tokenvolt[0].logstore_name
          ossRegionId = var.region
          ossEndpoint = "https://oss-${var.region}-internal.aliyuncs.com"
          ossBucket   = alicloud_oss_bucket.tokenvolt_billing[0].bucket
        }
      }
      higress = {
        namespace          = "higress-system"
        policyPluginUrl    = var.tokenvolt_policy_plugin_url
        policyPluginSha256 = var.tokenvolt_policy_plugin_sha256
        imagePullSecret    = kubernetes_secret_v1.tokenvolt_registry_higress[0].metadata[0].name
        policyIngress      = "${var.tokenvolt_namespace}/tokenvolt-model-api"
        gatewayConfigPublisher = {
          enabled = var.tokenvolt_gateway_config_publisher_enabled
        }
        aiStatistics = {
          enabled      = true
          pluginUrl    = var.tokenvolt_ai_statistics_plugin_url
          pluginSha256 = var.tokenvolt_ai_statistics_plugin_sha256
          paths        = ["/v1/chat/completions", "/v1/responses", "/v1/messages"]
        }
        rateLimits = {
          enabled = local.tokenvolt_rate_limit_enabled
          domains = compact([var.tokenvolt_data_public_host, var.tokenvolt_api_host])
          redis = {
            serviceName = local.tokenvolt_rate_limit_service_name
            servicePort = local.tokenvolt_rate_limit_redis_port
            password    = local.tokenvolt_rate_limit_redis_password
          }
          requestPlugin = {
            url    = var.tokenvolt_cluster_key_rate_limit_plugin_url
            sha256 = var.tokenvolt_cluster_key_rate_limit_plugin_sha256
          }
          tokenPlugin = {
            url    = var.tokenvolt_ai_token_rate_limit_plugin_url
            sha256 = var.tokenvolt_ai_token_rate_limit_plugin_sha256
          }
        }
      }
      rateLimitRedis = {
        enabled = var.tokenvolt_rate_limit_redis_enabled && !var.tokenvolt_managed_redis_enabled
        image   = var.tokenvolt_rate_limit_redis_image
      }
      portal = {
        directEntry = var.tokenvolt_split_public_entry
        host        = var.tokenvolt_portal_host
      }
      modelApi = {
        host = var.tokenvolt_api_host
        backendService = {
          name = var.tokenvolt_model_backend_service
          port = var.tokenvolt_model_backend_port
        }
        mock = {
          enabled = var.tokenvolt_mock_enabled
          image   = var.tokenvolt_mock_image
        }
      }
      publicEntry = {
        host          = var.tokenvolt_split_public_entry ? var.tokenvolt_data_public_host : var.tokenvolt_public_host
        tlsSecretName = var.tokenvolt_public_tls_enabled && !local.shared_public_edge ? kubernetes_secret_v1.tokenvolt_public_tls[0].metadata[0].name : ""
      }
      modelRouting = {
        useRealBackends = var.tokenvolt_real_model_backends
      }
      imagePullSecrets = [{ name = kubernetes_secret_v1.tokenvolt_registry[0].metadata[0].name }]
    })
  ]

  lifecycle {
    precondition {
      condition = (
        can(regex("@sha256:[0-9a-f]{64}$", var.tokenvolt_control_plane_image)) &&
        can(regex("^oci://.+@sha256:[0-9a-f]{64}$", var.tokenvolt_policy_plugin_url)) &&
        (can(regex("^oci://.+@sha256:[0-9a-f]{64}$", var.tokenvolt_ai_statistics_plugin_url)) ||
          (can(regex("^https://[^/]+/.*/sha256/[0-9a-f]{64}\\.wasm$", var.tokenvolt_ai_statistics_plugin_url)) &&
        endswith(var.tokenvolt_ai_statistics_plugin_url, "/${var.tokenvolt_ai_statistics_plugin_sha256}.wasm"))) &&
        endswith(var.tokenvolt_cluster_key_rate_limit_plugin_url, "/sha256/${var.tokenvolt_cluster_key_rate_limit_plugin_sha256}.wasm") &&
        endswith(var.tokenvolt_ai_token_rate_limit_plugin_url, "/sha256/${var.tokenvolt_ai_token_rate_limit_plugin_sha256}.wasm") &&
        (!var.tokenvolt_mock_enabled || can(regex("@sha256:[0-9a-f]{64}$", var.tokenvolt_mock_image)))
      )
      error_message = "TokenVolt control-plane and both Wasm plugin references must be immutable digest references."
    }
  }

  depends_on = [
    helm_release.higress,
    kubernetes_secret_v1.tokenvolt_database,
    kubernetes_secret_v1.tokenvolt_app,
    kubernetes_secret_v1.tokenvolt_registry,
    kubernetes_secret_v1.tokenvolt_registry_higress,
    alicloud_db_account_privilege.tokenvolt,
    alicloud_db_backup_policy.tokenvolt,
    alicloud_ram_role_policy_attachment.tokenvolt,
    alicloud_kvstore_instance.tokenvolt_rate_limit,
  ]
}
