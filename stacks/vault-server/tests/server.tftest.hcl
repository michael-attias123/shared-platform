# Offline checks with mocked providers (CI; no credentials).

mock_provider "oci" {
  mock_resource "oci_core_public_ip" {
    defaults = {
      ip_address = "203.0.113.7"
    }
  }
}

variables {
  region              = "test-region-1"
  tenancy_ocid        = "ocid1.tenancy.oc1..test"
  state_passphrase    = "test-passphrase-not-secret"
  ssh_public_key      = "ssh-ed25519 AAAATEST admin"
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
    condition     = output.vault_addr == "https://vault.203-0-113-7.sslip.io"
    error_message = "The public name must be derived from the reserved IP (sslip.io)."
  }
  assert {
    condition     = oci_core_public_ip.vault.lifetime == "RESERVED"
    error_message = "The public IP must be reserved, so the name never changes."
  }
  assert {
    condition     = strcontains(join("\n", oci_identity_policy.vault.statements), "target.key.id = '${oci_kms_key.seal.id}'")
    error_message = "The VM may use only its own unseal key."
  }
  assert {
    condition     = strcontains(join("\n", oci_identity_policy.vault.statements), "instance-agent-command-execution-family in compartment platform where request.instance.id = target.instance.id")
    error_message = "Run Command (admin access through HTTPS) must be allowed for the VM itself only."
  }
  assert {
    condition = alltrue([
      for s in ["seal \"ocikms\"", "address                          = \"127.0.0.1:8200\"", "vault=2.2.1-1", "disable_http_challenge", "vault.$${ip//./-}.sslip.io", "ocarun ALL=(ALL) NOPASSWD:ALL", "  - age"] :
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
