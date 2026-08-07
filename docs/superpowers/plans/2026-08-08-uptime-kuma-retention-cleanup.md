# Uptime Kuma Retention Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set Uptime Kuma heartbeat retention to 30 days and safely compact its SQLite database without expanding the 500 MiB PVC.

**Architecture:** Temporarily switch the existing ArgoCD Application from the upstream Helm chart to local manifests that preserve the same Deployment, Service, and PVC identities. A one-shot init container checkpoints the closed WAL, builds and validates a compacted database on `emptyDir`, replaces the database only when the compacted copy fits beside the rollback copy, then starts the unchanged Uptime Kuma container.

**Tech Stack:** ArgoCD, Kubernetes, Kustomize, Longhorn, POSIX shell, SQLite 3, Uptime Kuma 1.23.17

## Global Constraints

- Do not expand the 500 MiB PVC.
- Delete only `heartbeat` rows older than 30 days.
- Preserve monitors, users, notifications, status pages, certificates, and unrelated settings.
- Set `setting.key='keepDataPeriodDays'` to `30`.
- Do not delete an active WAL manually.
- Do not mutate cluster state with direct `kubectl apply`, `delete`, `patch`, or manual Helm operations.
- Commit every cluster-state change and let ArgoCD apply it.
- Do not push a commit that triggers cleanup without explicit user approval immediately before push.
- Require a successful current Longhorn backup before cleanup sync.
- Leave untracked `AGENTS.md` untouched.
- Abort before database replacement when compacted database plus 16 MiB safety margin does not fit while original database remains on PVC.

---

## File Map

- Create `argocd/manifests/uptime-kuma-maintenance/maintenance.sh`: idempotent SQLite checkpoint, purge, compaction, validation, replacement, and marker logic.
- Create `argocd/manifests/uptime-kuma-maintenance/test-maintenance.sh`: disposable SQLite fixture tests for successful purge, idempotency, and failure guards.
- Create `argocd/manifests/uptime-kuma-maintenance/kustomization.yaml`: assemble temporary resources and expose script through a stable ConfigMap name.
- Create `argocd/manifests/uptime-kuma-maintenance/deployment.yaml`: exact current Uptime Kuma workload plus one-shot init container and `emptyDir` workspace.
- Create `argocd/manifests/uptime-kuma-maintenance/service.yaml`: exact current ClusterIP service identity.
- Create `argocd/manifests/uptime-kuma-maintenance/pvc.yaml`: exact existing PVC identity and immutable storage contract.
- Create `argocd/manifests/uptime-kuma-maintenance/recurring-job.yaml`: temporary Longhorn filesystem trim assigned only to the Uptime Kuma PVC.
- Modify `argocd/apps/uptime-kuma.yaml`: temporarily point Application source to local maintenance manifests; later restore upstream Helm source.
- Delete `argocd/manifests/uptime-kuma-maintenance/` after verified cleanup and restored Helm management.

### Task 1: Build and test maintenance script

**Files:**
- Create: `argocd/manifests/uptime-kuma-maintenance/maintenance.sh`
- Create: `argocd/manifests/uptime-kuma-maintenance/test-maintenance.sh`

**Interfaces:**
- Consumes: SQLite database at `${DATA_DIR:-/data}/kuma.db`; workspace `${WORK_DIR:-/work}`.
- Produces: compacted `kuma.db`, retention value `30`, no heartbeat older than cutoff, marker `${DATA_DIR}/.maintenance/retention-30d-20260808.done`.
- Environment: `DATA_DIR`, `WORK_DIR`, `RETENTION_DAYS` default `30`, `SAFETY_BYTES` default `16777216`, `MAINTENANCE_ID` default `retention-30d-20260808`.

- [ ] **Step 1: Write fixture test before production script**

Create `test-maintenance.sh` with `set -eu`. Use `mktemp -d`, trap cleanup, create `data`, `work`, and SQLite schema containing:

