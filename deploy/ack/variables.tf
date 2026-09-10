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
  default     = "vsw-2zex87nrlhukk0mlgricd"
}

variable "availability_zone" {
  description = "Availability zone of the reused vSwitch."
  type        = string
  default     = "cn-beijing-k"
}

variable "cluster_name" {
  description = "Name of the disposable ACK test cluster."
  type        = string
  default     = "higress-ack-test"
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
    Environment = "test"
    ManagedBy   = "opentofu"
  }
}
