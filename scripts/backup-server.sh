#!/usr/bin/env bash
# Upload the newest odin-produced backup tarball to GCS.
#
# Usage: backup-server.sh <slug> [namespace]
#   <slug>       instance id; names the GCS path
#   [namespace]  defaults to valheim-<slug>; valheim7 lives in `kubicvalheim`
#
# odin (AUTO_BACKUP) already produced a consistent archive hourly, so unlike the
# KubicArk equivalent this does NOT exec a tar over a live world.
set -euo pipefail

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

pod="$(kubectl get pod -n "$ns" -l app=valheim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$pod" ]; then
  echo "ERROR: no pod with label app=valheim in namespace ${ns}" >&2
  exit 1
fi
echo "Found pod ${pod} in ${ns}"

newest="$(kubectl exec -n "$ns" "$pod" -c valheim-server -- sh -c 'ls -1t /home/steam/backups/*.tar.gz 2>/dev/null | head -1')"
if [ -z "$newest" ]; then
  echo "ERROR: no backup tarballs in /home/steam/backups on ${pod}." >&2
  echo "  Is AUTO_BACKUP=1 set, and is /home/steam/backups actually mounted?" >&2
  exit 1
fi
echo "Newest backup in pod: ${newest}"

mtime="$(kubectl exec -n "$ns" "$pod" -c valheim-server -- stat -c %Y "$newest")"
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
kubectl cp -n "$ns" -c valheim-server "${pod}:${newest}" "$local_file"

if [ ! -s "$local_file" ]; then
  echo "ERROR: copied file ${local_file} is empty." >&2
  exit 1
fi
echo "Copied $(stat -c %s "$local_file") bytes to ${local_file}"

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
kubectl exec -n "$ns" "$pod" -c valheim-server -- touch /home/steam/backups/.last-upload
echo "Upload marker refreshed"
