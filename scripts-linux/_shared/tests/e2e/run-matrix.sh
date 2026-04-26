#!/usr/bin/env bash
# E2E test matrix for scripts 65/66/67.
#
# Goals:
#   1. Run every script's per-folder smoke test on the *current* OS so we
#      get real Linux/Ubuntu coverage out of the box and real macOS
#      coverage when invoked on a Mac CI runner.
#   2. Drive each script through a sandbox-mode dry-run from this matrix
#      so we exercise the production entrypoint (run.sh) end-to-end with
#      the same flags an operator would type, on top of the smoke fixture.
#   3. Assert the OS guard fires correctly when a script is invoked on
#      the wrong OS (66 on Linux, 67 on macOS).
#   4. Assert the root-requirement contract: scripts that touch only
#      $HOME must NOT demand root (--scope user); scripts that touch
#      system paths must refuse without sudo (--scope system from a
#      non-root user).
#
# Every assertion prints PASS/FAIL with the matrix cell that triggered
# it (CODE RED rule: include path + reason on every file/path failure).
#
# Exit codes:
#   0 -> all matrix cells passed
#   1 -> at least one matrix cell failed
#   2 -> harness setup error (couldn't stage sandbox, missing scripts...)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_LINUX="$(cd "$HERE/../../.." && pwd)"

if [ ! -d "$SCRIPTS_LINUX/65-os-clean" ] \
|| [ ! -d "$SCRIPTS_LINUX/66-vscode-menu-cleanup-mac" ] \
|| [ ! -d "$SCRIPTS_LINUX/67-vscode-cleanup-linux" ]; then
  echo "FAIL: harness could not locate scripts 65/66/67 under $SCRIPTS_LINUX"
  exit 2
fi

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYA=$'\e[36m'; DIM=$'\e[2m'; RST=$'\e[0m'
if [ ! -t 1 ] || [ "${NO_COLOR:-0}" = "1" ]; then
  RED=""; GRN=""; YEL=""; CYA=""; DIM=""; RST=""
fi

HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
IS_ROOT=0; [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && IS_ROOT=1

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_CELLS=""

_cell_header() {
  printf '\n%s== matrix cell: %s ==%s\n' "$YEL" "$1" "$RST"
}
_pass() {
  TOTAL_PASS=$((TOTAL_PASS+1))
  printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"
}
_fail() {
  TOTAL_FAIL=$((TOTAL_FAIL+1))
  FAILED_CELLS="$FAILED_CELLS\n  - $1"
  printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"
  [ -n "${2:-}" ] && printf '       %sreason:%s %s\n' "$DIM" "$RST" "$2"
}
_skip() {
  TOTAL_SKIP=$((TOTAL_SKIP+1))
  printf '  %sSKIP%s %s %s(%s)%s\n' "$CYA" "$RST" "$1" "$DIM" "${2:-no reason}" "$RST"
}

# ------------------------------------------------------------------------
# Cell 1: per-folder smoke tests on the current OS
# ------------------------------------------------------------------------
# 65 runs on both Linux and macOS, 66 stubs uname=Darwin so it runs anywhere,
# 67 is Linux-only (the smoke test stubs apt/snap/dpkg). All three smoke
# tests are designed to run on a generic Linux CI box without sudo.
for script in 65-os-clean 66-vscode-menu-cleanup-mac 67-vscode-cleanup-linux; do
  _cell_header "$script :: smoke ($HOST_OS)"
  smoke="$SCRIPTS_LINUX/$script/tests/01-smoke.sh"
  if [ ! -x "$smoke" ] && [ ! -f "$smoke" ]; then
    _fail "$script smoke present at $smoke" "file missing or not executable"
    continue
  fi
  log="$(mktemp -t e2e-$script.XXXXXX)"
  if bash "$smoke" > "$log" 2>&1; then
    _pass "$script smoke completed (log: $log)"
  else
    _fail "$script smoke completed (log: $log)" "non-zero exit; tail follows"
    tail -n 20 "$log" | sed 's/^/       /'
  fi
done

# ------------------------------------------------------------------------
# Cell 2: production entrypoint dry-run against a sandbox HOME
# ------------------------------------------------------------------------
# This is the *operator path*: bash run.sh --dry-run --scope user.
# It must be safe (no mutations) and exit 0 even on a clean machine.
sandbox_home() {
  local d
  d="$(mktemp -d -t e2e-sandbox.XXXXXX)" || { echo ""; return 1; }
  mkdir -p "$d/.config" "$d/.local/bin" "$d/.local/share" \
           "$d/.cache" "$d/Library/Services" "$d/Library/LaunchAgents"
  echo "$d"
}

run_dry() {
  # $1 = label, $2 = script dir, $3.. = extra args
  local label="$1"; local sdir="$2"; shift 2
  local home; home="$(sandbox_home)"
  if [ -z "$home" ]; then
    _fail "$label dry-run staged sandbox" "mktemp failed"
    return
  fi
  local out; out="$(mktemp -t e2e-dry.XXXXXX)"
  HOME="$home" \
  XDG_CACHE_HOME="$home/.cache" \
  LOGS_OVERRIDE="$home/.logs" \
  NO_COLOR=1 \
    bash "$sdir/run.sh" --dry-run "$@" > "$out" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    _pass "$label dry-run rc=0 (out: $out)"
  else
    _fail "$label dry-run rc=$rc (out: $out)" "expected rc=0 from --dry-run"
    tail -n 15 "$out" | sed 's/^/       /'
  fi
  # Mutation guard: nothing under $home should have been deleted that we created.
  if [ -d "$home/.config" ] && [ -d "$home/.local" ]; then
    _pass "$label dry-run preserved sandbox HOME ($home)"
  else
    _fail "$label dry-run preserved sandbox HOME ($home)" "expected ~/.config and ~/.local intact"
  fi
  rm -rf "$home"
}

_cell_header "65-os-clean :: production dry-run"
run_dry "65" "$SCRIPTS_LINUX/65-os-clean" --yes

_cell_header "67-vscode-cleanup-linux :: production dry-run"
if [ "$HOST_OS" = "Linux" ]; then
  run_dry "67" "$SCRIPTS_LINUX/67-vscode-cleanup-linux" --scope user --no-color
else
  _skip "67 production dry-run" "host is $HOST_OS, script is Linux-only"
fi

_cell_header "66-vscode-menu-cleanup-mac :: production dry-run"
if [ "$HOST_OS" = "Darwin" ]; then
  run_dry "66" "$SCRIPTS_LINUX/66-vscode-menu-cleanup-mac" --scope user --no-color
else
  _skip "66 production dry-run" "host is $HOST_OS, script is macOS-only (covered by smoke via uname stub)"
fi

# ------------------------------------------------------------------------
# Cell 3: OS guard checks (run on the WRONG OS)
# ------------------------------------------------------------------------
# 66 must refuse on Linux; 67 must refuse on macOS.
_cell_header "66-vscode-menu-cleanup-mac :: OS guard on $HOST_OS"
if [ "$HOST_OS" = "Linux" ]; then
  out="$(mktemp -t e2e-osguard66.XXXXXX)"
  # No uname stub here -- we want the real OS to be detected.
  HOME="$(mktemp -d)" LOGS_OVERRIDE="$(mktemp -d)" NO_COLOR=1 \
    bash "$SCRIPTS_LINUX/66-vscode-menu-cleanup-mac/run.sh" --dry-run --scope user > "$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _pass "66 refused to run on Linux (rc=$rc, out: $out)"
  else
    _fail "66 refused to run on Linux (rc=$rc, out: $out)" "expected non-zero exit"
  fi
  if grep -Eqi "macos|darwin|not.*support|wrong.*os|requires" "$out"; then
    _pass "66 emitted an OS-mismatch reason"
  else
    _fail "66 emitted an OS-mismatch reason" "no macOS/darwin keyword in output ($out)"
  fi
else
  _skip "66 OS guard on Linux" "host is $HOST_OS"
fi

_cell_header "67-vscode-cleanup-linux :: OS guard on $HOST_OS"
if [ "$HOST_OS" = "Darwin" ]; then
  out="$(mktemp -t e2e-osguard67.XXXXXX)"
  HOME="$(mktemp -d)" LOGS_OVERRIDE="$(mktemp -d)" NO_COLOR=1 \
    bash "$SCRIPTS_LINUX/67-vscode-cleanup-linux/run.sh" --dry-run --scope user > "$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _pass "67 refused to run on macOS (rc=$rc, out: $out)"
  else
    _fail "67 refused to run on macOS (rc=$rc, out: $out)" "expected non-zero exit"
  fi
  if grep -Eqi "linux|ubuntu|not.*support|wrong.*os|requires" "$out"; then
    _pass "67 emitted an OS-mismatch reason"
  else
    _fail "67 emitted an OS-mismatch reason" "no linux/ubuntu keyword in output ($out)"
  fi
else
  _skip "67 OS guard on macOS" "host is $HOST_OS"
fi

# ------------------------------------------------------------------------
# Cell 4: root-requirement contract
# ------------------------------------------------------------------------
# Rule: --scope user must work for any UID (touches only $HOME).
#       --scope system on a non-root UID must either refuse cleanly OR
#       emit a clear "needs root/sudo" warning (not crash, not silently
#       proceed to attempt /etc writes).
#
# We can only assert the non-root path when we ARE non-root. When the
# harness runs as root (typical in CI containers) we fall back to a
# best-effort check: --scope user as root must still complete dry-run
# with rc=0, proving the script does not unconditionally demand sudo.
_cell_header "65-os-clean :: --scope user works without root"
if [ "$IS_ROOT" -eq 1 ]; then
  _skip "65 non-root --scope user" "harness running as root; covered by Cell 2 dry-run"
else
  run_dry "65 non-root user-scope" "$SCRIPTS_LINUX/65-os-clean" --yes
fi

_cell_header "67-vscode-cleanup-linux :: root requirement contract"
if [ "$HOST_OS" != "Linux" ]; then
  _skip "67 root contract" "host is $HOST_OS"
elif [ "$IS_ROOT" -eq 1 ]; then
  # As root, --scope user must still work and must NOT escalate.
  run_dry "67 root --scope user" "$SCRIPTS_LINUX/67-vscode-cleanup-linux" --scope user --no-color
else
  # As non-root, --scope system must either refuse or warn -- never silently proceed.
  out="$(mktemp -t e2e-root67.XXXXXX)"
  HOME="$(mktemp -d)" LOGS_OVERRIDE="$(mktemp -d)" NO_COLOR=1 \
    bash "$SCRIPTS_LINUX/67-vscode-cleanup-linux/run.sh" --dry-run --scope system > "$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] || grep -Eqi "root|sudo|permission" "$out"; then
    _pass "67 --scope system as non-root refused or warned (rc=$rc, out: $out)"
  else
    _fail "67 --scope system as non-root refused or warned (rc=$rc, out: $out)" \
          "expected non-zero rc OR root/sudo/permission keyword in output"
  fi
fi

_cell_header "66-vscode-menu-cleanup-mac :: root requirement contract"
if [ "$HOST_OS" != "Darwin" ]; then
  _skip "66 root contract" "host is $HOST_OS (66 only manages user-scope agents/services)"
else
  run_dry "66 user scope" "$SCRIPTS_LINUX/66-vscode-menu-cleanup-mac" --scope user --no-color
fi

# ------------------------------------------------------------------------
# Final tally
# ------------------------------------------------------------------------
printf '\n%s========== matrix verdict ==========%s\n' "$YEL" "$RST"
printf '  PASS=%d  FAIL=%d  SKIP=%d  (host=%s, root=%s)\n' \
  "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP" "$HOST_OS" "$IS_ROOT"
if [ "$TOTAL_FAIL" -gt 0 ]; then
  printf '%sFailed cells:%s%b\n' "$RED" "$RST" "$FAILED_CELLS"
  exit 1
fi
exit 0