resource "helm_release" "higress_ack_ops" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name      = "higress-ack-ops"
  namespace = "higress-system"
  chart     = "${path.module}/charts/higress-ack-ops"

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    yamlencode({
      monitoring = {
        remoteWriteUrl = local.prometheus_remote_write_url
        clusterId      = alicloud_cs_managed_kubernetes.this.id
      }
    })
  ]

  depends_on = [
    terraform_data.prometheus_auth_free_write,
    kubernetes_annotations.terway_cilium_metrics_rollout,
    helm_release.higress,
  ]
}
