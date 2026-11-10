# Inputs. scripts/tofu.sh sets region, tenancy_ocid, user_ocid and oci_profile from ~/.oci/config,
# and state_passphrase from the local state env file. Nothing here is committed with a value.

variable "region" {
  description = "OCI home region."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (from ~/.oci/config)."
  type        = string
}

variable "user_ocid" {
  description = "Your OCI user (from ~/.oci/config): the budget alerts go to its email, which never sits in the repo."
  type        = string
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config."
  type        = string
  default     = "DEFAULT"
}

variable "state_passphrase" {
  description = "Encrypts OpenTofu state and plans (shared by every stack in the bucket)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}

variable "alert_email" {
  description = "Where budget alerts go. Empty (default): your OCI user's email."
  type        = string
  default     = ""
}

variable "state_bucket" {
  description = "The OpenTofu state bucket, created by QuantumOps' oci.sh before this stack existed."
  type        = string
  default     = "qops-tofu-state"
}

variable "budget_name" {
  description = "The tenancy's one budget (OCI allows one per compartment), created by QuantumOps' oci.sh."
  type        = string
  default     = "qops-always-free"
}
