ROOT CAUSE
  main's branch protection requires a status check called `build`. A teammate's
  commit gave the `build` job a matrix (Python 3.12 and 3.13), and a matrix job
  reports one check PER LEG, named `build (3.12)` and `build (3.13)`. Nothing
  reports plain `build` any more, so GitHub waits for it forever: "Expected --
  Waiting for status to be reported". The checks are fine; the rule names a ghost.
  (Renaming the job's `name:` has the same effect.)

FIX
  Either update the rule to the names that exist now, or (better) add a stable
  gate job that the rule requires and the matrix feeds (rename the matrix job to
  `test`, then add):
      build:                      # the name the rule requires, whatever the matrix does
        needs: test
        if: always()
        runs-on: ubuntu-latest
        steps:
          - run: test "${{ needs.test.result }}" = success
  A gate job is also how you require "all of CI" without listing every leg.
  Then Priya's branch needs the new workflow (update branch) so the check reports.
  NOT: deleting the protection, requiring no checks, or unticking "Do not allow
  bypassing the above settings" (enforce_admins) so an admin can force the merge.
  The check looks at the final state of the rule.

WHAT STOPS IT RECURRING
  A stable gate-job name as the only required check; CODEOWNERS on
  .github/workflows/ so a name change is reviewed by someone who knows the rule
  exists; a rulesets-as-code (Terraform github provider) so the rule and the
  workflow live and change together.

SAY THIS IN THE INTERVIEW
  "Expected means the rule is waiting for a check name nobody reports. I compared
  the required name with the names on the PR: someone had added a matrix, so
  `build` became `build (3.12)` and `build (3.13)`. I did not bypass the rule or
  remove it; I made the required name stable with a gate job, and told the team the
  rule and the workflow are one contract, so changes to job names go through the
  same review."
