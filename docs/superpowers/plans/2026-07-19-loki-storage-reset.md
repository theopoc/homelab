# Loki Storage Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete full Loki storage through Argo CD, recreate a fresh `2Gi` claim, and reduce retention to `24h`.

**Architecture:** Temporarily annotate only Loki StatefulSet with Argo CD `Force=true,Replace=true`. Current StatefulSet deletion policy and PVC owner reference delete old claim and Longhorn volume; recreated StatefulSet provisions fresh `2Gi` storage. A second GitOps commit immediately removes destructive annotation while retaining `24h` configuration.

**Tech Stack:** Argo CD, Grafana Loki Helm chart `6.53.0`, Kubernetes StatefulSet/PVC, Longhorn, YAML, Git.

## Global Constraints

- Make every cluster change through Git and Argo CD; never run mutating `kubectl` commands.
- Current Loki data loss is intentional, irreversible, and explicitly approved.
- Keep Loki PVC request exactly `2Gi`.
- Set Loki retention exactly `24h`.
- Temporary force annotation must exist for one destructive sync only.
- Prefix every shell command with `rtk`.
- Preserve untracked user file `AGENTS.md`; never stage it.

---

### Task 1: Prepare destructive GitOps phase

**Files:**
- Modify: `argocd/manifests/monitoring/loki.yaml:38-62`

**Interfaces:**
- Consumes: Loki Application values rendered by Helm chart `6.53.0`.
- Produces: committed desired state containing `24h` retention and one-sync StatefulSet replacement annotation.

- [ ] **Step 1: Prove desired settings are absent**

Run:

```bash
rtk yq -e '.spec.source.helm.valuesObject.loki.limits_config.retention_period == "24h"' argocd/manifests/monitoring/loki.yaml
rtk yq -e '.spec.source.helm.valuesObject.singleBinary.annotations."argocd.argoproj.io/sync-options" == "Force=true,Replace=true"' argocd/manifests/monitoring/loki.yaml
```

Expected: both commands exit `1`; current retention remains `168h`, and annotation does not exist.

- [ ] **Step 2: Add minimal phase-1 values**

Edit existing values to exact shape:

```yaml
loki:
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
    retention_period: 24h

singleBinary:
  annotations:
    argocd.argoproj.io/sync-options: Force=true,Replace=true
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
  persistence:
    size: 2Gi
```

Do not alter other Loki values.

- [ ] **Step 3: Prove source values and rendered resources**

Run:

```bash
rtk yq -e '.spec.source.helm.valuesObject.loki.limits_config.retention_period == "24h"' argocd/manifests/monitoring/loki.yaml
rtk yq -e '.spec.source.helm.valuesObject.singleBinary.annotations."argocd.argoproj.io/sync-options" == "Force=true,Replace=true"' argocd/manifests/monitoring/loki.yaml
LOKI_RESET_TMP=$(rtk mktemp -d)
rtk yq '.spec.source.helm.valuesObject' argocd/manifests/monitoring/loki.yaml | rtk proxy helm template loki grafana/loki --version 6.53.0 --namespace monitoring -f - > "${LOKI_RESET_TMP}/rendered.yaml"
rtk yq -e 'select(.kind == "StatefulSet" and .metadata.name == "loki") | .metadata.annotations."argocd.argoproj.io/sync-options" == "Force=true,Replace=true"' "${LOKI_RESET_TMP}/rendered.yaml"
rtk yq -e 'select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[0].spec.resources.requests.storage == "2Gi"' "${LOKI_RESET_TMP}/rendered.yaml"
rtk yq -e 'select(.kind == "ConfigMap" and .metadata.name == "loki") | .data."config.yaml" | contains("retention_period: 24h")' "${LOKI_RESET_TMP}/rendered.yaml"
rtk git diff --check
```

Expected: every assertion prints `true` and exits `0`; diff check emits nothing.

- [ ] **Step 4: Commit phase 1 atomically**

Stage only Loki manifest:

