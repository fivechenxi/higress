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

variable "region" {
  description = "Alibaba Cloud region containing the existing VPC."
  type        = string
  default     = "cn-beijing"
}

variable "alicloud_profile" {
  description = "Alibaba Cloud CLI profile used by the provider."
  type        = string
  default     = "tokenvolt"
}

variable "vpc_id" {
  description = "Existing VPC to reuse. This stack never creates or deletes it."
  type        = string
  default     = "vpc-2ze8x9jglv9rug2n2a5z4"
}

variable "vswitch_id" {
  description = "Existing single-AZ vSwitch to reuse. This stack never creates or deletes it."
  type        = string
  default     = "vsw-2zevlkujoiw0wy0k15z9o"
}

variable "availability_zone" {
  description = "Availability zone of the reused vSwitch."
  type        = string
  default     = "cn-beijing-l"
}

variable "cluster_name" {
  description = "Name of the ACK cluster that is validated privately before production traffic cutover."
  type        = string
  default     = "higress-ack"
}

variable "cluster_spec" {
  description = "ACK managed cluster edition. ack.standard is the low-cost Basic edition."
  type        = string
  default     = "ack.standard"

  validation {
    condition     = contains(["ack.standard", "ack.pro.small"], var.cluster_spec)
    error_message = "cluster_spec must be ack.standard or ack.pro.small."
  }
}

variable "kubernetes_version" {
  description = "ACK version pinned for reproducible Terway DataPath V2 behavior. Kubernetes 1.34+ removes kube-proxy on new DataPath V2 clusters."
  type        = string
  default     = "1.36.2-aliyun.1"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR; must not overlap the reused VPC. Terway Pod IPs come from pod_vswitch_ids."
  type        = string
  default     = "172.21.0.0/20"
}

variable "enable_public_api" {
  description = "Create an Internet-facing endpoint for the ACK API server so local OpenTofu can install Higress. This does not expose the Higress gateway."
  type        = bool
  default     = true
}

variable "lifecycle_mode" {
  description = "Internal start/stop phase. Use make start/stop instead of setting this directly."
  type        = string
  default     = "running"

  validation {
    condition     = contains(["running", "stopping", "stopped", "starting"], var.lifecycle_mode)
    error_message = "lifecycle_mode must be running, stopping, stopped, or starting."
  }
}

variable "worker_instance_types" {
  description = "Ordered ECS types shared by the fixed baseline and elastic node pools."
  type        = list(string)
  # u1 is the lowest-cost checked 4 vCPU/8 GiB option that supports ENI
  # Trunking. The former e-c1m2.xlarge does not, and only exposes six
  # secondary IPs per ENI, which is too restrictive for the test topology.
  default = ["ecs.u1-c1m2.xlarge"]

  validation {
    condition     = length(var.worker_instance_types) > 0
    error_message = "At least one worker instance type is required."
  }
}

variable "base_node_count" {
  description = "Number of prepaid workers kept as the always-on single-AZ baseline."
  type        = number
  default     = 2

  validation {
    condition     = var.base_node_count >= 2 && floor(var.base_node_count) == var.base_node_count
    error_message = "base_node_count must be an integer of at least two so required hostname anti-affinity remains schedulable."
  }
}

variable "base_node_period" {
  description = "Initial and automatic renewal period, in months, for prepaid baseline workers."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3, 6, 12], var.base_node_period)
    error_message = "base_node_period must be one of 1, 2, 3, 6, or 12 months."
  }
}

variable "base_node_auto_renew" {
  description = "Automatically renew the prepaid baseline workers."
  type        = bool
  default     = true
}

variable "node_min_size" {
  description = "Minimum number of pay-as-you-go workers."
  type        = number
  default     = 0

  validation {
    condition     = var.node_min_size >= 0 && floor(var.node_min_size) == var.node_min_size
    error_message = "node_min_size must be a non-negative integer."
  }
}

