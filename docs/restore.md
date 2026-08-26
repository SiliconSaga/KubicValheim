# Restoring a Valheim world from a GCS backup

The world lives on the `valheim-data` PVC. Restoring means stopping the server, replacing the world files, and starting it again.

> **A restore that silently produces a FRESH world looks identical to success from outside.** Always verify against a specific known object placed in-world before the backup — not merely that the server started.

> **Prefer the Jenkins job.** `scripts/restore-server.sh` (run by the per-instance *Restore server (DESTRUCTIVE)* job) performs every step below plus guards this manual path cannot enforce: it pins an explicit kubectl context, refuses an archive belonging to another instance, checks the live Deployment's `WORLD` matches, and on any failure restores the staged world and the previous replica count automatically. Use this runbook to understand what the script does, or when Jenkins is unavailable — and when following it manually, **pass `--context` on every command**, because `ws k8s` uses the armed guard scope while a bare `kubectl` inherits whatever `current-context` happens to be, which on a workstation is regularly the wrong cluster.

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

**Readable is not the same as correct.** `tar tzf` proves the archive is a valid, uncorrupted tarball — it says nothing about *which world* is inside it. An archive from a different instance (wrong `<slug>`, or the right slug but grabbed from the wrong bucket path) would pass `tar tzf` cleanly, and clearing `worlds_local` and extracting it would then restore a world nobody asked for, onto an instance that no longer has its own world to fall back to. So after the readability check, also confirm the listing actually names *this* instance's world files before anything is cleared — grep it for `worlds_local/<WORLD>.db` and `worlds_local/<WORLD>.fwl`, where `<WORLD>` is the world name this instance is configured with (from its overlay's `instance-patch.yaml`, or `NAME`/`WORLD` in the running pod's env). If either is missing, **STOP** — do not proceed to the `rm -rf` below. The world on the PVC is still intact; go pick the correct archive instead.

**Keep `tar tzf` on its own line — do not pipe it into `sed`.** A pipeline's exit status is the *last* command's, so `tar tzf … | sed …` reports `sed`'s success and silently swallows a tar failure. A truncated archive that manages to list the world files before it dies would then satisfy both greps below, and the `rm -rf` would go ahead against a corrupt backup. Running tar on its own line keeps its exit status visible, and it must be `0` before you continue.

**Match those names exactly — `grep -Fqx`, not `grep -q`.** A plain `grep -q` treats the world name as a *regular expression* and matches *substrings*, which in this specific procedure is a data-loss bug: a world configured as `World.1` would have its `.` match any character and its pattern match as a substring, so a wrong archive containing `WorldX1.db` would satisfy the check, the `rm -rf` would delete the correct save, and the wrong world would be extracted over it. `-F` takes the pattern literally, `-x` requires the whole line to match, and the `sed` normalises the optional leading `./` that some tar implementations emit so a whole-line match still lands.

**Clear the existing saves — but only after validation.** `tar x` overwrites what the archive names and leaves everything else in place, so extracting an OLDER backup over a NEWER world strands the newer `.db` / `.fwl` / `.old` files beside the restored ones. Valheim then has two worlds in the directory and can happily load the wrong one — a restore that looks clean and isn't. Only the save dir goes; the player lists are re-copied by the init container on every start. The `ls` before the `rm` is the last chance to read what you are about to delete, and there is no undo on a PVC.

    ws k8s run restore-helper -n <ns> --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"restore-helper","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"world","mountPath":"/world"}]}],"volumes":[{"name":"world","persistentVolumeClaim":{"claimName":"valheim-data"}}]}}'
    ws k8s wait pod restore-helper -n <ns> --for=condition=Ready --timeout=120s
    ws k8s cp <slug>-<ts>.tar.gz <ns>/restore-helper:/tmp/restore.tar.gz
    ws k8s exec restore-helper -n <ns> -- tar tzf /tmp/restore.tar.gz > /tmp/restore-listing-raw.txt
    echo "tar exit status: $?"    # MUST be 0 — if not, STOP, the archive is bad
    sed 's#^\./##' /tmp/restore-listing-raw.txt > /tmp/restore-listing.txt
    grep -Fqx -- "worlds_local/<WORLD>.db"  /tmp/restore-listing.txt
    grep -Fqx -- "worlds_local/<WORLD>.fwl" /tmp/restore-listing.txt
    ws k8s exec restore-helper -n <ns> -- ls -la /world/worlds_local
    ws k8s exec restore-helper -n <ns> -- sh -c 'rm -rf /world/worlds_local.rollback && mv /world/worlds_local /world/worlds_local.rollback'
    ws k8s exec restore-helper -n <ns> -- tar xzf /tmp/restore.tar.gz -C /world
    ws k8s exec restore-helper -n <ns> -- sh -c "test -s '/world/worlds_local/<WORLD>.db'"
    ws k8s exec restore-helper -n <ns> -- sh -c "test -s '/world/worlds_local/<WORLD>.fwl'"
    ws k8s exec restore-helper -n <ns> -- rm -rf /world/worlds_local.rollback
    ws k8s delete pod restore-helper -n <ns>

**Move the old world aside; do not delete it first.** `tar tzf` above proved the archive can be *listed* — it did not prove that extraction can *write* every file to this PVC. A full volume or an I/O error fails partway, and if the old world was already deleted, the only copy is gone. A rename is atomic and free (same filesystem), so the previous world stays intact under `worlds_local.rollback` until the replacement is proven good. The two `test -s` checks are that proof: `tar xzf` exiting 0 is not sufficient evidence that the files Valheim needs are present and non-empty.

**If anything above fails, roll back BEFORE restarting the server.** Put the old world back, and only then scale up:

    ws k8s exec restore-helper -n <ns> -- sh -c 'rm -rf /world/worlds_local; mv /world/worlds_local.rollback /world/worlds_local'
    ws k8s exec restore-helper -n <ns> -- sh -c "test -s '/world/worlds_local/<WORLD>.db'"   # MUST pass before step 4

If that check does not pass, **leave the deployment at zero replicas**. A stopped server is loud and recoverable; a running server with no world generates a fresh one and overwrites the evidence.

## 4. Start the server

    ws k8s scale deployment valheim -n <ns> --replicas=1

## 5. Verify — the step that actually matters

Watch for the world load, and confirm it is NOT generating a fresh one:

    ws k8s logs deployment/valheim -n <ns> --tail=50

A restored world logs `Load world: <World>` **without** a following `missing .../<World>.db` line. That "missing" line means it created a new empty world — the restore did not take.

Then join the server and confirm the known object is present.
