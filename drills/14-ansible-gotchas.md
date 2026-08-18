# Drill 14 — Four Ansible bugs this lab actually hit

Not theory. Every one of these failed a real run against real AWS on
2026-08-18, and each is the kind of thing that only shows up when you run the
playbooks rather than read them.

## 1. `wait_for` runs on the TARGET, not on your laptop

The MinIO role waited for the service to come up:

```yaml
- name: Wait for MinIO
  ansible.builtin.wait_for:
    host: "{{ ansible_host }}"     # <- the PUBLIC ip
    port: 9000
```

```
fatal: [es-01]: FAILED! => Timeout when waiting for 100.27.7.146:9000
```

MinIO was running fine. The problem is that `wait_for` executes **on es-01**, so
this was es-01 probing its own *public* address. That packet leaves for the
internet gateway and comes back in, where the security group only admits port
9000 from your laptop's `/32`. The host could not reach a service it was itself
running.

```yaml
    host: 127.0.0.1                # correct: the container publishes on the host
```

The same bug was in the `mc alias set` command, and in the cluster-config play,
which pointed `es_url` at es-01's public IP on 9200.

**The rule:** any module that connects *from* a host to *itself* wants loopback
or the private IP. `ansible_host` is how **you** reach the box, not how the box
reaches itself.

## 2. One failed host in a single-host play aborts everything

The MinIO play targets `hosts: minio`, which is just es-01. When es-01 failed,
**100% of that play's hosts failed**, and Ansible stopped the entire run — so
Elasticsearch was never installed on any node. The recap made it look like a
small failure:

```
es-01 : ok=14  changed=9  failed=1
es-02 : ok=9   changed=5  failed=0     <- only the `common` role ran
```

`failed=0` on es-02 does not mean es-02 is fine. It means nothing happened to it.

## 3. Collections drop things, and the error names everything except the fix

Two removals bit in one session, both from upgrading to Ansible 14:

**`community.general.yaml` callback — removed in community.general 12.**
```
[ERROR]: The 'community.general.yaml' callback plugin has been removed.
```
Every playbook failed instantly. `ansible.cfg` now uses the built-in equivalent:
```ini
stdout_callback = default
result_format = yaml
```

**The `db` parameter — removed in community.postgresql 4.**
```
Unsupported parameters for (community.postgresql.postgresql_info) module: db.
Supported parameters include: ca_cert, connect_params, filter, login_db, ...
```
It is `login_db` now — except `postgresql_db`, which wants `maintenance_db`.
Check before guessing:
```bash
ansible-doc -j community.postgresql.postgresql_info | jq '.[].doc.options | keys'
```

## 4. Check the exit code you think you are checking

```bash
ansible-playbook ... > run.log 2>&1
echo "exit: $?"      # <- this is ansible's
tail -20 run.log     # <- but THIS is what the script exits with
```

A wrapper reported success while the playbook had failed, because the last
command in it was `tail`. Write the real code into the log where it cannot be
overwritten:

```bash
ansible-playbook ... > run.log 2>&1
echo "ANSIBLE_EXIT=$?" >> run.log
```

## 5. `hosts: all` makes a playbook impossible to parallelise

Two playbooks, deliberately run at the same time against different machines to
save wall-clock:

```
ansible-playbook playbooks/elastic.yml &            # es-01..03
ansible-playbook playbooks/k8s.yml --limit rke2-01 &
```

```
fatal: [rke2-01]: FAILED! => Failed to lock apt for exclusive operation:
Failed to lock directory /var/lib/apt/lists/
```

`elastic.yml` opened with `hosts: all`, so it was baselining **every** host --
including rke2-01, which `k8s.yml` was baselining at the same moment. Both ran
`apt` on the same box and `/var/lib/dpkg/lock-frontend` did its job.

The blast radius was small (rke2-01 needs nothing from `elastic.yml`, and only
that host failed) but the design flaw is real: **a playbook that touches hosts
it is not responsible for cannot be run alongside anything else.** Scope each
playbook to the hosts it owns:

```yaml
- name: Baseline the Elasticsearch hosts
  hosts: elastic          # not: all
```

`common` still runs everywhere — each playbook baselines *its own* hosts. That
is the difference between shared setup and overlapping ownership.

## Say this in the interview

> "The one that took longest was a MinIO wait that timed out even though MinIO
> was up. `wait_for` runs on the target, so the host was probing its own public
> IP — out through the internet gateway and back into a security group that only
> allowed my laptop. Loopback fixed it.
>
> What made it expensive was the blast radius: that play had one host in it, so
> when it failed, 100% of the play's hosts had failed and Ansible aborted the
> whole run. The recap showed `failed=0` for the other nodes, which reads like
> they were fine — they'd just never been touched."
