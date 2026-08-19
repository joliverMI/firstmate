#!/usr/bin/env bash
# tests/fm-dashboard-card-link.test.sh - end-to-end coverage for the mechanical
# link between a task and its Admiral's Fleet Dashboard card (docs/dashboard.md
# "The mechanical card link"): bin/fm-spawn.sh's --card populates the card's
# ref/agent identity and advances a not_started card to working;
# bin/fm-teardown.sh consumes that identity from state/<id>.meta and advances
# the card to testing once cleanup actually succeeds; bin/fm-backlog-handoff.sh's
# --card gives a handed-off backlog item the same link, recorded as a
# `dashboard_card:` body line on the item itself since a handed-off item has no
# local task metadata to hold it. All three scripts and a real dashboard server
# are driven only through their public CLIs.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "skipped - jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { pass "skipped - tasks-axi not available (required by the handoff card-link coverage)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"
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
  local worker_pid i
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  # The remote-route coverage below stages jobs through a detached remote job
  # worker; wait for it to actually exit so it cannot still be writing into
  # $TMP_ROOT while fm_test_cleanup removes it.
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid" 2>/dev/null || true)
    if [ -n "$worker_pid" ]; then
      kill "$worker_pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 500 ] && kill -0 "$worker_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
    fi
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

# --- handoff-side coverage (bin/fm-backlog-handoff.sh --card) ---------------
# A handed-off item has no local task metadata to hold dashboard_card= the
# way state/<id>.meta does, so the durable link instead lives as a
# `dashboard_card: <card-id>` body line on the item itself, carried into the
# secondmate's own backlog by the same move.

setup_handoff_homes() {  # <main-home> <secondmate-home> [<secondmate-id>]
  local home=$1 sub=$2 id=${3:-design} sub_abs
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$sub" "$id"
  sub_abs=$(cd "$sub" && pwd -P)
  printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
    "$id" "$sub_abs" > "$home/data/secondmates.md"
}

test_handoff_links_card_and_advances_not_started_to_working() {
  local home sub id card out
  home="$TMP_ROOT/handoff-link-main"
  sub="$TMP_ROOT/handoff-link-sub"
  id=handoff-link-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a1 - fix the thing (repo: alpha)

## Done
EOF
  card=$(add_card "Handoff-link coverage")
  [ -n "$card" ] || fail "add_card returned no id"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff with --card should succeed"
  assert_contains "$out" "handed off 1 item(s)" "handoff did not report success"
  assert_contains "$out" "dashboard: linked card $card" "handoff did not report the dashboard link firing"
  assert_grep "dashboard_card: $card" "$sub/data/backlog.md" \
    "secondmate backlog did not record dashboard_card: on the handed-off item"

  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-a1" ] \
    || fail "card ref was not set to $id:handoff-item-a1"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "card agent was not set to the secondmate id"
  [ "$(card_status "$card")" = working ] || fail "not_started card did not advance to working at handoff"
  pass "handoff --card links a not_started card's ref/agent and advances it to working"
}

test_handoff_without_card_flag_never_touches_the_dashboard() {
  local home sub id out
  home="$TMP_ROOT/handoff-nocard-main"
  sub="$TMP_ROOT/handoff-nocard-sub"
  id=handoff-nocard-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a2 - unrelated queued work (repo: alpha)

## Done
EOF

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a2 2>&1)
  expect_code 0 "$?" "handoff without --card should succeed"
  assert_contains "$out" "handed off 1 item(s)" "handoff did not report success"
  assert_not_contains "$out" "dashboard:" "a card-less handoff printed a dashboard line"
  assert_no_grep "dashboard_card:" "$sub/data/backlog.md" \
    "secondmate backlog recorded dashboard_card: with no --card given"
  pass "handoff without --card is a complete dashboard no-op (the normal case)"
}

