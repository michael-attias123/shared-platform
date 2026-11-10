# Mocked Vault: no server, no token.
mock_provider "vault" {
  mock_data "vault_kv_secret_v2" {
    defaults = {
      data = { shared = "from-mock" }
    }
  }
}

run "merges_paths" {
  command = plan

  variables {
    paths = ["house-manager/app", "house-manager/monitoring"]
  }

  assert {
    condition     = nonsensitive(output.values["shared"]) == "from-mock"
    error_message = "values must hold the keys of every path"
  }
}

run "rejects_bad_paths" {
  command = plan

  variables {
    paths = ["kv/data/house-manager/app"]
  }

  expect_failures = [var.paths]
}

run "rejects_no_paths" {
  command = plan

  variables {
    paths = []
  }

  expect_failures = [var.paths]
}
