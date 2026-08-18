# AGENTS.md — instructions for an AI assistant working on this repo

Read this before doing anything. It encodes an afternoon of failures against a
real KodeKloud AWS playground on 2026-08-18, so you do not repeat them.

**Everything below was verified live.** Where a claim is unverified it says so.

---

## 1. What this repo is

A lab that builds, with Terraform + Ansible:

- a 3-node **Elasticsearch** cluster (+ Kibana, MinIO for snapshots)
- **PostgreSQL** on EC2 **and** on RDS, for comparison
- **k3s** running Kong (API gateway) and Keycloak (OIDC)
- **RKE2** running Rancher — a second distribution, on purpose
- an **EKS** control plane, in a separate root module

The deliverable is not the stack. It is `drills/01`–`17`: each has a "say this
in the interview" section, and drills 09–17 are write-ups of bugs hit here.

---

## 2. Start of every session: get credentials

The playground gives console credentials. Two ways to get API access:

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
```

Get those from the console: sign in with the credentials the playground gives
you, then **IAM -> Users -> <your kk_labs_user> -> Security credentials ->
Create access key -> CLI**.

### `aws login` does NOT work here (verified twice, two different accounts)

`scripts/aws-lab-env.sh` wraps `aws login`, the AWS CLI's browser flow that
exchanges a console session for temporary API credentials. It is the nicer path
because it creates no long-lived key -- and the KodeKloud playground **rejects
it**:

```
Authentication failed
Invalid request
```

The flow needs console-to-CLI federation, which the playground's boundary policy
does not grant to its IAM users. The script is kept for real AWS accounts, where
it works; in the playground, go straight to an access key and do not spend
session time on it.

**Never write lab credentials into `~/.aws/credentials`.** Users of this repo
often have production profiles there. Keep them in the environment or a
throwaway file with mode `600`.

**Check which account you are in before every apply.** `scripts/tf-init.sh`
prints the account and refuses to continue without confirmation; set
`LAB_ACCOUNT_IDS=<id>` to skip the prompt once you have verified it.

### The IAM window is time-boxed — this WILL bite you

Every statement in the playground's boundary policy carries:

```json
"DateGreaterThan": {"aws:CurrentTime": "...T09:24:03Z"},
"DateLessThan":    {"aws:CurrentTime": "...T12:24:03Z"}
```

Three hours from session start, enforced in IAM. When it closes, AWS API calls
return AccessDenied **while the instances keep running**. A late failure is
often the clock, not the config. Check remaining time:

```bash
aws iam get-policy-version --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWS_EKSECSWithConditions \
  --version-id v1 --query 'PolicyVersion.Document' | grep CurrentTime
```

**Plan around it:** do everything requiring the AWS API (Terraform) first.
Ansible runs over SSH and has no deadline — it keeps working after the window
closes.

---

## 3. Build order

```bash
# 1. state bucket + backend (see drills/10)
./scripts/tf-init.sh

# 2. infrastructure
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
#    my_ip_cidr = "$(curl -4 -s ifconfig.me)/32"      <- -4 MATTERS, see §6
terraform apply            # writes inventory/hosts.ini itself

# 3. secrets  (NOTE THE all/ DIRECTORY -- see drills/16)
ansible-vault create inventory/group_vars/all/vault.yml
#   minio_root_password / postgres_app_password
#   rancher_bootstrap_password / keycloak_admin_password
ansible all -m debug -a "msg={{ minio_root_password }}" --ask-vault-pass   # VERIFY IT LOADED

# 4. configuration
ansible-playbook playbooks/elastic.yml --ask-vault-pass
ansible-playbook playbooks/k8s.yml --limit k3s-01  --ask-vault-pass -e rancher_enabled=false
ansible-playbook playbooks/k8s.yml --limit rke2-01 --ask-vault-pass -e kong_enabled=false -e kong_oidc_enabled=false

# 5. RDS — password comes from Terraform state, never a file
ansible-playbook playbooks/rds.yml --ask-vault-pass \
  -e rds_master_password="$(terraform -chdir=terraform/aws output -raw rds_password)"

