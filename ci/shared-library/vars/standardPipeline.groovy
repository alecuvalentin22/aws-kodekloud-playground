import org.platformlab.ImageTag

/**
 * The golden path. A team's ENTIRE Jenkinsfile becomes:
 *
 *   @Library('platform-lib') _
 *   standardPipeline(app: 'demo-api', context: 'ci/apps/demo-api', ...)
 *
 * This is what "shared, reusable pipeline patterns to reduce duplication" means
 * in practice. Twenty services stop carrying twenty copies of the same 150
 * lines, each drifting slightly; a fix to the build step lands everywhere at
 * once. The cost, which is worth saying in an interview: a bad library change
 * also lands everywhere at once -- which is why production pins the library to
 * a TAG and tests it on a canary job first.
 *
 * Branch behaviour:
 *   every branch   test, build the image (proves the Dockerfile still works)
 *   main only      push to ECR, deploy to EKS, wait, auto-rollback on failure
 */
def call(Map cfg) {
    String app      = cfg.app        ?: error('standardPipeline: app is required')
    String context  = cfg.context    ?: error('standardPipeline: context is required')
    // Registry is OPTIONAL and resolved at build time when absent. Hardcoding
    // it would bake one AWS account ID into every team's Jenkinsfile, and the
    // file would break the moment it ran anywhere else.
    String registry = cfg.registry   ?: ''
    String repoPrefix = cfg.repoPrefix ?: 'platform-lab'
    String region   = cfg.region     ?: 'us-east-1'
    String ns       = cfg.namespace  ?: 'demo-ci'
    String testCmd  = cfg.testCommand ?: 'pip install -q -r requirements.txt && python -m pytest -q --junitxml=test-results.xml'
    String deployBranch = cfg.deployBranch ?: 'main'

    pipeline {
        agent {
            kubernetes {
                yaml libraryResource('podtemplates/build.yaml')
                defaultContainer 'python'
            }
        }
        options {
            timestamps()
            timeout(time: 20, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '20'))
            disableConcurrentBuilds()
        }
        stages {
            stage('Test') {
                steps {
                    dir(context) {
                        sh testCmd
                    }
                }
                post {
                    always { junit allowEmptyResults: true, testResults: "${context}/test-results.xml" }
                }
            }
            stage('Build image') {
                steps {
                    script {
                        if (!registry) {
                            String acct = ''
                            container('deploy') {
                                acct = sh(returnStdout: true,
                                          script: 'aws sts get-caller-identity --query Account --output text').trim()
                            }
                            registry = "${acct}.dkr.ecr.${region}.amazonaws.com"
                        }
                        env.REPO = "${registry}/${repoPrefix}/${app}"
                        env.IMAGE_TAG = ImageTag.of(env.BRANCH_NAME, env.GIT_COMMIT, env.BUILD_NUMBER)
                        boolean push = (env.BRANCH_NAME == deployBranch)
                        env.IMAGE = buildImage(repository: env.REPO, tag: env.IMAGE_TAG,
                                               context: context, push: push, region: region)
                        echo push ? "pushed ${env.IMAGE}" : "built ${env.IMAGE} (not pushed: branch ${env.BRANCH_NAME})"
                    }
                }
            }
            stage('Deploy') {
                // expression{} rather than branch(): a Groovy variable inside
                // the branch() condition of a library-defined pipeline is a
                // known source of "when never matches" surprises.
                when { expression { env.BRANCH_NAME == deployBranch } }
                steps {
                    deployToEks(namespace: ns, deployment: app,
                                manifests: "${context}/k8s", image: env.IMAGE)
                }
            }
        }
        post {
            success { echo "OK: ${app} ${env.IMAGE_TAG ?: ''}" }
            failure { echo "FAILED: ${app} -- read the first red stage, not the last" }
        }
    }
}
