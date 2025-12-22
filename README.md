# etcd.me

High-availability Kubernetes on Hetzner Cloud. Built for resilience.

## High Availability

- **3 control plane nodes** with etcd quorum
- **Self-healing** workloads via Kubernetes
- **Automated failover** with Cilium Gateway API
- **GitOps reconciliation** ensures desired state

## Stack

- **Talos Linux** - Immutable, API-driven Kubernetes OS
- **Terragrunt** - Infrastructure as Code
- **ArgoCD** - GitOps with automatic drift correction
- **SOPS + age** - Encrypted secrets in Git
- **Cilium** - eBPF networking + Gateway API
- **AWS Route 53** - DNS management

## Structure

```
terraform/
  modules/        # Reusable infra (cluster, dns, firewall)
  live/           # Per-cluster stacks
argocd/
  base/           # Shared manifests
  overlays/       # Per-cluster config
tasks/            # Automation
```

## Prerequisite
[mise](https://mise.jdx.dev/installing-mise.html) installed

## Bootstrap

### Install neccesary tools with mise
```bash
mise install
```

### Generate sops age key
```bash
age-keygen --output agekey.txt
```

### Fill information on .env
Copy [.env.example](.env.example) into .env and fill it

```bash
task terragrunt:bootstrap
task terragrunt -- stack run apply terraform/live/hometheo
```

## Prepare configuration for composants inside K8S
```bash
task argocd:generate-secrets
task argocd:bootstrap:
```

## Services

Postgres, Keycloak, Grafana, Loki, Uptime Kuma, n8n, and more.

---

Inspired by [Sofiane Djerbi](https://sofianedjerbi.com)
