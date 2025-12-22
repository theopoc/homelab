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

variable "domain_auto_renew" {
  description = "Whether to automatically renew the domain registration"
  type        = bool
  default     = true
}

variable "domain_admin_contact" {
  description = "Administrative contact information for domain registration"
  type = object({
    address_line_1    = optional(string)
    address_line_2    = optional(string)
    city              = optional(string)
    contact_type      = optional(string)
    country_code      = optional(string)
    email             = optional(string)
    fax               = optional(string)
    first_name        = optional(string)
    last_name         = optional(string)
    organization_name = optional(string)
    phone_number      = optional(string)
    state             = optional(string)
    zip_code          = optional(string)
  })
  default = null
}

variable "domain_registrant_contact" {
  description = "Registrant contact information for domain registration"
  type = object({
    address_line_1    = optional(string)
    address_line_2    = optional(string)
    city              = optional(string)
    contact_type      = optional(string)
    country_code      = optional(string)
    email             = optional(string)
    fax               = optional(string)
    first_name        = optional(string)
    last_name         = optional(string)
    organization_name = optional(string)
    phone_number      = optional(string)
    state             = optional(string)
    zip_code          = optional(string)
  })
  default = null
}

variable "domain_tech_contact" {
  description = "Technical contact information for domain registration"
  type = object({
    address_line_1    = optional(string)
    address_line_2    = optional(string)
    city              = optional(string)
    contact_type      = optional(string)
    country_code      = optional(string)
    email             = optional(string)
    fax               = optional(string)
    first_name        = optional(string)
    last_name         = optional(string)
    organization_name = optional(string)
    phone_number      = optional(string)
    state             = optional(string)
    zip_code          = optional(string)
  })
  default = null
}

variable "create_domain_registration" {
  description = "Determine whether to register domain"
  type        = bool
  default     = true
}
