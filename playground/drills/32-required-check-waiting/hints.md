"Expected -- Waiting for status to be reported" means: the branch rule names a check
and nothing has reported under exactly that name. Compare two lists, character
for character: what the PR's Checks tab shows, and what the rule requires
(Settings > Branches, or GET /repos/<you>/playground-demo-api/branches/main/protection).
---
A job's check name is its `name:` (or its id), plus the matrix values in brackets
when it has a matrix. Who changed .github/workflows/ci.yml recently (git log -p), and
what did that do to the name `build`?
---
Two proper fixes. (a) Change the rule to require the names that exist now
("build (3.12)", "build (3.13)"). (b) Make the name stable: a final job named `build`
with `needs:` the matrix and `if: always()` that fails if any leg failed, so the rule
survives the next matrix change. Either way the rule must still require a check. Not
acceptable: removing the protection, emptying the required checks, or turning
"include administrators" off to merge.
