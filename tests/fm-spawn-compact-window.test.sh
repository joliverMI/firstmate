#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's --compact-window handling (AGENTS.md
# captain order, 2026-10-14): an xhigh-effort claude crewmate/scout spawn
# lifts the operator's global autoCompactWindow cap for that one launch via
# claude's --autocompact flag, a secondmate never gets it, and an explicit
# --compact-window overrides the default in either direction.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-compact-window)

# make_case <name> [harness]: isolated home/project/worktree/fakebin case dir,
# mirroring fm-spawn-dispatch-profile.test.sh's make_spawn_case but without
# its per-harness probe stubs, which this claude-only feature does not need.
make_case() {
  local name=$1 harness=${2:-claude} case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR= FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_ship_spawn() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@"
}

test_xhigh_crew_gets_compact_window_override() {
  local rec id out status launch
  id=compact-xhigh-z1
  rec=$(make_case compact-xhigh)
  read_case_record "$rec"

  out=$(run_ship_spawn "$id" --effort xhigh)
  status=$?
  expect_code 0 "$status" "xhigh claude crew spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--autocompact 1000000" \
    "xhigh claude crew spawn should lift the auto-compact window by default"
  assert_grep "compact_window=full" "$HOME_DIR/state/$id.meta" \
    "xhigh claude crew meta should record compact_window=full"
  pass "xhigh-effort claude crew spawn lifts the auto-compact window by default"
}

test_medium_crew_keeps_compact_window_capped() {
  local rec id out status launch
  id=compact-medium-z2
  rec=$(make_case compact-medium)
  read_case_record "$rec"

  out=$(run_ship_spawn "$id" --effort medium)
  status=$?
  expect_code 0 "$status" "medium claude crew spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--autocompact" \
    "medium-effort claude crew spawn must not lift the auto-compact window"
  assert_grep "compact_window=capped" "$HOME_DIR/state/$id.meta" \
    "medium claude crew meta should record compact_window=capped"
  pass "medium-effort claude crew spawn keeps the standing auto-compact cap"
}

test_secondmate_never_gets_compact_window_override() {
  local rec id sm out status launch
  id=compact-secondmate-z3
  rec=$(make_case compact-secondmate)
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sm" --secondmate --effort xhigh)
  status=$?
  expect_code 0 "$status" "xhigh secondmate spawn should still succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--autocompact" \
    "an xhigh secondmate spawn must never lift the auto-compact window"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" \
    "secondmate meta missing kind=secondmate"
  assert_grep "compact_window=capped" "$HOME_DIR/state/$id.meta" \
    "a secondmate's meta must always record compact_window=capped, never full"
  pass "a secondmate never gets the auto-compact window override, even at xhigh effort"
}

test_secondmate_refuses_explicit_compact_window_flag() {
  local rec id sm out status
  id=compact-secondmate-flag-z4
  rec=$(make_case compact-secondmate-flag)
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sm" --secondmate --compact-window full)
  status=$?
  expect_code 1 "$status" "an explicit --compact-window on a secondmate spawn should be refused"
  assert_contains "$out" "secondmate" \
    "the refusal should explain that --compact-window does not apply to secondmates"
  pass "an explicit --compact-window flag on a secondmate spawn is refused"
}

test_explicit_full_overrides_non_xhigh_crew() {
  local rec id out status launch
  id=compact-force-full-z5
  rec=$(make_case compact-force-full)
  read_case_record "$rec"

  out=$(run_ship_spawn "$id" --effort medium --compact-window full)
  status=$?
  expect_code 0 "$status" "forcing compact-window=full on a medium crew should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--autocompact 1000000" \
    "an explicit --compact-window full should lift the window even at medium effort"
  assert_grep "compact_window=full" "$HOME_DIR/state/$id.meta" \
    "meta should record the explicit compact_window=full override"
  pass "an explicit --compact-window full overrides a non-xhigh crew's default"
}

test_explicit_capped_overrides_xhigh_crew() {
  local rec id out status launch
  id=compact-force-capped-z6
  rec=$(make_case compact-force-capped)
  read_case_record "$rec"

  out=$(run_ship_spawn "$id" --effort xhigh --compact-window capped)
  status=$?
  expect_code 0 "$status" "forcing compact-window=capped on an xhigh crew should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--autocompact" \
    "an explicit --compact-window capped must keep the standing cap even at xhigh effort"
  assert_grep "compact_window=capped" "$HOME_DIR/state/$id.meta" \
    "meta should record the explicit compact_window=capped override"
  pass "an explicit --compact-window capped overrides an xhigh crew's default"
}

test_non_claude_harness_never_gets_compact_window_flag() {
  local rec id out status
  id=compact-nonclaude-z7
  rec=$(make_case compact-nonclaude codex)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --compact-window full)
  status=$?
  expect_code 1 "$status" "--compact-window on a non-claude harness spawn should be refused"
  assert_contains "$out" "claude" \
    "the refusal should explain --compact-window is claude-only"
  pass "--compact-window is refused for harnesses other than claude"
}

test_xhigh_crew_gets_compact_window_override
test_medium_crew_keeps_compact_window_capped
test_secondmate_never_gets_compact_window_override
test_secondmate_refuses_explicit_compact_window_flag
test_explicit_full_overrides_non_xhigh_crew
test_explicit_capped_overrides_xhigh_crew
test_non_claude_harness_never_gets_compact_window_flag

echo "# all fm-spawn-compact-window tests passed"
