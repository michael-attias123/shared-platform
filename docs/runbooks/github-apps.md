# GitHub Apps

The platform and each project use a GitHub App instead of a personal access token. An app gets
short-lived installation tokens, has no yearly expiry, and is limited to the repos it's installed on.

| App | Installed on | Its id and key live in | Used for |
|---|---|---|---|
| `platform-bot` | every project repo and shared-platform | `kv/platform/github-app` | starting the downstream checks and reading their results, starting a project's apply after a platform change, the github stack's baselines |
| `<project>-bot` | that project's repo only | `kv/<project>/providers` (`github_app_id`, `github_app_private_key`) | the project's own OpenTofu GitHub provider (it replaces `GH_ADMIN_TOKEN`) |

## Creating one
```bash
make vault-login
make github-app APP=platform-bot          # or APP=house-manager-bot
```
1. **Open the page** the script prints, and click **Create GitHub App** on GitHub.
2. **Come back here:** GitHub sends you to this page with `?code=...` in the address bar. Copy the whole
   address and paste it into the script's hidden prompt. The code works once, within an hour.
3. **The script stores the app:**
   - it writes the app's id and private key to Vault;
   - it prints the permissions GitHub granted, and warns about any it didn't;
   - it prints the install link.
4. **Install the app** with that link: on all repos for `platform-bot`, or on the project's repo only.

If you landed here after creating an app, go back to the terminal: the script is waiting for this page's address.
