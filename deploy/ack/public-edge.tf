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

resource "alicloud_slb_load_balancer" "higress_public" {
  load_balancer_name   = "tokenvolt-higress-public"
  address_type         = "internet"
  address_ip_version   = "ipv4"
  payment_type         = "PayAsYouGo"
  instance_charge_type = "PayByCLCU"
  internet_charge_type = "PayByTraffic"
  delete_protection    = "on"

  tags = merge(var.tags, {
    Lifecycle = "persistent-edge"
  })

  lifecycle {
    # The public entrypoint intentionally outlives disposable ACK workloads.
    # Removing it requires a reviewed, explicit lifecycle change.
    prevent_destroy = true
    precondition {
      condition     = !var.tokenvolt_split_public_entry || (local.shared_public_edge && var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled)
      error_message = "Split entry requires enabled TokenVolt, public TLS and shared CLB ECS sites."
    }
    # ACK CCM annotates a reused load balancer with ownership tags. Terraform
    # must not fight the controller for those tags during application updates.
    ignore_changes = [tags]
  }
}

resource "alicloud_alidns_record" "higress_public" {
  domain_name = "tokenvolt.net"
  rr          = "ack"
  type        = "A"
  value       = alicloud_slb_load_balancer.higress_public.address
  ttl         = 600
  status      = "ENABLE"
  remark      = "Persistent TokenVolt Higress public canary entrypoint"

  lifecycle {
    # DNS is an edge resource and intentionally outlives Helm releases and
    # disposable ACK workloads. Removing it requires an explicit review.
    prevent_destroy = true
    ignore_changes  = [remark]
  }
}

# This CA is intentionally limited to the ACK test edge. Its private key is
# retained in sensitive OpenTofu state and never enters Helm.
resource "tls_private_key" "tokenvolt_test_ca" {
  count = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 3072
}

resource "tls_self_signed_cert" "tokenvolt_test_ca" {
  count = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0

  private_key_pem = tls_private_key.tokenvolt_test_ca[0].private_key_pem

  subject {
    common_name  = "TokenVolt ACK Test CA"
    organization = "TokenVolt"
  }

  validity_period_hours = 8760
  is_ca_certificate     = true
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]
}

resource "tls_private_key" "tokenvolt_public" {
  count = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "tokenvolt_public" {
  count = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0

  private_key_pem = tls_private_key.tokenvolt_public[0].private_key_pem
  dns_names       = [var.tokenvolt_public_host]

  subject {
    common_name  = var.tokenvolt_public_host
    organization = "TokenVolt"
  }

  lifecycle {
    precondition {
      condition     = var.tokenvolt_public_host != ""
      error_message = "tokenvolt_public_host is required when tokenvolt_public_tls_enabled is true."
    }
  }
}

resource "tls_locally_signed_cert" "tokenvolt_public" {
  count = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0

  cert_request_pem      = tls_cert_request.tokenvolt_public[0].cert_request_pem
  ca_private_key_pem    = tls_private_key.tokenvolt_test_ca[0].private_key_pem
  ca_cert_pem           = tls_self_signed_cert.tokenvolt_test_ca[0].cert_pem
  validity_period_hours = 2160
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "kubernetes_secret_v1" "tokenvolt_public_tls" {
  count = var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0

  metadata {
    name      = "tokenvolt-public-tls"
    namespace = kubernetes_namespace_v1.tokenvolt[0].metadata[0].name
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = "${tls_locally_signed_cert.tokenvolt_public[0].cert_pem}${tls_self_signed_cert.tokenvolt_test_ca[0].cert_pem}"
    "tls.key" = tls_private_key.tokenvolt_public[0].private_key_pem
  }
}

resource "alicloud_alidns_record" "model_api" {
  # First adoption must still be staged and verified with DNS pinned to the CLB.
  depends_on  = [alicloud_slb_domain_extension.model_api, alicloud_slb_rule.model_api, helm_release.tokenvolt]
  count       = var.tokenvolt_split_public_entry ? 1 : 0
  domain_name = "tokenvolt.net"
  rr          = trimsuffix(var.tokenvolt_data_public_host, ".tokenvolt.net")
  type        = "A"
  value       = alicloud_slb_load_balancer.higress_public.address
  ttl         = 600
  status      = "ENABLE"
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [remark]
  }
}
