// (b) SCRIPTED pipeline: plain Groovy. node{} allocates the agent, stage{} is
// just a label for the UI. Everything is code you can loop over and branch on.
node('jenkins-jenkins-agent') {
    stage('Checkout') {
        git url: 'http://gitea.git.svc.cluster.local:3000/payments/jobtypes-demo.git', branch: 'main'
    }
    stage('Test') {
        sh 'sh ./test.sh'
    }
    stage('Report') {
        echo "scripted: built ${env.JOB_NAME} #${env.BUILD_NUMBER}"
    }
}
