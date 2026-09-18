# What names a world

Restoring a save onto a server is mostly a question of names lining up. This page is the part to get right *before* running [restore.md](restore.md), because the failure mode is quiet: Valheim will happily generate a fresh empty world and look, from outside, exactly like a successful restore.

## The world name has to match

Valheim loads whatever the Deployment's `WORLD` env var names. A server configured for a different name ignores restored files and generates an empty world beside them.

So reviving an old world on a new server means creating the instance with the world's **original** name (`WORLD` in the overlay's `instance-patch.yaml`), and only then running the restore.

Renaming an existing server's world is a *different* operation: change `WORLD`, apply, let the pod restart, and restore after that. A restore alone cannot rename anything.

## Two layouts, one name

Valheim 1.0 (September 2026) changed how a world is stored on disk, and both shapes are in circulation at once:

| | Before 1.0 | 1.0 and later |
|---|---|---|
| World | `worlds_local/<World>.db` | `worlds_local/<World>/` holding `*.chunk` files plus `_main.<N>.db2` |
| Seed and metadata | `worlds_local/<World>.fwl` | `worlds_local/<World>/_main.<N>.fwl2` (with `_main.<N>.chunks` and `_main.<N>.ok`) |
| Point-in-time copies | `<World>_backup_auto-<ts>.db` / `.fwl` | `<World>_backup_auto-<ts>/` directories |

`<N>` is the save number and climbs by one per save. The first boot on 1.0 converts a legacy world in place: the old pair becomes `<World>.db.old` / `.fwl.old`, a `<World>_backup_<ts>.db` / `.fwl` copy is taken first, and the directory takes over from then on.

Every running instance has converted, while every archive uploaded before the conversion — and any archive a player hands back from an older server — is still the flat pair. Restoring a legacy archive onto a 1.0 server is fine and is the normal way to revive an old world: the server converts it on boot. The lifecycle scripts accept either layout by name, through one shared check in `scripts/lib/world-files.sh`, and `tests/world-files.sh` exercises both.

Iron Gate has published no description of the directory. The file names above are read off a live save and match community reports, so the scripts assert the least a loadable world must have — a non-empty `.fwl2` with its matching non-empty `.db2` — rather than every file seen today.

## If you no longer remember the name, the archive knows

Worlds are stored under their name — `worlds_local/<World>.db` or `worlds_local/<World>/` — so the archive can be read without a cluster or a running server:

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

Valheim stores a world's own name inside the `.fwl` (now `.fwl2`), separate from the file or directory name. Before 1.0 it logged both:

```text
Load world: <internal name> (<filename>)
```

The `twinhenge` instance was migrated by renaming `Dedicated.db` / `.fwl` to `twinhenge.*`, and it logged `Load world: DualCircleCoastalBFs (twinhenge)`. Only the filename — which is what `WORLD` selects — changed.

That mismatch is harmless, and it was useful evidence: an internal name that survives a rename proves the save is genuinely the old world rather than a regenerated one. **1.0 dropped that line.** The server now logs `Get create world <World>` followed by `SaveSystem.Reload for World is done` whether it loaded the world or created a fresh one, and the old `missing .../<World>.db` tell for a fresh world is gone with it. What remains is the file check the scripts run, and a known object confirmed in-game.

## Cross-instance restore is supported

Any readable archive is a valid input. Pointing the restore job at another server's published link is a deliberate workflow, not an accident — it is much of the reason those links are published. What gets checked is that the archive matches the world *this instance is configured for*, not where the archive came from.

## Building an archive by hand on macOS

Set `COPYFILE_DISABLE=1`.

BSD `tar` bundles extended attributes as `._<name>` AppleDouble companions, so a repack on a Mac silently adds `._twinhenge.db` and friends. Valheim ignores them, but they land on the PVC and then propagate into every subsequent backup of that instance.
