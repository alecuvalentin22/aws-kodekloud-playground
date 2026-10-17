Read the whole error line: it names WHO (the principal), WHAT (the action)
and WHERE (the resource). Which principal is pushing? Is it a user, the
agent's service account, or something else?
---
"ECR login written" proves less than it looks: which permission does
logging in need, and which policy already grants it to every node so it can
PULL? Pushing needs different actions. Now list what the principal has:
  aws iam list-attached-role-policies --role-name <the role in the error>
(Lab credentials for the aws CLI: set -a; . ~/.config/platform-lab/aws-lab-creds.env; set +a)
---
Something was removed in #platform-changes. Put back what the pipeline needs
-- and only that. Then rebuild main. (The check penalises "make it work"
answers that hand every pod on the node far more than push.)
