From: Dana (API team)                                        #help-platform

  Since this morning's security group cleanup the orders API cannot reach
  its database. Every query dies with "connection timed out" after 30
  seconds (not "connection refused", not "password authentication failed").
  The DB itself is up, other tools on the DB tier are fine.
  Platform replaced the API tier's security group with a new, tidier one
  ("platform-lab-drill73-api") and the old one was supposed to be deleted.
  It is still lying around. Nobody changed the DB tier, nobody touched the
  app. Can someone get the API talking to Postgres again? Please do not
  just open the database to the world, security will notice.

From: Marc (platform)                                        #help-platform

  The delete of the old group failed, I did not look into why. Output is in
  cleanup.log. I would rather not guess: just make the DB accept the API.
  The API's network is in ~/platform-playground-aws/drill73
  (ids: inventory.txt, creds: . ./aws-env.sh, symptom: api-errors.log)
