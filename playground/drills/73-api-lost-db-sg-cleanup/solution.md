ROOT CAUSE
  A security group rule can name another security group as its SOURCE
  ("anything attached to THAT group"). The DB group allows tcp 5432 from the
  API tier's group by its ID. The cleanup replaced the API tier's group with a
  new one, which has a NEW ID. The DB rule still points at the old ID, which no
  longer belongs to anything that runs the API, so the API's packets match no
  allow rule and are silently dropped: a timeout, not a refusal.
  cleanup.log is the second clue: AWS refuses to delete a group while another
  group's rule references it (DependencyViolation). The failed delete is the
  proof that the DB still trusts the old group.

FIX
  1. aws ec2 describe-security-groups --group-ids <db sg>   (who does 5432 trust?)
     inventory.txt says which group the API really uses.
  2. Trust the new group:
       aws ec2 authorize-security-group-ingress --group-id <db> \
         --protocol tcp --port 5432 --source-group <new api sg>
  3. Revoke the rule that references the old group:
       aws ec2 revoke-security-group-ingress --group-id <db> \
         --protocol tcp --port 5432 --source-group <old api sg>
  4. Now the old group can finally be deleted (nothing references it).
  Do NOT "fix" it with 5432 from 10.73.0.0/16 or 0.0.0.0/0: it connects, and it
  also lets in every instance in that range (or the world). The check treats it
  as a non-fix when the reference is missing.

WHAT THE CHECK DOES (no packets sent)
  It reads the DB group's rules: there must be a tcp 5432 rule whose source is
  the API's current group. Penalties on an otherwise fixed state: 5432 open to
  0.0.0.0/0 or ::/0 (40); also open to a CIDR wider than /32 such as the VPC's
  /16 (25); the rule for the old group left behind (15); anything but tcp 5432
  allowed on the DB group (20).

THE COMMON MISTAKES
  - Opening 5432 to the VPC CIDR or to the internet because "it works".
  - Re-attaching the old group to the API instead of fixing the reference.
  - Adding the new rule and leaving the old one: stale access, and the old group
    can never be deleted.
  - Looking at the app, the password or the DB instead of the network: a
    timeout means packets are dropped (a security group or NACL), a refusal
    means nothing is listening, an auth error means you got through.

WHAT STOPS IT RECURRING
  Keep the groups and the rules between them in one Terraform module, with the
  rule referencing aws_security_group.api.id: replacing the group then updates
  the rule in the same plan (or fails the plan on the dependency), instead of
  leaving a dangling ID. Do the swap as add-new-rule, move the workloads,
  remove-old-rule, delete-old-group.

HOW THIS DRILL MADE THE SITUATION (honest version)
  break.sh creates a throwaway VPC platform-lab-drill73 (10.73.0.0/16) with three
  groups: api-old, api (current) and db (5432 from api-old's ID). There are no
  instances, so inventory.txt states which group is attached to what. The
  cleanup's delete of api-old is a REAL call that AWS really refuses; its error
  is saved in cleanup.log. check.sh reads the DB group's rules. All IDs are
  recorded in the state dir; reset.sh revokes the rules and deletes the groups
  and the VPC.

SAY THIS IN THE INTERVIEW
  "Timeouts after a security group cleanup. A timeout means packets are being
  dropped, and the DB group allowed 5432 from the API tier by security group ID.
  The cleanup gave the API a new group, so the ID in the rule was stale; the
  failed delete of the old group, DependencyViolation, confirmed the reference.
  I added a rule for 5432 with the new group as source, revoked the one for the
  old group, and did not open the database to the VPC range or the internet. Then
  the old group could be deleted. To stop it recurring I'd define the groups and
  the rule between them in Terraform so the reference follows the replacement."
