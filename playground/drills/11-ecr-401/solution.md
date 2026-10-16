ROOT CAUSE
  The `deploy` container (root) writes the ECR login into a Docker config,
  mode 600. BuildKit runs rootless as uid 1000 and cannot read it. BuildKit
  does not fail on that: it warns, carries on anonymously, builds, and then
  the registry answers 401. From the EKS lab write-up (drills/18 section 1):
    WARNING: Error loading config file: open /home/jenkins/agent/workspace/demo-api_main/.docker-1/config.json: permission denied
    ...
    #11 ERROR: failed to push <acct>.dkr.ecr.us-east-1.amazonaws.com/platform-lab/demo-api:main-fa2626d4-1:
        unexpected status from HEAD request to https://<acct>.dkr.ecr.../blobs/sha256:...: 401 Unauthorized
  Jordan's "redundant" chown was what made it readable.

FIX
  Revert the commit (chown -R 1000:1000 on the config directory), rebuild.
  NOT: chmod 644 (any process in the pod reads the token), and NOT running
  BuildKit as root or privileged (root on the node for every build).

WHAT STOPS IT RECURRING
  A comment on WHY next to the chown (the lab's buildImage has one; read it),
  and a library canary job that pushes for real before a library change
  reaches every team.

SAY THIS IN THE INTERVIEW
  "401 means no credentials arrived; 403 means they arrived and were refused.
  The developer had checked IAM -- the 403 question -- so I went back up the
  log and found BuildKit warning it couldn't read the config file, 140 lines
  above the error. Root wrote it mode 600, BuildKit runs as uid 1000. I fixed
  ownership rather than loosening permissions or giving BuildKit root."

  Source: platform-lab drills/18 section 1.
