#!/usr/bin/env bash
# tests/fm-dashboard.test.sh - end-to-end coverage for the Admiral's Fleet
# Dashboard: a real server process, driven only through bin/fm-dashboard.sh
# and the HTTP API it wraps, exactly the way an agent or the fleet auditor
# would use it. No test here asserts on implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "skipped - jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

DASH="$ROOT/bin/fm-dashboard.sh"
SERVER_PID=""

fm_dashboard_test_cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  fm_test_cleanup
}
trap fm_dashboard_test_cleanup EXIT
trap 'fm_dashboard_test_cleanup; exit 130' INT
trap 'fm_dashboard_test_cleanup; exit 143' TERM

FM_HOME=$(fm_test_tmproot fm-dashboard-test) || fail "could not create temp FM_HOME"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
export FM_HOME
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
  || fail "could not allocate a free port"
export FM_DASHBOARD_HOST=127.0.0.1
export FM_DASHBOARD_PORT="$PORT"

start_server() {
  "$DASH" start >"$FM_HOME/start.out" 2>&1 || {
    cat "$FM_HOME/start.out" >&2
    fail "server did not start"
  }
  SERVER_PID=$(cat "$FM_HOME/state/dashboard.pid" 2>/dev/null)
  [ -n "$SERVER_PID" ] || fail "no pid recorded after start"
}

start_server

test_health_and_server_status() {
  "$DASH" server-status | assert_grep "api:     reachable" -
  pass "server-status reports the running, reachable server"
}

test_add_and_list_round_trip() {
  local id row
  row=$("$DASH" add --title "Ship the board" --captain dj --prompt "His own words, verbatim." --agent "crew-1") \
    || fail "add failed: $row"
  id=$(printf '%s' "$row" | awk '{print $1}')
  [ -n "$id" ] || fail "add did not return a task id"

  assert_contains "$("$DASH" list)" "$id" "list did not include the newly added task"
  assert_contains "$("$DASH" show "$id")" "His own words, verbatim." "show did not return the verbatim prompt"
  echo "$id" > "$FM_HOME/task-id"
  pass "add/list/show round-trip works through the CLI"
}

test_status_and_captain_and_title_updates() {
  local id
  id=$(cat "$FM_HOME/task-id")

  "$DASH" status "$id" working >/dev/null || fail "status transition to working failed"
  assert_contains "$("$DASH" show "$id")" "status:   working" "status did not persist"

  "$DASH" title "$id" "Ship the board (renamed)" >/dev/null || fail "title update failed"
  assert_contains "$("$DASH" show "$id")" "Ship the board (renamed)" "title did not persist"

  "$DASH" captain "$id" river >/dev/null || fail "captain update failed"
  assert_contains "$("$DASH" show "$id")" "captain:  captain_river" "captain did not persist"

  pass "status, title, and captain updates persist through the CLI"
}

test_waiting_status_carries_target_and_reason() {
  local id waiter
  id=$(cat "$FM_HOME/task-id")
  waiter=$("$DASH" add --title "Blocked on the board" --captain firstmate --prompt "waits on the other card" | awk '{print $1}')
  [ -n "$waiter" ] || fail "second add failed"

  "$DASH" status "$waiter" waiting --waiting-on "$id" --reason "needs it merged first" >/dev/null \
    || fail "waiting status with target failed"
  local out
  out=$("$DASH" show "$waiter")
  assert_contains "$out" "waiting on: $id" "waiting-on target did not persist"
  assert_contains "$out" "needs it merged first" "waiting reason did not persist"
  pass "waiting status carries its target card and reason"
}

