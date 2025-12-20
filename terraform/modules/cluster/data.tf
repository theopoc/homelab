# Fetch Gateway API CRDs manifest
data "http" "gateway_api_crds" {
  count = var.gateway_api_enabled ? 1 : 0
  url   = local.gateway_api_manifest_url
}