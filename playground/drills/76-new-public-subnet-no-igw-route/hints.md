A subnet is "public" only because of its ROUTE TABLE, not because of its name
or a checkbox: it needs a route 0.0.0.0/0 -> an internet gateway that is
attached to the VPC. Compare how public-a and public-b are routed:
`aws ec2 describe-route-tables --filters Name=vpc-id,Values=<vpc id>`
and look at the Associations of each table.
---
A subnet with no explicit route table association silently uses the VPC's MAIN
route table. Which table is public-b using, and does it have an internet
gateway route? Which subnet is on the main table besides public-b?
---
Associate public-b with public-rt (the table public-a uses):
`aws ec2 associate-route-table --route-table-id <public-rt> --subnet-id <public-b>`
Do NOT "fix" it by adding 0.0.0.0/0 -> igw to the main table: that would make
every subnet that has no explicit association public, including private-a.
