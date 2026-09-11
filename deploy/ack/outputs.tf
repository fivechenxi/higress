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

output "tokenvolt_rds" {
  description = "Managed private RDS endpoint for the isolated TokenVolt deployment."
  value = var.tokenvolt_enabled ? {
    instance_id = alicloud_db_instance.tokenvolt[0].id
    endpoint    = alicloud_db_instance.tokenvolt[0].connection_string
    port        = alicloud_db_instance.tokenvolt[0].port
    zone        = alicloud_db_instance.tokenvolt[0].zone_id
  } : null
}

output "kubeconfig_command" {
  description = "Write a short-lived kubeconfig when kubectl access is needed."
  value       = "aliyun cs GET /k8s/${alicloud_cs_managed_kubernetes.this.id}/user_config --profile ${var.alicloud_profile} --region ${var.region}"
}
