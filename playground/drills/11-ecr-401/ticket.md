From: Jordan (platform team)                                  #platform-changes

  small cleanup merged in platform-lib: removed a chown from buildImage that
  looked redundant (config.json is already mode 600). no behaviour change.

From: Sam (payments team)                                     #help-platform

  demo-api main: build + tests fine, then the push to ECR fails with
  "401 Unauthorized" after a minute of building. I checked IAM and the node
  role still has ECR push. so it's not permissions?? what is it then
