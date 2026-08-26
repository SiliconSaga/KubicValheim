#!/usr/bin/env bash
# Restore a Valheim world from a GCS backup archive onto a LIVE instance.
#
# Usage: restore-server.sh <slug> <namespace> <world> <archive>
#   <slug>      instance id; validated the same way backup-server.sh validates it
#   <namespace> namespace holding the server
#   <world>     the WORLD this instance is configured with (see the overlay's
#               instance-patch.yaml, or the WORLD env var on the running pod) —
#               this is what step 4 below matches the archive against
#   <archive>   gs://... path OR the https://storage.googleapis.com/... URL
#               backup-server.sh prints, since the owner hands players that link
#
# Env:
#   KUBE_CONTEXT  kubectl context to target. REQUIRED when a workstation is
#                 involved — see the context guard below for why this one is not
#                 merely advisory like it is in backup-server.sh.
#
# DESTRUCTIVE: scales deployment/valheim to 0 and replaces worlds_local on the
# live PVC. Mirrors docs/restore.md — read that first if this needs changing.
# EVERY validation below (slug, world name, archive integrity, archive-vs-world
# match) runs and passes BEFORE anything is scaled down or touched, so a bad
# slug, an unreadable archive, or an archive from the wrong instance all abort
# with the live world completely intact.
set -euo pipefail

# Which cluster are we destroying a world on? kubectl defaults to whatever
# `current-context` happens to be. On a workstation that juggles k3d and GKE that
# is regularly NOT the cluster you mean — backup-server.sh silently queried a
# local k3d cluster and reported "no pod" for a server running fine on GKE. Here
# the same slip would scale down a deployment and `rm -rf` a worlds_local on the
# wrong cluster. KUBE_CONTEXT pins the target; unset, we resolve and print it so
# it is never silently inherited. Step 4b below turns this from "printed, hope
# someone reads it" into an actual guard.
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

slug="${1:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"
ns="${2:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"
world="${3:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"
archive_ref="${4:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"

# --- 1. Validate <slug>, exactly as backup-server.sh does ------------------
# Kept identical to backup-server.sh's checks. slug is a mutable Jenkins build
# parameter here too, and even though namespace is passed explicitly (unlike
# backup-server.sh's default-from-slug), slug still names the local workspace
# file below, so the same DNS-1123-label-ish discipline applies before any
# path is built from it.
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#slug} > 55 )); then
  echo "ERROR: <slug> must be <=55 chars so the namespace valheim-<slug> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi

# <world> only ever flows into literal grep -F patterns and log/echo text below
# — never into a path or command substitution — so it needs no shell-safety
# validation. This is the same printable-name allowlist start-server.sh enforces
# when it WRITES a world name; it just catches a typo'd/empty value early with a
# clear error instead of a confusing miss deep in step 4's grep.
world_re='^[A-Za-z0-9 _-]+$'
if [[ ! "$world" =~ $world_re ]]; then
  echo "ERROR: <world> may only contain letters, digits, spaces, hyphens, and underscores." >&2
  exit 1
fi

# --- Normalise the archive reference: accept either form -------------------
# backup-server.sh now prints both a gs:// path (for operators) and an
# https://storage.googleapis.com/... link (for players, since the bucket is
# public) — the owner wants to be able to hand either one back to this script.
# gsutil only understands gs://, so whichever form arrives is normalised once,
# up front, before anything else uses it.
case "$archive_ref" in
  https://storage.googleapis.com/*)
    gs_uri="gs://${archive_ref#https://storage.googleapis.com/}"
    ;;
  gs://*)
    gs_uri="$archive_ref"
    ;;
  *)
    echo "ERROR: <archive> must be a gs://... path or an https://storage.googleapis.com/... URL" >&2
    exit 1
    ;;
esac
echo "Archive: ${gs_uri}"

# Cleanup plumbing set up before anything is created, with the tracked
# variables pre-declared (set -u would otherwise choke on an unset var if the
# trap ran before a given step assigned it — e.g. a failure during download,
# before the listing files exist).
local_file=""
listing_raw=""
listing_norm=""
trap 'rm -f "$local_file" "$listing_raw" "$listing_norm"' EXIT

# --- 2. Download the archive to the workspace -------------------------------
local_file="$(basename "$gs_uri")"
gsutil cp "$gs_uri" "$local_file"
if [ ! -s "$local_file" ]; then
  echo "ERROR: downloaded file ${local_file} is empty." >&2
  exit 1
fi
# `wc -c`, not `stat -c %s` — this runs on the AGENT, and BSD stat (macOS) has no
# -c, so the GNU form prints "illegal option" and yields an empty size, which
# reads as a zero-byte download in an otherwise-successful log. See the matching
# note in backup-server.sh.
echo "Downloaded $(wc -c < "$local_file" | tr -d ' ') bytes to ${local_file}"

# --- 3. Validate it before touching anything --------------------------------
# `tar tzf` on its OWN line — never piped into anything else. A pipeline
# reports only the LAST command's exit status, which would silently swallow a
# tar failure. -e is suspended for exactly this one command so the exit status
# can be captured explicitly and checked, instead of relying on -e to abort
# invisibly.
listing_raw="${slug}-restore-listing-raw.txt"
listing_norm="${slug}-restore-listing.txt"
set +e
tar tzf "$local_file" > "$listing_raw"
tar_status=$?
set -e
echo "tar tzf exit status: ${tar_status}"
if [ "$tar_status" -ne 0 ]; then
  echo "ERROR: ${local_file} failed the 'tar tzf' integrity check (exit ${tar_status}) — corrupt or truncated. NOT touching the live world; pick a different backup." >&2
  exit 1
