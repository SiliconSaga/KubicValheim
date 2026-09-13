pipeline {
    agent {
        label 'kubectl && gcloud'
    }

    // NO `parameters` block and NO `triggers` block — same reasoning as the other
    // three Jenkinsfiles. jobs.dsl owns per-instance parameters; waking a server is
    // deliberate and never scheduled.
    //
    // No gcloud credentials here: unlike hibernate, this job never touches GCS.

    stages {
        stage('Wake') {
            steps {
                container('utility') {
                    withKubeConfig(credentialsId: 'utility-admin-kubeconfig-sa-token') {
                        // Exit 2 means "already awake" — the state you asked for is
                        // the state it is in.
                        //
                        // Exit 1 includes the case worth knowing about: the pod came
                        // up but has NO WORLD, which from the outside looks exactly
                        // like a healthy start. That is a failure, loudly, because
                        // the next thing that happens otherwise is players connecting
                        // to a freshly generated map.
                        script {
                            def rc = sh(
                                script: 'REPLICAS="$replicas" ./scripts/wake-server.sh "$slug" "$namespace"',
                                returnStatus: true
                            )
                            if (rc == 2) {
                                unstable("Instance '${env.slug}' is already awake — nothing to do.")
                            } else if (rc != 0) {
                                error("wake-server.sh failed for '${env.slug}' (exit ${rc})")
                            }
                        }
                    }
                }
            }
        }
    }
}
