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

data "alicloud_vpcs" "selected" {
  ids = [var.vpc_id]
}

data "alicloud_vswitches" "selected" {
  ids    = [var.vswitch_id]
  vpc_id = var.vpc_id
}

data "alicloud_vswitches" "tokenvolt_rds" {
  count  = var.tokenvolt_enabled ? 1 : 0
  ids    = [var.tokenvolt_rds_vswitch_id]
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

check "tokenvolt_rds_network_matches" {
  assert {
    condition = (
      !var.tokenvolt_enabled ||
      length(data.alicloud_vswitches.tokenvolt_rds[0].vswitches) == 1
    )
    error_message = "tokenvolt_rds_vswitch_id was not found in the reused VPC."
  }
}
