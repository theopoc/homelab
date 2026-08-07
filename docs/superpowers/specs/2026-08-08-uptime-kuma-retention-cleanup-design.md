# Uptime Kuma 30-day retention and PVC cleanup

## Goal

Reduce Uptime Kuma retained heartbeat history from 180 days to 30 days and reclaim filesystem space without expanding the 500 MiB PVC.

The cleanup deletes only heartbeat rows older than 30 days. It preserves monitors, settings unrelated to retention, notifications, status pages, users, certificates, and current heartbeat history.

## Current state

- ArgoCD application: `argocd/apps/uptime-kuma.yaml`
- Workload: Uptime Kuma 1.23.17, one Deployment replica
- PVC: `uptime-kuma-pvc`, Longhorn, 500 MiB
- Filesystem use observed before maintenance: 381 MiB used, 62 MiB available
- Active SQLite files: `kuma.db` 301 MiB and `kuma.db-wal` 69 MiB
- Configured retention: `keepDataPeriodDays=180`
- Longhorn actual-size ratio observed: 102.22%
- Latest Longhorn backup must be successful and restorable before cleanup begins

## Constraints

- No PVC expansion.
- No direct `kubectl apply`, `delete`, `patch`, or manual Helm operation.
- Every cluster-state change flows through committed ArgoCD manifests.
- Uptime Kuma may be unavailable for 10–30 minutes.
- Active WAL must never be deleted manually.
- Original database must not be replaced unless compacted copy passes integrity checks.

## Selected design

Use a temporary, Git-tracked ArgoCD maintenance deployment. During maintenance, the Uptime Kuma Application temporarily renders local manifests matching the existing Deployment, Service, and PVC resource identities. This avoids resource replacement while allowing a one-shot init container before the normal Uptime Kuma container starts.

The init container mounts:

- existing PVC at `/data`;
- node-backed `emptyDir` at `/work`, sized to hold a compacted database;
- no Kubernetes API token;
- no network-dependent control path;
- only tools needed for SQLite maintenance.

A versioned marker such as `/data/.maintenance/retention-30d-20260808.done` makes cleanup non-repeating. Failed checks leave marker absent and prevent Uptime Kuma startup.

## Maintenance algorithm

1. ArgoCD replaces running pod from committed temporary manifest. Normal container stops cleanly, allowing SQLite to close WAL.
2. Init container verifies:
   - PVC mounted read-write;
   - expected database exists;
   - completion marker absent;
   - latest Longhorn backup status was verified before maintenance commit is synced.
3. Init container copies active SQLite database into `/work` using SQLite backup semantics. It does not copy raw live WAL as replacement data.
4. Working copy receives one transaction:
   - set `setting.key='keepDataPeriodDays'` to `30`;
   - delete rows where `heartbeat.time < datetime('now', '-30 days')`.
5. Working copy runs `VACUUM` on `emptyDir`, keeping compaction workspace outside constrained PVC.
6. Validation runs on compacted copy:
   - `PRAGMA integrity_check` returns exactly `ok`;
   - retention setting equals `30`;
   - no heartbeat older than cutoff remains;
   - all monitor rows remain;
   - compacted database size plus a fixed safety margin fits current free PVC capacity while the original database remains present.
7. Only after all checks pass:
   - rename original `kuma.db` to a rollback filename on the same filesystem without copying it;
   - retain closed `kuma.db-shm` and `kuma.db-wal` until replacement succeeds;
   - copy compacted database to a temporary filename on PVC;
   - fsync file and directory;
   - atomically rename temporary file to `kuma.db`;
   - remove rollback database and obsolete SHM/WAL only after the replacement database passes a second integrity check from its final path;
   - create completion marker.
8. Normal Uptime Kuma container starts.

Because PVC has little free space, implementation must calculate sizes before any rename or deletion. If compacted database plus safety margin does not fit beside the renamed original database, maintenance aborts with original database unchanged. There is no low-space fallback that deletes the original first.

## Failure handling and rollback

- Failure before replacement: original database remains authoritative; init container exits non-zero; Uptime Kuma stays stopped.
- Failure during copy-back before atomic rename: temporary copy is removed and rollback filename is renamed back to `kuma.db`.
- Failure after replacement: restore verified Longhorn backup through a separate, explicitly approved recovery change.
- No automatic repeated deletion: completion marker prevents rerun after pod rescheduling.
- No cleanup of `/app/data/uptime-kuma/` stale directory in this operation. That separate 12 MiB deletion needs separate inventory and approval.

## GitOps lifecycle

1. Commit temporary local manifests and Application source change.
2. Allow ArgoCD sync.
3. Verify maintenance completion and application health.
4. Commit removal of temporary manifests and restore upstream Helm source.
5. Verify ArgoCD `Synced/Healthy` and stable Uptime Kuma pod after final sync.

No manual cluster mutation forms part of this lifecycle.

## Verification criteria

Maintenance succeeds only when all conditions hold:

- completion marker exists once;
- `PRAGMA integrity_check` returns `ok`;
- `keepDataPeriodDays` equals `30`;
- oldest heartbeat is no older than 30 days, allowing execution-time boundary tolerance;
- monitor count matches pre-maintenance count;
- Uptime Kuma pod becomes Ready with zero crash-loop behavior;
- application logs contain no SQLite corruption, disk-full, migration, or WAL errors;
- PVC filesystem use decreases materially;
- Longhorn volume remains healthy with three replicas;
- filesystem trim runs through declarative Longhorn recurring-job configuration or a separately reviewed GitOps resource;
- Longhorn actual-size alert resolves after snapshot/trim accounting catches up.

## Out of scope

- PVC expansion
- Uptime Kuma version upgrade
- chart migration
- deletion of stale `/app/data/uptime-kuma/`
- removal of monitors or other application configuration
- manual Longhorn or Kubernetes commands that change state
