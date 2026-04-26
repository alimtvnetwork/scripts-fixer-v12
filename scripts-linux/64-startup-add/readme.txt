64-startup-add  --  Cross-OS startup-add (apps + env vars), Unix side

let's start now 2026-04-26 22:55 MYT

Mirrors the Windows feature in scripts/os/startup-add. Lets you register an
application (executable / script) or an environment variable to run/exist at
user login on Linux or macOS, with a TTY method picker.

USAGE
  ./run.sh -I 64 -- app  <path> [--method auto|autostart|systemd-user|shell-rc|launchagent|login-item] [--name N] [--args "..."] [--interactive]
  ./run.sh -I 64 -- env  KEY=VALUE [--scope user] [--method shell-rc|systemd-env|launchctl]
  ./run.sh -I 64 -- list                 [--scope user|all]
  ./run.sh -I 64 -- remove <name>        [--method ...]

SAFE DEFAULTS
  Linux GUI session    -> autostart    (~/.config/autostart/lovable-startup-<name>.desktop)
  Linux headless       -> systemd-user (~/.config/systemd/user/lovable-startup-<name>.service)
  macOS                -> launchagent  (~/Library/LaunchAgents/com.lovable.startup.<name>.plist)
  env (any OS)         -> shell-rc     (marker block in ~/.zshrc or ~/.bashrc)

LOGS
  Per-run dir at .logs/64/<TIMESTAMP>/ with command.txt, manifest.json, session.log
  (mirrors the layout used by 63-remote-runner).

IDEMPOTENCY
  Every entry is tagged 'lovable-startup-<name>' so list/remove can safely
  filter without touching unrelated user entries. Same name + same method
  is upsert; same name + different method warns unless --force-replace.

NON-GOALS
  - No /etc system-wide writes unless an explicit machine-scope method is added later.
  - No GUI; picker is TTY only.
