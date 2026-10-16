Three teams, same time, none of them pushed: the change is in something
they all share. What do all three pipelines load? Check its recent history:
  git -C ~/platform-playground/platform-lib pull && git -C ~/platform-playground/platform-lib log --oneline -5
---
First stop the bleeding, THEN make it impossible to repeat. Stopping the
bleeding on a shared repo: `git revert <sha>` and push (a new commit),
not a reset + force-push -- other people have clones of main.
---
"Can't happen again": a team that pins @Library('platform-lib@v1.0.0') is
immune to main. The platform team then tags releases (v1.1.0 ...) and moves
teams forward on purpose, canary team first. Jordan's rename can come back as
a tagged release that accepts BOTH names for a while.
