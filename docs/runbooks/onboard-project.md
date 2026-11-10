# Onboarding a project

Each project gets:
- `kv/<project>/*` for its secrets;
- a read and a write policy;
- login roles.

Machines get the read policy (plus any write sub-paths a role declares); you, the admin, write secrets.
`kv/<project>/platform/*` is for what the platform mints for the project.

## 1. Declare it
Add `projects/<project>.yaml` in a PR (see [`projects/house-manager.yaml`](../../projects/house-manager.yaml)):
```yaml
repo: michael-attias123/myapp            # must be one of this account's repos
vault:
  roles:                                  # each is one GitHub Actions role: <project>-<owner>-<repo>[-<role>]
    - role: main
      ref: refs/heads/main
      write: [generated]                  # optional: kv/myapp/generated is writable by this role
    - role: pr
      ref: "refs/pull/*"                  # a glob: any pull request of the repo
  kubernetes:                             # needs stacks/vault-config/clusters/<cluster>.pub.pem
    - { cluster: mycluster, namespace: external-secrets, service_account: external-secrets }
  approle: true                           # VMs and scripts
  shared_credentials: [supabase]          # kv/shared/supabase (listed in projects/_shared.yaml)
  secrets:                                # what `make vault-seed` fills and the bootstrap checks expect
    database: [url, password]
```
After the merge, the vault-config stack applies it: `make plan/apply STACK=vault-config` from the laptop
until SP4 moves that to CI. A file can't grant a role to another account's repo or to an unknown cluster:
the stack's `check` blocks fail the plan.

Files starting with `_` aren't projects:
- `_shared.yaml` lists the account-wide credentials under `kv/shared/`;
- `_platform.yaml` lists the platform's own, under `kv/platform/`.

## 2. Add secrets
```bash
make vault-login
make vault-seed PROJECT=myapp                       # prompts (hidden) for each missing key
make vault-seed PROJECT=myapp ARGS=--check          # lists what is there and what is missing
```
- **Existing values** in Vault are never overwritten. Change one with
  `vault kv patch -mount=kv myapp/database password=-` (`-` reads stdin).
- **GitHub access:** `make github-app APP=myapp-bot`
  ([github-apps.md](github-apps.md)).

## 3. Connect the client

### Kubernetes (External Secrets Operator)
First add the cluster's public key once:
- `stacks/vault-config/clusters/mycluster.pub.pem`, from the cluster's service-account signing key. In k3s:
  `sudo openssl rsa -in /var/lib/rancher/k3s/server/tls/service.key -pubout`.
- Or for any cluster, convert `kubectl get --raw /openid/v1/jwks`.

This creates the `jwt-k8s-mycluster` mount. Then in the cluster:
```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: { name: vault }
spec:
  provider:
    vault:
      server: https://vault.<ip-with-dashes>.sslip.io
      path: kv
      version: v2
      auth:
        jwt:
          path: jwt-k8s-mycluster
          role: myapp-external-secrets-external-secrets   # <project>-<namespace>-<service account>
          kubernetesServiceAccountToken:
            serviceAccountRef: { name: external-secrets, namespace: external-secrets, audiences: [vault] }
```

### GitHub Actions
With the platform's [`tofu-stack.yml`](../../.github/workflows/tofu-stack.yml) pass `vault-role` and
`vault-secrets`. In any other job use the `vault-env` action:
```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: michael-attias123/shared-platform/.github/actions/vault-env@main
    with:
      addr: ${{ vars.VAULT_ADDR }}
      role: myapp-michael-attias123-myapp-main        # <project>-<owner>-<repo>[-<role>]
      secrets: |
        kv/data/myapp/database password | DB_PASSWORD
```

### VMs and scripts (AppRole)
Run `make vault-approle-secret PROJECT=myapp`. It writes `~/.config/platform/approle-myapp.env`; copy it to the VM
(mode 0600). Then on the VM:
```bash
set -a; . ./approle-myapp.env; set +a
export VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")"
vault kv get -field=password kv/myapp/database
```
