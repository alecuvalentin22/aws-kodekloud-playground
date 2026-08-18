# Drill 10 — Terraform state, and why it lives in S3

**The question:** "Where does your Terraform state live, and how do you stop two
people applying at once?"

## The chicken-and-egg, and how the repo resolves it

State goes in S3. But the bucket is itself Terraform-managed, and it cannot hold
its own state. So there are two root modules:

| | `terraform/bootstrap` | `terraform/aws`, `terraform/eks` |
|---|---|---|
| state | **local**, committed nowhere | remote, in the bucket bootstrap made |
| contains | one S3 bucket + its settings | everything else |
| run | once per account | constantly |

`scripts/tf-init.sh` runs bootstrap, reads the bucket name out of its output and
feeds it to `terraform init -backend-config=`. The bucket name is not hardcoded
because it contains the AWS account ID — S3 names are globally unique across
every account on earth, so `platform-lab-tfstate` is long gone.

## Locking with no DynamoDB table

This is the part worth being able to date.

**Before Terraform 1.10**, S3 could not do a compare-and-swap, so every tutorial
provisioned a **DynamoDB table** purely to hold a lock row. An extra resource, an
extra IAM policy, an extra thing to forget to delete.

**Since 1.10**, `use_lockfile = true` writes `<key>.tflock` using S3's
conditional write (`If-None-Match`), and S3 rejects the second writer itself.
No DynamoDB anywhere in this repo.

### Prove it
```bash
cd terraform/aws
terraform apply &        # let it start and take the lock
sleep 5
terraform plan           # second process
```
```
Error: Error acquiring the state lock
  Lock Info:
    ID:        ...
    Operation: OperationTypeApply
```
```bash
aws s3 ls s3://<bucket>/platform-lab/aws/     # terraform.tfstate.tflock exists
wait                                          # let the apply finish; lock clears
```

If a process is killed mid-apply the lock is orphaned. `terraform force-unlock <ID>`
clears it — **after** you have checked nobody is actually still applying.

## The other three settings, and why each is not optional

- **`versioning`** — a bad apply, a partial write or a `terraform state rm` at
  the wrong resource is recoverable *only* if the previous object version still
  exists. This is the single most valuable setting on the bucket.
- **`encryption`** — state holds RDS master passwords, private IPs, and whatever
  else providers return. It is a secrets file that happens to look like JSON.
  This repo's `random_password.rds` is in there in plaintext.
- **`public_access_block`** — see above.

A lifecycle rule expires noncurrent versions after 30 days, because versioning
without expiry means every apply accumulates forever.

## Say this in the interview

> "State's in S3, versioned and encrypted, one key per root module. Locking is
> `use_lockfile` — since Terraform 1.10 S3 does conditional writes, so the
> DynamoDB table everyone used to provision for this isn't needed any more.
>
> The bucket is its own root module with local state, because it can't hold the
> state of the thing that creates it. And it's versioned first and foremost:
> state contains generated database passwords, so it's a secrets file, and it's
> also the one file where a mistake is unrecoverable without object versions."
