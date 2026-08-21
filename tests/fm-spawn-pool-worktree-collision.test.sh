#!/usr/bin/env bash
# Regression test for fm-spawn.sh's acceptance of the worktree the isolated-copy
# pool hands back (bin/fm-spawn.sh, validate_spawn_worktree).
#
# validate_spawn_worktree already refuses a path that is not a real, distinct
# git worktree, but it never checked that path against worktrees THIS SAME home
# already recorded for OTHER still-tracked tasks. A hard cap, a stale lease, a
# crashed holder, or a race between two spawns can all end with the pool
# provider handing back a worktree another task already owns; without the
# cross-check, fm-spawn.sh silently accepted it and recorded the same worktree
# for two tasks, so whichever task tore down first would return that worktree
# out from under the other task's still-live, uncommitted work.
#
# This test simulates that hand-back with a fake tmux whose pane always reports
# an already-claimed worktree (the "how" a real pool got there - cap, lease,
# race - does not matter to fm-spawn.sh; only what it does with the answer
# does) and asserts the spawn refuses rather than recording the collision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-collision)

# make_collision_fakebin <dir> <path>: a fake tmux whose `#{pane_current_path}`
# always answers <path> - standing in for a pool provider that has already
# settled into some worktree by the time fm-spawn.sh starts polling, regardless
# of which real-world condition (cap, stale lease, crashed holder, race) put it
# there. The fake treehouse is a no-op, exactly like the sibling settle-loop
# test: this suite is about what fm-spawn.sh does with the reported path, not
# about reproducing the pool provider's own internals.
make_collision_fakebin() {
  local dir=$1 path=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-$path}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_collision_spawn() {
  local home=$1 proj=$2 fakebin=$3 wt_target=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt_target" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

# A worktree already recorded as a DIFFERENT, still-tracked task's own copy
# must be refused, not silently adopted by the new task too.
test_worktree_already_owned_by_another_task_is_refused() {
  local case_dir home proj wt fakebin out status
  case_dir="$TMP_ROOT/collision"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "wt-collision"
  fakebin=$(make_collision_fakebin "$case_dir/fake" "$wt")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  # An already-tracked, still-live task recorded as owning $wt.
  fm_write_meta "$home/state/holder-task.meta" \
    "window=firstmate:fm-holder-task" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  local id=collision-new-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"

  out=$(run_collision_spawn "$home" "$proj" "$fakebin" "$wt" "$id")
  status=$?
  expect_code 1 "$status" "spawn must refuse a worktree already owned by another tracked task" "$out"
  assert_contains "$out" "holder-task" "refusal did not name the task that already owns the worktree"
  assert_absent "$home/state/$id.meta" "spawn must not record the colliding worktree for the new task"
  pass "a worktree already recorded for another tracked task is refused, not silently reused"
}

# An unrelated task tracked in the same home, recorded against its OWN
# distinct worktree, must not cause a false-positive refusal.
test_unrelated_task_does_not_block_a_distinct_worktree() {
  local case_dir home proj wt other_wt fakebin out status
  case_dir="$TMP_ROOT/no-collision"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  other_wt="$case_dir/other-wt"
  fm_git_worktree "$proj" "$wt" "wt-no-collision"
  git -C "$proj" worktree add --quiet -b "wt-other" "$other_wt"
  fakebin=$(make_collision_fakebin "$case_dir/fake" "$wt")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  fm_write_meta "$home/state/other-task.meta" \
    "window=firstmate:fm-other-task" \
    "worktree=$other_wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  local id=no-collision-new-z2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"

  out=$(run_collision_spawn "$home" "$proj" "$fakebin" "$wt" "$id")
  status=$?
  expect_code 0 "$status" "spawn onto a distinct worktree must still succeed" "$out"
  assert_grep "worktree=$wt" "$home/state/$id.meta" \
    "meta did not record the settled worktree"
  pass "an unrelated task tracked against its own distinct worktree does not block a fresh spawn"
}

# A worktree a finished task legitimately gave back - its own record retired by
# teardown, exactly like bin/fm-teardown.sh's `rm -f -- "$STATE/$ID.meta"
# "$STATE/$ID.turn-ended"` - must still be handed to a new task normally. The
# collision guard reads only currently-tracked records, so this proves it
# refuses solely on an ACTIVE collision and never on a worktree's mere history.
test_worktree_freed_by_teardown_can_be_reused() {
  local case_dir home proj wt fakebin out status first_id second_id
  case_dir="$TMP_ROOT/freed-reuse"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "wt-freed-reuse"
  fakebin=$(make_collision_fakebin "$case_dir/fake" "$wt")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  first_id=freed-reuse-first-z3
  mkdir -p "$home/data/$first_id"
  printf 'brief for %s\n' "$first_id" > "$home/data/$first_id/brief.md"
  out=$(run_collision_spawn "$home" "$proj" "$fakebin" "$wt" "$first_id")
  status=$?
  expect_code 0 "$status" "the first spawn onto a free worktree must succeed" "$out"
  assert_grep "worktree=$wt" "$home/state/$first_id.meta" \
    "meta did not record the first task's worktree"

  # Retire the first task's record exactly as fm-teardown.sh does once its
  # worktree is genuinely returned to the pool.
  rm -f "$home/state/$first_id.meta" "$home/state/$first_id.turn-ended"

  second_id=freed-reuse-second-z4
  mkdir -p "$home/data/$second_id"
  printf 'brief for %s\n' "$second_id" > "$home/data/$second_id/brief.md"
  out=$(run_collision_spawn "$home" "$proj" "$fakebin" "$wt" "$second_id")
  status=$?
  expect_code 0 "$status" "a worktree freed by teardown must be reusable by a new task" "$out"
  assert_grep "worktree=$wt" "$home/state/$second_id.meta" \
    "meta did not record the second task's reused worktree"
  pass "a worktree a finished task's teardown retired is handed to a new task without refusal"
}

test_worktree_already_owned_by_another_task_is_refused
test_unrelated_task_does_not_block_a_distinct_worktree
test_worktree_freed_by_teardown_can_be_reused

echo "# all fm-spawn-pool-worktree-collision tests passed"
