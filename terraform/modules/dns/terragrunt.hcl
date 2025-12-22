# DNS module unit
# Manages Route53 DNS records

include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "cluster" {
  config_path = values.cluster_path

  mock_outputs = {
    primary_ip = "0.0.0.0"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "./"
}

inputs = {
  domain                     = values.domain
  origin_ip                  = dependency.cluster.outputs.primary_ip
  gateway_ip                 = try(values.gateway_ip, null)
  additional_subdomains      = try(values.additional_subdomains, [])
  tags                       = try(values.tags, {})
  domain_admin_contact       = try(values.domain_admin_contact, null)
  domain_registrant_contact  = try(values.domain_registrant_contact, null)
  domain_tech_contact        = try(values.domain_tech_contact, null)
  domain_auto_renew          = try(values.domain_auto_renew, true)
  create_domain_registration = try(values.create_domain_registration, true)
}
