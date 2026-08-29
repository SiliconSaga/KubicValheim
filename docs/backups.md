# Backups

Backups run in two stages: odin writes archives inside the cluster, and a nightly Jenkins job ships the newest one off it.

## In-cluster

odin's `AUTO_BACKUP` writes hourly tarballs to `/home/steam/backups`, on a dedicated **`valheim-backups` PVC**.

That volume being separate is load-bearing, not tidiness. The world PVC's root mounts at the save directory, so a `subPath` under it would make `/home/steam/backups` *be* `<savedir>/backups` — and odin archives the whole save directory. Every hourly tarball would then contain all previous ones, growing until the volume filled and world writes failed.

Pruning is on (`AUTO_BACKUP_REMOVE_OLD=1`, `DAYS_TO_LIVE=3`), so the backups volume should stay small.

**`AUTO_BACKUP_ON_SHUTDOWN` is evaluated independently of `AUTO_BACKUP`.** Leaving it enabled in base would write a tarball on every pod termination even for overlays that believe backups are switched off — with no pruning and no alerting on those archives.

## Off-cluster

A nightly Jenkins job ships the newest archive to `gs://kubic-game-hosting/valheim/<slug>/<ts>/` and touches a `.last-upload` marker. The marker is what makes the freshness metric mean *"a backup left the cluster"* rather than *"odin ran"* — those are different claims, and only the first one survives losing the cluster.

**Jenkins cron is UTC.** A `cron('30 3 * * *')` spec fires at 03:30 UTC, which is 23:30 Eastern — not overnight local. Archive names from Jenkins runs are stamped UTC accordingly, while a hand-run from a workstation stamps local time.

## Metrics and alerts

A busybox sidecar exposes `valheim_backup_{age,count,bytes,upload_age}_seconds` on `/metrics.txt`. Alerts route to the phone through heimdall's existing `watched: "true"` route.

The backup alerts live in the opt-in `components/observability-backups`, separately from the main observability component, because they assume `AUTO_BACKUP=1` — enabling them against an instance with backups off would page about a condition that is deliberate.

A `-1` sentinel means *no archive found at all* and fires `ValheimBackupMissing`; it deliberately does **not** also fire `ValheimBackupStale`, since "missing" and "old" want different responses.

## Restoring

See [restore.md](restore.md) for the runbook, and [world-identity.md](world-identity.md) first if you are restoring an archive onto a different instance than it came from.
