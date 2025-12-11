# Firewall module unit
# Manages admin IPs for cluster API access

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "./"
}

inputs = {
  firewall_name   = values.firewall_name
  hcloud_token    = values.hcloud_token
  use_current_ip  = try(values.use_current_ip, true)
  extra_admin_ips = try(values.extra_admin_ips, [])
}
