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
  default     = "ghcr.io/tokenvolt-ai/tokenvolt-control-plane@sha256:5b1fdf68a3358a989fbe5a84341b9c04deebe46b7bd089999ef4cf4cc01c0afa"
}

variable "tokenvolt_mock_image" {
  description = "Immutable TokenVolt OpenAI/Anthropic fixture image used only for staged end-to-end validation."
  type        = string
  default     = ""
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
  default     = ""
}

variable "tokenvolt_policy_plugin_sha256" {
  description = "Optional checksum expected by Higress. For a multi-platform OCI index this is the selected linux/amd64 image manifest digest, without the sha256: prefix."
  type        = string
  default     = ""

  validation {
    condition     = var.tokenvolt_policy_plugin_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.tokenvolt_policy_plugin_sha256))
    error_message = "tokenvolt_policy_plugin_sha256 must be empty or 64 lowercase hexadecimal characters."
  }
}

variable "tokenvolt_ai_statistics_plugin_url" {
  description = "Immutable OCI digest URL for this fork's ai-statistics Wasm plugin."
  type        = string
  default     = ""
}

variable "tokenvolt_ai_statistics_plugin_sha256" {
  description = "Optional checksum expected by Higress. For a multi-platform OCI index this is the selected linux/amd64 image manifest digest, without the sha256: prefix."
  type        = string
  default     = ""

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
