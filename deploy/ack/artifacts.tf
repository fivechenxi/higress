# Public, checksum-addressed release binaries only. No application data or secrets.
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
