#!/usr/bin/env bash
# Restore a Valheim world from a GCS backup archive onto a LIVE instance.
#
# Usage: restore-server.sh <slug> <namespace> <world> <archive>
#   <slug>      instance id; validated the same way backup-server.sh validates it
#   <namespace> namespace holding the server
#   <world>     the WORLD this instance is configured with (see the overlay's
#               instance-patch.yaml, or the WORLD env var on the running pod) —
#               this is what step 4 below matches the archive against
#   <archive>   gs://... path OR the https://storage.googleapis.com/... URL
#               backup-server.sh prints, since the owner hands players that link
#
# Env:
#   KUBE_CONTEXT  kubectl context to target. REQUIRED — this script refuses to
#                 run without it, unlike backup-server.sh where it is advisory.
#                 See the context guard below for why inheriting current-context
#                 is not safe here.
#   RESTORE_ALLOW_CURRENT_CONTEXT=1
#                 Deliberate opt-in to use kubectl's current-context instead.
#                 Set by restore.Jenkinsfile, where the agent has exactly one.
#
# DESTRUCTIVE: scales deployment/valheim to 0 and replaces worlds_local on the
# live PVC. Mirrors docs/restore.md — read that first if this needs changing.
# EVERY validation below (slug, world name, archive integrity, archive-vs-world
# match) runs and passes BEFORE anything is scaled down or touched, so a bad
# slug, an unreadable archive, or an archive from the wrong instance all abort
# with the live world completely intact.
set -euo pipefail

# Which cluster are we destroying a world on? kubectl defaults to whatever
# `current-context` happens to be. On a workstation that juggles k3d and GKE that
# is regularly NOT the cluster you mean — backup-server.sh silently queried a
# local k3d cluster and reported "no pod" for a server running fine on GKE. Here
# the same slip would scale down a deployment and `rm -rf` a worlds_local on the
# wrong cluster. KUBE_CONTEXT pins the target; unset, we resolve and print it so
# it is never silently inherited. Step 4b below turns this from "printed, hope
# someone reads it" into an actual guard.
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
if [ -n "$KUBE_CONTEXT" ]; then
  kctl() { kubectl --context "$KUBE_CONTEXT" "$@"; }
else
  # Fail closed rather than inheriting `current-context`. Step 4b's WORLD check
  # is NOT a cluster-identity check — applying the same overlay to a local test
  # cluster produces the same namespace and the same WORLD, so a stale context
  # can satisfy it and still reach the destructive steps. The Jenkins agent has
  # exactly one context and opts in explicitly below; a workstation must say
  # which cluster it means.
  if [ "${RESTORE_ALLOW_CURRENT_CONTEXT:-0}" != "1" ]; then
    echo "ERROR: KUBE_CONTEXT is not set." >&2
    echo "  This job deletes a world. Name the cluster explicitly:" >&2
    echo "    KUBE_CONTEXT=<context> $0 $*" >&2
    echo "  To deliberately use kubectl's current-context ($(kubectl config current-context 2>/dev/null || echo none)), set RESTORE_ALLOW_CURRENT_CONTEXT=1." >&2
    exit 1
  fi
  KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "$KUBE_CONTEXT" ]; then
    echo "ERROR: RESTORE_ALLOW_CURRENT_CONTEXT=1 but kubectl has no current-context" >&2
    exit 1
  fi
  kctl() { kubectl "$@"; }
fi
echo "Targeting kubectl context: ${KUBE_CONTEXT}"

slug="${1:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"
ns="${2:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"
world="${3:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"
archive_ref="${4:?usage: restore-server.sh <slug> <namespace> <world> <archive>}"

