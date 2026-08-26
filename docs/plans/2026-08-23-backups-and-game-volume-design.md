# KubicValheim — nightly off-cluster backups + a persistent game-files volume

**Status:** design, awaiting approval
**Date:** 2026-08-23
**Tracker:** SiliconSaga/tafl#2 (Phase 2)
**Cross-repo dependency:** SiliconSaga/heimdall (one-line selector fix)

## Why

Three unrelated-looking problems share one pod-spec change, so they are designed together.

1. **valheim7 has no backups.** The only copy of the Jotunheim world is a single GCE PD. An event runs on it in ~2 weeks.
2. **Every pod restart re-downloads ~1.76GB.** The PVC covers only the world/config dir; the game install at `/home/steam/valheim` is container-local, so `odin install` re-runs on every start — ~4 minutes of downtime for what should be seconds.
3. **No alerting.** Nothing tells Cervator the server is down except a player complaining.

## Deliberate divergence from the Phase-1 scaffold

`kustomize/components/backup/README.md` currently states the direction is an in-cluster CronJob shipping to an **abstract S3 endpoint**, and names the `AUTO_BACKUP*` env vars as "explicitly NOT the path forward."

This design does the opposite on both counts, deliberately and as an **interim Phase-2 step**:

- It uses odin's `AUTO_BACKUP*` to produce tarballs locally.
- It ships them with a **Jenkins job to GCS**, mirroring the working KubicArk pattern, not an S3-agnostic CronJob.

The Phase-1 rejection of `AUTO_BACKUP*` was aimed at it being the *whole* strategy — local-only, coupled to a rotted shared-NFS mount. Using it purely as the **local tarball producer**, with off-cluster shipping handled separately, is a different proposition and keeps the artifact file-based, which is what tafl's eventual dehydrate/rehydrate needs.

The scaffold README must be rewritten as part of this work so the repo does not contradict itself. The S3-agnostic CronJob remains the Phase-3 target; this is explicitly a stepping stone.

## A. Volume layout and restart safety

```
valheim-data     10Gi RWO   ~/.config/unity3d/IronGate/Valheim    (existing)
valheim-game     10Gi RWO   /home/steam/valheim                   (NEW PVC)
valheim-backups  10Gi RWO   /home/steam/backups                   (NEW PVC)
```

> **Corrected during final review.** This section originally put backups on the world PVC under `subPath: backups`, reasoning that they are staging only so co-locating them keeps the volume count down and lets a restore recover world and backup history together. That reasoning is wrong and the shipped manifests do not follow it. `subPath: backups` on `valheim-data` makes `/home/steam/backups` literally `<savedir>/backups`, and odin archives the whole savedir — so every hourly tarball would contain all previous tarballs, roughly doubling each run until the 10Gi world PVC fills (about a day at hourly with 72 retained) and world writes fail. Upstream's own docker-compose puts `/home/steam/backups` on a separate volume for exactly this reason. Backups get their own `valheim-backups` claim. The trade is now the opposite of the one described: losing the world PVC no longer takes the local tarballs with it.

`/home/steam/backups` **requires** a mount. The upstream docs are explicit: backups are written there and are lost with the container otherwise. Enabling `AUTO_BACKUP` without this mount silently produces nothing durable.

### `strategy: Recreate` is mandatory

The Deployment currently uses `RollingUpdate` with `maxSurge: 25%`. For a single replica that means Kubernetes starts the new pod **before** terminating the old one. With RWO volumes the new pod cannot attach disks the old pod still holds.

This has not bitten yet only because both pods happened to land on the same node, where a GCE PD can be mounted into two pods. That is luck, not design, and adding a second RWO volume doubles the exposure. `Recreate` is the correct strategy for a single-replica stateful workload and is currently missing.

`VALIDATE_ON_INSTALL` stays at its default of `1`. Persisting the game files removes the download; validation still runs each boot and catches corruption, which is cheap insurance for a server that is not restart-heavy.

## B. Backups

### Server side (base, off by default; enabled per-overlay)

