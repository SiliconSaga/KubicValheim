# Restoring a Valheim world from a GCS backup

The world lives on the `valheim-data` PVC. Restoring means stopping the server, replacing the world files, and starting it again.

> **A restore that silently produces a FRESH world looks identical to success from outside.** Always verify against a specific known object placed in-world before the backup — not merely that the server started.

## 1. Pick the backup

    gsutil ls gs://kubic-game-hosting/valheim/<slug>/

Choose a timestamp and download it:

    gsutil cp gs://kubic-game-hosting/valheim/<slug>/<ts>/<slug>-<ts>.tar.gz .

## 2. Stop the server

Releases the RWO volumes so another pod can mount them.

    ws k8s scale deployment valheim -n <ns> --replicas=0
    ws k8s wait pod -l app=valheim -n <ns> --for=delete --timeout=180s

## 3. Replace the world files

Start a throwaway pod mounting the world PVC, copy the tarball in, and extract it over the world dir. The archive is rooted at the Valheim config dir, so extract with `-C` pointing at the mount. Pod deletion isn't the same as the volume actually detaching, so if the helper pod times out waiting to become Ready, the previous attachment is probably still releasing — wait ~30s and retry rather than assuming the restore has failed.

**Clear the existing saves first.** `tar x` overwrites what the archive names and leaves everything else in place, so extracting an OLDER backup over a NEWER world strands the newer `.db` / `.fwl` / `.old` files beside the restored ones. Valheim then has two worlds in the directory and can happily load the wrong one — a restore that looks clean and isn't. Only the save dir goes; the player lists are re-copied by the init container on every start.

    ws k8s run restore-helper -n <ns> --image=busybox:1.36 --restart=Never --overrides='{"spec":{"containers":[{"name":"restore-helper","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"name":"world","mountPath":"/world"}]}],"volumes":[{"name":"world","persistentVolumeClaim":{"claimName":"valheim-data"}}]}}'
    ws k8s wait pod restore-helper -n <ns> --for=condition=Ready --timeout=120s
    ws k8s exec restore-helper -n <ns> -- ls -la /world/worlds_local
    ws k8s exec restore-helper -n <ns> -- rm -rf /world/worlds_local
    ws k8s cp <slug>-<ts>.tar.gz <ns>/restore-helper:/tmp/restore.tar.gz
    ws k8s exec restore-helper -n <ns> -- tar xzf /tmp/restore.tar.gz -C /world
    ws k8s delete pod restore-helper -n <ns>

The `ls` before the `rm` is not decoration: it is the last chance to read what you are about to delete, and there is no undo on a PVC.

## 4. Start the server

    ws k8s scale deployment valheim -n <ns> --replicas=1

## 5. Verify — the step that actually matters

Watch for the world load, and confirm it is NOT generating a fresh one:

    ws k8s logs deployment/valheim -n <ns> --tail=50

A restored world logs `Load world: <World>` **without** a following `missing .../<World>.db` line. That "missing" line means it created a new empty world — the restore did not take.

Then join the server and confirm the known object is present.
