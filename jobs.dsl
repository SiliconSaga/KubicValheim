// Generates a backup job per Valheim instance. Unlike the KubicArk DSL these
// carry a cron trigger — ARK's jobs are manual-only today.
//
// The cron lives HERE and not in backup.Jenkinsfile, and that placement is
// load-bearing. A Jenkinsfile `triggers` block only reaches the job once Jenkins
// has built it and read the file, while a seed run rewrites the job's config
// from this DSL alone. So a Jenkinsfile-only cron is armed by the first build
// and DISARMED by the next seed — which is exactly what happened: valheim7's
// timer fired 2026-08-26 03:30 UTC ("Started by timer"), the job was re-seeded
// later that day, and no timer build has run since. twinhenge and valheim3,
// never built by hand, never armed at all. Declaring it here means the trigger
// exists the moment the job does.
//
// `H 3 * * *` rather than a fixed `30 3`: H spreads the instances across the
// hour by job-name hash instead of firing every server's backup simultaneously
// at one cluster. Jenkins cron is in the CONTROLLER's timezone, which is UTC.
//
// Also generates a restore job per instance. Unlike backup, restore has NO
// cron trigger anywhere (DSL or Jenkinsfile) — it is destructive and manual-only.
//
// world is only needed by restore (it's what step 4 of restore-server.sh
// matches the archive against) — it stays out of the backup instance shape.

// ONE row per instance generates that instance's backup AND restore jobs — add a
// server here and both appear on the next seed run. `namespace` is spelled out
// rather than derived because valheim7 is grandfathered onto `kubicvalheim`
// instead of the `valheim-<slug>` convention every later instance follows.
def instances = [
    [slug: 'valheim7',  namespace: 'kubicvalheim',       world: 'Jotunheim'],
    [slug: 'twinhenge', namespace: 'valheim-twinhenge',  world: 'twinhenge'],
    [slug: 'valheim3',  namespace: 'valheim-valheim3',   world: 'valheim3'],
]

def parentGameFolder = "KubicGameHosting/Valheim"
folder("KubicGameHosting")
folder(parentGameFolder)

instances.each { inst ->
    folder("${parentGameFolder}/${inst.slug}") {
        displayName(inst.slug.capitalize())
    }

    pipelineJob("${parentGameFolder}/${inst.slug}/backup") {
        displayName("Back up server")

        triggers {
            cron('H 3 * * *')
        }

        parameters {
            stringParam('slug', inst.slug, 'Instance slug — names the GCS path')
            stringParam('namespace', inst.namespace, 'Namespace holding the server')
        }

        definition {
            cpsScm {
                scm {
                    git {
                        remote {
                            url('https://github.com/SiliconSaga/KubicValheim.git')
                            credentials('GooeyHub')
                        }
                        branch('master')
                    }
                }
                scriptPath('backup.Jenkinsfile')
            }
        }
    }

    pipelineJob("${parentGameFolder}/${inst.slug}/restore") {
        displayName("Restore server (DESTRUCTIVE)")

        // THE single source of truth for this job's parameters. restore.Jenkinsfile
        // deliberately has no `parameters` block: a Declarative Pipeline's
        // parameters block REPLACES the job's parameter definitions on every run,
        // so a shared, instance-agnostic Jenkinsfile would overwrite the
        // per-instance defaults below — in particular blanking `world`, which
        // restore-server.sh then rejects. Only the DSL knows each instance's
        // world, so only the DSL declares parameters. Add new ones here.
        parameters {
            stringParam('slug', inst.slug, 'Instance slug — same DNS-1123 validation as the backup job')
            stringParam('namespace', inst.namespace, 'Namespace holding the server')
            stringParam('world', inst.world, 'WORLD this instance is configured with — the archive is matched against this before anything is destroyed')
            stringParam('archive', '', 'Archive to restore: a gs://... path or an https://storage.googleapis.com/... URL')
        }

        definition {
            cpsScm {
                scm {
                    git {
                        remote {
                            url('https://github.com/SiliconSaga/KubicValheim.git')
                            credentials('GooeyHub')
                        }
                        branch('master')
                    }
                }
                scriptPath('restore.Jenkinsfile')
            }
        }
    }
}