```sql
CREATE TABLE setting (
  id INTEGER PRIMARY KEY,
  key VARCHAR(200) NOT NULL,
  value TEXT,
  type VARCHAR(20)
);
CREATE TABLE monitor (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);
CREATE TABLE heartbeat (
  id INTEGER PRIMARY KEY,
  monitor_id INTEGER NOT NULL REFERENCES monitor(id) ON DELETE CASCADE,
  time DATETIME NOT NULL,
  msg TEXT
);
INSERT INTO setting(key, value, type) VALUES ('keepDataPeriodDays', '180', 'general');
INSERT INTO monitor(id, name) VALUES (1, 'kept-monitor');
INSERT INTO heartbeat(monitor_id, time, msg) VALUES
  (1, datetime('now', '-31 days'), 'delete-me'),
  (1, datetime('now', '-29 days'), 'keep-me');
PRAGMA journal_mode=WAL;
```

Run production script with fixture directories and `SAFETY_BYTES=0`. Assert:

```sh
test "$(sqlite3 "$data_dir/kuma.db" "SELECT value FROM setting WHERE key='keepDataPeriodDays';")" = "30"
test "$(sqlite3 "$data_dir/kuma.db" "SELECT count(*) FROM heartbeat WHERE msg='delete-me';")" = "0"
test "$(sqlite3 "$data_dir/kuma.db" "SELECT count(*) FROM heartbeat WHERE msg='keep-me';")" = "1"
test "$(sqlite3 "$data_dir/kuma.db" "SELECT count(*) FROM monitor;")" = "1"
test "$(sqlite3 "$data_dir/kuma.db" "PRAGMA integrity_check;")" = "ok"
test -f "$data_dir/.maintenance/retention-30d-20260808.done"
```

Run script second time and assert database checksum does not change. Add low-space test by setting `SAFETY_BYTES` larger than filesystem free bytes; assert non-zero exit, original checksum unchanged, marker absent.

- [ ] **Step 2: Run fixture test and confirm expected failure**

Run:

```bash
rtk proxy sh argocd/manifests/uptime-kuma-maintenance/test-maintenance.sh
```

Expected: FAIL because `maintenance.sh` does not exist.

- [ ] **Step 3: Implement maintenance script**

Use strict shell mode and explicit command checks:

```sh
#!/bin/sh
set -eu

data_dir=${DATA_DIR:-/data}
work_dir=${WORK_DIR:-/work}
retention_days=${RETENTION_DAYS:-30}
safety_bytes=${SAFETY_BYTES:-16777216}
maintenance_id=${MAINTENANCE_ID:-retention-30d-20260808}
db="$data_dir/kuma.db"
marker_dir="$data_dir/.maintenance"
marker="$marker_dir/$maintenance_id.done"
source_copy="$work_dir/source.db"
compact_db="$work_dir/compact.db"
new_db="$data_dir/kuma.db.new"
rollback_db="$data_dir/kuma.db.pre-$maintenance_id"
```

Required control flow:

1. Verify `retention_days` contains only digits and equals `30` for this operation.
2. Exit success without writes when marker exists.
3. Verify `kuma.db`, `sqlite3`, `df`, `stat`, `cp`, `mv`, and `sync` availability.
4. Record monitor count and current UTC cutoff in workspace.
5. Run `sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);"`; require result busy count `0` and checkpoint success.
6. Create consistent working copy with SQLite `.backup`, never raw-copy active database files.
7. Require exactly one row from `SELECT count(*) FROM setting WHERE key='keepDataPeriodDays';`, then apply one transaction using quoted numeric retention:

```sql
BEGIN IMMEDIATE;
UPDATE setting
SET value = '30'
WHERE key = 'keepDataPeriodDays';
DELETE FROM heartbeat
WHERE time < datetime('now', '-30 days');
COMMIT;
```

