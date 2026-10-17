// (c) the SAME pipeline, DECLARATIVE: a fixed structure Jenkins can validate
// before running anything. Logic that does not fit goes inside script { }.
pipeline {
    agent { label 'jenkins-jenkins-agent' }
    options { timestamps(); timeout(time: 5, unit: 'MINUTES') }
    stages {
        stage('Checkout') {
            steps { git url: 'http://gitea.git.svc.cluster.local:3000/payments/jobtypes-demo.git', branch: 'main' }
        }
        stage('Test') {
            steps { sh 'sh ./test.sh' }
        }
        stage('Report') {
            steps {
                script {
                    // script { } is the escape hatch back to scripted Groovy.
                    def parts = ['declarative', env.JOB_NAME, "#${env.BUILD_NUMBER}"]
                    echo parts.join(' ')
                }
            }
        }
    }
    post {
        always  { echo "result so far: ${currentBuild.currentResult}" }
        success { echo 'post success: the happy path' }
        failure { echo 'post failure: the place for notifications and rollbacks' }
    }
}
