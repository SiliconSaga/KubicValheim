# KubicValheim documentation

One Kustomize `base/` is the single source of truth for the server; everything else composes it. Platform extras are additive Kustomize *components*, and the pod spec does not change between flavors — only where the `valheim-secrets` Secret comes from.

These pages assume you have read the [root README](../README.md), which carries the amd64 requirement and the quickest way in.

## Topics

| Page | What it covers |
|---|---|
| [flavors.md](flavors.md) | The three ways to run the same core, and how to choose |
| [instances.md](instances.md) | Running several servers from one base, without copy-paste |
| [networking.md](networking.md) | Ports, firewall rules, and how players actually connect |
| [published-address.md](published-address.md) | The shared DNS name in front of the fleet, and repointing it |
| [backups.md](backups.md) | How worlds get archived, and what the alerts mean |
| [restore.md](restore.md) | The restore runbook — destructive, read it before running it |
| [world-identity.md](world-identity.md) | What names a world, why a rename is not a rename, reviving old saves |

## Where to start

Running a server for the first time: [flavors.md](flavors.md), then [networking.md](networking.md).

Operating an existing one: [backups.md](backups.md) and [published-address.md](published-address.md) are the two that page you.

Recovering a world from an archive: [world-identity.md](world-identity.md) first — the world name has to line up before [restore.md](restore.md) can help you.
