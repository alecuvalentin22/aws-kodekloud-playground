# shellcheck shell=bash
# Helpers for drill 82 only (sourced after lib/common.sh). The drill lives in its own
# Gitea repo, namespace, Jenkins job and chart path in the registry, so it never
# touches demo-api's baseline (payments/demo-api, demo-ci, demo-helm-ci).
N=82
NS=helm-drill-82
REPO=payments/helm-drill-82
JOB=helm-drill-82
REL=demo-api
FULL=demo-api                                   # what the chart names its objects
CHARTS_PATH=platform-lab/charts-helm-drill-82    # OCI path Jenkinsfile.helm pushes to (own, not demo-api's)
SF="$STATE/drill82.env"                        # what break.sh recorded for check.sh / reset.sh
CLONE="$WORK/helm-drill-82"

HELM() { helm --kube-context "$CTX" "$@"; }

# vgt A B -- is version A greater than version B (sort -V)
vgt() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1) == "$1" ]]; }

# seed_dir DIR IMAGE_TAG -- the team's repo content: the app, the chart and
# Jenkinsfile.helm copied from ci/apps/demo-api, pointed at THIS drill.
seed_dir() {
  local d=$1 tag=$2 src="$LAB_ROOT/ci/apps/demo-api"
  rm -rf "$d"; mkdir -p "$d"
  cp "$src/Dockerfile" "$src/app.py" "$src/requirements.txt" "$src/Jenkinsfile.helm" "$d/"
  cp -R "$src/chart" "$d/chart"
  rm -f "$d/chart/demo-api/README.md"
  cat > "$d/README.md" <<EOF2
# demo-api chart (payments team)

  chart/demo-api/    the Helm chart (values.yaml, values-<env>.yaml, values.schema.json)
  Jenkinsfile.helm   lint -> template -> package -> push (OCI) -> deploy -> test
  chart/ci-rbac.yaml what the pipeline's ServiceAccount needs in namespace $NS
EOF2
  D="$d" NS="$NS" REL="$REL" TAG="$tag" CHARTS="$CHARTS_PATH" python3 - <<'PY'
import os, pathlib
d = pathlib.Path(os.environ["D"]); ns = os.environ["NS"]; rel = os.environ["REL"]
tag = os.environ["TAG"]; charts = os.environ["CHARTS"]
def sub(path, pairs):
    p = d / path; s = p.read_text()
    for old, new in pairs:
        assert old in s, (path, old)
        s = s.replace(old, new)
    p.write_text(s)
sub("Jenkinsfile.helm", [
    ("demo-helm-ci", ns),
    ("string(name: 'RELEASE', defaultValue: 'demo-api'", "string(name: 'RELEASE', defaultValue: '%s'" % rel),
    ("params.RELEASE     ?: 'demo-api'", "params.RELEASE     ?: '%s'" % rel),
    ("string(name: 'IMAGE_TAG', defaultValue: ''", "string(name: 'IMAGE_TAG', defaultValue: '%s'" % tag),
    ('oci://${registry}/platform-lab/charts"', 'oci://${registry}/%s"' % charts),
])
sub("chart/ci-rbac.yaml", [("demo-helm-ci", ns), ("ci/apps/demo-api/chart/ci-rbac.yaml", "chart/ci-rbac.yaml")])
for f in ("chart/demo-api/values.yaml", "chart/demo-api/values-staging.yaml"):
    sub(f, [("10.77.0.31:30500/platform-lab/demo-api", "kind-registry:5000/platform-lab/demo-api"),
            ("main-488bac7e-3", tag)])
sub("chart/demo-api/templates/_helpers.tpl", [("bug, see playground drill 74)", "bug)")])
PY
}

# repo_publish DIR -- first commit by the platform team, repo created in the payments org
repo_publish() {
  local d=$1
  git -C "$d" init -q -b main
  git -C "$d" add -A
  git -C "$d" -c user.name="Platform team" -c user.email="platform@playground.local" \
    commit -q -m "Initial import: demo-api chart and Jenkinsfile.helm"
  gitea_api POST /orgs/payments/repos "{\"name\":\"helm-drill-$N\",\"private\":false,\"description\":\"drill $N (Helm)\"}" >/dev/null
  git -C "$d" push -q "$(repo_url "$REPO")" main
}

# apply_rbac DIR -- the namespace and the Role the pipeline needs (chart/ci-rbac.yaml, as the chart README says)
apply_rbac() { K apply -f "$1/chart/ci-rbac.yaml" >/dev/null; }

# job_scm IMAGE_TAG -- Pipeline-from-SCM job on this drill's repo, Script Path Jenkinsfile.helm.
# The three string parameters are declared on the job so the very first build
# can be started WITH parameters; from then on Jenkinsfile.helm declares them.
job_scm() {
  local tag=$1 f="$STATE/scratch/job$N.xml"
  mkdir -p "$STATE/scratch"
  cat > "$f" <<EOF2
<?xml version="1.1" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>Drill $N: deploys $REPO with Jenkinsfile.helm into $NS. Removed by play reset.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition><name>IMAGE_TAG</name><defaultValue>$tag</defaultValue></hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition><name>EXTRA_SET</name><defaultValue></defaultValue></hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition><name>TIMEOUT</name><defaultValue>3m</defaultValue></hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$GITEA_IN_CLUSTER/$REPO.git</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
      <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile.helm</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF2
  jenkins_post -H 'Content-Type: application/xml' --data-binary "@$f" "$JENKINS_URL/createItem?name=$JOB" >/dev/null
  local rc=$?; rm -f "$f"; return $rc
}

