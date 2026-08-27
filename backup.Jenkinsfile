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
                            sh './scripts/backup-server.sh "$slug" "$namespace"'
                        }
                    }
                }
            }
        }
    }
}
