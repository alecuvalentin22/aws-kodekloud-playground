ROOT CAUSE
  The team's Jenkinsfile has `agent none` and gives each stage group its own
  `agent { kubernetes { ... } }`. Each of those is a SEPARATE POD with its own
  empty workspace. "Build" wrote image-ref.txt into the workspace of pod A;
  "Deploy" runs in pod B, which only did the automatic `checkout scm` -- the
  repository's files, nothing the previous stage generated. So:
    java.nio.file.NoSuchFileException: /home/jenkins/agent/workspace/demo-api_main/image-ref.txt
  The two console lines "Running on demo-api-main-xxxx-aaaa" and
  "Running on demo-api-main-xxxx-bbbb" give it away. Same workspace PATH,
  different machine.
  (The image WAS built and pushed, which is why the registry has the tag, and
  why a retry changes nothing: it never reached Deploy.)

WHAT THE FILE SYSTEM IS, AND IS NOT
  - A workspace lives on one agent. Different agent, different disk.
  - It is not on the controller. This Jenkins runs with numExecutors: 0, so
    nothing builds there; the controller only orchestrates and stores build
    records. (Stash data and archived artifacts are stored there, but that is
    Jenkins moving bytes for you, not a shared workspace.)
  - Nested `stages {}` under ONE `agent` share a workspace (the Build group
    here: Test, API contract and Build image all see each other's files).

FIX (any of these; pick by size of what moves)
  1. stash/unstash, for small build outputs (a reference, a report, rendered
     manifests): in Build, after writing the file
         stash name: 'build-output', includes: 'image-ref.txt'
     and in Deploy
         unstash 'build-output'
     It is build-scoped and deleted with the build.
  2. Pass the VALUE, not a file: `env.IMAGE = image` in Build, use env.IMAGE in
     Deploy. env is build-wide, whichever agent runs the stage. (Simplest for
     one string; the golden path does exactly this.)
  3. One agent for stages that share files: move `agent` to the top of the
     pipeline. The cost is what the team was avoiding: the biggest container
     is reserved for the whole build.
  4. Big artifacts (jars, images, wheels) do not belong in stash at all: push to
     the registry/Artifactory and hand over the REFERENCE.

NOT ACCEPTABLE
  - A hostPath or shared PVC mounted into both pods "so the file is there":
    it works on a one-node kind cluster and falls apart on a real one; two
    concurrent builds write the same path; files survive the build. (PENALTY 25)
  - archiveArtifacts in Build, then copyArtifacts / curl $BUILD_URL/artifact/...
    in Deploy: archiving is for people to download results after the build,
    not a transport inside one. (PENALTY 20)
  - Recomputing the tag in Deploy from BUILD_NUMBER: matches today, drifts
    the day the rule changes. (PENALTY 10)
  - Going back to the golden path and calling it fixed: it deletes the check
    the team needed. (PENALTY 25)

WHAT STOPS IT RECURRING
  - Say in the team's docs / template which stages share an agent and what
    crosses between them. Platform can offer the contract check (and a
    separate small deploy pod) in the library, so teams stay on the golden
    path; the golden path avoids this by passing env.IMAGE.
  - `when { beforeAgent true ... }` (already used) so a branch that does not
    deploy never starts the deploy pod.

SAY THIS IN THE INTERVIEW
  "A stage with its own agent is a new machine: new pod, new disk. The file
  was written to one workspace and read from another, and the console showed
  two different pod names. I did not reach for a shared volume or the
  controller. The thing that crosses is a single image reference, so I stashed
  that one file; for anything big I would push it to the registry and pass the
  reference. And I explained why 'did Jenkins lose my file' was the wrong
  question: Jenkins never had it where they were looking."
