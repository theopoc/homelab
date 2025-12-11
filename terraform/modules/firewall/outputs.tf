# Firewall Module Outputs

output "firewall_id" {
  description = "ID of the managed firewall"
  value       = hcloud_firewall.this.id
}

output "firewall_name" {
  description = "Name of the managed firewall"
  value       = hcloud_firewall.this.name
}

output "source_ips" {
  description = "List of IPs allowed to access cluster APIs"
  value       = local.source_ips
}

output "current_ipv4" {
  description = "Current machine's IPv4 address (if detected)"
  value       = length(local.current_ipv4) > 0 ? local.current_ipv4[0] : null
}

output "current_ipv6" {
  description = "Current machine's IPv6 address (if detected)"
  value       = length(local.current_ipv6) > 0 ? local.current_ipv6[0] : null
}
