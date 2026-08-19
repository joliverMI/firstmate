#!/usr/bin/env bash
# tests/fm-dashboard-card-link.test.sh - end-to-end coverage for the mechanical
# link between a spawned/torn-down task and its Admiral's Fleet Dashboard card
# (docs/dashboard.md "The mechanical card link"): bin/fm-spawn.sh's --card
# populates the card's ref/agent identity and advances a not_started card to
# working; bin/fm-teardown.sh consumes that identity from state/<id>.meta and
# advances the card to testing once cleanup actually succeeds. Both scripts
# and a real dashboard server are driven only through their public CLIs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "skipped - jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-card-link)

# --- shared dashboard server -------------------------------------------------
# One real server for the whole file, exactly like tests/fm-dashboard.test.sh.
# FM_DASHBOARD_HOST/PORT are exported so every subprocess this file spawns -
# this test's own $DASH calls, fm-spawn.sh's internal link, and
# fm-teardown.sh's internal advance - resolves the same server regardless of
# what FM_HOME each of those scripts otherwise runs with.
DASHBOARD_HOME="$TMP_ROOT/dashboard-home"
mkdir -p "$DASHBOARD_HOME/state" "$DASHBOARD_HOME/data"
SERVER_PID=""

fm_card_link_test_cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  fm_test_cleanup
}
trap fm_card_link_test_cleanup EXIT
trap 'fm_card_link_test_cleanup; exit 130' INT
trap 'fm_card_link_test_cleanup; exit 143' TERM

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
  || fail "could not allocate a free port"
export FM_DASHBOARD_HOST=127.0.0.1
export FM_DASHBOARD_PORT="$PORT"
FM_HOME="$DASHBOARD_HOME" "$DASH" start >"$DASHBOARD_HOME/start.out" 2>&1 || {
  cat "$DASHBOARD_HOME/start.out" >&2
  fail "dashboard server did not start"
}
SERVER_PID=$(cat "$DASHBOARD_HOME/state/dashboard.pid" 2>/dev/null)
[ -n "$SERVER_PID" ] || fail "no pid recorded after dashboard start"

card_status() {  # <card-id>
  "$DASH" show "$1" --json 2>/dev/null | jq -r '.status // empty'
}
card_field() {  # <card-id> <field>
  "$DASH" show "$1" --json 2>/dev/null | jq -r --arg f "$2" '.[$f] // empty'
}
add_card() {  # <title> [--status <status>]
  "$DASH" add --title "$1" --captain firstmate --prompt "coverage prompt" "${@:2}" | awk '{print $1}'
}

# --- spawn-side fake tmux/treehouse (adapted from fm-spawn-worktree-settle.test.sh) ---

