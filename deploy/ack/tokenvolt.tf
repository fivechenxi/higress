resource "random_password" "tokenvolt_database" {
  count = var.tokenvolt_enabled ? 1 : 0

  length  = 32
  special = false
}

resource "random_id" "tokenvolt_totp_master_key" {
  count       = var.tokenvolt_enabled ? 1 : 0
  byte_length = 32
}

resource "random_id" "tokenvolt_api_key_pepper" {
  count       = var.tokenvolt_enabled ? 1 : 0
  byte_length = 32
}

locals {
  tokenvolt_sls_project  = "tokenvolt-gateway-${data.alicloud_account.current.id}"
  tokenvolt_sls_logstore = "model-access"
  tokenvolt_oss_bucket   = "tokenvolt-billing-${data.alicloud_account.current.id}-${var.region}"
  tokenvolt_rrsa_role    = "tokenvolt-control-plane-${var.cluster_name}"
}

resource "alicloud_log_project" "tokenvolt" {
  count = var.tokenvolt_enabled ? 1 : 0

  project_name = local.tokenvolt_sls_project
  description  = "Authoritative raw model access records for TokenVolt usage reconciliation"
  tags         = merge(var.tags, { Component = "tokenvolt-usage" })
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
      "consumer"                        = "text"
      "path"                            = "text"
      "request_id"                      = "text"
      "start_time"                      = "text"
      "upstream_cluster"                = "text"
      "ai_log.model"                    = "text"
      "response_code"                   = "long"
      "ai_log.input_token"              = "long"
      "ai_log.output_token"             = "long"
      "ai_log.total_token"              = "long"
      "ai_log.cached_tokens"            = "long"
      "ai_log.llm_first_token_duration" = "double"
      "ai_log.llm_service_duration"     = "double"
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

  instance_id                     = alicloud_db_instance.tokenvolt[0].id
  backup_retention_period         = 90
  enable_backup_log               = true
  enable_pitr_protection          = true
  log_backup_retention_period     = 90
  archive_backup_keep_policy      = "ByMonth"
  archive_backup_keep_count       = 12
  archive_backup_retention_period = 365
  released_keep_policy            = "Lastest"
  preferred_backup_period         = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
  preferred_backup_time           = "18:00Z-19:00Z"
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
    totpMasterKeyB64 = random_id.tokenvolt_totp_master_key[0].b64_std
    apiKeyPepperB64  = random_id.tokenvolt_api_key_pepper[0].b64_std
  }
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
      controlPlane = {
        image        = var.tokenvolt_control_plane_image
        rrsaRoleName = alicloud_ram_role.tokenvolt[0].role_name
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
        policyIngress      = "${var.tokenvolt_namespace}/tokenvolt-model-api"
        aiStatistics = {
          enabled      = true
          pluginUrl    = var.tokenvolt_ai_statistics_plugin_url
          pluginSha256 = var.tokenvolt_ai_statistics_plugin_sha256
          paths        = ["/v1/chat/completions", "/v1/responses", "/v1/messages"]
        }
      }
      portal = {
        host = var.tokenvolt_portal_host
      }
      modelApi = {
        host = var.tokenvolt_api_host
        backendService = {
          name = var.tokenvolt_model_backend_service
          port = var.tokenvolt_model_backend_port
        }
      }
    })
  ]

  lifecycle {
    precondition {
      condition = (
        can(regex("@sha256:[0-9a-f]{64}$", var.tokenvolt_control_plane_image)) &&
        can(regex("^oci://.+@sha256:[0-9a-f]{64}$", var.tokenvolt_policy_plugin_url)) &&
        can(regex("^oci://.+@sha256:[0-9a-f]{64}$", var.tokenvolt_ai_statistics_plugin_url))
      )
      error_message = "TokenVolt control-plane and both Wasm plugin references must be immutable digest references."
    }
  }

  depends_on = [
    helm_release.higress,
    kubernetes_secret_v1.tokenvolt_database,
    kubernetes_secret_v1.tokenvolt_app,
    alicloud_db_account_privilege.tokenvolt,
    alicloud_db_backup_policy.tokenvolt,
    alicloud_ram_role_policy_attachment.tokenvolt,
  ]
}
