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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0