job_delete() { jenkins_post "$JENKINS_URL/job/$JOB/doDelete" >/dev/null 2>&1 || true; }

# job_run OUTFILE LIMIT_SECONDS [name=value ...] -- build once WITH parameters,
# wait for it, save the console to OUTFILE; the result (SUCCESS, FAILURE,
# ... or TIMEOUT) is left in JOB_RESULT and the build number in JOB_NUM.
job_run() {
  local out=$1 limit=$2 t0 b kv; shift 2
  local args=()
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  JOB_NUM=$(jenkins_get "/job/$JOB/api/json?tree=nextBuildNumber" | jq -r .nextBuildNumber) || return 1
  jenkins_post ${args[@]+"${args[@]}"} "$JENKINS_URL/job/$JOB/buildWithParameters" >/dev/null || return 1
  t0=$(date +%s); JOB_RESULT=TIMEOUT
  while (( $(date +%s) - t0 < limit )); do
    b=$(jenkins_get "/job/$JOB/$JOB_NUM/api/json?tree=building,result" 2>/dev/null || true)
    if [[ -n $b && $(jq -r .building <<<"$b") == false ]]; then JOB_RESULT=$(jq -r '.result' <<<"$b"); break; fi
    sleep 3
  done
  jenkins_get "/job/$JOB/$JOB_NUM/consoleText" > "$out" 2>/dev/null || : > "$out"
}

# charts_registry_cleanup -- delete the chart tags this drill's pipeline pushed (own path in the registry)
charts_registry_cleanup() {
  local t dg
  for t in $(curl -fsS "$REGISTRY_URL/v2/$CHARTS_PATH/demo-api/tags/list" 2>/dev/null | jq -r '.tags[]?' 2>/dev/null); do
    dg=$(curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      "$REGISTRY_URL/v2/$CHARTS_PATH/demo-api/manifests/$t" 2>/dev/null | tr -d '\r' \
      | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
    if [[ -n $dg ]]; then curl -fsS -X DELETE "$REGISTRY_URL/v2/$CHARTS_PATH/demo-api/manifests/$dg" >/dev/null 2>&1 || true; fi
  done
}

# leftovers_guard -- break.sh starts from nothing, or not at all
leftovers_guard() {
  if gitea_api GET "/repos/$REPO" >/dev/null 2>&1 || jenkins_get "/job/$JOB/api/json" >/dev/null 2>&1 \
     || K get ns "$NS" >/dev/null 2>&1; then
    echo "drill $N leftovers exist ($REPO / job $JOB / namespace $NS) -- run: play reset"; exit 1
  fi
}

# player_clone -- the candidate's clone, with the credential helper (no password in .git/config)
player_clone() {
  local w=$CLONE cred_file="$STATE/git-credentials"
  rm -rf "$w"
  git clone -q -c credential.helper="store --file=$cred_file" "${GITEA_URL/:\/\//://$GITEA_USER@}/$REPO.git" "$w"
  git -C "$w" config user.name "You (platform team)"
  git -C "$w" config user.email "you@playground.local"
  git -C "$w" config credential.helper "store --file=$cred_file"
}

# --- reading the cluster --------------------------------------------------

# objs_json -- stdin: YAML documents; stdout: one JSON array of the objects (kubectl, dry-run: nothing is created)
objs_json() { K create --dry-run=client -f - -o json 2>/dev/null | jq -c '(.items // [.])'; }

# sel_matches -- stdin: JSON array of objects. Succeeds when the Service has a selector and every
# key of it is a label of the Deployment's POD TEMPLATE with the same value.
sel_matches() {
  jq -e '(map(select(.kind=="Deployment"))[0].spec.template.metadata.labels // {}) as $l
         | (map(select(.kind=="Service"))[0].spec.selector // {}) as $s
         | ($s | length) > 0 and ($s | to_entries | all(.value == $l[.key]))' >/dev/null
}

rel_field() { HELM -n "$NS" status "$REL" -o json 2>/dev/null | jq -r "$1"; }   # .version  .info.status
live_chart_base() {   # chart version of the running release without the pipeline's -build.N suffix
  HELM -n "$NS" list -o json 2>/dev/null | jq -r --arg r "$REL" '.[]|select(.name==$r)|.chart' \
    | sed -E 's/^demo-api-//; s/-build\.[0-9]+$//'
}
main_chart_base() { curl -fsS "$GITEA_URL/$REPO/raw/branch/main/chart/demo-api/Chart.yaml" 2>/dev/null | sed -n 's/^version: *//p' | head -1; }

# svc_get PATH -- GET http://<service>:80PATH from inside a pod of the release (so it goes THROUGH the Service)
svc_get() {
  K -n "$NS" exec "deploy/$FULL" -- python -c \
    "import urllib.request; print(urllib.request.urlopen('http://$FULL:80$1', timeout=4).read().decode())" 2>/dev/null
}
