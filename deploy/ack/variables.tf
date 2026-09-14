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

variable "tokenvolt_namespace" {
  description = "Namespace for the isolated TokenVolt application."
  type        = string
  default     = "tokenvolt-system"
}

variable "tokenvolt_control_plane_image" {
  description = "Immutable VPC-reachable TokenVolt control-plane image."
  type        = string
  default     = "ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:0f993657cf19dcb91274cb4038200ea1cd52cc4a1df71648f804a535fc807a99"
}

variable "tokenvolt_mock_image" {
  description = "Immutable TokenVolt OpenAI/Anthropic fixture image used only for staged end-to-end validation."
  type        = string
  default     = "ghcr.io/tokenvolt-ai/openai-fixture@sha256:693eb67b93059f08c67d7807d3f448d1f8e016f8c5ce220db2d8c69062fe6cda"
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
  default     = "oci://ghcr.io/tokenvolt-ai/tokenvolt-policy@sha256:9e2deb470acb1c110910b3e6ec34b9f7760d6d80db4945c4b33da2384d8a18b7"
}

# For OCI URLs Higress verifies the selected platform manifest, not plugin.wasm.
# The release OCI index resolves to the linux/amd64 manifest below.
variable "tokenvolt_policy_plugin_sha256" {
  description = "Optional checksum expected by Higress. For a multi-platform OCI index this is the selected linux/amd64 image manifest digest, without the sha256: prefix."
  type        = string
  default     = "9e2deb470acb1c110910b3e6ec34b9f7760d6d80db4945c4b33da2384d8a18b7"

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
