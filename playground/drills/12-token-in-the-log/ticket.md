From: Security (automated secret scanner)                     #sec-alerts

  HIGH: string matching an AWS registry credential pattern in Jenkins build
  log demo-api/main. Visible to every user with Job/Read. Owner: platform.

From: Jordan (platform team)                                  #platform-changes

  turned tracing back on in buildImage's ECR login step, I couldn't debug a
  failed login with it hidden. builds are all green
