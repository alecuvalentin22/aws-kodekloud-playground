ROOT CAUSE
  Two independent reasons the static node was offline, and the ticket only
  shows one of them.
  1. build-01 was re-imaged "from the saved provisioning file", and that file
     held an OLD node secret. The agent (an inbound/WebSocket agent: the machine
     dials the controller and proves who it is with the node's secret) is
     refused every time and loops on "Failed to connect: Handshake error".
     The controller says why, the agent does not:
       docker logs pg-static-01          INFO: Failed to connect: Handshake error.   (every ~10 s)
       controller log                    WebSocketAgents#doIndex: incorrect secret for static-01
       node page                         "Connection was broken" / the agent never shows as connected
  2. Jordan marked the node "temporarily offline" while working on it and never
     cleared it. That is a flag in the controller, independent of the connection:
     even a connected agent stays out of rotation.
  The job asks for label `static` (the signing key is only on build-01), so
  "Waiting for next available executor" is the correct behaviour, not a bug.

FIX
  1. Give the agent the controller's CURRENT secret (node page -> the command
     shown there, or the Script Console) and CREATE THE CONTAINER AGAIN: a
     container takes its environment at creation, restarting it keeps the old
     one.   playground/setup/static-agent.sh up   does exactly that (it compares
     the secret the container holds, not the file's, and rewrites the file).
  2. Node page -> "Bring this node back online" (clears Jordan's flag).
  3. The queued build starts by itself. Confirm "Running on static-01" in its
     console, tell Ines.

NOT the fix
  - Running the release on the built-in node (executors on the controller, or
    `label 'built-in'`): the key is not there, the release manager signs off on
    where it was signed, and the controller holds every credential and is
    deliberately set to 0 executors.
  - Clicking "Bring this node back online" and stopping there: it changes nothing
    while the agent is not connected.

WHAT STOPS IT RECURRING
  - The saved provisioning data is the source of truth: after you rotate or
    regenerate the secret, fix the file in the same change. Better, fetch the
    secret at provisioning time (an API call or a secret store), never from a
    stale copy.
  - Alert on "node offline for > N minutes" and on a node that is offline-by-flag
    for more than a working day: both were visible for two days here.
  - Nodes that only one team's release depends on need an owner and a runbook.

SAY THIS IN THE INTERVIEW
  "The job was queued, not failing, so I looked at the node, and then at the
  other end of the connection. It's an inbound agent, so the controller can't
  tell you much: the agent log said 'handshake error' and the controller log said
  'incorrect secret'. The box had been re-imaged from an old provisioning file
  with a stale secret. I recreated the container with the current secret, and
  I also had to clear a 'temporarily offline' flag someone left, which is
  separate from the connection. I did not run the release on the controller:
  the signing key lives on that box, and the controller has zero executors on
  purpose. Then I fixed the provisioning file so the next re-image is right,
  and asked for an alert on nodes offline longer than an hour."

  Static vs dynamic: a pod agent has no identity to go stale; the Kubernetes
  plugin creates it with a fresh secret every time. A static agent is a
  machine with its own lifecycle, and its secret, disk, patches and flags are
  yours to keep in step with the controller.
