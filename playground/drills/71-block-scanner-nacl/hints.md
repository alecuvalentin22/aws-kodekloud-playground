Sam is right: a security group has allow rules only. There is no way to say
"everyone except this address" in one, and since it is stateful, an allowed
connection's replies are allowed automatically. What else filters traffic
at the network layer, per subnet? Look at what guards the subnet in
network.txt: `aws ec2 describe-network-acls --network-acl-ids <id>`.
---
A network ACL is a numbered list: rules are read from the lowest number
up, the first match wins and evaluation stops. It supports deny. It is
STATELESS, which is why the baseline has a rule for ephemeral ports (1024-65535)
and an outbound rule. So where does a deny have to sit to ever be reached?
(Look at the numbers of the existing allow rules.)
---
Add an inbound deny for 198.51.100.77/32 with a rule number LOWER than 100
(90, say), for all protocols, so the 1024-65535 rule cannot let it back in
on another port: `aws ec2 create-network-acl-entry --network-acl-id <id>
--ingress --rule-number 90 --protocol=-1 --cidr-block 198.51.100.77/32
--rule-action deny`. Leave the other rules and the security group alone, and
keep it a /32: 198.51.100.10 is a partner in the same /24.
