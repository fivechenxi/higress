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
  enable_rrsa          = false
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

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.node_min_size >= 1 && var.node_max_size > var.node_min_size
      error_message = "The test stack needs at least one base worker, and node_max_size must be greater than node_min_size."
    }
  }

  depends_on = [data.alicloud_vswitches.selected]
}

resource "alicloud_key_pair" "workers" {
  key_pair_name = "${var.cluster_name}-workers"
  tags          = var.tags
}