# --- 1. Validate <slug>, exactly as backup-server.sh does ------------------
# Kept identical to backup-server.sh's checks. slug is a mutable Jenkins build
# parameter here too, and even though namespace is passed explicitly (unlike
# backup-server.sh's default-from-slug), slug still names the local workspace
# file below, so the same DNS-1123-label-ish discipline applies before any
# path is built from it.
if [[ ! "$slug" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: <slug> must be a DNS-1123 label (lowercase alphanumerics and '-', start/end alphanumeric)" >&2
  exit 1
fi
if (( ${#slug} > 55 )); then
  echo "ERROR: <slug> must be <=55 chars so the namespace valheim-<slug> stays within Kubernetes' 63-char limit" >&2
  exit 1
fi

# <world> only ever flows into literal grep -F patterns and log/echo text below
# — never into a path or command substitution — so it needs no shell-safety
# validation. This is the same printable-name allowlist create-server.sh enforces
# when it WRITES a world name; it just catches a typo'd/empty value early with a
# clear error instead of a confusing miss deep in step 4's grep.
world_re='^[A-Za-z0-9 _-]+$'
if [[ ! "$world" =~ $world_re ]]; then
  echo "ERROR: <world> may only contain letters, digits, spaces, hyphens, and underscores." >&2
  exit 1
fi

# --- Normalise the archive reference: accept either form -------------------
# backup-server.sh now prints both a gs:// path (for operators) and an
# https://storage.googleapis.com/... link (for players, since the bucket is
# public) — the owner wants to be able to hand either one back to this script.
# gsutil only understands gs://, so whichever form arrives is normalised once,
# up front, before anything else uses it.
case "$archive_ref" in
  https://storage.googleapis.com/*)
    gs_uri="gs://${archive_ref#https://storage.googleapis.com/}"
    ;;
  gs://*)
    gs_uri="$archive_ref"
    ;;
  *)
    echo "ERROR: <archive> must be a gs://... path or an https://storage.googleapis.com/... URL" >&2
    exit 1
    ;;
esac

# ANY readable archive is accepted, deliberately. Restoring one instance's
# backup onto a different instance is a SUPPORTED workflow, not an accident:
# someone spinning up a fresh server to revive an old world pastes the public
# link to that world's zip, and the whole point of publishing those links is
# that they can be used. An earlier revision required the archive to sit under
# this instance's own <bucket>/valheim/<slug>/ prefix, which made that
# impossible — it optimised against a narrow mix-up and blocked the feature.
#
# What still protects a live world, and is enough:
#   - the archive must CONTAIN worlds_local/<world>.db and .fwl (step 4), so a
#     restore cannot quietly replace a world with an unrelated one;
#   - the live Deployment must already be running <world> (step 4b), so the
#     target has to be the instance you named;
#   - KUBE_CONTEXT must be explicit, so it is the cluster you named;
#   - the old world is staged aside and only dropped once the new one verifies.
#
# The residual risk is narrow and accepted: two instances configured with the
# SAME world name (the base default is "Dedicated") can be restored across, since
# nothing then distinguishes them. Name worlds distinctly if that matters to you.
# A cross-instance restore is called out below rather than blocked, because the
# operator should know which of the two things they are doing.
case "$gs_uri" in
  "gs://kubic-game-hosting/valheim/${slug}/"*) ;;
  *)
    echo "NOTE: this archive is not one of instance '${slug}'s own backups." >&2
    echo "  ${gs_uri}" >&2
    echo "  Proceeding — cross-instance restore is supported. The world-name and" >&2
    echo "  live-instance checks below still have to pass." >&2
    ;;
esac
echo "Archive: ${gs_uri}"

# Cleanup plumbing set up before anything is created, with the tracked
# variables pre-declared (set -u would otherwise choke on an unset var if the
# trap ran before a given step assigned it — e.g. a failure during download,
# before the listing files exist).
local_file=""
listing_raw=""
listing_norm=""
# Set once destructive work begins, so cleanup knows whether there is anything
# in the cluster to undo. Before this flips, a failure only needs temp files
# removed; after it, a failure has left a stopped server and a staged world.
destructive_started=0
# Whether a pre-existing world was moved aside. 0 means the PVC had none — a
# pristine instance — which changes what a failure means: there is nothing to
# restore and nothing to lose, so recovery is "return it to empty and running"
# rather than "refuse to start until the world reappears".
staged=0
# Deliberately separate from `staged`. `staged` means the move completed;
# `pristine_confirmed` means we positively established there was nothing to move.
# A failure BETWEEN those two leaves staged=0 with a real world still present, and
# only this flag stops recovery from deleting it.
pristine_confirmed=0
world_existed=0
helper="restore-helper"
prev_replicas=""

# One definition of the helper pod, used by the main flow AND by rollback —
# recovery may need a helper even when the original one has died, which is the
# case that makes a naive rollback silently do nothing.
helper_overrides='{"spec":{"containers":[{"name":"restore-helper","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"world","mountPath":"/world"}]}],"volumes":[{"name":"world","persistentVolumeClaim":{"claimName":"valheim-data"}}]}}'

start_helper() {
  # Pod deletion isn't the same as the volume actually detaching, so a leftover
  # helper from a prior failed attempt is removed first rather than assumed gone.
  kctl delete pod "$helper" -n "$ns" --ignore-not-found --wait=true
  kctl run "$helper" -n "$ns" --image=busybox:1.36 --restart=Never --overrides="$helper_overrides"
  kctl wait pod "$helper" -n "$ns" --for=condition=Ready --timeout=120s
}

cleanup() {
  status=$?
  rm -f "$local_file" "$listing_raw" "$listing_norm"
  if [ "$destructive_started" -eq 0 ] || [ "$status" -eq 0 ]; then
    return 0
  fi
  echo "" >&2
  echo "RESTORE FAILED (exit ${status}) — attempting rollback." >&2

  # The helper may itself be the thing that died. Rolling back requires one, so
  # recreate it rather than exec'ing into a pod that may not exist — an exec
  # into a dead helper fails silently, and the old code then restarted Valheim
  # with worlds_local MOVED AWAY, which makes Valheim generate a fresh empty
  # world: the precise silent data loss this script exists to prevent.
  if ! kctl exec "$helper" -n "$ns" -- true >/dev/null 2>&1; then
    echo "  helper pod unusable — recreating it to complete rollback" >&2
    start_helper >/dev/null 2>&1 || true
  fi

  # Gated on pristine_confirmed, NOT on staged==0. Those differ precisely when it
  # matters: if the world existed but the `ls` or `mv` failed, staged is still 0
  # while a REAL world sits in worlds_local — and deleting it here would be the
  # data loss this whole script exists to prevent, committed by its own recovery.
  # Only a definitive ABSENT reading earns the right to delete.
  if [ "$staged" -eq 0 ] && [ "$pristine_confirmed" -eq 1 ]; then
    kctl exec "$helper" -n "$ns" -- rm -rf /world/worlds_local >/dev/null 2>&1 || true
    # Confirm the removal instead of assuming it. If the helper is unusable the
    # rm silently does nothing, and restarting then points Valheim at a PARTIAL
    # extraction, which it will happily adopt and start writing to.
    after="$(kctl exec "$helper" -n "$ns" -- sh -c \
      'if [ -d /world/worlds_local ]; then echo EXISTS; else echo ABSENT; fi' 2>/dev/null \
      | tr -d '\r' | tail -1)"
    if [ "$after" = "ABSENT" ]; then
      kctl delete pod "$helper" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      if [ -n "$prev_replicas" ]; then
        kctl scale deployment valheim -n "$ns" --replicas="$prev_replicas" >/dev/null 2>&1 || true
        echo "  ROLLED BACK: the instance had no prior world, partial extraction cleared, back to empty and running (replicas ${prev_replicas})." >&2
        echo "  Nothing was lost. Fix the cause and re-run." >&2
      fi
    else
      echo "  ROLLBACK INCOMPLETE — could not confirm the partial extraction was removed." >&2
      echo "  Deployment deliberately LEFT AT 0 REPLICAS: starting Valheim against a" >&2
      echo "  half-extracted world would let it adopt and write to the fragments." >&2
      echo "  Helper '${helper}' left running; inspect with:" >&2
      echo "    kubectl --context ${KUBE_CONTEXT} exec ${helper} -n ${ns} -- ls -la /world /world/worlds_local" >&2
    fi
    return 0
  fi

  # Neither staged nor confirmed pristine. Touch nothing: this is the one case
  # where doing less is strictly safer, and the helper stays mounted so a human
  # can look. The two ways to land here need different words, because one of them
  # means a real world is probably sitting there untouched.
  if [ "$staged" -eq 0 ]; then
    if [ "$world_existed" -eq 1 ]; then
      echo "  A WORLD WAS PRESENT but staging it aside did not complete." >&2
      echo "  It is most likely still intact at /world/worlds_local — nothing here" >&2
      echo "  deleted or moved it. Verify that, then scale back up." >&2
    else
      echo "  PRIOR STATE UNKNOWN — the check that determines whether this instance" >&2
      echo "  had a world did not complete, so nothing has been deleted or restored." >&2
    fi
    echo "  Deployment LEFT AT 0 REPLICAS and helper '${helper}' left running:" >&2
    echo "    kubectl --context ${KUBE_CONTEXT} exec ${helper} -n ${ns} -- ls -la /world /world/worlds_local /world/worlds_local.rollback" >&2
    echo "  If a worlds_local.rollback exists, THAT is the original — swap it back" >&2
    echo "  before starting the server, or Valheim will adopt whatever is in its place." >&2
    return 0
  fi

  kctl exec "$helper" -n "$ns" -- sh -c \
    'if [ -d /world/worlds_local.rollback ]; then rm -rf /world/worlds_local; mv /world/worlds_local.rollback /world/worlds_local; fi' \
    >/dev/null 2>&1 || true

  # VERIFY before restarting. Restoring replicas is only safe once the world is
  # actually back; doing it unconditionally converts a failed restore into a
  # silently-new world, which is worse than staying down.
  if kctl exec "$helper" -n "$ns" -- sh -c "test -s '/world/worlds_local/${world}.db'" >/dev/null 2>&1; then
    kctl delete pod "$helper" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    if [ -n "$prev_replicas" ]; then
      kctl scale deployment valheim -n "$ns" --replicas="$prev_replicas" >/dev/null 2>&1 || true
      echo "  ROLLED BACK: ${world}.db verified in place, replicas restored to ${prev_replicas}." >&2
      echo "  The world on the PVC is the one you started with. Re-run once the cause is understood." >&2
    fi
  else
    # Deliberately leave the Deployment at zero and the helper alive. A stopped
    # server is loud and recoverable; a running server on a missing world starts
    # generating a new one and overwrites the evidence.
    echo "  ROLLBACK INCOMPLETE — ${world}.db is NOT in place." >&2
    echo "  Deployment deliberately LEFT AT 0 REPLICAS so Valheim cannot start and generate a new world." >&2
    echo "  The helper pod '${helper}' has been left running with the PVC mounted; inspect it:" >&2
    echo "    kubectl --context ${KUBE_CONTEXT} exec ${helper} -n ${ns} -- ls -la /world /world/worlds_local /world/worlds_local.rollback" >&2
    echo "  Recover from a known-good archive before scaling back up." >&2
  fi
}
trap cleanup EXIT

# --- 2. Download the archive to the workspace -------------------------------
local_file="$(basename "$gs_uri")"
gsutil cp "$gs_uri" "$local_file"
if [ ! -s "$local_file" ]; then
  echo "ERROR: downloaded file ${local_file} is empty." >&2
  exit 1
fi
# `wc -c`, not `stat -c %s` — this runs on the AGENT, and BSD stat (macOS) has no
# -c, so the GNU form prints "illegal option" and yields an empty size, which
# reads as a zero-byte download in an otherwise-successful log. See the matching
# note in backup-server.sh.
echo "Downloaded $(wc -c < "$local_file" | tr -d ' ') bytes to ${local_file}"

# --- 3. Validate it before touching anything --------------------------------
# `tar tzf` on its OWN line — never piped into anything else. A pipeline
# reports only the LAST command's exit status, which would silently swallow a
# tar failure. -e is suspended for exactly this one command so the exit status
# can be captured explicitly and checked, instead of relying on -e to abort
# invisibly.
listing_raw="${slug}-restore-listing-raw.txt"
listing_norm="${slug}-restore-listing.txt"
set +e
tar tzf "$local_file" > "$listing_raw"
tar_status=$?
set -e
echo "tar tzf exit status: ${tar_status}"
if [ "$tar_status" -ne 0 ]; then
  echo "ERROR: ${local_file} failed the 'tar tzf' integrity check (exit ${tar_status}) — corrupt or truncated. NOT touching the live world; pick a different backup." >&2
  exit 1
fi
echo "Integrity check passed (tar tzf)"

# --- 4. Confirm it is the RIGHT world ---------------------------------------
# Normalise a leading './' some tar implementations emit so a whole-line match
# still lands, then require the exact world files, literally and on the whole
# line. `-F` (literal, not regex) and `-x` (whole line) together are mandatory:
# a plain `grep -q` treats <world> as a REGEX and matches SUBSTRINGS, so a world
# named "World.1" would have its "." match any character and match as a
# substring of "WorldX1.db" from a different server's archive — and step 6
# would then delete the live world under a false positive.
sed 's#^\./##' "$listing_raw" > "$listing_norm"

# What worlds does this archive actually hold? Reported unconditionally, because
# "does not contain X" is a far less useful error than "does not contain X, it
# contains Y" — the second tells you either that you grabbed the wrong file or
# that the world you want is named something else. Excludes Valheim's own
# rotations (.db.old) and odin's timestamped autobackup copies, which are the
# same world under decorated names and would otherwise pad the list.
# awk, not `grep -v`: grep exits 1 when it selects nothing, and under
# `set -euo pipefail` that aborts here — so an archive containing no live worlds
# would kill the script instead of reaching the "found: no worlds at all" error
# below, which is precisely the message that case needs. awk exits 0 on empty.
# Matches the TIMESTAMP, not the word "backup". Valheim writes point-in-time
# copies in two forms, both ending in digits:
#     <World>_backup_auto-20260815120940     (odin's schedule)
#     <World>_backup_20260206-235715         (manual / version upgrade)
# Matching only the first made a real legacy archive report three worlds where it
# held one; matching a bare `_backup_` substring would instead hide a world
# someone legitimately called `World_backup_legacy`, which create-server.sh's
# allowlist permits. Anchoring on trailing digits catches exactly the copies.
archive_worlds="$(sed -n 's#^worlds_local/\([^/]*\)\.db$#\1#p' "$listing_norm" \
  | awk '!(/_backup_auto-[0-9]+$/ || /_backup_[0-9]+-[0-9]+$/)' | sort -u | tr '\n' ' ')"
echo "Worlds present in archive: ${archive_worlds:-(none)}"

if ! grep -Fqx -- "worlds_local/${world}.db" "$listing_norm" \
   || ! grep -Fqx -- "worlds_local/${world}.fwl" "$listing_norm"; then
  echo "ERROR: this archive does not contain world '${world}'." >&2
  echo "  wanted: worlds_local/${world}.db and worlds_local/${world}.fwl" >&2
  echo "  found:  ${archive_worlds:-no worlds at all}" >&2
  echo "  NOT touching the live world." >&2
  echo "" >&2
  echo "  If the archive holds the world you want under a different name, that is a" >&2
  echo "  RENAME, not a restore — Valheim loads whatever the Deployment's WORLD env" >&2
  echo "  says, so extracting a differently-named world here would leave those files" >&2
  echo "  unused and generate a fresh '${world}' instead. Set WORLD to the name above" >&2
  echo "  in the instance's overlay, apply it, let the pod restart, then re-run this." >&2
  exit 1
fi
echo "World match confirmed: worlds_local/${world}.db and .fwl both present in archive"

# --- 4b. Confirm the LIVE instance is the one we think it is ---------------
# Everything above validated the ARCHIVE. Nothing yet has checked that the
# cluster/namespace we are pointed at actually holds this instance — and the
# context we resolved above may simply be wrong. Reading WORLD off the live
# Deployment closes that gap: on the wrong cluster the Deployment is absent, and
# on the wrong namespace (or a namespace that was recycled for a different
# instance) WORLD won't match. Both abort here, while the live world is still
# untouched. Without this, a stale kubectl context plus a valid archive is
# sufficient to destroy an unrelated server's save.
live_world="$(kctl get deployment valheim -n "$ns" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="valheim-server")].env[?(@.name=="WORLD")].value}' 2>/dev/null || true)"
if [ -z "$live_world" ]; then
  echo "ERROR: no deployment/valheim with a WORLD env in namespace '${ns}' on context '${KUBE_CONTEXT}'." >&2
  echo "  Wrong cluster or wrong namespace — refusing to restore. Nothing was touched." >&2
  exit 1
fi
if [ "$live_world" != "$world" ]; then
  echo "ERROR: live instance in '${ns}' is running world '${live_world}', but this restore targets '${world}'." >&2
  echo "  Nothing was touched." >&2
  echo "" >&2
  echo "  Two different intentions end up here, and they have different fixes:" >&2
  echo "" >&2
  echo "  1. You aimed at the wrong server. '${ns}' hosts '${live_world}'. Re-run with" >&2
  echo "     the namespace of the instance that actually runs '${world}'." >&2
  echo "" >&2
  echo "  2. You want THIS server to become '${world}'. A restore cannot do that on" >&2
  echo "     its own: Valheim loads whatever the Deployment's WORLD env says, so the" >&2
  echo "     extracted files would sit unused while it regenerated '${live_world}'." >&2
  echo "     Set WORLD='${world}' in the instance's overlay (instance-patch.yaml)," >&2
  echo "     apply it, let the pod restart, and then re-run this restore. Note the" >&2
  echo "     old world's files stay on the PVC beside the new ones — see docs/restore.md" >&2
  echo "     on why two worlds in one directory is worth cleaning up." >&2
  exit 1
fi
echo "Live instance confirmed: ${ns} on ${KUBE_CONTEXT} is running world '${live_world}'"

# --- 5. Scale the deployment to 0 and wait for the pod to be gone ----------
# Releases the RWO volumes so the helper pod below can mount them. Everything
# above this line is read-only against the cluster — this is the first step
# that touches the live instance, and only validated input reaches it.
prev_replicas="$(kctl get deployment valheim -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
# Treat 0 as 1, not as "the state to return to". A restore exists to leave a
# RUNNING server holding the restored world, and the commonest way to find a
# deployment already at 0 is that a previous restore attempt failed and left it
# there — faithfully restoring 0 then makes a successful retry look like another
# failure, with the world correctly in place and nobody able to connect. It also
# means two failed attempts in a row can never recover on their own. An operator
# who deliberately wants it down can scale down after.
case "${prev_replicas:-0}" in
  ''|0) prev_replicas=1 ;;
esac
echo "Scaling deployment/valheim to 0 in ${ns} (was ${prev_replicas})..."
destructive_started=1
kctl scale deployment valheim -n "$ns" --replicas=0
kctl wait pod -l app=valheim -n "$ns" --for=delete --timeout=180s
echo "Pod gone — volumes released"

# --- 6. Helper pod: stage the old world aside, extract, verify, swap -------
# If the Ready wait inside start_helper times out, the previous attachment is
# probably still releasing (see docs/restore.md) — rerun the job rather than
# assuming the restore itself has failed; nothing destructive has happened yet.
start_helper

kctl cp "$local_file" "${ns}/${helper}:/tmp/restore.tar.gz"

# A PRISTINE instance has no worlds_local at all — Valheim creates it on first
# save, so a server deployed minutes ago and never played has only the player
# lists its init container copied. Restoring onto exactly such an instance is the
# headline use case (revive an old world on a new server), and an unconditional
# `ls` here fails under `set -e` and aborts the restore before it starts. That is
# how the twinhenge migration failed: nothing was wrong with the archive or the
# target, only with this assumption.
# Ask for the answer as OUTPUT rather than as an exit status. `kctl exec -- test
# -d` returns 1 both when the directory is absent AND when the exec itself fails,
# and those must not be conflated: treating a failed exec as "no world here" sends
# an instance that HAS a world down the pristine path, whose recovery deletes
# worlds_local. Printing EXISTS/ABSENT makes an unreachable helper produce
# neither, so it is caught below instead of guessed at.
world_state="$(kctl exec "$helper" -n "$ns" -- sh -c \
  'if [ -d /world/worlds_local ]; then echo EXISTS; else echo ABSENT; fi' 2>/dev/null \
  | tr -d '\r' | tail -1)"

case "$world_state" in
  EXISTS)
    # Recorded BEFORE anything else can fail. `staged` says the move completed;
    # this says a world was there at all. Conflating them is what let a failure
    # between the two look like "the PVC was empty".
    world_existed=1
    echo "Existing world on the PVC, last look before it is staged aside:"
    kctl exec "$helper" -n "$ns" -- ls -la /world/worlds_local

    # The old world is MOVED, not deleted. `tar tzf` in step 3 proved the archive
    # can be LISTED; it does not prove extraction can write every file to this PVC
    # — a full volume or an I/O error fails mid-extract. Deleting first and
    # extracting second means such a failure destroys the only copy, and `set -e`
    # then exits with the world already gone. A rename is atomic, cheap (same
    # filesystem), and leaves a complete copy to fall back to.
    # A leftover worlds_local.rollback is NOT junk to clear — it is the original
    # world from an attempt that staged it aside and never put it back. Blindly
    # `rm -rf`ing it here, as this once did, destroys the last good copy and then
    # promotes whatever the failed attempt left behind (possibly a partial
    # extraction) into its place. Retrying a failed restore would quietly consume
    # the very thing the staging exists to preserve.
    rollback_state="$(kctl exec "$helper" -n "$ns" -- sh -c \
      'if [ -d /world/worlds_local.rollback ]; then echo EXISTS; else echo ABSENT; fi' 2>/dev/null \
      | tr -d '\r' | tail -1)"
    if [ "$rollback_state" != "ABSENT" ]; then
      echo "ERROR: /world/worlds_local.rollback already exists in ${ns}." >&2
      if [ "$rollback_state" = "EXISTS" ]; then
        echo "  That is the ORIGINAL world from an earlier restore that did not finish" >&2
        echo "  putting it back. Overwriting it would destroy the last good copy." >&2
      else
        echo "  Could not determine whether it exists (got '${rollback_state}'), and" >&2
        echo "  proceeding risks overwriting an original that may be sitting there." >&2
      fi
      echo "" >&2
      echo "  Resolve it by hand before retrying — inspect both directories:" >&2
      echo "    kubectl --context ${KUBE_CONTEXT} exec ${helper} -n ${ns} -- ls -la /world/worlds_local /world/worlds_local.rollback" >&2
      echo "  If .rollback is the world you want, move it back over worlds_local." >&2
      echo "  If worlds_local is already correct, delete .rollback and re-run." >&2
      exit 1
    fi

    kctl exec "$helper" -n "$ns" -- mv /world/worlds_local /world/worlds_local.rollback
    staged=1
    echo "Previous world staged at /world/worlds_local.rollback"
    ;;
  ABSENT)
    # Only here — after a definitive ABSENT, not merely a non-zero exit — is it
    # safe for recovery to delete worlds_local, because we know there was none.
    pristine_confirmed=1
    echo "No existing world on this PVC — the instance has never saved one."
    echo "  Nothing to stage: a failure from here leaves it as empty as it started,"
    echo "  so there is no rollback copy to keep and none is needed."
    ;;
  *)
    echo "ERROR: could not determine whether ${ns} already has a world." >&2
    echo "  Expected EXISTS or ABSENT from the helper; got: '${world_state}'" >&2
    echo "  Refusing to continue: every safe path from here depends on knowing" >&2
    echo "  which of the two it is. Nothing on the PVC has been touched." >&2
    exit 1
    ;;
