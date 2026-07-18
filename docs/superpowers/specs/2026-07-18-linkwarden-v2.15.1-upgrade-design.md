# Linkwarden v2.15.1 Upgrade Design

## Goal

Upgrade Linkwarden from `v2.14.1` to `v2.15.1` and constrain allocator and
Node.js heap behavior.

## Change

Keep Helm chart `1.0.14` and override `valuesInline.image.tag` with
`"v2.15.1"`. Chart `1.0.14` supports image-tag overrides and currently defaults
to Linkwarden `v2.14.1`.

Add these non-secret values to existing `valuesInline.extraEnv`:

```yaml
- name: MALLOC_ARENA_MAX
  value: "2"
- name: NODE_OPTIONS
  value: "--max-old-space-size=400"
```

Retain existing `ARCHIVE_TAKE_COUNT` value `"1"`; do not duplicate it.

Linkwarden `v2.15.1` invokes Prisma directly during startup. Helm chart `1.0.14`
renders `DATABASE_URL` with shell-style `${VAR}` references, which remain
literal and prevent Prisma from reaching PostgreSQL. Extend existing strategic
Deployment customization with guarded JSON operations that verify chart's
container and environment positions, then replace value using Kubernetes
dependent-variable syntax `$(VAR)`. Replacement preserves position after
referenced PostgreSQL variables, which remain sourced from existing Secrets.
If chart layout changes, JSON `test` operations make manifest rendering fail
instead of patching wrong field.

Increase Linkwarden container memory limit from `1536Mi` to `2Gi`. Live
`v2.15.1` evidence showed repeatable `OOMKilled` exits immediately after worker
launched Chromium despite requested allocator and Node.js heap settings. Keep
memory request at `500Mi`; `2Gi` is smallest approved limit increase to test.

## Verification

Run repository pre-commit checks. Render Kustomize manifests with Helm support
and confirm generated Linkwarden Deployment uses image
`ghcr.io/linkwarden/linkwarden:v2.15.1`. Confirm all three requested
environment variables occur exactly once with exact string values.
Confirm rendered `DATABASE_URL` uses `$(VAR)` references after referenced
PostgreSQL variables, then verify live pod reaches Ready state without restart.
Monitor at least one link-processing/browser cycle and confirm restart counter
does not increase.
