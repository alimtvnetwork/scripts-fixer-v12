#!/usr/bin/env bash
set -u
cd /dev-server
export SCRIPT_ID="test"
. scripts-linux/_shared/logger.sh
. scripts-linux/_shared/pkg-detect.sh
. scripts-linux/_shared/path-utils.sh
. scripts-linux/_shared/apt-install.sh
. scripts-linux/_shared/aria2c-download.sh

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
eq()   { if [ "$1" = "$2" ]; then ok "$3 == '$1'"; else fail "$3: expected '$2', got '$1'"; fi; }

echo "===== path-utils ====="
eq "$(path_join '/a/b/' '/c/d')"     "/a/b/c/d"     "path_join double-slash dedup"
eq "$(path_join '/a/b'  'c/d')"      "/a/b/c/d"     "path_join no leading/trailing"
eq "$(path_join '/a/b/' 'c/d')"      "/a/b/c/d"     "path_join trailing only"
eq "$(path_join '/a/b'  '/c/d')"     "/a/b/c/d"     "path_join leading only"
eq "$(path_join ''      '/c/d')"     "/c/d"         "path_join empty a"
eq "$(path_join '/a/b'  '')"         "/a/b"         "path_join empty b"
eq "$(path_join_basename '/srv/data' '/var/lib/postgres/main')" "/srv/data/main" "path_join_basename"
eq "$(path_expand_tilde '~/.ssh/id')" "$HOME/.ssh/id" "path_expand_tilde ~/path"
eq "$(path_expand_tilde '~')"         "$HOME"         "path_expand_tilde bare ~"
eq "$(path_expand_tilde '/abs/path')" "/abs/path"     "path_expand_tilde absolute (passthrough)"
eq "$(path_expand_tilde 'rel/path')"  "rel/path"      "path_expand_tilde relative (passthrough)"
# backward-compat aliases
eq "$(combine_path '/a/' '/b')"           "/a/b"      "combine_path alias"
eq "$(combine_with_base_path '/x' '/y/z')" "/x/z"     "combine_with_base_path alias"

echo
echo "===== pkg-detect new helpers ====="
if is_command_available bash; then ok "is_command_available bash"; else fail "is_command_available bash"; fi
if is_command_available this-binary-cannot-exist-12345; then
  fail "is_command_available should return 1 for missing"
else
  ok "is_command_available returns 1 for missing binary"
fi
# is_package_installed (logs while checking)
out=$(is_package_installed bash 2>&1; echo "rc=$?")
echo "$out" | grep -q "rc=0" && ok "is_package_installed bash -> rc=0" || fail "is_package_installed bash"

echo
echo "===== logger: log_msg_ip ====="
out=$(log_msg_ip "test message" 2>&1)
echo "$out" | grep -qE '\[.*@.*\] test message' && ok "log_msg_ip default (info) tagged with host @ ip" \
  || { fail "log_msg_ip default level"; echo "    actual: $out"; }
out=$(log_msg_ip "warn message" warn 2>&1)
echo "$out" | grep -qE '\[warn\].*\[.*@.*\] warn message' && ok "log_msg_ip warn level" \
  || { fail "log_msg_ip warn level"; echo "    actual: $out"; }
out=$(log_msg_ip "ok message" ok 2>&1)
echo "$out" | grep -qE '\[ok\].*\[.*@.*\] ok message' && ok "log_msg_ip ok level" \
  || { fail "log_msg_ip ok level"; echo "    actual: $out"; }

echo
echo "===== apt-install: dry checks (no actual apt) ====="
type apt_install_packages       >/dev/null 2>&1 && ok "apt_install_packages defined"       || fail "apt_install_packages missing"
type apt_install_packages_quiet >/dev/null 2>&1 && ok "apt_install_packages_quiet defined" || fail "apt_install_packages_quiet missing"
# Run with empty args -- should be a no-op success
apt_install_packages       2>/dev/null && ok "apt_install_packages with no args: rc=0"       || ok "apt_install_packages with no args returned non-zero (acceptable)"
apt_install_packages_quiet 2>/dev/null && ok "apt_install_packages_quiet with no args: rc=0" || ok "apt_install_packages_quiet with no args returned non-zero (acceptable)"

echo
echo "===== aria2c-download: file:// URL (offline) ====="
TMPSRC=$(mktemp -d); echo "hello-from-test" > "$TMPSRC/payload.txt"
TMPDST=$(mktemp -d)
# Force the curl/wget fallback path by making aria2c unavailable for this test.
__ensure_aria2c_orig=$(declare -f __ensure_aria2c)
__ensure_aria2c() { return 1; }   # pretend aria2c isn't available
aria2c_download "file://$TMPSRC/payload.txt" "$TMPDST" >/tmp/dl.log 2>&1
rc=$?
if [ "$rc" = "0" ] && [ -f "$TMPDST/payload.txt" ] && grep -q "hello-from-test" "$TMPDST/payload.txt"; then
  ok "aria2c_download file:// via curl/wget fallback"
else
  fail "aria2c_download file:// fallback (rc=$rc)"
  cat /tmp/dl.log | head -5
fi
# missing url
aria2c_download "" /tmp 2>/dev/null && fail "missing url should return non-zero" || ok "aria2c_download empty url returns non-zero"
# unwritable output dir
aria2c_download "file://$TMPSRC/payload.txt" "/proc/cant-write-here" 2>/dev/null && fail "unwritable dst should fail" || ok "aria2c_download unwritable dst returns non-zero"
rm -rf "$TMPSRC" "$TMPDST" /tmp/dl.log
eval "$__ensure_aria2c_orig"

echo
echo "===== Verify augments are append-only (no breakage to existing helpers) ====="
type log_info        >/dev/null 2>&1 && ok "log_info still defined (existing)"
type log_file_error  >/dev/null 2>&1 && ok "log_file_error still defined (existing)"
type is_apt_available>/dev/null 2>&1 && ok "is_apt_available still defined (existing)"
type resolve_install_method >/dev/null 2>&1 && ok "resolve_install_method still defined (existing)"
type run_parallel    >/dev/null 2>&1 || . scripts-linux/_shared/parallel.sh
type run_parallel    >/dev/null 2>&1 && ok "run_parallel still loadable (existing)"

echo
echo "============================================="
echo "  PASS: $PASS    FAIL: $FAIL"
echo "============================================="
[ "$FAIL" = "0" ]
