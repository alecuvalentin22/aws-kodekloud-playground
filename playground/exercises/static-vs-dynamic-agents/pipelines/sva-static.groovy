// sva-static: the SAME steps as sva-dynamic. Only the agent line differs.
pipeline {
    agent { label 'static' }
    options { timestamps() }
    stages {
        stage('Where am I') {
            steps {
                script { echo "COLD_START_MS=${System.currentTimeMillis() - currentBuild.startTimeInMillis}" }
                sh '''
                    echo "NODE=$NODE_NAME HOST=$(uname -n) USER=$(id -un) WORKSPACE=$WORKSPACE"
                    if [ -f .left-by-previous-build ]; then echo "MARKER=found ($(cat .left-by-previous-build))"; else echo "MARKER=absent"; fi
                    echo "left by build $BUILD_NUMBER of $JOB_NAME at $(date -u +%H:%M:%S)" > .left-by-previous-build
                    echo "FAKE-DEPLOY-TOKEN-$BUILD_NUMBER-not-a-real-secret" > .deploy-token
                    df -h . | tail -1
                '''
            }
        }
        stage('Hold the executor') {
            steps { sh 'sleep 20' }
        }
    }
}
