The pipeline did its job: it deployed, waited, saw the new pods never become
Ready, and rolled back. So the question is not "why is Jenkins red" but "why
were the new pods never Ready". The Deploy stage's log printed the pod state
at the moment it gave up -- read that part.
---
Reproduce it in the cluster instead of guessing:
  kubectl --context kind-playground -n demo-ci get events --sort-by=.lastTimestamp | tail
  kubectl --context kind-playground -n demo-ci describe deploy demo-api
What does the readiness probe hit, and what does it get back?
---
git log -p in payments/demo-api shows what Priya changed. Compare it with
what app.py does with that variable.