variable "node_max_size" {
  description = "Maximum number of workers added by ACK cluster autoscaler."
  type        = number
  default     = 10

  validation {
    condition     = var.node_max_size > 0 && floor(var.node_max_size) == var.node_max_size
    error_message = "node_max_size must be a positive integer."
  }
}

variable "scale_down_delay" {
  description = "How long nodes must remain eligible before ACK automatically scales them down."
  type        = string
  default     = "5m"

  validation {
    condition     = can(regex("^[1-9][0-9]*m$", var.scale_down_delay))
    error_message = "scale_down_delay must be a positive whole number of minutes, for example 5m."
  }
}

variable "tags" {
  description = "Tags placed only on resources created by this stack."
  type        = map(string)
  default = {
    Project     = "higress"
    Environment = "production"
    ManagedBy   = "opentofu"
  }
}

variable "tokenvolt_enabled" {
  description = "Deploy an isolated TokenVolt control plane in ACK and its managed RDS database."
  type        = bool
  default     = false
}

variable "deployment_baseline_tag" {
  description = "Exact immutable Git tag whose local Helm and OpenTofu sources are approved for deployment."
  type        = string

  validation {
    condition     = can(regex("^tokenvolt-ack-[0-9A-Za-z._-]+$", var.deployment_baseline_tag))
    error_message = "deployment_baseline_tag must be a TokenVolt ACK release tag."
  }
}

variable "tokenvolt_namespace" {
  description = "Namespace for the isolated TokenVolt application."
  type        = string
  default     = "tokenvolt-system"
}

variable "tokenvolt_quota_enabled" {
  description = "Enable the control-plane quota publisher; persist this switch across ACK releases."
  type        = bool
  default     = false
}

variable "tokenvolt_usage_dashboard" {
  description = "Explicit statistics environment/source; legacy_usage reads existing RDS summaries without enabling billing."
  type = object({
    environment = string
    source      = string
  })
  default = { environment = "", source = "" }
  validation {
    condition = (
      (var.tokenvolt_usage_dashboard.environment == "") == (var.tokenvolt_usage_dashboard.source == "") &&
      trimspace(var.tokenvolt_usage_dashboard.environment) == var.tokenvolt_usage_dashboard.environment &&
      trimspace(var.tokenvolt_usage_dashboard.source) == var.tokenvolt_usage_dashboard.source &&
      length(var.tokenvolt_usage_dashboard.environment) <= 256 &&
      length(var.tokenvolt_usage_dashboard.source) <= 512 &&
      length(regexall("[\\r\\n]", "${var.tokenvolt_usage_dashboard.environment}${var.tokenvolt_usage_dashboard.source}")) == 0
    )
    error_message = "Dashboard environment and source must both be set or both empty, without surrounding whitespace or line breaks."
  }
}

variable "tokenvolt_control_plane_image" {
  description = "Immutable VPC-reachable TokenVolt control-plane image."
  type        = string
  default     = "ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:2a855b96e4a3e00ed1a0d05ff6bfbf8bbc4d8c757f701aae301829ddcf8763bf"
}

variable "tokenvolt_mock_image" {
  description = "Immutable TokenVolt OpenAI/Anthropic fixture image used only for staged end-to-end validation."
  type        = string
  default     = "ghcr.io/tokenvolt-ai/openai-fixture@sha256:dc9047167ff8732566284bee7bc3f971e1dd310f2198517e5781f6cd20c6cc31"
}

variable "tokenvolt_mock_enabled" {
  description = "Deploy the deterministic model fixture behind the internal model API ingress."
  type        = bool
  default     = true
}

variable "tokenvolt_real_model_backends" {
  description = "Route the three deployed TokenVolt models to their existing external providers instead of the deterministic fixture."
  type        = bool
  default     = false
}

variable "tokenvolt_gateway_config_publisher_enabled" {
  description = "Allow TokenVolt admin desired state to reconcile its labeled Higress routes and AI proxy configuration."
  type        = bool
  default     = false
}

