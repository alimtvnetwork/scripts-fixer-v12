# 07 — Per-Repo Implementation Checklist

Use this checklist when migrating an existing repo (`scripts-fixer-vN`)
to the generic spec.

## Files to add or update

- [ ] `quick-install.ps1` — thin wrapper, sources shared discovery
- [ ] `quick-install.sh` — same in Bash
- [ ] `release-install.ps1` — strict mode wrapper
- [ ] `release-install.sh` — same in Bash
- [ ] `error-manage.ps1` — diagnostics
- [ ] `error-manage.sh` — same in Bash
- [ ] `scripts/shared/install-bootstrap-core.ps1` — discovery + mode resolution
- [ ] `scripts/shared/install-bootstrap-core.sh` — same in Bash
- [ ] `.resolved/install-source.json` written after install (gitignored)
- [ ] `changelog.md` entry under matching version

## Existing files to keep

- `install.ps1`, `install.sh` — keep as legacy aliases that call
  `quick-install.*`. Log `[DEPRECATED] use-quick-install` once.
- `spec/install-bootstrap/readme.md` — keep, but add a top-of-file
  banner pointing to `spec/00-generic-install-script-behavior/`.

## Test matrix per repo

| Test | Expected |
|------|----------|
| `quick-install` from v3, v9 exists | Redirects to v9 main |
| `quick-install -NoUpgrade` from v3 | Stays on v3 |
| `release-install` from v3, v9 has release | Redirects to v9 release tag |
| `release-install` from v3, no release in v1..v20 | Exits `2` |
| `error-manage --json` | Prints JSON, exit `0` |
| Network offline | Logs `[SKIP] discovery-offline`, continues from current |
| `SCRIPTS_FIXER_REDIRECTED=1` set | Skips discovery |
| `release-install --main` | Exits `2` (`conflicting-modes`) |

## Migration order (recommended)

1. Land `install-bootstrap-core.{ps1,sh}` first.
2. Add `quick-install.*` (lowest risk, just renames `install.*`).
3. Add `release-install.*` (strict path, can be tested in isolation).
4. Add `error-manage.*` (read-only, lowest risk).
5. Update `install.*` to delegate to `quick-install.*`.
6. Bump minor version, update `changelog.md`.

## Per-repo version bump

Each repo bumps its own minor version when adopting this spec. Tag the
release `vX.Y.0+generic-bootstrap` so `error-manage` can detect
adoption status across the family.

## Memory + tracker updates

- Update `mem://features/install-bootstrap` to add a "see also"
  pointer to this spec.
- Mark
  `.lovable/pending-issues/01-generic-install-spec-awaiting-confirmation.md`
  as resolved.
- Tick the matching item in
  `.lovable/memory/suggestions/01-suggestions-tracker.md` if added.