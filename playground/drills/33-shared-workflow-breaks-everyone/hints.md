Two repos, nobody pushed, both red at the same minute: the change is in something
they share. Open one failing run: the annotation says which file is invalid and why.
Then see who changed what in the shared repo:
  git -C ~/platform-playground-github/playground-workflows pull && git log --oneline -5
---
First stop the bleeding, THEN make it unrepeatable. In the shared repo: git revert the
commit and push to main (a NEW commit: other people have clones; no reset + force-push),
or make the new input optional with a default. Rolling forward beats rewriting.
---
"Can't happen again": callers reference the shared workflow by a release, not by a
moving branch. Tag the fixed main (v1.0.1 -- never move or delete v1.0.0, others may
already depend on it), and change every caller's `uses: ...python-lint.yml@main` to
`@v1.0.1` (or a full commit SHA). demo-api's main is protected, so that one goes
through a pull request; search-api takes a direct push. The new input can come back
later as a tagged release that accepts both.
