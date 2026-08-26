#!/usr/bin/env bash
# Report what is inside a Valheim backup archive — above all, WHICH WORLD it holds.
#
# Usage: inspect-archive.sh <archive>
#   <archive>  gs://... path, an https://storage.googleapis.com/... URL, or a
#              local .tar.gz file
#
# Why this exists: to revive an old world you must create the server with the
# world's ORIGINAL name, because Valheim loads whatever the Deployment's WORLD env
# says and will happily generate a fresh empty world rather than adopt a
# differently-named save sitting next to it. If you no longer remember the name,
# the archive knows: the world files are stored as worlds_local/<World>.db and
# .fwl, so the name is simply the filename. This reads it out without downloading
# anything you then have to clean up, and without touching a cluster.
#
# Read-only by construction: it lists and prints. Nothing here can modify an
# archive, a bucket, or a server.
set -euo pipefail

archive_ref="${1:?usage: inspect-archive.sh <gs://... | https://storage.googleapis.com/... | local file>}"

work=""
cleanup() { [ -n "$work" ] && rm -rf "$work"; }
trap cleanup EXIT

case "$archive_ref" in
  https://storage.googleapis.com/*)
    gs_uri="gs://${archive_ref#https://storage.googleapis.com/}"
    work="$(mktemp -d)"
    local_file="${work}/archive.tar.gz"
    echo "Downloading ${gs_uri} ..."
    gsutil cp "$gs_uri" "$local_file"
    ;;
  gs://*)
    work="$(mktemp -d)"
    local_file="${work}/archive.tar.gz"
    echo "Downloading ${archive_ref} ..."
    gsutil cp "$archive_ref" "$local_file"
    ;;
  *)
    if [ ! -f "$archive_ref" ]; then
      echo "ERROR: '${archive_ref}' is not a readable file, a gs:// path, or an https://storage.googleapis.com/... URL" >&2
      exit 1
    fi
    local_file="$archive_ref"
    ;;
esac

# On its own line, status checked explicitly — a pipeline would report the LAST
# command's status and silently swallow a tar failure on a truncated archive.
listing="$(mktemp)"
set +e
tar tzf "$local_file" > "$listing"
tar_status=$?
set -e
if [ "$tar_status" -ne 0 ]; then
  rm -f "$listing"
  echo "ERROR: archive failed 'tar tzf' (exit ${tar_status}) — corrupt or truncated." >&2
  exit 1
fi

norm="$(mktemp)"
sed 's#^\./##' "$listing" > "$norm"

# The live worlds: worlds_local/<name>.db, excluding Valheim's own .db.old
# rotation and odin's timestamped autobackup copies. Those are the same world
# wearing a decorated name and would make one world look like several.
worlds="$(sed -n 's#^worlds_local/\([^/]*\)\.db$#\1#p' "$norm" | grep -v -- '_backup_auto-' | sort -u)"

echo
echo "=== Worlds in this archive ==="
if [ -z "$worlds" ]; then
  echo "  (none — no worlds_local/<name>.db entry found)"
  echo "  This does not look like a Valheim world backup."
else
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    db_size="$(awk -v n="worlds_local/${w}.db" '$0==n {found=1} END {print found?"present":"MISSING"}' "$norm")"
    fwl_size="$(awk -v n="worlds_local/${w}.fwl" '$0==n {found=1} END {print found?"present":"MISSING"}' "$norm")"
    echo "  ${w}    (.db ${db_size}, .fwl ${fwl_size})"
  done <<EOF
$worlds
EOF
  echo
  echo "To revive one of these on a NEW server, create the instance with that exact"
  echo "world name — set WORLD in the overlay's instance-patch.yaml — then run the"
  echo "restore job against this archive. A server configured for any other name will"
  echo "ignore these files and generate an empty world instead."
fi

echo
echo "=== Full contents ==="
sort "$norm"
rm -f "$listing" "$norm"
