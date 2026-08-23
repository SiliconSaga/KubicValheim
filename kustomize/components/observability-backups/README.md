# Backup alerting component — opt in ONLY where `AUTO_BACKUP="1"`

Ships one `PrometheusRule` (`valheim-backups`) carrying `ValheimBackupStale`, `ValheimBackupMissing`, `ValheimBackupNotUploaded`, and `ValheimBackupExporterDown`.

> **Include this only from an overlay that patches `AUTO_BACKUP="1"`.** Base ships `AUTO_BACKUP="0"` and the `backup-exporter` sidecar runs regardless, reporting `valheim_backup_age_seconds=-1`. On an overlay without backups that makes `ValheimBackupMissing` — `severity: critical`, `watched: "true"`, so it pushes to a phone — fire permanently, 30 minutes after every deploy.

Today that means `overlays/valheim7`. `overlays/gitops` and `overlays/plain` deliberately do **not** include it.

## Why it is a separate component

`components/observability` carries what is true for every instance: the ServiceMonitor, the dashboard, and `ValheimDown` / `ValheimNotOnline`. Backup alerting is conditional on a per-overlay env patch, so it gets its own additive component rather than a flag inside the first one — matching how the rest of this repo composes optional behaviour.

Whenever a new overlay turns `AUTO_BACKUP` on, add this component alongside `components/observability` in its `components:` list.
