#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    # The exact-NAME resolver behind a recorded-target send (and the window kill
    # and agent-state read) asks `-t "=<session>"` for
    # '#{window_id} #{window_name}' and compares only the NAME half before
    # addressing the ID half, so that format is answered from the recorded task
    # inventory this stub already models as live, with a synthetic @N id that is
    # deliberately NOT the name. Every other -F keeps its previous answer.
    fm_fake_ses=
    fm_fake_prev=
    fm_fake_fmt=name
    for fm_fake_arg in "$@"; do
      [ "$fm_fake_prev" = -t ] && fm_fake_ses=${fm_fake_arg#=}
      fm_fake_prev=$fm_fake_arg
      case "$fm_fake_arg" in *'#{window_id}'*) fm_fake_fmt=id ;; esac
    done
    if [ "$fm_fake_fmt" = id ]; then
      fm_fake_ses=${fm_fake_ses%%:*}
      fm_fake_n=0
      for fm_fake_meta in "${FM_STATE_OVERRIDE:-${FM_HOME:-/nonexistent}/state}"/*.meta; do
        [ -f "$fm_fake_meta" ] || continue
        fm_fake_win=$(sed -n 's/^window=//p' "$fm_fake_meta" | head -1)
        case "$fm_fake_win" in "$fm_fake_ses":*) ;; *) continue ;; esac
        fm_fake_win=${fm_fake_win#*:}
        case "$fm_fake_win" in *:*|'') continue ;; esac
        fm_fake_n=$((fm_fake_n + 1))
        printf '@%s %s\n' "$fm_fake_n" "$fm_fake_win"
      done
      exit 0
    fi
    exit 0
    ;;
  new-window)
    # Real tmux answers `new-window -dP -F '#{window_id}'` with the new
    # window's id, which fm_backend_tmux_create_task captures as the
    # rename-safe handle spawn-time typing then addresses. A stub that
    # printed nothing left that handle empty, so spawn silently fell back
    # to the name form for reads the id exists to make rename-proof.
    for fm_fake_arg in "$@"; do
      case "$fm_fake_arg" in -*P*) printf '@1\n'; break ;; esac
    done
    exit 0 ;;
  has-session|new-session|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  # The first task's own record still claims $POOL_DIR; fm-spawn.sh now
  # refuses to hand that same worktree to a second task while another task's
  # meta still owns it (tests/fm-spawn-pool-worktree-collision.test.sh). A real
  # sequential reuse only happens after fm-teardown.sh retires that record
  # (bin/fm-teardown.sh's `rm -f -- "$STATE/$ID.meta" ...`), so mirror that
  # here before reusing the fixture's pool worktree for a second spawn.
  rm -f "$HOME_DIR/state/pool-current-base-r1.meta" "$HOME_DIR/state/pool-current-base-r1.turn-ended"

  id='pool-current-base-repeat-r1'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

test_fork_tracking_pool_refreshes_from_fork_not_origin() {
  local rec id out status fork_tip
  id='pool-fork-tracking-r6'
  rec=$(make_case fork-tracking "$id")
  read_case_record "$rec"

  # The checkout develops on a fork while origin is an upstream template it
  # cannot even reach - this repo's own shape (see
  # docs/remote-secondmates.md). Only the fork carries the fork-only tooling.
  git clone --quiet --bare "$PROJECT_DIR" "$CASE_DIR/fork.git"
  git -C "$PROJECT_DIR" remote add fork "file://$CASE_DIR/fork.git"
  git clone --quiet "file://$CASE_DIR/fork.git" "$CASE_DIR/fork-publisher"
  printf 'fork-only tooling\n' > "$CASE_DIR/fork-publisher/fork-only.txt"
  git -C "$CASE_DIR/fork-publisher" add fork-only.txt
  git -C "$CASE_DIR/fork-publisher" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fork-only
  git -C "$CASE_DIR/fork-publisher" push --quiet origin main
  git -C "$PROJECT_DIR" fetch --quiet fork
  git -C "$PROJECT_DIR" branch --quiet --set-upstream-to=fork/main main
  git -C "$PROJECT_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  fork_tip=$(git --git-dir="$CASE_DIR/fork.git" rev-parse main)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should provision a pooled worktree from the fork it tracks: $out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$fork_tip" ] \
    || fail "spawn did not start the pooled worktree at the fork's tip"
  assert_grep 'fork-only tooling' "$POOL_DIR/fork-only.txt" \
    "the pooled worktree is missing the fork-only file it should have been provisioned with"
  [ ! -e "$POOL_DIR/advanced-main.txt" ] \
    || fail "spawn provisioned the pooled worktree from origin's diverged lineage instead of the fork's"
  pass "a pooled worktree tracking a fork is provisioned from that fork, even when origin is unreachable"
}

test_origin_fallback_refusal_explains_itself() {
  local rec id out status before
  id='pool-fallback-note-r7'
  rec=$(make_case fallback-note "$id")
  read_case_record "$rec"

  # The checkout tracks fork/main, but the FORK's own default branch is named
  # "trunk" - a name no local branch here carries. freshen_spawn_worktree_base
  # re-resolves the base against that remote default name, finds no configured
  # upstream for it, and falls back to origin/trunk. That fallback is allowed;
  # a refusal that then blames an unreachable origin without saying how origin
  # entered the picture is not, because the operator is left staring at an
  # origin error for a checkout that develops on a fork.
  git clone --quiet --bare "$PROJECT_DIR" "$CASE_DIR/fork.git"
  git -C "$CASE_DIR/fork.git" branch trunk main
  git -C "$CASE_DIR/fork.git" symbolic-ref HEAD refs/heads/trunk
  git -C "$PROJECT_DIR" remote add fork "file://$CASE_DIR/fork.git"
  git -C "$PROJECT_DIR" fetch --quiet fork
  git -C "$PROJECT_DIR" branch --quiet --set-upstream-to=fork/main main
  git -C "$PROJECT_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable fallback base"
  assert_contains "$out" "no upstream configured for trunk; using origin/trunk" \
    "spawn refused on origin without explaining why it fell back to origin at all"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after refusing on the fallback base"
  pass "a refusal on the origin fallback carries the resolver's reason for falling back"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_fork_tracking_pool_refreshes_from_fork_not_origin
test_origin_fallback_refusal_explains_itself
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base

echo "# all fm-spawn-pool-base-freshen tests passed"