test_handoff_with_unreachable_dashboard_still_succeeds_and_warns() {
  local home sub id card out
  home="$TMP_ROOT/handoff-unreach-main"
  sub="$TMP_ROOT/handoff-unreach-sub"
  id=handoff-unreach-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a3 - fix the other thing (repo: alpha)

## Done
EOF
  card=some-card-id

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a3 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable"
  assert_contains "$out" "handed off 1 item(s)" "handoff did not report success despite the unreachable dashboard"
  assert_contains "$out" "warning: dashboard card link failed" "handoff did not warn about the failed link"
  assert_grep "dashboard_card: $card" "$sub/data/backlog.md" \
    "secondmate backlog should still record the requested card id even when the link call failed"
  pass "handoff --card never fails the handoff when the dashboard is unreachable, but warns loudly"
}

test_handoff_refuses_card_with_more_than_one_item() {
  local home sub id out rc
  home="$TMP_ROOT/handoff-multi-main"
  sub="$TMP_ROOT/handoff-multi-sub"
  id=handoff-multi-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-m1 - first (repo: alpha)
- [ ] handoff-item-m2 - second (repo: alpha)

## Done
EOF

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-m1 handoff-item-m2 --card some-card 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a multi-item --card handoff should be refused"
  assert_contains "$out" "--card applies only to a single-item handoff" "the refusal did not name the single-item rule"
  assert_grep 'handoff-item-m1' "$home/data/backlog.md" "the refused handoff moved handoff-item-m1 anyway"
  assert_grep 'handoff-item-m2' "$home/data/backlog.md" "the refused handoff moved handoff-item-m2 anyway"
  pass "handoff refuses --card with more than one item and moves nothing"
}

# Regression: a handoff is documented as idempotent, so the same command is
# expected to be re-run. By then the secondmate may already have spawned
# against the card, replacing the coarse handoff identity with a precise
# per-task one - re-running must not reset the board to the stale identity.
test_handoff_already_present_never_overwrites_an_existing_card_link() {
  local home sub id card out
  home="$TMP_ROOT/handoff-relink-main"
  sub="$TMP_ROOT/handoff-relink-sub"
  id=handoff-relink-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a4 - already landed here (repo: alpha)

## Done
EOF
  card=$(add_card "Already-linked coverage")
  # Exactly what the secondmate's own fm-spawn.sh --card writes once it picks
  # the item up: a precise <home>:<task-id> ref and the task id as agent.
  "$DASH" ref "$card" "sm-home:task-99" >/dev/null || fail "setup: could not set the card ref"
  "$DASH" agent "$card" task-99 >/dev/null || fail "setup: could not set the card agent"
  "$DASH" status "$card" working >/dev/null || fail "setup: could not move the card to working"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a4 --card "$card" 2>&1)
  expect_code 0 "$?" "re-running an already-landed handoff should still succeed"
  assert_contains "$out" "nothing to move" "the re-run did not report the idempotent no-op"
  assert_contains "$out" "already links to sm-home:task-99" "the re-run did not report leaving the existing link alone"
  assert_not_contains "$out" "dashboard: linked card" "the re-run claimed it linked a card that was already linked"

  [ "$(card_field "$card" backlog_ref)" = "sm-home:task-99" ] \
    || fail "a handoff re-run overwrote a newer, more precise card ref"
  [ "$(card_field "$card" agent)" = task-99 ] \
    || fail "a handoff re-run overwrote a newer, more precise card agent"
  assert_grep "dashboard_card: $card" "$sub/data/backlog.md" \
    "the re-run should still record the item's durable card identity"
  pass "a handoff re-run never overwrites a card link something more precise already claimed"
}

