"Fails in 3 seconds, before tests" means it failed before any stage ran.
What does Jenkins do before the first stage? Open the console log of the
failed main build, and read from the TOP, not the bottom.
---
The error is about loading the library. Which versions of platform-lib
actually exist? Look at the repo's tags in Gitea, or:
  git -C ~/platform-playground/platform-lib ls-remote --tags origin
---
Fix the version in payments/demo-api's Jenkinsfile to one that exists, push,
and wait for the build (or "Scan Multibranch Pipeline Now").
