// (f) the DOWNSTREAM job, jt-downstream. Create it and RUN IT ONCE before the
// upstream job calls it (a parameter only exists after a run: drills 47 and 48).
pipeline {
    agent none
    parameters {
        string(name: 'WHO', defaultValue: '', description: 'who triggered me')
    }
    stages {
        stage('Receive') {
            steps {
                script {
                    if (!params.WHO) { error('WHO is required: nobody told me who called') }
                    echo "downstream received WHO=${params.WHO}"
                }
            }
        }
    }
}
