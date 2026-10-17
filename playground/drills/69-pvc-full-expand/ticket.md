From: Tomas (security-engineering)                            #help-platform

  the audit-writer pod has been crash-looping since this morning and the
  compliance export that reads its log is empty for today. kubectl says:

      audit-writer-0   0/1   CrashLoopBackOff   9 (2m ago)

  I looked at the logs but I am not sure what I am looking at. we still want
  the history that is already on its disk: that log is the audit trail and
  we cannot regenerate it. nothing was deployed, the manifest is unchanged.
  namespace: platform-lab-drill69

From: Platform on-call                                        #platform-changes

  do not delete the volume or the claim. also: the cluster is a shared lab,
  keep disks small (EBS <= 30 GB each).
