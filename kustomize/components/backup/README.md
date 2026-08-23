# Backup component — still an inert scaffold (Phase 3 seam)

This Kustomize component remains intentionally empty (`resources: []`). Including it is a no-op.

## What actually ships backups today (Phase 2)

Backups are **not** in this component. As of 2026-08-23 they work in two halves, outside this seam:

1. **odin's built-in `AUTO_BACKUP`** writes hourly tarballs to `/home/steam/backups`, which `base` mounts as a `subPath` on the world PVC. Enabled per-overlay by patching `AUTO_BACKUP="1"`.
2. **A nightly Jenkins job** (`backup.Jenkinsfile` + `scripts/backup-server.sh`) uploads the newest tarball to `gs://kubic-game-hosting/valheim/<slug>/<ts>/`, mirroring the long-running KubicArk pattern.

Design: `docs/plans/2026-08-23-backups-and-game-volume-design.md`.

## Why this reverses the earlier note

An earlier revision of this file named the `AUTO_BACKUP*` env vars as "explicitly NOT the path forward." That judgement was aimed at `AUTO_BACKUP` as the *entire* strategy — local-only, coupled to a shared-NFS mount that had rotted. Using it purely as the **local tarball producer**, with off-cluster shipping handled separately, is a different proposition, and it keeps the artifact file-based, which is what tafl's eventual dehydrate/rehydrate needs.

## What this seam is still for (Phase 3)

The S3-endpoint-agnostic CronJob — `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` — so the same manifests back up to Garage or SeaweedFS on homelab and GCS on GKE without a redesign. The Jenkins path above is GCS-specific and GKE-specific by construction; it is a stepping stone, not the destination.
