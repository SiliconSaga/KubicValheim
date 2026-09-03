pipeline {
    agent {
        label 'kubectl && gcloud'
    }

    // NO `parameters` block — same reasoning as backup.Jenkinsfile and
    // restore.Jenkinsfile. A Declarative Pipeline's parameters block REPLACES the
    // job's definitions on every run, so this shared, instance-agnostic file would
    // overwrite jobs.dsl's per-instance defaults. jobs.dsl knows each instance's
    // slug and namespace; this file cannot.
    //
    // NO `triggers` block either, and here that is not just convention: hibernating
    // a server is a deliberate act, exactly like restore. Nothing should put a
    // server to sleep on a timer.
    //
    // gcloud credentials are needed even though this job does not upload directly —
    // it shells out to backup-server.sh, which does.

    stages {
        stage('Hibernate') {
            steps {
                container('utility') {
                    withKubeConfig(credentialsId: 'utility-admin-kubeconfig-sa-token') {
                        withCredentials([file(credentialsId: 'jenkins-bucket-sa', variable: 'GCLOUD_KEY')]) {
                            sh 'cat "$GCLOUD_KEY" | gcloud auth activate-service-account --key-file=-'
                            // Exit 2 means "already hibernated" — nothing to do, and
                            // that is correct. Red for a server that is already in the
                            // state you asked for trains people to ignore this job;
                            // green would claim an action that did not happen.
                            //
                            // Everything else non-zero is a real failure, INCLUDING the
                            // pre-hibernation backup failing, which deliberately aborts
                            // the scale-down rather than parking a server with a stale
                            // off-cluster copy.
                            script {
                                def rc = sh(
                                    script: 'SKIP_BACKUP="$skipBackup" ./scripts/hibernate-server.sh "$slug" "$namespace"',
                                    returnStatus: true
                                )
                                if (rc == 2) {
                                    unstable("Instance '${env.slug}' is already hibernated — nothing to do.")
                                } else if (rc != 0) {
                                    error("hibernate-server.sh failed for '${env.slug}' (exit ${rc})")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
