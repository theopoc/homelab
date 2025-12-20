# Firewall Module
# Manages admin IPs for cluster API access independently
# This avoids chicken-and-egg problems with API health checks

locals {
  # Build source IPs list from current IP + extra admin IPs
  current_ipv4 = var.use_current_ip && length(data.external.current_ips) > 0 && data.external.current_ips[0].result.ipv4 != "" ? ["${data.external.current_ips[0].result.ipv4}/32"] : []
  current_ipv6 = var.use_current_ip && length(data.external.current_ips) > 0 && data.external.current_ips[0].result.ipv6 != "" ? ["${data.external.current_ips[0].result.ipv6}/128"] : []

  source_ips = distinct(concat(
    var.extra_admin_ips,
    local.current_ipv4,
    local.current_ipv6
  ))
}

# Get existing firewall to preserve labels
# data "hcloud_firewall" "cluster" {
#   name = var.firewall_name
# }

# Manage firewall rules
# NOTE: This takes over management from the cluster module.
# The firewall must be imported into this module's state first.
resource "hcloud_firewall" "this" {
  name   = var.firewall_name
  labels = var.labels

  rule {
    description = "Allow Incoming Requests to Kube API"
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = local.source_ips
  }

  rule {
    description = "Allow Incoming Requests to Talos API"
    direction   = "in"
    protocol    = "tcp"
    port        = "50000"
    source_ips  = local.source_ips
  }

  lifecycle {
    # Ignore apply_to - managed by cluster module's server resources
    ignore_changes = [apply_to]
  }
}
