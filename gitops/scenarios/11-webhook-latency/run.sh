# QUESTION: How much of "git to live" is the reconcile, and how much is the poll?
# EXPECT: Almost all of it is the poll. Which means tuning the sync changes nothing.
#
# Scenario 04 measured git-to-live at 155s and left it there. This one takes the
# measurement apart, because the two halves have completely different fixes:
#
#   detection  -> how long until the controller NOTICES the commit
#                 Argo CD: polls every 180s (timeout.reconciliation)
#                 Flux:    GitRepository interval, 1m here
#                 fix: a webhook. Nothing else helps.
#
#   convergence -> how long from noticing to the pods being live
#                 fix: image pull time, readiness probes, sync waves
#
# Run this BEFORE and AFTER ./scripts/argocd-webhook.sh --apply.
#
# The honest caveat, which belongs in the answer out loud: a webhook is
# best-effort. GitHub retries a failed delivery a few times and then gives up.
# If Argo CD is restarting when the hook fires, that commit is simply never
# announced, and only the poll catches it. Push for speed, poll for correctness
# -- never turn the poll off.

scenario_apply() {
  echo "    measuring DETECTION latency: how long until the controller re-reads git"
  echo "    (no commit is made -- this reads the configured intervals and the"
  echo "     controller's own record of when it last looked)"
}

scenario_observe() {
  if [[ "$CTL" == "argocd" ]]; then
    echo
    echo "    configured poll interval:"
    kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null \
      | sed 's/^/      timeout.reconciliation = /'
    echo "      (empty means the 180s default)"
    echo
    echo "    is a webhook configured?"
    if kubectl -n argocd get secret argocd-secret -o jsonpath='{.data}' 2>/dev/null | grep -q 'webhook.github.secret'; then
      echo "      yes -- webhook.github.secret is set on argocd-secret"
      echo "      so detection should now be seconds, and the poll is a backstop"
    else
      echo "      no -- detection is bounded by the poll interval above"
      echo "      ./scripts/argocd-webhook.sh --apply"
    fi
    echo
    echo "    how the endpoint is reachable (or is not):"
    kubectl -n argocd get svc argocd-server \
      -o custom-columns='TYPE:.spec.type,PORTS:.spec.ports[*].nodePort' --no-headers | sed 's/^/      /'
    echo
    echo "    last sync, and how long ago:"
    kubectl -n argocd get app demo-argocd \
      -o jsonpath='      finishedAt={.status.operationState.finishedAt} revision={.status.sync.revision}{"\n"}' 2>/dev/null
  else
    echo
    echo "    Flux polls per-source, not globally -- each GitRepository has its own:"
    kubectl -n flux-system get gitrepository \
      -o custom-columns='NAME:.metadata.name,INTERVAL:.spec.interval,LASTREV:.status.artifact.revision' --no-headers 2>/dev/null | sed 's/^/      /'
    echo
    echo "    and each Kustomization has ANOTHER interval on top of it:"
    kubectl -n flux-system get kustomization \
      -o custom-columns='NAME:.metadata.name,INTERVAL:.spec.interval,READY:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null | sed 's/^/      /'
    echo
    echo "      -> worst-case detection is source interval + kustomization interval,"
    echo "         not whichever number you happened to look at first."
    echo
    echo "    Flux's webhook equivalent is a Receiver, which needs the"
    echo "    notification-controller exposed the same way:"
    kubectl -n flux-system get receiver 2>/dev/null | sed 's/^/      /' || echo "      (no Receiver configured)"
  fi
}

scenario_reset() { return 0; }
