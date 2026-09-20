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

# Public, checksum-addressed release binaries only. No application data or secrets.
locals {
  grafana_sls_plugin_manifest = {
    for line in split("\n", file("${path.module}/artifacts/grafana-sls-plugin.sh")) :
    split("=", trimspace(line))[0] => split("=", trimspace(line))[1]
    if trimspace(line) != "" && !startswith(trimspace(line), "#")
  }
  grafana_sls_plugin_artifact = {
    version   = local.grafana_sls_plugin_manifest.GRAFANA_SLS_PLUGIN_VERSION
    commit    = local.grafana_sls_plugin_manifest.GRAFANA_SLS_PLUGIN_COMMIT
    sha256    = local.grafana_sls_plugin_manifest.GRAFANA_SLS_PLUGIN_SHA256
    sourceUrl = local.grafana_sls_plugin_manifest.GRAFANA_SLS_PLUGIN_SOURCE_URL
    objectKey = local.grafana_sls_plugin_manifest.GRAFANA_SLS_PLUGIN_OBJECT_KEY
  }
}

resource "alicloud_oss_bucket" "tokenvolt_plugins" {
  count         = var.tokenvolt_enabled ? 1 : 0
  bucket        = "tokenvolt-plugins-${data.alicloud_account.current.id}-${var.region}"
  storage_class = "Standard"
  force_destroy = false
  tags          = merge(var.tags, { Component = "tokenvolt-public-plugins" })
}

resource "alicloud_oss_bucket_acl" "tokenvolt_plugins" {
  count      = var.tokenvolt_enabled ? 1 : 0
  bucket     = alicloud_oss_bucket.tokenvolt_plugins[0].bucket
  acl        = "public-read"
  depends_on = [alicloud_oss_bucket_public_access_block.tokenvolt_plugins]
}

resource "alicloud_oss_bucket_public_access_block" "tokenvolt_plugins" {
  count               = var.tokenvolt_enabled ? 1 : 0
  bucket              = alicloud_oss_bucket.tokenvolt_plugins[0].bucket
  block_public_access = false
}
