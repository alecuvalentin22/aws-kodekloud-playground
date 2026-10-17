Sam's build is not failing, it is waiting. With Kubernetes agents "waiting" means
no pod could be started for it. So who is holding the pods that DO exist?
  kubectl --context kind-playground -n jenkins get pods
Which builds do they belong to (pod name, or `describe pod`), what are those
builds doing right now, and for how long? Open one in Jenkins.
---
Two order-router builds sit at "Release order-router to prod?" and each keeps its
agent pod, doing nothing, until a human clicks. The cloud allows 2 pods
(Manage Jenkins -> Clouds -> kubernetes -> Concurrency limit), so everyone else
queues. Raising that number only moves the wall: a pending approval can last days
and each parked build costs a pod. Where is `input` in the Jenkinsfile, relative
to the agent? And what ends a build that nobody ever answers?
---
Fix the Jenkinsfile in ~/platform-playground/order-router: top level `agent none`,
an agent only on the stages that do real work (Build, deploy), the approval in a
stage with NO agent and wrapped in a `timeout`. Keep the approval itself.
Then deal with the two parked builds: ABORT them (releasing the release manager's
decision to someone else is not your call, so do not click Proceed), and look at
`get pods` again. Push, and let a build reach the approval to confirm it holds nothing.
