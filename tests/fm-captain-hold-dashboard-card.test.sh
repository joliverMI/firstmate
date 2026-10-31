#!/usr/bin/env bash
# tests/fm-captain-hold-dashboard-card.test.sh - coverage for the mechanical
# link between a captain hold and its one Fleet Dashboard card
# (docs/captain-hold-lifecycle.md "Every captain hold carries exactly one board
# card"): fm-captain-hold.sh hold auto-creates or reuses a needs-action (or, with
# --card-plan, needs-review) card, re-holding the same task id never duplicates
# that card, a board the home cannot reach defers the link to a durable pending
# marker that resume-pending-cards later completes, card-task reverse-looks-up a
# card id to its held task, and --await-path arms (and answer retires) the
# deliverable re-test watch. Driven only through fm-captain-hold.sh's and
# fm-dashboard.sh's public CLIs, against a real, test-local dashboard server.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-dashboard-card)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

# --- one real, test-local dashboard server for the whole file --------------
# Same isolation contract as tests/fm-dashboard-card-link.test.sh: a
# dynamically allocated port plus exported FM_DASHBOARD_HOST/PORT so every
# subprocess this file or fm-captain-hold.sh itself spawns resolves to this
# server, never a real one, regardless of what FM_HOME it otherwise runs with.
DASHBOARD_HOME="$TMP_ROOT/dashboard-home"
mkdir -p "$DASHBOARD_HOME/state" "$DASHBOARD_HOME/data"
SERVER_PID=""

fm_dashboard_card_test_cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  fm_test_cleanup
}
trap fm_dashboard_card_test_cleanup EXIT
trap 'fm_dashboard_card_test_cleanup; exit 130' INT
trap 'fm_dashboard_card_test_cleanup; exit 143' TERM

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

i=0
until "$DASH" server-status 2>/dev/null | grep -qF 'api:     reachable'; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "dashboard server never became reachable within 10s of starting"
  kill -0 "$SERVER_PID" 2>/dev/null || fail "dashboard server process died while waiting for it to become reachable"
  sleep 0.1
done

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

card_json() {  # <card-id>
  "$DASH" show "$1" --json 2>/dev/null
}

