// Generates a backup job per Valheim instance. Unlike the KubicArk DSL these
// carry a cron trigger — ARK's jobs are manual-only today.

def instances = [
    [slug: 'valheim7', namespace: 'kubicvalheim'],
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
}
