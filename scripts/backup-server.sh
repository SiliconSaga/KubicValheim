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
# is built. Same DNS-1123-label-ish convention scripts/create-server.sh already
# uses for its <name> argument: lowercase alphanumerics and '-', start/end
# alphanumeric — which as a side effect also rejects '/', '..', and a leading '-'.
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
# Same bound scripts/create-server.sh enforces on <name>, for the same reason: the
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
# Exit 2 must mean DORMANT and nothing else, because backup.Jenkinsfile turns it
# into a yellow build. Everything below can produce a 2 by accident: `kubectl
# exec` propagates the REMOTE command's exit status, and gcloud/gsutil use 2 for
# usage errors. Under `set -e` that status becomes the script's, so a failed
# upload would be reported as UNSTABLE — the "looks fine, shipped nothing"
# outcome the staleness and `tar -tzf` guards exist to prevent.
#
# So: only a deliberate dormancy exit sets the flag, and the trap normalizes
# every other non-zero status to 1. The trap also does the workspace cleanup
# that used to be installed further down.
dormant=0
# EXIT trap: remove the workspace copy if one was made, then collapse the exit
# status to the contract Jenkins reads — 0 success, 2 only when `dormant` was set
# deliberately, 1 for everything else.
finish() {
  rc=$?
  if [ -n "${local_file:-}" ]; then rm -f "$local_file"; fi
  if [ "$rc" -eq 0 ]; then exit 0; fi
  if [ "$dormant" -eq 1 ]; then exit 2; fi
  exit 1
}
trap finish EXIT

# `--ignore-not-found` so a missing Deployment is exit 0 with empty output, which
# separates "it is not there" from "the query itself failed". Without it, both
# arrive as a non-zero status and an auth, RBAC or network fault gets reported as
# "the instance is gone" — sending someone to look for a deleted server that is
# actually running fine behind a broken credential.
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
  echo "DORMANT: deployment/valheim in ${ns} is scaled to 0 replicas (spec.replicas=0)."
  echo "  Skipping backup: there is no running server to produce or serve a tarball,"
  echo "  and the world on the PVC is unchanged since it was parked."
  echo "  The last upload in ${bucket}/${slug}/ remains the current off-cluster copy."
  echo "  Scale the instance back up to resume scheduled backups."
  exit 2
fi
echo "Instance is active (spec.replicas=${spec_replicas})"

# `{range}` rather than `{.items[0]...}`: an empty item list is a normal result
# for a label selector, and indexing [0] into it errors on some kubectl versions
# — which would be indistinguishable from a real query failure here.
if ! pods="$(kctl get pod -n "$ns" -l app=valheim -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>&1)"; then
  echo "ERROR: could not query pods in ${ns} — the API call failed:" >&2
  echo "  ${pods}" >&2
  exit 1
fi
pod="${pods%% *}"
if [ -z "$pod" ]; then
  # Re-read spec.replicas rather than trusting the value from above. An operator
  # can park the instance between the two calls, and a nightly job that happens
  # to land in that window would otherwise go red for a server someone had just
  # deliberately switched off — the exact false alarm this change removes.
  # Status kept, same as the two lookups above — an earlier revision of this line
  # fell back to the previous count on failure, which would have reported a
  # missing pod when the API call itself was what broke.
  if ! spec_now="$(kctl get deployment valheim -n "$ns" --ignore-not-found -o jsonpath='{.spec.replicas}' 2>&1)"; then
    echo "ERROR: could not re-query deployment/valheim in ${ns} — the API call failed:" >&2
    echo "  ${spec_now}" >&2
    exit 1
  fi
  if [ -z "$spec_now" ]; then
    echo "ERROR: deployment/valheim disappeared from ${ns} during this run." >&2
    exit 1
  fi
  if [ "$spec_now" -eq 0 ]; then
    dormant=1
    echo "DORMANT: deployment/valheim in ${ns} was scaled to 0 while this run was starting."
    echo "  Skipping backup; nothing was missed."
    exit 2
  fi
  echo "ERROR: no pod with label app=valheim in namespace ${ns}, but spec.replicas=${spec_now}." >&2
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
# Workspace cleanup is handled by the `finish` EXIT trap installed above — it
# covers success, failure and any early exit, and reads local_file at trap time
# so it is safe that the variable is only set here. A second `trap ... EXIT` at
# this point would REPLACE that one, silently dropping the exit-status
# normalization along with it.
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
