# Restoring a Valheim world from a GCS backup

The world lives on the `valheim-data` PVC. Restoring means stopping the server, replacing the world files, and starting it again.

**Read [world-identity.md](world-identity.md) first** if the archive came from a different instance, or if you are not certain which world is inside it. The name the instance is configured for has to match the name in the archive before the world files are cleared or extracted — inspecting and listing an archive is safe regardless — and getting that wrong produces a fresh empty world rather than an error.

> **A restore that silently produces a FRESH world looks identical to success from outside.** Always verify against a specific known object placed in-world before the backup — not merely that the server started.

> **Prefer the Jenkins job.** `scripts/restore-server.sh` (run by the per-instance *Restore server (DESTRUCTIVE)* job) performs every step below plus guards this manual path cannot enforce: it pins an explicit kubectl context, checks the live Deployment's `WORLD` matches, and on failure restores the staged world and the previous replica count automatically — **with one deliberate exception: if it cannot verify the world is back in place, it leaves the Deployment at zero replicas** rather than restarting a server with no world for it to load, since Valheim would generate a fresh one and overwrite the evidence. A restore that ends with the server still down is reporting that it could not recover, not that it forgot to. Use this runbook to understand what the script does, or when Jenkins is unavailable — and when following it manually, **pass `--context` on every command**, because `ws k8s` uses the armed guard scope while a bare `kubectl` inherits whatever `current-context` happens to be, which on a workstation is regularly the wrong cluster.

## 1. Pick the backup

    gsutil ls gs://kubic-game-hosting/valheim/<slug>/

Choose a timestamp and download it:

    gsutil cp gs://kubic-game-hosting/valheim/<slug>/<ts>/<slug>-<ts>.tar.gz .

## 2. Stop the server

Releases the RWO volumes so another pod can mount them.

    ws k8s scale deployment valheim -n <ns> --replicas=0
    ws k8s wait pod -l app=valheim -n <ns> --for=delete --timeout=180s

## 3. Replace the world files

Start a throwaway pod mounting the world PVC, copy the tarball in, verify it's actually readable, and only then clear the world dir and extract over it. The archive is rooted at the Valheim config dir, so extract with `-C` pointing at the mount. Pod deletion isn't the same as the volume actually detaching, so if the helper pod times out waiting to become Ready, the previous attachment is probably still releasing — wait ~30s and retry rather than assuming the restore has failed.

**Copy and validate before destroying anything.** The order below matters: the archive is copied in and proven readable with a non-destructive `tar tzf` listing *before* the existing world is touched. If the archive is truncated or corrupt, `tar tzf` fails, the world on the PVC is still completely intact, and you can pick a different backup and try again — a bad backup costs you nothing. Only once the archive has passed that check does the world dir get cleared.

**Restoring across instances is supported.** Any readable archive is a valid input — pasting the public link to some other server's world tarball into the restore job is a deliberate workflow, which is much of the point of publishing those links. What is checked is that the archive matches the world this instance is *configured for*, not where the archive came from. So to revive an old world on a fresh server, set that server's `WORLD` to the old world's name and point the job at the `.tar.gz`.

**Readable is not the same as correct.** `tar tzf` proves the archive is a valid, uncorrupted tarball — it says nothing about *which world* is inside it. An archive containing a different world would pass `tar tzf` cleanly, and clearing `worlds_local` and extracting it would then restore a world nobody asked for, onto an instance that no longer has its own world to fall back to. So after the readability check, also confirm the listing actually names *this* instance's world before anything is cleared, where `<WORLD>` is the world name this instance is configured with (from its overlay's `instance-patch.yaml`, or `NAME`/`WORLD` in the running pod's env). An archive holds the world in one of two layouts — see [world-identity.md](world-identity.md) — so grep for **either** `worlds_local/<WORLD>.db` plus `worlds_local/<WORLD>.fwl` (before Valheim 1.0) **or** `worlds_local/<WORLD>/_main.<N>.fwl2` plus `.db2` (1.0 and later). If neither pair is complete, **STOP** — do not proceed to the `rm -rf` below. The world on the PVC is still intact; go pick the correct archive instead. `scripts/inspect-archive.sh <archive>` does this classification for you.

**Keep `tar tzf` on its own line — do not pipe it into `sed`.** A pipeline's exit status is the *last* command's, so `tar tzf … | sed …` reports `sed`'s success and silently swallows a tar failure. A truncated archive that manages to list the world files before it dies would then satisfy both greps below, and the `rm -rf` would go ahead against a corrupt backup. Running tar on its own line keeps its exit status visible, and it must be `0` before you continue.