# Regression: the `dashboard_card:` body line is the item's SINGLE durable card
# identity, so a corrected card id must replace the old one. Two lines on one
# item would make the outbox-resume path link both cards to the same item.
test_handoff_card_annotation_replaces_a_stale_card_id() {
  local home sub id card out count
  home="$TMP_ROOT/handoff-recard-main"
  sub="$TMP_ROOT/handoff-recard-sub"
  id=handoff-recard-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a5 - carries a stale card id (repo: alpha)
  intent: keep this body line
  dashboard_card: stale-card-id

## Done
EOF
  card=$(add_card "Re-carded coverage")

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a5 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff onto a corrected card should succeed"
  assert_contains "$out" "dashboard: linked card $card" "the corrected card was not linked"
  assert_grep "dashboard_card: $card" "$sub/data/backlog.md" "the corrected card id was not recorded"
  assert_no_grep "dashboard_card: stale-card-id" "$sub/data/backlog.md" \
    "the stale card id survived beside the corrected one"
  assert_grep "intent: keep this body line" "$sub/data/backlog.md" \
    "rewriting the card line dropped the rest of the item body"
  count=$(grep -c 'dashboard_card:' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "item carries $count dashboard_card lines; exactly one is the durable identity"
  pass "a corrected --card replaces the item's stale dashboard_card line rather than appending beside it"
}

# Regression: recording the card id REPLACES the item's whole body through
# `tasks-axi update --body-file`, so anything the reader failed to see is
# written away unrecoverably. A whitespace-only line (a lone space, a tab) is a
# blank body line to tasks-axi, and nothing refuses it on the way in - it is an
# ordinary editor artifact, not malformed input. It reaches the rewrite on the
# already-present path, whose file no tasks-axi move has just normalized and
# which no pre-move canonical check ever validated.
test_handoff_card_annotation_keeps_a_body_split_by_a_whitespace_only_line() {
  local home sub id card out
  home="$TMP_ROOT/handoff-wsbody-main"
  sub="$TMP_ROOT/handoff-wsbody-sub"
  id=handoff-wsbody-sm
  setup_handoff_homes "$home" "$sub" "$id"
  printf '## Queued\n\n## Done\n' > "$home/data/backlog.md"
  {
    printf '## Queued\n'
    printf -- '- [ ] handoff-item-a6 - body split by stray whitespace (repo: alpha)\n'
    printf '  intent: first body line\n'
    printf ' \n'
    printf '  more: important detail\n'
    printf '\t\n'
    printf '  owner: someone\n'
    printf '\n## Done\n'
  } > "$sub/data/backlog.md"
  card=$(add_card "Whitespace-split body coverage")

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a6 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff of an item whose body has a whitespace-only line should succeed"
  assert_grep "dashboard_card: $card" "$sub/data/backlog.md" "the card id was not recorded on the item"
  assert_grep "intent: first body line" "$sub/data/backlog.md" "annotation lost the first body line"
  assert_grep "more: important detail" "$sub/data/backlog.md" \
    "annotation truncated the body at a whitespace-only line"
  assert_grep "owner: someone" "$sub/data/backlog.md" \
    "annotation truncated the body at a whitespace-only line"
  pass "recording a card id never truncates a body that a whitespace-only line splits"
}

# Regression: the already-present path annotates the SECONDMATE's backlog,
# which no pre-move canonical check ever validated, so a tab-indented
# continuation line reaches the rewrite there. tasks-axi does not read such a
# line as body, so it must be left exactly where it is rather than written away.
test_handoff_already_present_annotation_keeps_a_noncanonical_body() {
  local home sub id card out
  home="$TMP_ROOT/handoff-tabbody-main"
  sub="$TMP_ROOT/handoff-tabbody-sub"
  id=handoff-tabbody-sm
  setup_handoff_homes "$home" "$sub" "$id"
  printf '## Queued\n\n## Done\n' > "$home/data/backlog.md"
  {
    printf '## Queued\n'
    printf -- '- [ ] handoff-item-a7 - already landed with a tab body (repo: alpha)\n'
    printf '  intent: canonical line\n'
    printf '\tmore: tab indented detail\n'
    printf '  owner: someone\n'
    printf '\n## Done\n'
  } > "$sub/data/backlog.md"
  card=$(add_card "Tab-indented body coverage")

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a7 --card "$card" 2>&1)
  expect_code 0 "$?" "an already-present handoff should still succeed"
  assert_contains "$out" "nothing to move" "the re-run did not report the idempotent no-op"
  assert_grep "intent: canonical line" "$sub/data/backlog.md" "annotation lost the canonical body line"
  assert_grep "more: tab indented detail" "$sub/data/backlog.md" \
    "annotation wrote away the tab-indented continuation line"
  assert_grep "owner: someone" "$sub/data/backlog.md" \
    "annotation wrote away body content following a tab-indented line"
  pass "annotating an already-present item never writes away a non-canonical continuation line"
}

