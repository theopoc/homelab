# DNS Module
# Sets up Route53 DNS record pointing to origin IP

locals {
  # Extract root domain (e.g., sub.etcd.me -> etcd.me)
  domain_parts = split(".", var.domain)
  root_domain  = join(".", slice(local.domain_parts, length(local.domain_parts) - 2, length(local.domain_parts)))

  tags = merge(var.tags, {
    module = "dns"
  })
}

resource "aws_route53domains_domain" "this" {
  count       = var.create_domain_registration ? 1 : 0
  domain_name = local.root_domain
  auto_renew  = var.domain_auto_renew


  dynamic "admin_contact" {
    for_each = var.domain_admin_contact != null ? [var.domain_admin_contact] : []
    content {
      address_line_1    = lookup(admin_contact.value, "address_line_1", null)
      address_line_2    = lookup(admin_contact.value, "address_line_2", null)
      city              = lookup(admin_contact.value, "city", null)
      contact_type      = lookup(admin_contact.value, "contact_type", null)
      country_code      = lookup(admin_contact.value, "country_code", null)
      email             = lookup(admin_contact.value, "email", null)
      fax               = lookup(admin_contact.value, "fax", null)
      first_name        = lookup(admin_contact.value, "first_name", null)
      last_name         = lookup(admin_contact.value, "last_name", null)
      organization_name = lookup(admin_contact.value, "organization_name", null)
      phone_number      = lookup(admin_contact.value, "phone_number", null)
      state             = lookup(admin_contact.value, "state", null)
      zip_code          = lookup(admin_contact.value, "zip_code", null)
    }
  }

  dynamic "registrant_contact" {
    for_each = var.domain_registrant_contact != null ? [var.domain_registrant_contact] : []
    content {
      address_line_1    = lookup(registrant_contact.value, "address_line_1", null)
      address_line_2    = lookup(registrant_contact.value, "address_line_2", null)
      city              = lookup(registrant_contact.value, "city", null)
      contact_type      = lookup(registrant_contact.value, "contact_type", null)
      country_code      = lookup(registrant_contact.value, "country_code", null)
      email             = lookup(registrant_contact.value, "email", null)
      fax               = lookup(registrant_contact.value, "fax", null)
      first_name        = lookup(registrant_contact.value, "first_name", null)
      last_name         = lookup(registrant_contact.value, "last_name", null)
      organization_name = lookup(registrant_contact.value, "organization_name", null)
      phone_number      = lookup(registrant_contact.value, "phone_number", null)
      state             = lookup(registrant_contact.value, "state", null)
      zip_code          = lookup(registrant_contact.value, "zip_code", null)
    }
  }

  dynamic "tech_contact" {
    for_each = var.domain_tech_contact != null ? [var.domain_tech_contact] : []
    content {
      address_line_1    = lookup(tech_contact.value, "address_line_1", null)
      address_line_2    = lookup(tech_contact.value, "address_line_2", null)
      city              = lookup(tech_contact.value, "city", null)
      contact_type      = lookup(tech_contact.value, "contact_type", null)
      country_code      = lookup(tech_contact.value, "country_code", null)
      email             = lookup(tech_contact.value, "email", null)
      fax               = lookup(tech_contact.value, "fax", null)
      first_name        = lookup(tech_contact.value, "first_name", null)
      last_name         = lookup(tech_contact.value, "last_name", null)
      organization_name = lookup(tech_contact.value, "organization_name", null)
      phone_number      = lookup(tech_contact.value, "phone_number", null)
      state             = lookup(tech_contact.value, "state", null)
      zip_code          = lookup(tech_contact.value, "zip_code", null)
    }
  }

  tags = local.tags
}

data "aws_route53_zone" "this" {
  name = local.root_domain
}


# DNS A record pointing to gateway IP (for ingress traffic) or origin IP
resource "aws_route53_record" "this" {
  zone_id = data.aws_route53_zone.this.id
  name    = var.domain
  type    = "A"
  ttl     = 60
  records = [coalesce(var.gateway_ip, var.origin_ip)]
}

# Additional subdomain A records (e.g., argo.etcd.me)
# Uses gateway_ip if set, otherwise falls back to origin_ip
resource "aws_route53_record" "subdomains" {
  for_each = toset(var.additional_subdomains)

  zone_id = data.aws_route53_zone.this.id
  name    = "${each.value}.${var.domain}"
  type    = "A"
  ttl     = 60
  records = [coalesce(var.gateway_ip, var.origin_ip)]
}
