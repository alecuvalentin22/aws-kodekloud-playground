Follow ONE build through both jobs. Open the rel-build console and find the
step that starts rel-deploy; read the line(s) right after it. Then open the
rel-deploy build it started and look at its "Parameters" page and at what its
first stage printed ("DEPLOYING ..."). Do the two jobs agree on which tag?
---
rel-build starts rel-deploy with a parameter called TAG. rel-deploy's
parameter is IMAGE_TAG. A parameter the downstream job does not define is
dropped. Jenkins complains about it in the CONTROLLER's log, not in either
build's console (kubectl -n jenkins logs jenkins-0 | grep -i skipped), so rel-deploy ran with
its default: empty, which Priya's change turns into "redeploy what is running".
Green, and a no-op.
---
Pass the tag under the name the downstream job actually declares:
  build job: 'rel-deploy', parameters: [string(name: 'IMAGE_TAG', value: env.IMAGE_TAG)]
Push it, run rel-build again, and check three things: no new "Skipped
parameter" line in the controller log, rel-deploy's Parameters page shows the exact tag, and
  kubectl -n rel-demo get deploy relsvc -o wide
shows that tag. Do NOT "fix" it by deploying :latest.
