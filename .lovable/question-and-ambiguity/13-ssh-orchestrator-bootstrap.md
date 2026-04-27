# 13 - SSH orchestrator: spec + scaffold + kubeadm playbook

**Spec reference:** "Run the same command on multiple OS using SSH from
root level. Install Kubernetes and other tools using SSH. Easy
password->key bootstrap. Write a memory spec, then implement. NO UI."

## Confirmed decisions (from question round)

- **Controller runtime:** Bash + POSIX sh.
- **K8s distribution:** kubeadm + CRI-O + Kubernetes v1.31, ported from
  `aukgit/kubernetes-training-v1/03-kube-Installer` (Weave CNI, Helm 3.16.2).
- **Windows targets:** out of scope (Linux + macOS only).
- **Key strategy:** configurable per HostGroup (default common, opt-in per-host).

Spec saved to `mem://specs/01-ssh-orchestration` and indexed in
`mem://index.md`.

## What was implemented

```
scripts-orchestrator/
  run.sh                        # 194 lines, subcmds: bootstrap|run|playbook|inventory|log
  lib/01-logger.sh              # CODE-RED log_file_error helper
  lib/02-os-detect.sh           # /etc/os-release + uname probe
  lib/03-ssh-exec.sh            # ControlMaster multiplexed ssh + scp wrappers
  lib/04-parallel.sh            # bounded parallel runner (wait -n)
  lib/05-vault.sh               # AES-256-CBC + PBKDF2 (see note below)
  lib/06-sqlite-audit.sh        # 9 PascalCase tables, audit_log helper
  lib/07-inventory.sh           # POSIX [section]+key=value parser, no YAML dep
  lib/08-bootstrap.sh           # password->key->config->verify
  playbooks/k8s-kubeadm/        # 6 ordered .sh + playbook.json
  inventory.example/            # hosts.conf + groups.conf samples
  readme.md
```

## Inferences made

1. **`openssl enc` does NOT support GCM mode.** Initial spec said
   AES-256-GCM; switched to AES-256-CBC + PBKDF2. CBC + 0600 file mode +
   0700 vault dir is appropriate for local at-rest secrets on a trusted
   controller. Documented inline in `05-vault.sh`.
2. **Used `wait -n`** for the parallel runner (bash 4.3+). Validated
   timing: 4 jobs * 0.3s with max-concurrency 2 finished in **616 ms**
   (sequential would be ~1200 ms), confirming parallelism works.
3. **POSIX inventory format** (`.conf` with `[section]` + `key=value`)
   chosen over YAML to avoid a parser dependency on the controller.
4. **Worker join command provisioning** is two-phase: control-plane init
   step prints the join command, operator (or a future automation hook)
   writes it to `/etc/ssh-orchestrator/k8s-join.cmd` on every worker, then
   `04-join-worker.sh` consumes it. Documented in the script's
   CODE-RED FILE-ERROR message.
5. **Inline commands gated behind `--allow-inline`** to make the audit
   trail explicit -- preapproved playbooks are the default.
6. **No UI** per user correction.

## Verification (this loop)

| Check | Result |
|---|---|
| `bash -n` on all 15 .sh files | 0 failures |
| `run.sh --version` | `ssh-orchestrator 0.1.0` |
| `run.sh --help` | full usage printed |
| `inventory list` | parsed 3 example hosts correctly |
| `inventory show k8s-master` | all 5 fields returned |
| sqlite audit DB schema | 9 PascalCase tables created |
| `audit_log` roundtrip | 2 rows inserted + read back via sqlite3 |
| Parallel runner timing | 616 ms for 4x0.3s jobs, max=2 (sequential ~1200 ms) |
| Vault encrypt/decrypt (OpenSSL 3.6.1 via nix) | `stored` -> `decrypt OK -> [supersecret-pw]` |
| CODE-RED FILE-ERROR format | `[FILE-ERROR] path=... reason=...` confirmed for missing playbook dir |

## Controller install requirements

`apt-get install -y openssh-client sshpass sqlite3 openssl`
(Mac: `brew install sshpass sqlite openssl` -- sshpass is in
`hudochenkov/sshpass` tap.)

## How to revert

`rm -rf scripts-orchestrator/` and remove the index entry +
`.lovable/memory/specs/01-ssh-orchestration.md`.