# 6. Rancher imports the k3s cluster -- THE demo (see drills/07)
ansible-playbook playbooks/rancher-import.yml --ask-vault-pass
```

**Install Rancher EARLY in the session.** It needs sustained CPU, and a
`t3.medium` in `standard` credit mode is throttled to ~20% baseline once its
launch credits are gone. Rancher took 9 minutes to start on a credit-exhausted
node and needed its startup probe widened to survive. See drills/17.

### Where each component goes, and why

Do not co-locate Rancher and Keycloak — they do not fit on 4 GiB together.

| node | runs |
|---|---|
| es-01/02/03 | Elasticsearch (+ Kibana, MinIO, Postgres on es-01) |
| k3s-01 | k3s, Kong, Keycloak |
| rke2-01 | RKE2, cert-manager, Rancher |

es-01 is the tight one: Elasticsearch sizes its heap to half of RAM without
knowing it shares the box. Cap it:

```yaml
# inventory/host_vars/es-01.yml
elastic_heap_mb: 1200        # frees ~700 MB
```

Add `--private-key ~/.ssh/id_ed25519` if your key is not the default.

---

## 4. Capacity — the constraint that shapes everything

**5 instances maximum.** 3 ES + k3s + RKE2 = exactly 5. Nothing else fits.

**Every node is `t3.medium`: 2 vCPU / 4 GiB, `standard` CPU credits.**
`unlimited` mode **suspends the session** — never set it.

Measured, mid-session:

| node | carrying | result |
|---|---|---|
| es-01 | Elasticsearch 2365 MB + Kibana 509 MB + MinIO 100 MB + Postgres | **259 MB free** |
| k3s-01 | k3s + Kong + Keycloak + Rancher | **wedged, needed a reboot** |
| rke2-01 | RKE2 + Rancher | 1.9 GB free, **82% CPU steal** |

Use the toggles rather than hoping:

| toggle | where | frees |
|---|---|---|
| `kibana_enabled=false` | Ansible | ~509 MB on es-01 (verified 259→754 MB) |
| `minio_enabled=false` | Ansible | ~100 MB |
| `postgres_enabled=false` | Ansible | redundant once RDS exists |
| `rancher_enabled=false` | Ansible | ~1.5 GB |
| `kong_enabled=false` | Ansible | ~500 MB |
| `kong_oidc_enabled=false` | Ansible | ~1 GB (Keycloak) |
| `create_rds=false` | Terraform | saves 6-10 min of apply |
| `create_rancher_node=false` | Terraform | frees an instance |
| `data_volume_gb=0` | Terraform | skips the EBS volumes |

The Ansible toggles **stop running services**, not just skip installation.

**Rancher and Keycloak do not fit on one node.** Run Rancher on rke2-01 and
Keycloak on k3s-01. That is why `create_rancher_node` exists.

---

## 5. What the playground does NOT allow

Verified by running it, not by reading docs:

| | |
|---|---|
| `eks:CreateNodegroup` | **DENIED** — cluster builds, compute is refused. Use `create_node_group=false` |
| EKS Fargate | permitted in policy, but needs **private subnets**; the default VPC has none |
| `iam:CreateRole` | only for `eksClusterRole`, `eksWorkerNodeRole`, `AmazonEKSFargatePodExecutionRole` — **exact names** |
| `iam:ListAttachedUserPolicies` | **DENIED** — you cannot enumerate your own permissions |
| `us-east-1e` | no `t3.medium`, and EKS will not put a control plane there |

EC2, S3, RDS, VPC are all permitted but granted by a policy you cannot read.
Probe with `--dry-run` instead of guessing:

```bash
aws ec2 run-instances --dry-run --image-id ami-... --instance-type t3.medium --count 1
# DryRunOperation: Request would have succeeded, but DryRun flag is set
```

---

## 6. Traps that cost hours — do not rediscover these

**`curl ifconfig.me` returns IPv6.** A security group rule wants IPv4. Use
`curl -4`, or `python3 -c "import urllib.request;print(urllib.request.urlopen('https://checkip.amazonaws.com').read().decode())"`.

**A host cannot reach its own public IP.** `wait_for` and `uri` run *on the
target*. Pointing them at `ansible_host` sends the packet out to the internet
gateway and back into a security group that only admits your laptop's `/32`. It
times out with `http_code=000`. Use `127.0.0.1` or `private_ip`. This bit three
separate times — MinIO, cluster-config, and the OIDC tasks. See drills/14.

**Keycloak's `iss` must stay the public URL** even though Ansible reaches it over
loopback. That is what `KC_HOSTNAME` pins, and why Kong's credential lookup
works. Do not "fix" it to loopback.

**`group_vars/vault.yml` is silently ignored.** It declares variables for a group
named `vault`. Use `group_vars/all/vault.yml`. See drills/16 — this is the worst
bug in the repo's history because it fails *open*.

**Check the exit code you think you are checking.**
```bash
ansible-playbook ... > run.log 2>&1
echo "ANSIBLE_EXIT=$?" >> run.log    # NOT `echo $?` after a later command
```

**`kubectl apply -f` applies documents in file order.** A `KongConsumer` before
its credential `Secret` is rejected by the admission webhook — and succeeds on a
re-run, which hides it.

**Scaling a webhook's Deployment to 0 does not disable it.** The
`ValidatingWebhookConfiguration` is cluster-scoped, outlives the pods, and with
`failurePolicy: Fail` breaks *unrelated* workloads. `helm uninstall`, don't
`scale`.

**Probes kill slow starters on a throttled box.** Kong's ingress-controller and
Rancher both CrashLoopBackOff'd because their probe budgets assumed a healthy
CPU. The role already widens Kong's; Rancher may still need
`failureThreshold: 90` patched onto its `startupProbe`. See drills/15 and 17.

**Diagnose memory vs CPU before acting:**
```bash
free -m                  # available -> memory
top -bn1 | grep '%Cpu'   # st -> hypervisor steal, unfixable from inside
```

---

## 7. Ansible version notes

Built against **ansible 14 / ansible-core 2.21**. Two removals that break older
copies of this repo:

- `stdout_callback = yaml` — **removed** in community.general 12. Use
  `stdout_callback = default` + `result_format = yaml` (already fixed in
  `ansible.cfg`).
- the `db:` parameter — **removed** in community.postgresql 4. It is `login_db:`
  now, except `postgresql_db` which wants `maintenance_db:`. Check with
  `ansible-doc -j community.postgresql.<module> | jq '.[].doc.options | keys'`.

---

## 8. Verifying a build

```bash
export ES=http://<es-01>:9200
./scripts/es health          # expect status=green, 3 nodes, 0 unassigned
./scripts/seed-logs.sh 5000

