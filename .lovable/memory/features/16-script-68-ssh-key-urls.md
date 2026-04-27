---
name: Script 68 sshKeyUrls -- fetch public keys from URLs
description: add-user.sh and add-user-from-json.sh can fetch authorized_keys from HTTPS URLs with timeout, host allowlist, and max-bytes safety
type: feature
---

# Script 68 -- sshKeyUrls (v0.171.0)

Adds a third source for authorized_keys, alongside `--ssh-key` (inline)
and `--ssh-key-file` (local file): `--ssh-key-url <URL>`. Keys are pulled
over HTTPS, validated, and merged into the existing dedup pipeline.

## Safety guards (all enforced; defaults safe)

| Guard                  | Default                               | Override flag                      |
|------------------------|---------------------------------------|------------------------------------|
| Scheme                 | `https://` only                       | `--allow-insecure-url`             |
| Host allowlist         | github/gitlab/codeberg/bitbucket/launchpad/api.github | `--ssh-key-url-allowlist a,b,c` |
| Per-URL timeout        | 10 seconds                            | `--ssh-key-url-timeout 30`         |
| Connect timeout        | 5 seconds (curl path)                 | n/a                                |
| Max bytes per URL      | 65536 (64 KB)                         | `--ssh-key-url-max-bytes N`        |
| Redirect protocol      | `=https` only (`,http` if insecure)   | follows from `--allow-insecure-url`|
| Max redirects          | 3 (wget path) / curl default          | n/a                                |
| Retries                | 2 with 1s delay (curl)                | n/a                                |
| Hard-cap truncate      | `head -c MAX_BYTES` after fetch       | belt-and-suspenders                |

Allowlist matching:
- Exact match: `github.com` matches only `github.com`.
- Leading-dot suffix: `.corp.local` matches `a.corp.local` and
  `b.x.corp.local` but NOT `corp.local` itself (forces the operator to
  list the apex if they want it).
- Wildcard: a single `*` entry disables host checking. NOT recommended.

curl is preferred (supports `--max-filesize`, `--proto-redir`, retries).
wget is used as a fallback. If neither exists the URL is rejected with
`sshUrlNoCurl`.

## URL body parsing

The fetched body is run through the same `_ssh_emit` filter as
`--ssh-key-file`: blank lines / `#` comments dropped, algo prefix sanity
check (`ssh-rsa|ssh-ed25519|ecdsa-sha2-*|sk-*`), then merged into the
shared dedup buffer. Keys already present in the user's
`authorized_keys` are preserved -- only net-new entries are appended.

Logs include HTTP status code, byte count, and parsed-key count via
`sshUrlFetched`. Key bodies are NEVER logged -- only fingerprints (same
policy as `--ssh-key`/`--ssh-key-file`).

## JSON spec (strict-validated)

`add-user-from-json.sh` accepts these new optional fields:

| Field                       | Type            | Default |
|-----------------------------|-----------------|---------|
| `sshKeyUrls`                | array of strings| `[]`    |
| `sshKeyUrlTimeout`          | non-neg integer | `10`    |
| `sshKeyUrlMaxBytes`         | non-neg integer | `65536` |
| `sshKeyUrlAllowlist`        | string (CSV)    | `""`    |
| `allowInsecureSshKeyUrl`    | boolean         | `false` |

The strict schema validator from v0.170.0 enforces every type. Invalid
records are rejected loudly (e.g. `sshKeyUrls: "string"` -> array hint;
`sshKeyUrlTimeout: "abc"` -> "string is not numeric"; `allowInsecureSshKeyUrl:
"yes"` -> "expected boolean").

## Example

`scripts-linux/68-user-mgmt/examples/users-with-url-keys.json` shows
three patterns: GitHub-only, mixed inline+URL, and internal corp
keyserver via extended allowlist.

## Verified end-to-end (11 tests)

1. `http://` rejected without `--allow-insecure-url`
2. `file://` rejected
3. Host not in allowlist rejected
4. Host extraction strips userinfo + port, lowercases (`USER@Github.COM:443` -> `github.com`)
5. Extra allowlist accepts custom host
6. Leading-dot suffix matches subdomains, not bare apex
7. `*` wildcard disables host check
8. With `--allow-insecure-url`, scheme guard passes but host guard still applies
9. Real fetch of `https://github.com/torvalds.keys` -> 525 bytes, 2 keys parsed
10. Max-bytes hard cap respected (1024-byte cap on real fetch)
11. JSON validator catches every type error in `sshKeyUrls` / `sshKeyUrlTimeout` / `sshKeyUrlMaxBytes` / `allowInsecureSshKeyUrl`
