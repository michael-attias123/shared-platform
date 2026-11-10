output "state_bucket" {
  description = "The OpenTofu state bucket (every stack's backend)."
  value       = oci_objectstorage_bucket.state.name
}

output "s3_endpoint" {
  description = "The bucket's S3-compatible endpoint, for backend configs."
  value       = "https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oci.customer-oci.com"
}

output "budget_alerts" {
  description = "The budget's alert rules (names only)."
  value       = sort(keys(oci_budget_alert_rule.this))
}
