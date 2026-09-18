#!/usr/bin/env bash
# Exercise scripts/lib/world-files.sh against both world layouts on a scratch
# directory — no cluster, no archive download.
#
# Run: bash tests/world-files.sh   (from the component root)
#
# The in-container check is run through `sh -c`, the same way the scripts run it
# inside a pod, so a bash-ism creeping into WORLD_PRESENT_SH fails here rather
# than inside a busybox helper mid-restore.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/world-files.sh
. "$ROOT/scripts/lib/world-files.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
expect() {
  # $1 = description, $2 = expected status, then the command.
  local desc="$1" want="$2" got
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then
    echo "  PASS  $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL  $desc (exit $got, wanted $want)"
    fail=$((fail + 1))
  fi
}

present() { sh -c "$WORLD_PRESENT_SH" sh "$1" "$2"; }

# --- On-disk layouts ---------------------------------------------------------
wl="$work/worlds_local"
mkdir -p "$wl"

echo "=== WORLD_PRESENT_SH ==="
expect "nothing there at all" 1 present "$wl" Jotunheim

printf 'seed' > "$wl/Legacy.fwl"
printf 'world' > "$wl/Legacy.db"
expect "legacy pair, both non-empty" 0 present "$wl" Legacy

: > "$wl/Empty.db"
printf 'seed' > "$wl/Empty.fwl"
expect "legacy pair with an empty .db" 1 present "$wl" Empty

# The shape a converted 1.0 world leaves behind: directory + .old pair + a
# conversion-time backup copy. Only the directory counts.
mkdir -p "$wl/Jotunheim"
printf 'chunk' > "$wl/Jotunheim/1e_1e__1_62.chunk"
printf 'index' > "$wl/Jotunheim/_main.407.chunks"
printf 'db2' > "$wl/Jotunheim/_main.407.db2"
printf 'fwl2' > "$wl/Jotunheim/_main.407.fwl2"
printf 'ok' > "$wl/Jotunheim/_main.407.ok"
printf 'old' > "$wl/Jotunheim.db.old"
printf 'old' > "$wl/Jotunheim.fwl.old"
printf 'copy' > "$wl/Jotunheim_backup_20260909-081232.db"
printf 'copy' > "$wl/Jotunheim_backup_20260909-081232.fwl"
expect "chunked directory with a complete save generation" 0 present "$wl" Jotunheim
expect "chunked check names the layout" 0 sh -c 'sh -c "$1" sh "$2" Jotunheim | grep -q "chunked layout"' sh "$WORLD_PRESENT_SH" "$wl"

mkdir -p "$wl/Torn"
printf 'chunk' > "$wl/Torn/00_00__0_1.chunk"
printf 'fwl2' > "$wl/Torn/_main.3.fwl2"
: > "$wl/Torn/_main.3.db2"
expect "chunked directory whose .db2 is empty" 1 present "$wl" Torn

mkdir -p "$wl/Bare"
printf 'chunk' > "$wl/Bare/00_00__0_1.chunk"
expect "chunked directory with chunks but no metadata" 1 present "$wl" Bare

mkdir -p "$wl/Odin's Realm"
printf 'db2' > "$wl/Odin's Realm/_main.1.db2"
printf 'fwl2' > "$wl/Odin's Realm/_main.1.fwl2"
expect "a world name with an apostrophe is passed as data" 0 present "$wl" "Odin's Realm"