variable "tokenvolt_neutoken_single_use_clusters" {
  description = "Current published neutoken.net McpBridge cluster names that must use one upstream request per connection while the T07 UC incident is investigated. Verify the domain before setting; refresh names after connection republication."
  type        = list(string)
  default     = []

  validation {
    condition = length(var.tokenvolt_neutoken_single_use_clusters) == length(distinct(var.tokenvolt_neutoken_single_use_clusters)) && alltrue([
      for name in var.tokenvolt_neutoken_single_use_clusters : can(regex("^outbound\\|443\\|\\|tokenvolt-mp-[0-9a-f]{40}\\.dns$", name))
    ])
    error_message = "Each neutoken single-use cluster must be a unique published tokenvolt-mp DNS cluster on port 443."
  }
}

variable "tokenvolt_public_tls_enabled" {
  description = "Terminate HTTPS in Higress for the public TokenVolt host using the stack-managed test certificate."
  type        = bool
  default     = false
}

variable "tokenvolt_ghcr_username" {
  description = "GitHub user used by ACK to pull private TokenVolt release images."
  type        = string
  default     = "fivechenxi"
}

variable "tokenvolt_ghcr_token" {
  description = "GitHub token with read:packages for private TokenVolt GHCR images. Pass through TF_VAR_tokenvolt_ghcr_token; never commit it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tokenvolt_acr_registry" {
  description = "Exact Beijing ACR registry hostname used in TokenVolt image references; leave empty until switching ACK pulls to ACR."
  type        = string
  default     = ""

  validation {
    condition     = var.tokenvolt_acr_registry == "" || can(regex("^[a-z0-9][a-z0-9.-]*\\.cr\\.aliyuncs\\.com$", var.tokenvolt_acr_registry))
    error_message = "tokenvolt_acr_registry must be an Aliyun ACR hostname without a scheme, path, or port."
  }
}

variable "tokenvolt_acr_username" {
  description = "Username for private TokenVolt ACR pulls. Pass through TF_VAR_tokenvolt_acr_username; never commit it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tokenvolt_acr_password" {
  description = "Password for private TokenVolt ACR pulls. Pass through TF_VAR_tokenvolt_acr_password; never commit it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tokenvolt_rds_vswitch_id" {
  description = "Existing vSwitch used by the production-candidate RDS PostgreSQL instance. It must be in the selected VPC and the ACK availability zone."
  type        = string
  default     = "vsw-2zevlkujoiw0wy0k15z9o"
}

variable "tokenvolt_rds_deletion_protection" {
  description = "Protect the TokenVolt RDS instance from accidental deletion. Disable only for an explicitly reviewed data-destruction operation."
  type        = bool
  default     = true
}

variable "tokenvolt_oss_worm_enabled" {
  description = "Enable irreversible OSS WORM retention only after the legal retention period is approved."
  type        = bool
  default     = false
}

variable "tokenvolt_billing" {
  description = "Non-destructive wiring for the automatic production SLS coverage and invoice pipeline. Existing users, keys, models, routes, prices and logs are never mutated or backfilled."
  type = object({
    enabled          = bool
    environment      = string
    source           = string
    archive_prefix   = string
    billing_start_at = string
    start_cursors = list(object({
      shard = object({
        ID        = number
        CreatedAt = number
        Status    = string
        BeginKey  = string
        EndKey    = string
      })
      cursor = string
    }))
    monthly_drafts_enabled = bool
    monthly_first_month    = string
    monthly_owner_id       = string
  })
  default = {
    enabled                = false
    environment            = ""
    source                 = ""
    archive_prefix         = ""
    billing_start_at       = ""
    start_cursors          = []
    monthly_drafts_enabled = false
    monthly_first_month    = ""
    monthly_owner_id       = ""
  }
  validation {
    condition = !var.tokenvolt_billing.enabled || (
      can(regex("^[A-Za-z0-9_-]{1,256}$", var.tokenvolt_billing.environment)) &&
      length(var.tokenvolt_billing.source) <= 512 && trimspace(var.tokenvolt_billing.source) == var.tokenvolt_billing.source && var.tokenvolt_billing.source != "" &&
      can(regex("^usage-archive/[A-Za-z0-9/_-]+/$", var.tokenvolt_billing.archive_prefix)) &&
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:00:00Z$", var.tokenvolt_billing.billing_start_at)) &&
      length(var.tokenvolt_billing.start_cursors) > 0 && length(var.tokenvolt_billing.start_cursors) <= 256 &&
      length(distinct([for v in var.tokenvolt_billing.start_cursors : "${v.shard.ID}/${v.shard.CreatedAt}"])) == length(var.tokenvolt_billing.start_cursors) &&
      alltrue([for v in var.tokenvolt_billing.start_cursors :
        v.shard.ID >= 0 && v.shard.ID <= 2147483647 &&
        v.shard.CreatedAt > 0 && v.shard.CreatedAt <= 2147483647 &&
        contains(["readwrite", "readonly"], v.shard.Status) &&
        v.shard.BeginKey != "" && v.shard.EndKey != "" &&
        v.cursor != "" && length(v.cursor) <= 4096
      ]) &&
      (!var.tokenvolt_billing.monthly_drafts_enabled || (can(regex("^[0-9]{4}-[0-9]{2}$", var.tokenvolt_billing.monthly_first_month)) && can(regex("^[A-Za-z0-9_-]{1,128}$", var.tokenvolt_billing.monthly_owner_id))))
    )
    error_message = "Enabled billing requires an explicit environment/source, UTC-hour billing start, archive prefix, reviewed shard cursors and valid optional monthly settings."
  }
}

variable "tokenvolt_policy_plugin_url" {
  description = "Immutable OCI digest or checksum-addressed HTTPS URL for the TokenVolt policy Wasm plugin."
  type        = string
  default     = "https://tokenvolt-plugins-1150088752341921-cn-beijing.oss-cn-beijing.aliyuncs.com/tokenvolt-policy/sha256/6d2b7a774011db6acce7e2cbcab9fa0ce5fb12b9dff4968ea8ef4d907cb6907a.wasm"
}

variable "tokenvolt_policy_plugin_sha256" {
  description = "Checksum expected by Higress: Wasm file SHA-256 for HTTPS, selected image manifest SHA-256 for OCI."
  type        = string
  default     = "6d2b7a774011db6acce7e2cbcab9fa0ce5fb12b9dff4968ea8ef4d907cb6907a"

  validation {
    condition     = var.tokenvolt_policy_plugin_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.tokenvolt_policy_plugin_sha256))
    error_message = "tokenvolt_policy_plugin_sha256 must be empty or 64 lowercase hexadecimal characters."
  }
}

variable "tokenvolt_ai_statistics_plugin_url" {
  description = "Immutable OCI digest or checksum-addressed HTTPS URL for this fork's ai-statistics Wasm plugin."
  type        = string
  default     = "https://tokenvolt-plugins-1150088752341921-cn-beijing.oss-cn-beijing.aliyuncs.com/ai-statistics/sha256/54ad15680a864eb0f02e23ec5196cb14759862002f4cab9c54b690638e1d1d93.wasm"
}

variable "tokenvolt_ai_statistics_plugin_sha256" {
  description = "Checksum expected by Higress: Wasm file SHA-256 for HTTPS, selected image manifest SHA-256 for OCI."
  type        = string
  default     = "54ad15680a864eb0f02e23ec5196cb14759862002f4cab9c54b690638e1d1d93"

  validation {
    condition     = var.tokenvolt_ai_statistics_plugin_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.tokenvolt_ai_statistics_plugin_sha256))
    error_message = "tokenvolt_ai_statistics_plugin_sha256 must be empty or 64 lowercase hexadecimal characters."
  }
}

