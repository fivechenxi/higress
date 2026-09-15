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
  description = "Ordered low-cost ECS types for the single-AZ elastic node pool."
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

variable "node_min_size" {
  description = "Minimum number of pay-as-you-go workers."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of workers added by ACK cluster autoscaler."
  type        = number
  default     = 3
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

variable "tokenvolt_policy_plugin_url" {
  description = "Immutable OCI digest URL for the TokenVolt policy Wasm plugin."
  type        = string
  default     = "oci://ghcr.io/tokenvolt-ai/tokenvolt-policy@sha256:f1507e1dd27a0194b8b24a590f19e2846ef9133925e04f8d80c6754011042a02"
}

variable "tokenvolt_policy_plugin_sha256" {
  description = "Optional checksum expected by Higress. For a multi-platform OCI index this is the selected linux/amd64 image manifest digest, without the sha256: prefix."
  type        = string
  default     = "3c1758b43c3290b6943f8b6b24a462c6cb72071723178b2b0f7e0f0f26f8e203"

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
