There are two different "offline"s hiding here, so work from the evidence, not
from the label. Open the node page (Manage Jenkins -> Nodes -> static-01) and
read what it says. Then look at the OTHER end of the connection: this is an
inbound agent, so the machine dials the controller. What does the agent itself
say?   docker logs --tail 20 pg-static-01      and the controller's own log:
kubectl --context kind-playground -n jenkins logs jenkins-0 -c jenkins --tail 40 | grep static-01
---
The agent loops on "Handshake error" and the controller logs "incorrect secret
for static-01": the agent is presenting a secret the controller does not
recognise. The box was rebuilt from a saved provisioning file; the file holds
an old secret. The node's CURRENT secret is on its page in Jenkins (the
command line it shows, after -secret), and in the Script Console. A container
takes its environment at creation, so restarting it changes nothing: it has to
be created again with the right secret. And Jordan's "marked offline" is a
separate flag: connecting the agent will not clear it.
---
Recreate the agent with the controller's current secret:
  playground/setup/static-agent.sh up      (it compares the secret the container
  holds with the controller's and re-creates it; it also rewrites the state
  file, so the next re-provision is right too)
Then clear Jordan's "temporarily offline" flag on the node page ("Bring this
node back online"). The queued release build starts by itself; check it
says "Running on static-01". Do not move the job: the key is only on build-01.
