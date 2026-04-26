---
name: scripts-linux/_shared/ helpers (bash)
description: Inventory of all shared bash helpers in scripts-linux/_shared/. Logger, file-error, pkg-detect, parallel, apt-install, aria2c-download, path-utils, doctor, registry. Includes upstream provenance + naming-consistency aliases.
type: feature
---
## scripts-linux/_shared/ inventory (post-port from kubernetes-training-v1)

| File | Public functions | Notes |
|---|---|---|
| `logger.sh` | `log_info` `log_ok` `log_warn` `log_err` `log_file_error` `log_msg_ip` | `log_msg_ip` ported from k8s-training/01-logger.sh; supports level arg (info/ok/warn/err) |
| `file-error.sh` | `report_file_missing` `report_file_unreadable` `report_dir_create_failed` `ensure_dir` | CODE RED: every file/path error MUST include exact path + reason |
| `pkg-detect.sh` | `is_apt_available` `is_snap_available` `is_dpkg_available` `has_curl` `has_wget` `has_jq` `has_tar` `is_root` `get_arch` `get_distro_id` `get_distro_like` `get_ubuntu_version` `is_debian_family` `is_apt_pkg_installed` `is_snap_pkg_installed` `resolve_install_method` `is_command_available` `is_package_installed` | `is_command_available` and `is_package_installed` ported from k8s-training/04-is-package-installed.sh |
| `parallel.sh` | `run_parallel` | xargs -P with serial fallback when N<=1 |
| `apt-install.sh` | `apt_install_packages` `apt_install_packages_quiet` | Ported from k8s-training/02-install-apt.sh. Idempotent (dpkg -s check), single apt-get update per session, chatty + quiet variants |
| `aria2c-download.sh` | `aria2c_download` `has_aria2c` | Ported from k8s-training/03-aria2c-download.sh. **Fixes upstream bug** where install_apt_no_msg was called with no args -> aria2c was never auto-installed. Now: aria2c -> curl -> wget fallback chain; returns non-zero on failure |
| `path-utils.sh` | `path_join` `path_join_basename` `path_expand_tilde` + aliases `combine_path` `combine_with_base_path` | Ported from k8s-training/05-combine_path.sh. Pure bash, no external deps. Tilde expansion uses `${p:2}` (NOT `${p#~/}` -- that doesn't strip in bash 4+) |
| `doctor.sh` | env-readiness banner | Existing |
| `registry.sh` | reads `scripts-linux/registry.json` | Existing |
| `tests/` | `smoke.sh` `resolve.sh` `test-base-helpers.sh` | `test-base-helpers.sh` = 31-assertion regression suite for the ported helpers |

## Naming consistency rules (enforced)

- All function names: `snake_case`
- Boolean predicates: `is_<x>` or `has_<x>` (true=0, false=non-zero)
- File paths: bare names, NO numeric prefixes (k8s-training used `01-`, `02-` -- we don't)
- Each ported file has a `# Provenance:` header pointing to upstream
- Backward-compat aliases preserve upstream names (so copy-pasted k8s scripts still work):
  * `combine_path` -> `path_join`
  * `combine_with_base_path` -> `path_join_basename`
  * `is_package_installed` -> `is_command_available` + log
  * `log_message` (upstream) is NOT aliased -- callers use `log_info` instead

## Sourcing order

```bash
. _shared/logger.sh         # always first (others may call log_*)
. _shared/file-error.sh     # depends on logger.sh
. _shared/pkg-detect.sh     # standalone
. _shared/apt-install.sh    # depends on logger.sh + pkg-detect.sh
. _shared/aria2c-download.sh # depends on logger.sh + pkg-detect.sh + apt-install.sh
. _shared/path-utils.sh     # standalone (pure bash)
. _shared/parallel.sh       # standalone
```

## Bug caught during port + fixed

`path_expand_tilde "~/.ssh/id"` initially returned `/root/~/.ssh/id` because
`${p#~/}` does not strip a literal `~` prefix in bash 4+ (the `~` is treated
as the tilde-expansion sentinel, not a literal). Fix: use `${p:2}` to strip
exactly the leading 2 chars (`~/`) by position. Verified by 31 assertions.

Built: v0.118.0
Tests: `bash scripts-linux/_shared/tests/test-base-helpers.sh`
