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
ns="${2:-valheim-${slug}}"
bucket="gs://kubic-game-hosting/valheim"
# A tarball older than this means odin's hourly schedule is not running. Uploading
# it anyway would look like success while shipping a stale world — the exact silent
# failure this design exists to avoid.
max_age_seconds=10800   # 3h

pod="$(kubectl get pod -n "$ns" -l app=valheim -o jsonpath='{.items[0].metadata.name}')"
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
kubectl cp -n "$ns" -c valheim-server "${pod}:${newest}" "$local_file"

if [ ! -s "$local_file" ]; then
  echo "ERROR: copied file ${local_file} is empty." >&2
  exit 1
fi
echo "Copied $(stat -c %s "$local_file") bytes to ${local_file}"

gsutil cp "$local_file" "${bucket}/${slug}/${ts}/${local_file}"
echo "Uploaded: ${bucket}/${slug}/${ts}/${local_file}"

# Touch the marker the backup-exporter sidecar reads, ONLY after a confirmed upload.
# This is what makes `valheim_backup_upload_age_seconds` mean "backups are actually
# leaving the cluster" rather than merely "odin ran locally". Placed after gsutil so
# a failed upload leaves the marker stale and the alert fires.
kubectl exec -n "$ns" "$pod" -c valheim-server -- touch /home/steam/backups/.last-upload
echo "Upload marker refreshed"
