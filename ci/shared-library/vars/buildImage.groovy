/**
 * Build a container image with rootless BuildKit and push it to ECR.
 *
 *   buildImage(repository: '123.dkr.ecr.us-east-1.amazonaws.com/team/app',
 *              tag: 'main-ab12cd34-7', context: 'path/to/app', push: true)
 *
 * Credentials: NONE stored in Jenkins. The ECR login token is minted at build
 * time from the NODE'S IAM role via the instance metadata service. Nothing to
 * rotate, nothing to leak from the credentials store. The honest caveat: every
 * pod on that node inherits the same push permission. The production answer is
 * IRSA / EKS Pod Identity, scoping push to the agent's service account only.
 */
def call(Map cfg) {
    String repo    = cfg.repository ?: error('buildImage: repository is required')
    String tag     = cfg.tag        ?: error('buildImage: tag is required')
    String context = cfg.context    ?: '.'
    boolean push   = cfg.push == null ? true : cfg.push
    String region  = cfg.region     ?: 'us-east-1'
    String registry = repo.tokenize('/')[0]
    // Only ECR needs a minted token. Anything else (the playground's kind
    // registry) is either anonymous or logged in some other way.
    boolean ecr    = registry.contains('.dkr.ecr.')
    // Plain-HTTP registry, e.g. the playground's. Never set for ECR.
    boolean insecure = cfg.insecure == null ? (env.PLATFORM_REGISTRY_INSECURE == 'true') : cfg.insecure

    // Docker-style config.json in the workspace, readable by the BuildKit
    // container (shared emptyDir). Mode 600; deleted in `finally`.
    String dockerCfg = "${env.WORKSPACE}/.docker-${env.BUILD_NUMBER}"

    try {
        if (push && ecr) {
            container('deploy') {
                // `set +x` FIRST. Jenkins runs every `sh` with -x, which echoes
                // each command with its variables expanded -- the first version
                // of this step printed the full ECR token into the console log,
                // readable by anyone who can view the job. withCredentials()
                // masks secrets it binds; a token minted inside the script is
                // not bound, so nothing masks it.
                //
                // chown to 1000: this container runs as root, BuildKit runs
                // rootless as uid 1000. A root-owned mode-600 file is unreadable
                // to it, and BuildKit does not fail on that -- it logs
                //   WARNING: Error loading config file: ... permission denied
                // carries on anonymously, and the push dies minutes later as
                //   unexpected status from HEAD request ...: 401 Unauthorized
                // which reads as an IAM problem. It is a file permission.
                sh """
                    set +x
                    set -eu
                    mkdir -p '${dockerCfg}'
                    TOKEN=\$(aws ecr get-login-password --region ${region})
                    AUTH=\$(printf 'AWS:%s' "\$TOKEN" | base64 | tr -d '\\n')
                    printf '{"auths":{"%s":{"auth":"%s"}}}' '${registry}' "\$AUTH" > '${dockerCfg}/config.json'
                    chmod 600 '${dockerCfg}/config.json'
                    chown -R 1000:1000 '${dockerCfg}'
                    echo "ECR login written for ${registry} (token not shown)"
                """
            }
        }
        container('buildkit') {
            // --output push=false still builds, so feature branches prove the
            // Dockerfile works without polluting the registry.
            sh """
                set -eu
                export DOCKER_CONFIG='${dockerCfg}'
                buildctl-daemonless.sh build \\
                  --frontend dockerfile.v0 \\
                  --local context='${context}' \\
                  --local dockerfile='${context}' \\
                  --opt build-arg:VERSION='${tag}' \\
                  --output type=image,name='${repo}:${tag}',push=${push}${insecure ? ',registry.insecure=true' : ''}
            """
        }
    } finally {
        sh "rm -rf '${dockerCfg}'"
    }
    return "${repo}:${tag}"
}
