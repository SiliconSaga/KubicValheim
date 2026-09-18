# Shared definition of "this world is present", sourced by the lifecycle scripts.
#
# Valheim 1.0 (2026-09-09) changed how a world is stored, and every script that
# verified a world by name assumed the old shape. Before 1.0 a world was two
# files: worlds_local/<World>.db (the world) and <World>.fwl (seed + metadata).
# From 1.0 it is a DIRECTORY, worlds_local/<World>/, holding the world split into
# *.chunk files plus one generation of metadata named by save number:
#
#   _main.<N>.chunks   chunk index
#   _main.<N>.db2      the non-chunked remainder of what .db held
#   _main.<N>.fwl2     what .fwl held
#   _main.<N>.ok       written last, once the save verified
#
# The first boot on 1.0 converts a legacy world in place: the pair becomes
# <World>.db.old / .fwl.old, a <World>_backup_<ts>.db/.fwl copy is written beside
# them, and the directory takes over. The game's own point-in-time copies become
# <World>_backup_auto-<ts>/ directories with the same inner layout.
#
# Both layouts must verify, because both exist at once: every running instance
# has converted, while every archive in GCS from before 2026-09-09 — and any
# archive a player hands back from an older server — is still the flat pair.
# Restoring a legacy archive onto a 1.0 server is the supported revive path; the
# server converts it on boot.
#
# Iron Gate has published no spec for the directory. The names above are read off
# a live save dir and match community reports, so the check asserts the least a
# loadable world must have — a non-empty .fwl2 with its matching non-empty .db2 —
# rather than every file seen today. The 1.0 log no longer says `Load world:` or
# `missing <World>.db` either; it prints `Get create world <World>` whether it
# loaded or created, so this file check is the only mechanical proof left that a
# server came back on ITS world rather than a fresh one.

# POSIX sh, run INSIDE a container — the game image or a busybox helper — so
# nothing bash-only. Invoked as:
#
#   sh -c "$WORLD_PRESENT_SH" sh <worlds_dir> <world>
#
# Exits 0 and names the layout when <world> is present and non-empty in either
# form; exits 1, printing nothing, otherwise. The two values arrive as positional
# parameters and are never spliced into the string — a world named "Odin's
# Realm" would otherwise end the quoting, and anything worse would run inside
# the container.
WORLD_PRESENT_SH='
dir="$1"
world="$2"
if [ -s "$dir/$world.db" ] && [ -s "$dir/$world.fwl" ]; then
  echo "legacy layout: $world.db + $world.fwl"
  ls -l "$dir/$world.db" "$dir/$world.fwl"
  exit 0
fi
if [ -d "$dir/$world" ]; then
  for fwl2 in "$dir/$world"/_main.*.fwl2; do
    [ -s "$fwl2" ] || continue
    save="${fwl2%.fwl2}"
    [ -s "$save.db2" ] || continue
    echo "chunked layout (Valheim 1.0+): $world/ at save ${save##*/_main.}"
    ls -l "$save".*
    exit 0
  done
fi
exit 1
'

# --- Archive listings (run on the agent, in bash) -----------------------------
# Both take a normalised `tar tzf` listing: one path per line, leading ./
# already stripped.

# Print every world the listing holds, one per line, each once. A legacy world
# contributes its name via <World>.db, a chunked one via <World>/_main.<N>.fwl2.
# Backup copies (<World>_backup_auto-<ts>, <World>_backup_<ts>) come out too, in
# both layouts — callers that want only live worlds filter on the name.
archive_world_names() {
  sed -n \
    -e 's#^worlds_local/\([^/]*\)\.db$#\1#p' \
    -e 's#^worlds_local/\([^/]*\)/_main\.[0-9][0-9]*\.fwl2$#\1#p' \
    "$1" | sort -u
}

# Valheim's own point-in-time copies live beside the live world under decorated
# names, and both layouts produce them. They are loadable saves, so they are
# reported as restore points, never as peer worlds. Classified by the TIMESTAMP
# suffix rather than the word "backup" — a world someone legitimately called
# `World_backup_legacy` (create-server.sh's allowlist permits it) must stay a
# world. Three spellings, all ending in digits:
#     <World>_backup_auto-20260815120940         auto copy, before 1.0
#     <World>_backup_auto-20260917-172727        auto copy, 1.0 (hyphenated)
#     <World>_backup_20260909-081232             manual / version-upgrade copy
# awk program text, for `awk "$WORLD_BACKUP_COPY_AWK"` and its negation.
WORLD_BACKUP_COPY_AWK='/_backup_auto-[0-9]+(-[0-9]+)?$/ || /_backup_[0-9]+-[0-9]+$/'

# The worlds a restore could target, and the copies, split. awk rather than
# `grep -v`: grep exits 1 when nothing is selected, which under `set -e` kills a
# caller that was about to say "no worlds at all"; awk exits 0 on empty.
archive_live_world_names() {
  archive_world_names "$1" | awk "!(${WORLD_BACKUP_COPY_AWK})"
}
archive_backup_copy_names() {
  archive_world_names "$1" | awk "${WORLD_BACKUP_COPY_AWK}"
}

# True when the listing carries world $2 in either layout. Whole-line matches
# only: a substring match would let "World.1" satisfy "WorldX1", the exact
# mistake restore-server.sh documents. The legacy check stays literal (-F); the
# chunked one needs a regex for <N>, so the name is escaped for ERE first — the
# allowed character set is letters, digits, space, hyphen and underscore, none of
# which need it, but the escape costs nothing and the check should not depend on
# a validation that lives in another file.
archive_has_world() {
  local listing="$1" world="$2" esc
  if grep -Fqx -- "worlds_local/${world}.db" "$listing" \
     && grep -Fqx -- "worlds_local/${world}.fwl" "$listing"; then
    return 0
  fi
  esc="$(printf '%s' "$world" | sed 's/[][\.*^$/+?(){}|]/\\&/g')"
  grep -qE -- "^worlds_local/${esc}/_main\.[0-9]+\.fwl2$" "$listing" \
    && grep -qE -- "^worlds_local/${esc}/_main\.[0-9]+\.db2$" "$listing"
}

# One word naming the layout the listing holds world $2 in: `legacy`, `chunked`,
# or `absent`. For reporting; archive_has_world is the gate.
archive_world_layout() {
  local listing="$1" world="$2" esc
  if grep -Fqx -- "worlds_local/${world}.db" "$listing"; then
    echo legacy
    return 0
  fi
  esc="$(printf '%s' "$world" | sed 's/[][\.*^$/+?(){}|]/\\&/g')"
  if grep -qE -- "^worlds_local/${esc}/_main\.[0-9]+\.fwl2$" "$listing"; then
    echo chunked
    return 0
  fi
  echo absent
}
