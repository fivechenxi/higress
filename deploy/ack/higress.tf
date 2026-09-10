resource "helm_release" "higress" {
  count = var.lifecycle_mode == "running" ? 1 : 0

  name             = "higress"
  namespace        = "higress-system"
  create_namespace = true
  chart            = "${path.module}/../../helm/core"

  values = [file("${path.module}/values/higress-test.yaml")]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  depends_on = [alicloud_cs_kubernetes_node_pool.gateway]
}