```yaml
AUTO_BACKUP: "1"
AUTO_BACKUP_SCHEDULE: "0 * * * *"   # hourly
AUTO_BACKUP_ON_SHUTDOWN: "1"
AUTO_BACKUP_REMOVE_OLD: "1"
AUTO_BACKUP_DAYS_TO_LIVE: "3"
```

**Hourly, not nightly, and this is the important bit.** If odin backed up nightly and Jenkins uploaded nightly, the two schedules would race: a Jenkins run firing before odin's would silently ship the *previous day's* world, and the failure is invisible — the upload succeeds, the contents are just stale. Running odin hourly means Jenkins can upload "the newest tarball" at any time and always get something at most an hour old. It removes an ordering dependency between two schedulers that cannot see each other.

`AUTO_BACKUP_PAUSE_WITH_NO_PLAYERS` stays `0`. Setting it saves space but makes "newest" potentially stale during quiet periods, reintroducing the ambiguity we just removed.

Retention of 3 days at hourly is ~72 local tarballs; a Valheim world is tens of MB, comfortably inside 10Gi alongside the world.

### Jenkins side (this repo, mirroring KubicArk)

New files: `backup.Jenkinsfile`, `backup-server.sh`, `jobs.dsl`, `auth/{sa,role,rb}.yaml`.

Reuses the existing credentials — `utility-admin-kubeconfig-sa-token` and `jenkins-bucket-sa` — on a `kubectl && gcloud` agent, exactly as ARK does.

The script is substantially simpler than ARK's because odin has already produced a consistent archive. No `kubectl exec` + `find` + `tar` of a live world:

```
newest=$(kubectl exec deploy/valheim -n <ns> -- sh -c 'ls -t /home/steam/backups/*.tar.gz | head -1')
kubectl cp <ns>/<pod>:$newest ./<slug>-<ts>.tar.gz
gsutil cp ./<slug>-<ts>.tar.gz gs://kubic-game-hosting/valheim/<slug>/<ts>/
```

Bucket layout mirrors ARK's `gs://kubic-game-hosting/ark/<server>/<ts>/`, using `valheim/` as the sibling prefix.

Jobs are generated per instance by `jobs.dsl` under `KubicGameHosting/Valheim/<slug>/backup`, **with a nightly `triggers { cron(...) }`** — ARK's jobs are manual today, so this adds scheduling rather than copying it.

### The slug

One identifier per instance drives everything that is **not** namespaced: the overlay directory, the namespace, node ports, the GCP firewall rule name, the GCS path, and the Jenkins job path. In-namespace resource names (`valheim-data`, `valheim`, `valheim-secrets`) stay generic — they are namespaced and do not collide, and renaming valheim7's PVC would orphan the existing claim and delete Jotunheim with it, since `standard-rwo` has `reclaimPolicy: Delete`.

`scripts/start-server.sh` already implements this convention for generated overlays. The hand-written `event` overlay deviated from it and is renamed to `valheim7` — a repo-only change, since the namespace is declared inside the kustomization.

valheim7 keeps namespace `kubicvalheim`, grandfathered. Whether instances get one namespace each is a Phase-3/tafl architectural decision, not something to force now; the expectation is that valheim7 is eventually **restored into** its Phase-3 home from a bucket file rather than migrated in place.

### Restore

Documented, and exercised on the test instance before it is trusted:

1. `kubectl scale deploy/valheim --replicas=0` (releases the RWO volumes)
2. `gsutil cp` the chosen tarball down
3. Extract onto the world PVC via a throwaway pod mounting `valheim-data`
4. `kubectl scale deploy/valheim --replicas=1`

A restore that silently produces a *fresh* world looks identical to success from the outside, so validation must confirm a specific known object placed before the backup — not merely that the server started.

## C. Observability for valheim7

Most of this already exists and is simply not switched on: the overlay does not include `components/observability`. Adding it yields the ServiceMonitor and the Grafana dashboard (`uid: kubicvalheim`, already carrying *Server Up* and *Players Online*).

