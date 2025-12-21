# etcd.me Environment
# Production-grade Kubernetes cluster on Hetzner Cloud

locals {
  cluster_name = "hometheo"
  domain       = "hometheo.click"

  labels = {
    managed_by  = "terraform"
    environment = "production"
    cluster     = local.cluster_name
  }
}

# Firewall management - runs BEFORE cluster to avoid chicken-and-egg with API health checks
unit "firewall" {
  source = "../../modules/firewall"
  path   = "firewall"

  values = {
    firewall_name   = local.cluster_name
    hcloud_token    = get_env("HCLOUD_TOKEN")
    use_current_ip  = true
    extra_admin_ips = []
    labels          = local.labels
  }
}

# Kubernetes cluster (uses external firewall from firewall module)
unit "cluster" {
  source = "../../modules/cluster"
  path   = "cluster"

  values = {
    cluster_name = local.cluster_name
    hcloud_token = get_env("HCLOUD_TOKEN")

    # External firewall management
    firewall_path = "../firewall"

    control_plane_nodepools = [
      {
        name     = "control-plane"
        type     = "cx33"
        location = "nbg1"
        count    = 1
      }
    ]

    # No separate workers - schedule on control planes
    worker_nodepools = []

    # Gateway API support (installs CRDs + enables Cilium Gateway controller)
    gateway_api_enabled      = true
    gateway_api_version      = "v1.4.1"
    gateway_api_experimental = true # Includes TLSRoute

    # Set false to allow cluster destruction
    cluster_delete_protection = false
    cluster_graceful_destroy  = false
  }
}

# DNS records
unit "dns" {
  source = "../../modules/dns"
  path   = "dns"

  values = {
    domain = local.domain
    #additional_subdomains = ["argo", "kube", "loki", "n8n", "auth", "uptime", "playwright.mcp"]
    additional_subdomains = ["kube"]

    # Get control plane IP from cluster output (for kube subdomain)
    cluster_path = "../cluster"

    # Gateway LoadBalancer IP (from Cilium Gateway -> Hetzner CCM)
    # Subdomains point here for ingress traffic
    gateway_ip = "91.98.5.86"

    tags = local.labels
  }
}
