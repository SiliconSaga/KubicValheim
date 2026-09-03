#!/usr/bin/env bash
# Upload the newest odin-produced backup tarball to GCS.
#
# Usage: backup-server.sh <slug> [namespace]
#   <slug>       instance id; names the GCS path
#   [namespace]  defaults to valheim-<slug>; valheim7 lives in `kubicvalheim`
#
# Env:
#   KUBE_CONTEXT  kubectl context to target. Optional in Jenkins (one context on
#                 the agent), but strongly recommended anywhere a workstation is
#                 involved — see the context note below.
#
# Exit codes (backup.Jenkinsfile depends on these — keep them in sync):
#   0  backup uploaded
#   2  instance is DORMANT (spec.replicas == 0); nothing to do, and that is
#      correct. Jenkins maps this to UNSTABLE, not FAILURE.
#   1  anything actually wrong
#
# odin (AUTO_BACKUP) already produced a consistent archive hourly, so unlike the
# KubicArk equivalent this does NOT exec a tar over a live world.
set -euo pipefail

# Which cluster are we talking to? Left implicit, kubectl uses whatever
# `current-context` happens to be, which on a workstation juggling k3d and GKE is
# routinely the wrong one — this script silently ran against a local k3d cluster
# and reported "no pod" for a server that was running fine on GKE. That is the
# benign half of the failure; restore-server.sh shares this code path and deletes
# a world, so the same slip there destroys the wrong cluster's save.
# KUBE_CONTEXT pins it. Unset, we resolve and PRINT the context rather than
# silently inheriting it, so the target is always visible in the log.
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

slug="${1:?usage: backup-server.sh <slug> [namespace]}"

