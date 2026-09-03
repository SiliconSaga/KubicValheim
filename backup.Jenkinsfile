pipeline {
    agent {
        label 'kubectl && gcloud'
    }

    // NO `parameters` block here, deliberately — same reasoning as
    // restore.Jenkinsfile. A Declarative Pipeline's parameters block REPLACES the
    // job's parameter definitions on every run, so this shared, instance-agnostic
    // file would overwrite jobs.dsl's per-instance defaults with its own. The
    // defaults that used to live here were `valheim7`/`kubicvalheim`, so one build
    // of the twinhenge or valheim3 job was enough to leave that job's timer
    // pointed at valheim7 — backing the wrong server up, into the wrong GCS path,
    // and reporting success. jobs.dsl knows each instance's slug and namespace;
    // this file cannot.
    //
    // NO `triggers` block either. The nightly cron is declared in jobs.dsl so it
    // survives a seed run — a Jenkinsfile trigger is armed by the first build and
    // silently dropped by the next re-seed. One source, and it is the DSL.

    stages {
        stage('Backup') {
            steps {
                container('utility') {
                    withKubeConfig(credentialsId: 'utility-admin-kubeconfig-sa-token') {
                        withCredentials([file(credentialsId: 'jenkins-bucket-sa', variable: 'GCLOUD_KEY')]) {
                            sh 'cat "$GCLOUD_KEY" | gcloud auth activate-service-account --key-file=-'
                            // returnStatus, not the default throw-on-nonzero, so exit 2
                            // can be told apart from a real failure. Console output still
                            // streams either way.
                            //
                            // A dormant instance (spec.replicas == 0) is neither success
                            // nor failure: no backup was taken, and none was needed. Red
                            // every night for a server someone deliberately parked is how
                            // an operator learns to ignore this job — and with it the next
                            // genuine failure. Green would be worse still: it would report
                            // a backup that did not happen.
                            //
                            // Exit codes are the contract in scripts/backup-server.sh;
                            // change them together.
                            script {
                                def rc = sh(
                                    script: './scripts/backup-server.sh "$slug" "$namespace"',
                                    returnStatus: true
                                )
                                if (rc == 2) {
                                    unstable("Instance '${env.slug}' is dormant (spec.replicas == 0) — no backup taken, none needed.")
                                } else if (rc != 0) {
                                    error("backup-server.sh failed for '${env.slug}' (exit ${rc})")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
