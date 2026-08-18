# Drill 13 — Not every AZ can do every thing

**The question:** "What surprised you about AWS?"

This one, and it cost two failed applies to find. Both were discovered live in
`us-east-1` on 2026-08-18, and both come down to the same thing: **an
availability zone is not a commodity.**

## Failure 1 — EC2

The lab spreads three Elasticsearch nodes across the default VPC's subnets,
round-robin. The default VPC has six, one per AZ. `terraform apply`:

```
Error: creating EC2 Instance: api error Unsupported: Your requested instance
type (t3.medium) is not supported in your requested Availability Zone
(us-east-1e). Please retry your request by not specifying an Availability Zone
or choosing us-east-1a, us-east-1b, us-east-1c, us-east-1d, us-east-1f.
```

## Failure 2 — EKS, same zone, different reason

```
UnsupportedAvailabilityZoneException: Cannot create cluster because EKS does
not support creating control plane instances in us-east-1e
```

**`us-east-1e` is an old zone with old hardware.** It has no Nitro-generation
instance types and several services skip it entirely. It is the single most
common cause of "it works in my other account" in `us-east-1`.

## Why this hurts more than it looks

The failure arrives at **RunInstances**, not at plan time. Terraform validated
the config, accepted the plan, built the security group, the key pair, the EBS
volumes, the RDS instance — six minutes of work — and *then* failed on the third
instance. Everything else stays created. The plan being clean tells you nothing
about whether the AZ can host what you asked for.

## The fix, and why it cannot be a hardcoded list

AZ names are **per-account aliases**. Your `us-east-1a` and mine are usually
different physical zones — AWS shuffles the mapping to stop everyone piling into
"a". So a hardcoded exclusion list is wrong in the next account, and the set of
supported types changes over time anyway.

Ask the API instead:

```hcl
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

locals {
  usable_subnets_by_az = {
    for id, subnet in data.aws_subnet.default : subnet.availability_zone => id
    if contains(data.aws_ec2_instance_type_offerings.supported.locations, subnet.availability_zone)
  }
  # Ordered by AZ NAME so placement is stable AND predictable:
  # es-01 -> us-east-1a, es-02 -> 1b, es-03 -> 1c.
  usable_subnet_ids = [for az in sort(keys(local.usable_subnets_by_az)) : local.usable_subnets_by_az[az]]
}
```

Check it from the CLI the same way:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=t3.medium \
  --query 'InstanceTypeOfferings[].Location' --output text
# us-east-1a us-east-1b us-east-1c us-east-1d us-east-1f     <- no 1e
```

### EKS has no equivalent API

There is no "does EKS support this AZ" call. The `terraform/eks` module filters
on the **node instance type's** availability instead — a real constraint in its
own right, since the node group cannot launch there either — and keeps an
`excluded_azs` variable as the escape hatch for the case where those two sets
diverge. The exception message itself lists the good zones, which is the only
authoritative source.

## Sorting: by AZ, not by subnet ID

A subtlety worth the extra line. Sorting the subnet list by **subnet ID** is
deterministic but arbitrary — and if the set changes, instances silently move
between subnets, which is a **replacement**, not an update. Sorting by **AZ
name** keeps es-01 in 1a permanently and makes "is this cluster actually spread
across zones?" answerable at a glance.

## Say this in the interview

> "Spreading nodes round-robin across the default VPC's subnets put one in
> us-east-1e, which doesn't offer t3.medium — and separately can't host an EKS
> control plane. It's an old zone that a lot of services skip.
>
> What made it expensive is that it fails at RunInstances, not at plan time, so
> everything else was already built before it broke. And you can't fix it with a
> hardcoded exclusion list, because AZ names are per-account aliases —
> my us-east-1a isn't yours. So I query
> `aws_ec2_instance_type_offerings` and only place instances in zones that
> actually offer the type. I sort by AZ name rather than subnet ID too, so the
> placement is stable and an unrelated change can't propose moving an instance,
> which would be a replacement."
