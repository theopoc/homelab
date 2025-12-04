# Homelab Infrastructure

Kubernetes cluster on Hetzner Cloud with Talos, managed via GitOps.

## Prerequisites

- [Taskfile](https://taskfile.dev)
- [Terragrunt](https://terragrunt.gruntwork.io)
- [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
- `kubectl`, `helm`

## Quick Start

```bash
# 1. Configure credentials
cp .env.example .env
# Edit .env with your values

# 2. Generate secrets
task argocd:generate-secrets

# 3. Deploy infrastructure
task tg -- stack run apply terraform/live/etcdme-nbg1-dc3

# 4. Bootstrap ArgoCD
task argocd:bootstrap
```

## Structure

```
terraform/          # Infrastructure (Hetzner, DNS, Talos)
argocd/
  base/             # Shared manifests (placeholders)
  overlays/         # Per-cluster config (secrets, domains)
tasks/              # Taskfile automation
```

## Tasks

```bash
task                           # Show help
task argocd:generate-secrets   # Generate encrypted secrets
task argocd:bootstrap          # Deploy ArgoCD + apps
task argocd:password           # Get ArgoCD admin password
task tg -- <cmd> <path>        # Run terragrunt command in path
task tg:bootstrap              # Initialize S3 backend
```

## Adding a New Cluster

1. Copy overlay: `cp -r argocd/overlays/etcdme-nbg1-dc3 argocd/overlays/new-cluster`
2. Edit `kustomization.yaml` (domain, repo-url, overlay-path)
3. Create terragrunt stack in `terraform/live/new-cluster/`
4. Generate secrets and deploy
