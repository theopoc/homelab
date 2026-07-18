# Linkwarden RSS Polling Interval Design

## Goal

Configure Linkwarden to poll RSS subscriptions every 12 hours.

## Change

Add `NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES` to Linkwarden Helm
`valuesInline.extraEnv` with string value `"720"`. Twelve hours equals 720
minutes, matching variable unit.

No Secret or ConfigMap needed because value is non-sensitive and existing
Linkwarden settings already use `extraEnv`.

## Verification

Render Kustomize manifests with Helm support and confirm generated Linkwarden
Deployment contains exactly one environment variable named
`NEXT_PUBLIC_RSS_POLLING_INTERVAL_MINUTES` with value `"720"`.
