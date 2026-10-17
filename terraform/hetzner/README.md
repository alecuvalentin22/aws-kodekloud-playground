# terraform/hetzner -- the persistent lab on Hetzner Cloud (alternative host)

**Status: OPTIONAL, dormant.** Same lab as `terraform/aws` (3 Elasticsearch
nodes + 1 k3s node) on a paid, non-wiped provider. No `make` target or script
runs it; it is in the README ("an option among Hetzner and local Multipass"),
`terraform/README.md` and CI validate. Not related to KodeKloud at all, so none
of the playground limits apply (and none of its protections either).

## What it creates (`main.tf`)

- SSH key, private network `10.0.0.0/16` + subnet in `eu-central`.
- Firewall: tcp 22, 5601, 9000-9001, 9200, 443, 30000-32767 from `my_ip_cidr` only.
- 3 x `cx22` (`es_server_type`) Elasticsearch servers and 1 x `cx32`
  (`k8s_server_type`) k3s server, Ubuntu 24.04, location `nbg1`.
- `inventory/hosts.ini` for Ansible (same file `terraform/aws` writes; whichever
  applied last wins), and a `next_steps` output. About EUR 21/month while running.

Providers: `hcloud ~> 1.48`, `local ~> 2.4`; `required_version >= 1.5`.
Variables: `hcloud_token` (sensitive, required), `my_ip_cidr` (required),
`prefix`, `location`, `es_server_type`, `k8s_server_type`, `ssh_public_key_path`.
Server type names (`cx22`, `cx32`) were chosen in 2026-08 and not re-checked
against Hetzner's current catalogue.

## State

**Local** (no backend block): `terraform.tfstate` in this folder, gitignored.
Not tied to the S3 bucket or to any KodeKloud account, so the "new account =
new bucket" re-init trap does not apply. `tf-init.sh hetzner` would not work (no
S3 backend).

## Who uses it

`README.md` (links the folder), `terraform/README.md` ("Persistent lab ->
Hetzner"), `.github/workflows/ci.yml` (`fmt` + `validate`). Nothing else.

## Status evidence

Commits `04ce2b7` (2026-08-18, created with the first lab) and `e2b5752`
(2026-09-02, CI/docs pass only). There is no `terraform.tfstate` in the folder
and `.terraform/` dates from 2026-09-02 (an init/CI pass), so nothing here is
currently deployed. Not superseded;
simply unused since the work moved to the KodeKloud EKS lab.

## KodeKloud fit

n.a. (not an AWS/GCP playground stack). It would not be subject to the
compliance job, but it costs real money: destroy when idle.

## How to run / destroy (from the repo root)

Needs a Hetzner Cloud API token and an SSH key.

```bash
cd terraform/hetzner
export TF_VAR_hcloud_token=...            # never write it into a file in the repo
terraform init
terraform apply -var "my_ip_cidr=$(curl -4 -s ifconfig.me)/32"
cd ../.. && ansible all -m ping && ansible-playbook playbooks/site.yml --ask-vault-pass
# when done:
terraform -chdir=terraform/hetzner destroy     # prompts for the two required variables
```

`make destroy` does not touch it. Using it overwrites `inventory/hosts.ini`
(which `terraform/aws` also writes); keep only one of the two applied at a time.
