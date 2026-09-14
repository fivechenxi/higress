# Copyright 2026 Alibaba Group Holding Ltd.
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

provider "alicloud" {
  region  = var.region
  profile = var.alicloud_profile
}

data "alicloud_account" "current" {}

locals {
  bucket_name = "tokenvolt-iac-${data.alicloud_account.current.id}-${var.region}"
  ots_name    = "tviaclock"
  ots_table   = "opentofu_state_lock"
}

resource "alicloud_oss_bucket" "state" {
  bucket        = local.bucket_name
  storage_class = "Standard"
  force_destroy = false
  tags = {
    Project   = "tokenvolt"
    Component = "iac-state"
    ManagedBy = "opentofu-bootstrap"
  }

  versioning {
    status = "Enabled"
  }

  server_side_encryption_rule {
    sse_algorithm = "AES256"
  }

  # Provider 1.292 also exposes these settings through legacy nested state and
  # can otherwise propose removing a setting managed by the same resource.
  lifecycle {
    ignore_changes = [versioning, server_side_encryption_rule]
  }
}

resource "alicloud_oss_bucket_acl" "state" {
  bucket = alicloud_oss_bucket.state.bucket
  acl    = "private"
}

resource "alicloud_oss_bucket_public_access_block" "state" {
  bucket              = alicloud_oss_bucket.state.bucket
  block_public_access = true
}

resource "alicloud_ots_instance" "state_lock" {
  name          = local.ots_name
  description   = "OpenTofu state locking for TokenVolt ACK"
  instance_type = "Capacity"
  accessed_by   = "Any"
  tags = {
    Project   = "tokenvolt"
    Component = "iac-state-lock"
    ManagedBy = "opentofu-bootstrap"
  }
}

resource "alicloud_ots_table" "state_lock" {
  instance_name = alicloud_ots_instance.state_lock.name
  table_name    = local.ots_table
  max_version   = 1
  time_to_live  = -1

  primary_key {
    name = "LockID"
    type = "String"
  }
}

output "backend" {
  value = {
    bucket              = alicloud_oss_bucket.state.bucket
    region              = var.region
    profile             = var.alicloud_profile
    prefix              = "ack"
    key                 = "terraform.tfstate"
    tablestore_endpoint = "https://${alicloud_ots_instance.state_lock.name}.${var.region}.ots.aliyuncs.com"
    tablestore_table    = alicloud_ots_table.state_lock.table_name
    tfvars_key          = "ack/config/terraform.tfvars"
  }
}
