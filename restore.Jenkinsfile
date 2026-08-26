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

    options {
        // Two concurrent restores of the same instance would fight over one
        // Deployment, one PVC, and a fixed `restore-helper` pod name — build B
        // can delete build A's helper mid-extract, or stage a rollback copy over
        // the other's. Serialise them.
        disableConcurrentBuilds()
    }

    // NO `parameters` block here, deliberately. A Declarative Pipeline's
    // parameters block REPLACES the job's existing parameter definitions on
    // every run, so declaring them here would overwrite jobs.dsl's per-instance
    // defaults with whatever this shared, instance-agnostic file says — in
    // particular blanking `world`, which restore-server.sh then rejects. jobs.dsl
    // knows each instance's slug/namespace/world; this file cannot. Leaving the
    // block out lets the DSL remain the single source of truth.

    environment {
        // The agent carries exactly one kubeconfig context, so inheriting
        // current-context is safe HERE and only here; restore-server.sh
        // otherwise refuses to run without an explicit KUBE_CONTEXT.
        RESTORE_ALLOW_CURRENT_CONTEXT = '1'
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
