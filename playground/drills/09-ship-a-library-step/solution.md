ROOT CAUSE
  Nothing is broken. This is how duplication starts: a block that is "just a
  few lines" has no owner, so every team that needs it copies it, and the
  copies drift (checkout lost the fail-fast flag a month ago and nobody
  noticed). The fix is an owner: one versioned step in the shared library.

DO IT IN THIS ORDER
  1. Write the step on a BRANCH of platform-lib (vars/pytestCommand.groovy):

       /** Test command for Python repos. Usage: testCommand: pytestCommand() ... */
       def call() {
           List flags = ['-q', '--junitxml=test-results.xml']
           if (env.BRANCH_NAME != 'main') { flags << '-x' }
           return "pip install -q -r requirements.txt && python -m pytest ${flags.join(' ')}"
       }

     File name = step name; `call` is what the Jenkinsfile invokes.
  2. TEST it before anyone depends on it: a throwaway pipeline job (or a
     branch of demo-api) with @Library('platform-lib@your-branch') _ . The
     library resolves any ref, so a branch is a free staging environment.
  3. Merge to main, then RELEASE: git tag v1.1.0 <the merge commit>; git push
     origin v1.1.0. Additive feature, nobody breaks: MINOR bump. Never touch
     v1.0.0: search-indexer is pinned to that exact commit.
  4. Adopt: demo-api -> @Library('platform-lib@v1.1.0') _ and
     testCommand: pytestCommand(); delete the block. Wait for the green build.
     The other teams move when THEY choose (checkout and search-indexer get
     a PR from you, canary first).

WHAT WORKS BUT HURTS (the check penalizes these)
  - demo-api on @main: the day someone pushes a bad commit to the library,
    this team is the canary, unasked. Pin a tag.
  - moving v1.0.0 forward to "include the step": every team pinned to it
    changes under its feet. A tag is a release; releases are immutable.
  - merging to main without tagging, or tagging a branch commit that never
    reached main (the next release drops your step).
  - touching standardPipeline in the same release. Additive means additive.

THINGS A LIBRARY AUTHOR MUST KNOW
  - vars/ steps run as CPS code on the CONTROLLER. Anything the pipeline
    "remembers" must be serializable (implements Serializable in src/ classes);
    a non-serializable local (a Matcher, a JsonSlurper result) held across a
    step like sh or sleep dies with NotSerializableException. Heavy parsing
    belongs in @NonCPS methods (no pipeline steps inside them) or, better, in
    a script run by `sh` on the AGENT, not on the controller that every team
    shares. A step that only builds a String, like this one, needs no agent
    at all: that is why it works outside a node.
  - src/ holds classes and testable logic (ImageTag); vars/ is the thin,
    documented surface teams call.
  - Library code is trusted: it runs outside the Script Security sandbox.
    That is power and responsibility, and why a library change needs review.

SAY THIS IN THE INTERVIEW
  "Copy-pasted pipeline blocks drift, so I turn them into a step in the shared
  library and release it like any dependency: written on a branch, tried from
  a throwaway job with @Library('platform-lib@branch'), merged, tagged with a
  semantic version, and only then adopted by one pilot team pinned to the tag.
  Teams pin tags, so a release never changes anyone's build unless they bump
  it, and the blast radius of a mistake is one pilot team, not all of them.
  A new step with no behaviour change is a minor version; a removed parameter
  is a major, and ships as 'accept both, deprecate, remove'. I also know what
  runs where: library steps are CPS on the controller, so I keep them thin,
  serializable and free of heavy work, and push real work to the agent."

  Background: drill 07 (what an unpinned library costs), drill 01 (library
  versions), platform-lab docs/ci-track.md "How do you share pipeline code
  across teams?".
