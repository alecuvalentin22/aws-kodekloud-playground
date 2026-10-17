// (f) the UPSTREAM job, jt-upstream: runs, then starts jt-downstream with a parameter.
pipeline {
    agent none
    stages {
        stage('Build') {
            steps { echo 'upstream: pretend we built something' }
        }
        stage('Trigger downstream') {
            steps {
                // wait: true (the default) blocks until the downstream finishes and
                // propagate: true (the default) makes THIS build fail if it fails.
                build job: 'jt-downstream', wait: true, propagate: true,
                      parameters: [string(name: 'WHO', value: "jt-upstream #${env.BUILD_NUMBER}")]
            }
        }
    }
}
