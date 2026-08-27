#!/usr/bin/env python3
"""Pin the ordering invariants that restore-server.sh's safety rests on.

Run: python3 tests/restore-invariants.py   (from the component root)

Why this exists as a text check rather than an execution test: the failure it
guards against cannot be reached without a cluster, a PVC, and a deliberately
broken helper pod — so it is the kind of path that is never exercised until the
day it matters. The bug it encodes was an ORDERING bug: a flag meaning "the move
finished" was read as "there was nothing to move", and the recovery path then
deleted a world that was sitting right there. Asserting the order statically is
cheap and catches a re-conflation during an edit, which is how it happened.

These are deliberately narrow. They do not prove the script is correct; they
prove three specific things stay distinguishable:
    world_existed        a world was present at all
    staged               it was successfully moved aside
    pristine_confirmed   we positively established there was none
"""
import pathlib
import sys

script = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "restore-server.sh"
src = script.read_text()


def before(a: str, b: str) -> bool:
    """True when a appears before b — i.e. a is established first."""
    return src.index(a) < src.index(b)


def pristine_block() -> str:
    """Just the confirmed-pristine recovery branch.

    Scoping matters: the script scales the Deployment in several places, so an
    unscoped search for the scale command can match a different one and pass
    while this branch is wrong.
    """
    start = src.index('if [ "$staged" -eq 0 ] && [ "$pristine_confirmed" -eq 1 ]')
    end = src.index("# Neither staged nor confirmed pristine", start)
    return src[start:end]


def ordered_within(block: str, *anchors: str) -> bool:
    """True when every anchor appears, in the given order, inside block."""
    pos = -1
    for anchor in anchors:
        try:
            found = block.index(anchor, pos + 1)
        except ValueError:
            return False
        if found <= pos:
            return False
        pos = found
    return True


CHECKS = [
    ("world_existed is recorded before the ls that can fail",
     lambda: before("world_existed=1", "last look before it is staged aside")),
    # Anchored on the exec'd command, not on a quoted `sh -c` fragment: the
    # earlier version of this anchor matched a form the script no longer uses and
    # so failed the moment the command was rewritten. Anchors should track what
    # the script does, not how it happened to be spelled.
    ("staged=1 is set only after the mv completes",
     lambda: before("-- mv /world/worlds_local /world/worlds_local.rollback", "    staged=1")),
    ("pristine_confirmed is set only inside the ABSENT branch",
     lambda: before("  ABSENT)", "pristine_confirmed=1")),
    ("deletion requires pristine_confirmed, not merely staged==0",
     lambda: '[ "$staged" -eq 0 ] && [ "$pristine_confirmed" -eq 1 ]' in src),
    # Three steps, in order, inside the pristine branch specifically. The middle
    # one is the point: scaling up is what makes a half-extracted world live, so
    # it must come after the confirmation, not merely after the removal attempt.
    ("pristine recovery removes, then CONFIRMS, then scales up — in that order",
     lambda: ordered_within(
         pristine_block(),
         "rm -rf /world/worlds_local >/dev/null",
         'if [ "$after" = "ABSENT" ]',
         "kctl scale deployment valheim",
     )),
    ("a retry never deletes an existing worlds_local.rollback",
     lambda: "rm -rf /world/worlds_local.rollback &&" not in src),
    ("staging aborts when a rollback copy is already present",
     lambda: before('if [ "$rollback_state" != "ABSENT" ]',
                    "mv /world/worlds_local /world/worlds_local.rollback")),
    ("an indeterminate world_state aborts instead of guessing",
     lambda: "Refusing to continue: every safe path from here depends on knowing" in src),
    ("prior state is read as output, not as an exit status",
     lambda: "if [ -d /world/worlds_local ]; then echo EXISTS; else echo ABSENT; fi" in src),
]

failed = 0
for name, check in CHECKS:
    try:
        ok = check()
    except ValueError:
        ok = False  # a searched-for anchor is gone entirely
    print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        failed += 1

print()
if failed:
    print(f"RESULT: {failed} invariant(s) violated — recovery may delete a world it cannot prove was absent")
    sys.exit(1)
print("RESULT: all ordering invariants hold")
