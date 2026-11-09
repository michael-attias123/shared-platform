mock_provider "github" {}

variables {
  state_passphrase = "test-passphrase-not-secret"
  vault_addr       = "https://vault.example.com"
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
}
