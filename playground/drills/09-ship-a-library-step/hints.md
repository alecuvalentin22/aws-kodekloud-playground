Three jobs in one ticket: WRITE the step, RELEASE it, ADOPT it. Start from
what exists: git pull both clones, read demo-api's Jenkinsfile, then see how
the library lays out a step (vars/buildImage.groovy: file name = step name,
the work is in `call`). What is a "version" of platform-lib in this setup?
  git -C ~/platform-playground/platform-lib ls-remote --tags origin
---
A release is a tag, and demo-api's @Library('platform-lib@...') is what picks
it. Do not touch v1.0.0 (search-indexer is on it). Safe order: write the step
on a branch, try it from a throwaway pipeline job with
@Library('platform-lib@your-branch') _, merge to main, tag the merge commit
(v1.1.0: a new feature that breaks nobody is a MINOR bump), push the tag, and
only then point demo-api at the tag.
---
vars/pytestCommand.groovy:

  def call() {
      List flags = ['-q', '--junitxml=test-results.xml']
      if (env.BRANCH_NAME != 'main') { flags << '-x' }
      return "pip install -q -r requirements.txt && python -m pytest ${flags.join(' ')}"
  }

demo-api's Jenkinsfile: @Library('platform-lib@v1.1.0') _  and
testCommand: pytestCommand()  in place of the block. Add a doc comment on the
step; the next team will read it before using it.
