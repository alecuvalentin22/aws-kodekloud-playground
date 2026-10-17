ROOT CAUSE
  public-b was created and never associated with a route table, so it uses the
  VPC's MAIN route table, which only has the local route. A subnet is "public"
  because of its ROUTE TABLE, not its name: it needs 0.0.0.0/0 -> an internet
  gateway that is attached to the VPC. public-a works because it is explicitly
  associated with public-rt (0.0.0.0/0 -> igw). Nothing was wrong with the IGW,
  the security group or the load balancer.

  Rules to keep in your head:
    - Every subnet is associated with exactly one route table. No explicit
      association = the MAIN route table (the console copies subnet settings,
      not the route table association).
    - Public = route 0.0.0.0/0 -> igw-xxx (and the IGW is attached to the VPC).
    - Private = no IGW route. It reaches the internet outbound through a NAT
      gateway (0.0.0.0/0 -> nat-xxx in its own route table), never inbound.
    - Keep the MAIN table private/bare ("fail closed"): a forgotten association
      then gives you a private subnet, not an exposed one.

FIX
  1. aws ec2 describe-route-tables --filters Name=vpc-id,Values=<vpc id>
     public-rt has the igw route and the association with public-a; the main
     table (Main: true) has only the local route and lists no subnets, which
     means public-b and private-a are both on it.
  2. aws ec2 associate-route-table --route-table-id <public-rt> --subnet-id <public-b>
     (or a separate public route table for public-b with the same default route)
  3. Leave the main table, private-a, and the IGW alone.

WHAT THE CHECK DOES (no traffic sent)
  It works out each subnet's EFFECTIVE route table (explicit association, else
  main) and reads its 0.0.0.0/0 route: public-b and public-a must point to the
  attached IGW; the IGW must still be attached. Penalties: private-a ended up with
  an IGW route, which is what adding the route to the MAIN table does (40); the
  IGW was detached or replaced on the way (15).

THE COMMON MISTAKES
  - Adding 0.0.0.0/0 -> igw to the MAIN table. public-b works, so it feels
    fixed, but private-a (the database tier) is now internet-facing.
  - Looking at the security group or NACL first: they are fine, nothing reaches
    the subnet because it has no route.
  - Re-creating the IGW or detaching/attaching it: it was never broken.
  - Putting a route to a NAT for a PUBLIC subnet (a NAT is for private ones, and
    it sits in a public subnet itself).

WHAT STOPS IT RECURRING
  Subnets and their route table associations in the same Terraform module
  (aws_route_table_association next to aws_subnet), a bare main route table, and
  a Config rule / CI check that flags a subnet with mapPublicIpOnLaunch or an IGW
  route on the main table. Reachability Analyzer is the quick way to prove a path.

HOW THIS DRILL MADE THE SITUATION (honest version)
  break.sh creates a throwaway VPC platform-lab-drill76 (10.76.0.0/16) with an
  attached IGW, a route table public-rt (0.0.0.0/0 -> igw) associated with
  public-a, and subnets private-a and public-b left on the main table. No
  instances, so no traffic: check.sh evaluates the route tables. IDs are recorded
  in the state dir; reset.sh disassociates and deletes the route tables, detaches
  and deletes the IGW, deletes the subnets and the VPC.

SAY THIS IN THE INTERVIEW
  "The new public subnet was dead from the internet. I compared its route table
  with the working subnet's: a subnet is public only if its route table sends
  0.0.0.0/0 to an attached internet gateway, and the new one had never been
  associated with a route table, so it had silently fallen back to the main
  table, which only has the local route. I associated it with the public route
  table. I deliberately did not add the IGW route to the main table: that would
  have made every unassociated subnet public, including the private database
  subnet. Longer term I keep the main table bare and define subnet-to-route-table
  associations in the same Terraform module, so a forgotten one fails closed."