**This is decoupled from everything above.** ServiceMonitor, dashboard ConfigMap, and PrometheusRule are all separate objects — no pod-spec change, so this can land on valheim7 with zero downtime, independent of the migration window.

Two additions:

- **Request/limit reference lines** on the CPU and memory panels, from `kube_pod_container_resource_requests` / `_limits`. Note the asymmetry: memory has request 4Gi and limit 8Gi, but CPU has a request (500m) and **no limit**, so there is no "max" line to draw for CPU unless one is added.
- **A new `PrometheusRule`**, labelled `watched: "true"`:

```
ValheimDown       max by (namespace) (
                     (kube_deployment_status_replicas_available{deployment="valheim"} == 0)
                     or (up{service="valheim-metrics", endpoint="huginn"} == 0)
                   )                                                           for: 3m   severity: critical
ValheimNotOnline  valheim_online == 0                                          for: 5m   severity: warning
```

Both are needed. `up{..., endpoint="huginn"} == 0` catches a dead or unreachable pod; `valheim_online == 0` catches the container being alive while the game itself is not — a state the pod-level alerts are blind to.

**`max by (namespace) (...)` wraps both arms of `ValheimDown` deliberately.** During a real outage both arms are typically true at once, but they come from different metrics with different label sets — `kube_deployment_status_replicas_available` carries kube-state-metrics' labels, `up` carries the ServiceMonitor's target labels — so without the wrapper, `or` between them produces two distinct series (and thus two alerts, and two pages) for one outage. `max by (namespace)` collapses that down to exactly one series per namespace; the surviving series still carries `namespace`, which is what the annotations reference, and `severity`/`watched` still come from the rule's `labels:` block, unaffected by the aggregation.

The `up` expression is scoped to `endpoint="huginn"` deliberately: `valheim-metrics` exposes **two** ports (huginn's game-status endpoint and the backup-exporter's), so a bare `up{service="valheim-metrics"}` yields two series, and the backup-exporter's busybox `httpd` daemonizing while PID 1 stays a `sleep` loop means httpd dying leaves the container Running with `up{endpoint="backups"}=0` while the game is perfectly healthy — without the scope that pages `ValheimDown` for a backup-visibility problem, not a player-facing one. The `backups` endpoint gets its own warning alert, `ValheimBackupExporterDown`, in `components/observability-backups`.

**`absent()` is not used here**, even though it would seem to cover "the target disappeared from service discovery entirely." `absent()` is global: expressions in this rule deliberately carry no namespace pin (§C above / one rule covers every instance, each firing alert keeps its own `namespace` label, Alertmanager dedupes), and a global `absent(up{...})` would resolve false as soon as *any* instance is up — masking a genuinely down instance elsewhere. Multi-instance safety requires a per-instance signal instead. That signal is `kube_deployment_status_replicas_available{deployment="valheim"} == 0`: a kube-state-metrics series keyed on the Deployment object itself, which still exists (and reports 0 available) even when the pod — and with it the `huginn` scrape target — has vanished from service discovery entirely on a scale-to-zero. `up == 0` alone cannot see that case, since the series stops existing rather than going to 0; the deployment-availability arm is what closes it without reintroducing a global `absent()`.

No Alertmanager change is required. The deployed config already routes `watched = "true"` to the `ntfy-watched` receiver with `repeat_interval: 1h`, pushing to the `heimdall-watched` ntfy topic — a purpose-built escape hatch for exactly this.

> **2026-08-25 update:** this section predates the published-IP drift alert (added
> as a post-design addition — see the note near the end of the companion plan doc).
> That alert was originally built against `externalTrafficPolicy: Local`, joining
> the published IP to whichever node the pod was currently on. The Service has
> since moved to `externalTrafficPolicy: Cluster` — any node answers, so the pod's
> node is no longer load-bearing — and the alert was simplified to a plain
> `absent()` on the published address. See the plan doc's Step 3b / Step 2c notes
> and `kustomize/overlays/valheim7/prometheusrule-ip.yaml` for the current state.