make_spawn_fakebin() {
  local dir=$1 fakebin wt=$2
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
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

# make_spawn_case <name> <id> - a home, a project with a real worktree, and a
# fake tmux that already reports the settled worktree path (no staleness to
# simulate here; that is fm-spawn-worktree-settle.test.sh's own concern).
# Echoes "<home>|<proj>|<wt>|<fakebin>".
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/data/$id"
  # Pin the crew harness. Without config/crew-harness, bin/fm-spawn.sh resolves
  # the harness from bin/fm-harness.sh's OWN-process detection, so the fixture
  # would inherit whatever harness happens to run the suite: a developer running
  # it under Claude Code gets claude and spawns fine, while a bare CI runner
  # detects `unknown`, finds no launch template, and fails every spawn here.
  # codex matches tests/fm-spawn-worktree-settle.test.sh and needs no executable
  # on PATH (its launch template is only typed into the fake pane).
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$wt")
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn() {  # <home> <proj> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 fakebin=$3 id=$4; shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off "$@" 2>&1
}

test_spawn_links_card_and_advances_not_started_to_working() {
  local rec home proj wt fakebin id card home_name out
  id=spawn-link-a1
  rec=$(make_spawn_case spawn-link "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=$(add_card "Spawn-link coverage")
  [ -n "$card" ] || fail "add_card returned no id"

  out=$(run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn with --card should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "dashboard: linked card $card" "spawn did not report the dashboard link firing"
  assert_grep "dashboard_card=$card" "$home/state/$id.meta" "meta did not record dashboard_card="

  home_name=$(basename "$home")
  [ "$(card_field "$card" backlog_ref)" = "$home_name:$id" ] \
    || fail "card ref was not set to $home_name:$id"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "card agent was not set to the task id"
  [ "$(card_status "$card")" = working ] || fail "not_started card did not advance to working at spawn"
  pass "spawn --card links a not_started card's ref/agent and advances it to working"
}

test_spawn_without_card_flag_never_touches_the_dashboard() {
  local rec home proj wt fakebin id out
  id=spawn-nocard-a2
  rec=$(make_spawn_case spawn-nocard "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  out=$(run_spawn "$home" "$proj" "$fakebin" "$id")
  expect_code 0 "$?" "spawn without --card should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "dashboard:" "a card-less spawn printed a dashboard line"
  assert_no_grep "dashboard_card=" "$home/state/$id.meta" "meta recorded dashboard_card= with no --card given"
  pass "spawn without --card is a complete dashboard no-op (the normal case)"
}

test_spawn_with_unreachable_dashboard_still_succeeds_and_warns() {
  local rec home proj wt fakebin id card out
  id=spawn-unreach-a3
  rec=$(make_spawn_case spawn-unreach "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=some-card-id

  out=$(FM_DASHBOARD_PORT=1 run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn must not fail just because the dashboard is unreachable"
  assert_contains "$out" "spawned $id" "spawn did not report success despite the unreachable dashboard"
  assert_contains "$out" "warning: dashboard card link failed" "spawn did not warn about the failed link"
  assert_grep "dashboard_card=$card" "$home/state/$id.meta" \
    "meta should still record the requested card id even when the link call failed"
  pass "spawn --card never fails the spawn when the dashboard is unreachable, but warns loudly"
}

test_spawn_with_unknown_card_id_warns_and_records_a_fleet_finding() {
  local rec home proj wt fakebin id card out status_json
  id=spawn-unknown-a4
  rec=$(make_spawn_case spawn-unknown "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=does-not-exist-zzzz

  out=$(run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn must not fail just because --card names an unknown card"
  assert_contains "$out" "spawned $id" "spawn did not report success for an unknown card id"
  assert_contains "$out" "warning: dashboard card link failed" "spawn did not warn about the unknown card"

  status_json=$("$DASH" audit-status --json)
  assert_contains "$status_json" "$id" "a failed link for an unknown card id was not recorded to the fleet audit log"
  assert_contains "$status_json" "$card" "the fleet audit log finding did not name the unresolved card"
  pass "spawn --card with an unknown card id warns and leaves a fleet-visible finding, not a silent drop"
}

# --- teardown-side fake project/worktree (adapted from tests/fm-teardown.test.sh) ---

make_teardown_case() {
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

land_teardown_case() {  # <case_dir> <id> - commit on the worktree branch, then
  # fast-forward local main to it so the landed-work check passes with no PR.
  local case_dir=$1 id=$2 wt_head
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "land $id"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
}

run_teardown_case() {  # <case_dir> <id> [extra args...]
  local case_dir=$1 id=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

test_teardown_advances_linked_card_to_testing_on_landed_work() {
  local id case_dir card out home_name
  id=teardown-link-b1
  card=$(add_card "Teardown-link coverage" --status working)
  case_dir=$(make_teardown_case teardown-link "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed local-only teardown should succeed"
  assert_contains "$out" "teardown $id complete" "teardown did not report completion"
  assert_contains "$out" "dashboard: advanced card $card to testing" "teardown did not report the dashboard advance firing"
  [ "$(card_status "$card")" = testing ] || fail "linked card did not advance to testing on landed teardown"
  pass "teardown advances a linked card to testing once landed cleanup actually succeeds"
}

test_teardown_without_dashboard_card_meta_is_a_noop() {
  local id case_dir out
  id=teardown-nocard-b2
  case_dir=$(make_teardown_case teardown-nocard "$id")
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed teardown with no linked card should still succeed"
  assert_not_contains "$out" "dashboard:" "a card-less teardown printed a dashboard line"
  pass "teardown with no dashboard_card= recorded is a complete dashboard no-op"
}

test_teardown_force_discard_never_advances_the_card() {
  local id case_dir card out
  id=teardown-force-b3
  card=$(add_card "Force-discard coverage" --status working)
  case_dir=$(make_teardown_case teardown-force "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  # Truly unpushed, not landed - only --force can tear this down, and a forced
  # discard must never be read as a landing.
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unlanded work"

  out=$(run_teardown_case "$case_dir" "$id" --force)
  expect_code 0 "$?" "forced teardown of unlanded work should still succeed"
  assert_not_contains "$out" "dashboard:" "a --force teardown reported advancing the card"
  [ "$(card_status "$card")" = working ] || fail "a --force (discard) teardown must never advance the linked card"
  pass "teardown --force never advances the linked card, since a forced discard is not a landing"
}

test_teardown_never_downgrades_an_already_complete_card() {
  local id case_dir card out
  id=teardown-complete-b4
  card=$(add_card "Already-approved coverage" --status working)
  "$DASH" status "$card" testing >/dev/null || fail "setup: could not move card to testing"
  "$DASH" status "$card" complete >/dev/null || fail "setup: could not move card to complete"
  case_dir=$(make_teardown_case teardown-complete "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed teardown should succeed"
  assert_not_contains "$out" "dashboard:" "teardown reported advancing an already-complete card"
  [ "$(card_status "$card")" = complete ] || fail "an already-complete card must never be downgraded back to testing"
  pass "teardown never downgrades a card the Admiral already marked complete"
}

test_teardown_with_unreachable_dashboard_still_succeeds_and_warns() {
  local id case_dir card out
  id=teardown-unreach-b5
  card=some-card-id
  case_dir=$(make_teardown_case teardown-unreach "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(FM_DASHBOARD_PORT=1 run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "teardown must not fail just because the dashboard is unreachable"
  assert_contains "$out" "teardown $id complete" "teardown did not report completion despite the unreachable dashboard"
  assert_contains "$out" "warning: dashboard card advance failed" "teardown did not warn about the failed advance"
  pass "teardown --card advance never fails the teardown when the dashboard is unreachable, but warns loudly"
}

test_spawn_links_card_and_advances_not_started_to_working
test_spawn_without_card_flag_never_touches_the_dashboard
test_spawn_with_unreachable_dashboard_still_succeeds_and_warns
test_spawn_with_unknown_card_id_warns_and_records_a_fleet_finding
test_teardown_advances_linked_card_to_testing_on_landed_work
test_teardown_with_unreachable_dashboard_still_succeeds_and_warns
test_teardown_without_dashboard_card_meta_is_a_noop
test_teardown_force_discard_never_advances_the_card
test_teardown_never_downgrades_an_already_complete_card

echo "# all fm-dashboard-card-link tests passed"
