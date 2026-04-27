---
name: change-port + DNS installer toolkit
description: Root-level change-port.sh and install-dns.sh dispatchers powered by 80-91 port scripts and 100-109 DNS scripts; backup+validate+rollback safety
type: feature
---

# Change-port + DNS toolkit (v0.175.0)

Two new top-level Linux features added in v0.175.0.

## Layout

```
/change-port.sh                            -> scripts-linux/91-change-port-menu/run.sh
/install-dns.sh                            -> scripts-linux/109-install-dns-menu/run.sh

scripts-linux/_shared/port-change.sh       -- shared engine (backup, validate, prompt, restart, rollback)
scripts-linux/_shared/dns-install.sh       -- shared engine (apt/snap/binary, drop-in config write)

scripts-linux/80-change-port-ssh/          (and 81..90)
scripts-linux/91-change-port-menu/         interactive selector
scripts-linux/100-install-dns-bind9/       (and 101..108)
scripts-linux/109-install-dns-menu/        interactive selector
```

## Port-change family (80-90)

Each per-service `run.sh` is ~25 lines: sets `PC_SERVICE_ID`,
`PC_SERVICE_NAME`, `PC_DEFAULT_PORT`, `PC_CONFIG_JSON`,
`PC_SYSTEMD_UNIT`, `PC_VALIDATE_CMD`, `PC_FIREWALL_PROTO`, and
`PC_EDIT_SPECS` (array of `path|||sed-pattern|||sed-replacement-with-{PORT}`),
then calls `pc_run "$@"`.

`pc_run` enforces (in order):
1. arg parsing (--port, -i, --yes, --dry-run, --no-restart, --no-firewall)
2. pre-flight: every targeted file must exist (CODE RED log_file_error)
3. plan render to stderr
4. operator confirm (or --yes / --dry-run)
5. backup each file -> `<path>.bak.<ts>`
6. sed rewrite with `{PORT}` substitution; per-file diff to stderr
7. service-native validator (sshd -t, nginx -t, etc.)
8. ufw/firewalld open NEW port (warns OLD is not closed)
9. systemctl restart unit
10. on any failure -> rollback every edit from backup

SMTP (script 90) is intentionally a READ-ONLY inspector — it will not
modify Postfix because changing port 25 breaks inbound mail delivery.

## DNS family (100-108)

Each per-server `run.sh` is ~15 lines: sets `DNS_ID`, `DNS_NAME`,
`DNS_CONFIG_JSON`, `DNS_INSTALLED_MARK`, then calls `dns_run "$@"`.

`config.json` carries:
- `install.apt` (string|array), optional `install.snap`, optional `install.binary` ({url,dest})
- `verify` shell test, `systemdUnit` to restart
- `configDropPath` + `configTemplate` with `{PORT}/{LISTEN}/{FORWARDERS}` placeholders
- `defaults.{port,listen,forwarders[]}`

`dns_run` supports verbs install|check|repair|uninstall and flags
`-i/--interactive`, `--no-config`, `--port`, `--listen`, `--forwarders`.

## Friendly aliases at root level

`change-port.sh`: ssh sshd | mysql | postgres pg | ftp vsftpd | redis |
mongo mongodb | nginx | apache httpd | docker | rabbitmq | smtp postfix.

`install-dns.sh`: bind bind9 named | unbound | powerdns-auth pdns |
powerdns-recursor recursor | dnsmasq | knot | knot-resolver kresd |
coredns | nsd.

## Verified

- `./change-port.sh --list` and `./install-dns.sh --list` enumerate all
- `./change-port.sh ssh --port 2222 --dry-run` correctly logs CODE RED
  FILE-ERROR when /etc/ssh/sshd_config is missing on the sandbox
- per-service `--help` is uniform across all 20 scripts
- registry.json updated (now 69 entries, was 49)
