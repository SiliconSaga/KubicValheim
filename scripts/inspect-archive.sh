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
# NOT `[ -n "$work" ] && rm -rf "$work"`. For a local-file argument $work stays
# empty, the test is false, the && short-circuits, and the function returns 1 —
# which an EXIT trap propagates as the script's exit status. Inspecting a local
# archive would then report failure while having worked perfectly. An explicit
# `if` keeps the trap's status independent of whether there was anything to clean.
cleanup() {
  if [ -n "$work" ]; then
    rm -rf "$work"
  fi
}
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
# Valheim keeps its own point-in-time copies beside the live world, under BOTH
# `<World>_backup_auto-<ts>` (odin's schedule) and `<World>_backup_<ts>` (manual
# and version-upgrade saves). Matching only the first form made a real legacy
# archive report three "worlds" when it held one — the copies are loadable, so
# they are not wrong exactly, but presenting them as peers of the live world
# buries the single answer this command exists to give. Filtering on `_backup_`
# catches both, and the copies are reported separately below as what they are:
# restore points.
#
# awk, not `grep -v`: grep exits 1 when it selects nothing, and under
# `set -euo pipefail` that aborts the script right here — so an archive holding
# ONLY backup copies, or no worlds at all, would die silently instead of
# reaching the "(none)" branch that exists to explain exactly that case.
# Match the TIMESTAMP, not the word "backup". A plain `_backup_` substring test
# also swallows a world someone legitimately called `World_backup_legacy` —
# start-server.sh's allowlist permits underscores, so that name is reachable, and
# hiding a real world is the same failure as inventing fake ones, just inverted.
# Valheim's two copy formats both END in digits:
#     <World>_backup_auto-20260815120940     (odin's schedule)
#     <World>_backup_20260206-235715         (manual / version upgrade)
# so anchoring on trailing digits classifies exactly those and leaves any
# human-chosen name alone. `[0-9]+$` rather than a {14} interval keeps this
# portable across awk implementations.
is_backup_copy='/_backup_auto-[0-9]+$/ || /_backup_[0-9]+-[0-9]+$/'
worlds="$(sed -n 's#^worlds_local/\([^/]*\)\.db$#\1#p' "$norm" | awk "!(${is_backup_copy})" | sort -u)"
backup_copies="$(sed -n 's#^worlds_local/\([^/]*\)\.db$#\1#p' "$norm" | awk "${is_backup_copy}" | sort -u)"

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

if [ -n "$backup_copies" ]; then
  echo
  echo "=== Point-in-time copies also inside this archive ==="
  echo "  (Valheim's own backups of the world above — NOT separate worlds. Each is a"
  echo "   loadable save, so any of them can be revived by naming it as WORLD.)"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    echo "  ${b}"
  done <<EOF
$backup_copies
EOF
fi

echo
echo "=== Full contents ==="
sort "$norm"
rm -f "$listing" "$norm"
