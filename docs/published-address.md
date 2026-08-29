# The published address

The live event server is **`play.terasology.org:32456`** (instance `valheim7`, world `Jotunheim`).

That name is a single explicit **A record** pointed at one node's external IP. It is not managed by any Ingress or Gateway. Because the Service uses `externalTrafficPolicy: Cluster` (see [networking.md](networking.md)), any node's address serves the NodePorts — so one name can front the whole fleet, with instances distinguished only by port.

## Repointing it

The address is owned by the **`tafl` component**, not this one: one A record serves every hosted game, so a drifted address is a fleet-wide condition rather than a Valheim one. Keeping a copy per instance produced a separate critical page per namespace for a single DNS failure, which is why it moved.

Repointing means updating the DNS record **and** the address written into tafl's `kustomize/fleet/published-ip.yaml`. Use tafl's `scripts/update-published-ip.sh <new-ip> --apply`, which does both together.

Two things to know before touching this by hand:

- **`terasology.org` carries many unrelated records.** Namecheap's `setHosts` API is declarative for the entire domain — it replaces the whole record set. Do **not** point nordri's `scripts/update-dns-namecheap.sh` at this domain: it sends only `@` and `*`, so everything else on the domain is deleted.
- **Prefer a node that is currently running a game pod.** Those carry `safe-to-evict: "false"`, so the autoscaler cannot reclaim them out from under the published address.

## What the drift alert does and does not catch

`GameFleetPublishedIPDrift` **never resolves DNS.** It checks only whether the address recorded in the rule still appears among the cluster's node `ExternalIP` metrics.

So it catches the failure that happens on its own — a node recycled out from under a published address, which is what a node-pool roll does. It cannot catch the A record and the rule disagreeing with *each other*: update one without the other and the alert sits green while the fleet is unreachable by name.

That is the reason to use the script rather than editing two places by hand. Closing the gap properly needs a check against the hostname rather than a transcribed address — tracked as [tafl#4](https://github.com/SiliconSaga/tafl/issues/4).
