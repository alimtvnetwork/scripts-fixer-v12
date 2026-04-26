#!/usr/bin/env bash
# Tests for resolve_install_method.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../logger.sh"
. "$HERE/../pkg-detect.sh"
. "$HERE/../file-error.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    log_ok   "PASS $name (got: $actual)"; pass=$((pass+1))
  else
    log_err  "FAIL $name expected='$expected' got='$actual'"; fail=$((fail+1))
  fi
}

# 1. Missing config -> none
assert_eq "missing config" "none" "$(resolve_install_method "$TMP/nope.json")"

# 2. Empty install -> none
echo '{"install":{}}' > "$TMP/empty.json"
assert_eq "empty install" "none" "$(resolve_install_method "$TMP/empty.json")"

# 3. apt only (string) on debian-family with apt
echo '{"install":{"apt":"git"}}' > "$TMP/apt.json"
expected="none"
if is_apt_available && is_debian_family; then expected="apt"; fi
assert_eq "apt-string when apt available" "$expected" "$(resolve_install_method "$TMP/apt.json")"

# 4. apt array
echo '{"install":{"apt":["build-essential","gdb"]}}' > "$TMP/apt-arr.json"
assert_eq "apt-array" "$expected" "$(resolve_install_method "$TMP/apt-arr.json")"

# 5. snap only
echo '{"install":{"snap":"code"}}' > "$TMP/snap.json"
exp_snap="none"
if is_snap_available; then exp_snap="snap"; fi
assert_eq "snap only" "$exp_snap" "$(resolve_install_method "$TMP/snap.json")"

# 6. tarball only (object form)
echo '{"install":{"tarball":{"url":"https://example/x.tgz"}}}' > "$TMP/tar.json"
exp_tar="none"
if has_curl; then exp_tar="tarball"; fi
assert_eq "tarball object" "$exp_tar" "$(resolve_install_method "$TMP/tar.json")"

# 7. tarball string short form
echo '{"install":{"tarball":"https://example/x.tgz"}}' > "$TMP/tar2.json"
assert_eq "tarball string" "$exp_tar" "$(resolve_install_method "$TMP/tar2.json")"

# 8. priority: apt > snap > tarball
echo '{"install":{"apt":"git","snap":"git","tarball":"https://x"}}' > "$TMP/all.json"
exp_all="$exp_tar"
if is_snap_available; then exp_all="snap"; fi
if is_apt_available && is_debian_family; then exp_all="apt"; fi
assert_eq "priority apt>snap>tarball" "$exp_all" "$(resolve_install_method "$TMP/all.json")"

# 9. Detection helpers callable
assert_eq "is_root int"       "0" "$(is_root && echo 0 || echo 1)"
assert_eq "get_arch nonempty" "1" "$( [ -n "$(get_arch)" ] && echo 1 || echo 0)"

log_info "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
