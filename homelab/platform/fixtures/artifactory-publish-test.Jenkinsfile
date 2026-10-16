// Test fixture (not part of the golden path): proves Jenkins -> Artifactory.
// Job "artifactory-publish-test" on the home-lab Jenkins holds this script inline
// (created through the REST createItem API, config.xml: CpsFlowDefinition).
// Needs the Jenkins credential "artifactory-admin" (username/password).
@Library('platform-lib') _
pipeline {
    agent {
        kubernetes {
            yaml libraryResource('podtemplates/build.yaml')
            defaultContainer 'deploy'
        }
    }
    options { timestamps(); timeout(time: 5, unit: 'MINUTES') }
    environment {
        // In-cluster Service artifactory (namespace artifactory), port 8082 (router).
        BASE = 'http://artifactory.artifactory.svc.cluster.local:8082/artifactory/generic-local/jenkins'
    }
    stages {
        stage('Publish') {
            steps {
                sh 'echo "build ${BUILD_NUMBER} $(date -u +%FT%TZ)" > artifact.txt'
                sh 'sha256sum artifact.txt | tee up.sha'
                withCredentials([usernamePassword(credentialsId: 'artifactory-admin',
                                                  usernameVariable: 'AU', passwordVariable: 'AP')]) {
                    sh 'curl -sS -f -u "$AU:$AP" -T artifact.txt -w "upload HTTP %{http_code}\\n" -o /dev/null "$BASE/${BUILD_NUMBER}.txt"'
                    sh 'curl -sS -f -u "$AU:$AP" -o down.txt -w "download HTTP %{http_code}\\n" "$BASE/${BUILD_NUMBER}.txt"'
                }
            }
        }
        stage('Verify') {
            steps {
                sh '''
                    sha256sum down.txt | tee down.sha
                    test "$(cut -d" " -f1 up.sha)" = "$(cut -d" " -f1 down.sha)" && echo "sha256 MATCH for ${BASE}/${BUILD_NUMBER}.txt"
                '''
            }
        }
    }
}
