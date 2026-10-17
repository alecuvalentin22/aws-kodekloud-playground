// (e) a PARAMETERIZED pipeline. Read the comments, then do the first-run trap.
pipeline {
    agent { label 'jenkins-jenkins-agent' }
    parameters {
        // The FIRST choice is the default. Put the safe one first.
        choice(name: 'TARGET', choices: ['staging', 'prod'], description: 'where to greet')
        booleanParam(name: 'LOUD', defaultValue: false, description: 'shout it')
    }
    stages {
        stage('Greet') {
            steps {
                script {
                    // A run that started BEFORE the parameters existed (the very first one, or
                    // right after you added them) was not given any: params.TARGET quietly holds
                    // its default ('staging'), but the environment variable TARGET does not exist.
                    if (env.TARGET == null) {
                        echo 'Parameters registered. Nothing done: build again with "Build with Parameters".'
                        currentBuild.result = 'NOT_BUILT'
                        return
                    }
                    String msg = "hello from ${params.TARGET}"
                    echo params.LOUD ? msg.toUpperCase() : msg
                }
            }
        }
    }
}
