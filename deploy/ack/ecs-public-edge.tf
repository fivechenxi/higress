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

# Terraform owns listeners and rules; CCM owns ONLY ACK group membership.
# These edge resources deliberately outlive lifecycle_mode=stopped.
locals {
  shared_public_edge = length(var.ecs_public_sites) > 0
  default_ecs_site   = try(var.ecs_public_sites[var.ecs_default_site], null)
}

resource "alicloud_slb_server_group" "ecs" {
  for_each         = var.ecs_public_sites
  load_balancer_id = alicloud_slb_load_balancer.higress_public.id
  name             = "tokenvolt-ecs-${each.key}"
  servers {
    server_ids = [each.value.instance_id]
    port       = each.value.port
    weight     = 100
    type       = "ecs"
  }
  lifecycle { prevent_destroy = true }
}

# Keep the public edge open for slow model first-token responses. This must not
# expire before the listener request timeout and turn an in-flight request into
# an edge-generated 502.
resource "alicloud_slb_listener" "public_https" {
  count                     = local.shared_public_edge ? 1 : 0
  load_balancer_id          = alicloud_slb_load_balancer.higress_public.id
  frontend_port             = 443
  protocol                  = "https"
  bandwidth                 = -1
  description               = "tokenvolt-ecs-public-https"
  server_group_id           = alicloud_slb_server_group.ecs[var.ecs_default_site].id
  server_certificate_id     = local.default_ecs_site.certificate_id
  sticky_session            = "off"
  scheduler                 = "wrr"
  enable_http2              = "on"
  gzip                      = true
  tls_cipher_policy         = "tls_cipher_policy_1_2_strict_with_1_3"
  idle_timeout              = 180
  request_timeout           = 180
  health_check              = "on"
  health_check_type         = "http"
  health_check_method       = "get"
  health_check_uri          = local.default_ecs_site.health_path
  health_check_domain       = local.default_ecs_site.domain
  health_check_connect_port = local.default_ecs_site.port
  health_check_http_code    = "http_2xx"
  health_check_interval     = 3
  health_check_timeout      = 5
  healthy_threshold         = 2
  unhealthy_threshold       = 3
  x_forwarded_for { retrive_slb_proto = true }
  lifecycle { prevent_destroy = true }
}

resource "alicloud_slb_listener" "public_http" {
  count            = local.shared_public_edge ? 1 : 0
  load_balancer_id = alicloud_slb_load_balancer.higress_public.id
  frontend_port    = 80
  protocol         = "http"
  bandwidth        = -1
  description      = "tokenvolt-ecs-redirect-https"
  listener_forward = "on"
  forward_port     = 443
  idle_timeout     = 180
  request_timeout  = 180
  health_check     = "off"
  sticky_session   = "off"
  depends_on       = [alicloud_slb_listener.public_https]
  lifecycle { prevent_destroy = true }
}

resource "alicloud_slb_rule" "ecs" {
  for_each         = { for name, site in var.ecs_public_sites : name => site if name != var.ecs_default_site }
  load_balancer_id = alicloud_slb_load_balancer.higress_public.id
  frontend_port    = 443
  name             = "tokenvolt-${each.key}-ecs"
  domain           = each.value.domain
  # Sites listed in ecs_public_sites_on_ack keep their ECS server group (rollback
  # path) but serve the ACK control-plane group, so one portal host can be moved
  # between the legacy ECS and the cluster without recreating the rule.
  server_group_id = contains(var.ecs_public_sites_on_ack, each.key) ? alicloud_slb_server_group.portal_http[0].id : alicloud_slb_server_group.ecs[each.key].id
  # The default site uses the listener directly; these are non-default sites.
  listener_sync       = "off"
  sticky_session      = "off"
  scheduler           = "wrr"
  health_check        = "on"
  health_check_uri    = contains(var.ecs_public_sites_on_ack, each.key) ? "/readyz" : each.value.health_path
  health_check_domain = each.value.domain
  # The provider rejects an explicit 0 ("backend port") here, and an ACK-backed
  # site must probe the control plane's own port, guarded below.
  health_check_connect_port = each.value.port
  health_check_http_code    = "http_2xx"
  health_check_interval     = 3
  health_check_timeout      = 5
  healthy_threshold         = 2
  unhealthy_threshold       = 3
  depends_on                = [alicloud_slb_listener.public_https]
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length(var.ecs_public_sites_on_ack) == 0 || var.tokenvolt_split_public_entry
      error_message = "Serving an ECS site from the ACK control plane requires tokenvolt_split_public_entry, which owns the dedicated portal group."
    }
    precondition {
      condition     = alltrue([for name in var.ecs_public_sites_on_ack : var.ecs_public_sites[name].port == 8000])
      error_message = "An ACK-backed portal site must use port 8000, the control plane's listening port behind the dedicated server group; any other port would fail the health check."
    }
  }
}

