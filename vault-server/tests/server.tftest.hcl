# Offline checks with mocked providers (CI; no credentials).

mock_provider "oci" {}
mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = {
      zone_id = "0123456789abcdef0123456789abcdef"
    }
  }
}

variables {
  region              = "test-region-1"
  tenancy_ocid        = "ocid1.tenancy.oc1..test"
  state_passphrase    = "test-passphrase-not-secret"
  ssh_public_key      = "ssh-ed25519 AAAATEST admin"
  vault_hostname      = "vault.example.com"
  cloudflare_zone     = "example.com"
  image_ocid          = "ocid1.image.oc1..test"
  availability_domain = "Abcd:TEST-REGION-1-AD-1"
}

run "closed_until_initialized" {
  command = apply

  assert {
    condition     = oci_core_instance.vault.shape == "VM.Standard.E2.1.Micro"
    error_message = "Vault must run on the Always Free AMD micro shape."
  }
  assert {
    condition = alltrue([
      for r in oci_core_security_list.vault.ingress_security_rules :
      r.source == "10.30.0.0/16" && one(r.tcp_options).min == 22
    ])
    error_message = "Before init, the only inbound rule is SSH from inside the VCN (Bastion)."
  }
  assert {
    condition     = length(oci_core_default_security_list.default.ingress_security_rules) == 0
    error_message = "The VCN default security list must be empty."
  }
  assert {
    condition     = cloudflare_dns_record.vault.proxied == false && cloudflare_dns_record.vault.type == "A"
    error_message = "The DNS record must be DNS-only, so TLS ends on the VM."
  }
  assert {
    condition     = strcontains(join("\n", oci_identity_policy.vault.statements), "target.key.id = '${oci_kms_key.seal.id}'")
    error_message = "The VM may use only its own unseal key."
  }
  assert {
    condition = alltrue([
      for s in ["seal \"ocikms\"", "address                          = \"127.0.0.1:8200\"", "vault=2.2.1-1", "disable_http_challenge"] :
      strcontains(base64decode(oci_core_instance.vault.metadata["user_data"]), s)
    ])
    error_message = "cloud-init must pin Vault, bind it to localhost, auto-unseal with OCI KMS and use TLS-ALPN in Caddy."
  }
}

run "exposed_after_init" {
  command = apply
  variables {
    expose_public = true
  }

  assert {
    condition = length([
      for r in oci_core_security_list.vault.ingress_security_rules : r
      if r.source == "0.0.0.0/0" && one(r.tcp_options).min == 443 && one(r.tcp_options).max == 443
    ]) == 1
    error_message = "When exposed, exactly one rule opens 443 to the internet."
  }
  assert {
    condition = length([
      for r in oci_core_security_list.vault.ingress_security_rules : r
      if r.source == "0.0.0.0/0" && one(r.tcp_options).min != 443
    ]) == 0
    error_message = "Nothing but 443 may be open to the internet."
  }
}

run "rejects_a1_shape" {
  command = plan
  variables {
    shape = "VM.Standard.A1.Flex"
  }
  expect_failures = [var.shape]
}

run "rejects_too_much_disk" {
  command = plan
  variables {
    boot_volume_gb = 150
  }
  expect_failures = [var.boot_volume_gb]
}
