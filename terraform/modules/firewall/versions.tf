terraform {
  required_version = ">= 1.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.0.0"
    }
  }
}