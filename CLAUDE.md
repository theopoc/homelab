# Claude Code Guidelines for this Project

## Golden Rule: Infrastructure as Code Only

**NEVER modify cluster resources directly.** All changes must be made through Infrastructure as Code:

- **Terraform/Terragrunt** for infrastructure (Hetzner servers, DNS, Talos images)
- **ArgoCD Applications** for Kubernetes resources
- **Git commits** to persist all changes

If we cannot replicate everything with IaC, the mission has failed.

### What NOT to do:
- `kubectl delete/apply/patch` directly
- `talosctl` commands that modify state (upgrade is acceptable only if not automatable via Terraform)
- Manual helm installs
- Any imperative commands that change cluster state

### What TO do:
- Modify ArgoCD manifests in `argocd/base/` or `argocd/overlays/`
- Update Terraform/Terragrunt configurations
- Commit changes to git
- Let ArgoCD sync automatically or trigger sync via ArgoCD CLI

## Project Structure

- `terraform/live/` - Per-cluster Terragrunt stacks
- `terraform/modules/` - Reusable Terraform modules (cluster, dns, firewall)
- `argocd/base/` - Shared manifests with placeholders
- `argocd/overlays/` - Per-cluster config (secrets, domains, patches)
- `tasks/` - Taskfile automation scripts
