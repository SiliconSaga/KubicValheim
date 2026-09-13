#!/usr/bin/env bash
# Upgrade a running Valheim instance to the current Steam build, and prove it
# came back with its world.
#
# Usage: upgrade-server.sh <slug> [namespace]
#   <slug>       instance id
#   [namespace]  defaults to valheim-<slug>; valheim7 lives in `kubicvalheim`
#
# Env:
#   KUBE_CONTEXT  kubectl context to target.
#
# Exit codes (upgrade.Jenkinsfile depends on these — keep them in sync):
#   0  restarted, came back Ready, and the world verified
#   2  instance is hibernated; nothing to upgrade -> UNSTABLE
#   1  anything actually wrong
#
# WHY THIS EXISTS RATHER THAN "DELETE THE POD AND WAIT"
#
# odin updates from Steam on every start (UPDATE_ON_STARTUP=1), so deleting the
# pod IS the upgrade. What it never gave you is an answer: the pod goes away, a
# new one appears, and whether the server came back on the new build with the
# right world is something you find out from players. Two things make that worse
# than it sounds — a stuck SteamCMD update crashloops rather than failing once
# (docs/steam-updates.md), and a server that comes up on a FRESH world looks
# identical from the outside to one that came back correctly.
#
# This is deliberately thin. It restarts, waits, and verifies. It does not clear
# Steam state or run a rescue pod: image 3.7.1+ resets a stuck download itself
# and retries, so a recovery path here would be a second implementation of
# something the container already does. When the container's own recovery is not
# enough, that is a human-shaped problem — see docs/steam-updates.md.
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

slug="${1:?usage: upgrade-server.sh <slug> [namespace]}"
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#slug} > 55 )); then
  echo "ERROR: <slug> must be <=55 chars so the namespace valheim-<slug> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi
ns="${2:-valheim-${slug}}"

# Exit 2 is reserved for "already in the desired state" across this script
# family — here that means hibernated, since a server that is off has no build
# to move. Set only where exiting 2 is correct, never up front: the EXIT trap
# would otherwise rewrite a genuine failure into a no-op. Same reasoning as
# wake-server.sh.
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

# A hibernated instance is not a failure and is not an upgrade. It will pick up
# whatever Steam has current the next time wake-server.sh starts it, so forcing
# it awake here would be this job deciding, on its own, that a server someone
# deliberately parked should be running again.
if [ "$spec_replicas" -eq 0 ]; then
  dormant=1
  echo "HIBERNATED: deployment/valheim in ${ns} is at spec.replicas=0."
  echo "  Nothing to upgrade — it will update on its own when woken."
  exit 2
fi

echo "Restarting deployment/valheim in ${ns} to pick up the current Steam build..."
kctl rollout restart deployment valheim -n "$ns"

# Generous for the same reason wake-server.sh is: this is the step that may
# download a whole new build on a 2-vCPU node, and a big release is exactly when
# Steam is slowest.
echo "Waiting for the rollout to complete (up to 20m)..."
if ! kctl rollout status deployment valheim -n "$ns" --timeout=1200s; then
  echo "" >&2
  echo "ERROR: the rollout did not complete for ${ns}." >&2
  # Control flow keys off the rollout, not off log text — readiness is
  # structured state the API reports, whereas a log signature is a string that
  # changes when upstream rewords it. The log is still worth SHOWING, because
  # the one failure an operator most needs to recognise has a runbook.
  echo "  Container exit code and recent log tail follow, to say which failure this is." >&2
  kctl get pods -n "$ns" -l app=valheim \
    -o jsonpath='{range .items[*]}{.metadata.name}{" restarts="}{.status.containerStatuses[?(@.name=="valheim-server")].restartCount}{" lastExit="}{.status.containerStatuses[?(@.name=="valheim-server")].lastState.terminated.exitCode}{"\n"}{end}' >&2 || true
  kctl logs -n "$ns" -l app=valheim -c valheim-server --tail=40 >&2 2>/dev/null || true
  echo "" >&2
  echo "  If that tail shows \"state is 0x6 after update job\" repeating, this is a stuck" >&2
  echo "  Steam update rather than a bad build. Image 3.7.1+ clears that itself; if it" >&2
  echo "  still cannot, follow docs/steam-updates.md." >&2
  exit 1
fi

# Hand the wait-and-verify to wake-server.sh instead of repeating it. The
# deployment is already at >=1 replica here, so wake skips its scale, waits for
# Ready, and asserts the configured world's .db and .fwl are present and
# non-empty — the same check, maintained in one place.
#
# EXIT 2 IS THE SUCCESS CASE, not a surprise. wake reserves 2 for "it was
# already awake AND its world verified", which after a restart is precisely what
# a good upgrade looks like. A world that fails verification exits 1 there and
# stays 1 here.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +e
"$script_dir/wake-server.sh" "$slug" "$ns"
wake_rc=$?
set -e
case "$wake_rc" in
  0|2) : ;;
  *)
    echo "ERROR: the instance came back but did not verify — see the wake output above." >&2
    exit 1
    ;;
esac

# The banner is the only line that names the version players are matched
# against, so it is worth surfacing rather than leaving in the log.
pod="$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | cut -d' ' -f1)"
version_line="$(kctl logs -n "$ns" "$pod" -c valheim-server --tail=400 2>/dev/null \
  | grep -o 'Console: Valheim [^ ]* (network version [0-9]*)' | tail -1 || true)"

echo ""
echo "UPGRADED: ${ns} restarted, came back Ready, and its world verified."
if [ -n "$version_line" ]; then
  echo "  ${version_line}"
else
  echo "  NOTE: could not read the version banner from the log — the server is up and"
  echo "  verified regardless, but confirm the build before telling players to reconnect."
fi