variable "tokenvolt_ai_proxy_plugin_url" {
  description = "Immutable OCI digest or checksum-addressed HTTPS URL for the Higress ai-proxy Wasm plugin. Override this through the OSS-managed tfvars when promoting a compatibility fix."
  type        = string
  default     = "oci://higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/ai-proxy@sha256:69c17eae7b8331f37f05a651a0a1aa731fe7aff2ce30452ff4bbba7c7271818d"
}

variable "tokenvolt_ai_proxy_plugin_sha256" {
  description = "Checksum expected by Higress: Wasm file SHA-256 for HTTPS, selected image manifest SHA-256 for OCI."
  type        = string
  default     = "69c17eae7b8331f37f05a651a0a1aa731fe7aff2ce30452ff4bbba7c7271818d"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.tokenvolt_ai_proxy_plugin_sha256))
    error_message = "tokenvolt_ai_proxy_plugin_sha256 must be 64 lowercase hexadecimal characters."
  }
}

variable "tokenvolt_rate_limit_redis_enabled" {
  description = "Run the temporary in-cluster Redis fallback. Keep false when managed Redis is enabled."
  type        = bool
  default     = false
}

variable "tokenvolt_managed_redis_enabled" {
  description = "Create a private pay-as-you-go Alibaba Cloud Redis instance for Higress rate-limit and quota counters."
  type        = bool
  default     = true
}

