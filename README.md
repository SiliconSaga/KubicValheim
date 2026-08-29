# KubicValheim

A Kustomize-based Valheim dedicated server that runs the **same core three ways** — plain Docker, plain Kubernetes, and Kubernetes-plus-platform-extras (GitOps). One source of truth, data-driven instancing, observability included. This is the reference pattern other game components (Ark, Terasology, Rend) follow.

## Requirements

The Valheim dedicated server is **x86_64-only** — there is no ARM build, and the bundled 32-bit SteamCMD segfaults under emulation. Run it on an amd64 host or cluster. The manifests are architecture-independent; the game binary is not.

## Start here

| You want | Go to |
|---|---|
| Run it with Docker, no Kubernetes | [`docker/README.md`](docker/README.md) |
| Run it on Kubernetes | `kubectl apply -k kustomize/overlays/plain` |
| Understand the three flavors | [`docs/flavors.md`](docs/flavors.md) |
| Add another server instance | [`docs/instances.md`](docs/instances.md) |
| Let players in | [`docs/networking.md`](docs/networking.md) |
| Recover a world | [`docs/restore.md`](docs/restore.md) |

Full documentation index: [`docs/README.md`](docs/README.md).

## Layout

```
docker/                      # Flavor 1: docker-compose + env + README
kustomize/
  base/                      # the shared core (one source of truth)
  components/                # additive extras: observability, secrets-openbao, backup
  overlays/                  # per-flavor and per-instance compositions
scripts/                     # instance renderer, backup, restore, archive inspector
docs/                        # documentation index and topics
```

## License

Apache-2.0 — contributions and forks welcome. The [`mbround18/valheim`](https://github.com/mbround18/valheim-docker) image is licensed per its upstream project.