**Match the name exactly, and never as a pattern.** `archive_has_world` compares whole lines literally (`grep -Fqx` for the legacy pair, a literal-prefix match for the 1.0 directory) and requires the `.fwl2` and `.db2` to share one save number. A hand-rolled `grep -q` would treat the world name as a *regular expression* and match *substrings*, which in this specific procedure is a data-loss bug: a world configured as `World.1` would have its `.` match any character, so a wrong archive containing `WorldX1.db` would satisfy the check, the `rm -rf` would delete the correct save, and the wrong world would be extracted over it. The `sed` normalises the optional leading `./` that some tar implementations emit so a whole-line match still lands.

**Clear the existing saves — but only after validation.** `tar x` overwrites what the archive names and leaves everything else in place, so extracting an OLDER backup over a NEWER world strands the newer `.db` / `.fwl` / `.old` files beside the restored ones. Valheim then has two worlds in the directory and can happily load the wrong one — a restore that looks clean and isn't. Only the save dir goes; the player lists are re-copied by the init container on every start. The `ls` before the `rm` is the last chance to read what you are about to delete, and there is no undo on a PVC.

    ws k8s run restore-helper -n <ns> --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"restore-helper","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"world","mountPath":"/world"}]}],"volumes":[{"name":"world","persistentVolumeClaim":{"claimName":"valheim-data"}}]}}'
    ws k8s wait pod restore-helper -n <ns> --for=condition=Ready --timeout=120s
    ws k8s cp <slug>-<ts>.tar.gz <ns>/restore-helper:/tmp/restore.tar.gz
    ws k8s exec restore-helper -n <ns> -- tar tzf /tmp/restore.tar.gz > /tmp/restore-listing-raw.txt
    echo "tar exit status: $?"    # MUST be 0 — if not, STOP, the archive is bad
    sed 's#^\./##' /tmp/restore-listing-raw.txt > /tmp/restore-listing.txt
    # either layout, one COMPLETE pair — legacy .db + .fwl, or _main.<N>.fwl2 + .db2 with the same <N>
    . scripts/lib/world-files.sh
    archive_has_world /tmp/restore-listing.txt '<WORLD>'   # MUST exit 0 — if not, STOP, wrong archive
    ws k8s exec restore-helper -n <ns> -- ls -la /world/worlds_local
    ws k8s exec restore-helper -n <ns> -- sh -c 'rm -rf /world/worlds_local.rollback && mv /world/worlds_local /world/worlds_local.rollback'
    ws k8s exec restore-helper -n <ns> -- tar xzf /tmp/restore.tar.gz -C /world
    # verify the extracted world in whichever layout the archive carried
    ws k8s exec restore-helper -n <ns> -- sh -c "$WORLD_PRESENT_SH" sh /world/worlds_local '<WORLD>'
    ws k8s exec restore-helper -n <ns> -- rm -rf /world/worlds_local.rollback
    ws k8s delete pod restore-helper -n <ns>

**Move the old world aside; do not delete it first.** `tar tzf` above proved the archive can be *listed* — it did not prove that extraction can *write* every file to this PVC. A full volume or an I/O error fails partway, and if the old world was already deleted, the only copy is gone. A rename is atomic and free (same filesystem), so the previous world stays intact under `worlds_local.rollback` until the replacement is proven good. The layout check is that proof: `tar xzf` exiting 0 is not sufficient evidence that the files Valheim needs are present and non-empty. The check is the same `WORLD_PRESENT_SH` the scripts use, sourced from `scripts/lib/world-files.sh` so the manual path and the job cannot disagree about what "present" means.

**If anything above fails, roll back BEFORE restarting the server.** Put the old world back, and only then scale up. The swap is guarded on the rollback copy existing: a failure *before* the staging `mv` ran has nothing to undo, and an unguarded `rm -rf /world/worlds_local` at that point would delete the intact world with nothing to put back.

    ws k8s exec restore-helper -n <ns> -- sh -c 'if [ -d /world/worlds_local.rollback ]; then rm -rf /world/worlds_local && mv /world/worlds_local.rollback /world/worlds_local; else echo "no rollback copy — the live world was never staged aside, leave it"; fi'
    ws k8s exec restore-helper -n <ns> -- sh -c "$WORLD_PRESENT_SH" sh /world/worlds_local '<WORLD>'   # MUST pass before step 4

If that check does not pass, **leave the deployment at zero replicas**. A stopped server is loud and recoverable; a running server with no world generates a fresh one and overwrites the evidence.

## 4. Start the server

    ws k8s scale deployment valheim -n <ns> --replicas=1

## 5. Verify — the step that actually matters

Watch the world load:

    ws k8s logs deployment/valheim -n <ns> --tail=50

Before Valheim 1.0 a restored world logged `Load world: <World>` and a fresh one added a `missing .../<World>.db` line, so the log settled it. **1.0 logs `Get create world <World>` in both cases**, so the log no longer distinguishes a restore that took from one that did not. The layout check in step 3 is the mechanical proof, and a legacy archive being converted to the 1.0 directory on this boot is expected.

Then join the server and confirm the known object is present — that is the check that cannot be fooled.
