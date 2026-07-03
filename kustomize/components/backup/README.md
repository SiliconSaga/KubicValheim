# Backup component — inert scaffold (Phase 3 seam)

This Kustomize component is intentionally empty. It ships **no** backup workload in Phase 1 — no CronJob, no sidecar, no credentials. Its only job is to reserve the shape and document the contract so a later phase can fill it without touching the Valheim core.

## The contract: S3-endpoint-agnostic

The umbrella design requires the game component to depend on an **abstract S3 endpoint**, never a specific storage engine. The backup workload (Phase 3) takes its entire configuration from env/Secret — `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` — so swapping the engine (Garage or SeaweedFS on homelab, GCS on GKE) is a Secret change, not a redesign.

## Planned mechanism (Phase 3, not implemented here)

A CronJob that ships the world save files from `/home/steam/.config/unity3d/IronGate/Valheim/worlds/` to the configured S3 endpoint, restorable by dropping the files back onto the PVC before the server starts.

## Explicitly NOT the path forward

The legacy `mbround18` `AUTO_BACKUP*` env vars and the deleted shared-NFS volume (`valheim-shared-pv-claim`, `storage-class: dynamic-nfs`) are **not** the backup strategy — they were local-only and have rotted. Off-cluster, engine-agnostic S3 is the direction.

## Using the seam today

Including this component in an overlay is a no-op (`resources: []` renders nothing). It exists so overlays can wire the seam early and Phase 3 can fill it in place.