```bash
rtk git add argocd/manifests/monitoring/loki.yaml
rtk git diff --cached --check
rtk git status --short
```

Expected: Loki manifest staged; `AGENTS.md` remains untracked. Invoke `commit` skill with message `fix(loki): reset storage with 24h retention`.

### Task 2: Publish phase 1 and prove storage recreation

**Files:**
- No file changes.

**Interfaces:**
- Consumes: committed destructive phase from Task 1 and live Loki StatefulSet/PVC.
- Produces: fresh bound `2Gi` PVC, healthy Loki, live `24h` retention.

- [ ] **Step 1: Record destructive targets before push**

Run and retain outputs:

```bash
rtk kubectl get statefulset -n monitoring loki -o custom-columns='NAME:.metadata.name,UID:.metadata.uid'
rtk kubectl get pvc -n monitoring storage-loki-0 -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,VOLUME:.spec.volumeName,CAPACITY:.status.capacity.storage'
rtk kubectl get pv pvc-512f3613-703d-4e2f-8f70-ac0c17cd09a1 -o custom-columns='NAME:.metadata.name,UID:.metadata.uid'
```

Expected baseline: StatefulSet UID `2c8d3370-a65f-4343-95d3-aa3a0546dc43`, PVC UID `512f3613-703d-4e2f-8f70-ac0c17cd09a1`, capacity `2Gi`. If live UIDs drifted, record new values and use those for comparison.

- [ ] **Step 2: Push phase 1**

Run:

```bash
rtk git push origin main
rtk git status --short --branch
```

Expected: push succeeds; branch matches `origin/main`; only `AGENTS.md` remains untracked.

- [ ] **Step 3: Poll Argo CD and replacement resources**

Poll read-only state in intervals no longer than 30 seconds:

```bash
rtk kubectl get application -n argocd monitoring -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
rtk kubectl get application -n argocd loki -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'
rtk kubectl get statefulset -n monitoring loki -o custom-columns='UID:.metadata.uid,READY:.status.readyReplicas'
rtk kubectl get pvc -n monitoring storage-loki-0 -o custom-columns='UID:.metadata.uid,VOLUME:.spec.volumeName,PHASE:.status.phase,CAPACITY:.status.capacity.storage'
rtk kubectl get pv pvc-512f3613-703d-4e2f-8f70-ac0c17cd09a1
rtk kubectl get pv -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,CLAIM_NAMESPACE:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name' | rtk rg 'monitoring\s+storage-loki-0'
```

Expected: StatefulSet and PVC UIDs differ from baseline; replacement PVC becomes `Bound` with `2Gi`; old PV query returns `NotFound`; final query shows a different PV name and UID bound to `monitoring/storage-loki-0`. If baseline PV name drifted, query that recorded name instead.

- [ ] **Step 4: Verify recovered runtime**

Run:

```bash
rtk kubectl wait -n monitoring --for=condition=Ready pod/loki-0 --timeout=60s
rtk kubectl get pod -n monitoring loki-0 -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
rtk kubectl get configmap -n monitoring loki -o jsonpath='{.data.config\.yaml}' | rtk rg 'retention_period: 24h'
rtk kubectl logs -n monitoring loki-0 -c loki --since=10m | rtk rg 'no space left on device'
rtk kubectl get application -n argocd loki -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Expected: wait exits `0`; both containers Ready; config match exists; error search exits `1` with no output; application reports `Synced Healthy`.

### Task 3: Remove destructive annotation

**Files:**
- Modify: `argocd/manifests/monitoring/loki.yaml:50-64`

**Interfaces:**
- Consumes: healthy Loki on fresh `2Gi` PVC from Task 2.
- Produces: safe steady-state manifest with `24h` retention and no force replacement.

- [ ] **Step 1: Prove temporary annotation still exists**

Run:

```bash
rtk yq -e '.spec.source.helm.valuesObject.singleBinary.annotations."argocd.argoproj.io/sync-options" == null' argocd/manifests/monitoring/loki.yaml
```

Expected: exit `1` because destructive annotation still exists.

- [ ] **Step 2: Remove only annotation block**

Final steady-state values must begin:

```yaml
singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
```

Keep `retention_period: 24h` and `persistence.size: 2Gi` unchanged.

- [ ] **Step 3: Render and verify safe steady state**

Run:

```bash
rtk yq -e '.spec.source.helm.valuesObject.singleBinary.annotations."argocd.argoproj.io/sync-options" == null' argocd/manifests/monitoring/loki.yaml
rtk yq -e '.spec.source.helm.valuesObject.loki.limits_config.retention_period == "24h"' argocd/manifests/monitoring/loki.yaml
LOKI_SAFE_TMP=$(rtk mktemp -d)
rtk yq '.spec.source.helm.valuesObject' argocd/manifests/monitoring/loki.yaml | rtk proxy helm template loki grafana/loki --version 6.53.0 --namespace monitoring -f - > "${LOKI_SAFE_TMP}/rendered.yaml"
rtk yq -e 'select(.kind == "StatefulSet" and .metadata.name == "loki") | .metadata.annotations."argocd.argoproj.io/sync-options" == null' "${LOKI_SAFE_TMP}/rendered.yaml"
rtk yq -e 'select(.kind == "StatefulSet" and .metadata.name == "loki") | .spec.volumeClaimTemplates[0].spec.resources.requests.storage == "2Gi"' "${LOKI_SAFE_TMP}/rendered.yaml"
rtk yq -e 'select(.kind == "ConfigMap" and .metadata.name == "loki") | .data."config.yaml" | contains("retention_period: 24h")' "${LOKI_SAFE_TMP}/rendered.yaml"
rtk git diff --check
```

Expected: all assertions exit `0`; diff check emits nothing.

- [ ] **Step 4: Commit safety phase atomically**

Run:

```bash
rtk git add argocd/manifests/monitoring/loki.yaml
rtk git diff --cached --check
rtk git status --short
```

Expected: only Loki manifest staged; `AGENTS.md` remains untracked. Invoke `commit` skill with message `fix(loki): disable forced storage recreation`.

### Task 4: Publish safe state and close incident

**Files:**
- No file changes.

**Interfaces:**
- Consumes: safe steady-state commit from Task 3.
- Produces: remote parity and proof no second recreation occurred.

- [ ] **Step 1: Record replacement UIDs before phase-2 push**

Run and retain outputs:

```bash
rtk kubectl get statefulset -n monitoring loki -o custom-columns='NAME:.metadata.name,UID:.metadata.uid'
rtk kubectl get pvc -n monitoring storage-loki-0 -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,VOLUME:.spec.volumeName,CAPACITY:.status.capacity.storage'
```

- [ ] **Step 2: Push phase 2 and wait for reconciliation**

Run:

```bash
rtk git push origin main
rtk kubectl get application -n argocd monitoring -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
rtk kubectl get application -n argocd loki -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Poll until parent revision equals pushed `HEAD` and both applications report `Synced Healthy`.

- [ ] **Step 3: Prove destructive option is gone without another reset**

Run:

```bash
rtk kubectl get statefulset -n monitoring loki -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}'
rtk kubectl get statefulset -n monitoring loki -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,READY:.status.readyReplicas'
rtk kubectl get pvc -n monitoring storage-loki-0 -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,VOLUME:.spec.volumeName,PHASE:.status.phase,CAPACITY:.status.capacity.storage'
rtk kubectl wait -n monitoring --for=condition=Ready pod/loki-0 --timeout=60s
rtk kubectl logs -n monitoring loki-0 -c loki --since=10m | rtk rg 'no space left on device'
rtk git status --short --branch
rtk git log -3 --oneline
```

Expected: annotation query prints nothing; StatefulSet/PVC UIDs match Task 4 Step 1; PVC remains `Bound 2Gi`; Loki remains Ready; error search exits `1`; branch matches `origin/main`; only `AGENTS.md` remains untracked.