test_star_and_delete() {
  local id
  id=$(cat "$FM_HOME/task-id")
  "$DASH" star "$id" >/dev/null || fail "star failed"
  assert_contains "$("$DASH" show "$id")" "starred:  true" "star did not persist"

  if "$DASH" delete "$id" 2>/dev/null; then
    fail "delete without --confirm should have been refused"
  fi

  "$DASH" delete "$id" --confirm >/dev/null || fail "confirmed delete failed"
  if "$DASH" show "$id" >/dev/null 2>&1; then
    fail "deleted task is still readable"
  fi
  pass "starring persists and delete requires --confirm"
}

test_notes_tabs_and_empty_tab_semantics() {
  local id out
  id=$("$DASH" add --title "Notes coverage" --captain firstmate --prompt "checking tabs" | awk '{print $1}')

  out=$("$DASH" show "$id")
  assert_not_contains "$out" "--- interpretation ---" "a fresh task must not show a forced interpretation section"

  "$DASH" note "$id" --tab interpretation --author agent --text "a genuine reading" >/dev/null \
    || fail "note add failed"
  out=$("$DASH" show "$id")
  assert_contains "$out" "a genuine reading" "interpretation note did not appear"

  pass "interpretation tab stays absent until something real is recorded"
}

test_link_policy_rejects_github_and_localhost() {
  local id out rc
  id=$("$DASH" add --title "Link policy coverage" --captain firstmate --prompt "checking links" | awk '{print $1}')

  out=$("$DASH" link "$id" --url "https://github.com/kunchenguid/firstmate/pull/1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a GitHub link was accepted"
  assert_contains "$out" "standing order 17" "GitHub rejection did not cite standing order 17"

  out=$("$DASH" link "$id" --url "http://127.0.0.1:9/thing" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a local-only link was accepted"

  "$DASH" link "$id" --url "https://example.com/review/42" --label "Preview" >/dev/null \
    || fail "a legitimate phone-openable link was rejected"
  assert_contains "$("$DASH" show "$id")" "example.com/review/42" "accepted link did not persist"
  pass "link policy rejects GitHub/PR and local-only links, accepts a real one"
}

test_audit_log_run_and_interval() {
  "$DASH" audit-log --fleet "seeded discrepancy for coverage" --kind discrepancy >/dev/null \
    || fail "fleet-wide audit-log failed"
  "$DASH" audit-run --duration-seconds 1.5 --checked 3 --discrepancies 1 >/dev/null \
    || fail "audit-run failed"

  local status_json
  status_json=$(curl -sS "http://127.0.0.1:$PORT/api/audit/status")
  assert_contains "$status_json" "seeded discrepancy for coverage" "discrepancy log did not record the finding"
  assert_contains "$status_json" '"tasks_checked": 3' "audit run summary did not persist"

  assert_contains "$("$DASH" audit-interval get)" "every 15 minute(s)" "default audit interval is not 15 minutes"
  assert_contains "$("$DASH" audit-interval 5)" "every 5 minute(s)" "audit interval did not update"
  assert_contains "$("$DASH" audit-interval get)" "every 5 minute(s)" "audit interval change did not persist"
  pass "audit-log, audit-run, and audit-interval work end to end"
}

test_bad_input_fails_with_nonzero_exit() {
  if "$DASH" status nonexistent-id working >/dev/null 2>&1; then
    fail "status on a nonexistent task should have failed"
  fi

  if "$DASH" add --captain dj --prompt "missing title" >/dev/null 2>&1; then
    fail "add without --title should have failed"
  fi

  if "$DASH" captain "$(cat "$FM_HOME/task-id" 2>/dev/null || printf 'x')" nobody >/dev/null 2>&1; then
    fail "an unknown captain should have been refused"
  fi
  pass "invalid input fails loudly with a non-zero exit, not a silent success"
}

test_health_and_server_status
test_add_and_list_round_trip
test_status_and_captain_and_title_updates
test_waiting_status_carries_target_and_reason
test_notes_tabs_and_empty_tab_semantics
test_link_policy_rejects_github_and_localhost
test_audit_log_run_and_interval
test_bad_input_fails_with_nonzero_exit
test_star_and_delete
