# Mocked OCI: no account, no credentials. The data sources return what oci.sh created.
mock_provider "oci" {
  mock_data "oci_objectstorage_namespace" {
    defaults = { namespace = "testns" }
  }
  mock_data "oci_identity_user" {
    defaults = { email = "owner@example.com" }
  }
  mock_data "oci_budget_budgets" {
    defaults = { budgets = [{ id = "ocid1.budget.oc1..b" }] }
  }
  mock_data "oci_budget_alert_rules" {
    defaults = {
      alert_rules = [
        { id = "ocid1.alertrule.oc1..any", display_name = "any-spend" },
        { id = "ocid1.alertrule.oc1..c50", display_name = "credits-50" },
        { id = "ocid1.alertrule.oc1..c150", display_name = "credits-150" },
        { id = "ocid1.alertrule.oc1..c250", display_name = "credits-250" },
      ]
    }
  }
}

variables {
  region           = "il-jerusalem-1"
  tenancy_ocid     = "ocid1.tenancy.oc1..t"
  user_ocid        = "ocid1.user.oc1..u"
  state_passphrase = "test-only-not-a-real-passphrase"
  # `tofu test` cannot import (it panics); the import blocks get their first run in the real plan,
  # which must show imports only.
  take_over = false
}

run "takes_over_what_oci_sh_made" {
  command = plan

  assert {
    condition     = oci_objectstorage_bucket.state.name == "qops-tofu-state" && oci_objectstorage_bucket.state.versioning == "Enabled"
    error_message = "the state bucket keeps its name and versioning"
  }

  assert {
    condition     = oci_objectstorage_bucket.state.access_type == "NoPublicAccess"
    error_message = "the state bucket is never public"
  }

  assert {
    condition     = oci_budget_budget.always_free.amount == 1 && oci_budget_budget.always_free.targets == tolist(["ocid1.tenancy.oc1..t"])
    error_message = "the budget stays the $1 guard on the tenancy"
  }

  assert {
    condition     = toset(keys(oci_budget_alert_rule.this)) == toset(["any-spend", "credits-50", "credits-150", "credits-250"])
    error_message = "the four alerts oci.sh made"
  }

  assert {
    condition     = oci_budget_alert_rule.this["any-spend"].threshold == 1 && oci_budget_alert_rule.this["any-spend"].threshold_type == "PERCENTAGE"
    error_message = "any spend at all alerts"
  }

  assert {
    condition     = alltrue([for r in oci_budget_alert_rule.this : r.recipients == "owner@example.com"])
    error_message = "alerts go to the OCI user's email by default"
  }
}

run "alert_email_override" {
  command = plan

  variables {
    alert_email = "alerts@example.com"
  }

  assert {
    condition     = alltrue([for r in oci_budget_alert_rule.this : r.recipients == "alerts@example.com"])
    error_message = "alert_email overrides the user's email"
  }
}

run "rejects_a_short_passphrase" {
  command = plan

  variables {
    state_passphrase = "short"
  }

  expect_failures = [var.state_passphrase]
}

run "s3_endpoint" {
  command = plan

  variables {
    take_over = false
  }

  assert {
    condition     = output.s3_endpoint == "https://testns.compat.objectstorage.il-jerusalem-1.oci.customer-oci.com"
    error_message = "the S3 endpoint backends use"
  }
}
