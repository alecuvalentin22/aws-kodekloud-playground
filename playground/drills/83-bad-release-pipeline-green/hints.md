Service first, root cause second. What did the cluster get, and what was
there before? The release has a history; the pipeline's descriptions say which
build made each revision:
  helm --kube-context kind-playground -n helm-drill-83 history demo-api
  helm --kube-context kind-playground -n helm-drill-83 get values demo-api --revision 3
  kubectl -n helm-drill-83 get pods,cm
Then read what the Deploy stage of Jenkinsfile.helm actually runs (git log -p
-- Jenkinsfile.helm) and compare it with what its comments and error message claim.
---
Recover with the release record, not with edits to live objects:
  helm -n helm-drill-83 rollback demo-api 2 --wait --timeout 2m
(revision 2 is the last one whose values did not set FAIL_HEALTH; rollback makes a
NEW revision 4 with revision 2's content). Not uninstall + install: that throws the
history away. Staging also moved to the Recreate strategy in the same week, which is
why this release took every pod down instead of stalling beside the old ones.
In Jenkinsfile.helm, Sam removed `--atomic --wait --timeout "$TIMEOUT"` from the
helm upgrade and deleted the Test stage: without --wait the command returns as soon
as the API accepted the manifests, so "green" only means "Kubernetes accepted the YAML".
---
Put the safety back: on the helm upgrade command  --atomic (Helm 4 name:
--rollback-on-failure) --wait --timeout "$TIMEOUT", and restore the Test stage:
    stage('Test') { steps { sh 'helm -n "$NAMESPACE" test "$RELEASE" --timeout 30s --logs' } }
Push, then prove it the way the check does: run the job with
EXTRA_SET=config.FAIL_HEALTH=true and TIMEOUT=60s. The build must be RED, helm
history must show a failed revision followed by a rollback, and staging must
still answer.
