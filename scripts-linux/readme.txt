Linux Installer Toolkit
=======================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

v0.127.0 milestone: Script 68 (cross-OS user/group management) COMPLETE.
  - Root run.sh dispatcher + 4 leaves: add-user, add-group,
    add-user-from-json, add-group-from-json (Linux + macOS).
  - JSON loader auto-detects single object, array, or {users:[]} / {groups:[]}.
  - Plain --password CLI/JSON allowed (mirrors Windows os add-user risk),
    plus --password-file with 0600 mode check. Passwords never logged;
    console echo masked.
  - Linux uses useradd/groupadd/chpasswd/usermod; macOS uses dscl with
    automatic UID/GID allocation from 510.
  - CODE RED file/path errors: exact path + reason on every failure.
  - Smoke test: 9/9 PASS in dry-run (no root, no host mutation).
  - Full docs: scripts-linux/68-user-mgmt/readme.md

v0.126.0 milestone: Script 64 (cross-OS startup-add) COMPLETE.
  - 6 methods: autostart, systemd-user, shell-rc-app, launchagent, login-item, shell-rc-env
  - Subverbs: app | env | list | remove (all wired through dispatcher)
  - Tag-based enumeration (lovable-startup-*) -> deterministic list/remove
  - macOS plist round-trips through plistlib; env values survive sourcing
  - Smoke test: 4 entries -> 2 removes -> empty list
  - Full docs: scripts-linux/64-startup-add/readme.md
  - Memory:    .lovable/memory/features/03-cross-os-startup-add.md

Earlier milestone (v0.114.0): skeleton + shared helpers complete.

Layout:
  _shared/         logger, pkg-detect, parallel, file-error, registry
  _shared/tests/   smoke.sh
  registry.json    list of scripts and their phase
  run.sh           root dispatcher (install|check|repair|uninstall|--list|-I)
  .installed/      per-script install markers (runtime)
  .resolved/       runtime resolved state
  .logs/           per-script logs
  64-startup-add/  cross-OS startup entry manager (Linux + macOS)

Resolution order per package: apt-get -> snap -> tarball/curl|sh -> none

Run smoke test:    bash scripts-linux/_shared/tests/smoke.sh
List scripts:      bash scripts-linux/run.sh --list
Startup demo:      HOME=/tmp/x bash scripts-linux/64-startup-add/run.sh list

CODE RED rule: every file/path error logs exact path + reason via log_file_error.

Next phases:
  02 Detection layer hardening + resolve_install_method tests
  03 Foundational tools (nodejs, python, git, cpp, powershell)
  04 Editors + terminals
  05 Language runtimes
  06 SQL databases
  07 NoSQL + search
  08 Containers + orchestration
  09 AI tools
  10 Cross-platform UX
  11 Orchestrator
  12 Health-check + repair
  13 macOS port
  14 Docs + E2E tests
