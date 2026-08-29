# Flavors

The same core runs three ways. A single Kustomize `base/` — Deployment, UDP NodePort Service, ClusterIP metrics Service, PVCs, player-list ConfigMap — is the one source of truth. Each platform extra is an additive Kustomize **component**, and overlays compose them.

The pod spec is identical across all three. The only thing that differs is the *source* of the `valheim-secrets` Secret.

## Flavor 1 — Plain Docker

For running the server without Kubernetes at all. Same pinned image and the same Huginn settings as the Kubernetes flavors.

Setup, connection details and the persistence model live in [`docker/README.md`](../docker/README.md), next to the compose file you will actually be running.

## Flavor 2 — Plain Kubernetes

Zero extra tooling — boots with a bare kustomize apply:

```bash
kubectl apply -k kustomize/overlays/plain
```

The password is a plain Kubernetes Secret. Nothing else is required: no operator, no GitOps controller, no secrets backend. This is the flavor to reach for on a cluster you do not otherwise run a platform on.

The bundled `plain` overlay is an example instance named "midgard". To run your own, see [instances.md](instances.md).

## Flavor 3 — GitOps (ArgoCD + OpenBAO)

The `kustomize/overlays/gitops` overlay is base + `observability` + `secrets-openbao`, deployed by the nidavellir ArgoCD Application. The server password is sourced from OpenBAO through External Secrets rather than living in a Secret manifest.

Observability comes with it: metrics scrape into heimdall's Prometheus and Grafana, and logs reach Loki through the cluster-wide OTel Collector.

**Change this flavor through Git.** A `kubectl edit` against a flavor-3 deployment is reverted by selfHeal, which presents as your change silently disappearing some minutes later.

## Components

| Component | Adds | Opt-in |
|---|---|---|
| `observability` | ServiceMonitor + Grafana dashboard | yes |
| `secrets-openbao` | ExternalSecret for `valheim-secrets` | yes |
| `backup` | inert S3 seam, reserved for the Phase-3 CronJob | yes |

## Repository layout

```
docker/                      # Flavor 1: docker-compose + .env.example + README
kustomize/
  base/                      # the shared core (one source of truth)
  components/
    observability/           # ServiceMonitor + Grafana dashboard
    secrets-openbao/         # ExternalSecret for valheim-secrets
    backup/                  # inert S3 seam scaffold (Phase 3)
  overlays/
    plain/                   # Flavor 2: base + plain Secret (example "midgard")
    gitops/                  # Flavor 3: base + observability + secrets-openbao
    <instance>/              # per-instance overlays, generated
scripts/start-server.sh      # data-driven per-instance overlay renderer
```

## Details worth knowing

- **Image:** `mbround18/valheim:3.6.0`, pinned — never `:latest`. It runs the Huginn HTTP server (`HTTP_PORT` / `PUBLIC` / `ADDRESS`), which serves `/metrics` and `/status`.
- **Player lists:** the `valheim-player-lists` ConfigMap (admin / banned / permitted) is copied into the world config directory by an init container on every start. That is why a restore does not need to preserve them.
