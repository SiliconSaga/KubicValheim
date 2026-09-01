# Networking

Valheim uses two UDP ports, and they are not interchangeable. Most connection problems are one of them being used where the other was wanted.

## The two ports

| Port (in-container) | Purpose | Used by |
|---|---|---|
| 2456 | **game** | *Join by IP* in-game, and the actual gameplay traffic |
| 2457 | query (Steam / A2S) | the Steam server browser, to list and find the server |

On Kubernetes these are exposed as NodePorts — `32456` game and `32457` query for the `valheim7` instance, offset per instance (see [instances.md](instances.md)).

**Which one you give a player depends on how they are joining, and this is the part that costs a live debugging session:**

- **Joining by address in-game.** Valheim's *Join by IP* dialog wants the **game** port — `<host>:32456`. Entering the query port here fails.
- **Finding the server in the Steam server browser.** Adding a server to Steam's favourites wants the **query** port — `<host>:32457`. That is what the browser protocol answers on.

Both are correct for their own mechanism. Allow UDP on both ports through the host firewall regardless of which you hand out.

## Verified port bindings

Checked inside the container (`/proc/net/udp`, `/proc/net/udp6`) against the pinned 3.6.0 image:

- **2456 game** — bound on an **IPv6 dual-stack socket**. It does not appear in IPv4-only listings, so a check against `/proc/net/udp` alone reports it as not listening. This is the trap that makes the port question hard to settle by inspection.
- **2457 query** — IPv4.
- Plus a Steam ephemeral socket.

**Port 2458 is not bound by this version.** Older Valheim used `port+2`, which is why long-lived deployments often carry three-port firewall rules. Two ports is correct here — a two-port rule is not a misconfiguration to be "fixed".

## externalTrafficPolicy: Cluster

The base Service uses `externalTrafficPolicy: Cluster`, which means **any** node's external IP serves the NodePorts — not only the node currently running the pod.

That is what lets one DNS name front several instances distinguished purely by port, without anyone having to track pod placement. It also means a pod moving between nodes does not break connectivity.

The trade-off: client source IPs are SNAT'd, so server logs show a node IP rather than the player's address. That is acceptable here because Valheim's admin and ban lists are SteamID-based, not IP-based.

For the shared DNS name in front of the fleet, see [published-address.md](published-address.md).
