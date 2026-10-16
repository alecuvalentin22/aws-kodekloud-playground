Find it first: which build, which step, which line? Open the console of a
recent main build and search for the login step. What does Jenkins print for
every line of an `sh` step, and with what expanded?
---
Two separate jobs: stop NEW leaks (the library: why was `set +x` there? read
the comment above it in buildImage.groovy) and deal with the OLD ones. Every
build that ran since Jordan's commit has the token in its log. Jenkins keeps
build records until you delete them.
---
Fix the library, rebuild main, then delete the leaky build records (build
page -> Delete build, or the REST API: POST .../job/demo-api/job/main/<n>/doDelete).
Then the part security will ask about: can you REVOKE what leaked? Read the
solution's last section only after you have an answer.
