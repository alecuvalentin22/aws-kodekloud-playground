# terraform/aws -- the EC2 lab (Elasticsearch, k3s, RKE2, RDS)

**Status: OPTIONAL.** Works, used on demand: `make ec2` and `make destroy`
reference it, and the Elasticsearch/Ansible drills need it. The current
GitOps/EKS work does **not** need it. KodeKloud AWS playground, with a budget
warning (below).

## What it creates

All in the **default VPC** (`main.tf`; VPC creation is restricted on the playground).

| What | File | Default |
|---|---|---|
| Elasticsearch EC2 nodes `<prefix>-es-0N` (Ubuntu 24.04, t3.medium) | `main.tf` | `es_node_count = 3` |
| k3s node `<prefix>-k3s-01` | `main.tf` | `create_k8s_node = true` |
| RKE2 node `<prefix>-rke2-01` (Rancher) | `main.tf` | `create_rancher_node = false` |
| Per-ES-node EBS data volume, attached `/dev/sdf` | `main.tf` | `data_volume_gb = 10` (0 = none) |
| Key pair + one security group (SSH and 6443 from `my_ip_cidr`; web ports from `service_source_ranges`) | `main.tf` | |
| RDS PostgreSQL 16 `db.t3.micro`, its own SG and subnet group, generated password | `rds.tf` | `create_rds = true` |
| `inventory/hosts.ini` for Ansible (written by Terraform) | `outputs.tf` | |

Providers: `aws ~> 5.0`, `local ~> 2.4`, `random ~> 3.6`; `required_version >= 1.10`.
Required variable: `my_ip_cidr` (no default). Outputs: public/private IPs,
volume IDs, `rds_endpoint`, `rds_password` (sensitive), `next_steps`.

Your current (gitignored) `terraform.tfvars` is a minimal footprint: 1 ES node,
no EBS data volume, no RDS, no RKE2, k3s on, `service_source_ranges = ["0.0.0.0/0"]`.
Note what that last line does: Elasticsearch runs unauthenticated here
(see `variables.tf` `service_source_ranges`) and it is open to the internet.

## State

S3, `backend.tf`: key `platform-lab/aws/terraform.tfstate`, `use_lockfile = true`
(no DynamoDB). The **bucket is not in the file** (partial config); it is
`andrei-lab-tfstate-<account-id>`, supplied at init time by
`./scripts/tf-init.sh` (aws is its default stack). So a plain `terraform init`
does not work here.

New KodeKloud account = new account ID = new bucket: this folder's
`.terraform/` still points at the old bucket and fails with "S3 bucket ... does
not exist". Re-init with `./scripts/tf-init.sh aws` (or `make state`, which
does `aws eks`).

## Who uses it

- `make ec2` -> `cd terraform/aws && terraform apply -auto-approve` (Makefile).
- `make destroy` -> `terraform destroy -auto-approve` here, after `terraform/eks`.
- `make state` / `scripts/tf-init.sh` (default stack).
- `playbooks/*` and `drills/*` consume `inventory/hosts.ini`;
  `playbooks/rds.yml`, `drills/10-terraform-state.md`, `drills/11-rds-vs-ec2-postgres.md`,
  AGENTS.md section 3 ("Build order").
- CI: `.github/workflows/ci.yml` runs `fmt` and `validate` on it.

## Status evidence

Last commits: `cae4924` (2026-08-19), `24e556c` (2026-08-18), `04ce2b7`
(2026-08-18). Nothing since the August Elasticsearch/Ansible phase; the October
work moved to `terraform/eks`. Still referenced by the Makefile, README and CI,
so not legacy.

## KodeKloud fit (`docs/kodekloud-limits.md`)

| Limit | This stack |
|---|---|
| t2/t3 up to medium only | `instance_type` default `t3.medium` (variables.tf) -- OK |
| credits must be `standard` | pinned for every instance: `main.tf:180-184`, `208-212`, `311-315` (only if the type starts with t2./t3.) -- OK |
| per-volume <= 30 GB, gp2/gp3 | root `root_volume_gb = 30`, type `gp2`, data 10 GB -- OK (30 is exactly the cap; do not raise) |
| EC2 total <= 10 vCPU / 20 GiB, max 10 running | defaults: 3 ES + 1 k3s = 4 x t3.medium = 8 vCPU / 16 GiB. With `create_rancher_node = true` it is 5 = 10 / 20, **the whole budget** |
| ECS / EKS caps | n.a. |
| RDS | `db.t3.micro` (variables.tf `rds_instance_class`). Not on KodeKloud's published table; AGENTS.md says RDS is permitted. Unverified against the live policy |

**Budget collision.** `terraform/eks` can take up to 5 nodes (tfvars:
`node_max_size = 5`, `eks-up.sh` default 3). The EC2 budget is shared account-wide:
this stack at its defaults (4) plus EKS at 3 = 7 instances = 14 vCPU, over the cap.
With your current tfvars (2 instances) + 3 EKS nodes = exactly 10 vCPU / 20 GiB.
Do not run both at larger sizes.

Also: EBS KodeKloud limits say 30 GB per volume only; the default 4 x 30 GB root
+ 3 x 10 GB data is fine per volume.

## How to run / destroy (from the repo root)

Needs: the state bucket (`make state` does it), lab credentials in the shell
(file `~/.config/platform-lab/aws-lab-creds.env`, mode 600, loaded into the
environment; never `~/.aws/credentials`), `LAB_ACCOUNT_IDS` set or the account ID
typed at the `tf-init.sh` prompt, and an SSH key at `~/.ssh/id_ed25519.pub`.

```bash
make state                       # bucket + re-init (or ./scripts/tf-init.sh aws)
cp terraform/aws/terraform.tfvars.example terraform/aws/terraform.tfvars   # only if missing
$EDITOR terraform/aws/terraform.tfvars   # my_ip_cidr = "$(curl -4 -s ifconfig.me)/32"
make ec2                         # apply -auto-approve; writes inventory/hosts.ini
ansible all -m ping
ansible-playbook playbooks/site.yml --ask-vault-pass
```

Destroy: `make destroy` (asks; destroys `terraform/eks` first, then this) or
`terraform -chdir=terraform/aws destroy`. RDS takes 5-10 min to create, so
`create_rds = false` when you only need the cluster.

Remember the 3-hour IAM window: apply first, Ansible (SSH) works after it closes.
