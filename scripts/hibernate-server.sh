#!/usr/bin/env bash
# Put a Valheim instance into hibernation: back it up, verify, then scale to 0.
#
# Usage: hibernate-server.sh <slug> [namespace]
#   <slug>       instance id; also names the GCS path the backup lands in
#   [namespace]  defaults to valheim-<slug>; valheim7 lives in `kubicvalheim`
#
# Env:
#   KUBE_CONTEXT  kubectl context to target. Same reasoning as backup-server.sh —
#                 pin it anywhere a workstation is involved.
#   SKIP_BACKUP   set to 1 to scale down WITHOUT backing up first. See below.
#
# Exit codes (hibernate.Jenkinsfile depends on these — keep them in sync):
#   0  hibernated
#   2  already hibernated; nothing to do, and that is correct -> UNSTABLE
#   1  anything actually wrong, INCLUDING the pre-hibernation backup failing
#
# WHY THIS EXISTS AS A SCRIPT AND NOT A RUNBOOK STEP
#
# The ordering is the whole point, and it is not the intuitive one:
# backup-server.sh needs a RUNNING POD to copy the archive from, so the upload
# cannot happen after the scale-down. Written as prose in docs/backups.md, that
# constraint is one someone discovers by getting it wrong. Here it is the only
# order available.
#
# SKIP_BACKUP=1 exists for the "I need this down now" case — a misbehaving
# server, an urgent node drain. It is deliberately an env var rather than a
# positional argument so it cannot be passed by accident, and the run says
# loudly which mode it took. What it does NOT do is change the resulting cluster
# state: a server stopped in a hurry and a server hibernated properly are both
# `spec.replicas: 0` and indistinguishable afterwards. The difference lives in
# whether a fresh archive reached GCS, which is exactly why the default backs up.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
if [ -n "$KUBE_CONTEXT" ]; then
  kctl() { kubectl --context "$KUBE_CONTEXT" "$@"; }
else
  KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "$KUBE_CONTEXT" ]; then
    echo "ERROR: no kubectl context set and KUBE_CONTEXT unset" >&2
    exit 1
  fi
  kctl() { kubectl "$@"; }
fi
echo "Targeting kubectl context: ${KUBE_CONTEXT}"

slug="${1:?usage: hibernate-server.sh <slug> [namespace]}"
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#slug} > 55 )); then
  echo "ERROR: <slug> must be <=55 chars so the namespace valheim-<slug> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi
ns="${2:-valheim-${slug}}"

# Same reservation as backup-server.sh: exit 2 means "already in the desired
# state", never "something broke". Normalize everything else to 1 — `kubectl
# exec` propagates the REMOTE status and gcloud uses 2 for usage errors, so an
# unguarded failure could otherwise be read as an idempotent no-op.
dormant=0
finish() {
  rc=$?
  if [ "$rc" -eq 0 ]; then exit 0; fi
  if [ "$dormant" -eq 1 ]; then exit 2; fi
  exit 1
}
trap finish EXIT

if ! spec_replicas="$(kctl get deployment valheim -n "$ns" --ignore-not-found -o jsonpath='{.spec.replicas}' 2>&1)"; then
  echo "ERROR: could not query deployment/valheim in ${ns} — the API call failed:" >&2
  echo "  ${spec_replicas}" >&2
  exit 1
fi
if [ -z "$spec_replicas" ]; then
  echo "ERROR: no deployment/valheim in namespace ${ns} — wrong namespace, or the instance is gone." >&2
  exit 1
fi
if [ "$spec_replicas" -eq 0 ]; then
  dormant=1
  echo "ALREADY HIBERNATED: deployment/valheim in ${ns} is at spec.replicas=0."
  echo "  Nothing to do. Its last upload remains the current off-cluster copy."
  exit 2
fi

