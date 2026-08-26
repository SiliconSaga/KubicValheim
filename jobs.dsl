// Generates a backup job per Valheim instance. Unlike the KubicArk DSL these
// carry a cron trigger — ARK's jobs are manual-only today.
//
// Also generates a restore job per instance. Unlike backup, restore has NO
// cron trigger anywhere (DSL or Jenkinsfile) — it is destructive and manual-only.
//
// world is only needed by restore (it's what step 4 of restore-server.sh
// matches the archive against) — it stays out of the backup instance shape.

def instances = [
    [slug: 'valheim7', namespace: 'kubicvalheim', world: 'Jotunheim'],
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

        // DUPLICATED here and in restore.Jenkinsfile's own `parameters` block —
        // deliberately, not an oversight. Jenkins only registers a Jenkinsfile's
        // `parameters` block AFTER the first build runs once; before that, a
        // pipelineJob has no parameters at all unless the DSL declares them here
        // too. Without this, run #1 of a brand-new restore job would offer no
        // `slug`/`namespace`/`world`/`archive` fields to fill in. Do not "tidy"
        // this away — keep both in sync if a parameter changes.
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
