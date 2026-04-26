#!/usr/bin/env bash
set -u
ROOT="${PROJECT_ROOT:-/dev-server}"
SCRIPT="$ROOT/scripts-linux/62-install-zsh-clear/run.sh"

PASS=0; FAIL=0
note(){ printf '\n=== %s ===\n' "$*"; }
ok(){   PASS=$((PASS+1)); echo "  PASS: $*"; }
bad(){  FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A pristine zshrc the user supposedly had BEFORE installing 60+61
PRISTINE=$'# pristine user zshrc\nalias ll="ls -lh"\nexport EDITOR=vim\n'

# A "polluted" zshrc as it would look AFTER 60+61 installed:
#   pristine + 60 extras block + 61 switcher block + a custom user line outside markers
POLLUTED=$'# pristine user zshrc\nalias ll="ls -lh"\nexport EDITOR=vim\n\n# >>> lovable zsh extras >>>\nalias gs="git status"\nplugins=(git zsh-autosuggestions)\n# <<< lovable zsh extras <<<\n\n# user added this AFTER install -- must survive\nexport MY_CUSTOM=42\n\n# >>> lovable zsh-theme switcher >>>\nzsh-theme(){ echo "switcher fn"; }\n# <<< lovable zsh-theme switcher <<<\n'

mkfix(){
  local d="$1"
  rm -rf "$TMP/$d"
  mkdir -p "$TMP/$d/home/.zsh-backups" "$TMP/$d/home/.oh-my-zsh"
  echo "stub" > "$TMP/$d/home/.oh-my-zsh/oh-my-zsh.sh"
}

put_backup(){
  # $1=fix $2=ts $3=content
  local dir="$TMP/$1/home/.zsh-backups/$2"
  mkdir -p "$dir"
  printf '%s' "$3" > "$dir/.zshrc"
}

run62(){ HOME="$TMP/$1/home" bash "$SCRIPT" "${@:2}" 2>&1; }

# --- Case A: install (safe) restores newest backup + strips both blocks ---
note "Case A: install restores latest backup + strips marker blocks"
mkfix A
printf '%s' "$POLLUTED" > "$TMP/A/home/.zshrc"
put_backup A 20260101-120000 "$PRISTINE"
out=$(run62 A install); ec=$?
[ $ec -eq 0 ] && ok "exit 0" || bad "expected 0, got $ec"
h1=$(sha256sum < "$TMP/A/home/.zshrc" | awk "{print \$1}"); h2=$(printf "%s" "$PRISTINE" | sha256sum | awk "{print \$1}"); [ "$h1" = "$h2" ] && ok "zshrc matches pristine backup" || bad "zshrc != pristine (h1=$h1 h2=$h2)"
ls "$TMP/A/home/.zsh-backups/" | grep -q '^pre-clear-' && ok "pre-clear safety backup created" || bad "no pre-clear backup"
[ -d "$TMP/A/home/.oh-my-zsh" ] && ok "~/.oh-my-zsh untouched (safe mode)" || bad "~/.oh-my-zsh removed in safe mode"

# --- Case B: --no-restore strips polluted zshrc IN PLACE, preserving non-marker content ---
note "Case B: --no-restore preserves user lines outside markers"
mkfix B
printf '%s' "$POLLUTED" > "$TMP/B/home/.zshrc"
out=$(run62 B install --no-restore); ec=$?
[ $ec -eq 0 ] && ok "exit 0" || bad "expected 0, got $ec"
grep -q 'MY_CUSTOM=42'              "$TMP/B/home/.zshrc" && ok "custom user line preserved" || bad "user line lost"
grep -q '^# pristine user zshrc'    "$TMP/B/home/.zshrc" && ok "pristine header preserved" || bad "header lost"
grep -q 'gs="git status"'           "$TMP/B/home/.zshrc" && bad "60 extras content NOT stripped" || ok "60 extras content stripped"
grep -q 'zsh-theme(){'              "$TMP/B/home/.zshrc" && bad "61 switcher fn NOT stripped" || ok "61 switcher fn stripped"
grep -Fq '# >>> lovable zsh extras >>>'        "$TMP/B/home/.zshrc" && bad "60 BEGIN marker remains"  || ok "60 BEGIN marker removed"
grep -Fq '# <<< lovable zsh-theme switcher <<<' "$TMP/B/home/.zshrc" && bad "61 END marker remains"   || ok "61 END marker removed"

# --- Case C: check verb reports clean after strip ---
note "Case C: check verb"
out=$(run62 B check); ec=$?
[ $ec -eq 0 ] && ok "check exit 0 after strip" || bad "expected 0, got $ec"
echo "$out" | grep -q "No lovable marker blocks present" && ok "check confirms clean" || bad "no clean message"

# Pollute again and re-check
printf '%s' "$POLLUTED" > "$TMP/B/home/.zshrc"
out=$(run62 B check); ec=$?
[ $ec -eq 1 ] && ok "check exit 1 with residuals" || bad "expected 1, got $ec"
echo "$out" | grep -q "Residual marker block.*60-extras" && ok "check names residual block" || bad "no residual name"

# --- Case D: multiple occurrences of same block all removed ---
note "Case D: duplicate marker blocks all stripped"
mkfix D
cat > "$TMP/D/home/.zshrc" << 'EOF'
# header
# >>> lovable zsh extras >>>
alias one=1
# <<< lovable zsh extras <<<
middle line
# >>> lovable zsh extras >>>
alias two=2
# <<< lovable zsh extras <<<
trailing line
EOF
out=$(run62 D strip); ec=$?
[ $ec -eq 0 ] && ok "strip exit 0" || bad "expected 0, got $ec"
grep -q 'alias one=1' "$TMP/D/home/.zshrc" && bad "first block remains"  || ok "first block stripped"
grep -q 'alias two=2' "$TMP/D/home/.zshrc" && bad "second block remains" || ok "second block stripped"
grep -q '^middle line'   "$TMP/D/home/.zshrc" && ok "middle line kept"   || bad "middle line lost"
grep -q '^trailing line' "$TMP/D/home/.zshrc" && ok "trailing line kept" || bad "trailing lost"

# --- Case E: list-backups + restore by timestamp ---
note "Case E: list-backups + restore <TS>"
mkfix E
put_backup E 20260101-100000 $'# old\n'
put_backup E 20260201-110000 $'# newer\n'
put_backup E 20260301-120000 $'# newest\n'
echo "current garbage" > "$TMP/E/home/.zshrc"
out=$(run62 E list-backups)
echo "$out" | grep -q '20260301-120000' && ok "list-backups shows newest" || bad "newest missing"
echo "$out" | head -2 | tail -1 | grep -q '20260301-120000' && ok "list-backups newest first" || bad "ordering wrong"
out=$(run62 E restore 20260201-110000); ec=$?
[ $ec -eq 0 ] && ok "restore <TS> exit 0" || bad "expected 0, got $ec"
grep -q '^# newer$' "$TMP/E/home/.zshrc" && ok "restored specific timestamp" || bad "did not restore right TS"
out=$(run62 E restore latest); ec=$?
grep -q '^# newest$' "$TMP/E/home/.zshrc" && ok "restore latest picks newest" || bad "latest != newest"

# --- Case F: backup root doesn't exist -> install still runs strip + warns ---
note "Case F: no backup root -> graceful skip + strip"
mkfix F
rm -rf "$TMP/F/home/.zsh-backups"
printf '%s' "$POLLUTED" > "$TMP/F/home/.zshrc"
out=$(run62 F install); ec=$?
[ $ec -eq 0 ] && ok "install exit 0 with no backups" || bad "expected 0, got $ec"
echo "$out" | grep -q "No timestamped backups found" && ok "warns about missing backup root" || bad "no warning"
grep -Fq '# >>> lovable zsh extras >>>' "$TMP/F/home/.zshrc" && bad "60 marker remains" || ok "stripped despite no backup"

echo
echo "============================="
echo "Total: PASS=$PASS  FAIL=$FAIL"
echo "============================="
[ $FAIL -eq 0 ]
