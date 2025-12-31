# Kubernetes cluster on Hetzner Cloud using Talos Linux
# Uses fork with external firewall support:
# https://github.com/sofianedjerbi/terraform-hcloud-kubernetes

locals {
  # Gateway API manifest URL
  gateway_api_manifest_url = var.gateway_api_enabled ? "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/${var.gateway_api_experimental ? "experimental" : "standard"}-install.yaml" : null

  # Merge Cilium helm values with Gateway API settings
  cilium_helm_values = merge(
    var.cilium_helm_values,
    var.gateway_api_enabled ? {
      gatewayAPI = {
        enabled = true
      }
    } : {}
  )
}

module "kubernetes" {
  source = "git::https://github.com/sofianedjerbi/terraform-hcloud-kubernetes.git?ref=feat/external-firewall-support"

  cluster_name = var.cluster_name
  hcloud_token = var.hcloud_token

  # Control plane nodes
  control_plane_nodepools = var.control_plane_nodepools

  # Worker nodes (optional)
  worker_nodepools = var.worker_nodepools

  # Floating IP for ingress
  control_plane_public_vip_ipv4_enabled = true

  # External firewall management (managed by firewall module)
  firewall_id               = var.firewall_id
  firewall_use_current_ipv4 = var.firewall_id == null

  # Cilium CNI with Gateway API support
  cilium_enabled     = true
  cilium_helm_values = local.cilium_helm_values

  # Cert Manager
  cert_manager_enabled = true

  # Longhorn storage
  longhorn_enabled               = true
  longhorn_default_storage_class = true

  # Disable NGINX ingress (using Cilium Gateway API instead)
  ingress_nginx_enabled = false

  # Talos config patches for extensions
  control_plane_config_patches = var.control_plane_config_patches
  worker_config_patches        = var.worker_config_patches

  # Gateway API CRDs as inline manifest
  talos_extra_inline_manifests = var.gateway_api_enabled ? [
    {
      name     = "gateway-api-crds"
      contents = data.http.gateway_api_crds[0].response_body
    }
  ] : null

  # Output configs to files
  cluster_kubeconfig_path  = var.kubeconfig_path
  cluster_talosconfig_path = var.talosconfig_path

  # Delete protection (set false to allow destroy)
  cluster_delete_protection = var.cluster_delete_protection

  # Graceful destroy (set false to skip etcd leave)
  cluster_graceful_destroy = var.cluster_graceful_destroy

  prometheus_operator_crds_enabled = false
}
