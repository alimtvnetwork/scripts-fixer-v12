# Playbook contract

Every directory under `playbooks/<name>/` MUST contain:

1. `playbook.json` describing the playbook (name, version, description,
   `osCompatibility` array, ordered `steps[]` each with `file` and `roles`).
2. One or more `NN-name.sh` step files, numbered for execution order.
   Each step:
   - Starts with `#!/usr/bin/env bash` and `set -e`.
   - Is **idempotent** where possible (skip on already-installed).
   - Logs ONE final `[OK]` line on success, or a CODE-RED `[FILE-ERROR] path=... reason=...` line on path failure.
   - Reads tunables from environment variables (e.g. `HELM_VERSION`).
   - MUST NOT depend on any helper not also shipped in the playbook directory.
3. Optional `readme.md` documenting the playbook's purpose and tested OS matrix.

The orchestrator copies each step to `/tmp/<basename>` on the target,
runs it under sudo, and removes it afterward. No persistent state on the
target other than what the step itself installs.
