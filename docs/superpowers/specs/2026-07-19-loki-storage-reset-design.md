# Loki Storage Reset Design

## Goal

Recover Loki from a full `2Gi` persistent volume, reduce log retention from
seven days to 24 hours, and keep the persistent volume size at `2Gi`.

The reset intentionally and irreversibly deletes all currently stored Loki
logs. This data loss was explicitly approved.

## Evidence

The live `storage-loki-0` claim is `2Gi` and uses about 99.2% of its usable
capacity. Loki exits during startup with `no space left on device` while
building TSDB data from WAL files. The claim has a controller owner reference
to StatefulSet `loki`. The StatefulSet declares
`persistentVolumeClaimRetentionPolicy.whenDeleted: Delete`, and Longhorn uses
reclaim policy `Delete`.

The Loki chart forces one replica for single-binary filesystem mode, even when
`singleBinary.replicas` is set to zero. Scaling to zero through Helm values
therefore cannot perform the reset.

## Change

Perform reset through two GitOps phases.

### Phase 1: Recreate StatefulSet and storage

Change `loki.limits_config.retention_period` from `168h` to `24h`.

Add this temporary StatefulSet annotation through
`singleBinary.annotations`:

```yaml
argocd.argoproj.io/sync-options: Force=true,Replace=true
```

Argo CD will delete and recreate only StatefulSet `loki`. Deleting current
StatefulSet triggers Kubernetes garbage collection of owned
`storage-loki-0`, then Longhorn deletes its volume. Recreated StatefulSet
creates a fresh `2Gi` claim from unchanged volume claim template.

Commit and push phase 1. Let parent `monitoring` application update child
`loki` application, then let child application sync automatically. Do not
issue imperative cluster mutations.

### Phase 2: Remove destructive sync option

After confirming new claim exists and Loki is healthy, remove temporary
`Force=true,Replace=true` annotation. Commit and push phase 2 immediately so
future routine syncs cannot recreate storage again.

## Verification

Before phase 1, record StatefulSet, PVC, and PV UIDs. Render Loki Helm chart
locally and confirm:

- StatefulSet annotation is exactly `Force=true,Replace=true`.
- retention period is exactly `24h`.
- persistent volume request remains exactly `2Gi`.

After phase 1 sync, confirm:

- old PVC and PV UIDs no longer exist;
- replacement claim is `Bound` with capacity `2Gi`;
- Loki reaches `2/2 Ready`;
- live Loki config contains `retention_period: 24h`;
- recent Loki logs contain no `no space left on device` error;
- Argo CD child application reaches `Synced` and `Healthy`.

After phase 2 sync, confirm temporary annotation is absent from both desired
and live StatefulSet, UIDs remain unchanged, and Loki remains Ready.

## Rollback

Deleted logs and old Longhorn volume cannot be recovered through this change.
Retention can be returned to `168h` in Git, but doing so risks filling `2Gi`
again. Removing temporary force annotation stops further storage recreation;
it does not restore deleted data.