# Kong: open route, JWT route, and a tampered token
curl -s -o /dev/null -w '%{http_code}\n' http://<k3s>:30080/demo       # 200
curl -s -o /dev/null -w '%{http_code}\n' http://<k3s>:30080/secure     # 401
TOKEN=$(curl -s -X POST http://<k3s>:30081/realms/lab/protocol/openid-connect/token \
  -d grant_type=password -d client_id=lab-api -d username=labuser -d password=labpassword \
  | jq -r .access_token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" http://<k3s>:30080/secure  # 200
```

Service URLs (all firewalled to `my_ip_cidr` — if your IP rotates, everything
dies at once and you must update `terraform.tfvars` and re-apply):

| service | where |
|---|---|
| Elasticsearch | `http://<es-01>:9200` |
| Kibana | `http://<es-01>:5601` |
| MinIO console | `http://<es-01>:9001` |
| Kong | `http://<k3s>:30080/demo` and `/secure` |
| Keycloak | `http://<k3s>:30081` |
| Rancher | `https://<rke2>:30443` (self-signed) |
| RDS | private only — reach it *through* es-01 |

---

## 9. Working style expected here

- **Verify, do not assert.** Every claim in `drills/` has real command output
  behind it. If you add one, run it first.
- **Report failures honestly.** The drills are valuable *because* they document
  what broke. Do not quietly fix and move on — write down the error text.
- **Never commit secrets.** `.gitignore` covers `inventory/hosts.ini`,
  `inventory/group_vars/all/vault.yml`, `terraform.tfvars`, `*.tfstate*`.
- **Destroy when done**, or let the playground expire:
  `terraform -chdir=terraform/eks destroy && terraform -chdir=terraform/aws destroy`
