terraform {
  required_version = ">= 1.11.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.12"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }

  # Same OCI bucket as QuantumOps (bucket/region/endpoint from scripts/tofu.sh); only the key differs.
  backend "s3" {
    key                         = "platform/vault-server/terraform.tfstate"
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
