# DNS Module
# Sets up Route53 DNS record pointing to origin IP

locals {
  # Extract root domain (e.g., sub.etcd.me -> etcd.me)
  domain_parts = split(".", var.domain)
  root_domain  = join(".", slice(local.domain_parts, length(local.domain_parts) - 2, length(local.domain_parts)))

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "dns"
  })
}


resource "aws_route53_zone" "this" {
  name = "${local.root_domain}."
}


# DNS A record pointing to gateway IP (for ingress traffic) or origin IP
resource "aws_route53_record" "this" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain
  type    = "A"
  ttl     = 300
  records = [coalesce(var.gateway_ip, var.origin_ip)]
}

# Additional subdomain A records (e.g., argo.etcd.me)
# Uses gateway_ip if set, otherwise falls back to origin_ip
resource "aws_route53_record" "subdomains" {
  for_each = toset(var.additional_subdomains)

  zone_id = aws_route53_zone.this.zone_id
  name    = "${each.value}.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [coalesce(var.gateway_ip, var.origin_ip)]
}
