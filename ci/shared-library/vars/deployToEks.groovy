/**
 * Roll a new image out to EKS and WAIT for it -- then roll back automatically
 * if it never becomes healthy.
 *
 *   deployToEks(namespace: 'demo-ci', deployment: 'demo-api',
 *               manifests: 'ci/apps/demo-api/k8s', image: '...:tag')
 *
 * Manifests reference the image as IMAGE_PLACEHOLDER; it is substituted here.
 *
 * The step that most pipelines get wrong is the WAIT. `kubectl apply` returns
 * as soon as the API server accepts the object, so a pipeline that stops there
 * goes green while the new pods crash-loop. `rollout status` with a timeout is
 * what makes the pipeline's colour mean anything.
 */
def call(Map cfg) {
    String ns   = cfg.namespace  ?: error('deployToEks: namespace is required')
    String dep  = cfg.deployment ?: error('deployToEks: deployment is required')
    String dir  = cfg.manifests  ?: error('deployToEks: manifests is required')
    String img  = cfg.image      ?: error('deployToEks: image is required')
    String timeout = cfg.timeout ?: '180s'

    container('deploy') {
        // Render the image INTO the manifests, then apply once. The tempting
        // alternative -- `apply` then `kubectl set image` -- triggers TWO
        // rollouts, the first one to whatever placeholder the manifest holds.
        sh """
            set -eu
            rm -rf .rendered && mkdir .rendered
            for f in '${dir}'/*.yaml; do
              sed "s|IMAGE_PLACEHOLDER|${img}|g" "\$f" > ".rendered/\$(basename "\$f")"
            done
            kubectl -n ${ns} apply -f .rendered/
            kubectl -n ${ns} annotate deployment/${dep} --overwrite \\
              kubernetes.io/change-cause='jenkins ${env.JOB_NAME} #${env.BUILD_NUMBER}: ${img}'
        """
        int rc = sh(returnStatus: true,
                    script: "kubectl -n ${ns} rollout status deployment/${dep} --timeout=${timeout}")
        if (rc != 0) {
            // Leave evidence before undoing it -- the developer who reads this
            // build log needs to see WHY, not just that it was rolled back.
            sh """
                echo '--- rollout did not complete; pod state at failure ---'
                kubectl -n ${ns} get pods -l app=${dep} -o wide || true
                kubectl -n ${ns} describe deployment/${dep} | tail -20 || true
                echo '--- rolling back to the previous revision ---'
                kubectl -n ${ns} rollout undo deployment/${dep}
                kubectl -n ${ns} rollout status deployment/${dep} --timeout=${timeout}
            """
            error("Deploy of ${img} did not become healthy within ${timeout}; rolled back.")
        }
    }
}
