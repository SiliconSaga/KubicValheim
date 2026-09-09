# Backups

Backups run in two stages: odin writes archives inside the cluster, and a nightly Jenkins job ships the newest one off it.

## In-cluster

odin's `AUTO_BACKUP` writes hourly tarballs to `/home/steam/backups`, on a dedicated **`valheim-backups` PVC**.

That volume being separate is load-bearing, not tidiness. The world PVC's root mounts at the save directory, so a `subPath` under it would make `/home/steam/backups` *be* `<savedir>/backups` — and odin archives the whole save directory. Every hourly tarball would then contain all previous ones, growing until the volume filled and world writes failed.

Pruning is on (`AUTO_BACKUP_REMOVE_OLD=1`, `DAYS_TO_LIVE=3`), so the backups volume should stay small.

**`AUTO_BACKUP_ON_SHUTDOWN` is evaluated independently of `AUTO_BACKUP`.** Leaving it enabled in base would write a tarball on every pod termination even for overlays that believe backups are switched off — with no pruning and no alerting on those archives.

## Off-cluster

A nightly Jenkins job ships the newest archive to `gs://kubic-game-hosting/valheim/<slug>/<ts>/` and touches a `.last-upload` marker. The marker is what makes the freshness metric mean *"a backup left the cluster"* rather than *"odin ran"* — those are different claims, and only the first one survives losing the cluster.

**Jenkins cron is UTC.** A `cron('30 3 * * *')` spec fires at 03:30 UTC, which is the *previous* evening in Eastern — 23:30 EDT in summer, 22:30 EST in winter — not overnight local. Archive names from Jenkins runs are stamped UTC accordingly, while a hand-run from a workstation stamps local time.

## Dormant instances

An instance scaled to zero has no pod, so there is nothing to produce a tarball
and nothing to copy one from. The nightly job still runs — and reports
**UNSTABLE**, not failure.

`backup-server.sh` checks `spec.replicas` before looking for a pod and exits **2**
when it is zero; `backup.Jenkinsfile` maps that one code to `unstable()`. Exit 1
still means something is genuinely wrong, including `spec >= 1` with no pod,
which is a server that fell over rather than one that was parked.

**This is the same intent signal the `ValheimDown` alert uses** to stay quiet for a
parked server (the trailing `unless … kube_deployment_spec_replicas == 0` in
`kustomize/fleet/prometheusrule.yaml`). Deliberately the same one: an operator
scaling a server down should not have to know that alerting and backups disagree
about what "off" means.

The three obvious alternatives are each worse:

| Option | Why not |
|---|---|
| Fail | A nightly red build for a server nobody asked to be running. Expected red is ignored red — and the next *real* failure goes with it. |
| Succeed | Reports a backup that did not happen. The exact silent failure the staleness and `tar -tzf` guards exist to prevent. |
| Disable the job | The schedule then has to be remembered and re-armed by hand at wake-up. That is the step that gets forgotten. |

UNSTABLE is the honest answer: nothing was backed up, nothing needed to be, and
the job is still armed for when the server comes back.

**Hibernating a server — use the job.** `scripts/hibernate-server.sh`, and the
per-instance **Hibernate server** Jenkins job that wraps it, exist precisely
because the ordering is not the intuitive one. The upload path needs a running
pod, so it cannot run after the scale-down. The script does, in order:

1. Refuse if already hibernated (exit 2 → UNSTABLE).
2. Warn if the server log still shows connections.
3. Ask odin for a **fresh** archive — see below.
4. Run `backup-server.sh`, which applies the staleness and `tar -tzf` guards and
   refreshes the upload marker. **If this fails, it does not scale down.**
5. Scale to 0. `AUTO_BACKUP_ON_SHUTDOWN=1` writes one final local tarball to the
   backups PVC as it stops.

`SKIP_BACKUP=1` (the `skipBackup` job parameter) scales down without step 3 or 4,
for urgent shutdowns. It does not change the resulting state — a server stopped
in a hurry and one hibernated properly are both `spec.replicas: 0` and
indistinguishable afterwards. The difference is only whether a fresh archive
reached GCS, which is why the default takes one.

**Why a fresh archive rather than the newest hourly.** Without step 3,
wake-then-hibernate deadlocks: the staleness guard rejects anything older than
3h, and immediately after a wake the newest tarball on the PVC is the *shutdown*
archive from the previous hibernation, already hours old. Observed exactly that —
`newest backup is 10878s old (limit 10800s)` — leaving only "wait for odin's next
hourly" or "skip the backup" as ways forward, neither of which is a reasonable
answer to *put this server to sleep*. A hibernation backup should also simply
capture the world as it is **now**, not up to an hour ago.

**That final tarball is not protected immediately.** It cannot be uploaded —
there is no pod left to copy it from — so it waits for the *next* Velero
snapshot of the `valheim-backups` PVC, which is external to this repo and runs
daily. Depending on when you park the server that is **up to ~24 hours** during
which the shutdown archive exists only on the PVC.

That is usually an acceptable gap rather than a real exposure, because the
shutdown tarball is a *duplicate* of a world that is already covered: the
`valheim-data` PVC is snapshotted on the same schedule, and step 2 above put a
copy in GCS. It matters only if you are relying on that last archive
specifically — in which case wait for the next snapshot before deleting
anything.

**Waking a server:** use `scripts/wake-server.sh` or the **Wake server** job. It
scales up, waits for Ready, and then **verifies a world actually came back** — a
server that starts with an empty world is indistinguishable from a healthy one
from the outside, which is the same reasoning [restore.md](restore.md) applies to
restores. It fails loudly if `worlds_local` is empty, because the next thing that
happens otherwise is players connecting to a freshly generated map.

The first *scheduled* backup after a wake can still legitimately fail the 3-hour
staleness guard, since the newest tarball dates from the hibernation. Let odin
write a fresh hourly archive, or just hibernate again — that path takes its own
fresh archive and is unaffected.

## Metrics and alerts

A busybox sidecar exposes four gauges on `/metrics.txt`. Only the two age metrics are in seconds:

| Metric | Meaning |
|---|---|
| `valheim_backup_age_seconds` | age of the newest local tarball; `-1` when none exist |
| `valheim_backup_upload_age_seconds` | age of the last off-cluster upload marker; `-1` when never uploaded |
| `valheim_backup_count` | how many local tarballs are retained |
| `valheim_backup_bytes` | size of the newest local tarball |

Only **`ValheimBackupMissing`** pages the phone, through heimdall's `watched: "true"` route — no backups existing at all is a standing data-loss exposure on a world people are building in. `ValheimBackupStale`, `ValheimBackupNotUploaded` and `ValheimBackupExporterDown` deliberately route to `heimdall-info` instead: each is a backup *plumbing* fault with a healthy world and a running game, and routing every one of them to the paging tier is how the tier stops meaning anything.

The backup alerts live in the opt-in `components/observability-backups`, separately from the main observability component, because they assume `AUTO_BACKUP=1` — enabling them against an instance with backups off would page about a condition that is deliberate.

A `-1` sentinel means *no archive found at all* and fires `ValheimBackupMissing`; it deliberately does **not** also fire `ValheimBackupStale`, since "missing" and "old" want different responses.

## Restoring

See [restore.md](restore.md) for the runbook, and [world-identity.md](world-identity.md) first if you are restoring an archive onto a different instance than it came from.
