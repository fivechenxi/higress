resource "alicloud_cs_managed_kubernetes" "this" {
  name         = var.cluster_name
  cluster_spec = var.cluster_spec
  profile      = "Default"
  version      = var.kubernetes_version

  vswitch_ids     = [var.vswitch_id]
  pod_vswitch_ids = [var.vswitch_id]
  service_cidr    = var.service_cidr
  node_cidr_mask  = 24

  new_nat_gateway      = false
  slb_internet_enabled = var.enable_public_api
  deletion_protection  = false
  enable_rrsa          = true
  timezone             = "Asia/Shanghai"

  addons {
    name = "terway-eniip"
    config = jsonencode({
      # ACK retains IPVlan as the cluster-creation compatibility switch for
      # shared-ENI acceleration. Terway >= 1.8 materializes it as DataPath V2,
      # not the retired IPvlan datapath.
      IPVlan        = "true"
      NetworkPolicy = "true"
      CiliumArgs    = local.terway_cilium_args
    })
  }

  addons {
    name   = "metrics-server"
    config = ""
  }

  dynamic "addons" {
    for_each = var.tokenvolt_enabled ? [1] : []
    content {
      name = "logtail-ds"
      config = jsonencode({
        IngressDashboardEnabled = "false"
        sls_project_name        = alicloud_log_project.tokenvolt[0].project_name
      })
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.node_min_size >= 1 && var.node_max_size > var.node_min_size
      error_message = "The test stack needs at least one base worker, and node_max_size must be greater than node_min_size."
    }
  }

  depends_on = [data.alicloud_vswitches.selected]
}

# Manage this post-creation addon independently. Putting it in the cluster's
# creation-time addons set makes an existing cluster credential unknown during
# planning, which also prevents the Kubernetes and Helm providers from reading
# their current resources.
resource "alicloud_cs_kubernetes_addon" "pod_identity" {
  count      = var.tokenvolt_enabled ? 1 : 0
  cluster_id = alicloud_cs_managed_kubernetes.this.id
  name       = "ack-pod-identity-webhook"
  version    = "0.4.4"
  config = jsonencode({
    AutoInjectSTSEnvVars = true
  })
}

resource "alicloud_key_pair" "workers" {
  key_pair_name = "${var.cluster_name}-workers"
  tags          = var.tags
}