variable "tokenvolt_managed_redis_class" {
  description = "Alibaba Cloud Redis instance class. The default is the smallest available one-GiB master-replica class."
  type        = string
  default     = "redis.master.small.default"
}

variable "tokenvolt_rate_limit_redis_image" {
  description = "Immutable Redis image used by the temporary in-cluster rate-limit counter store."
  type        = string
  default     = "ghcr.io/fivechenxi/higress-rate-limit-test-redis@sha256:b1addbe72465a718643cff9e60a58e6df1841e29d6d7d60c9a85d8d72f08d1a7"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.tokenvolt_rate_limit_redis_image))
    error_message = "tokenvolt_rate_limit_redis_image must be an immutable digest reference."
  }
}

variable "tokenvolt_cluster_key_rate_limit_plugin_url" {
  description = "Immutable checksum-addressed URL for the customer RPM protection plugin."
  type        = string
  default     = "https://tokenvolt-plugins-1150088752341921-cn-beijing.oss-cn-beijing.aliyuncs.com/cluster-key-rate-limit/sha256/e123e3a93970dfd48a89b8e2440a0cd6e486f18be5b93c445d7b9017888d69e6.wasm"
}

variable "tokenvolt_cluster_key_rate_limit_plugin_sha256" {
  description = "Wasm SHA-256 for the customer RPM protection plugin."
  type        = string
  default     = "e123e3a93970dfd48a89b8e2440a0cd6e486f18be5b93c445d7b9017888d69e6"
}

variable "tokenvolt_ai_token_rate_limit_plugin_url" {
  description = "Immutable checksum-addressed URL for trial and postpaid Token quota plugins."
  type        = string
  default     = "https://tokenvolt-plugins-1150088752341921-cn-beijing.oss-cn-beijing.aliyuncs.com/ai-token-ratelimit/sha256/3b0096af81cfa041ea886848373f8eff711ef8c2b551d673b099b1ce32ee117a.wasm"
}

variable "tokenvolt_ai_token_rate_limit_plugin_sha256" {
  description = "Wasm SHA-256 for the trial and postpaid Token quota plugin."
  type        = string
  default     = "3b0096af81cfa041ea886848373f8eff711ef8c2b551d673b099b1ce32ee117a"
}

variable "tokenvolt_portal_host" {
  description = "Internal validation host routed to the TokenVolt Portal before public cutover."
  type        = string
  default     = "portal.tokenvolt.internal"
}