# Players first. Hibernating a server with someone on it drops them mid-session,
# and the count is free to check — the exporter is already scraped for it.
connected="$(kctl exec -n "$ns" "$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | cut -d' ' -f1)" -c valheim-server -- sh -c 'grep -o "Connections [0-9]*" /home/steam/valheim_server.log 2>/dev/null | tail -1 | grep -o "[0-9]*"' 2>/dev/null || true)"
if [ -n "$connected" ] && [ "$connected" != "0" ]; then
  echo "WARNING: the server log reports ${connected} connection(s) at last count." >&2
  echo "  Hibernating now will disconnect them. Continuing — this is a deliberate action." >&2
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ "${SKIP_BACKUP:-0}" = "1" ]; then
  echo "SKIP_BACKUP=1 — scaling down WITHOUT a fresh off-cluster backup."
  echo "  The newest archive in GCS is whatever the last successful run uploaded."
else
  echo "=== Backing up before hibernation (the upload needs a running pod) ==="

  # Take a FRESH archive first, rather than uploading whatever odin's hourly
  # schedule last happened to write.
  #
  # Two reasons, and the second one is why this is not optional:
  #
  #  1. A hibernation backup should capture the world as it is NOW. Shipping an
  #     archive up to an hour old means an hour of play is protected only by the
  #     shutdown tarball, which cannot be uploaded.
  #
  #  2. Without it, wake-then-hibernate DEADLOCKS. backup-server.sh refuses any
  #     tarball older than 3h, and immediately after a wake the newest one on the
  #     PVC is the shutdown archive from the previous hibernation — already
  #     hours old. Observed exactly that: "newest backup is 10878s old (limit
  #     10800s)", so hibernate refused to scale down and the only ways forward
  #     were to wait for odin's next hourly or to skip the backup entirely.
  #     Neither is a reasonable answer to "put this server to sleep".
  #
  # Same output directory and .tar.gz shape odin's own scheduler uses, so
  # backup-server.sh picks it up as the newest archive by mtime and the existing
  # integrity and staleness guards still apply to it unchanged.
  pod="$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | cut -d' ' -f1)"
  if [ -z "$pod" ]; then
    echo "ERROR: no pod with label app=valheim in ${ns}, but spec.replicas=${spec_replicas}." >&2
    exit 1
  fi
  fresh="/home/steam/backups/$(date +%Y%m%d-%H%M%S)-hibernate.tar.gz"
  echo "Asking odin for a fresh archive: ${fresh}"
  if ! kctl exec -n "$ns" "$pod" -c valheim-server -- \
       odin backup /home/steam/.config/unity3d/IronGate/Valheim "$fresh"; then
    echo "ERROR: odin backup failed — NOT scaling down." >&2
    exit 1
  fi

  # Deliberately NOT reimplemented here. backup-server.sh owns the staleness
  # guard, the tar integrity check and the upload marker; a second copy of that
  # logic would drift and the drift would be silent.
  if ! "$ROOT/backup-server.sh" "$slug" "$ns"; then
    echo "ERROR: pre-hibernation backup failed — NOT scaling down." >&2
    echo "  Hibernating now would park the server with a stale off-cluster copy." >&2
    echo "  Fix the backup, or pass SKIP_BACKUP=1 if you accept that knowingly." >&2
    exit 1
  fi
  echo "=== Backup complete ==="
fi

echo "Scaling deployment/valheim to 0 in ${ns}..."
kctl scale deployment valheim -n "$ns" --replicas=0
kctl wait pod -l app=valheim -n "$ns" --for=delete --timeout=180s
echo "HIBERNATED: ${ns} is at spec.replicas=0."
echo "  AUTO_BACKUP_ON_SHUTDOWN wrote one final local tarball to the backups PVC on"
echo "  the way down. That one cannot be uploaded — there is no pod left to copy it"
echo "  from — and waits for the next Velero snapshot of that PVC."
echo "  Scheduled backups will now report UNSTABLE until the server is woken."
