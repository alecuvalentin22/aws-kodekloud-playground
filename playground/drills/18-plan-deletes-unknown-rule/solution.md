ROOT CAUSE
  Terraform makes reality match the CODE. During the partner incident (INC-4471)
  somebody changed the security group by hand: an ingress rule 22/tcp from
  0.0.0.0/0 ("tmp debug") and the `owner` tag (payments -> payments-oncall).
  Nothing in the code or the state knows about either. Dan's plan therefore holds
  three kinds of line, and only one of them is his:
    + "cost-center" = "pay-1042"        Dan's change: wanted
    ~ "owner" = "payments-oncall" -> "payments"   drift: someone's console edit
    - ingress { 22/tcp from 0.0.0.0/0 } drift: a rule nobody on the team wrote
  "Can I just apply?" Applying would, in one go, delete the rule, flip the tag and
  add his tag. Here the outcome happens to be right, but nobody decided it: the same
  habit deletes a rule that a partner is using at that moment, or reverts a hotfix.

FIX
  1. Read the plan line by line. `-` / `~` on things nobody wrote = drift.
  2. See only the drift: terraform plan -refresh-only
     ("Objects have changed outside of Terraform"; it proposes nothing).
  3. Who and why: CloudTrail records the API call whatever the console or CLI did.
       aws cloudtrail lookup-events \
         --lookup-attributes AttributeKey=EventName,AttributeValue=AuthorizeSecurityGroupIngress \
         --query 'Events[].[EventTime,Username,EventName]' --output table
     (also CreateTags, RevokeSecurityGroupIngress; events arrive a few minutes late (up to 15);
     the event body has the source IP and the request: group, port, CIDR.) Then ask
     the person: the incident channel, the on-call.
  4. Decide per change, not as a bundle:
     - 22/tcp from 0.0.0.0/0 is a security finding: SSH open to the internet.
       Ask whether it is still needed (the debugging is over), tell security, then
       REMOVE it: let Terraform revert it (it is already in the plan), or revoke it
       yourself. Do NOT write it into main.tf to make the plan clean: that makes a
       temporary hole permanent and reviewed-looking.
       (If the access is really needed: a narrow rule, a named CIDR, in code, in
       a PR, with an owner and an expiry. Better still, no inbound SSH at all:
       SSM Session Manager.)
     - The owner tag: harmless. Either revert (Terraform does) or accept it
       deliberately: change `owner` in main.tf to what it should be. Choose, write
       down why.
  5. terraform apply (after reading the plan once more: it should now hold exactly
     the changes you decided on), then terraform plan: "No changes".
  NOT: ignore_changes (the resource stops being compared in that place, so the next
  hand edit there is invisible too, and the plan "looks clean"); terraform import
  (adopts resources that are missing from the state; this rule belongs to a resource
  that is already managed); terraform state rm / destroy and re-create (drops
  whatever depends on the group); -refresh=false (plans against a state you know is
  wrong).

WHAT STOPS IT RECURRING
  - Drift detection on a schedule: a nightly `terraform plan -detailed-exitcode`
    (exit 2 = drift) in CI that posts to the team channel, so a hand edit is a
    next-morning conversation and not a surprise during someone else's change.
  - Break-glass that is written down: a documented incident procedure, an
    incident-scoped role for console changes, and "after the incident, put it in code
    or revert it" as a checklist item. IAM: day-to-day roles read-only, change
    through the pipeline.
  - AWS Config rule (restricted-ssh / vpc-sg-open-only-to-authorized-ports) or a
    GuardDuty / EventBridge rule on AuthorizeSecurityGroupIngress with 0.0.0.0/0:
    the hole is flagged within minutes, not found in a plan weeks later.
  - Tag-based ownership and a policy test (Checkov/tfsec/OPA) on the Terraform
    code, so 0.0.0.0/0 on 22 cannot be merged either.
  - Rules as separate resources (aws_vpc_security_group_ingress_rule) do NOT detect
    foreign rules: Terraform only manages what it declares. Inline ingress blocks
    on aws_security_group are authoritative and do (that is why this plan shows the
    removal). Know which one you have.

HOW THIS DRILL MADE THE DRIFT (honest version)
  break.sh applies a real Terraform root (S3 backend, use_lockfile) that creates the
  security group `platform-lab-drill18` in the default VPC (free: a group and tags,
  no instance). Dan's cost-center tag is then written into main.tf, uncommitted.
  The "console" edits are two real EC2 API calls made with the aws CLI
  (AuthorizeSecurityGroupIngress, CreateTags): the API call a console click makes,
  so CloudTrail has them. The one difference from real life: the CloudTrail actor is
  the lab IAM user, the same identity you use, not a different person. In
  production the Username / source IP tells you who.

SAY THIS IN THE INTERVIEW
  "A plan with lines I did not write is a question, not a to-do. I read it line by
  line, ran plan -refresh-only to see just the drift, and looked in CloudTrail for
  who made the changes and when, then asked them. I decided each change separately:
  the world-open SSH rule is a security finding, so it gets removed (and reported),
  not committed into the code, and the tag was harmless so I reverted it
  deliberately. Only then did I apply Dan's change and plan again until it said no
  changes. I would not use ignore_changes, which hides drift, or import, which is for
  resources missing from the state. To stop it recurring: a scheduled plan in CI
  that reports drift, a break-glass procedure with 'put it in code or revert it'
  afterwards, and a Config or EventBridge rule on 0.0.0.0/0 ingress."
