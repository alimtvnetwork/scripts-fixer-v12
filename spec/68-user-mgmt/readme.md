# 68 — User & SSH key management (cross-OS spec)

Single specification covering both OS implementations:

- Windows leaves: `scripts/os/helpers/*.ps1` (dispatcher: `scripts/os/run.ps1`)
- Unix leaves:    `scripts-linux/68-user-mgmt/*.sh` (dispatcher: `run.sh`)
- Fan-out:        `scripts-orchestrator/playbooks/{users,groups,ssh-keys}-fanout/`

## Pipeline

```
 single-host CLI ──┐
                   ├──► leaf script (idempotent, logs JSON) ──► host mutation
 JSON bundle ──────┤                                                │
                   │                                                ▼
 orchestrator ─────┘                                       cross-OS ledger
   (fan-out)                                              (~/.lovable/...)
                                                                    │
                                                                    ▼
                                          ---FANOUT-RESULT-JSON--- (per host)
                                          ---FANOUT-SUMMARY-JSON--- (rollup)
```

## Invariants

1. **Dispatcher is pure routing** — no business logic, no flag parsing
   beyond `subverb -> leaf`.
2. **Leaves are idempotent** — re-running with identical input is a
   no-op and exits 0.
3. **Errors carry paths** — every file/path failure includes the exact
   path and the reason (CODE RED rule from `mem://features/error-management-file-path-rule`).
4. **Secrets never logged** — passwords are masked; SSH key bodies are
   replaced with `SHA256:` fingerprints in all log lines.
5. **Same JSON shapes on both OSes** — a `users.json` written on Linux
   must work on Windows unchanged (and vice-versa).
6. **Ledger is the source of truth** for SSH key state; helpers must
   acquire the lock before mutating it.

## Audit-line conventions

| Line prefix                       | Emitter                  | Purpose                          |
|-----------------------------------|--------------------------|----------------------------------|
| `FILE-ERROR path='…' reason='…'`  | any leaf                 | CODE RED file/path failure       |
| `---FANOUT-RESULT-JSON---`        | orchestrator             | one per host, machine-readable   |
| `---FANOUT-SUMMARY-JSON---`       | orchestrator             | terminal roll-up                 |
| `LEDGER op=… fp=SHA256:…`         | ssh leaves               | post-mutation ledger record      |

## Cross-references

- Linux readme: `scripts-linux/68-user-mgmt/readme.md`
- Windows readme: `scripts/os/README-user-mgmt.md`
- Ledger schema: `mem://features/ssh-key-ledger` (planned, Phase 7)
- Error rule: `mem://features/error-management-file-path-rule`
- Script structure rule: `mem://preferences/script-structure`