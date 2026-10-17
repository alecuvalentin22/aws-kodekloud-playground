ROOT CAUSE
  The fulfilment team's order-router Jenkinsfile declares its agent (a
  Kubernetes pod) for the WHOLE pipeline, and the release-manager approval is an
  `input` step in a stage inside it. While a build waits for a human, it keeps
  its pod: running, idle, reserved. There is no timeout either, so "tomorrow
  09:00" can be "next week". Two such builds hold both of the 2 agent pods the
  Kubernetes cloud allows (Concurrency limit, a platform guardrail), so every
  other team's build waits for a pod that will not come. Nothing is broken and
  nothing is red; the capacity is simply all taken by builds doing nothing.
  How you see it (verbatim, local playground):
    Sam's console:   Still waiting to schedule task
                     All nodes of label 'demo-api_main_16-3mw49' are offline
                     (no pod was even created for it: the cloud is at its cap)
    kubectl -n jenkins get pods        order-router-main-1-... and -2-..., 2/2 Running, hours old
    the order-router builds            paused at "Release order-router to prod?"
    Manage Jenkins -> Clouds -> kubernetes -> Concurrency limit: 2
    the fix commit's own build         queues behind them too, until the parked ones are aborted

FIX (the pipeline, not the cap)
  Jenkinsfile: `agent none` at the top; an agent only on the stages that do real
  work; the approval in a stage with NO agent, inside a timeout:

    pipeline {
        agent none
        options { timestamps(); timeout(time: 24, unit: 'HOURS') }   // the safety net
        stages {
            stage('Build') {
                agent { kubernetes { yaml '...'; defaultContainer 'tools' } }
                steps { sh '...' }
            }
            stage('Deploy to staging') { agent { kubernetes {...} } steps { sh '...' } }
            stage('Approve prod') {
                options { timeout(time: 12, unit: 'HOURS') }
                steps { input message: 'Release order-router to prod?', ok: 'Release' }
            }
            stage('Deploy to prod') { agent { kubernetes {...} } steps { sh '...' } }
        }
    }

  A parked build then costs one lightweight controller thread and no pod (the
  `input` directive on a stage that has its own agent does NOT do that: the
  agent is allocated first). The `timeout` makes an unanswered question end the
  build as ABORTED instead of living forever.
  Then the builds that are parked right now: ABORT them (never Proceed: a prod
  release is the release manager's decision, not the platform engineer's).
  Their pods go away (Terminating for up to 30 s); Sam's and Mia's queued builds start by themselves.
  KEEP the approval. Compliance asked for it; "fix" by deleting it is the answer
  that loses the interview.

NOT the fix
  Raising the cloud's cap: it only buys a few approvals' worth of time, costs
  node capacity, and the next team that adds a gate does the same. The cap is
  the platform team's guardrail; it did its job by making the problem visible.

WHAT STOPS IT RECURRING
  - A short review rule (and a library helper): `input` never inside an agent;
    every wait has a timeout. Make it the default in the golden-path
    standardPipeline (an `approval:` option that does the right thing once).
  - A dashboard/alert on "pods older than N hours in namespace jenkins" and on
    queue time, so it is noticed in minutes, not at 10:12.
  - Approvals that outlive a working day belong in the deploy tool (an Argo CD
    sync window / a protected environment), not in a parked build.

SAY THIS IN THE INTERVIEW
  "Builds queued, nothing red, so I looked at who was using the capacity: two
  agent pods, hours old, both idle. The builds behind them were paused at a
  manual approval, and the approval sat inside the stage that owns the agent, so
  each waiting build kept a pod. The cloud had a cap of two, so one team's
  overnight approval froze everyone. I did not raise the cap, and I did not
  remove the approval, which compliance required. I moved the `input` out of the
  agent with a timeout around it, aborted the two parked builds, and the queue
  drained on its own. Then I proposed making that the default in the shared
  library, so a team cannot reintroduce it."
