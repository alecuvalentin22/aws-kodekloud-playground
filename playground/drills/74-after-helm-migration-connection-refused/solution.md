ROOT CAUSE
  The Helm chart migration relabelled ledger's pods from `app: ledger` to
  `app.kubernetes.io/name: ledger` + `app.kubernetes.io/instance: ledger`. A Deployment's
  selector is immutable, so "migrating" it meant deleting and re-creating the Deployment
  with the new labels. The Service was not part of the PR and still has
  `selector: {app: ledger}`. A Service does not know Deployments; it selects PODS by
  label, continuously. No pod has `app: ledger` any more, so the Service has zero
  endpoints. The ClusterIP still exists and still resolves, but kube-proxy has no backend
  for it and rejects the connection. Both ledger pods are Running and Ready the whole
  time -- readiness only matters for pods the Service already selects.

  The error, as the app sees it:
    ERROR could not reach http://ledger:8080/ -> <urlopen error [Errno 111] Connection refused>
  (with a selector-less/empty Service, kube-proxy answers with an immediate reject; on
  some CNIs or in ipvs mode the symptom is a connect timeout instead.)

HOW TO SEE IT
  kubectl -n platform-lab-drill74 describe svc ledger          # Selector: app=ledger, Endpoints: <none>
  kubectl -n platform-lab-drill74 get endpointslices -l kubernetes.io/service-name=ledger
                                                               # ENDPOINTS: <unset>
  kubectl -n platform-lab-drill74 get pods --show-labels       # app.kubernetes.io/name=ledger,...
  kubectl -n platform-lab-drill74 get pods -l app=ledger       # "No resources found" = the selector matches nothing
  git -C ~/platform-playground-aws/drill74 log -p              # the PR touched only ledger-deploy.yaml
  (A second classic with the same "Endpoints: <none>" shape is targetPort not matching the
  container port: then the endpoints exist but the connection is refused by the pod itself.
  Endpoints empty = selector/readiness problem; endpoints present but refused = port problem.)

FIX
  Change the Service selector to the labels the pods carry now, in ledger-svc.yaml, and
  kubectl apply it:
      selector:
        app.kubernetes.io/name: ledger
        app.kubernetes.io/instance: ledger
  The EndpointSlice controller fills in both pod IPs within a second; checkout logs OK.
  Use name+instance (the chart's pair), not just name, so two releases of the same chart
  in one namespace do not get mixed.

  Alternative: add `app: ledger` back to the Deployment's pod TEMPLATE (labels may differ
  from the selector; only the selector is immutable). That works and rolls the pods, but it
  keeps the legacy label alive just to satisfy one Service, so the migration is never
  finished and the next chart-managed Service will not have it. Acceptable as a bridge
  while other consumers still select app=ledger; the long-term answer is one set of labels
  everywhere.

  NOT:
  - a pod IP (or the Service ClusterIP) in checkout's LEDGER_URL: the log goes green, the
    Service stays empty, and the first pod restart breaks it again (PENALTY 30).
  - a selector-less Service + hand-made Endpoints/EndpointSlice: it works until a pod is
    replaced; nothing updates the IPs and readiness stops protecting callers (PENALTY 20).
  - `kubectl label pod ... app=ledger` on the running pods, or scaling ledger to 1: it
    "works" for exactly one rollout; the Deployment template is the source of truth
    (PENALTY 10; scaling down fails the check).

WHAT STOPS IT RECURRING
  Ship the Service in the same chart/PR as the Deployment so selector and labels come from
  the same helper (selectorLabels in the chart); a smoke test after every deploy that
  asserts `kubectl get endpointslices` has ready endpoints (or an alert on kube-state-metrics
  kube_endpoint_address_available == 0 for a Service that has a Deployment behind it);
  a PR check (helm template | kubeconform / conftest) that every Service selector matches
  at least one workload's template labels.

HOW THIS DRILL MADE THE FAILURE (honest version)
  break.sh creates namespace platform-lab-drill74 with ledger (2 replicas, python
  http.server), its Service (selector app: ledger) and checkout (python polling loop), proves
  checkout logs OK, then applies a second commit: ledger-deploy.yaml gets the
  app.kubernetes.io/* labels in metadata, selector and template, the old Deployment is
  deleted (selector is immutable) and the new one applied. Service file untouched. The
  failure is real: the Service genuinely has no endpoints. check.sh inspects the live
  EndpointSlices, does a fresh request from the checkout pod and reads the log.

SAY THIS IN THE INTERVIEW
  "After a Helm chart migration checkout got connection refused although every pod was
  Running and Ready. I went to the Service, not the pods: describe svc showed Endpoints
  none, and the selector was app=ledger while the pods had been relabelled to
  app.kubernetes.io/name=ledger. A Service is a label selector that is evaluated
  continuously against pods; the Deployment's selector is immutable, so the migration had
  re-created the Deployment with new labels and nobody touched the Service. I changed the
  Service selector to the new labels and applied it, rather than adding the old label back
  or pointing checkout at a pod IP. To prevent it I would keep Service and Deployment in
  the same chart with shared selector helpers and alert on a Service with zero available
  endpoints."
