#!/usr/bin/env bash
# Two jobs from one repo: rel-build (checks out demo-api, builds + pushes
# payments/relsvc:rel-<n>-<sha>, then starts rel-deploy) and rel-deploy
# (deploys an image to namespace rel-demo with the library's deployToEks).
# Last week Priya renamed rel-deploy's parameter TAG -> IMAGE_TAG and made "no
# tag" mean "re-apply what runs now". rel-build still sends TAG. Jenkins skips a
# parameter the downstream job does not define (logging a WARNING in the
# controller's system log only), so rel-deploy always runs with its default:
# green, and a no-op.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"; load_creds
source "$(dirname "$0")/lib.sh"

if gitea_api GET "/repos/$REPO48" >/dev/null 2>&1 || jenkins_get "/job/$JOBA/api/json" >/dev/null 2>&1 \
   || K get ns "$NS48" >/dev/null 2>&1; then
  echo "drill 48 leftovers exist ($REPO48 / $JOBA / namespace $NS48) -- run: play reset"; exit 1
fi

# 1. The cluster side: a namespace the agents may deploy into, and release 0
#    (the baseline demo-api image: it is in the registry and it is healthy).
img0=$(K -n demo-ci get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ -n $img0 ]] || { echo "demo-api is not deployed in demo-ci -- run: play reset"; exit 1; }

d="$STATE/scratch/seed48"; rm -rf "$d"; mkdir -p "$d/build" "$d/deploy/k8s"

cat > "$d/deploy/k8s/deployment.yaml" <<'EOF2'
# IMAGE_PLACEHOLDER is substituted by the deployToEks library step.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: relsvc
  labels: {app: relsvc}
spec:
  replicas: 1
  revisionHistoryLimit: 5
  selector:
    matchLabels: {app: relsvc}
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxUnavailable: 0, maxSurge: 1}
  template:
    metadata:
      labels: {app: relsvc}
    spec:
      containers:
        - name: relsvc
          image: IMAGE_PLACEHOLDER
          ports: [{containerPort: 8080, name: http}]
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 5
          resources:
            requests: {cpu: 20m, memory: 48Mi}
            limits: {memory: 192Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: relsvc
  labels: {app: relsvc}
spec:
  selector: {app: relsvc}
  ports:
    - {name: http, port: 80, targetPort: http}
EOF2

K apply -f - >/dev/null <<EOF2
apiVersion: v1
kind: Namespace
metadata: {name: $NS48}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: deployer, namespace: $NS48}
rules:
  - apiGroups: ["apps"]
    resources: [deployments, replicasets]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: [""]
    resources: [services, pods, configmaps]
    verbs: [get, list, watch, create, update, patch]
  - apiGroups: [""]
    resources: [events]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: jenkins-agent-deployer, namespace: $NS48}
subjects:
  - {kind: ServiceAccount, name: jenkins-agent, namespace: jenkins}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: deployer}
EOF2
sed "s|IMAGE_PLACEHOLDER|$img0|g" "$d/deploy/k8s/deployment.yaml" | K -n "$NS48" apply -f - >/dev/null
K -n "$NS48" rollout status deploy/relsvc --timeout=120s >/dev/null

# 2. The repo. v1: both jobs speak TAG.
cat > "$d/build/Jenkinsfile" <<'EOF2'
// rel-build: build payments/relsvc from demo-api's main, push it, deploy it.
@Library('platform-lib') _

pipeline {
    agent {
        kubernetes {
            yaml libraryResource('podtemplates/build.yaml')
            defaultContainer 'python'
        }
    }
    options {
        skipDefaultCheckout()
        timestamps()
        timeout(time: 15, unit: 'MINUTES')
        disableConcurrentBuilds()
    }
    stages {
        stage('Checkout app') {
            steps {
                container('jnlp') {
                    dir('app') {
                        script {
                            def vars = git(url: 'http://gitea.git.svc.cluster.local:3000/payments/demo-api.git', branch: 'main')
                            env.APP_SHA = vars.GIT_COMMIT.substring(0, 8)
                        }
                    }
                }
            }
        }
        stage('Build and push') {
            steps {
                script {
                    env.IMAGE_TAG = "rel-${env.BUILD_NUMBER}-${env.APP_SHA}"
                    env.IMAGE = buildImage(repository: "${env.PLATFORM_REGISTRY}/payments/relsvc",
                                           tag: env.IMAGE_TAG, context: 'app', push: true)
                    echo "BUILT ${env.IMAGE}"
                }
            }
        }
        stage('Deploy') {
            steps {
                build job: 'rel-deploy', wait: true,
                      parameters: [string(name: 'TAG', value: env.IMAGE_TAG)]
            }
        }
    }
}
EOF2
cat > "$d/deploy/Jenkinsfile" <<'EOF2'
// rel-deploy: roll an image out to namespace rel-demo and wait for it.
@Library('platform-lib') _

