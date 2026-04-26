12-install-all-dev-tools
========================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

Title:    Orchestrator with profiles + parallel execution + summary report
Method:   Reads profiles.json, resolves profile -> ordered ID list, dispatches each
          id to "scripts-linux/run.sh -I <id> <verb>" (serial or xargs -P parallel).
          Captures per-script timing + rc, writes JSON + Markdown summary into ../.summary/.

Profiles:
  minimal    - editor + git + node + python                 (4 scripts)
  backend    - minimal + db + docker + java/go/dotnet       (11 scripts)
  fullstack  - backend + pnpm + php + mongo + jenkins       (15 scripts)
  ai         - python venv + ollama + llama.cpp + jupyter   (7 scripts)
  all        - every registered script (* wildcard)         (36 scripts)

Verbs:
  install    Run install for every id in the profile
  check      Run check verb for every id in the profile
  repair     Re-run install for ids whose check fails
  uninstall  Run uninstall in REVERSE order
  --list-profiles   Print all profiles + their resolved id lists
  --profile NAME    Select profile (default: minimal)
  --parallel N      Run N installs concurrently (install verb only, default: 1)
  --stop-on-fail    Abort on first non-zero exit
  --dry-run         Print plan without executing

Summary output:
  ../.summary/run-YYYYMMDD-HHMMSS.json   (machine-readable)
  ../.summary/run-YYYYMMDD-HHMMSS.md     (human-readable table)