fi
echo "Integrity check passed (tar tzf)"

# --- 4. Confirm it is the RIGHT world ---------------------------------------
# Normalise a leading './' some tar implementations emit so a whole-line match
# still lands, then require the exact world files, literally and on the whole
# line. `-F` (literal, not regex) and `-x` (whole line) together are mandatory:
# a plain `grep -q` treats <world> as a REGEX and matches SUBSTRINGS, so a world
# named "World.1" would have its "." match any character and match as a
# substring of "WorldX1.db" from a different server's archive — and step 6
# would then delete the live world under a false positive.
sed 's#^\./##' "$listing_raw" > "$listing_norm"
if ! grep -Fqx -- "worlds_local/${world}.db" "$listing_norm"; then
  echo "ERROR: archive does not contain worlds_local/${world}.db — this is the WRONG archive for world '${world}'. NOT touching the live world." >&2
  exit 1
fi
if ! grep -Fqx -- "worlds_local/${world}.fwl" "$listing_norm"; then
  echo "ERROR: archive does not contain worlds_local/${world}.fwl — this is the WRONG archive for world '${world}'. NOT touching the live world." >&2
  exit 1
fi
echo "World match confirmed: worlds_local/${world}.db and .fwl both present in archive"

# --- 4b. Confirm the LIVE instance is the one we think it is ---------------
# Everything above validated the ARCHIVE. Nothing yet has checked that the
# cluster/namespace we are pointed at actually holds this instance — and the
# context we resolved above may simply be wrong. Reading WORLD off the live
# Deployment closes that gap: on the wrong cluster the Deployment is absent, and
# on the wrong namespace (or a namespace that was recycled for a different
# instance) WORLD won't match. Both abort here, while the live world is still
# untouched. Without this, a stale kubectl context plus a valid archive is
# sufficient to destroy an unrelated server's save.
live_world="$(kctl get deployment valheim -n "$ns" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="valheim-server")].env[?(@.name=="WORLD")].value}' 2>/dev/null || true)"
if [ -z "$live_world" ]; then
  echo "ERROR: no deployment/valheim with a WORLD env in namespace '${ns}' on context '${KUBE_CONTEXT}'." >&2
  echo "  Wrong cluster or wrong namespace — refusing to restore. Nothing was touched." >&2
  exit 1
fi
if [ "$live_world" != "$world" ]; then
  echo "ERROR: live instance in '${ns}' is running world '${live_world}', but this restore targets '${world}'." >&2
  echo "  Refusing to overwrite a different server's world. Nothing was touched." >&2
  exit 1
fi
echo "Live instance confirmed: ${ns} on ${KUBE_CONTEXT} is running world '${live_world}'"

# --- 5. Scale the deployment to 0 and wait for the pod to be gone ----------
# Releases the RWO volumes so the helper pod below can mount them. Everything
# above this line is read-only against the cluster — this is the first step
# that touches the live instance, and only validated input reaches it.
echo "Scaling deployment/valheim to 0 in ${ns}..."
kctl scale deployment valheim -n "$ns" --replicas=0
kctl wait pod -l app=valheim -n "$ns" --for=delete --timeout=180s
echo "Pod gone — volumes released"

# --- 6. Helper pod: last look, remove worlds_local, extract, delete --------
helper="restore-helper"
# Pod deletion isn't the same as the volume actually detaching, so a leftover
# helper from a prior failed attempt is removed first rather than assumed gone.
kctl delete pod "$helper" -n "$ns" --ignore-not-found --wait=true

kctl run "$helper" -n "$ns" --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"restore-helper","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"world","mountPath":"/world"}]}],"volumes":[{"name":"world","persistentVolumeClaim":{"claimName":"valheim-data"}}]}}'
# If this Ready wait times out, the previous attachment is probably still
# releasing (see docs/restore.md) — rerun the job rather than assuming the
# restore itself has failed; nothing destructive has happened yet.
kctl wait pod "$helper" -n "$ns" --for=condition=Ready --timeout=120s

kctl cp "$local_file" "${ns}/${helper}:/tmp/restore.tar.gz"

echo "Existing world on the PVC, last look before removal:"
kctl exec "$helper" -n "$ns" -- ls -la /world/worlds_local

kctl exec "$helper" -n "$ns" -- rm -rf /world/worlds_local
kctl exec "$helper" -n "$ns" -- tar xzf /tmp/restore.tar.gz -C /world

kctl delete pod "$helper" -n "$ns"
echo "Helper pod cleaned up"

# --- 7. Scale back to 1 ------------------------------------------------------
kctl scale deployment valheim -n "$ns" --replicas=1
echo "Scaled deployment/valheim back to 1 in ${ns}"

# --- 8. How to verify — the step that actually matters -----------------------
# A restore that silently produces a FRESH world looks identical to success
# from outside unless someone checks for exactly this.
cat <<EOF

Restore submitted. Verify it actually took:

  kubectl --context ${KUBE_CONTEXT} logs deployment/valheim -n ${ns} --tail=50

The log should show:  Load world: ${world}
with NO following:    ... missing .../${world}.db ...
That "missing" line means Valheim generated a brand-new empty world instead of
loading the restored one — if you see it, the restore did not take.

Then join the server and confirm a known object placed before the backup is
actually there.
EOF
