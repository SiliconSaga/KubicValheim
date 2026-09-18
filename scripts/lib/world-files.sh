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
# form; exits 1, printing nothing, otherwise. The generation must be all digits,
# the same contract archive_world_saves enforces on a listing, so the live check
# and the archive gate cannot disagree about a stray `_main.bad.fwl2`. The two
# values arrive as positional
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
    case "${save##*/_main.}" in
      ""|*[!0-9]*) continue ;;
    esac
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
    "$1" | LC_ALL=C sort -u
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

# Save numbers <N> for which the listing has `worlds_local/<world>/_main.<N>.fwl2`
# — paired with its `.db2` or not. The world name is matched as a LITERAL
# prefix via awk's index(), never interpolated into a regex or a sed
# expression: a name is anything without a `/` (an archive from elsewhere can
# hold `A#B` or `World.1`), and "World.1" as a pattern would happily match
# "WorldX1", the substring mistake restore-server.sh documents. Only the part
# after the prefix, `<digits>.fwl2`, is tested with a pattern.
_archive_world_fwl2_saves() {
  awk -v p="worlds_local/$2/_main." '
    index($0, p) == 1 {
      r = substr($0, length(p) + 1)
      if (r ~ /^[0-9]+\.fwl2$/) print substr(r, 1, length(r) - 5)
    }' "$1" | sort -n
}

# The subset of those saves that are COMPLETE: the `.db2` with the same <N> is
# also present. Same rule as WORLD_PRESENT_SH on disk — `_main.1.fwl2` next to
# `_main.2.db2` is no loadable generation at all, and pre-clear validation must
# not accept what the post-extract check would then refuse.
archive_world_saves() {
  local listing="$1" world="$2" n
  for n in $(_archive_world_fwl2_saves "$listing" "$world"); do
    if grep -Fqx -- "worlds_local/${world}/_main.${n}.db2" "$listing"; then
      echo "$n"
    fi
  done
}

# True when the listing carries world $2 in either layout: the literal `.db` +
# `.fwl` pair, or a directory with at least one complete save generation.
archive_has_world() {
  local listing="$1" world="$2"
  if grep -Fqx -- "worlds_local/${world}.db" "$listing" \
     && grep -Fqx -- "worlds_local/${world}.fwl" "$listing"; then
    return 0
  fi
  [ -n "$(archive_world_saves "$listing" "$world")" ]
}

# One word naming the layout the listing holds world $2 in: `legacy`, `chunked`,
# or `absent`. For reporting; archive_has_world is the gate, so `chunked` here
# can still fail it (a directory with no complete pair).
archive_world_layout() {
  local listing="$1" world="$2"
  if grep -Fqx -- "worlds_local/${world}.db" "$listing"; then
    echo legacy
    return 0
  fi
  if [ -n "$(_archive_world_fwl2_saves "$listing" "$world")" ]; then
    echo chunked
    return 0
  fi
  echo absent
}