variable "tokenvolt_api_host" {
  description = "Internal validation host routed to the TokenVolt model API before public cutover."
  type        = string
  default     = "api.tokenvolt.internal"
}

variable "tokenvolt_public_host" {
  description = "Persistent public canary host shared by the TokenVolt portal and model API paths."
  type        = string
  default     = "ack.tokenvolt.net"
}

variable "tokenvolt_model_backend_service" {
  description = "Service used behind the model API ingress during staged provider integration."
  type        = string
  default     = "tokenvolt-model-backend"
}

variable "tokenvolt_model_backend_port" {
  description = "Port of the staged model API backend Service."
  type        = number
  default     = 8080
}

variable "ecs_public_sites" {
  description = "Persistent ECS sites sharing the ACK CLB. Import existing resources before first apply. Certificate IDs refer to CLB certificates in this region."
  type = map(object({
    domain         = string
    instance_id    = string
    port           = number
    certificate_id = string
    health_path    = string
  }))
  default = {}
  validation {
    condition     = alltrue([for s in values(var.ecs_public_sites) : endswith(s.domain, ".tokenvolt.net") && s.port >= 1 && s.port <= 65535 && s.certificate_id != ""])
    error_message = "ECS sites require a TokenVolt domain, valid backend port and CLB certificate ID."
  }
}

variable "ecs_default_site" {
  description = "Default HTTPS backend; its GET health checks are inherited by its domain rule."
  type        = string
  default     = "newapi"
}

# 2026-09-21: www.tokenvolt.net moved from the legacy prepaid ECS to the ACK
# control plane. The ECS server group, its SNI certificate and the DNS record
# stay in place so the cutover is a one-line rollback.
variable "ecs_public_sites_on_ack" {
  description = "Keys of ecs_public_sites whose domain rule is served by the ACK control-plane group instead of the ECS group. Their ECS server group is kept for rollback."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for name in var.ecs_public_sites_on_ack : contains(keys(var.ecs_public_sites), name)])
    error_message = "ecs_public_sites_on_ack entries must also exist in ecs_public_sites."
  }
}

variable "tokenvolt_extra_allowed_origins" {
  description = "Additional exact browser origins accepted by the control plane for host aliases that share the same portal (for example https://www.tokenvolt.net). Requires a control-plane image that parses a comma-separated ALLOWED_ORIGIN list."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for origin in var.tokenvolt_extra_allowed_origins : startswith(origin, "https://") || startswith(origin, "http://")])
    error_message = "Extra allowed origins must be absolute origins including the http(s) scheme."
  }
}

variable "ack_edge_certificate_id" {
  description = "Trusted RSA CLB certificate for the ACK host; required when TokenVolt uses the shared public edge."
  type        = string
  default     = ""
}
variable "prometheus_alerts_enabled" {
  description = "Create ARMS-side bridge alerts while the ACK workload stack is running."
  type        = bool
  default     = true
}

variable "prometheus_alert_dispatch_rule_id" {
  description = "Optional ARMS notification-policy ID. Empty uses the account's default AlertManager path."
  type        = string
  default     = ""
}

variable "prometheus_query_url" {
  description = "ACK Prometheus intranet HTTP API URL returned by GetPrometheusInstance; used by Grafana so collector restarts do not lose dashboard history."
  type        = string
  default     = ""
  validation {
    condition     = var.prometheus_query_url == "" || startswith(var.prometheus_query_url, "http://cn-beijing-intranet.arms.aliyuncs.com:9090/")
    error_message = "prometheus_query_url must be the cn-beijing ARMS intranet HTTP API URL."
  }
}

variable "hpa_event_center_enabled" {
  description = "Persist Kubernetes events, including HPA decisions and failures, in the ACK SLS Event Center. This does not enable cs-default Prometheus collection."
  type        = bool
  default     = true
}

variable "grafana_enabled" {
  description = "Run a single Grafana instance behind the Higress /grafana sub-route while the workload stack is running."
  type        = bool
  default     = true
}

