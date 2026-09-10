data "alicloud_vpcs" "selected" {
  ids = [var.vpc_id]
}

data "alicloud_vswitches" "selected" {
  ids    = [var.vswitch_id]
  vpc_id = var.vpc_id
}

check "existing_network_matches" {
  assert {
    condition = (
      length(data.alicloud_vpcs.selected.vpcs) == 1 &&
      length(data.alicloud_vswitches.selected.vswitches) == 1 &&
      data.alicloud_vswitches.selected.vswitches[0].zone_id == var.availability_zone
    )
    error_message = "The configured VPC/vSwitch was not found in the region, or the vSwitch zone does not match availability_zone."
  }
}