8. Run `VACUUM` on `source.db`, close SQLite, then rename workspace file from `source.db` to `compact.db`.
9. Require `PRAGMA integrity_check` on `compact.db` exactly `ok`, retention `30`, old-heartbeat count `0`, monitor count unchanged.
10. Calculate `compact_size`, PVC `available_bytes`, and require `compact_size + safety_bytes <= available_bytes`.
11. Remove stale `kuma.db.new` only; never remove original or rollback filename before guards pass.
12. Rename original to rollback filename, copy compact DB to `kuma.db.new`, `sync`, validate final-path temporary DB, rename to `kuma.db`, `sync`.
13. Validate final `kuma.db` again, then remove rollback DB and closed `kuma.db-shm`/`kuma.db-wal`.
14. Create marker atomically with pre/post row counts, removed-row count, compact size, and UTC completion time; never include heartbeat messages or secrets.
15. Install trap before replacement: on failure, remove `kuma.db.new`; if `kuma.db` is absent and rollback exists, rename rollback back to `kuma.db`.

- [ ] **Step 4: Run fixture tests**

Run:

```bash
rtk proxy sh argocd/manifests/uptime-kuma-maintenance/test-maintenance.sh
rtk proxy sh -n argocd/manifests/uptime-kuma-maintenance/maintenance.sh
rtk proxy sh -n argocd/manifests/uptime-kuma-maintenance/test-maintenance.sh
```

Expected: all tests exit `0`; output reports successful purge test, idempotency test, low-space abort test.

- [ ] **Step 5: Commit script and tests**

Stage only two files. Use `commit` skill with message:

```text
feat(uptime-kuma): add safe retention cleanup
```

### Task 2: Add temporary GitOps maintenance resources

**Files:**
- Create: `argocd/manifests/uptime-kuma-maintenance/kustomization.yaml`
- Create: `argocd/manifests/uptime-kuma-maintenance/deployment.yaml`
- Create: `argocd/manifests/uptime-kuma-maintenance/service.yaml`
- Create: `argocd/manifests/uptime-kuma-maintenance/pvc.yaml`
- Create: `argocd/manifests/uptime-kuma-maintenance/recurring-job.yaml`
- Modify: `argocd/apps/uptime-kuma.yaml`

**Interfaces:**
- Consumes: `maintenance.sh` from Task 1 through ConfigMap `uptime-kuma-maintenance`.
- Produces: same `Deployment/uptime-kuma`, `Service/uptime-kuma`, and `PersistentVolumeClaim/uptime-kuma-pvc` identities currently tracked by Application `uptime-kuma`.

- [ ] **Step 1: Render current Helm resources as reference**

Run exact Helm render and save only as review output, not committed artifact:

```bash
rtk proxy helm template uptime-kuma uptime-kuma \
  --repo https://dirsigler.github.io/uptime-kuma-helm \
  --version 2.24.0 \
  --namespace uptime-kuma \
  --set useDeploy=true \
  --set service.type=ClusterIP \
  --set service.port=3001 \
  --set ingress.enabled=false \
  --set volume.enabled=true \
  --set volume.accessMode=ReadWriteOnce \
  --set volume.size=500Mi \
  --set resources.requests.cpu=35m \
  --set resources.requests.memory=180Mi \
  --set resources.limits.memory=180Mi
```

Expected resources: PVC, Service, Deployment, Helm test Pod. Do not include test Pod in local maintenance manifests.

- [ ] **Step 2: Create Kustomization and stable ConfigMap**

Create:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - service.yaml
  - deployment.yaml
  - recurring-job.yaml
configMapGenerator:
  - name: uptime-kuma-maintenance
    namespace: uptime-kuma
    files:
      - maintenance.sh
generatorOptions:
  disableNameSuffixHash: true
```

- [ ] **Step 3: Create PVC and Service matching live immutable fields**

PVC must keep name `uptime-kuma-pvc`, `storageClassName: longhorn`, `ReadWriteOnce`, `500Mi`, filesystem volume mode, and existing Helm labels. Add `recurring-job.longhorn.io/source: enabled` so Longhorn 1.10 dynamically synchronizes PVC recurring-job labels to the existing volume, plus `recurring-job-group.longhorn.io/uptime-kuma-cleanup: enabled` for temporary trim assignment. Service must keep name `uptime-kuma`, port `3001`, target port `http`, and selector labels from current Deployment.

Do not add replacement annotations, finalizers, volume names, cluster IPs, or generated live metadata.

- [ ] **Step 4: Create targeted Longhorn filesystem-trim job**

Create `recurring-job.yaml`:

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: uptime-kuma-cleanup-trim
  namespace: longhorn-system
spec:
  cron: "*/5 * * * *"
  task: filesystem-trim
  groups:
    - uptime-kuma-cleanup
  retain: 0
  concurrency: 1
```