pipeline {
    agent {
        kubernetes {
            yaml libraryResource('podtemplates/build.yaml')
            defaultContainer 'deploy'
        }
    }
    parameters {
        string(name: 'TAG', defaultValue: '', description: 'relsvc image tag to deploy, e.g. rel-12-1a2b3c4d')
    }
    options { timestamps(); timeout(time: 10, unit: 'MINUTES') }
    stages {
        stage('Pick image') {
            steps {
                script {
                    if (params.TAG) {
                        env.DEPLOY_IMAGE = "${env.PLATFORM_REGISTRY}/payments/relsvc:${params.TAG}"
                    } else {
                        env.DEPLOY_IMAGE = 'MISSING'
                    }
                    echo "DEPLOYING ${env.DEPLOY_IMAGE}"
                }
            }
        }
        stage('Deploy') {
            steps {
                deployToEks(namespace: 'rel-demo', deployment: 'relsvc',
                            manifests: 'deploy/k8s', image: env.DEPLOY_IMAGE)
            }
        }
    }
}
EOF2
git -C "$d" init -q -b main
git -C "$d" add -A
git -C "$d" -c user.name="Platform team" -c user.email="platform@playground.local" commit -q -m "Release pipelines: rel-build and rel-deploy"
gitea_api POST /orgs/payments/repos '{"name":"rel-pipelines","private":false,"description":"payments rel-build/rel-deploy (drill 48)"}' >/dev/null
git -C "$d" push -q "$(repo_url "$REPO48")" main
rm -rf "$d"

# 3. Last week: Priya's rename. rel-build is not touched.
as_teammate "Priya (payments)" "$REPO48" "rel-deploy: IMAGE_TAG (matches the release job); no tag = re-apply what is running" <<'SH'
python3 - <<'PY'
p = "deploy/Jenkinsfile"
s = open(p).read()
s = s.replace("string(name: 'TAG', defaultValue: ''", "string(name: 'IMAGE_TAG', defaultValue: ''")
old = """                    if (params.TAG) {
                        env.DEPLOY_IMAGE = "${env.PLATFORM_REGISTRY}/payments/relsvc:${params.TAG}"
                    } else {
                        env.DEPLOY_IMAGE = 'MISSING'
                    }
"""
new = """                    if (params.IMAGE_TAG) {
                        env.DEPLOY_IMAGE = "${env.PLATFORM_REGISTRY}/payments/relsvc:${params.IMAGE_TAG}"
                    } else {
                        // No tag given: re-apply whatever is running, so a failed deploy can be re-run safely.
                        container('deploy') {
                            env.DEPLOY_IMAGE = sh(returnStdout: true, script: "kubectl -n rel-demo get deployment relsvc -o jsonpath='{.spec.template.spec.containers[0].image}'").trim()
                        }
                    }
"""
assert old in s
s = s.replace(old, new)
open(p, "w").write(s)
PY
SH

# 4. The jobs. rel-deploy has run once since the rename (Priya tested it with no
#    tag), so Jenkins knows IMAGE_TAG; wait for that run, then start rel-build.
job48 "$JOBB" deploy/Jenkinsfile
job48 "$JOBA" build/Jenkinsfile
jenkins_post "$JENKINS_URL/job/$JOBB/build?delay=0" >/dev/null
for _ in $(seq 1 90); do
  r=$(jenkins_get "/job/$JOBB/1/api/json?tree=building,result" 2>/dev/null || true)
  [[ -n $r && $(jq -r .building <<<"$r") == false ]] && break
  sleep 3
done
[[ $(jq -r '.result' <<<"$r") == SUCCESS ]] || { echo "the test run of $JOBB did not succeed -- see $JENKINS_URL/job/$JOBB/1/console"; exit 1; }
# This morning's run: Sam's change goes through rel-build. Not waited for.
jenkins_post "$JENKINS_URL/job/$JOBA/build?delay=0" >/dev/null

# 5. The player's clone.
cred_file="$STATE/git-credentials"
w="$WORK/rel-pipelines"; rm -rf "$w"
git clone -q "http://$GITEA_USER@localhost:30300/$REPO48.git" "$w" -c credential.helper="store --file=$cred_file"
git -C "$w" config user.name "You (platform team)"
git -C "$w" config user.email "you@playground.local"
