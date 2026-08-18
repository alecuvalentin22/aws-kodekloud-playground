# Drill 09 — Kong, JWT and OIDC

**The question:** "How did you handle authentication at the gateway?"

## Say the honest thing first

Kong's `openid-connect` plugin — discovery, the authorization-code redirect
flow, introspection, refresh — is **Kong Enterprise only**. It is not in OSS.

What OSS gives you is the `jwt` plugin, and it does the part that actually
guards the API: verify the RS256 signature against the issuer's public key,
check `exp`, reject anything unsigned, expired or from an unknown issuer.

So the lab runs **Keycloak as the OIDC provider** issuing real OIDC tokens, and
**Kong validating them**. The gateway is genuinely protected. What it does not
do is run the login redirect itself, or introspect on every request — meaning a
revoked-but-unexpired token stays valid until it expires. That is why
`accessTokenLifespan` in the realm is 30 minutes rather than 12 hours.

Saying that precisely is worth more than claiming "OIDC on Kong".

## Try it

```bash
K3S=<k3s public ip>

# open route -- no auth
curl -s -o /dev/null -w '%{http_code}\n' http://$K3S:30080/demo        # 200

# protected route -- anonymous
curl -s -o /dev/null -w '%{http_code}\n' http://$K3S:30080/secure      # 401

# get a token from Keycloak
TOKEN=$(curl -s -X POST \
  "http://$K3S:30081/realms/lab/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=lab-api \
  -d username=labuser -d password=labpassword | jq -r .access_token)

# look at what you actually got -- the claims matter more than the string
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, exp, preferred_username, azp}'

# protected route -- authenticated
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" http://$K3S:30080/secure           # 200

# tamper with the signature -- same claims, one flipped character
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer ${TOKEN%?}X" http://$K3S:30080/secure      # 401
```

The playbook asserts all four of those outcomes, so a broken build fails the
run rather than quietly serving an unprotected route.

## The two things that break this, and both are worth knowing

**1. `iss` must match the credential's `key` exactly.**

Kong looks up *which public key to verify with* by the token's `iss` claim.
Keycloak derives `iss` from the URL the client used to reach it — so hitting it
via `localhost`, via the node IP, and via a Service DNS name produce three
different issuers and two of them fail with:

```
{"message":"No credentials found for given 'iss'"}
```

That is why the manifest pins `KC_HOSTNAME`. A cryptographically perfect token
gets rejected because a *string* did not match.

**2. The realm signing key is regenerated every time the realm is.**

Which is why Ansible fetches it live from `/realms/lab` and templates it in,
rather than anyone pasting a PEM into a manifest. Hardcode it and the lab works
exactly once. Keycloak returns base64 DER **without** the PEM armour, so the
playbook wraps it at 64 columns and adds the header and footer — Kong wants a
PEM.

## Verified live, 2026-08-18

From a laptop, against the real playground:

```
open  /demo   anonymous       -> 200
jwt   /secure anonymous       -> 401
jwt   /secure valid bearer    -> 200
jwt   /secure tampered sig    -> 401

token iss  = http://98.82.19.61:30081/realms/lab
token user = labuser   azp = lab-api
```

Note the `iss`: Ansible fetched the signing key and the token over **loopback**,
and the claim is still the **public** URL — which is the whole point of pinning
`KC_HOSTNAME`. The issuer Keycloak advertises is decoupled from the address you
happen to reach it on, so Kong's credential lookup works no matter which route
the token was minted through.

Two things had to be fixed to get there, both worth knowing:

**The realm user was rejected with `"Account is not fully set up"`.** The
imported user had no email and inherited the realm's required actions, so the
password grant refused it. Fixed with an email and an explicit
`requiredActions: []`.

**Editing the realm appeared to do nothing.** A ConfigMap change does not
restart anything, and Keycloak's `--import-realm` **skips a realm that already
exists**. So the container kept serving the old realm while the JSON on disk was
correct — you debug the wrong file for twenty minutes. Fixed with a
`checksum/realm` annotation on the pod template, which makes a realm edit a
rollout.

That reroll regenerates the realm signing key, which is exactly why the playbook
fetches the key at deploy time and re-applies the Kong credential. The design
self-corrects; a pasted PEM would not.

## Say this in the interview

> "Kong OSS doesn't have the openid-connect plugin — that's Enterprise. So I ran
> Keycloak as the IdP and used the OSS jwt plugin to validate its RS256 tokens
> at the gateway: signature and expiry checked, unknown issuers rejected. The
> trade-off is no introspection, so revocation waits for expiry, which I
> compensated for with a short token lifetime.
>
> The thing that cost me the most time was `iss`. Kong finds the verification
> key *by* the issuer claim, and Keycloak builds that claim from whatever URL
> the client used — so the token was valid and still rejected until I pinned
> `KC_HOSTNAME`. And the realm's signing key changes whenever the realm is
> recreated, so the playbook fetches it at deploy time instead of anyone pasting
> a PEM into git."