variable "grafana_admin_user" {
  description = "Grafana administrator user stored with its generated password in a Kubernetes Secret."
  type        = string
  default     = "admin"
}

variable "feishu_alert_webhook_url" {
  description = "Feishu custom-bot webhook for TokenVolt alerts. Keep empty to deploy Alertmanager with a null receiver."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.feishu_alert_webhook_url == "" || can(regex("^https://open\\.(feishu\\.cn|larksuite\\.com)/open-apis/bot/v2/hook/[A-Za-z0-9_-]+$", var.feishu_alert_webhook_url))
    error_message = "feishu_alert_webhook_url must be an official Feishu/Lark custom-bot webhook URL."
  }
}

variable "feishu_alert_escalation_webhook_url" {
  description = "Optional second Feishu custom-bot webhook for firing critical alerts. Keep empty to use only the primary webhook."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.feishu_alert_escalation_webhook_url == "" || can(regex("^https://open\\.(feishu\\.cn|larksuite\\.com)/open-apis/bot/v2/hook/[A-Za-z0-9_-]+$", var.feishu_alert_escalation_webhook_url))
    error_message = "feishu_alert_escalation_webhook_url must be an official Feishu/Lark custom-bot webhook URL."
  }
}

variable "tokenvolt_split_public_entry" {
  description = "Route the portal directly from CLB and expose model traffic on a separate public host."
  type        = bool
  default     = false
}

variable "tokenvolt_data_public_host" {
  description = "Public model API hostname when split entry is enabled."
  type        = string
  default     = "api.tokenvolt.net"
}

variable "tokenvolt_data_certificate_id" {
  description = "Trusted RSA CLB certificate for the model API hostname."
  type        = string
  default     = ""
}

variable "ack_alb_ingress_controller_enabled" {
  description = "Install and retain the ACK-managed ALB Ingress Controller addon."
  type        = bool
  default     = false
}

variable "higress_alb_ingress_enabled" {
  description = "Create the opt-in ALB public edge for the Higress Gateway."
  type        = bool
  default     = false
}

variable "higress_alb_dns_enabled" {
  description = "Point the managed model API DNS record at the ACK-managed ALB. Kept separate from ALB creation for staged cutover and rollback."
  type        = bool
  default     = false
}

variable "higress_alb_dns_name" {
  description = "ACK-managed ALB DNS name used as the model API CNAME target after an approved cutover."
  type        = string
  default     = ""
}

variable "higress_alb_vswitch_ids" {
  description = "Two existing vSwitch IDs in distinct ALB-supported zones of the ACK VPC."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.higress_alb_vswitch_ids) == 0 || (length(var.higress_alb_vswitch_ids) == 2 && length(distinct(var.higress_alb_vswitch_ids)) == 2 && alltrue([for id in var.higress_alb_vswitch_ids : trimspace(id) != ""]))
    error_message = "higress_alb_vswitch_ids must be empty or contain two distinct non-empty vSwitch IDs."
  }
}

variable "higress_alb_certificate_id" {
  description = "Certificate Management Service CertIdentifier for the Higress ALB HTTPS listener."
  type        = string
  default     = ""
}

variable "higress_alb_request_timeout" {
  description = "ALB listener request timeout in seconds."
  type        = number
  default     = 900

  validation {
    condition     = var.higress_alb_request_timeout >= 1 && var.higress_alb_request_timeout <= 3600
    error_message = "higress_alb_request_timeout must be between 1 and 3600 seconds."
  }
}

variable "higress_alb_idle_timeout" {
  description = "ALB listener idle timeout in seconds."
  type        = number
  default     = 900

  validation {
    condition     = var.higress_alb_idle_timeout >= 1 && var.higress_alb_idle_timeout <= 3600
    error_message = "higress_alb_idle_timeout must be between 1 and 3600 seconds."
  }
}
