// DESTRUCTIVE: this job stops a LIVE Valheim server, deletes its current
// worlds_local, and replaces it with the contents of a GCS archive. There is
// no undo on the PVC once step 6 runs. Manual-only on purpose (no `triggers`
// block, unlike backup.Jenkinsfile's nightly cron) — this is for operators
// trusted to run a restore deliberately, not something that should ever fire
// unattended. See docs/restore.md for the full runbook and scripts/restore-server.sh
// for what actually executes.
pipeline {
    agent {
        label 'kubectl && gcloud'
    }

    parameters {
        string(name: 'slug',      defaultValue: 'valheim7',     description: 'Instance slug — same DNS-1123 validation as the backup job')
        string(name: 'namespace', defaultValue: 'kubicvalheim', description: 'Namespace holding the server')
        string(name: 'world',     defaultValue: '',             description: 'WORLD this instance is configured with (instance-patch.yaml) — the archive is matched against this before anything is destroyed')
        string(name: 'archive',   defaultValue: '',             description: 'Archive to restore: a gs://... path or an https://storage.googleapis.com/... URL')
    }

    stages {
        stage('Restore') {
            steps {
                container('utility') {
                    withKubeConfig(credentialsId: 'utility-admin-kubeconfig-sa-token') {
                        withCredentials([file(credentialsId: 'jenkins-bucket-sa', variable: 'GCLOUD_KEY')]) {
                            sh 'cat "$GCLOUD_KEY" | gcloud auth activate-service-account --key-file=-'
                            sh './scripts/restore-server.sh "$slug" "$namespace" "$world" "$archive"'
                        }
                    }
                }
            }
        }
    }
}
