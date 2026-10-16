From: Sam (payments team)                                     #help-platform

  pushed a one-line change to demo-api. pipeline went red at Deploy after 3
  minutes. I ran `kubectl get pods -n demo-ci` and it's just the two old pods,
  Running, no errors, no CrashLoop, nothing. the new pod never even appears.
  how do I debug a pod that doesn't exist?

From: FinOps bot                                              #platform-changes

  Applied namespace cost guardrails to demo-ci (ticket FIN-2231).
