#!/usr/bin/env bash
# Regression test for fm-spawn.sh's acceptance of the worktree the isolated-copy
# pool hands back (bin/fm-spawn.sh, validate_spawn_worktree).
#
# validate_spawn_worktree already refuses a path that is not a real, distinct
# git worktree, but it never checked that path against worktrees THIS SAME home
# already recorded for OTHER still-tracked tasks. What these tests cover is that
# acceptance-side gap, and nothing upstream of it.
#
# The reported condition itself is UNCONFIRMED and is not what this suite
# proves. Four candidate triggers were driven directly against a real treehouse
# pool - a hard cap with a live holder, a hard cap with a dirty holder, a 9-way
# concurrent race for the last free slot, and a stale/crashed lease - on both
# the CI-pinned and the current release, and none reproduced it: the pool
# refused cleanly every time. So this is a guard against a failure mode that
# could not be triggered, not a fix for one that was, and the original report
# stays unconfirmed at the pool-provider layer.
#
# What is proven is only what fm-spawn.sh does with the answer it is given: IF
# a worktree another tracked task already records were ever handed back, the
# unguarded acceptance would record one copy for two tasks, and whichever task
# tore down first would return it out from under the other's still-live,
# uncommitted work. These tests supply that answer directly with a fake tmux
# whose pane reports an already-claimed worktree - the "how" a real pool could
# get there does not matter to fm-spawn.sh - and assert it refuses rather than
# recording the collision.
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
# FM_FAKE_TMUX_LOG records every fake tmux invocation, so a test can assert what
# the refusal did to the endpoint it created. FM_FAKE_WINDOWS is the session
# inventory and FM_FAKE_PANE_COMMAND the pane's foreground command: together they
# drive fm_backend_agent_state, which a relaunch consults before anything else
# (a recorded window plus an idle shell reads `dead`, the positively agent-free
# endpoint a relaunch requires).
make_collision_fakebin() {
  local dir=$1 path=$2 fakebin winreg
  fakebin=$(fm_fakebin "$dir")
  winreg="$dir/windows"
  : > "$winreg"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
WINREG='$winreg'
[ -z "\${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_TMUX_LOG"
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-$path}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "\${FM_FAKE_PANE_COMMAND:-firstmate}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window)
    # The shared tmux target resolver (bin/backends/tmux.sh) addresses a
    # window this process just created by the stable id \`new-window -dP -F
    # '#{window_id}'\` returns, then later resolves a NAMED kill/send target by
    # matching that id/name pair back out of \`list-windows\`. A stub that
    # answered new-window with nothing left the id empty and every later
    # named-target resolution unable to find the window at all, so record the
    # requested name against a counted id here and answer list-windows from
    # that same registry below.
    fm_fake_name=
    fm_fake_prev=
    for fm_fake_arg in "\$@"; do
      [ "\$fm_fake_prev" = -n ] && fm_fake_name=\$fm_fake_arg
      fm_fake_prev=\$fm_fake_arg
    done
    fm_fake_n=\$(( \$(wc -l < "\$WINREG") + 1 ))
    printf '@%s %s\n' "\$fm_fake_n" "\$fm_fake_name" >> "\$WINREG"
    for fm_fake_arg in "\$@"; do
      case "\$fm_fake_arg" in -*P*) printf '@%s\n' "\$fm_fake_n" ;; esac
    done
    exit 0 ;;
  list-windows)
    if [ -n "\${FM_FAKE_WINDOWS:-}" ]; then
      printf '%s\n' "\${FM_FAKE_WINDOWS}"
    else
      cat "\$WINREG"
    fi
    exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
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
    FM_FAKE_TMUX_LOG="${FM_FAKE_TMUX_LOG:-}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

run_collision_relaunch() {
  local home=$1 fakebin=$2 wt_target=$3 id=$4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt_target" \
    FM_FAKE_WINDOWS="fm-$id" FM_FAKE_PANE_COMMAND="bash" \
    FM_FAKE_TMUX_LOG="${FM_FAKE_TMUX_LOG:-}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1
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

  local tmuxlog="$case_dir/tmux.log"
  : > "$tmuxlog"
  out=$(FM_FAKE_TMUX_LOG="$tmuxlog" run_collision_spawn "$home" "$proj" "$fakebin" "$wt" "$id")
  status=$?
  expect_code 1 "$status" "spawn must refuse a worktree already owned by another tracked task" "$out"
  assert_contains "$out" "holder-task" "refusal did not name the task that already owns the worktree"
  assert_grep "kill-window" "$tmuxlog" \
    "the refusal must close the window this spawn created instead of stranding it on the copy"
  assert_absent "$home/state/$id.meta" "spawn must not record the colliding worktree for the new task"
  assert_grep "worktree=$wt" "$home/state/holder-task.meta" \
    "the guard must never mutate the record of the task that owns the worktree"
  pass "a worktree already recorded for another tracked task is refused, not silently reused"
}

# A relaunch acquires nothing from the pool - it reuses the task's OWN recorded
# worktree - but it is still the case the guard has to cover, because a relaunch
# is only allowed once the prior endpoint reads positively agent-free
# (bin/fm-spawn.sh requires fm_backend_agent_state = dead before it adopts the
# endpoint, and the pane-cwd check that follows is a bare directory read that a
# crashed harness's idle shell also passes). So a dead task's recorded worktree
# may since have been handed to a live task, and relaunching into it is the same
# catastrophe by another door. The refusal must therefore still fire, and must
# say what is actually wrong - two records claiming one path - without the
# pool-exhaustion advice that belongs to the fresh-acquisition path.
test_relaunch_into_a_claimed_worktree_refuses_without_pool_advice() {
  local case_dir home proj wt fakebin out status owner
  case_dir="$TMP_ROOT/relaunch-collision"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "wt-relaunch-collision"
  fakebin=$(make_collision_fakebin "$case_dir/fake" "$wt")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  owner=relaunch-owner-z9
  mkdir -p "$home/data/$owner"
  printf 'brief for %s\n' "$owner" > "$home/data/$owner/brief.md"
  fm_write_meta "$home/state/$owner.meta" \
    "window=firstmate:fm-$owner" \
    "endpoint_task_id=$owner" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  fm_write_meta "$home/state/relaunch-holder-task.meta" \
    "window=firstmate:fm-relaunch-holder-task" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_collision_relaunch "$home" "$fakebin" "$wt" "$owner")
  status=$?
  expect_code 1 "$status" "a relaunch into a worktree another record claims must refuse" "$out"
  assert_contains "$out" "relaunch-holder-task" "the relaunch refusal did not name the record that also claims the worktree"
  assert_contains "$out" "stale record" "the relaunch refusal must point at the stale record as the thing to retire"
  assert_not_contains "$out" "treehouse status" \
    "a relaunch makes no pool call, so it must not send the operator to the pool"
  assert_not_contains "$out" "hard cap" \
    "a relaunch makes no pool call, so pool-exhaustion wording is misleading there"
  assert_grep "worktree=$wt" "$home/state/$owner.meta" \
    "a refused relaunch must leave the task's own record untouched"
  pass "a relaunch into a worktree another record claims refuses with record advice, not pool advice"
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
test_relaunch_into_a_claimed_worktree_refuses_without_pool_advice
test_unrelated_task_does_not_block_a_distinct_worktree
test_worktree_freed_by_teardown_can_be_reused

echo "# all fm-spawn-pool-worktree-collision tests passed"
