# Proposed engine changes (for the owner of `play` / `lib/common.sh`)

Not applied: `playground/semaphore/` does not edit the engine. Everything
works without these; each one removes a rough edge under Semaphore.

## 1. `play close` without a terminal -- APPLIED 2026-10-16

A Semaphore task has no TTY, so `"${EDITOR:-vi}" "$f"` cannot work there. The
wrapper refuses `close` today and tells the candidate to run it in the terminal.
With this change, the template could offer it too:

```diff
--- a/playground/play
+++ b/playground/play
@@ cmd_close() {
-  "${EDITOR:-vi}" "$f"
-  c_ok "saved $f"
+  if [[ -t 0 && -t 1 ]]; then
+    "${EDITOR:-vi}" "$f"
+    c_ok "saved $f"
+  else
+    # No terminal (Semaphore, CI): leave the template for the candidate to fill in.
+    c_ok "journal template written: $f -- fill it in from your editor"
+  fi
```

Then add `close` to the allowlist in `tasks/play.sh` and a "Close ticket"
template in `project.tf`.

## 2. `$STATE/bin` first on PATH (informational)

`lib/common.sh` does `export PATH="$STATE/bin:$PATH"`. Inside the container
`$STATE/bin` holds the macOS `kind` binary. Harmless today because `play`
never calls `kind` (only `setup/` does), but it would become an "exec format
error" the day it does. Option: prepend `$STATE/bin` only in `setup/*.sh`.

## 3. Drill 08 and Terraform versions (informational)

Drill 08 keeps local state in `$WORK/infra`. Terraform refuses state written
by a NEWER version, so breaking it in the terminal (laptop terraform) and
checking it from Semaphore needs the same version on both sides. The image
pins `TERRAFORM_VERSION=1.14.4` (the laptop's, 2026-10-16) in
`/opt/playground/bin`. If the laptop upgrades, bump the Dockerfile ARG.
