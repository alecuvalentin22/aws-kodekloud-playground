From: Sam (payments team)                                     #help-platform

  one of the two demo-api pods has been ImagePullBackOff since it got
  rescheduled this morning. the other one is fine, so nothing is down yet,
  but if that one restarts we are. I didn't change the image or the
  Jenkinsfile, same tag as yesterday. it just says it can't find it??

From: Cloud team                                              #platform-changes

  cost review: ECR was in the top 3 storage lines. added a lifecycle policy
  on platform-lab/demo-api so old images expire (COST-212). no impact expected.
