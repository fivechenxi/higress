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
  }
}