Unique group label ensures job targets only `uptime-kuma-pvc`. Temporary five-minute schedule allows execution without direct Longhorn mutation; resource and PVC label are removed after proof.

- [ ] **Step 5: Create Deployment with one-shot init container**

Copy chart-rendered Deployment spec, retaining Uptime Kuma image `louislam/uptime-kuma:1.23.17-debian`, probes, service account, resources, labels, PVC mount `/app/data`, and one replica.

Add:

```yaml
initContainers:
  - name: retention-cleanup-20260808
    image: louislam/uptime-kuma:1.23.17-debian
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh", "/maintenance/maintenance.sh"]
    env:
      - name: DATA_DIR
        value: /data
      - name: WORK_DIR
        value: /work
      - name: RETENTION_DAYS
        value: "30"
      - name: SAFETY_BYTES
        value: "16777216"
      - name: MAINTENANCE_ID
        value: retention-30d-20260808
    resources:
      requests:
        cpu: 35m
        memory: 180Mi
      limits:
        memory: 512Mi
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
      - name: storage
        mountPath: /data
      - name: maintenance-script
        mountPath: /maintenance
        readOnly: true
      - name: maintenance-work
        mountPath: /work
```

Add volumes:

```yaml
- name: maintenance-script
  configMap:
    name: uptime-kuma-maintenance
    defaultMode: 0555
- name: maintenance-work
  emptyDir:
    sizeLimit: 1Gi
```

Set pod `automountServiceAccountToken: false`. Use `strategy.type: Recreate` during maintenance so old SQLite writer stops before init container mounts database.

- [ ] **Step 6: Switch ArgoCD Application to local source**

Replace Helm source block temporarily with:

```yaml
source:
  repoURL: https://github.com/theopoc/homelab.git
  targetRevision: HEAD
  path: argocd/manifests/uptime-kuma-maintenance
```

Before writing exact URL, verify `rtk git remote -v`; use repository URL already configured as `origin`, never assume owner or host.

- [ ] **Step 7: Validate rendered manifests locally**

Run:

```bash
rtk proxy kubectl kustomize argocd/manifests/uptime-kuma-maintenance > /tmp/uptime-kuma-maintenance.yaml
rtk proxy yamllint -c .yamllint.yaml argocd/apps/uptime-kuma.yaml argocd/manifests/uptime-kuma-maintenance
rtk proxy kubeconform -strict -summary -ignore-missing-schemas /tmp/uptime-kuma-maintenance.yaml
rtk proxy kubectl diff --server-side=false -f /tmp/uptime-kuma-maintenance.yaml
```

`kubectl diff` is read-only. Review expected changes: Deployment strategy, init container, ConfigMap, volumes, and Application source. Reject any PVC replacement, size change, Service immutable-field change, or unrelated deletion.

- [ ] **Step 8: Commit temporary maintenance manifests**

Stage only Application and maintenance directory. Use `commit` skill with message:

```text
fix(uptime-kuma): schedule retention cleanup
```

Do not push yet.

### Task 3: Preflight backup and explicitly authorize destructive sync

**Files:** None

**Interfaces:**
- Consumes: committed maintenance manifests from Task 2.
- Produces: recorded read-only evidence allowing user to approve push that triggers purge.

- [ ] **Step 1: Verify clean scoped Git state and remote**

Run:

```bash
rtk git status --short
rtk git log -3 --oneline
rtk git remote -v
```

Expected: only known unrelated `?? AGENTS.md`; two implementation commits present; `origin` points to repository ArgoCD watches.

- [ ] **Step 2: Capture current application and database evidence read-only**

Run read-only checks:

```bash
rtk kubectl -n argocd get application uptime-kuma -o wide
rtk kubectl -n uptime-kuma get pod,pvc -o wide
rtk kubectl -n uptime-kuma exec deploy/uptime-kuma -- df -h /app/data
rtk kubectl -n uptime-kuma exec deploy/uptime-kuma -- sqlite3 -readonly /app/data/kuma.db "SELECT count(*) FROM monitor; SELECT value FROM setting WHERE key='keepDataPeriodDays'; SELECT min(time),max(time),count(*) FROM heartbeat; PRAGMA integrity_check;"
```

Store counts in session notes, not repository files.

- [ ] **Step 3: Verify Longhorn backup freshness and health**

Run:

```bash
rtk kubectl -n longhorn-system get volumes.longhorn.io pvc-3918e9b9-26ff-44e7-a82f-a8439fdca25b -o yaml
rtk kubectl -n longhorn-system get backups.longhorn.io -l longhornvolume=pvc-3918e9b9-26ff-44e7-a82f-a8439fdca25b -o wide
```

Require volume `robustness: healthy`, three healthy replicas, non-empty `lastBackup`, and `lastBackupAt` from current backup cycle. If backup status cannot prove restorable current backup, stop before push.

- [ ] **Step 4: Ask final push confirmation**

Report exact cutoff timestamp computed for execution, estimated rows affected when query finishes, current monitor count, current backup ID/time, expected downtime, and two commit hashes.

Ask explicit confirmation: pushing maintenance commit will automatically stop Uptime Kuma and irreversibly delete heartbeat history older than 30 days after validation. Do not push without affirmative response.

### Task 4: Trigger maintenance and verify completion

**Files:** None

**Interfaces:**
- Consumes: explicit push approval from Task 3.
- Produces: synced maintenance commit, compacted healthy database, objective runtime evidence.

- [ ] **Step 1: Push only approved branch**

Use non-interactive push after rechecking branch and remote:

```bash
rtk git branch --show-current
rtk git remote -v
rtk git push origin HEAD
```

- [ ] **Step 2: Monitor ArgoCD and pod transition**

Use read-only commands only:

```bash
rtk kubectl -n argocd get application uptime-kuma -w
rtk kubectl -n uptime-kuma get pods -w
```

Stop watches within 10 minutes. If init container fails, inspect status and logs; do not patch or delete resources manually.

- [ ] **Step 3: Inspect init-container evidence**

Run:

```bash
rtk kubectl -n uptime-kuma logs deploy/uptime-kuma -c retention-cleanup-20260808
rtk kubectl -n uptime-kuma get pod -l app.kubernetes.io/name=uptime-kuma -o wide
```

Require logged integrity `ok`, retention `30`, unchanged monitor count, deleted-row count, final compact size, marker creation, and init exit code `0`. Logs must contain no heartbeat content or secrets.

- [ ] **Step 4: Verify application and storage**

Run:

```bash
rtk kubectl -n uptime-kuma exec deploy/uptime-kuma -- sqlite3 -readonly /app/data/kuma.db "PRAGMA integrity_check; SELECT value FROM setting WHERE key='keepDataPeriodDays'; SELECT count(*) FROM monitor; SELECT min(time),max(time),count(*) FROM heartbeat;"
rtk kubectl -n uptime-kuma exec deploy/uptime-kuma -- df -h /app/data
rtk kubectl -n uptime-kuma exec deploy/uptime-kuma -- ls -lh /app/data/kuma.db /app/data/kuma.db-wal /app/data/kuma.db-shm
rtk kubectl -n uptime-kuma logs deploy/uptime-kuma --since=30m
rtk kubectl -n longhorn-system get volumes.longhorn.io pvc-3918e9b9-26ff-44e7-a82f-a8439fdca25b -o wide
rtk kubectl -n argocd get application uptime-kuma -o wide
```

Require integrity `ok`, retention `30`, same monitor count, oldest heartbeat within 30-day tolerance, Ready pod, no SQLite/disk errors, healthy Longhorn volume, and ArgoCD `Synced/Healthy`.

