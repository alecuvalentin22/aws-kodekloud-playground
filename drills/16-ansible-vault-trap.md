# Drill 16 — The vault file that was never loaded

**The question:** "How do you handle secrets in Ansible?"

The answer is `ansible-vault`, and this repo used it. Encrypted file, committed
safely, password supplied at run time. Textbook.

**It had no effect for the entire life of the lab**, and nothing said so.

## How it was found

Keycloak's admin console rejected the password from the vault file. Checking
what actually reached the pod:

```bash
$ kubectl -n keycloak get deploy keycloak -o json | jq '...env'
  KC_BOOTSTRAP_ADMIN_USERNAME = admin
  KC_BOOTSTRAP_ADMIN_PASSWORD = CHANGE-ME-IN-VAULT     # <- the role DEFAULT
```

And directly:

```bash
$ ansible k3s-01 -m debug -a "msg='{{ minio_root_password }}'" --vault-password-file ...
  "msg": "minio=CHANGE-ME-IN-VAULT keycloak=UNDEFINED"
```

`keycloak_admin_password` was **undefined**, despite being in a vault file that
decrypts perfectly and contains exactly that key.

## The cause

```
inventory/group_vars/all.yml      <- variables for the group "all"     LOADED
inventory/group_vars/vault.yml    <- variables for a group "vault"     IGNORED
```

**`vault.yml` is not a magic filename.** Ansible reads
`group_vars/<GROUPNAME>.yml`, so that file declares variables for a group called
`vault` — a group with no hosts. It is silently skipped. No error. No warning.
Not even with `-vvv`, because nothing went wrong: you asked for variables for a
group nobody is in, and got them.

Every secret therefore fell back to its role default. Since the defaults in this
repo are the string `CHANGE-ME-IN-VAULT`, the lab ran with **`CHANGE-ME-IN-VAULT`
as the actual MinIO root password, the actual Keycloak admin password, and the
actual PostgreSQL application password** — and everything worked, because the
same wrong value was used consistently on both sides.

The repo's own README instructed this layout. So the vault workflow had never
worked, and the encryption was theatre: a correctly encrypted file, correctly
committed, correctly decrypted, and correctly ignored.

## The fix

Use the **directory** form. Every file inside `group_vars/all/` applies to the
group `all`:

```
inventory/group_vars/all/vars.yml     <- non-secret variables
inventory/group_vars/all/vault.yml    <- ansible-vault encrypted
```

Both load; `vault.yml` wins for any key it redefines (later file
alphabetically). Verified:

```bash
$ ansible all -m debug -a "msg='{{ minio_root_password }}'" --vault-password-file ...
  "msg": "minio=<the value from vault.yml> keycloak=<...> pg=<...>"
```

## Why this is worse than a normal bug

It fails **open and silently**. A typo'd variable name blows up on first use. A
misplaced vault file just... doesn't apply, and the system keeps running on
defaults. If those defaults had been real-looking passwords instead of
`CHANGE-ME-IN-VAULT`, nothing would ever have looked wrong.

That is the "we thought we had Vault" incident: secrets encrypted at rest,
rotated on schedule, reviewed in PRs — and not in effect.

**Never assume variable precedence. Print it.**

```bash
ansible all -m debug -a "msg={{ some_secret }}" --ask-vault-pass
ansible-inventory --host es-01 --vault-password-file ... | jq
```

## Related precedence facts worth knowing

- role `defaults/` is the **lowest** precedence — anything overrides it, which
  is exactly why the fallback was silent
- `group_vars/all/` < `group_vars/<group>/` < `host_vars/` < `-e` (highest)
- two files in the same `group_vars/<group>/` directory load **alphabetically**,
  so `vault.yml` beats `vars.yml` — put secrets in the later-sorting name
- `-e` beats everything, including vault, which is how the RDS playbook takes a
  Terraform-generated password without it ever touching a file

## Say this in the interview

> "The one that genuinely unsettled me: our vault file was never being loaded.
> It was `group_vars/vault.yml` — but that's not a special name, it declares
> variables for a group called *vault*, which had no hosts. Ansible skipped it
> silently and every secret fell back to its role default.
>
> Everything worked, because both sides used the same wrong value. The fix is
> the directory form, `group_vars/all/vault.yml`. But the lesson is that secret
> management fails *open* — a typo'd variable errors immediately, a misplaced
> vault file just quietly doesn't apply. So I now verify precedence with
> `ansible -m debug` rather than trusting the layout."
