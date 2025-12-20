# Get current public IPs (handles missing IPv6 gracefully)
data "external" "current_ips" {
  count   = var.use_current_ip ? 1 : 0
  program = ["bash", "-c", <<-EOT
    ipv4=$(curl -4sf --connect-timeout 5 https://ip.hetzner.com 2>/dev/null | tr -d '\n' || echo "")
    ipv6=$(curl -6sf --connect-timeout 5 https://ip.hetzner.com 2>/dev/null | tr -d '\n' || echo "")
    printf '{"ipv4": "%s", "ipv6": "%s"}' "$ipv4" "$ipv6"
  EOT
  ]
}