# --- remote-route handoff coverage ------------------------------------------
# A remote handoff stages the item into data/handoff/<id>.outbox.md, annotates
# the card id onto the staged item there, and links the card only once delivery
# is confirmed. A crash in between leaves the annotated outbox as the sole
# record of which card to link, which is what --resume-pending reads back.
# Both paths run through the same fake-ssh + real remote entrypoint shape
# tests/fm-remote-backlog-handoff.test.sh uses.

REMOTE_SM='remote-card-sm'
REMOTE_PARENT="$TMP_ROOT/remote-parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_SM_HOME="$TMP_ROOT/remote-home"
REMOTE_FAKEBIN=

setup_remote_route() {
  mkdir -p "$REMOTE_PARENT/data" "$REMOTE_PARENT/state" "$REMOTE_ROOT/bin" \
    "$REMOTE_SM_HOME/data" "$REMOTE_SM_HOME/state" "$REMOTE_SM_HOME/config" "$REMOTE_SM_HOME/bin"
  REMOTE_FAKEBIN=$(fm_fakebin "$TMP_ROOT/remote-fake")
  printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
  cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
    "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-file.sh" \
    "$ROOT/bin/fm-backlog-receive.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$REMOTE_ROOT/bin/"
  ln -s "$(command -v tasks-axi)" "$REMOTE_ROOT/bin/tasks-axi"
  ln -s "$(command -v node)" "$REMOTE_ROOT/bin/node"
  chmod +x "$REMOTE_ROOT/bin"/*.sh
  git -C "$REMOTE_ROOT" init -q -b main
  git -C "$REMOTE_ROOT" add AGENTS.md bin
  git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'
  printf 'fixture\n' > "$REMOTE_SM_HOME/AGENTS.md"
  printf '%s\n' "$REMOTE_SM" > "$REMOTE_SM_HOME/.fm-secondmate-home"
  printf -- '- %s - remote delivery (host: remote-mac; root: %s; home: %s; scope: remote work; projects: alpha; added 2026-08-02)\n' \
    "$REMOTE_SM" "$REMOTE_ROOT" "$REMOTE_SM_HOME" > "$REMOTE_PARENT/data/secondmates.md"
  cat > "$REMOTE_FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
[ "${FM_FAKE_SSH_MODE:-normal}" != unreachable ] || exit 255
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
  chmod +x "$REMOTE_FAKEBIN/fake-ssh"
}

write_remote_parent_backlog() {  # <queued-line>
  cat > "$REMOTE_PARENT/data/backlog.md" <<EOF
## In flight

## Queued
$1

## Done
EOF
}

run_remote_handoff() {  # <handoff args...>
  FM_HOME="$REMOTE_PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_SSH_BIN="$REMOTE_FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
    "$HANDOFF" "$@" 2>&1
}

test_remote_handoff_links_card_only_after_confirmed_delivery() {
  local card out
  card=$(add_card "Remote handoff coverage")
  write_remote_parent_backlog '- [ ] remote-item-r1 - remote card work (repo: alpha)'

  out=$(run_remote_handoff "$REMOTE_SM" remote-item-r1 --card "$card")
  expect_code 0 "$?" "remote handoff with --card should succeed"
  assert_contains "$out" "handed off 1 item(s) to remote secondmate $REMOTE_SM" "remote handoff did not report success"
  assert_contains "$out" "dashboard: linked card $card" "remote handoff did not report the dashboard link firing"
  assert_absent "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "confirmed remote delivery left a pending outbox"
  assert_grep 'remote-item-r1' "$REMOTE_SM_HOME/data/backlog.md" "remote delivery lost the item"
  assert_grep "dashboard_card: $card" "$REMOTE_SM_HOME/data/backlog.md" \
    "the card id did not travel with the item through the outbox transfer"

  [ "$(card_field "$card" backlog_ref)" = "$REMOTE_SM:remote-item-r1" ] \
    || fail "remote card ref was not set to $REMOTE_SM:remote-item-r1"
  [ "$(card_field "$card" agent)" = "$REMOTE_SM" ] || fail "remote card agent was not set to the secondmate id"
  [ "$(card_status "$card")" = working ] || fail "not_started card did not advance to working after confirmed remote delivery"
  pass "a remote handoff links the card once delivery is confirmed, carrying the card id through the outbox"
}

test_resume_pending_links_the_card_recorded_in_the_staged_outbox() {
  local card out rc outbox
  card=$(add_card "Remote resume coverage")
  outbox="$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md"
  write_remote_parent_backlog '- [ ] remote-item-r2 - survives an unreachable secondmate (repo: alpha)'

  out=$(FM_FAKE_SSH_MODE=unreachable run_remote_handoff "$REMOTE_SM" remote-item-r2 --card "$card") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "handoff to an unreachable remote claimed success"
  assert_present "$outbox" "the unreachable handoff lost its durable outbox"
  assert_grep "dashboard_card: $card" "$outbox" "the staged outbox did not record which card to link on recovery"
  [ -z "$(card_field "$card" backlog_ref)" ] || fail "the card was linked before delivery was ever confirmed"
  [ "$(card_status "$card")" = not_started ] || fail "the card advanced before delivery was ever confirmed"

  # --resume-pending takes no keys and no --card: the annotated outbox is the
  # only surviving record of which card this delivery serves.
  out=$(run_remote_handoff --resume-pending)
  expect_code 0 "$?" "resuming the pending outbox should succeed"
  assert_absent "$outbox" "confirmed resume did not clean the local outbox"
  assert_grep 'remote-item-r2' "$REMOTE_SM_HOME/data/backlog.md" "resume did not deliver the item"

  [ "$(card_field "$card" backlog_ref)" = "$REMOTE_SM:remote-item-r2" ] \
    || fail "resume did not link the card recorded in the staged outbox"
  [ "$(card_field "$card" agent)" = "$REMOTE_SM" ] || fail "resume did not set the card agent"
  [ "$(card_status "$card")" = working ] || fail "resume did not advance the not_started card to working"
  pass "a crash-recovered outbox links its card from the annotated item alone, with no --card on the command line"
}

# stage_unreachable_card_item <key> <card-id> - leave one annotated item in the
# pending outbox by handing it off to an unreachable remote, the state a failed
# delivery genuinely leaves behind.
stage_unreachable_card_item() {
  local key=$1 card=$2 rc
  write_remote_parent_backlog "- [ ] $key - staged before the remote came back (repo: alpha)"
  FM_FAKE_SSH_MODE=unreachable run_remote_handoff "$REMOTE_SM" "$key" --card "$card" >/dev/null && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "handoff to an unreachable remote claimed success"
  assert_grep "dashboard_card: $card" "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" \
    "the unreachable handoff did not stage its card annotation"
}

# Regression: an outbox is transferred and deleted as a WHOLE, so a later
# handoff lands every item an earlier failed run left staged. Linking only the
# key this command line named orphans those cards permanently - the deleted
# outbox was the only record of them - which is the freeze-at-not-started bug
# this whole mechanism exists to prevent.
test_remote_handoff_links_every_card_its_delivery_lands() {
  local stranded fresh out
  stranded=$(add_card "Stranded co-staged coverage")
  fresh=$(add_card "Fresh remote coverage")
  stage_unreachable_card_item remote-item-r3 "$stranded"

  write_remote_parent_backlog '- [ ] remote-item-r4 - handed off once the remote is back (repo: alpha)'
  out=$(run_remote_handoff "$REMOTE_SM" remote-item-r4 --card "$fresh")
  expect_code 0 "$?" "the later handoff should succeed"
  assert_absent "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "confirmed delivery left a pending outbox"
  assert_grep 'remote-item-r3' "$REMOTE_SM_HOME/data/backlog.md" "the co-staged item was not delivered"
  assert_grep 'remote-item-r4' "$REMOTE_SM_HOME/data/backlog.md" "the newly staged item was not delivered"

  [ "$(card_field "$fresh" backlog_ref)" = "$REMOTE_SM:remote-item-r4" ] \
    || fail "the card this run named was not linked"
  [ "$(card_field "$stranded" backlog_ref)" = "$REMOTE_SM:remote-item-r3" ] \
    || fail "a co-staged card the same delivery landed was left orphaned at not_started"
  [ "$(card_field "$stranded" agent)" = "$REMOTE_SM" ] || fail "the co-staged card's agent was not set"
  [ "$(card_status "$stranded")" = working ] || fail "the co-staged card never advanced to working"
  pass "a remote handoff links every card its delivery landed, not only the one it was asked about"
}

# The same boundary reached with no --card at all: the run stages nothing on
# the board of its own, it only completes a link an earlier --card call staged
# and would otherwise destroy by deleting the delivered outbox.
test_card_less_remote_handoff_completes_a_link_its_delivery_lands() {
  local stranded out
  stranded=$(add_card "Card-less flush coverage")
  stage_unreachable_card_item remote-item-r5 "$stranded"

  write_remote_parent_backlog '- [ ] remote-item-r6 - ordinary card-less handoff (repo: alpha)'
  out=$(run_remote_handoff "$REMOTE_SM" remote-item-r6)
  expect_code 0 "$?" "the card-less handoff should succeed"
  assert_grep 'remote-item-r5' "$REMOTE_SM_HOME/data/backlog.md" "the co-staged item was not delivered"
  assert_grep 'remote-item-r6' "$REMOTE_SM_HOME/data/backlog.md" "the card-less item was not delivered"

  [ "$(card_field "$stranded" backlog_ref)" = "$REMOTE_SM:remote-item-r5" ] \
    || fail "a card-less handoff dropped the link its own delivery made recoverable-never-again"
  [ "$(card_status "$stranded")" = working ] || fail "the co-staged card never advanced to working"
  pass "a card-less remote handoff still completes a link an earlier --card call staged"
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
test_handoff_links_card_and_advances_not_started_to_working
test_handoff_without_card_flag_never_touches_the_dashboard
test_handoff_with_unreachable_dashboard_still_succeeds_and_warns
test_handoff_refuses_card_with_more_than_one_item
test_handoff_already_present_never_overwrites_an_existing_card_link
test_handoff_card_annotation_replaces_a_stale_card_id
test_handoff_card_annotation_keeps_a_body_split_by_a_whitespace_only_line
test_handoff_already_present_annotation_keeps_a_noncanonical_body
if command -v node >/dev/null 2>&1; then
  setup_remote_route
  test_remote_handoff_links_card_only_after_confirmed_delivery
  test_resume_pending_links_the_card_recorded_in_the_staged_outbox
  test_remote_handoff_links_every_card_its_delivery_lands
  test_card_less_remote_handoff_completes_a_link_its_delivery_lands
else
  pass "skipped remote-route card coverage - node not available for the remote fixture"
fi

echo "# all fm-dashboard-card-link tests passed"
