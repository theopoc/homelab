# DNS Module Variables

variable "domain" {
  description = "The domain name (e.g., etcd.me)"
  type        = string
}

variable "additional_subdomains" {
  description = "Additional subdomains to create (e.g., ['argo'] creates argo.etcd.me)"
  type        = list(string)
  default     = []
}

variable "origin_ip" {
  description = "Origin server IP address (used for root domain)"
  type        = string
}

variable "gateway_ip" {
  description = "Gateway LoadBalancer IP address (used for subdomains). If not set, uses origin_ip."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
