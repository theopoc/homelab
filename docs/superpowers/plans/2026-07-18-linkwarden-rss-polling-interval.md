# Linkwarden RSS Polling Interval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure Linkwarden to poll RSS subscriptions every 12 hours.

**Architecture:** Extend existing Helm `valuesInline.extraEnv` list used by Linkwarden Deployment. Keep value as quoted minute count so generated Kubernetes environment variable is string `"720"`.

**Tech Stack:** Kubernetes, Kustomize Helm chart inflation, YAML

## Global Constraints

- Set `NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES` exactly once.
- Use string value `"720"`, equivalent to 12 hours.
- Keep value in existing Linkwarden `valuesInline.extraEnv`; do not add Secret or ConfigMap.

---

### Task 1: Configure and verify RSS polling interval

**Files:**
- Modify: `argocd/manifests/linkwarden/kustomization.yaml`

**Interfaces:**
- Consumes: Linkwarden Helm chart `extraEnv` values.
- Produces: Linkwarden Deployment environment variable `NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES="720"`.

- [ ] **Step 1: Confirm variable is absent before change**

Run:

```bash
rtk rg -n 'NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES' argocd/manifests/linkwarden/kustomization.yaml
```

Expected: exit status 1 with no matches.

- [ ] **Step 2: Add environment variable**

Add after existing RSS subscription limit:

```yaml
        - name: RSS_SUBSCRIPTION_LIMIT_PER_USER
          value: "150"
        - name: NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES
          value: "720"
```

- [ ] **Step 3: Validate YAML and whitespace**

Run:

```bash
rtk git diff --check
rtk pre-commit run --files argocd/manifests/linkwarden/kustomization.yaml
```

Expected: both commands exit 0; pre-commit hooks report `Passed` or `Skipped`.

- [ ] **Step 4: Render Deployment and verify exact value**

Run:

```bash
linkwarden_render=$(mktemp)
rtk kustomize build --enable-helm argocd/manifests/linkwarden > "$linkwarden_render"
rtk rg -n -A1 'name: NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES' "$linkwarden_render"
```

Expected: build exits 0 and match is followed by `value: "720"` or YAML-equivalent `value: '720'`.

- [ ] **Step 5: Review final delta**

Run:

```bash
rtk git diff -- argocd/manifests/linkwarden/kustomization.yaml
rtk git status --short
```

Expected: one two-line environment-variable addition in Linkwarden Kustomization, plus this implementation plan if still uncommitted.

- [ ] **Step 6: Commit implementation**

Use `commit` skill with message:

```text
feat(linkwarden): set RSS polling interval
```
