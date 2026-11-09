.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
STACK ?= vault-server
ARGS ?=
TOFU := STACK=$(STACK) bash scripts/tofu.sh
VAULT := bash scripts/vault.sh

.PHONY: help tools cloudflare-login check lint plan apply output \
	vault-bootstrap-status vault-ssh vault-init vault-admin vault-login vault-mfa-enroll vault-revoke-root \
	vault-snapshot-setup vault-approle-secret vault-health config-plan-root config-apply-root

help: ## Show targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# --- setup -----------------------------------------------------------------------------------------------------------
tools: ## Install the Vault CLI (other tools: QuantumOps make tools-admin)
	bash scripts/setup.sh tools

cloudflare-login: ## Save a Cloudflare API token (hidden prompt)
	bash scripts/setup.sh cloudflare-login

# --- infrastructure as code ------------------------------------------------------------------------------------------
check: ## Offline: fmt, validate, mocked tests for all stacks (same as CI)
	$(TOFU) check

lint: ## shellcheck
	shellcheck -x -P SCRIPTDIR scripts/*.sh

plan: ## Plan a stack: make plan STACK=vault-server|vault-config|github
	$(TOFU) plan $(ARGS)

apply: ## Apply the reviewed plan: make apply STACK=...
	$(TOFU) apply

output: ## Show a stack's outputs
	$(TOFU) output $(ARGS)

config-plan-root: ## First setup only: plan vault-config with the root token
	$(VAULT) with-root env STACK=vault-config bash scripts/tofu.sh plan

config-apply-root: ## First setup only: apply that plan with the root token
	$(VAULT) with-root env STACK=vault-config bash scripts/tofu.sh apply

# --- operating Vault -------------------------------------------------------------------------------------------------
vault-bootstrap-status: ## First-boot progress on the VM (via Bastion)
	bash scripts/bastion.sh status

vault-ssh: ## Shell on the Vault VM (via Bastion)
	bash scripts/bastion.sh ssh

vault-init: ## Initialize Vault (once); keys -> ~/.config/platform/vault-init.json
	$(VAULT) init

vault-admin: ## Create or rotate the admin user (hidden prompt)
	$(VAULT) admin

vault-login: ## Log in as admin -> ~/.vault-token
	$(VAULT) login

vault-mfa-enroll: ## Show the admin TOTP QR code (once)
	$(VAULT) mfa-enroll

vault-revoke-root: ## Revoke the root token after setup
	$(VAULT) revoke-root

vault-snapshot-setup: ## Install the snapshot token on the VM and take a snapshot
	$(VAULT) snapshot-setup

vault-approle-secret: ## New AppRole secret ID: make vault-approle-secret PROJECT=name
	$(VAULT) approle-secret

vault-health: ## Public health check
	$(VAULT) health
