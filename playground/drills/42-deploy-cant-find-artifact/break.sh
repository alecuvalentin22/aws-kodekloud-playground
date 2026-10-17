#!/usr/bin/env bash
# The team leaves the golden path for its own pipeline, with one agent pod
# for Build and a second, smaller one for Deploy. The image reference crosses
# between them as a FILE in the workspace -- which does not cross pods.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
as_teammate "Priya (payments)" payments/demo-api "Jenkinsfile: own pipeline -- contract check, small Deploy pod" <<'SH'
cat > Jenkinsfile <<'JF'
// payments team's own pipeline. We left the golden path for two reasons:
//   - an API contract check before the image is built
//   - Deploy runs in a small pod of its own, so BuildKit's memory is not held
//     while kubectl waits for the rollout
@Library('platform-lib') _
import org.platformlab.ImageTag

pipeline {
    agent none
    options {
        timestamps()
        timeout(time: 25, unit: 'MINUTES')
        disableConcurrentBuilds()
    }
    stages {
        stage('Build') {
            agent {
                kubernetes {
                    yaml libraryResource('podtemplates/build.yaml')
                    defaultContainer 'python'
                }
            }
            stages {
                stage('Test') {
                    steps {
                        sh 'pip install -q -r requirements.txt && python -m pytest -q --junitxml=test-results.xml'
                    }
                    post {
                        always { junit 'test-results.xml' }
                    }
                }
                stage('API contract') {
                    steps {
                        sh '''pip install -q pyyaml && python -c "import yaml; d = yaml.safe_load(open('openapi.yaml')); assert str(d['openapi']).startswith('3.'), d['openapi']; print('contract ok:', d['info']['title'], d['info']['version'])"'''
                    }
                }
                stage('Build image') {
                    steps {
                        script {
                            String repo  = "${env.PLATFORM_REGISTRY}/platform-lab/demo-api"
                            String tag   = ImageTag.of(env.BRANCH_NAME, env.GIT_COMMIT, env.BUILD_NUMBER)
                            String image = buildImage(repository: repo, tag: tag, context: '.',
                                                      push: env.BRANCH_NAME == 'main')
                            writeFile file: 'image-ref.txt', text: image + '\n'
                            echo "built ${image}"
                        }
                    }
                }
            }
        }
        stage('Deploy') {
            when {
                beforeAgent true
                expression { env.BRANCH_NAME == 'main' }
            }
            agent {
                kubernetes {
                    yaml '''
                      apiVersion: v1
                      kind: Pod
                      spec:
                        serviceAccountName: jenkins-agent
                        containers:
                          - name: deploy
                            image: alpine/k8s:1.33.13
                            command: [sleep]
                            args: [infinity]
                            resources:
                              requests: {cpu: 50m, memory: 64Mi}
                              limits: {memory: 256Mi}
                    '''
                    defaultContainer 'deploy'
                }
            }
            steps {
                script {
                    String image = readFile('image-ref.txt').trim()
                    echo "deploying ${image}"
                    deployToEks(namespace: 'demo-ci', deployment: 'demo-api',
                                manifests: 'k8s', image: image)
                }
            }
        }
    }
    post {
        success { echo "OK: demo-api" }
        failure { echo "FAILED: read the first red stage, not the last" }
    }
}
JF
grep -q "image-ref.txt" Jenkinsfile
SH
jenkins_scan
