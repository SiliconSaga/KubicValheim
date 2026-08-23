pipeline {
    agent {
        label 'kubectl && gcloud'
    }

    parameters {
        string(name: 'slug',      defaultValue: 'valheim7',     description: 'Instance slug — names the GCS path')
        string(name: 'namespace', defaultValue: 'kubicvalheim', description: 'Namespace holding the server')
    }

    triggers {
        // Nightly at 03:30. odin backs up hourly, so this picks up something at
        // most an hour old whenever it runs — no ordering dependency between the two.
        cron('30 3 * * *')
    }

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