# slug is a mutable Jenkins build parameter and is interpolated straight into a
# local filename and a gs:// path below, so it is validated BEFORE ns or any path
# is built. Same DNS-1123-label-ish convention scripts/start-server.sh already
# uses for its <name> argument: lowercase alphanumerics and '-', start/end
# alphanumeric — which as a side effect also rejects '/', '..', and a leading '-'.
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
# Same bound scripts/start-server.sh enforces on <name>, for the same reason: the
# default namespace below is valheim-<slug>, so an overly long slug would exceed
# Kubernetes' 63-char namespace limit. Checking it here gives a clear error
# instead of a confusing failure later against the API.
if (( ${#slug} > 55 )); then
  echo "ERROR: <slug> must be <=55 chars so the namespace valheim-<slug> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi

ns="${2:-valheim-${slug}}"
bucket="gs://kubic-game-hosting/valheim"
# A tarball older than this means odin's hourly schedule is not running. Uploading
# it anyway would look like success while shipping a stale world — the exact silent
# failure this design exists to avoid.
max_age_seconds=10800   # 3h

# --- Dormancy: an instance that is deliberately OFF is not a failure ---------
#
# Exit 2 means "nothing to back up, and that is correct" — distinct from exit 1,
# which always means something is wrong. backup.Jenkinsfile maps 2 to UNSTABLE so
# a parked server shows yellow rather than red.
#
# Three outcomes were all worse than a third state:
#   - FAILURE: a nightly red build for a server nobody asked to be running. Red
#     that is expected is red that gets ignored, and the next REAL failure with
#     it.
#   - SUCCESS: reports a backup happened when none did. That is the silent
#     failure this whole script is built to refuse.
#   - Disabling the job: the schedule then has to be remembered and re-armed by
#     hand at wake-up, which is exactly the step that gets forgotten.
#
# The intent signal is `spec.replicas`, the SAME marker the ValheimDown alert
# uses for this purpose (kustomize/fleet/prometheusrule.yaml — the trailing
# `unless ... kube_deployment_spec_replicas == 0`). Deliberately the same one:
# an operator scaling a server down should not have to know that backups and
# alerting disagree about what "off" means.
#
#   spec == 0                -> dormant, on purpose        -> exit 2 (UNSTABLE)
#   spec >= 1 but no pod     -> it fell over               -> exit 1 (FAILURE)
#   deployment missing       -> wrong ns, or it is gone    -> exit 1 (FAILURE)
#
# Checked BEFORE the pod lookup, because a dormant instance has no pod and would
# otherwise fail on the generic "no pod" path with a misleading message.
spec_replicas="$(kctl get deployment valheim -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
if [ -z "$spec_replicas" ]; then
  echo "ERROR: no deployment/valheim in namespace ${ns} — wrong namespace, or the instance is gone." >&2
  exit 1
fi
if [ "$spec_replicas" -eq 0 ]; then
  echo "DORMANT: deployment/valheim in ${ns} is scaled to 0 replicas (spec.replicas=0)."
  echo "  Skipping backup: there is no running server to produce or serve a tarball,"
  echo "  and the world on the PVC is unchanged since it was parked."
  echo "  The last upload in ${bucket}/${slug}/ remains the current off-cluster copy."
  echo "  Scale the instance back up to resume scheduled backups."
  exit 2
fi
echo "Instance is active (spec.replicas=${spec_replicas})"

pod="$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$pod" ]; then
  # Reachable only with spec >= 1, so this is a genuine problem: the instance is
  # supposed to be running and is not. Dormancy was already handled above.
  echo "ERROR: no pod with label app=valheim in namespace ${ns}, but spec.replicas=${spec_replicas}." >&2
  echo "  The instance is supposed to be running — check the Deployment and node capacity." >&2
  exit 1
fi
echo "Found pod ${pod} in ${ns}"

newest="$(kctl exec -n "$ns" "$pod" -c valheim-server -- sh -c 'ls -1t /home/steam/backups/*.tar.gz 2>/dev/null | head -1')"
if [ -z "$newest" ]; then
  echo "ERROR: no backup tarballs in /home/steam/backups on ${pod}." >&2
  echo "  Is AUTO_BACKUP=1 set, and is /home/steam/backups actually mounted?" >&2
  exit 1
fi
echo "Newest backup in pod: ${newest}"

mtime="$(kctl exec -n "$ns" "$pod" -c valheim-server -- stat -c %Y "$newest")"
now="$(date +%s)"
age=$(( now - mtime ))
if [ "$age" -gt "$max_age_seconds" ]; then
  echo "ERROR: newest backup is ${age}s old (limit ${max_age_seconds}s)." >&2
  echo "  odin's AUTO_BACKUP_SCHEDULE is probably not running. Refusing to upload a stale world." >&2
  exit 1
fi
echo "Backup age ${age}s — within limit"

ts="$(date +%Y%m%d-%H%M%S)"
local_file="${slug}-${ts}.tar.gz"
# Remove the copied archive from the Jenkins workspace after the upload attempt,
# regardless of outcome — a trap covers both the success and failure paths (and
# any early exit) without changing exit status or the semantics below.
trap 'rm -f "$local_file"' EXIT
kctl cp -n "$ns" -c valheim-server "${pod}:${newest}" "$local_file"

if [ ! -s "$local_file" ]; then
  echo "ERROR: copied file ${local_file} is empty." >&2
  exit 1
fi
# `wc -c`, not `stat -c %s`: this line runs on the AGENT, which is Linux under
# Jenkins but a macOS workstation when run by hand, and BSD stat has no -c (it
# spells the same thing `-f %z`). The GNU form failed with "illegal option -- c"
# and printed "Copied  bytes", which looks like a zero-byte copy in a log that is
# otherwise reporting success. wc -c is POSIX and behaves the same on both.
# (The `stat -c %Y` above is fine — that one runs INSIDE the Linux container.)
echo "Copied $(wc -c < "$local_file" | tr -d ' ') bytes to ${local_file}"

# Non-empty does not mean complete. Odin writes directly to the final .tar.gz
# path — including from its shutdown hook — so a pod terminating mid-backup can
# leave a fresh, non-empty, TRUNCATED tarball that would otherwise sail past
# both guards above and get uploaded as the newest backup. A corrupt backup
# that looks healthy is worse than a missing one: it would silently defeat the
# staleness alert. `tar -tzf` decompresses and walks the whole archive, so a
# truncated gzip stream or a cut-off tar member both fail it.
if ! tar -tzf "$local_file" >/dev/null 2>&1; then
  echo "ERROR: ${local_file} is corrupt or truncated (failed tar -tzf integrity check) — NOT uploaded." >&2
  echo "  Leaving the stale-backup alert firing rather than shipping a broken archive as 'latest'." >&2
  exit 1
fi
echo "Integrity check passed (tar -tzf)"

gs_path="${bucket}/${slug}/${ts}/${local_file}"
gsutil cp "$local_file" "$gs_path"
echo "Uploaded: ${gs_path}"

# The bucket is public (allUsers: roles/storage.objectViewer) so players can grab
# their own world archive directly — but a gs:// URI is useless to them; it only
# means anything to gcloud/gsutil. Derive the HTTPS form from the same $bucket and
# path pieces used above (never a second hardcoded copy) so the two can't drift.
https_path="https://storage.googleapis.com/${gs_path#gs://}"
echo "Shareable link (public bucket): ${https_path}"

# Touch the marker the backup-exporter sidecar reads, ONLY after a confirmed upload.
# This is what makes `valheim_backup_upload_age_seconds` mean "backups are actually
# leaving the cluster" rather than merely "odin ran locally". Placed after gsutil so
# a failed upload leaves the marker stale and the alert fires.
kctl exec -n "$ns" "$pod" -c valheim-server -- touch /home/steam/backups/.last-upload
echo "Upload marker refreshed"
