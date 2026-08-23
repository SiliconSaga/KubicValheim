# KubicValheim

A modernized, Kustomize-based Valheim dedicated server that runs the **same core three ways** — plain Docker, plain Kubernetes, and Kubernetes-plus-platform-extras (GitOps). One source of truth, data-driven instancing, base observability. This is the reference pattern other game components (Ark, Terasology, Rend) follow.

## One core, three flavors

A single Kustomize `base/` (Deployment + UDP NodePort Service + ClusterIP metrics Service + PVC + player-list ConfigMap) is the one source of truth. Each platform extra is an additive Kustomize **component** (`observability`, `secrets-openbao`, `backup`); overlays compose them. The pod spec never changes between flavors — only the *source* of the `valheim-secrets` Secret differs (a plain Secret in flavor 2, an ExternalSecret from OpenBAO in flavor 3).

### Flavor 1 — Plain Docker

For users with no Kubernetes. See [`docker/`](docker/): `cp .env.example .env`, set a password, `docker compose up -d`. Same pinned image and Huginn settings as the k8s flavors.

### Flavor 2 — Plain Kubernetes

Zero extra tooling — boots with a bare kustomize apply:

```bash
kubectl apply -k kustomize/overlays/plain
```

Players connect at `<nodeIP>:32456` — the **game** port. Valheim's in-game *Join by IP* takes the game port, not the query port; `32457` is the Steam query/A2S port used by the server browser, and entering it in *Join by IP* fails. Allow UDP on both node ports (32456-32457 for the example "midgard" instance) on the host firewall. `externalTrafficPolicy: Local` preserves player source IPs.

Verified port bindings inside the container (`/proc/net/udp`, `/proc/net/udp6`) for the pinned 3.6.0 image: **2456 game** (IPv6 dual-stack socket — it does not appear in IPv4-only listings), **2457 query** (IPv4), plus a Steam ephemeral socket. Port **2458 is not bound** by this version — older Valheim used `port+2`, which is why long-lived deployments often carry three-port firewall rules, but two is correct here.

Additional instances are **data-driven** — one namespace per instance, no copy-paste:

```bash
scripts/start-server.sh asgard 32556 Asgard          # renders kustomize/overlays/asgard (ns valheim-asgard)
APPLY=1 scripts/start-server.sh asgard 32556 Asgard   # render + apply
```

### Flavor 3 — GitOps (ArgoCD + OpenBAO)

The `kustomize/overlays/gitops` overlay (base + observability + secrets-openbao) is deployed by the nidavellir ArgoCD Application, with the server password sourced from OpenBAO via External Secrets. Observability is built in: metrics scrape into heimdall's Prometheus/Grafana and logs flow to Loki via the cluster-wide OTel Collector. **Test through Git** — change flavor 3 by committing + syncing, never `kubectl edit` (selfHeal reverts it).

## Layout

```
docker/                      # Flavor 1: docker-compose + env + README
kustomize/
  base/                      # the shared core (one source of truth)
  components/
    observability/           # ServiceMonitor + Grafana dashboard (opt-in)
    secrets-openbao/         # ExternalSecret for valheim-secrets (opt-in)
    backup/                  # inert S3 seam scaffold (Phase 3)
  overlays/
    plain/                   # Flavor 2: base + plain Secret (example "midgard")
    gitops/                  # Flavor 3: base + observability + secrets-openbao
scripts/start-server.sh      # data-driven per-instance overlay renderer
```

## Details

- **Image:** `mbround18/valheim:3.6.0` (pinned, never `:latest`), with the Huginn HTTP server (`HTTP_PORT`/`PUBLIC`/`ADDRESS`) serving `/metrics` + `/status`.
- **Player lists:** the `valheim-player-lists` ConfigMap (admin / banned / permitted) is copied into the world config dir by an init container.
- **Backup:** odin's `AUTO_BACKUP` writes hourly tarballs to `/home/steam/backups` (its own `valheim-backups` PVC — deliberately not a `subPath` of the world PVC, or each tarball would contain every previous one); a nightly Jenkins job ships the newest to `gs://kubic-game-hosting/valheim/<slug>/<ts>/`. Restore procedure: [`docs/restore.md`](docs/restore.md). The `components/backup` seam remains inert and is reserved for the Phase-3 S3-endpoint-agnostic CronJob.
- **Architecture:** the Valheim dedicated server is x86_64-only (no ARM build), and its bundled 32-bit SteamCMD segfaults under emulation — so run it on an **amd64** host/cluster (GKE, an amd64 homelab, or a Windows/Linux amd64 box). The manifests are architecture-independent; the game binary is not.

## License

This project is Apache-2.0, contributions and forks welcome. The [`mbround18/valheim`](https://github.com/mbround18/valheim-docker) image is licensed per its upstream project.
