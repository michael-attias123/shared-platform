terraform {
  required_version = ">= 1.11.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.6"
    }
  }

  backend "s3" {
    key                         = "platform/github/terraform.tfstate"
    use_path_style              = true
    use_lockfile                = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }
    state {
      method   = method.aes_gcm.main
      enforced = true
    }
    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}

variable "state_passphrase" {
  description = "Encrypts OpenTofu state and plans."
  type        = string
  sensitive   = true
}

variable "github_owner" {
  description = "Repository owner."
  type        = string
  default     = "michael-attias123"
}

variable "repository" {
  description = "This repository."
  type        = string
  default     = "shared-platform"
}

variable "vault_addr" {
  description = "Public Vault URL, published to Actions as the VAULT_ADDR variable (not a secret)."
  type        = string
}

variable "required_checks" {
  description = "CI job names that must pass before merging into main."
  type        = list(string)
  # changes: the others are skipped when their area didn't change, and a skipped job passes, so a failed
  # change detection must block the merge itself. downstream: every project's own CI and plan against the
  # PR (downstream.yml, docs/contract.md).
  default = ["changes", "opentofu", "shellcheck", "tools", "secret scan", "downstream"]
}

variable "take_over" {
  description = "Import what was set by hand before this stack owned it (baseline.tf). false only for tests."
  type        = bool
  default     = true
}

provider "github" {
  owner = var.github_owner
}

resource "github_repository_ruleset" "main" {
  name        = "main"
  repository  = var.repository
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      dynamic "required_check" {
        for_each = var.required_checks
        content {
          context = required_check.value
        }
      }
    }
  }
}

resource "github_actions_variable" "vault_addr" {
  repository    = var.repository
  variable_name = "VAULT_ADDR"
  value         = var.vault_addr
}
