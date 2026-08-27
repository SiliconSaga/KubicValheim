// Generates a backup job per Valheim instance. Unlike the KubicArk DSL these
// carry a cron trigger — ARK's jobs are manual-only today.
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
