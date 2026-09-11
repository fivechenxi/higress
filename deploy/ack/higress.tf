resource "helm_release" "higress" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name             = "higress"
  namespace        = "higress-system"
  create_namespace = true
  chart            = "${path.module}/../../helm/core"

  values = [
    file("${path.module}/values/higress-test.yaml"),
    yamlencode({
      gateway = {
        service = {
          annotations = {
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-id"                       = alicloud_slb_load_balancer.higress_public.id
            "service.beta.kubernetes.io/alibaba-cloud-loadbalancer-force-override-listeners" = "true"
          }
        }
      }
    })
  ]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  depends_on = [
    alicloud_cs_kubernetes_node_pool.gateway,
    alicloud_slb_load_balancer.higress_public,
  ]
}
