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
# the archive knows: a world is stored as worlds_local/<World>.db + .fwl (before
# Valheim 1.0) or as a worlds_local/<World>/ directory (1.0 and later), so the
# name is simply the file or directory name. This reads it out without
# downloading anything you then have to clean up, and without touching a cluster.
#
# Read-only by construction: it lists and prints. Nothing here can modify an
# archive, a bucket, or a server.
set -euo pipefail

# shellcheck source=lib/world-files.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/world-files.sh"

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

# The live worlds — worlds_local/<name>.db or worlds_local/<name>/ (see
# lib/world-files.sh for the two layouts) — with Valheim's own .db.old rotation
# and its timestamped point-in-time copies split out. Those are the same world
# wearing a decorated name; presenting them as peers of the live world buries
# the single answer this command exists to give. Matching only the auto-copy
# form once made a real legacy archive report three "worlds" when it held one,
# and the 1.0 auto-copy timestamp grew a hyphen that the old pattern rejected,
# so the classification now lives in the lib beside the layout rules and is
# tested there. The copies are reported separately below as what they are:
# restore points.
worlds="$(archive_live_world_names "$norm")"
backup_copies="$(archive_backup_copy_names "$norm")"

echo
echo "=== Worlds in this archive ==="
if [ -z "$worlds" ]; then
  echo "  (none — no worlds_local/<name>.db or worlds_local/<name>/_main.<N>.fwl2 entry found)"
  echo "  This does not look like a Valheim world backup."
else
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    # Which layout, and is the pair complete? A name with only half its files is
    # the one case worth flagging here: it will list as a world and then fail
    # the restore's own check.
    case "$(archive_world_layout "$norm" "$w")" in
      legacy)
        if archive_has_world "$norm" "$w"; then
          echo "  ${w}    (legacy: .db + .fwl present)"
        else
          echo "  ${w}    (legacy: .db present, .fwl MISSING)"
        fi
        ;;
      chunked)
        saves="$(sed -n "s#^worlds_local/${w}/_main\.\([0-9][0-9]*\)\.fwl2\$#\1#p" "$norm" | sort -n | tr '\n' ' ')"
        if archive_has_world "$norm" "$w"; then
          echo "  ${w}    (Valheim 1.0 directory: save ${saves% })"
        else
          echo "  ${w}    (Valheim 1.0 directory: save ${saves% }, .db2 MISSING)"
        fi
        ;;
    esac
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
