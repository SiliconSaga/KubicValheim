# What names a world

Restoring a save onto a server is mostly a question of names lining up. This page is the part to get right *before* running [restore.md](restore.md), because the failure mode is quiet: Valheim will happily generate a fresh empty world and look, from outside, exactly like a successful restore.

## The world name has to match

Valheim loads whatever the Deployment's `WORLD` env var names. A server configured for a different name ignores restored files and generates an empty world beside them.

So reviving an old world on a new server means creating the instance with the world's **original** name (`WORLD` in the overlay's `instance-patch.yaml`), and only then running the restore.

Renaming an existing server's world is a *different* operation: change `WORLD`, apply, let the pod restart, and restore after that. A restore alone cannot rename anything.

## If you no longer remember the name, the archive knows

Worlds are stored as `worlds_local/<World>.db`, so the archive can be read without a cluster or a running server:

```bash
scripts/inspect-archive.sh https://storage.googleapis.com/kubic-game-hosting/valheim/<slug>/<ts>/<slug>-<ts>.tar.gz
```

It prints the world names the archive contains and touches nothing — so it works for someone holding only a link.

## Accepted inputs

Both the restore job and the inspector take exactly three forms, and reject anything else rather than fetching it:

- a `gs://` path
- a public link of the form `https://storage.googleapis.com/<bucket>/<path>` (the form the backup job prints)
- a local file

Archives are **`.tar.gz`**, not zip.

## Renaming the files does not rename the world

Valheim stores a world's own name inside the `.fwl`, separate from the filename, and logs both:

```text
Load world: <internal name> (<filename>)
```

The `twinhenge` instance was migrated by renaming `Dedicated.db` / `.fwl` to `twinhenge.*`, and it still logs `Load world: DualCircleCoastalBFs (twinhenge)`. Only the filename — which is what `WORLD` selects — changed.

That mismatch is harmless, and it is useful evidence: an internal name that survives a rename proves the save is genuinely the old world rather than a regenerated one.

## Cross-instance restore is supported

Any readable archive is a valid input. Pointing the restore job at another server's published link is a deliberate workflow, not an accident — it is much of the reason those links are published. What gets checked is that the archive matches the world *this instance is configured for*, not where the archive came from.

## Building an archive by hand on macOS

Set `COPYFILE_DISABLE=1`.

BSD `tar` bundles extended attributes as `._<name>` AppleDouble companions, so a repack on a Mac silently adds `._twinhenge.db` and friends. Valheim ignores them, but they land on the PVC and then propagate into every subsequent backup of that instance.
