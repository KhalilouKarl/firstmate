#!/usr/bin/env bash
# Deterministic checks of the live doorbell guard's dedicated secondmate
# fixture (tests/fixtures.sh: fm_live_sm_fixture_check / _prepare / _cleanup).
# No live Codex and no tokens: this is NOT live secondmate proof. It pins the
# untested report when no fixture is supplied, the preflight refusals, and that
# repeated prepare/spawn/cleanup cycles leave a valid fixture reusable and clean.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-sm-fixture)

git_t() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

# A stand-in firstmate root, and consented standalone clones of it as fixtures.
SRC="$TMP_ROOT/src"
mkdir -p "$SRC/.codex" "$SRC/bin"
printf '# Firstmate\n' > "$SRC/AGENTS.md"
printf 'hooks\n' > "$SRC/.codex/hooks.json"
: > "$SRC/bin/keep"
cp "$ROOT/.gitignore" "$SRC/.gitignore"
git -C "$SRC" init -q -b main
git -C "$SRC" add -A
git_t -C "$SRC" commit -qm initial

new_fixture() {  # <name> -> echoes the clone's path
  local dir="$TMP_ROOT/$1"
  git clone -q "$SRC" "$dir"
  printf '%s\n' "$dir" > "$dir/.git/fm-live-secondmate-fixture"
  printf '%s\n' "$dir"
}

check_rc() {  # <expected-rc> <reason-substring> <label> <dir> [root]
  local want_rc=$1 want=$2 label=$3 dir=$4 root=${5:-$SRC} out rc
  out=$(fm_live_sm_fixture_check "$dir" "$root")
  rc=$?
  expect_code "$want_rc" "$rc" "$label"
  assert_contains "$out" "$want" "$label: report names its reason"
  pass "$label"
}

check_rc 2 'untested: no dedicated fixture supplied' 'unset fixture is untested, not a pass' ''

FIX=$(new_fixture good)
check_rc 1 'not an absolute path' 'relative path refused' good
ln -s "$FIX" "$TMP_ROOT/link"
check_rc 1 'is a symlink' 'symlink refused' "$TMP_ROOT/link"
git -C "$SRC" worktree add -q --detach "$TMP_ROOT/linked"
check_rc 1 'not a standalone clone' 'linked worktree refused' "$TMP_ROOT/linked"
NOS=$(new_fixture nosentinel)
rm "$NOS/.git/fm-live-secondmate-fixture"
check_rc 1 'no consent sentinel' 'missing sentinel refused' "$NOS"
WRONG=$(new_fixture wrongsentinel)
printf '%s\n' "$FIX" > "$WRONG/.git/fm-live-secondmate-fixture"
check_rc 1 'no consent sentinel' 'wrong sentinel refused' "$WRONG"
DIRTY=$(new_fixture dirty)
printf 'x\n' >> "$DIRTY/AGENTS.md"
check_rc 1 'work tree is not clean' 'dirty tree refused' "$DIRTY"
MARK=$(new_fixture marker)
printf 'codex-live\n' > "$MARK/.fm-secondmate-home"
check_rc 1 "stale fixture state; remove manually: $MARK/.fm-secondmate-home" 'pre-existing marker refused' "$MARK"
out=$(FM_HOME="$FIX" fm_live_sm_fixture_check "$FIX" "$SRC") && fail "fixture equal to FM_HOME accepted"
assert_contains "$out" 'equal to or inside' 'fixture equal to FM_HOME refused'
pass 'fixture equal to FM_HOME refused'
out=$(HOME="$FIX" fm_live_sm_fixture_check "$FIX" "$SRC") && fail "fixture equal to HOME accepted"
assert_contains "$out" 'equal to or inside' 'fixture equal to HOME refused'
pass 'fixture equal to HOME refused'
DRIFT=$(new_fixture drift)
git_t -C "$DRIFT" commit -q --allow-empty -m drift
check_rc 1 'HEAD differs' 'HEAD mismatch refused' "$DRIFT"
OTHER=$(new_fixture other-root)
printf 'other\n' > "$OTHER/.codex/hooks.json"
check_rc 1 'hooks.json is missing or differs' 'hooks.json mismatch refused' "$FIX" "$OTHER"

# A valid fixture passes, twice, through the real fm-spawn secondmate path.
for cycle in 1 2; do
  abs=$(fm_live_sm_fixture_check "$FIX" "$SRC") || fail "cycle $cycle: valid fixture refused: $abs"
  assert_equals "$FIX" "$abs" "cycle $cycle: check echoes the canonical fixture"
  fm_live_sm_fixture_prepare "$abs" codex-live || fail "cycle $cycle: prepare failed"
  launch=$(fm_test_capture_codex_launch "$TMP_ROOT/case-$cycle" "--secondmate=$abs")
  assert_contains "$launch" "FM_HOME='$abs'" "cycle $cycle: generated launch runs in the fixture home"
  assert_contains "$launch" '-c disable_paste_burst=true' "cycle $cycle: secondmate launch carries the paste-burst setting"
  assert_not_contains "$launch" '--disable hooks' "cycle $cycle: secondmate keeps hooks on"
  fm_live_sm_fixture_cleanup
  assert_absent "$FIX/.fm-secondmate-home" "cycle $cycle: marker removed"
  assert_absent "$FIX/data" "cycle $cycle: created data/ removed"
  assert_absent "$FIX/state" "cycle $cycle: created state/ removed"
  assert_absent "$FIX/config" "cycle $cycle: spawn wrote no inherited config"
  assert_equals '' "$(git -C "$FIX" status --porcelain --ignored)" "cycle $cycle: fixture left clean"
  pass "cycle $cycle: valid fixture prepared, spawned into, and cleaned"
done
