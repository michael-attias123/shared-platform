# Onboarding a project

Each project gets `kv/<project>/*`, a read and a write policy, and login roles. Machines get the read policy;
you (admin) write secrets.

## 1. Declare it
In [`vault-config/projects.tf`](../../vault-config/projects.tf):
```hcl
module "myapp" {
  source = "./modules/project"
  name   = "myapp"

  # Kubernetes: needs vault-config/clusters/<cluster>.pub.pem (the cluster's service-account public key).
  kubernetes = [{ mount = "jwt-k8s-mycluster", namespace = "external-secrets", service_account = "external-secrets" }]

  # GitHub Actions: this repo, only from main.
  github = [{ repository = "michael-attias123/myapp", ref = "refs/heads/main" }]

  # VMs / scripts.
  approle = true
}
```
Open a PR, merge, then `make plan STACK=vault-config` and `make apply STACK=vault-config`.

## 2. Add secrets
```bash
make vault-login
vault kv put kv/myapp/database url=... password=-     # "-" reads the value from stdin
```

## 3. Connect the client

### Kubernetes (External Secrets Operator)
First add the cluster's public key once:
- `vault-config/clusters/mycluster.pub.pem`, from the cluster's service-account signing key. In k3s:
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
```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: hashicorp/vault-action@v3
    with:
      url: https://vault.<ip-with-dashes>.sslip.io
      method: jwt
      path: jwt-github
      role: myapp-michael-attias123-myapp            # <project>-<owner>-<repo>
      jwtGithubAudience: vault
      secrets: kv/data/myapp/database password | DB_PASSWORD
```

### VMs and scripts (AppRole)
Run `make vault-approle-secret PROJECT=myapp`. It writes `~/.config/platform/approle-myapp.env`; copy it to the VM
(mode 0600). Then on the VM:
```bash
set -a; . ./approle-myapp.env; set +a
export VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")"
vault kv get -field=password kv/myapp/database
```
