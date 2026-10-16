From: Dana (payroll team)                                     #help-platform

  URGENT: our namespace `payroll` is gone -- the ConfigMap with the payout
  calendar and the Secret with the bank API credentials. Someone ran a cleanup
  script. We never put them in git (yes, we know). Can you get them back
  EXACTLY as they were? Re-typing them is not an option, the values are gone.

From: Platform runbook                                        #platform

  etcd snapshots are taken every 6 h and on demand; they are copied off the
  server (homelab/README.md, "Backups"). There is one from right before the
  deletion.

Write what you did, and what it cost, to:
  ~/platform-playground-homelab/answers/24.md
