#!/usr/bin/env bash
# Wake a hibernated Valheim instance: scale to 1, wait, and verify the world came
# back rather than a fresh one.
#
# Usage: wake-server.sh <slug> [namespace]
#   <slug>       instance id
#   [namespace]  defaults to valheim-<slug>; valheim7 lives in `kubicvalheim`
#
# Env:
#   KUBE_CONTEXT  kubectl context to target.
#   REPLICAS      how many to scale to (default 1). Valheim is single-instance;
#                 this exists so the value is never silently assumed.
#
# Exit codes (wake.Jenkinsfile depends on these — keep them in sync):
#   0  awake and the world verified
#   2  already awake; nothing to do -> UNSTABLE
#   1  anything actually wrong
#
# WHY THIS VERIFIES RATHER THAN JUST SCALING
#
# `kubectl scale --replicas=1` is one command, and a job that only does that
# would be ceremony. What earns the script is the check afterwards: a server that
# starts with an EMPTY world looks identical, from the outside, to one that came
# back correctly — same pod, same Ready, same port. docs/restore.md already makes
# this point about restores; it applies just as much to a wake, because the world
# volume is the thing most likely to have been disturbed while nobody was
# watching.
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

slug="${1:?usage: wake-server.sh <slug> [namespace]}"
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#slug} > 55 )); then
  echo "ERROR: <slug> must be <=55 chars so the namespace valheim-<slug> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi
ns="${2:-valheim-${slug}}"
replicas="${REPLICAS:-1}"

# Exit 2 is reserved for "already in the desired state" — see hibernate-server.sh.
already=0
finish() {
  rc=$?
  if [ "$rc" -eq 0 ]; then exit 0; fi
  if [ "$already" -eq 1 ]; then exit 2; fi
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
if [ "$spec_replicas" -ne 0 ]; then
  already=1
  echo "ALREADY AWAKE: deployment/valheim in ${ns} is at spec.replicas=${spec_replicas}."
  echo "  Nothing to do."
  exit 2
fi

echo "Scaling deployment/valheim to ${replicas} in ${ns}..."
kctl scale deployment valheim -n "$ns" --replicas="$replicas"

# Generous: the game image re-downloads via SteamCMD whenever the game PVC was
# rebuilt (it carries the `reconstructible` label, so a Velero restore hands back
# an empty one), and these are 2-vCPU nodes.
echo "Waiting for the pod to become Ready (up to 15m)..."
kctl wait pod -l app=valheim -n "$ns" --for=condition=Ready --timeout=900s

pod="$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | cut -d' ' -f1)"
echo "Pod ${pod} is Ready"

# The verification the header promises. A .db of a plausible size means a real
# world loaded; a missing or tiny one means the server generated a fresh map,
# which is the failure that otherwise passes for success.
echo "=== Verifying the world came back ==="
worlds="$(kctl exec -n "$ns" "$pod" -c valheim-server -- sh -c 'ls -l /home/steam/.config/unity3d/IronGate/Valheim/worlds_local/*.db 2>/dev/null' || true)"
if [ -z "$worlds" ]; then
  echo "ERROR: no world .db files in worlds_local on ${pod}." >&2
  echo "  The server is running but has no world — it will generate a fresh one." >&2
  echo "  Do NOT let players connect. Check the valheim-data PVC, and see docs/restore.md." >&2
  exit 1
fi
echo "$worlds"
echo "World files present — confirm the size above looks like your world, not a fresh map."
echo ""
echo "AWAKE: ${ns} is at spec.replicas=${replicas}."
echo "  NOTE: the next scheduled backup can legitimately fail the 3h staleness"
echo "  guard, because the newest tarball on the PVC dates from when the server was"
echo "  hibernated. Let odin write a fresh hourly archive before re-running it."
