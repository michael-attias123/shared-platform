terraform {
  required_version = ">= 1.11.0" # ephemeral variables + write-only attributes (admin password never in state)

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }

  backend "s3" {
    key                         = "platform/vault-config/terraform.tfstate"
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

# VAULT_ADDR and VAULT_TOKEN come from scripts/tofu.sh (your `make vault-login` token, or the root token once).
provider "vault" {}
