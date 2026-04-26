#!/usr/bin/env bash
# Tests for _shared/git-config-defaults.sh (apply_default_git_config).
# Sandboxes $HOME so the real ~/.gitconfig is never touched.
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SHARED_DIR/../.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; printf '       expected: %s\n       got:      %s\n' "$2" "$3"; }
assert_eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3" "$1" "$2"; }
assert_contains() { case "$2" in *"$1"*) pass "$3";; *) fail "$3" "contains: $1" "$2";; esac; }

printf '%s===== git-config-defaults =====%s\n' "$YEL" "$RST"

if ! command -v git >/dev/null 2>&1; then
  printf '  %sSKIP%s git not installed in sandbox\n' "$YEL" "$RST"; exit 0
fi

# Sandbox.
SANDBOX="$(mktemp -d -t gcd-XXXXXX)"
export HOME="$SANDBOX"
export XDG_CONFIG_HOME="$SANDBOX/.config"
export GIT_CONFIG_GLOBAL="$SANDBOX/.gitconfig"
: > "$GIT_CONFIG_GLOBAL"

# Source after HOME is set so logger files land in sandbox if they need to.
. "$SHARED_DIR/logger.sh"     >/dev/null 2>&1 || true
. "$SHARED_DIR/file-error.sh" >/dev/null 2>&1 || true
. "$SHARED_DIR/git-config-defaults.sh"

# 1. First run on empty config should set every default.
apply_default_git_config >/dev/null 2>&1

assert_eq "main"  "$(git config --global --get init.defaultBranch)"   "init.defaultBranch=main"
assert_eq "input" "$(git config --global --get core.autocrlf)"        "core.autocrlf=input on Linux (osOverride)"
assert_eq "true"  "$(git config --global --get push.autoSetupRemote)" "push.autoSetupRemote=true"
assert_eq "true"  "$(git config --global --get fetch.prune)"          "fetch.prune=true"
assert_eq "false" "$(git config --global --get pull.rebase)"          "pull.rebase=false"
# safe.directory uses --add semantics; expect '*'.
assert_eq "*"     "$(git config --global --get safe.directory)"       "safe.directory=*"
# credential.helper has Linux override.
assert_contains "cache" "$(git config --global --get credential.helper)" "credential.helper has 'cache' (Linux override)"

# 2. Idempotent: running again should NOT duplicate safe.directory entries.
apply_default_git_config >/dev/null 2>&1
sd_count=$(git config --global --get-all safe.directory | wc -l | tr -d ' ')
assert_eq "1" "$sd_count" "safe.directory not duplicated on re-run"

# 3. set-if-empty: pre-existing user value MUST be preserved.
git config --global init.defaultBranch trunk
apply_default_git_config >/dev/null 2>&1
assert_eq "trunk" "$(git config --global --get init.defaultBranch)" "preserves user-set init.defaultBranch"

# 4. --dry-run should not mutate config.
: > "$GIT_CONFIG_GLOBAL"
GCD_DRYRUN=0 apply_default_git_config --dry-run >/dev/null 2>&1
# Count non-empty lines without grep's exit-1-on-no-match perturbing the value.
lines=$(awk 'NF{c++} END{print c+0}' "$GIT_CONFIG_GLOBAL")
assert_eq "0" "$lines" "dry-run did not write to .gitconfig"

# 5. Custom config path with extra safe.directory entries via --add.
: > "$GIT_CONFIG_GLOBAL"
git config --global --add safe.directory /workspace
apply_default_git_config >/dev/null 2>&1
# Both /workspace AND * should be present, in some order.
all=$(git config --global --get-all safe.directory | sort | xargs)
assert_eq "* /workspace" "$all" "merges with pre-existing safe.directory entries"

# Cleanup
rm -rf "$SANDBOX"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%sALL %d ASSERTIONS PASSED%s\n' "$GRN" "$PASS" "$RST"; exit 0
else
  printf '%s%d/%d failed%s\n' "$RED" "$FAIL" "$((PASS+FAIL))" "$RST"; exit 1
fi