# --- Archive listings --------------------------------------------------------
echo
echo "=== archive listing helpers ==="
listing="$work/listing.txt"
cat > "$listing" <<'EOF'
adminlist.txt
worlds_local/Legacy.db
worlds_local/Legacy.fwl
worlds_local/Legacy.db.old
worlds_local/Legacy_backup_auto-20260815120940.db
worlds_local/Legacy_backup_auto-20260815120940.fwl
worlds_local/Jotunheim/1e_1e__1_62.chunk
worlds_local/Jotunheim/_main.407.chunks
worlds_local/Jotunheim/_main.407.db2
worlds_local/Jotunheim/_main.407.fwl2
worlds_local/Jotunheim/_main.407.ok
worlds_local/Jotunheim_backup_auto-20260917-172727/_main.406.db2
worlds_local/Jotunheim_backup_auto-20260917-172727/_main.406.fwl2
worlds_local/JotunheimX/_main.1.db2
worlds_local/JotunheimX/_main.1.fwl2
worlds_local/Jotunheim_backup_20260909-081232.db
worlds_local/Jotunheim_backup_20260909-081232.fwl
worlds_local/World_backup_legacy.db
worlds_local/World_backup_legacy.fwl
worlds_local/Mismatch/_main.1.fwl2
worlds_local/Mismatch/_main.2.db2
worlds_local/Multi/_main.3.fwl2
worlds_local/Multi/_main.4.fwl2
worlds_local/Multi/_main.4.db2
worlds_local/A#B/_main.7.fwl2
worlds_local/A#B/_main.7.db2
worlds_local/WorldX1/_main.1.fwl2
worlds_local/WorldX1/_main.1.db2
EOF

names="$(archive_world_names "$listing" | tr '\n' ' ')"
expect "names: legacy world listed" 0 sh -c 'case " $1 " in *" Legacy "*) exit 0;; esac; exit 1' sh "$names"
expect "names: chunked world listed" 0 sh -c 'case " $1 " in *" Jotunheim "*) exit 0;; esac; exit 1' sh "$names"
expect "names: chunked backup copy listed under its own name" 0 sh -c 'case " $1 " in *" Jotunheim_backup_auto-20260917-172727 "*) exit 0;; esac; exit 1' sh "$names"
expect "names: .db.old rotation is not a world" 1 sh -c 'case " $1 " in *" Legacy.db "*|*" Legacy.db.old "*) exit 0;; esac; exit 1' sh "$names"

live="$(archive_live_world_names "$listing" | tr '\n' ' ')"
copies="$(archive_backup_copy_names "$listing" | tr '\n' ' ')"
expect "live: legacy and chunked worlds, nothing else" 0 sh -c '[ "$1" = "A#B Jotunheim JotunheimX Legacy Mismatch Multi WorldX1 World_backup_legacy " ]' sh "$live"
expect "copies: pre-1.0 auto, 1.0 hyphenated auto, and manual copies" 0 sh -c '[ "$1" = "Jotunheim_backup_20260909-081232 Jotunheim_backup_auto-20260917-172727 Legacy_backup_auto-20260815120940 " ]' sh "$copies"

expect "has: legacy pair" 0 archive_has_world "$listing" Legacy
expect "has: chunked directory" 0 archive_has_world "$listing" Jotunheim
expect "has: missing world" 1 archive_has_world "$listing" Helheim
expect "has: whole-name match only (Jotunheim vs JotunheimX)" 0 archive_has_world "$listing" JotunheimX
expect "has: a name that is only a prefix of a real one" 1 archive_has_world "$listing" Jotunhei
expect "has: .fwl2 and .db2 with DIFFERENT save numbers is no world" 1 archive_has_world "$listing" Mismatch
expect "has: one complete pair among several generations" 0 archive_has_world "$listing" Multi
expect "has: a name with a sed delimiter and regex chars is matched literally" 0 archive_has_world "$listing" "A#B"
expect "has: 'World.1' does not match the directory 'WorldX1'" 1 archive_has_world "$listing" "World.1"

saves_are() { [ "$(archive_world_saves "$1" "$2" | tr '\n' ' ')" = "$3" ]; }
expect "saves: only the complete generation is listed" 0 saves_are "$listing" Multi "4 "
expect "saves: mismatched generations list nothing" 0 saves_are "$listing" Mismatch ""
expect "saves: the live Jotunheim pair" 0 saves_are "$listing" Jotunheim "407 "

layout_is() { [ "$(archive_world_layout "$1" "$2")" = "$3" ]; }
expect "layout: legacy" 0 layout_is "$listing" Legacy legacy
expect "layout: chunked" 0 layout_is "$listing" Jotunheim chunked
expect "layout: absent" 0 layout_is "$listing" Helheim absent
expect "layout: a directory with no complete pair still reads as chunked" 0 layout_is "$listing" Mismatch chunked

echo
echo "Summary: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
