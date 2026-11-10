mock_provider "github" {}

variables {
  state_passphrase = "test-passphrase-not-secret"
  vault_addr       = "https://vault.example.com"
  take_over        = false
}

run "main_is_protected" {
  command = apply

  assert {
    condition     = github_repository_ruleset.main.rules[0].deletion && github_repository_ruleset.main.rules[0].non_fast_forward
    error_message = "main must be protected against deletion and force pushes."
  }
  assert {
    condition     = length(github_repository_ruleset.main.bypass_actors) == 0
    error_message = "Nobody bypasses the rules in this repo."
  }
  assert {
    condition     = github_actions_variable.vault_addr.value == "https://vault.example.com"
    error_message = "Actions get VAULT_ADDR as a variable."
  }
  assert {
    condition     = contains([for c in github_repository_ruleset.main.rules[0].required_status_checks[0].required_check : c.context], "downstream")
    error_message = "A platform PR can't merge before every project's check passed against it."
  }
}

# projects/house-manager.yaml asks for the baseline; projects/smoke.yaml (this repo) does not.
run "projects_get_the_baseline" {
  command = apply

  assert {
    condition     = join(",", output.baseline_repositories) == "michael-attias123/house-manager"
    error_message = "Only projects with github.baseline get the baseline."
  }
  assert {
    condition     = module.baseline["house-manager"].ruleset == "platform-baseline"
    error_message = "The baseline ruleset has its own name, so it stacks with the project's rules."
  }
  assert {
    condition = alltrue([
      for a in ["michael-attias123/*", "opentofu/setup-opentofu@*", "gitleaks/gitleaks-action@*", "denoland/setup-deno@*"] :
      contains(module.baseline["house-manager"].allowed_actions, a)
    ])
    error_message = "A project may use what the building blocks use, plus what it declared."
  }
}

run "baseline_rules" {
  command = apply

  module {
    source = "./modules/baseline"
  }
  variables {
    repository      = "myapp"
    allowed_actions = ["acme/*", "acme/tool@v1"]
  }

  assert {
    condition     = github_repository_ruleset.baseline.rules[0].deletion && github_repository_ruleset.baseline.rules[0].non_fast_forward
    error_message = "The default branch can't be deleted or rewritten."
  }
  assert {
    condition     = github_repository_ruleset.baseline.rules[0].pull_request[0].required_approving_review_count == 0
    error_message = "A pull request is required, a review is not (one maintainer)."
  }
  assert {
    condition     = length(github_repository_ruleset.baseline.rules[0].required_status_checks) == 0
    error_message = "Required checks stay with the project."
  }
  assert {
    condition     = github_workflow_repository_permissions.this.default_workflow_permissions == "read" && !github_workflow_repository_permissions.this.can_approve_pull_request_reviews
    error_message = "The default Actions token is read-only."
  }
  assert {
    condition     = github_actions_repository_permissions.this.allowed_actions == "selected" && !github_actions_repository_permissions.this.allowed_actions_config[0].verified_allowed
    error_message = "Only listed actions run."
  }
}

run "bad_action_pattern_is_refused" {
  command = plan

  module {
    source = "./modules/baseline"
  }
  variables {
    repository      = "myapp"
    allowed_actions = ["*"]
  }

  expect_failures = [var.allowed_actions]
}