test_hold_creates_a_needs_action_card_with_the_reason() {
  local home card_id card
  home=$(make_home needs-action-card)
  run_captain "$home" hold sample-route-call \
    --title "Choose the route" --reason "captain must choose north or south" --repo sample \
    >/dev/null || fail "could not create the captain-held task"

  assert_present "$home/state/sample-route-call.hold-card" "a captain hold left no card-link record"
  card_id=$(cat "$home/state/sample-route-call.hold-card")
  [ -n "$card_id" ] || fail "the card-link record was empty"
  card=$(card_json "$card_id") || fail "the auto-created card could not be read back"
  printf '%s' "$card" | jq -e '
    .status == "needs_action"
      and .title == "Choose the route"
      and (.needs_action_reason // "") == "captain must choose north or south"
  ' >/dev/null || fail "the auto-created card does not carry the hold's title/reason: $card"
  pass "a captain hold auto-creates a needs-action card carrying its reason"
}

test_card_plan_creates_a_needs_review_card() {
  local home card_id card
  home=$(make_home needs-review-card)
  run_captain "$home" hold sample-plan-call \
    --title "Approve the migration plan" --reason "captain review requested" --repo sample \
    --card-plan "Migrate in three stages, cut over on a Friday" \
    >/dev/null || fail "could not create the plan-carrying captain-held task"

  card_id=$(cat "$home/state/sample-plan-call.hold-card")
  card=$(card_json "$card_id") || fail "the plan-carrying card could not be read back"
  printf '%s' "$card" | jq -e '
    .status == "needs_review"
      and (.review_plan // "") == "Migrate in three stages, cut over on a Friday"
  ' >/dev/null || fail "--card-plan did not produce a needs-review card with that plan: $card"
  pass "--card-plan creates a needs-review card carrying the plan instead of a needs-action card"
}

test_rehold_reuses_the_linked_card_and_resyncs_the_reason() {
  local home card_id first_card_id card
  home=$(make_home reuse-card)
  run_captain "$home" hold sample-reuse-call \
    --title "Pick a vendor" --reason "captain must pick a vendor" --repo sample \
    >/dev/null || fail "could not create the vendor-choice captain-held task"
  first_card_id=$(cat "$home/state/sample-reuse-call.hold-card")

  run_captain "$home" hold sample-reuse-call --reason "captain must pick a vendor by Friday" \
    >/dev/null || fail "re-holding the same task id failed"
  card_id=$(cat "$home/state/sample-reuse-call.hold-card")
  [ "$card_id" = "$first_card_id" ] || fail "re-holding the same task id created a duplicate card"

  card=$(card_json "$card_id") || fail "the reused card could not be read back"
  printf '%s' "$card" | jq -e '(.needs_action_reason // "") == "captain must pick a vendor by Friday"' >/dev/null \
    || fail "re-holding did not re-sync the card's reason text: $card"
  pass "re-holding the same task id reuses its card and re-syncs the reason while it is still unresolved"
}

test_unreachable_board_defers_to_a_pending_marker_until_resumed() {
  local home pending
  home=$(make_home pending-card)
  FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT=1 \
    run_captain "$home" hold sample-offline-call \
      --title "Approve the rollback" --reason "captain approval needed to roll back" --repo sample \
      >/dev/null 2>"$home/offline-hold.err" \
    || fail "a captain hold must still succeed when the board is unreachable"

  assert_absent "$home/state/sample-offline-call.hold-card" \
    "an unreachable board must not leave a card-link record behind"
  pending="$home/state/sample-offline-call.hold-card-pending"
  assert_present "$pending" "an unreachable board must defer the card link to a pending marker"
  assert_grep "Approve the rollback" "$pending" "the pending marker lost the card's intended title"
  assert_grep "captain approval needed to roll back" "$pending" "the pending marker lost the card's intended reason"

  run_captain "$home" resume-pending-cards > "$home/resume.out" \
    || fail "resume-pending-cards failed once the board was reachable again"
  assert_grep "linked=1" "$home/resume.out" "resume-pending-cards did not report completing the deferred link"
  assert_present "$home/state/sample-offline-call.hold-card" \
    "resume-pending-cards did not leave a card-link record behind"
  assert_absent "$pending" "resume-pending-cards left its pending marker behind after linking"
  pass "an unreachable board defers the card link to a pending marker that resume-pending-cards later completes"
}

test_card_task_reverse_looks_up_the_held_task() {
  local home card_id found
  home=$(make_home reverse-lookup)
  run_captain "$home" hold sample-lookup-call \
    --title "Name the on-call rotation" --reason "captain must name the rotation" --repo sample \
    >/dev/null || fail "could not create the rotation-naming captain-held task"
  card_id=$(cat "$home/state/sample-lookup-call.hold-card")

  found=$(run_captain "$home" card-task "$card_id") \
    || fail "card-task could not resolve a card this home actually linked"
  [ "$found" = sample-lookup-call ] || fail "card-task resolved the wrong task id: $found"

  if run_captain "$home" card-task does-not-exist > "$home/missing-card.out" 2>&1; then
    fail "card-task resolved a card id this home never linked"
  fi
  pass "card-task reverse-looks-up a linked card id to its captain-held task, and only a linked one"
}

test_await_path_arms_and_answer_retires_the_deliverable_watch() {
  local home await_file watch_marker source
  home=$(make_home await-watch)
  await_file="$home/data/awaited-report.md"
  run_captain "$home" hold sample-await-call \
    --title "Review the awaited report" --reason "captain review once DJ's table lands" --repo sample \
    --await-path "$await_file" \
    >/dev/null || fail "could not create the deliverable-awaiting captain-held task"

  watch_marker="$home/state/sample-await-call.hold-await-source"
  assert_present "$watch_marker" "--await-path did not record an armed deliverable watch"
  source=$(cat "$watch_marker")
  [ "$source" = "captain-hold-await-sample-await-call" ] \
    || fail "the recorded watch source id does not match the expected naming: $source"

  printf 'Captain picked the report.\n' > "$home/decision.txt"
  run_captain "$home" answer sample-await-call --decision-file "$home/decision.txt" >/dev/null \
    || fail "could not answer the deliverable-awaiting captain-held task"
  assert_absent "$watch_marker" "answering the hold did not retire its armed deliverable watch"
  pass "--await-path arms a deliverable watch that answer retires once the hold is closed"
}

test_hold_creates_a_needs_action_card_with_the_reason
test_card_plan_creates_a_needs_review_card
test_rehold_reuses_the_linked_card_and_resyncs_the_reason
test_unreachable_board_defers_to_a_pending_marker_until_resumed
test_card_task_reverse_looks_up_the_held_task
test_await_path_arms_and_answer_retires_the_deliverable_watch
