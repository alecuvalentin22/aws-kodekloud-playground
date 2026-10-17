ROOT CAUSE
  Nothing was broken: the API's network had no way to say "not this address".
  Sam was looking in the wrong layer. A SECURITY GROUP only has allow rules (no
  deny, no rule order: any matching allow wins) and is STATEFUL: replies to an
  allowed connection go out without a rule. So "everyone on 443 except one IP"
  cannot be written in one. A NETWORK ACL is the layer that can:
    - attached to a SUBNET (not to an instance), applies to everything in it
    - numbered rules, read lowest first, first match wins, then stop;
      the last rule (32767) denies everything
    - allow AND deny
    - STATELESS: return traffic needs its own rules (inbound ephemeral
      1024-65535 for connections the subnet starts, outbound for replies)
  Baseline here: inbound 100 allow tcp 443, 110 allow tcp 1024-65535,
  outbound 100 allow all.

FIX
  1. aws ec2 describe-network-acls --network-acl-ids <NACL id from network.txt>
  2. Add the deny BELOW 100, for the scanner only:
       aws ec2 create-network-acl-entry --network-acl-id <id> --ingress \
         --rule-number 90 --protocol=-1 --cidr-block 198.51.100.77/32 \
         --rule-action deny
     - Number < 100: a deny at 200 is never reached for a 443 packet, rule 100
       already allowed it.
     - Protocol -1 (all), not just tcp 443: rule 110 lets 1024-65535 in from
       anywhere, so a 443-only deny leaves the scanner the rest of the ports.
     - /32, not /24 or /16: 198.51.100.10 is a partner in the same /24.
  3. Leave rules 100/110/outbound and the security group exactly as they are.
  Optional: an egress deny for the same /32 (rule < 100 outbound). Because the
  NACL is stateless it is a separate list; it would stop OUR side from
  initiating to that address. The inbound deny alone already stops the scanner
  from connecting, so egress is defence in depth, not the fix.

WHAT THE CHECK DOES (no packets sent)
  It reads the NACL and replays the evaluation: scanner :443 and :8443 inbound
  must be DENY; 203.0.113.5 :443 inbound ALLOW; the outbound reply to its
  ephemeral port ALLOW; inbound return traffic on ephemeral ports ALLOW; the
  subnet must still use the drill's NACL; the SG must still allow 443 from
  0.0.0.0/0. Penalties: the SG rule removed/narrowed at any point (40, the whole
  API goes down and an SG could not have blocked one IP anyway); a deny wider
  than /32 that covers the scanner (20).

THE COMMON MISTAKES
  - Looking for a deny in the security group (there is none).
  - Deny numbered after the allow (200): never reached, the check says which
    allow rule wins first.
  - Forgetting that a NACL is stateless when building one from scratch: an empty
    NACL denies everything; without the ephemeral/outbound rules, 443 "works"
    but nothing comes back.
  - Denying the whole /24 or /16 to be safe.
  - Editing the VPC's DEFAULT NACL (allow-all, shared by every subnet that has
    no NACL of its own) in a shared VPC: it changes subnets you did not mean to.

WHAT STOPS IT RECURRING
  NACL deny entries kept in the same Terraform as the subnet (rule numbers
  reserved: 1-99 for blocks, 100+ for allows), and a rate limit/WAF in front
  of the API for the next scanner: a NACL has a rule limit (20 per direction by
  default) and is the wrong tool for thousands of addresses (WAF IP sets or
  AWS Network Firewall).

HOW THIS DRILL MADE THE SITUATION (honest version)
  break.sh creates a throwaway VPC platform-lab-drill71 (10.71.0.0/16), a
  subnet "public-api", a custom NACL with the three baseline rules associated
  to it, and a security group allowing 443. No instances, so no traffic is
  sent: check.sh evaluates the NACL's rules the way the network does. All
  IDs are recorded in the state dir; reset.sh puts the subnet back on the VPC's
  default NACL and deletes NACL, SG, subnet and VPC.

SAY THIS IN THE INTERVIEW
  "Security wanted one IP blocked now. A security group can't do it: it only
  has allow rules and is stateful, so there is no 'deny this address'. The
  network ACL on the subnet can: it is stateless, ordered by rule number with
  the first match winning, and supports deny. I added an inbound deny for the
  /32 at rule 90, below the allow at 100, for all protocols so the ephemeral
  range rule couldn't let it back in on another port. I kept it to a /32 because
  a partner sits in the same /24, left the baseline and the SG alone, and
  verified by evaluating the rules rather than waiting for the scanner. For
  scale I'd move to a WAF IP set; NACL entries are capped and not meant for
  thousands of addresses."
