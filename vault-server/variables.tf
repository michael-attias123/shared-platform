# Credentials and account IDs come from scripts/tofu.sh (TF_VAR_*); settings.auto.tfvars holds the public settings.

variable "region" {
  description = "OCI home region."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (from ~/.oci/config)."
  type        = string
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config."
  type        = string
  default     = "DEFAULT"
}

variable "state_passphrase" {
  description = "Encrypts OpenTofu state and plans (shared with QuantumOps, ~/.config/qops/tofu.env)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}

variable "ssh_public_key" {
  description = "Admin SSH public key, used only through OCI Bastion sessions."
  type        = string
}

variable "vault_hostname" {
  description = "Public name of Vault, e.g. vault.example.com. Must be inside cloudflare_zone."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.vault_hostname))
    error_message = "vault_hostname must be a lowercase DNS name like vault.example.com."
  }
}

variable "cloudflare_zone" {
  description = "Cloudflare zone (your domain) that holds vault_hostname, e.g. example.com."
  type        = string
}

variable "expose_public" {
  description = "Open TCP 443 to the internet. Keep false until `make vault-init` has run: an uninitialized Vault must never be public."
  type        = bool
  default     = false
}

# Always Free guard: only the AMD micro shape (2 per tenancy, free forever). Never A1 (QuantumOps owns that allowance).
variable "shape" {
  description = "Compute shape for the Vault VM."
  type        = string
  default     = "VM.Standard.E2.1.Micro"

  validation {
    condition     = var.shape == "VM.Standard.E2.1.Micro"
    error_message = "Only VM.Standard.E2.1.Micro is allowed (Always Free; the A1 allowance belongs to the QuantumOps cluster)."
  }
}

variable "boot_volume_gb" {
  description = "Boot volume size. Always Free block storage is 200 GB per tenancy (the QuantumOps node uses 100)."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_gb >= 47 && var.boot_volume_gb <= 100
    error_message = "boot_volume_gb must be 47-100 to stay inside the 200 GB Always Free block storage."
  }
}

variable "vault_version" {
  description = "Vault version from HashiCorp's apt repository (pinned; Renovate proposes updates)."
  type        = string
  default     = "2.2.1"
}

variable "image_ocid" {
  description = "Pin a node image. Default (null): newest Canonical Ubuntu 24.04 Minimal for the micro shape."
  type        = string
  default     = null
}

variable "availability_domain" {
  description = "Availability domain. Default (null): the first one."
  type        = string
  default     = null
}

variable "vcn_cidr" {
  description = "Private range of the platform VCN."
  type        = string
  default     = "10.30.0.0/16"
}

variable "snapshot_retention_days" {
  description = "Days to keep daily Raft snapshots in Object Storage."
  type        = number
  default     = 30
}
