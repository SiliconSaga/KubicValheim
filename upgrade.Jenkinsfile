pipeline {
    agent {
        label 'kubectl && gcloud'
    }

    // NO `parameters` block and NO `triggers` block — same reasoning as the other
    // Jenkinsfiles. jobs.dsl owns per-instance parameters.
    //
    // No cron in particular. Steam decides when a new build exists, and a timer
    // that restarts a server on a schedule would take it away from players to
    // apply nothing on most runs. This is the button you press when the devs
    // have shipped something.
    //
    // No gcloud credentials: like wake, this job never touches GCS. It takes no
    // backup of its own — an upgrade rewrites the game volume, which carries the
    // `reconstructible` label, and never the world volume.

    stages {
        stage('Upgrade') {
            steps {
                container('utility') {
                    withKubeConfig(credentialsId: 'utility-admin-kubeconfig-sa-token') {
                        // Exit 2 means the instance is hibernated — there is no
                        // running server to move to a new build, and it will take
                        // whatever is current when someone wakes it. Not a failure,
                        // but not the upgrade you asked for either.
                        //
                        // Exit 1 covers both "it never came back Ready" and the one
                        // that matters more: it came back, but WITHOUT ITS WORLD.
                        // The script's output says which, and points at
                        // docs/steam-updates.md when the log shows a stuck Steam
                        // update rather than a bad build.
                        script {
                            def rc = sh(
                                script: './scripts/upgrade-server.sh "$slug" "$namespace"',
                                returnStatus: true
                            )
                            if (rc == 2) {
                                unstable("Instance '${env.slug}' is hibernated — nothing to upgrade.")
                            } else if (rc != 0) {
                                error("upgrade-server.sh failed for '${env.slug}' (exit ${rc})")
                            }
                        }
                    }
                }
            }
        }
    }
}
