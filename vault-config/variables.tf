variable "state_passphrase" {
  description = "Encrypts OpenTofu state and plans (shared with QuantumOps)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}

variable "enforce_admin_mfa" {
  description = "Require TOTP for userpass logins. Turn on only after `make vault-mfa-enroll`, or you lock yourself out."
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub user/org whose repositories may log in with Actions OIDC."
  type        = string
  default     = "michael-attias123"
}