## D. heimdall dependency

The `PrometheusRule` above cannot be discovered as written, because heimdall's Prometheus sets:

```
ruleSelector: {"matchLabels": {"release": "heimdall-hzx5s-kube-prometheus"}}
```

`hzx5s` is the **random per-cluster composite suffix**. A rule shipped from another repository cannot know it at author time.

heimdall#11 already fixed this class of bug for `serviceMonitorSelector`, `podMonitorSelector`, and `probeSelector` via `…NilUsesHelmValues: false`. `ruleSelector` is the only one still at the chart default. heimdall's own composition works around it by generating the label from the composite name — an option external repos do not have.

The 2026-07-27 alerting design states the principle explicitly for probes: *"a probe is meant to be a file someone writes without consulting the cluster."* Rules are no different.

**Fix:** add `ruleSelectorNilUsesHelmValues: false` to `crossplane/composition.yaml`, completing the set. heimdall's own self-health rules are unaffected — they carry the label, and an empty selector is a superset.

**Prerequisite, now satisfied.** An empty `ruleSelector` sweeps in *every* PrometheusRule cluster-wide. Before this work there was a 577-day-old orphan, `cnpg/tera-cnpg-cluster-alert-rules`, defining ten alerts including `CNPGClusterZoneSpreadWarning` — which would have fired permanently on this single-zone cluster and paged via `ntfy-info` every four hours. That namespace was a `bootstrappedtestdb` experiment with no consumers and no GitOps owner; it was deleted on 2026-08-23, reclaiming 24Gi and ~150m CPU / 1.5Gi of requests. Only heimdall's own labelled rules remain, so the empty selector is now clean.

Any future stray PrometheusRule will be picked up automatically — that is the intended behaviour, but it is a standing consequence worth knowing.

## E. Test plan

All of this is proven on a **new throwaway instance**; valheim7 is load-bearing and is not touched until the test passes.

```
scripts/start-server.sh testbed 32466 Testbed
  -> ns valheim-testbed, ports 32466/32467
  -> firewall rule kubicvalheim-testbed udp:32466-32467
```

| # | Check | Pass condition |
|---|---|---|
| 1 | First boot | Full download, world generated |
| 2 | **Restart** | **No 1.76GB download** — game PVC populated; boot is seconds, not ~4 min |
| 3 | odin backup | Tarball appears in `/home/steam/backups` on the `valheim-backups` PVC |
| 4 | Backup survives restart | Tarballs still present after pod recreate |
| 5 | Jenkins job | Object lands at `gs://kubic-game-hosting/valheim/testbed/<ts>/` |
| 6 | Alerting | Scale to 0 → `ValheimDown` fires → ntfy push arrives on phone |
| 7 | Dashboard | Grafana shows Up, players, CPU/mem vs request/limit |
| 8 | **Restore** | Cervator joins, places a known object, backs up, wipes, restores, and confirms **that object** is present |

Step 2 is the one that justifies the new PVC, and step 8 is the one that justifies the whole backup story. Cervator performs the in-game placement and restore validation.

## F. Rollout to valheim7

Ordering, once the test instance passes:

1. **Observability first** — zero downtime, no pod restart. Gets alerting live immediately.
2. Cervator takes a **GCP volume snapshot** of `valheim-data`.
3. One migration restart applies the game PVC, the backups mount, `AUTO_BACKUP`, and `Recreate`. Costs one final ~4-minute full download.
4. Jenkins job enabled for the `valheim7` slug.

After step 3, restarts drop to seconds and nightly off-cluster backups are running — before the event, as agreed.

## Out of scope

- The S3-endpoint-agnostic CronJob (Phase 3).
- Namespace-per-instance as an architectural rule (Phase 3 / tafl).
- Restoring the legacy `valheim` namespace servers — separate, and Cervator's to do (replica 0 → 1).
- A shared KubicGameHosting Kustomize parent; that repo is currently legacy NFS/load-balancer material with no shared home yet.
