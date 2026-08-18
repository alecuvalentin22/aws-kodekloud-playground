# Drill 06 — Turn security on

Once the cluster mechanics are comfortable, set `elastic_security_enabled: true`
in `inventory/group_vars/all.yml` and rebuild. This is the configuration a real
production cluster runs, and it is worth having done once.

What you will have to work through:
1. **Transport TLS** — generate a CA and node certs with
   `elasticsearch-certutil ca` / `elasticsearch-certutil cert`. Every node must
   trust the same CA or the cluster will not form.
2. **HTTP TLS** — separate keystore, and Kibana now needs the CA to trust it.
3. **Built-in users** — `elasticsearch-setup-passwords` / the `elastic` user, and
   a service account token for Kibana rather than a password in a config file.
4. **Roles and role mappings** — create a read-only role for a log-viewing user.
   This maps directly onto RBAC work you already do on the IDP platform, so it is
   the easiest part to speak about with authority.

The pain here is certificate distribution, and that pain is exactly why doing it
by hand once makes you credible when someone asks how you would operate it.
