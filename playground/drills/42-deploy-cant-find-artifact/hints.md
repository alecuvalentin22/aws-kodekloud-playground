Compare the two stages in the console log. Each prints where it runs ("Running
on <pod> in <workspace path>"). Same pod? Then watch the agent pods while a
build runs:
  kubectl --context kind-playground -n jenkins get pods -w
How many pods does one build get?
---
A workspace belongs to ONE agent. A stage with its own `agent` gets a new pod
and a fresh workspace: Jenkins checks the repo out again, but anything the
previous stage wrote is not there. (It is not on the controller either: this
Jenkins has 0 executors, nothing builds there.) So the question is how the
output of one agent reaches the next. Options: stash/unstash for small files,
a value passed through env, one agent for the stages that share files, or an
artifact repository for big things.
---
Smallest honest fix in payments/demo-api's Jenkinsfile: after writing
image-ref.txt, `stash name: 'build-output', includes: 'image-ref.txt'`; in
Deploy, `unstash 'build-output'` before readFile. (Or: put the image in
env.IMAGE and use it in Deploy; or move `agent` up to the pipeline level.)
Keep the API contract stage -- it is the reason the team left the golden
path. Push and watch main.
