# The baseline every project repo gets from the platform: main can't be pushed to directly, deleted or
# rewritten; Actions run with a read-only default token and only the listed actions; the repo knows where
# Vault is. The project keeps its own required-checks rule next to this one (rulesets stack).
# Called once per projects/<name>.yaml with `github: { baseline: true }` (see ../../baseline.tf).
# Secret scanning has no resource of its own in the provider: ../../scripts/repo-security.sh sets it.

terraform {
  required_providers {
    github = {
      source = "integrations/github"
    }
  }
}

variable "repository" {
  description = "Repository name (the owner is set on the provider)."
  type        = string
}

variable "vault_addr" {
  description = "Public Vault URL, published as the VAULT_ADDR Actions variable."
  type        = string
}

variable "allowed_actions" {
  description = "Action patterns the repo may use (owner/* or owner/repo@*). GitHub's own actions are always allowed."
  type        = list(string)

  validation {
    condition     = alltrue([for a in var.allowed_actions : can(regex("^[A-Za-z0-9_.-]+/(\\*|[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[A-Za-z0-9_.*-]+)$", a))])
    error_message = "allowed_actions entries look like owner/* or owner/repo@* (or @v1, or a commit SHA)."
  }
}

resource "github_repository_ruleset" "baseline" {
  name        = "platform-baseline"
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

    # One maintainer: a pull request is required, a review is not.
    pull_request {
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# A job gets a read-only token unless its workflow asks for more, and no workflow can approve a PR.
resource "github_workflow_repository_permissions" "this" {
  repository                       = var.repository
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

resource "github_actions_repository_permissions" "this" {
  repository      = var.repository
  enabled         = true
  allowed_actions = "selected"

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = false
    patterns_allowed     = sort(distinct(var.allowed_actions))
  }
}

resource "github_actions_variable" "vault_addr" {
  repository    = var.repository
  variable_name = "VAULT_ADDR"
  value         = var.vault_addr
}

output "ruleset" {
  description = "Name of the baseline ruleset."
  value       = github_repository_ruleset.baseline.name
}

output "allowed_actions" {
  description = "The action patterns the repo may use."
  value       = github_actions_repository_permissions.this.allowed_actions_config[0].patterns_allowed
}
