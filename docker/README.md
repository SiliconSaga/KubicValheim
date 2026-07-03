# Flavor 1 — Plain Docker Compose

The zero-Kubernetes way to run KubicValheim: the same pinned community image and the same Huginn settings as the Kubernetes flavors, in a single `docker-compose.yml`.

## Quickstart

Copy the example env and set a real password (>= 5 chars, must not contain the server NAME):

```bash
cp .env.example .env
# edit .env and set VALHEIM_PASSWORD
docker compose up -d
```

First boot downloads the server via SteamCMD — be patient (a couple of GB). Watch progress:

```bash
docker compose logs -f
```

## Connecting

Valheim listens on UDP **2456** (game) and **2457** (query — the port the Steam server browser lists and players use to find/join the server). Add the server in the Steam server browser by its query port, `<host>:2457`. Allow UDP 2456-2457 through the host firewall either way.

## Metrics & status

The Huginn HTTP server (enabled via `HTTP_PORT`/`PUBLIC`/`ADDRESS`) serves:

- `http://<host>:8080/metrics` — Prometheus exposition (player count, system stats)
- `http://<host>:8080/status` — JSON status

## Persistence

The named volume `valheim-data` holds the world at `/home/steam/.config/unity3d/IronGate/Valheim` and survives `docker compose down` / `up`. `stop_grace_period: 2m` gives the server time to flush the world on shutdown.

## Architecture note

The Valheim dedicated server is x86_64-only — this image has no ARM build. On an Apple Silicon Mac the 32-bit SteamCMD it bundles segfaults under emulation, so run this on an amd64 host (an Intel/AMD Linux box, a Windows machine, or an amd64 cloud VM).
