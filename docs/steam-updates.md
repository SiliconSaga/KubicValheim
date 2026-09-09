# Game updates, and the one that needs a hand

odin updates the game from Steam on every pod start (`UPDATE_ON_STARTUP=1`), so a normal Valheim patch needs nothing from you: roll the pod, SteamCMD pulls the new build, the server comes back. This page is about the case where that loop cannot recover on its own.

## The failure

A big release day is the usual trigger. Steam's content servers are saturated, SteamCMD cannot resolve the new depot manifest, and the update fails:

```
Error! App '896660' state is 0x6 after update job.
ERROR odin::server::install: steamcmd exited with code: 8
```

odin retries three times (5s then 10s) and then exits, so the container dies and Kubernetes backs it off. The pod sits in `CrashLoopBackOff` and the server is down.

**The part that does not fix itself:** when an update fails, SteamCMD writes the failure into `steamapps/appmanifest_896660.acf` on the game volume — `StateFlags 6` and `UpdateResult 6`. On the next run it reads that state and aborts in tens of seconds *without attempting a download at all*. Every subsequent restart then fails the same way for a reason that has nothing to do with whether Steam has recovered. Waiting does not clear it.

This is why two instances hit by the same outage can end up in different places: one whose retry happened to break through is fine, and one whose retry did not is stuck until someone clears the manifest.

## Confirming it

Read the manifest on the game volume. The signature is a `buildid` that disagrees with `TargetBuildID`, alongside the poisoned flags:

```
"buildid"          "21981590"     <- what is installed
"TargetBuildID"    "25185644"     <- what Steam wants it to be
"StateFlags"       "6"            <- UpdateRequired + FullyInstalled
"UpdateResult"     "6"
"BytesToDownload"  "0"            <- resolved nothing to fetch: the tell
```

`BytesToDownload 0` next to a known `TargetBuildID` is the thing to look for. Steam knows which build it wants and has decided there is nothing to download to get there.

Rule out the ordinary causes before reaching for the fix below — the diagnostics odin prints on failure cover them:

| Check | Not the cause if |
|---|---|
| Disk on the game volume | `avail` comfortably exceeds the new build (~2 GiB and growing) |
| `steamapps/downloading` and `steamapps/temp` | empty; a wedged staging dir is a different problem |
| Ownership under the game volume | `111:1000`, matching odin's runtime uid/gid |

## Recovery

The game volume is disposable by design — it carries `backup.siliconsaga.org/content: reconstructible` and holds nothing authored here. The world lives on `valheim-data` and is not touched by any of this.

1. **Scale to 0.** `kubectl scale deployment/valheim -n <ns> --replicas=0`. This stops the crashloop and, because the volume is `ReadWriteOnce`, releases it for the next step.

2. **Run SteamCMD against the volume with the manifest cleared.** A throwaway pod on the `mbround18/valheim` image with `valheim-game` mounted at `/home/steam/valheim`, running:

   ```sh
   rm -f /home/steam/valheim/steamapps/appmanifest_896660.acf
   rm -rf /home/steam/valheim/steamapps/downloading /home/steam/valheim/steamapps/temp
   steamcmd +@NoPromptForPassword 1 +@ShutdownOnFailedCommand 1 \
            +@sSteamCmdForcePlatformType linux +@sSteamCmdForcePlatformBitness 64 \
            +force_install_dir /home/steam/valheim +login anonymous \
            +app_update 896660 validate +quit
   ```

   Run it as uid 111 / gid 1000 so the install stays readable by the server.

   **Pass odin's `@`-flags, and do not clear `~/.steam`.** SteamCMD stores its platform configuration under the Steam home at bootstrap; wiping that directory between attempts produces `Failed to install app '896660' (Missing configuration)`, a different failure that looks like progress and is not.

3. **Watch for it to get past `reconfiguring`.** A healthy run moves `verifying install` -> `preallocating` -> `downloading` -> `staging` -> `verifying update` -> `Success! App '896660' fully installed.` Reaching `verifying install` is the signal that the manifest was the blocker; a run that fails back out of `reconfiguring` in under a minute has not.

4. **Confirm the manifest, then scale back to 1.** `buildid` should now match the old `TargetBuildID` and `StateFlags` should be `4` (FullyInstalled, no update pending). On boot odin logs `Current build: <new>` and `No change in build version`, and the server console banner names the version it is actually running.

If Steam is still refusing, wrap step 2 in a retry loop rather than deleting more. Clearing the manifest is the whole fix; anything beyond it is guesswork against an outage you cannot influence.

## When it is worth wiping instead

Re-downloading the full install is roughly 2 GiB and a few minutes, so if the manifest fix does not take, emptying `/home/steam/valheim` and letting odin install from scratch on the next boot is a legitimate second move rather than a last resort. It costs bandwidth and nothing else. Keep the world volume out of it.