resource "alicloud_slb_domain_extension" "ecs" {
  for_each              = { for name, site in var.ecs_public_sites : name => site if name != var.ecs_default_site }
  load_balancer_id      = alicloud_slb_load_balancer.higress_public.id
  frontend_port         = 443
  domain                = each.value.domain
  server_certificate_id = each.value.certificate_id
  depends_on            = [alicloud_slb_listener.public_https]
  lifecycle { prevent_destroy = true }
}

resource "alicloud_alidns_record" "ecs" {
  for_each    = var.ecs_public_sites
  domain_name = "tokenvolt.net"
  rr          = trimsuffix(each.value.domain, ".tokenvolt.net")
  type        = "A"
  value       = alicloud_slb_load_balancer.higress_public.address
  ttl         = 600
  status      = "ENABLE"
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [remark]
  }
}

resource "alicloud_slb_server_group" "ack_http" {
  count            = local.shared_public_edge ? 1 : 0
  load_balancer_id = alicloud_slb_load_balancer.higress_public.id
  name             = "tokenvolt-ack-http"
  lifecycle {
    prevent_destroy = true
    # CCM adds/removes only the backends of the referenced Kubernetes Service.
    ignore_changes = [servers]
  }
}

resource "alicloud_slb_domain_extension" "ack" {
  count                 = local.shared_public_edge && var.tokenvolt_enabled && var.tokenvolt_public_tls_enabled ? 1 : 0
  load_balancer_id      = alicloud_slb_load_balancer.higress_public.id
  frontend_port         = 443
  domain                = var.tokenvolt_public_host
  server_certificate_id = var.ack_edge_certificate_id
  depends_on            = [alicloud_slb_listener.public_https]
}

resource "alicloud_slb_rule" "ack" {
  count                  = local.shared_public_edge && var.tokenvolt_enabled ? 1 : 0
  load_balancer_id       = alicloud_slb_load_balancer.higress_public.id
  frontend_port          = 443
  name                   = var.tokenvolt_split_public_entry ? "tokenvolt-ack-control-plane" : "tokenvolt-ack-higress"
  domain                 = var.tokenvolt_public_host
  server_group_id        = var.tokenvolt_split_public_entry ? alicloud_slb_server_group.portal_http[0].id : alicloud_slb_server_group.ack_http[0].id
  listener_sync          = "off"
  sticky_session         = "off"
  health_check           = "on"
  health_check_uri       = "/readyz"
  health_check_domain    = var.tokenvolt_public_host
  health_check_http_code = "http_2xx"
  health_check_interval  = 3
  health_check_timeout   = 5
  healthy_threshold      = 2
  unhealthy_threshold    = 3
  depends_on             = [alicloud_slb_listener.public_https, helm_release.tokenvolt]
  lifecycle {
    precondition {
      condition     = var.tokenvolt_public_tls_enabled && var.tokenvolt_public_host != "" && var.ack_edge_certificate_id != ""
      error_message = "Shared ACK edge requires a public host, a trusted RSA CLB certificate ID and tokenvolt_public_tls_enabled=true."
    }
  }
}

# Each Kubernetes Service owns only its dedicated group's membership.
resource "alicloud_slb_server_group" "portal_http" {
  count            = local.shared_public_edge && var.tokenvolt_split_public_entry ? 1 : 0
  load_balancer_id = alicloud_slb_load_balancer.higress_public.id
  name             = "tokenvolt-ack-control-plane"
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [servers]
  }
}

resource "alicloud_slb_domain_extension" "model_api" {
  count                 = local.shared_public_edge && var.tokenvolt_split_public_entry ? 1 : 0
  load_balancer_id      = alicloud_slb_load_balancer.higress_public.id
  frontend_port         = 443
  domain                = var.tokenvolt_data_public_host
  server_certificate_id = var.tokenvolt_data_certificate_id
  depends_on            = [alicloud_slb_listener.public_https]
}

resource "alicloud_slb_rule" "model_api" {
  count                     = local.shared_public_edge && var.tokenvolt_split_public_entry ? 1 : 0
  load_balancer_id          = alicloud_slb_load_balancer.higress_public.id
  frontend_port             = 443
  name                      = "tokenvolt-api-higress"
  domain                    = var.tokenvolt_data_public_host
  server_group_id           = alicloud_slb_server_group.ack_http[0].id
  listener_sync             = "off"
  sticky_session            = "off"
  health_check              = "on"
  health_check_uri          = "/healthz/ready"
  health_check_connect_port = 15020
  health_check_domain       = var.tokenvolt_data_public_host
  health_check_http_code    = "http_2xx"
  health_check_interval     = 3
  health_check_timeout      = 5
  healthy_threshold         = 2
  unhealthy_threshold       = 3
  depends_on                = [alicloud_slb_listener.public_https, helm_release.tokenvolt]
  lifecycle {
    precondition {
      condition     = var.tokenvolt_data_public_host != var.tokenvolt_public_host && var.tokenvolt_data_certificate_id != ""
      error_message = "Split entry requires distinct portal/model hosts and a trusted model API certificate."
    }
  }
}
