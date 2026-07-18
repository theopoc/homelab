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

## Verification

Run repository pre-commit checks. Render Kustomize manifests with Helm support
and confirm generated Linkwarden Deployment uses image
`ghcr.io/linkwarden/linkwarden:v2.15.1`. Confirm all three requested
environment variables occur exactly once with exact string values.
