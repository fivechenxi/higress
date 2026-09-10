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

output "lifecycle_mode" {
  description = "Requested lifecycle phase. Stable values are running and stopped."
  value       = var.lifecycle_mode
}

output "kubeconfig_command" {
  description = "Write a short-lived kubeconfig when kubectl access is needed."
  value       = "aliyun cs GET /k8s/${alicloud_cs_managed_kubernetes.this.id}/user_config --profile ${var.alicloud_profile} --region ${var.region}"
}
