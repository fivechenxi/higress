resource "alicloud_cs_kubernetes_node_pool" "gateway" {
  cluster_id     = alicloud_cs_managed_kubernetes.this.id
  node_pool_name = "${var.cluster_name}-elastic"
  vswitch_ids    = [var.vswitch_id]

  instance_types       = var.worker_instance_types
  instance_charge_type = "PostPaid"
  key_name             = alicloud_key_pair.workers.key_pair_name

  image_type                 = "AliyunLinux4ContainerOptimized"
  runtime_name               = "containerd"
  system_disk_category       = "cloud_essd_entry"
  system_disk_size           = 40
  install_cloud_monitor      = false
  internet_max_bandwidth_out = 0
  force_delete               = true
  desired_size = (
    var.lifecycle_mode == "stopped" ? "0" :
    var.lifecycle_mode == "starting" ? tostring(var.node_min_size) : null
  )

  scaling_config {
    enable      = var.lifecycle_mode == "running"
    min_size    = var.node_min_size
    max_size    = var.node_max_size
    type        = "cpu"
    is_bond_eip = false
  }

  labels {
    key   = "workload"
    value = "higress"
  }

  tags = var.tags

  timeouts {
    create = "90m"
    update = "60m"
    delete = "60m"
  }
}

resource "alicloud_cs_autoscaling_config" "this" {
  cluster_id = alicloud_cs_managed_kubernetes.this.id

  cool_down_duration            = var.scale_down_delay
  unneeded_duration             = "10m"
  utilization_threshold         = "0.5"
  gpu_utilization_threshold     = "0.5"
  scan_interval                 = "30s"
  scale_down_enabled            = true
  expander                      = "least-waste"
  skip_nodes_with_system_pods   = true
  skip_nodes_with_local_storage = false
  daemonset_eviction_for_nodes  = false
  max_graceful_termination_sec  = 600
  min_replica_count             = 0
  recycle_node_deletion_enabled = false
  scale_up_from_zero            = true
  scaler_type                   = "cluster-autoscaler"

  depends_on = [alicloud_cs_kubernetes_node_pool.gateway]
}
