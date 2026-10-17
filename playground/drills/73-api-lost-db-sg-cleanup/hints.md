Timeouts, not refusals: packets are being silently dropped, which is what a
security group does to traffic nothing allows. Look at what the DB tier's
security group allows on 5432 and WHO it allows it from:
`aws ec2 describe-security-groups --group-ids <db sg> --query 'SecurityGroups[0].IpPermissions'`
and compare with the security group the API actually uses (inventory.txt).
---
The rule's source is not an address, it is another security group's ID
("members of THAT group"). A security group's ID is its identity: the
replacement has a different ID, so a rule pointing at the old one trusts
nobody who is still running. It also explains cleanup.log: AWS will not
delete a group that another group's rule still references.
---
Add an inbound rule on the DB group: tcp 5432, source = the NEW API group's
ID (--source-group, or UserIdGroupPairs): `aws ec2 authorize-security-group-ingress
--group-id <db> --protocol tcp --port 5432 --source-group <api>`. Then revoke
the rule that still references the old group. Do not take the shortcut of a
CIDR (the VPC range or 0.0.0.0/0): it lets in everything in that range, and the
next instance added to the VPC can reach the database.
