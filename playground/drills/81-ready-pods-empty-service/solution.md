ROOT CAUSE
  A "tidy-up" of templates/_helpers.tpl gave the Service its own selector helper:

      {{- define "demo-api.serviceSelector" -}}
      app.kubernetes.io/name: {{ include "demo-api.fullname" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}

  while the Deployment's selector and every pod label still come from
  selectorLabels, which uses {{ include "demo-api.name" . }} (the CHART name).
  For a release called "demo-api" fullname == name, so it worked on the first
  team's release. For release "checkout" fullname is "checkout-demo-api", so:

      Service selector   app.kubernetes.io/name=checkout-demo-api
      pod labels         app.kubernetes.io/name=demo-api

  A Service does not know about Deployments, it selects PODS by label,
  continuously. Nothing matches, so the EndpointSlice is empty. The ClusterIP
  exists and resolves, kube-proxy has no backend, the connection is refused.
  The pods are Ready the whole time (readiness only matters for pods a Service
  already selects), and helm upgrade --wait was happy: it waits for the
  Deployment, not for the Service to have endpoints. Only helm test, which calls
  the Service by name, noticed: that is why the Test stage was red.

HOW TO SEE IT
  kubectl -n helm-drill-81 describe svc checkout-demo-api   # Selector: ...name=checkout-demo-api, Endpoints: <none>
  kubectl -n helm-drill-81 get endpointslices               # ENDPOINTS <unset>
  kubectl -n helm-drill-81 get pods --show-labels           # ...name=demo-api
  kubectl -n helm-drill-81 get pods -l app.kubernetes.io/name=checkout-demo-api   # No resources found
  helm -n helm-drill-81 get manifest checkout | less        # what Helm applied, both sides
  git -C ~/platform-playground/helm-drill-81 log -p -- chart   # the helpers commit, chart version NOT bumped
  (Empty endpoints = selector or readiness problem. Endpoints present but refused =
  targetPort problem. Different layer, different fix.)

FIX
  Make the Service select exactly what the Deployment selects. In
  templates/service.yaml use  {{- include "demo-api.selectorLabels" . | nindent 4 }}
  again (or make serviceSelector call selectorLabels, and delete the duplicate
  if nobody needs it). Bump version: in Chart.yaml (0.1.1), push, run the
  helm-drill-81 job: Deploy, then Test goes green. Revision 3 of the release.

  Why not change selectorLabels to fullname so "both sides agree"? A Deployment's
  spec.selector is IMMUTABLE. helm upgrade would fail with
      Deployment.apps "checkout-demo-api" is invalid: spec.selector: Invalid value: ... field is immutable
  (--atomic in the pipeline rolls the attempt back, leaving the release at
  revision 2). The only ways through are deleting and re-creating the Deployment
  (helm uninstall + install, or  helm upgrade --force), which drops the pods and
  can lose the release history. Fixing the SERVICE side touches nothing
  immutable and does not restart a single pod.

NOT ACCEPTABLE
  - Hand-made Endpoints/EndpointSlice and a selector-less Service, or a pod IP in
    the callers' config: it works until the first pod is replaced. (PENALTY 30.)
  - kubectl edit/patch of the live Service (or labelling pods by hand): it works
    until the next helm upgrade or pipeline run puts the bug back, and helm get
    manifest no longer matches the cluster. (PENALTY 20.)
  - helm uninstall + install: history is gone, no rollback target. (PENALTY 10.)
  - Scaling down or deleting pods hoping they come back "different".

WHAT STOPS IT RECURRING
  - One helper for "the labels that identify this app", used by the Deployment
    selector, the pod template and the Service. Two helpers that must agree will
    eventually not.
  - helm test (or any smoke test) that goes THROUGH the Service. It was the only
    thing that caught this, and it caught it after the release was already live.
    Make the pipeline's last stage a gate, and alert on
    kube_endpoint_address_available == 0 for a Service that has a Deployment.
  - A PR check: helm template | kubeconform, plus a script asserting every
    Service selector is a subset of a workload's pod template labels. Bump the
    chart version in the same PR (it is a different package).
  - Test the chart with a release name that is NOT the chart name: helm template
    foo ./chart behaves differently from helm template demo-api ./chart.

SAY THIS IN THE INTERVIEW
  "Pods Ready and a Service that refuses connections means the Service selects
  nothing, so I went to the selector and the pod labels, not to the pods.
  describe svc showed Endpoints none; the Service wanted name=checkout-demo-api
  and the pods carried name=demo-api. git log pointed at a helpers change that
  gave the Service its own helper built from fullname while the Deployment kept
  the chart name: identical for a release called demo-api, different for
  checkout. I made the Service use the same selector helper as the Deployment,
  bumped the chart version, and let the pipeline's helm test prove it end to
  end. I did not touch the Deployment selector, because it is immutable and the
  upgrade would have been refused, and I did not patch the live Service,
  because the next helm upgrade would have undone it. Then I suggested a single
  helper for identity labels and testing the chart under a release name that
  differs from the chart name."

  Related: drill 74 (the same symptom after a label migration, on EKS),
  drill 02 (readiness and rollout), the demo-api chart README.