esac

kctl exec "$helper" -n "$ns" -- tar xzf /tmp/restore.tar.gz -C /world

# Extraction reporting success is still not proof the world is usable: verify
# the two files Valheim actually needs are present and non-empty. Without this
# a truncated-but-exit-0 extract would be swapped in and the rollback deleted.
kctl exec "$helper" -n "$ns" -- sh -c "test -s '/world/worlds_local/${world}.db'"
kctl exec "$helper" -n "$ns" -- sh -c "test -s '/world/worlds_local/${world}.fwl'"
echo "Extracted world verified: ${world}.db and ${world}.fwl both present and non-empty"

# Only now is the old copy expendable — and only if there was one.
if [ "$staged" -eq 1 ]; then
  kctl exec "$helper" -n "$ns" -- rm -rf /world/worlds_local.rollback
  echo "Rollback copy removed — restore committed"
else
  echo "Restore committed (no prior world to discard)"
fi

kctl delete pod "$helper" -n "$ns"
echo "Helper pod cleaned up"

# --- 7. Scale back to the replica count we found -----------------------------
kctl scale deployment valheim -n "$ns" --replicas="$prev_replicas"
echo "Scaled deployment/valheim back to ${prev_replicas} in ${ns}"
# Past this point there is nothing left to roll back, and the trap must not
# undo a completed restore.
destructive_started=0

# --- 8. How to verify — the step that actually matters -----------------------
# A restore that silently produces a FRESH world looks identical to success
# from outside unless someone checks for exactly this.
cat <<EOF

Restore submitted. Verify it actually took:

  kubectl --context ${KUBE_CONTEXT} logs deployment/valheim -n ${ns} --tail=50

The log should show:  Load world: ${world}
with NO following:    ... missing .../${world}.db ...
That "missing" line means Valheim generated a brand-new empty world instead of
loading the restored one — if you see it, the restore did not take.

Then join the server and confirm a known object placed before the backup is
actually there.
EOF
