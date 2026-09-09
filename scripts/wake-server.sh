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
#   0  scaled up, and the world verified
#   2  was already awake AND the world verified; nothing to do -> UNSTABLE
#   1  anything actually wrong, INCLUDING an already-awake instance whose world
#      failed verification — that is a broken server, not a no-op
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
#
# `already` is deliberately set only at the very END, once the instance has been
# verified. Setting it up front and falling through would make the EXIT trap
# convert a genuine verification failure into exit 2 — reporting a broken server
# as "nothing to do", the exact confusion this script exists to prevent.
already=0
was_awake=0
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
# A nonzero replica count is NOT sufficient to call this done. A previous wake
# that scaled up and then failed — or was interrupted — leaves exactly this
# state, so short-circuiting here would report a half-woken or worldless
# instance as "already awake, nothing to do". Skip the scale, but still run the
# readiness wait and the world verification below.
if [ "$spec_replicas" -ne 0 ]; then
  was_awake=1
  echo "Already at spec.replicas=${spec_replicas} in ${ns} — not scaling."
  echo "  Verifying it is genuinely healthy rather than assuming it is."
else
  echo "Scaling deployment/valheim to ${replicas} in ${ns}..."
  kctl scale deployment valheim -n "$ns" --replicas="$replicas"
fi

# Generous: the game image re-downloads via SteamCMD whenever the game PVC was
# rebuilt (it carries the `reconstructible` label, so a Velero restore hands back
# an empty one), and these are 2-vCPU nodes.
echo "Waiting for the pod to become Ready (up to 15m)..."
kctl wait pod -l app=valheim -n "$ns" --for=condition=Ready --timeout=900s

pod="$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | cut -d' ' -f1)"
echo "Pod ${pod} is Ready"

# The verification the header promises. Checking for ANY *.db would accept a
# freshly generated world — the precise failure this is meant to catch — so
# assert on the world this instance is configured to serve, by name.
#
# WORLD comes from the pod's own environment rather than a job parameter: it is
# the value the server process actually booted with, so it cannot disagree with
# reality the way a separately-maintained parameter can. It also keeps the wake
# job's parameter list honest — nothing to mis-type.
echo "=== Verifying the world came back ==="
if ! world="$(kctl exec -n "$ns" "$pod" -c valheim-server -- printenv WORLD)" || [ -z "$world" ]; then
  echo "ERROR: could not read WORLD from ${pod}." >&2
  echo "  Without it there is no way to tell this instance's world from a fresh one." >&2
  exit 1
fi
echo "Configured world: ${world}"

# Same assertion restore-server.sh makes after extracting an archive: both files
# present AND non-empty. `.fwl` carries the seed and `.db` the world itself; a
# zero-byte either way is a world that will not load.
worlds_dir=/home/steam/.config/unity3d/IronGate/Valheim/worlds_local
if ! kctl exec -n "$ns" "$pod" -c valheim-server -- sh -c "test -s '${worlds_dir}/${world}.db'"; then
  echo "ERROR: ${world}.db is missing or empty in worlds_local on ${pod}." >&2
  echo "  The server is running but has no world — it will generate a fresh one." >&2
  echo "  Do NOT let players connect. Check the valheim-data PVC, and see docs/restore.md." >&2
  exit 1
fi
if ! kctl exec -n "$ns" "$pod" -c valheim-server -- sh -c "test -s '${worlds_dir}/${world}.fwl'"; then
  echo "ERROR: ${world}.fwl is missing or empty in worlds_local on ${pod}." >&2
  echo "  The world seed is gone; loading this would not give you your map back." >&2
  echo "  Do NOT let players connect. See docs/restore.md." >&2
  exit 1
fi
kctl exec -n "$ns" "$pod" -c valheim-server -- ls -l "${worlds_dir}/${world}.db" "${worlds_dir}/${world}.fwl"
echo "Verified: ${world}.db and ${world}.fwl both present and non-empty."

# Only now that the instance is verified is "nothing to do" a truthful answer.
if [ "$was_awake" -eq 1 ]; then
  already=1
  echo ""
  echo "ALREADY AWAKE: ${ns} was already at spec.replicas=${spec_replicas}, and its world verified."
  echo "  Nothing to do."
  exit 2
fi

echo ""
echo "AWAKE: ${ns} is at spec.replicas=${replicas}."
echo "  NOTE: the next scheduled backup can legitimately fail the 3h staleness"
echo "  guard, because the newest tarball on the PVC dates from when the server was"
echo "  hibernated. Let odin write a fresh hourly archive before re-running it."
