Compare three things: what the ConfigMap holds, what a pod's environment
holds, and what the pods' age says.
  kubectl -n helm-drill-82 get cm demo-api -o yaml | grep VERSION
  kubectl -n helm-drill-82 exec deploy/demo-api -- printenv VERSION
  kubectl -n helm-drill-82 get pods
Environment variables from a ConfigMap (envFrom) are read when the container
STARTS. What makes Kubernetes start new pods? Then read the history of the
Deployment template:
  git -C ~/platform-playground/helm-drill-82 log -p -- chart/demo-api/templates/deployment.yaml
---
Pods only restart when the POD TEMPLATE changes. A ConfigMap edit alone changes
nothing in the template. The standard Helm answer is an annotation on the pod
template that holds a hash of the rendered ConfigMap, so any config change is a
template change and therefore a rolling update. Somebody removed it ("noisy
diffs"). Check:  helm -n helm-drill-82 get manifest demo-api | grep -n checksum
---
Put it back in templates/deployment.yaml, under spec.template.metadata.annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
Bump `version:` in Chart.yaml, push, run the job: this upgrade changes the
template (the annotation is new), so the pods roll and pick up 2026.10.2.
`kubectl rollout restart` would show the new label today and break again on the
next config change; a random or `now` annotation would restart every pod on every
upgrade, even when nothing changed. The check changes the config itself and
watches the pods.
