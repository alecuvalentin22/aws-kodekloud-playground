Start at the Service, not the pods. A Service is just a name plus a label
selector; what it actually points at is its endpoints:
`kubectl -n platform-lab-drill74 get endpointslices -l kubernetes.io/service-name=ledger`
and `kubectl -n platform-lab-drill74 describe svc ledger` (look at Selector and Endpoints).
---
Compare the two sides of the match: `kubectl -n platform-lab-drill74 get svc ledger -o jsonpath='{.spec.selector}'`
against `kubectl -n platform-lab-drill74 get pods --show-labels`. Then try
`kubectl -n platform-lab-drill74 get pods -l app=ledger` -- what does the Service's selector select?
`git -C ~/platform-playground-aws/drill74 show HEAD` shows which file the PR touched.
---
Point the Service at the labels the pods really have (`app.kubernetes.io/name: ledger`
and `instance`), in ledger-svc.yaml, and kubectl apply it. Do it on the Service, not on the
pods: `kubectl label pod` is wiped by the next rollout, and a Service without a
selector plus hand-made endpoints stops following the pods.
