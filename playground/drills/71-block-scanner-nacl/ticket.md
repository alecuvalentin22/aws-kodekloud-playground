From: Priya (security)                                       #sec-incidents

  198.51.100.77 has been scanning our public API for the last half hour:
  login brute force, then /.env, /admin, path traversal. It is the same
  address every time. Block it at the network layer, NOW. Do not wait for
  the app team to ship a rate limiter.
  The API must stay up for everyone else: our partners call it from the
  same neighbourhood (198.51.100.0/24 and 203.0.113.0/24 are both partners).
  Nothing to do with the rest of the account; this is the API's own network.

From: Sam (backend)                                          #help-platform

  I tried to add a deny for that IP to the API's security group in the
  console. There is no "deny" option. The only choices are the type, the
  port and the source -- the rule can only allow. Am I missing something?
  Is this one of those things only the network people can do?

  the API's network is in ~/platform-playground-aws/drill71
  (ids: network.txt, creds: . ./aws-env.sh, access log excerpt: api-access.log)
