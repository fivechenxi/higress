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

output "cluster_id" {
  description = "ID of the disposable ACK cluster."
  value       = alicloud_cs_managed_kubernetes.this.id
}

output "node_pool_id" {
  description = "ID of the elastic worker node pool."
  value       = alicloud_cs_kubernetes_node_pool.gateway.node_pool_id
}

output "reused_network" {
  description = "Existing resources intentionally outside this stack's lifecycle."
  value = {
    vpc_id     = var.vpc_id
    vswitch_id = var.vswitch_id
    zone       = var.availability_zone
  }
}

output "gateway_service" {
  description = "Cluster-internal Higress gateway endpoint."
  value       = var.lifecycle_mode == "running" ? "higress-gateway.higress-system.svc.cluster.local:80" : null
}

output "higress_public_edge" {
  description = "Persistent public CLB referenced by the disposable Higress Service."
  value = {
    id      = alicloud_slb_load_balancer.higress_public.id
    address = alicloud_slb_load_balancer.higress_public.address
  }
}

output "lifecycle_mode" {
  description = "Requested lifecycle phase. Stable values are running and stopped."
  value       = var.lifecycle_mode
}

output "tokenvolt_internal_hosts" {
  description = "Internal-only TokenVolt test hosts when the optional release is enabled."
  value = var.tokenvolt_enabled && var.lifecycle_mode == "running" ? {
    portal = var.tokenvolt_portal_host
    api    = var.tokenvolt_api_host
  } : null
}

output "tokenvolt_public_host" {
  description = "Persistent public canary hostname routed through the fixed Higress CLB."
  value       = var.tokenvolt_enabled ? var.tokenvolt_public_host : null
}

output "grafana_admin_credentials" {
  description = "Grafana URL and generated administrator credentials. Reveal explicitly with: tofu output -json grafana_admin_credentials"
  value = var.grafana_enabled ? {
    url      = "${var.tokenvolt_public_tls_enabled ? "https" : "http"}://${local.grafana_public_host}/grafana/"
    username = var.grafana_admin_user
    password = random_password.grafana_admin[0].result
  } : null
  sensitive = true
}

output "tokenvolt_test_ca_certificate" {
  description = "Public test CA certificate to trust locally while using the self-issued ACK edge certificate."
  value       = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? tls_self_signed_cert.tokenvolt_test_ca[0].cert_pem : null
}

output "tokenvolt_rds" {
  description = "Managed private RDS endpoint for the isolated TokenVolt deployment."
  value = var.tokenvolt_enabled ? {
    instance_id = alicloud_db_instance.tokenvolt[0].id
    endpoint    = alicloud_db_instance.tokenvolt[0].connection_string
    port        = alicloud_db_instance.tokenvolt[0].port
    zone        = alicloud_db_instance.tokenvolt[0].zone_id
  } : null
}

output "tokenvolt_rate_limit_redis" {
  description = "Managed private Redis endpoint used for Higress rate-limit and quota counters."
  value = var.tokenvolt_enabled && var.tokenvolt_managed_redis_enabled ? {
    instance_id = alicloud_kvstore_instance.tokenvolt_rate_limit[0].id
    endpoint    = alicloud_kvstore_instance.tokenvolt_rate_limit[0].connection_domain
    port        = local.tokenvolt_rate_limit_redis_port
    class       = alicloud_kvstore_instance.tokenvolt_rate_limit[0].instance_class
    zone        = alicloud_kvstore_instance.tokenvolt_rate_limit[0].zone_id
  } : null
}

output "kubeconfig_command" {
  description = "Write a short-lived kubeconfig when kubectl access is needed."
  value       = "aliyun cs GET /k8s/${alicloud_cs_managed_kubernetes.this.id}/user_config --profile ${var.alicloud_profile} --region ${var.region}"
}
