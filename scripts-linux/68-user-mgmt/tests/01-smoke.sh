#!/usr/bin/env bash
# Smoke test for 68-user-mgmt. Runs entirely in --dry-run mode so it does
# NOT need root and does NOT mutate the host. Verifies:
#   1. root dispatcher routes every subverb to the right leaf
#   2. CLI parsing on add-user / add-group rejects bad flags with exit 64
#   3. JSON loaders auto-detect array, single-object, and wrapped shapes
#   4. CODE RED file/path errors fire with exact path + reason on missing JSON
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$SCRIPT_DIR/run.sh"

pass=0; fail=0
_pass() { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
_fail() { fail=$((fail+1)); printf '  [FAIL] %s\n  expected: %s\n  got: %s\n' "$1" "$2" "$3"; }

# 1. dispatcher --help works
out=$(bash "$RUN" --help 2>&1) && rc=0 || rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "add-user-json"; then
  _pass "dispatcher --help lists subverbs"
else
  _fail "dispatcher --help" "rc=0 + lists add-user-json" "rc=$rc"
fi

# 2. unknown subverb -> exit 64 with file/path style failure message
out=$(bash "$RUN" no-such-thing 2>&1); rc=$?
if [ $rc -eq 64 ] && echo "$out" | grep -q "unknown subverb"; then
  _pass "unknown subverb exits 64"
else
  _fail "unknown subverb" "rc=64 + 'unknown subverb' msg" "rc=$rc out=$out"
fi

# 3. add-user with no name -> exit 64
out=$(bash "$RUN" add-user --dry-run 2>&1); rc=$?
if [ $rc -eq 64 ]; then
  _pass "add-user without name exits 64"
else
  _fail "add-user without name" "rc=64" "rc=$rc"
fi

# 4. add-group with no name -> exit 64
out=$(bash "$RUN" add-group --dry-run 2>&1); rc=$?
if [ $rc -eq 64 ]; then
  _pass "add-group without name exits 64"
else
  _fail "add-group without name" "rc=64" "rc=$rc"
fi

# 5. add-user-json with missing file -> exit 2 + FILE-ERROR record
out=$(bash "$RUN" add-user-json /nonexistent/path/users.json 2>&1); rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "FILE-ERROR" && echo "$out" | grep -q "/nonexistent/path/users.json"; then
  _pass "add-user-json missing file: rc=2 + FILE-ERROR with exact path"
else
  _fail "add-user-json missing file" "rc=2 + FILE-ERROR exact path" "rc=$rc out=$out"
fi

# 6. JSON shape auto-detect: object, array, wrapped (parse-only via dry-run)
#    These need jq installed. If jq is missing, skip with [SKIP].
if command -v jq >/dev/null 2>&1; then
  for f in user-single.json users.json users-wrapped.json; do
    full="$SCRIPT_DIR/examples/$f"
    if [ ! -f "$full" ]; then
      _fail "example exists: $f" "file present" "missing at $full"
      continue
    fi
    # Dry-run still requires no root; the script's um_require_root early-exits
    # ok under UM_DRY_RUN=1, so this exercises the JSON parser end-to-end.
    out=$(bash "$RUN" add-user-json "$full" --dry-run 2>&1); rc=$?
    # Parser success means we see "loaded N user record(s)" in output.
    if echo "$out" | grep -qE 'loaded [0-9]+ user record'; then
      _pass "JSON shape auto-detect ok: $f"
    else
      _fail "JSON parse: $f" "loaded N user record(s)" "rc=$rc out=$(echo "$out" | head -3)"
    fi
  done

  # 7. groups JSON
  out=$(bash "$RUN" add-group-json "$SCRIPT_DIR/examples/groups.json" --dry-run 2>&1); rc=$?
  if echo "$out" | grep -qE 'loaded [0-9]+ group record'; then
    _pass "groups JSON auto-detect ok"
  else
    _fail "groups JSON parse" "loaded N group record(s)" "rc=$rc out=$(echo "$out" | head -3)"
  fi
else
  printf '  [SKIP] JSON tests need jq (not installed)\n'
fi

# 8. edit-user without name -> exit 64
out=$(bash "$RUN" edit-user --dry-run 2>&1); rc=$?
if [ $rc -eq 64 ]; then
  _pass "edit-user without name exits 64"
else
  _fail "edit-user without name" "rc=64" "rc=$rc"
fi

# 9. edit-user with no flags -> warn + exit 0 (nothing to do)
out=$(bash "$RUN" edit-user someuser --dry-run 2>&1); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "no changes requested"; then
  _pass "edit-user with no flags warns and exits 0"
else
  _fail "edit-user no flags" "rc=0 + 'no changes requested'" "rc=$rc out=$out"
fi

# 10. edit-user --promote and --demote together -> exit 64
out=$(bash "$RUN" edit-user someuser --promote --demote --dry-run 2>&1); rc=$?
if [ $rc -eq 64 ]; then
  _pass "edit-user --promote+--demote rejected (exit 64)"
else
  _fail "edit-user --promote+--demote" "rc=64" "rc=$rc out=$out"
fi

# 11. remove-user without name -> exit 64
out=$(bash "$RUN" remove-user --dry-run 2>&1); rc=$?
if [ $rc -eq 64 ]; then
  _pass "remove-user without name exits 64"
else
  _fail "remove-user without name" "rc=64" "rc=$rc"
fi

# 12. remove-user --dry-run on nonexistent -> exit 0 (idempotent: warns)
out=$(bash "$RUN" remove-user no-such-user-xyz --yes --dry-run 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  _pass "remove-user dry-run on nonexistent exits 0 (idempotent)"
else
  _fail "remove-user nonexistent" "rc=0" "rc=$rc out=$out"
fi

# 13. edit-user multi-flag plan banner renders rename + add-group + shell + comment
out=$(bash "$RUN" edit-user someuser --rename newname --promote \
        --add-group docker --shell /bin/zsh --comment "X" --dry-run 2>&1)
if echo "$out" | grep -q "edit-user plan for 'someuser'" \
   && echo "$out" | grep -q "rename 'someuser' -> 'newname'" \
   && echo "$out" | grep -q "add groups: docker,sudo" \
   && echo "$out" | grep -q "set shell: /bin/zsh"; then
  _pass "edit-user multi-flag plan banner renders all changes"
else
  _fail "edit-user multi-flag plan" "rename+groups+shell lines present" "$(echo "$out" | head -10)"
fi

# 14. edit-user --enable + --disable mutual exclusion -> exit 64
out=$(bash "$RUN" edit-user someuser --enable --disable --dry-run 2>&1); rc=$?
if [ $rc -eq 64 ]; then
  _pass "edit-user --enable+--disable rejected (exit 64)"
else
  _fail "edit-user --enable+--disable" "rc=64" "rc=$rc out=$out"
fi

# 15. remove-user --purge-profile (Windows alias) accepted on Unix
out=$(bash "$RUN" remove-user no-such-user-xyz --purge-profile --yes --dry-run 2>&1); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "remove-user plan for 'no-such-user-xyz'"; then
  _pass "remove-user --purge-profile alias accepted on Unix"
else
  _fail "remove-user --purge-profile" "rc=0 + plan banner" "rc=$rc out=$out"
fi

# 16. JSON loaders: edit-user-json + remove-user-json + bare-string list
if command -v jq >/dev/null 2>&1; then
  for pair in \
      "edit-user-json:examples/edit-users.json:loaded [0-9]+ user-edit record" \
      "edit-user-json:examples/edit-users-wrapped.json:loaded [0-9]+ user-edit record" \
      "remove-user-json:examples/remove-users.json:loaded [0-9]+ user-removal record" \
      "remove-user-json:examples/remove-users-wrapped.json:loaded [0-9]+ user-removal record" \
      "remove-user-json:examples/remove-users-bare.json:loaded [0-9]+ user-removal record"
  do
    sub=${pair%%:*}; rest=${pair#*:}
    file=${rest%%:*}; needle=${rest#*:}
    full="$SCRIPT_DIR/$file"
    if [ ! -f "$full" ]; then
      _fail "example exists: $file" "file present" "missing at $full"; continue
    fi
    out=$(bash "$RUN" "$sub" "$full" --dry-run 2>&1)
    if echo "$out" | grep -qE "$needle"; then
      _pass "JSON loader $sub parses $(basename "$file")"
    else
      _fail "JSON loader $sub: $file" "$needle" "$(echo "$out" | head -3)"
    fi
  done

  # 17. edit-user-json: per-record promote+demote rejection propagates
  tmp="${TMPDIR:-/tmp}/68-smoke-bad-edit-$$.json"
  printf '[{"name":"x","promote":true,"demote":true}]' > "$tmp"
  out=$(bash "$RUN" edit-user-json "$tmp" --dry-run 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    _pass "edit-user-json per-record promote+demote rejected"
  else
    _fail "edit-user-json promote+demote" "non-zero rc" "rc=$rc out=$(echo "$out" | head -5)"
  fi
  rm -f "$tmp"

  # 18. remove-user-json missing file -> exit 2 + FILE-ERROR with exact path
  bogus=/nonexistent/path/remove-users.json
  out=$(bash "$RUN" remove-user-json "$bogus" 2>&1); rc=$?
  if [ $rc -eq 2 ] && echo "$out" | grep -q "FILE-ERROR" && echo "$out" | grep -q "$bogus"; then
    _pass "remove-user-json missing file: rc=2 + FILE-ERROR with exact path"
  else
    _fail "remove-user-json missing file" "rc=2 + FILE-ERROR exact path" "rc=$rc out=$out"
  fi
else
  printf '  [SKIP] edit-user-json/remove-user-json tests need jq\n'
fi

# 19. dispatcher aliases: modify-user-json + delete-user-json route correctly
if command -v jq >/dev/null 2>&1; then
  out=$(bash "$RUN" modify-user-json "$SCRIPT_DIR/examples/edit-users.json" --dry-run 2>&1)
  if echo "$out" | grep -qE 'loaded [0-9]+ user-edit record'; then
    _pass "dispatcher alias modify-user-json routes to edit-user-json"
  else
    _fail "alias modify-user-json" "loaded N user-edit record(s)" "$(echo "$out" | head -3)"
  fi
  out=$(bash "$RUN" delete-user-json "$SCRIPT_DIR/examples/remove-users-bare.json" --dry-run 2>&1)
  if echo "$out" | grep -qE 'loaded [0-9]+ user-removal record'; then
    _pass "dispatcher alias delete-user-json routes to remove-user-json"
  else
    _fail "alias delete-user-json" "loaded N user-removal record(s)" "$(echo "$out" | head -3)"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0