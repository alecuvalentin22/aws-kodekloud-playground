Start from the Service, not from the pods. A Service does not point at
Deployments, it selects PODS by label. Compare the two sides:
  kubectl -n helm-drill-81 describe svc checkout-demo-api       # Selector, Endpoints
  kubectl -n helm-drill-81 get endpointslices
  kubectl -n helm-drill-81 get pods --show-labels
Then ask git who touched the chart since the first deploy that worked:
  git -C ~/platform-playground/helm-drill-81 log -p -- chart
---
The Service selects app.kubernetes.io/name=checkout-demo-api; the pods carry
app.kubernetes.io/name=demo-api. A recent commit gave the Service its own
helper in _helpers.tpl (serviceSelector) built from the release-qualified name
(fullname), while the Deployment and its pods still use selectorLabels, built
from the chart name. Same chart, two helpers, two answers, as soon as the
release is not literally called "demo-api".
Careful which side you change: a Deployment's spec.selector is IMMUTABLE.
---
Make the Service use the SAME labels as the Deployment's selector again: have
templates/service.yaml include "demo-api.selectorLabels" (or make serviceSelector
call it). Do not change selectorLabels itself: helm upgrade would be refused
with "field is immutable" (and the pods would not be touched anyway).
Bump `version:` in chart/demo-api/Chart.yaml (the templates changed, so the
package must have a new number), push, run the helm-drill-81 job, and let its
Test stage prove it. Locally:  helm --kube-context kind-playground -n helm-drill-81 test checkout