- [ ] **Step 5: Verify targeted filesystem trim**

Wait for one scheduled run, then inspect read-only Longhorn state:

```bash
rtk kubectl -n longhorn-system get recurringjobs.longhorn.io uptime-kuma-cleanup-trim -o yaml
rtk kubectl -n longhorn-system get pods,jobs -l recurring-job.longhorn.io=uptime-kuma-cleanup-trim -o wide
rtk proxy kubectl -n monitoring get --raw '/api/v1/namespaces/monitoring/services/http:prometheus-stack-kube-prom-prometheus:9090/proxy/api/v1/query?query=longhorn_volume_actual_size_bytes%7Bpvc%3D%22uptime-kuma-pvc%22%7D%20%2F%20longhorn_volume_capacity_bytes%7Bpvc%3D%22uptime-kuma-pvc%22%7D%20%2A%20100'
```

Require successful trim job and actual-size ratio below 90%. If trim fails, preserve maintenance resources and diagnose from job logs; do not trigger manual trim.

### Task 5: Restore Helm source and remove maintenance hook

**Files:**
- Modify: `argocd/apps/uptime-kuma.yaml`
- Delete: `argocd/manifests/uptime-kuma-maintenance/kustomization.yaml`
- Delete: `argocd/manifests/uptime-kuma-maintenance/deployment.yaml`
- Delete: `argocd/manifests/uptime-kuma-maintenance/service.yaml`
- Delete: `argocd/manifests/uptime-kuma-maintenance/pvc.yaml`
- Delete: `argocd/manifests/uptime-kuma-maintenance/recurring-job.yaml`
- Delete: `argocd/manifests/uptime-kuma-maintenance/maintenance.sh`
- Delete: `argocd/manifests/uptime-kuma-maintenance/test-maintenance.sh`

**Interfaces:**
- Consumes: successful runtime evidence from Task 4 and persistent marker/retention value in SQLite.
- Produces: original upstream Helm-managed Application without cleanup init container.

- [ ] **Step 1: Restore exact Helm source**

Restore chart `uptime-kuma`, repository `https://dirsigler.github.io/uptime-kuma-helm`, target revision `2.24.0`, and original values including `volume.size: 500Mi`, resources, service, ingress, and `useDeploy: true`.

- [ ] **Step 2: Remove temporary maintenance directory**

Delete only seven files listed above. Preserve design and plan documents. Do not delete marker or application data through shell commands. Restoring Helm-rendered PVC removes temporary recurring-job group label through ArgoCD ownership; removing `recurring-job.yaml` prunes only `uptime-kuma-cleanup-trim`.

- [ ] **Step 3: Validate final diff**

Run:

```bash
rtk git diff --check
rtk proxy yamllint -c .yamllint.yaml argocd/apps/uptime-kuma.yaml
rtk git diff -- argocd/apps/uptime-kuma.yaml argocd/manifests/uptime-kuma-maintenance
rtk git status --short
```

Expected: Application source restored exactly; maintenance directory deleted; unrelated `AGENTS.md` untouched.

- [ ] **Step 4: Commit hook removal**

Stage only Application and deleted maintenance files. Use `commit` skill with message:

```text
chore(uptime-kuma): remove retention cleanup hook
```

- [ ] **Step 5: Ask approval and push cleanup commit**

Explain this push removes temporary hook and returns management to upstream Helm chart. Push only after explicit approval.

- [ ] **Step 6: Verify final stable state**

After ArgoCD sync, require:

- Application `Synced/Healthy`;
- one Ready pod with stable UID and zero restarts after final rollout;
- no init container in final Deployment;
- SQLite integrity `ok` and retention `30`;
- monitor count unchanged;
- PVC use remains materially below pre-cleanup 87%;
- Longhorn volume healthy with three replicas;
- actual-size alert resolved after declarative trim/snapshot lifecycle.

If Longhorn actual size stays above 90% while filesystem use is low, stop and create a separate design for assigning this PVC to a GitOps-managed filesystem-trim recurring job. Do not broaden this cleanup automatically.
