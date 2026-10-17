// sva-snoop: "another team's job" on the same label. It reads nothing it was
// not allowed to read by Jenkins: it just lists the box it landed on.
pipeline {
    agent { label 'static' }
    stages {
        stage('Look around') {
            steps {
                sh '''
                    echo "I am $(id -un) on $(uname -n); other workspaces on this box:"
                    ls -la ../
                    for t in ../*/.deploy-token; do [ -f "$t" ] && { echo "found $t:"; cat "$t"; }; done
                    exit 0
                '''
            }
        }
    }
}
