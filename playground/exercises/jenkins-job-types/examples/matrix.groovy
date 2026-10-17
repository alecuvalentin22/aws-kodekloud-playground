// (g) declarative MATRIX: one stage definition, run once per combination of axes.
pipeline {
    agent none
    stages {
        stage('Greet everyone') {
            matrix {
                axes {
                    axis { name 'GREETEE'; values 'Ada', 'Grace', 'Linus' }
                    axis { name 'WHERE';   values 'dev', 'ci' }
                }
                excludes {
                    exclude {
                        axis { name 'GREETEE'; values 'Linus' }
                        axis { name 'WHERE';   values 'dev' }
                    }
                }
                agent { label 'jenkins-jenkins-agent' }
                stages {
                    stage('Greet') {
                        steps {
                            git url: 'http://gitea.git.svc.cluster.local:3000/payments/jobtypes-demo.git', branch: 'main'
                            sh "sh ./greet.sh ${GREETEE} ${WHERE}"
                        }
                    }
                }
            }
        }
    }
}
