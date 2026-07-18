# Linkwarden v2.15.1 Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade Linkwarden to `v2.15.1` and add allocator and Node.js heap environment settings.

**Architecture:** Keep Helm chart `1.0.14`, override its Linkwarden image tag, and extend existing `extraEnv`. Preserve existing archive-worker setting without duplication.

**Tech Stack:** Kubernetes, Kustomize Helm chart inflation, YAML

## Global Constraints

- Keep Linkwarden Helm chart version `1.0.14`.
- Set image tag exactly to `"v2.15.1"`.
- Set `MALLOC_ARENA_MAX` to string `"2"`.
- Set `NODE_OPTIONS` to string `"--max-old-space-size=400"`.
- Retain exactly one `ARCHIVE_TAKE_COUNT` with string value `"1"`.
- Replace chart's literal `${VAR}` `DATABASE_URL` with Kubernetes `$(VAR)` expansion.
- Increase container memory limit from `1536Mi` to `2Gi`; retain `500Mi` request.

---

### Task 1: Upgrade Linkwarden image and runtime settings

**Files:**
- Modify: `argocd/manifests/linkwarden/kustomization.yaml`

**Interfaces:**
- Consumes: Linkwarden Helm chart `image` and `extraEnv` values.
- Produces: Deployment image `ghcr.io/linkwarden/linkwarden:v2.15.1` and requested runtime environment.

- [ ] **Step 1: Verify upgrade settings are absent and archive setting exists once**

Run:

```bash
rtk rg -n 'v2\.15\.1|MALLOC_ARENA_MAX|NODE_OPTIONS' argocd/manifests/linkwarden/kustomization.yaml
rtk rg -c 'name: ARCHIVE_TAKE_COUNT' argocd/manifests/linkwarden/kustomization.yaml
```

Expected: first command exits 1 with no matches; second prints `1`.

- [ ] **Step 2: Add image override and missing environment values**

Add under `valuesInline`:

```yaml
      image:
        tag: "v2.15.1"
```

Set resource limit while retaining existing request:

```yaml
      resources:
        requests:
          cpu: 250m
          memory: 500Mi
        limits:
          memory: 2Gi
```

Add before existing `ARCHIVE_TAKE_COUNT`:

```yaml
        - name: MALLOC_ARENA_MAX
          value: "2"
        - name: NODE_OPTIONS
          value: "--max-old-space-size=400"
        - name: ARCHIVE_TAKE_COUNT
          value: "1"
```

Add guarded JSON operations under `patches` in
`argocd/manifests/linkwarden/kustomization.yaml`:

```yaml
  - target:
      kind: Deployment
      name: linkwarden
    patch: |-
      - op: test
        path: /spec/template/spec/containers/0/name
        value: linkwarden
      - op: test
        path: /spec/template/spec/containers/0/env/8/name
        value: DATABASE_URL
      - op: replace
        path: /spec/template/spec/containers/0/env/8/value
        value: "postgresql://$(LINKWARDEN_POSTGRES_USER):$(LINKWARDEN_POSTGRES_PASSWORD)@$(LINKWARDEN_POSTGRES_HOST):$(LINKWARDEN_POSTGRES_PORT)/$(LINKWARDEN_POSTGRES_DATABASE)"
```

- [ ] **Step 3: Validate YAML and whitespace**

Run:

```bash
rtk git diff --check
rtk pre-commit run --files argocd/manifests/linkwarden/kustomization.yaml
```

Expected: exit 0; YAML and whitespace hooks pass.

- [ ] **Step 4: Render and verify exact Deployment settings**

Run:

```bash
linkwarden_render=$(mktemp)
rtk kustomize build --enable-helm argocd/manifests/linkwarden > "$linkwarden_render"
rtk rg -n 'image: ghcr.io/linkwarden/linkwarden:v2.15.1' "$linkwarden_render"
rtk rg -n 'memory: 2Gi' "$linkwarden_render"
rtk rg -n -A1 'name: (MALLOC_ARENA_MAX|NODE_OPTIONS|ARCHIVE_TAKE_COUNT)' "$linkwarden_render"
rtk rg -n -A1 'name: DATABASE_URL' "$linkwarden_render"
```

Expected: exact image appears once. Each requested variable appears once with values `"2"`, `"--max-old-space-size=400"`, and `"1"` respectively.
`DATABASE_URL` uses `$(LINKWARDEN_POSTGRES_*)` references, not `${LINKWARDEN_POSTGRES_*}`.

- [ ] **Step 5: Commit and push**

Use `commit` skill with message:

```text
feat(linkwarden): upgrade to v2.15.1
```

Push `main` to `origin/main`, then verify local and remote commit IDs match.
