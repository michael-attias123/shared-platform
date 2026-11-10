# Takes over what QuantumOps' oci.sh created (see main.tf). The ids are looked up by name, so nothing
# tenancy-specific is committed. Once imported these blocks are no-ops; they stay as the record of
# where the resources came from. take_over = false skips them (the mocked tests: `tofu test` cannot
# import, and a fresh tenancy has nothing to take over).

variable "take_over" {
  description = "Import the bucket, budget and alerts oci.sh created. false only for tests or a fresh tenancy."
  type        = bool
  default     = true
}

data "oci_budget_budgets" "existing" {
  count          = var.take_over ? 1 : 0
  compartment_id = var.tenancy_ocid
  display_name   = var.budget_name
}

data "oci_budget_alert_rules" "existing" {
  count     = var.take_over ? 1 : 0
  budget_id = local.existing_budget_id
}

locals {
  existing_budget_id = var.take_over ? one(data.oci_budget_budgets.existing[0].budgets[*].id) : ""
  existing_alert_ids = var.take_over ? { for r in data.oci_budget_alert_rules.existing[0].alert_rules : r.display_name => r.id } : {}
}

import {
  for_each = var.take_over ? toset(["state"]) : toset([])
  to       = oci_objectstorage_bucket.state
  id       = "n/${data.oci_objectstorage_namespace.ns.namespace}/b/${var.state_bucket}"
}

import {
  for_each = var.take_over ? toset(["budget"]) : toset([])
  to       = oci_budget_budget.always_free
  id       = local.existing_budget_id
}

import {
  for_each = var.take_over ? local.alerts : {}
  to       = oci_budget_alert_rule.this[each.key]
  id       = "budgets/${local.existing_budget_id}/alertRules/${local.existing_alert_ids[each.key]}"
}
