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
MIGRATION_SERVER_PID=""
PORT_HOLDER_PID=""
RECYCLED_PID=""

# bin/fm-dashboard.sh starts the server with `nohup ... &` and exits, so the
# process is orphaned and never a child of this shell: `wait` on its pid returns
# immediately without waiting for anything. Poll until it is really gone, so a
# following `start` against the same FM_HOME cannot lose a race with
# cmd_server_start's "already running" guard on the not-yet-dead pid.
stop_dashboard_server() {  # <pid>
  local pid=$1 waited=0
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      kill -9 "$pid" 2>/dev/null
      sleep 0.2
      return 0
    fi
    sleep 0.05
  done
}

fm_dashboard_test_cleanup() {
  stop_dashboard_server "$SERVER_PID"
  stop_dashboard_server "$MIGRATION_SERVER_PID"
  [ -n "$PORT_HOLDER_PID" ] && kill "$PORT_HOLDER_PID" 2>/dev/null
  [ -n "$RECYCLED_PID" ] && kill "$RECYCLED_PID" 2>/dev/null
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

test_testing_and_review_are_distinct_statuses() {
  local id out
  id=$("$DASH" add --title "Split status coverage" --captain firstmate --prompt "checking testing/review" | awk '{print $1}')

  "$DASH" status "$id" testing >/dev/null || fail "status transition to testing failed"
  assert_contains "$("$DASH" show "$id")" "status:   testing" "testing status did not persist"
  assert_contains "$("$DASH" list --status testing)" "$id" "list --status testing did not include the card"
  assert_not_contains "$("$DASH" list --status review)" "$id" "a testing card showed up under review"

  "$DASH" status "$id" review >/dev/null || fail "status transition to review failed"
  assert_contains "$("$DASH" show "$id")" "status:   review" "review status did not persist"
  assert_contains "$("$DASH" list --status review)" "$id" "list --status review did not include the card"
  assert_not_contains "$("$DASH" list --status testing)" "$id" "a review card is still listed under testing"

  pass "testing and review are separate, independently settable statuses"
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

test_needs_action_status_carries_reason_and_sorts_first() {
  local id working_id out
  id=$("$DASH" add --title "Needs a decision" --captain firstmate --prompt "checking needs-action" | awk '{print $1}')
  working_id=$("$DASH" add --title "Being actively worked" --captain firstmate --prompt "sort-order control" --status working | awk '{print $1}')

  "$DASH" status "$id" needs-action --reason "pick red or blue for the trim" >/dev/null \
    || fail "status transition to needs-action failed"
  out=$("$DASH" show "$id")
  assert_contains "$out" "status:   needs_action" "needs-action status did not persist"
  assert_contains "$out" "needs action: pick red or blue for the trim" "needs-action reason did not persist"

  local first_id
  first_id=$("$DASH" list --sort status | head -n1 | awk '{print $1}')
  [ "$first_id" = "$id" ] || fail "needs-action ($id) did not sort above a working card ($working_id) under --sort status, got: $first_id"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-action failed"
  assert_not_contains "$("$DASH" show "$id")" "needs action:" "needs-action reason was not cleared on status change"

  pass "needs-action status carries a reason and sorts above every other status"
}

test_needs_action_requires_a_real_ask() {
  local id out rc
  id=$("$DASH" add --title "Reason guard coverage" --captain firstmate --prompt "checking the needs-action guard" | awk '{print $1}')

  # The CLI refuses locally, before any network round-trip, on the obvious
  # missing-reason case.
  out=$("$DASH" status "$id" needs-action 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "needs-action with no --reason was accepted"
  assert_contains "$out" "requires --reason" "missing-reason rejection did not explain the requirement"

  # The server enforces the same rule structurally, not just the CLI's
  # local check: a direct call with an empty reason must also be refused.
  local raw_code
  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" \
    -H 'Content-Type: application/json' -d '{"status":"needs_action"}')
  [ "$raw_code" = "400" ] || fail "the API accepted needs_action with no reason (got HTTP $raw_code)"

  # A reason that only reports progress is refused too, even though it is
  # non-empty.
  out=$("$DASH" status "$id" needs-action --reason "You reported flares not changing the lights - being chased now" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a report-shaped needs-action reason was accepted"
  assert_contains "$out" "reads as a progress report" "report-shaped rejection did not explain why"

  # A genuine ask is accepted and persists.
  "$DASH" status "$id" needs-action --reason "approve the trim color before the install" >/dev/null \
    || fail "a genuine ask was rejected as report-shaped"
  assert_contains "$("$DASH" show "$id")" "needs action: approve the trim color before the install" \
    "a genuine ask did not persist after the guard ran"

  # Creating a card straight into needs-action is governed the same way.
  out=$("$DASH" add --title "Bad create" --captain firstmate --prompt "x" --status needs-action 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs-action with no --reason was accepted"
  assert_contains "$out" "requires --reason" "add's missing-reason rejection did not explain the requirement"

  out=$("$DASH" add --title "Reporty create" --captain firstmate --prompt "x" \
    --status needs-action --reason "looking into the checkout timeout" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs-action with a report-shaped reason was accepted"
  assert_contains "$out" "reads as a progress report" "add's report-shaped rejection did not explain why"

  # And the create path is enforced by the server itself, not only by the
  # CLI's local pre-check - the same treatment the status path gets above.
  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Direct bad create","captain":"firstmate","initial_prompt":"x","status":"needs_action"}')
  [ "$raw_code" = "400" ] || fail "the API accepted a created needs_action card with no reason (got HTTP $raw_code)"

  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Direct reporty create","captain":"firstmate","initial_prompt":"x","status":"needs_action","reason":"still chasing the supplier"}')
  [ "$raw_code" = "400" ] || fail "the API accepted a created needs_action card with a report-shaped reason (got HTTP $raw_code)"

  local created
  created=$("$DASH" add --title "Good create" --captain firstmate --prompt "x" \
    --status needs-action --reason "sign the updated contractor agreement" | awk '{print $1}')
  [ -n "$created" ] || fail "add --status needs-action with a real ask should have succeeded"
  assert_contains "$("$DASH" show "$created")" "needs action: sign the updated contractor agreement" \
    "a card created straight into needs-action did not carry its reason"

  pass "needs-action refuses a missing or report-shaped reason, on both status and add, and the server enforces both independently of the CLI"
}

# `add` can only write the needs_action reason; every other status's reason
# belongs to the `status` subcommand, which is the one path that persists it.
# Passing --reason with any other starting status used to exit 0 and drop the
# text on the floor, so refuse it outright rather than lose it silently.
test_add_refuses_a_reason_for_a_status_that_cannot_carry_one() {
  local out rc id
  out=$("$DASH" add --title "Waiting with a reason" --captain firstmate --prompt "x" \
    --status waiting --reason "waiting on the plumber" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status waiting --reason was accepted, and the reason is silently dropped"
  assert_contains "$out" "only accepted with --status needs-action" \
    "add's refusal did not explain that --reason belongs to needs-action"
  assert_contains "$out" "waiting" "add's refusal did not name the status that was given"
  # `waiting` genuinely persists a reason through the status subcommand, so it
  # is the one status the refusal may redirect to.
  assert_contains "$out" "status <id> waiting --reason" \
    "add's refusal did not point at the subcommand that owns the waiting reason"

  # `working` does not store a reason anywhere `show` renders, so the refusal
  # must not send the caller to a command that would drop it just as quietly.
  out=$("$DASH" add --title "Working with a reason" --captain firstmate --prompt "x" \
    --status working --reason "ready for his eyes" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status working --reason was accepted, and the reason is silently dropped"
  assert_contains "$out" "a reason is not stored for 'working'" \
    "add's refusal did not say a reason is not stored for working"
  assert_not_contains "$out" "status <id> working --reason" \
    "add's refusal redirected to a command that drops the reason for working too"

  # The same starting status is still creatable without a reason, and the
  # `status` subcommand still owns and persists the waiting reason.
  id=$("$DASH" add --title "Waiting without a reason" --captain firstmate --prompt "x" \
    --status waiting | awk '{print $1}')
  [ -n "$id" ] || fail "add --status waiting without --reason should have succeeded"
  "$DASH" status "$id" waiting --reason "waiting on the plumber" >/dev/null \
    || fail "the status subcommand refused the waiting reason it owns"
  assert_contains "$("$DASH" show "$id")" "waiting on the plumber" \
    "the waiting reason set through the status subcommand did not persist"

  pass "add refuses a --reason no status but needs-action can carry, instead of dropping it"
}

# A genuine ask that merely mentions one of the report phrases mid-sentence
# ("approve the $400 monitoring subscription renewal") must still reach the
# board: refusing it leaves the card stuck in `working` and never asks him,
# which is the inverse of the failure the guard exists to prevent.
test_a_genuine_ask_mentioning_a_report_word_is_accepted() {
  local id
  id=$("$DASH" add --title "Mid-sentence report word" --captain firstmate --prompt "checking edge anchoring" | awk '{print $1}')

  "$DASH" status "$id" needs-action --reason "approve the \$400 monitoring subscription renewal" >/dev/null \
    || fail "a genuine ask containing 'monitoring' mid-sentence was refused"
  assert_contains "$("$DASH" show "$id")" "monitoring subscription renewal" \
    "the accepted mid-sentence ask did not persist"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-action failed"
  "$DASH" status "$id" needs-action --reason "pick which contractor keeps working on the deck" >/dev/null \
    || fail "a genuine ask containing 'working on' mid-sentence was refused"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-action failed"
  "$DASH" status "$id" needs-action --reason "approve the invoice for the in progress work" >/dev/null \
    || fail "a genuine ask containing 'in progress' mid-sentence was refused"

  pass "a report phrase buried mid-clause does not refuse a genuine ask"
}

# docs/dashboard.md publishes exact catch/miss/false-positive counts for this
# guard, and the fleet auditor is told to compensate for precisely that
# documented blind spot. Pin the numbers to executed behaviour so narrowing or
# extending REPORT_SHAPED_PHRASES cannot silently make the prose false.
test_documented_guard_rates_still_hold() {
  python3 - "$ROOT/bin/fleet-dashboard/server" <<'GUARD_RATES' || fail "the documented needs-action guard rates no longer hold"
import sys

sys.path.insert(0, sys.argv[1])
from validation import InvalidReasonError, validate_needs_action_reason

# The three corpora documented in docs/dashboard.md, "The needs-action
# reason guard". Keep these in step with the counts stated there.
REPORT_SHAPED = [
    "You reported flares not changing the lights - being chased now",
    "Migration is in progress",
    "Still investigating the checkout timeout",
    "Looking into the failed backup",
    "Currently working on the invoice import",
    "Keeping an eye on the disk usage",
    "Monitoring the alert queue overnight",
    "No update yet",
    "Will update once the vendor replies",
    "Rebuild kicked off - update to follow",
    "Tracking down the duplicate charge",
    "Digging into the log spike",
    "Emails bouncing since Tuesday - following up on it",
    "The permit is under investigation",
    "Still chasing the supplier",
]
REWORDED_REPORTS = [
    "No change since last time",
    "Still on it",
    "Checked again, same result",
    "Reproduced it, cause unclear",
    "Nothing new to report",
    "Same as yesterday",
    "Waiting on the vendor to call back",
    "Ran the script twice, both failed",
    "It is not fixed yet",
    "Heard back from the supplier, no news",
    "The team is looking into the failed backup",
    "The crew was investigating the leak",
    "We are investigating the checkout timeout",
    "I was digging into the bounced payouts",
    "We were keeping an eye on the disk usage",
    "It's still chasing the supplier",
    "Monitoring disk usage",
    "Still monitoring disk usage",
]
GENUINE_ASKS = [
    "Pick red or blue for the trim",
    "Approve the $400 hosting renewal",
    "Confirm the domain transfer by Friday",
    "Approve the $400 monitoring subscription renewal",
    "Pick which contractor keeps working on the deck",
    "Approve the invoice for the in progress work",
    "Decide whether to keep the monitoring alerts on overnight",
    "Sign the updated contractor agreement",
    "Tell me which of the two quotes to accept",
    "Send me the router password so the install can finish",
    "Choose a delivery date for the countertops",
    "Confirm you want the old server decommissioned",
    "Is monitoring the pool worth $80 a month?",
    "Was looking into the second quote worth the delay?",
]


def refused(reason):
    try:
        validate_needs_action_reason(reason)
    except InvalidReasonError:
        return True
    return False


failures = []
for corpus, name, want in (
    (REPORT_SHAPED, "report-shaped", True),
    (REWORDED_REPORTS, "reworded report", False),
    (GENUINE_ASKS, "genuine ask", False),
):
    for reason in corpus:
        if refused(reason) is not want:
            failures.append(f"{name} {reason!r} was {'accepted' if want else 'refused'}")

counts = (
    sum(refused(r) for r in REPORT_SHAPED),
    sum(refused(r) for r in REWORDED_REPORTS),
    sum(refused(r) for r in GENUINE_ASKS),
)
if counts != (15, 0, 0):
    failures.append(
        f"documented rates drifted: caught/missed/false-positive counts are {counts}, "
        "docs/dashboard.md says 15/15 caught, 0/18 already-missed caught, 0/14 false positives"
    )

for line in failures:
    print(line, file=sys.stderr)
sys.exit(1 if failures else 0)
GUARD_RATES
  pass "the catch, miss, and false-positive rates documented for the reason guard are the ones it actually achieves"
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

# The board is typically a tailnet host that can simply be powered off, which
# drops packets rather than refusing them, and these calls run inside held
# handoff locks (bin/fm-backlog-handoff.sh) and on bin/fm-bootstrap.sh's
# synchronous path - an unbounded wait there stalls the whole fleet rather
# than one card. Drive that with a real listener that accepts the connection
# and then answers nothing at all, which is exactly what a refused-connection
# fixture cannot reproduce.
test_calls_are_bounded_against_a_board_that_never_answers() {
  local portfile blackhole_pid port i rc
  command -v timeout >/dev/null 2>&1 || { pass "skipped bounded-call coverage - timeout(1) not available"; return 0; }
  portfile="$FM_HOME/blackhole.port"
  rm -f "$portfile"
  python3 - "$portfile" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(sys.argv[1] + ".tmp", "w") as fh:
    fh.write(str(s.getsockname()[1]))
import os
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
held = []
while True:
    conn, _ = s.accept()
    held.append(conn)  # accepted, then deliberately never answered
    time.sleep(0.01)
PY
  blackhole_pid=$!
  i=0
  until [ -s "$portfile" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || { kill "$blackhole_pid" 2>/dev/null; fail "the never-answering fixture never bound a port"; }
    sleep 0.05
  done
  port=$(cat "$portfile")

  rc=0
  FM_DASHBOARD_URL="http://127.0.0.1:$port" FM_DASHBOARD_MAX_TIME=2 \
    timeout 20 "$DASH" show any-card --json >/dev/null 2>&1 || rc=$?
  kill "$blackhole_pid" 2>/dev/null
  wait "$blackhole_pid" 2>/dev/null

  [ "$rc" -ne 124 ] || fail "a board that accepts the connection and never answers hung the call: it is not bounded"
  [ "$rc" -ne 0 ] || fail "a board that never answers somehow reported success"
  pass "every dashboard call is bounded, so a board that never answers fails fast instead of hanging"
}

# The bound above can be handed back by an override curl accepts but reads as
# "no timeout at all": --max-time 0 and --connect-timeout 0 are unlimited, not
# instant. A zero (or all-zero decimal) override therefore has to be refused
# exactly like a non-numeric one - reported loudly and replaced by the
# default - rather than passed through to curl.
test_zero_timeout_override_is_refused_like_any_other_unusable_one() {
  local err
  err="$FM_HOME/zero-timeout.err"

  FM_DASHBOARD_MAX_TIME=0 FM_DASHBOARD_CONNECT_TIMEOUT=0.0 \
    "$DASH" list >/dev/null 2>"$err" || fail "list failed under a zero timeout override: $(cat "$err")"
  assert_grep 'ignoring invalid FM_DASHBOARD_MAX_TIME=0' "$err" \
    "a zero --max-time override was accepted silently instead of falling back to the bounded default"
  assert_grep 'ignoring invalid FM_DASHBOARD_CONNECT_TIMEOUT=0.0' "$err" \
    "an all-zero --connect-timeout override was accepted silently instead of falling back to the bounded default"

  FM_DASHBOARD_MAX_TIME=2 "$DASH" list >/dev/null 2>"$err" \
    || fail "list failed under a valid timeout override: $(cat "$err")"
  assert_no_grep 'ignoring invalid' "$err" "a valid timeout override was rejected"
  pass "a zero timeout override is refused and replaced by the default, so the bound cannot be handed back"
}

# bin/fm-backlog-handoff.sh's pending card record retires neither: a
# "no such card" only proves some host answered, never that the host answering
# was the board, so such a pair is kept and retried exactly like one the board
# could not be reached for. Both are reported the same way too - once per
# command that sweeps the pair, and again on a later separate invocation while
# the link is still owed. Neither reaches the fleet audit log either. What the
# two answers still decide is WHICH stderr warning the pair gets, so the
# handoff has to be able to tell them apart from the outside - by exit code
# rather than by parsing stderr.
test_missing_id_and_unreachable_board_have_distinct_exit_codes() {
  local rc=0
  "$DASH" show definitely-no-such-card --json >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 4 ] || fail "a board-answered 'no such card' should exit 4, got $rc"

  rc=0
  FM_DASHBOARD_PORT=1 "$DASH" show definitely-no-such-card --json >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "an unreachable board should exit 1, not the not-found code, got $rc"
  pass "a board-answered missing id and an unreachable board are distinguishable by exit code"
}

# --help renders the script's whole header comment block. The blocks asserted
# here are the LAST ones in that header, so a future header edit that truncates
# the rendering (as a fixed line range once did) fails here instead of silently
# dropping the tail of the only syntax reference agents are pointed at.
test_help_prints_the_whole_header_through_its_last_block() {
  local out
  out=$("$DASH" --help) || fail "--help should succeed"

  assert_contains "$out" "statuses: needs-action" "--help lost the statuses block"
  assert_contains "$out" "Server URL resolution" "--help lost the server URL resolution block"
  assert_contains "$out" "--connect-timeout 5s and --max-time 20s" \
    "--help lost the call-bounding block"
  assert_contains "$out" "FM_DASHBOARD_CONNECT_TIMEOUT" "--help lost the timeout override names"
  assert_contains "$out" "Exit codes: 0 success" "--help lost the exit-code table"
  pass "--help prints the header through its final exit-code block"
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

# Regression: the testing/review split (docs/dashboard.md "Why `testing`
# split into `testing` and `review`") migrates every pre-existing `testing`
# card to `review` exactly once, the first time the server ever starts
# against a database that predates the split - never again afterward, or a
# genuinely new `testing` card would be wrongly rewritten on a later restart.
# Seeds a database directly via store.py's own schema (never duplicating it
# by hand) so a `testing` row can exist before any code has ever constructed
# a Store against this file, which is the only way to simulate "this card
# predates the split" in a single test run.
test_testing_to_review_split_migration_runs_once() {
  local mig_home mig_db mig_port mig_url out live_id
  mig_home="$FM_HOME/migration-case"
  mkdir -p "$mig_home/state" "$mig_home/data"
  mig_db="$mig_home/data/dashboard.db"

  PYTHONPATH="$ROOT/bin/fleet-dashboard/server" python3 - "$mig_db" <<'PY' || fail "could not seed a pre-split database"
import sqlite3
import sys

import store

conn = sqlite3.connect(sys.argv[1])
conn.executescript(store.SCHEMA)
conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('audit_interval_minutes', '15')")
ts = "2020-01-02T03:04:05Z"
conn.execute(
    """INSERT INTO tasks (id, title, agent, captain, status, initial_prompt, created_at, updated_at)
       VALUES ('premigration-testing-1', 'Pre-split testing card', '', 'firstmate', 'testing', 'seed prompt', ?, ?)""",
    (ts, ts),
)
conn.commit()
conn.close()
PY

  mig_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
    || fail "could not allocate a port for the migration case"
  mig_url="http://127.0.0.1:$mig_port"

  FM_HOME="$mig_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$mig_port" FM_DASHBOARD_DB="$mig_db" \
    "$DASH" start >"$mig_home/start.out" 2>&1 || { cat "$mig_home/start.out" >&2; fail "migration-case server did not start"; }
  MIGRATION_SERVER_PID=$(cat "$mig_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after migration-case server start"

  out=$(FM_DASHBOARD_URL="$mig_url" "$DASH" show premigration-testing-1)
  assert_contains "$out" "status:   review" "a pre-existing testing card was not migrated to review on first start"
  assert_not_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" list --status testing)" "premigration-testing-1" \
    "the migrated card is still listed under testing"

  # The migration must also prove what it changed, not just change it. Its two
  # artifacts are the card's own persisted status_history (served through the
  # HTTP API) and the startup report the server writes to its log.
  FM_DASHBOARD_URL="$mig_url" "$DASH" show premigration-testing-1 --json \
    | jq -e '[.status_history[] | select(.from_status == "testing" and .to_status == "review")] | length == 1' >/dev/null \
    || fail "the migration left no single testing->review status_history entry proving what it rewrote"
  FM_DASHBOARD_URL="$mig_url" "$DASH" show premigration-testing-1 --json \
    | jq -e '[.status_history[] | select(.to_status == "review" and (.note // "") != "")] | length == 1' >/dev/null \
    || fail "the migration's status_history entry carries no note explaining the rewrite"
  assert_contains "$(cat "$mig_home/state/dashboard.log")" "migrated 1 card(s) from testing to review" \
    "the server did not report the migration it performed at startup"
  assert_contains "$(cat "$mig_home/state/dashboard.log")" "premigration-testing-1" \
    "the startup migration report does not name the card it rewrote"
  # A mechanical relabel is not the Admiral's work changing, so it must not
  # float the card to the top of the board's default updated-desc sort.
  assert_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" show premigration-testing-1 --json | jq -r '.updated_at')" \
    "2020-01-02T03:04:05Z" "the migration bumped updated_at and would reorder the Admiral's default board view"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""

  # Restart against the SAME, already-migrated database and add a genuinely
  # new testing card (the new meaning). If the migration ran a second time it
  # would wrongly rewrite this card to review too.
  FM_HOME="$mig_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$mig_port" FM_DASHBOARD_DB="$mig_db" \
    "$DASH" start >"$mig_home/restart.out" 2>&1 || { cat "$mig_home/restart.out" >&2; fail "migration-case server did not restart"; }
  MIGRATION_SERVER_PID=$(cat "$mig_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after migration-case server restart"

  live_id=$(FM_DASHBOARD_URL="$mig_url" "$DASH" add --title "Genuinely in-flight testing" \
    --captain firstmate --prompt "the fleet is testing this right now" --status testing | awk '{print $1}')
  [ -n "$live_id" ] || fail "could not add a genuine post-split testing card"
  assert_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" show "$live_id")" "status:   testing" \
    "the post-split testing card did not come back as testing before any further restart"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""

  # The card above only crosses a migration boundary NOW: it was created after
  # the last start, so this third one is the first time an existing, genuinely
  # in-flight testing card is present while the migration decides whether to
  # run. An ungated migration rewrites it to review here.
  FM_HOME="$mig_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$mig_port" FM_DASHBOARD_DB="$mig_db" \
    "$DASH" start >"$mig_home/restart2.out" 2>&1 \
    || { cat "$mig_home/restart2.out" >&2; fail "migration-case server did not start a third time"; }
  MIGRATION_SERVER_PID=$(cat "$mig_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after the third migration-case server start"

  assert_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" show "$live_id")" "status:   testing" \
    "a later server start re-ran the migration and rewrote a genuine post-split testing card to review"
  assert_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" list --status testing)" "$live_id" \
    "the genuine post-split testing card fell out of the testing list across a restart"
  assert_not_contains "$(cat "$mig_home/state/dashboard.log")" "from testing to review" \
    "a later start reported running the migration again over an already-migrated database"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""
  pass "the testing-to-review split migration converts only pre-existing testing cards, and runs at most once"
}

# Guards the ordering contract between the one-time migration and the
# listening socket, and the synchrony contract of `stop`. Both exist because
# the live board is upgraded with `fm-dashboard.sh restart`: if `stop` returned
# while the old server still held the port, the new server would commit the
# irreversible migration and then die on EADDRINUSE, leaving the database
# migrated while a pre-split server kept serving statuses it cannot render.
test_a_start_that_cannot_bind_leaves_the_migration_pending() {
  local blk_home blk_db blk_port blk_url holder_pid first_pid waited

  blk_home="$FM_HOME/blocked-bind-case"
  mkdir -p "$blk_home/state" "$blk_home/data"
  blk_db="$blk_home/data/dashboard.db"

  PYTHONPATH="$ROOT/bin/fleet-dashboard/server" python3 - "$blk_db" <<'PY' || fail "could not seed a pre-split database for the blocked-bind case"
import sqlite3
import sys

import store

conn = sqlite3.connect(sys.argv[1])
conn.executescript(store.SCHEMA)
conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('audit_interval_minutes', '15')")
ts = "2020-02-03T04:05:06Z"
conn.execute(
    """INSERT INTO tasks (id, title, agent, captain, status, initial_prompt, created_at, updated_at)
       VALUES ('blocked-bind-testing-1', 'Pre-split testing card', '', 'firstmate', 'testing', 'seed prompt', ?, ?)""",
    (ts, ts),
)
conn.commit()
conn.close()
PY

  blk_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
    || fail "could not allocate a port for the blocked-bind case"
  blk_url="http://127.0.0.1:$blk_port"

  # Stand in for the old server that has been signalled but has not let go of
  # the port yet - the exact window a non-waiting `stop` leaves open.
  python3 -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
time.sleep(600)' "$blk_port" &
  holder_pid=$!
  PORT_HOLDER_PID="$holder_pid"
  waited=0
  until python3 -c 'import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
s.close()' "$blk_port" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -gt 100 ] && fail "the port holder never came up for the blocked-bind case"
    sleep 0.05
  done

  if FM_HOME="$blk_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$blk_port" FM_DASHBOARD_DB="$blk_db" \
      "$DASH" start >"$blk_home/blocked-start.out" 2>&1; then
    fail "start reported success while another process already held the port"
  fi

  kill "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null || true
  PORT_HOLDER_PID=""

  # The blocked start must not have consumed the one-time migration: the card
  # is still pre-split, so the first start that actually serves migrates it.
  FM_HOME="$blk_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$blk_port" FM_DASHBOARD_DB="$blk_db" \
    "$DASH" start >"$blk_home/start.out" 2>&1 \
    || { cat "$blk_home/start.out" >&2; fail "blocked-bind-case server did not start once the port was free"; }
  MIGRATION_SERVER_PID=$(cat "$blk_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after the blocked-bind-case server start"
  first_pid="$MIGRATION_SERVER_PID"

  assert_contains "$(FM_DASHBOARD_URL="$blk_url" "$DASH" show blocked-bind-testing-1)" "status:   review" \
    "a start that could not bind consumed the one-time migration, so the card never reached review"
  assert_contains "$(cat "$blk_home/state/dashboard.log")" "migrated 1 card(s) from testing to review" \
    "the start that actually served did not report the migration the blocked start must have left pending"

  # `stop` must not return until the process is really gone, or `restart`
  # would hand the port to a new server the old one still owns.
  FM_HOME="$blk_home" "$DASH" stop >"$blk_home/stop.out" 2>&1 \
    || { cat "$blk_home/stop.out" >&2; fail "stop failed for the blocked-bind-case server"; }
  MIGRATION_SERVER_PID=""
  if kill -0 "$first_pid" 2>/dev/null; then
    fail "stop returned while pid $first_pid was still running, so restart can overlap two servers"
  fi

  # ...which is exactly what makes an immediate re-start on the same port work.
  FM_HOME="$blk_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$blk_port" FM_DASHBOARD_DB="$blk_db" \
    "$DASH" start >"$blk_home/restart.out" 2>&1 \
    || { cat "$blk_home/restart.out" >&2; fail "an immediate start after stop could not take the port back"; }
  MIGRATION_SERVER_PID=$(cat "$blk_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after the immediate re-start"
  assert_contains "$(FM_DASHBOARD_URL="$blk_url" "$DASH" show blocked-bind-testing-1)" "status:   review" \
    "the card did not survive an immediate stop/start cycle as review"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""
  pass "a start that cannot bind leaves the migration pending, and stop waits for the port"
}

# `restart` is the operator's one command for bringing the live board back, so
# it must survive every state `stop` can refuse: a stale pidfile left by a
# crashed server, and no pidfile at all after a clean stop. Both are `die`
# paths inside cmd_server_stop, and `die` is `exit 1`.
test_restart_recovers_from_a_crashed_or_stopped_board() {
  local rst_home rst_db rst_port rst_url crashed_pid revived_pid card_id

  rst_home="$FM_HOME/restart-case"
  mkdir -p "$rst_home/state" "$rst_home/data"
  rst_db="$rst_home/data/dashboard.db"
  rst_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
    || fail "could not allocate a port for the restart case"
  rst_url="http://127.0.0.1:$rst_port"

  FM_HOME="$rst_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$rst_port" FM_DASHBOARD_DB="$rst_db" \
    "$DASH" start >"$rst_home/start.out" 2>&1 \
    || { cat "$rst_home/start.out" >&2; fail "restart-case server did not start"; }
  MIGRATION_SERVER_PID=$(cat "$rst_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after the restart-case server start"
  crashed_pid="$MIGRATION_SERVER_PID"

  card_id=$(FM_DASHBOARD_URL="$rst_url" "$DASH" add --title "Survives a restart" \
    --captain firstmate --prompt "seeded before the crash" --status review | awk '{print $1}')
  [ -n "$card_id" ] || fail "could not seed a card before the crash"

  # Crash the server the way an OOM kill or a lost tmux session would: the
  # process dies without ever removing its own pidfile.
  kill -9 "$crashed_pid" 2>/dev/null
  while kill -0 "$crashed_pid" 2>/dev/null; do sleep 0.05; done
  [ -f "$rst_home/state/dashboard.pid" ] || fail "the crash removed the pidfile, so this is not the stale-pidfile case"

  FM_HOME="$rst_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$rst_port" FM_DASHBOARD_DB="$rst_db" \
    "$DASH" restart >"$rst_home/restart-after-crash.out" 2>&1 \
    || { cat "$rst_home/restart-after-crash.out" >&2; fail "restart did not bring the board back after a crash left a stale pidfile"; }
  MIGRATION_SERVER_PID=$(cat "$rst_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after restarting over a stale pidfile"
  revived_pid="$MIGRATION_SERVER_PID"
  [ "$revived_pid" != "$crashed_pid" ] || fail "restart recorded the dead pid instead of a new server"
  assert_contains "$(FM_DASHBOARD_URL="$rst_url" "$DASH" show "$card_id")" "status:   review" \
    "the board did not serve its cards again after a restart over a stale pidfile"

  # A clean stop removes the pidfile, so restarting from stopped is the
  # "no pidfile" die path - it must start the board, not refuse.
  FM_HOME="$rst_home" "$DASH" stop >"$rst_home/stop.out" 2>&1 \
    || { cat "$rst_home/stop.out" >&2; fail "stop failed for the restart-case server"; }
  MIGRATION_SERVER_PID=""
  if [ -f "$rst_home/state/dashboard.pid" ]; then
    fail "a clean stop left a pidfile behind, so this is not the no-pidfile case"
  fi

  FM_HOME="$rst_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$rst_port" FM_DASHBOARD_DB="$rst_db" \
    "$DASH" restart >"$rst_home/restart-from-stopped.out" 2>&1 \
    || { cat "$rst_home/restart-from-stopped.out" >&2; fail "restart refused to start an already-stopped board"; }
  MIGRATION_SERVER_PID=$(cat "$rst_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after restarting an already-stopped board"

  # And the ordinary case: restarting a healthy board hands the same port to a
  # genuinely new process without losing the board.
  crashed_pid="$MIGRATION_SERVER_PID"
  FM_HOME="$rst_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$rst_port" FM_DASHBOARD_DB="$rst_db" \
    "$DASH" restart >"$rst_home/restart-live.out" 2>&1 \
    || { cat "$rst_home/restart-live.out" >&2; fail "restart failed against a healthy running board"; }
  MIGRATION_SERVER_PID=$(cat "$rst_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after restarting a healthy board"
  [ "$MIGRATION_SERVER_PID" != "$crashed_pid" ] || fail "restart against a healthy board did not replace the process"
  assert_contains "$(FM_DASHBOARD_URL="$rst_url" "$DASH" show "$card_id")" "status:   review" \
    "the board did not serve its cards again after restarting a healthy server"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""
  pass "restart brings the board back from a crash, from stopped, and from healthy"
}

# A crash leaves the pidfile behind, and the host's pid counter can hand that
# number to an unrelated process before anyone types stop or restart. The
# lifecycle commands must recognise that the recorded pid is no longer a
# dashboard and drop the stale file, not signal whatever inherited the number.
test_lifecycle_commands_refuse_a_recycled_pid() {
  local rec_home rec_db rec_port rec_url pf innocent_pid out card_id

  rec_home="$FM_HOME/recycled-pid-case"
  mkdir -p "$rec_home/state" "$rec_home/data"
  rec_db="$rec_home/data/dashboard.db"
  rec_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
    || fail "could not allocate a port for the recycled-pid case"
  rec_url="http://127.0.0.1:$rec_port"
  pf="$rec_home/state/dashboard.pid"

  # Stand in for the unrelated process that inherited the crashed board's pid.
  sleep 600 &
  innocent_pid=$!
  RECYCLED_PID="$innocent_pid"
  printf '%s\n' "$innocent_pid" >"$pf"

  # server-status must not claim the board is running just because the number
  # in the pidfile happens to be alive.
  out=$(FM_HOME="$rec_home" FM_DASHBOARD_URL="$rec_url" "$DASH" server-status 2>&1)
  assert_contains "$out" "process: not running" \
    "server-status reported a recycled pid as the running board"

  if FM_HOME="$rec_home" "$DASH" stop >"$rec_home/stop.out" 2>&1; then
    fail "stop reported success against a pid that is not a dashboard server"
  fi
  assert_contains "$(cat "$rec_home/stop.out")" "not a fleet dashboard server" \
    "stop did not say why it refused the recycled pid"
  kill -0 "$innocent_pid" 2>/dev/null \
    || fail "stop signalled an unrelated process that had inherited the recorded pid"
  if [ -f "$pf" ]; then
    fail "stop left the stale pidfile in place, so start would keep refusing"
  fi

  # ...and having dropped the stale file, the board comes back up normally
  # without the innocent process being touched.
  FM_HOME="$rec_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$rec_port" FM_DASHBOARD_DB="$rec_db" \
    "$DASH" start >"$rec_home/start.out" 2>&1 \
    || { cat "$rec_home/start.out" >&2; fail "start did not bring the board up after the stale pidfile was dropped"; }
  MIGRATION_SERVER_PID=$(cat "$pf" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after the recycled-pid-case start"
  card_id=$(FM_DASHBOARD_URL="$rec_url" "$DASH" add --title "After a recycled pid" \
    --captain firstmate --prompt "the board still works" --status review | awk '{print $1}')
  [ -n "$card_id" ] || fail "the board that started after the recycled pid does not serve"
  kill -0 "$innocent_pid" 2>/dev/null \
    || fail "the unrelated process was killed somewhere in the recycled-pid lifecycle"

  # restart over the same recycled state must also spare the innocent process
  # while still ending with a board running.
  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""
  printf '%s\n' "$innocent_pid" >"$pf"
  FM_HOME="$rec_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$rec_port" FM_DASHBOARD_DB="$rec_db" \
    "$DASH" restart >"$rec_home/restart.out" 2>&1 \
    || { cat "$rec_home/restart.out" >&2; fail "restart did not bring the board back over a recycled pidfile"; }
  MIGRATION_SERVER_PID=$(cat "$pf" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after restarting over a recycled pidfile"
  [ "$MIGRATION_SERVER_PID" != "$innocent_pid" ] || fail "restart recorded the unrelated pid as the board"
  kill -0 "$innocent_pid" 2>/dev/null \
    || fail "restart killed the unrelated process that had inherited the recorded pid"
  assert_contains "$(FM_DASHBOARD_URL="$rec_url" "$DASH" show "$card_id")" "status:   review" \
    "the board did not serve its cards after restarting over a recycled pidfile"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""
  kill "$innocent_pid" 2>/dev/null
  wait "$innocent_pid" 2>/dev/null || true
  RECYCLED_PID=""
  pass "the lifecycle commands refuse a recycled pid instead of signalling it"
}

# The captain set has ONE hand-maintained copy: bin/fleet-dashboard/web/captains.json.
# The CLI reads it with jq, the server with json, and the page fetches it over
# the static path this test uses. Nothing here reads that file from disk: the
# set is taken from the running board exactly as the browser takes it, and then
# every other surface is driven through its own public interface and required to
# agree. Add a captain to only one of them and this fails.
#
# The honest limit: with no browser in CI, the page's agreement is proved only
# as far as "the manifest it fetches is served, at that path, with the fields it
# renders". A hand-written captain list re-introduced INSIDE app.js would not be
# caught here - only re-introducing one in the CLI or the server is.
test_the_captain_set_agrees_across_every_surface() {
  local served ids id short label card row cli_ids raw_code n field
  served=$(curl -fsS "http://127.0.0.1:$PORT/captains.json") \
    || fail "the board does not serve /captains.json - the page cannot name any captain"
  printf '%s' "$served" | jq -e '.captains | type == "array" and length > 0' >/dev/null \
    || fail "/captains.json does not carry a non-empty captains array"

  # Every field the page renders must be present for every captain, or a captain
  # ships as a blank pill instead of a name.
  printf '%s' "$served" \
    | jq -e '.captains | all(has("id") and has("short") and has("label") and has("color"))' >/dev/null \
    || fail "a captain in /captains.json is missing id/short/label/color"
  n=$(printf '%s' "$served" | jq '.captains | length')
  for field in id short label color; do
    [ "$(printf '%s' "$served" | jq "[.captains[].$field] | unique | length")" = "$n" ] \
      || fail "two captains share a $field - ids, shorthands, labels and colors must each be distinct"
  done

  ids=$(printf '%s' "$served" | jq -r '.captains[].id')

  # The CLI's own list must be exactly the page's list, in the same order.
  cli_ids=$("$DASH" captains | tail -n +2 | awk '{print $1}')
  [ "$cli_ids" = "$ids" ] \
    || fail "the CLI and the page disagree about the captains: CLI [$cli_ids] vs served [$ids]"

  # ...and every one of them must actually work end to end, by shorthand on the
  # way in and by id on the way back out, through the CLI, the API and the DB.
  while IFS=$'\t' read -r id short label; do
    card=$("$DASH" add --title "Card for $label" --captain "$short" \
      --prompt "captain-set agreement check" | awk '{print $1}') \
      || fail "the board refused a card for '$short', a captain it lists"
    [ -n "$card" ] || fail "no card created for captain '$short'"
    assert_contains "$("$DASH" show "$card")" "captain:  $id" \
      "card for '$short' did not come back filed under $id"
    row=$("$DASH" list --captain "$id" --json | jq -r --arg c "$card" '.tasks[] | select(.id==$c) | .captain')
    [ "$row" = "$id" ] || fail "filtering by captain $id did not return its own card"
    "$DASH" captain "$card" "$id" >/dev/null \
      || fail "the CLI refused the full id '$id' for a captain it lists"
    "$DASH" delete "$card" --confirm >/dev/null || fail "could not clean up the card for $short"
  done < <(printf '%s' "$served" | jq -r '.captains[] | "\(.id)\t\(.short)\t\(.label)"')

  # Fail-closed both ways: a captain nobody lists is refused by the CLI's local
  # check AND by the server itself, so a stale local manifest cannot mislabel a
  # card through the raw API.
  local out rc
  out=$("$DASH" add --title "Nobody's card" --captain captain_nobody --prompt "x" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the CLI accepted an unlisted captain"
  assert_contains "$out" "unknown captain" "the CLI's refusal did not name the problem"
  local body server_ids
  body=$(curl -sS -o "$FM_HOME/unlisted.out" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Direct unlisted captain","captain":"captain_nobody","initial_prompt":"x"}')
  [ "$body" = "400" ] || fail "the API accepted an unlisted captain (got HTTP $body)"

  # That refusal also names the set the SERVER is enforcing, which is how this
  # test sees the server's own copy without reading its source. Anything the
  # server would accept that the page never lists is drift.
  server_ids=$(jq -r '.error' "$FM_HOME/unlisted.out" | sed -E 's/.*(Valid|one of): //' | tr ',' '\n' | tr -d ' ')
  [ "$server_ids" = "$ids" ] \
    || fail "the server and the page disagree about the captains: server [$server_ids] vs served [$ids]"

  pass "the CLI, the server and the page the browser loads all name the same captains"
}

# The doctrine in .agents/skills/fleet-dashboard/SKILL.md sends every card whose
# next step is the Admiral's own labour to `needs-action`, so `--reason` is what he
# actually reads to know what he has to do. That promise is only as good as the
# narrowest path that can set the status: the ones covered above are the
# ordinary ones, and these are the rest of the surface - the underscore spelling
# a caller may reach for, a reason that is present but is only whitespace, and
# the general-purpose PATCH that edits a card's other fields.
test_no_path_can_set_needs_action_without_an_ask() {
  local id out rc code before after
  id=$("$DASH" add --title "Enforcement surface" --captain firstmate --prompt "checking every writer" | awk '{print $1}')

  # The CLI canonicalises the status before it refuses, so the underscore
  # spelling is refused exactly like the dashed one rather than slipping past
  # the local check.
  out=$("$DASH" status "$id" needs_action 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "status needs_action (underscore) with no --reason was accepted"
  assert_contains "$out" "requires --reason" "underscore-spelled status rejection did not explain the requirement"

  out=$("$DASH" add --title "Underscore create" --captain firstmate --prompt "x" --status needs_action 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs_action (underscore) with no --reason was accepted"
  assert_contains "$out" "requires --reason" "underscore-spelled add rejection did not explain the requirement"

  # A whitespace-only reason is a reason as far as "did the caller pass one"
  # goes, and renders as nothing at all on the card. The server refuses it on
  # both writing paths.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" \
    -H 'Content-Type: application/json' -d '{"status":"needs_action","reason":"   "}')
  [ "$code" = "400" ] || fail "the API accepted needs_action with a whitespace-only reason (got HTTP $code)"
  assert_contains "$("$DASH" show "$id")" "status:   not_started" \
    "a refused whitespace-only reason still moved the card"

  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Blank-reason create","captain":"firstmate","initial_prompt":"x","status":"needs_action","reason":"\t\n "}')
  [ "$code" = "400" ] || fail "the API accepted a created needs_action card with a whitespace-only reason (got HTTP $code)"
  assert_not_contains "$("$DASH" list)" "Blank-reason create" \
    "a card refused for a blank reason was created anyway"

  # PATCH exists to edit a card's other fields; it must not be a second,
  # unguarded way into needs_action. It answers, and the status is untouched.
  before=$("$DASH" show "$id" | grep '^status:')
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
    "http://127.0.0.1:$PORT/api/tasks/$id" -H 'Content-Type: application/json' \
    -d '{"title":"Enforcement surface (patched)","status":"needs_action"}')
  [ "$code" = "200" ] || fail "PATCH of an ordinary field failed (got HTTP $code)"
  after=$("$DASH" show "$id" | grep '^status:')
  [ "$before" = "$after" ] || fail "PATCH wrote a status: was [$before], now [$after]"
  assert_contains "$("$DASH" show "$id")" "Enforcement surface (patched)" \
    "PATCH did not apply the field it is allowed to write"
  assert_not_contains "$("$DASH" show "$id")" "needs action:" \
    "PATCH left a needs-action card behind with no ask on it"

  pass "no path - either spelling, a blank reason, or PATCH - can put a card in needs-action without a real ask"
}

# The deprecated spelling has to keep WORKING, not merely be tolerated: the
# fleet auditor's sweep, bin/fm-dashboard-link-lib.sh, and any agent holding an
# older copy of the doctrine all still say needs-attention. It must land on
# needs_action, and it must never be echoed back as a status of its own.
test_needs_attention_is_an_accepted_input_alias_and_never_an_output() {
  local id out
  id=$("$DASH" add --title "Alias coverage" --captain firstmate --prompt "x" | awk '{print $1}')

  "$DASH" status "$id" needs-attention --reason "approve the trim color before the install" >/dev/null \
    || fail "the deprecated needs-attention spelling was refused instead of mapped"
  assert_contains "$("$DASH" show "$id")" "status:   needs_action" \
    "needs-attention did not land on needs_action"

  # Underscored spelling, and the raw API, are the same door.
  "$DASH" status "$id" working >/dev/null || fail "could not reset the card"
  "$DASH" status "$id" needs_attention --reason "sign the updated contractor agreement" >/dev/null \
    || fail "the underscored deprecated spelling was refused"
  assert_contains "$("$DASH" show "$id")" "status:   needs_action" \
    "needs_attention did not land on needs_action"

  "$DASH" status "$id" working >/dev/null || fail "could not reset the card"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" -H 'Content-Type: application/json' \
    -d '{"status":"needs_attention","reason":"pick red or blue for the trim"}')
  [ "$code" = "200" ] || fail "the API refused the deprecated spelling (got HTTP $code)"
  assert_contains "$("$DASH" show "$id")" "status:   needs_action" \
    "the API did not map needs_attention onto needs_action"

  # Filtering by the old name finds the migrated card, and answers in the new one.
  out=$("$DASH" list --status needs-attention)
  assert_contains "$out" "$id" "listing by the deprecated status name did not find the card"
  assert_contains "$out" "needs_action" "listing by the deprecated name did not answer in the new one"
  assert_not_contains "$out" "needs_attention" "the board echoed the retired status name back as output"

  # And the alias is a rename, not a bypass: the reason rule still binds.
  out=$("$DASH" status "$id" needs-attention 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the deprecated spelling was accepted with no --reason"
  assert_contains "$out" "requires --reason" "the alias path skipped the reason requirement"

  pass "needs-attention is accepted as an input alias for needs-action, enforced the same way, and never emitted"
}

# The whole point of needs_review is the approval box, and an approval box with
# nothing in it would record his consent to nothing at all. Every writer must
# refuse it, not just the convenient one.
test_needs_review_without_a_plan_is_refused_everywhere() {
  local id out rc code
  id=$("$DASH" add --title "Plan requirement" --captain firstmate --prompt "x" | awk '{print $1}')

  out=$("$DASH" status "$id" needs-review 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "needs-review with no --plan was accepted"
  assert_contains "$out" "requires --plan" "the refusal did not explain the plan requirement"
  assert_contains "$("$DASH" show "$id")" "status:   not_started" \
    "a refused needs-review still moved the card"

  out=$("$DASH" add --title "Planless create" --captain firstmate --prompt "x" --status needs-review 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs-review with no --plan was accepted"
  assert_not_contains "$("$DASH" list)" "Planless create" "a card refused for a missing plan was created anyway"

  # The server enforces it independently of the CLI, on both writing paths,
  # and a whitespace-only plan is no plan at all - it renders as an empty box.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" -H 'Content-Type: application/json' \
    -d '{"status":"needs_review"}')
  [ "$code" = "400" ] || fail "the API accepted needs_review with no plan (got HTTP $code)"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" -H 'Content-Type: application/json' \
    -d '{"status":"needs_review","plan":"  \t \n "}')
  [ "$code" = "400" ] || fail "the API accepted needs_review with a whitespace-only plan (got HTTP $code)"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Direct planless","captain":"firstmate","initial_prompt":"x","status":"needs_review"}')
  [ "$code" = "400" ] || fail "the API created a needs_review card with no plan (got HTTP $code)"
  assert_contains "$("$DASH" show "$id")" "status:   not_started" \
    "a refused needs_review still moved the card"

  # A plan already on the card is enough - it does not have to be re-passed.
  "$DASH" status "$id" needs-review --plan "Rebase onto the open PR and re-run the checks." >/dev/null \
    || fail "needs-review with a plan was refused"
  "$DASH" status "$id" working >/dev/null || fail "could not leave needs-review"
  "$DASH" status "$id" needs-review >/dev/null \
    || fail "needs-review was refused on a card that already carries a plan"
  assert_contains "$("$DASH" show "$id")" "recommended plan: Rebase onto the open PR" \
    "the card lost the plan it already carried"

  pass "needs-review refuses a missing, blank, or absent plan on every writer, and accepts one the card already holds"
}

# The safety property of this whole change: an approval is bound to the exact
# wording he was looking at, and can never drift onto text he never read.
test_an_approval_binds_to_the_plan_text_it_was_given_for() {
  local id json code
  id=$("$DASH" add --title "Approval binding" --captain firstmate --prompt "x" \
        --status needs-review --plan "Reserve fixed addresses for the six lights." | awk '{print $1}')

  # Approving wording the card does not carry is refused as a conflict, and
  # records nothing at all.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/approve-plan" -H 'Content-Type: application/json' \
    -d '{"plan":"Something he was never shown."}')
  [ "$code" = "409" ] || fail "approving text that does not match the card was not refused as a conflict (got HTTP $code)"
  json=$("$DASH" show "$id" --json)
  [ "$(printf '%s' "$json" | jq -r '.plan_approved')" = "false" ] \
    || fail "a refused approval was recorded anyway"

  # Naming no wording at all is refused too - that is the same drift with the
  # check simply omitted.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/approve-plan" -H 'Content-Type: application/json' -d '{}')
  [ "$code" = "400" ] || fail "approving without naming the displayed plan was accepted (got HTTP $code)"

  # The exact displayed text is approved, and both the approval and the text
  # it is bound to are readable back.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/approve-plan" -H 'Content-Type: application/json' \
    -d '{"plan":"Reserve fixed addresses for the six lights."}')
  [ "$code" = "200" ] || fail "approving the displayed plan failed (got HTTP $code)"
  json=$("$DASH" show "$id" --json)
  [ "$(printf '%s' "$json" | jq -r '.plan_approved')" = "true" ] || fail "the approval was not recorded"
  [ "$(printf '%s' "$json" | jq -r '.plan_approval_stale')" = "false" ] \
    || fail "a fresh approval was reported as stale"
  [ "$(printf '%s' "$json" | jq -r '.plan_approved_text')" = "Reserve fixed addresses for the six lights." ] \
    || fail "the approval did not record the verbatim text it was given for"
  [ -n "$(printf '%s' "$json" | jq -r '.plan_approved_at // empty')" ] || fail "the approval recorded no time"
  assert_contains "$("$DASH" show "$id")" "APPROVAL: he approved this exact plan" \
    "show did not report a current approval"

  # Editing the plan must not carry the approval over. The record of his word
  # survives - it is never destroyed - but it is reported as covering the old
  # wording only, and both texts are visible.
  "$DASH" plan "$id" "Change the software to find devices by hardware ID." >/dev/null \
    || fail "could not edit the plan"
  json=$("$DASH" show "$id" --json)
  [ "$(printf '%s' "$json" | jq -r '.plan_approved')" = "true" ] \
    || fail "editing the plan destroyed the record that he had approved something"
  [ "$(printf '%s' "$json" | jq -r '.plan_approval_stale')" = "true" ] \
    || fail "an approval silently carried over onto plan text he never read"
  [ "$(printf '%s' "$json" | jq -r '.plan_approved_text')" = "Reserve fixed addresses for the six lights." ] \
    || fail "the bound text changed when the plan was edited"
  local out
  out=$("$DASH" show "$id")
  assert_contains "$out" "that approval covers the OLD wording only" \
    "show did not say plainly that the approval no longer covers the displayed plan"
  assert_contains "$out" "approved wording: Reserve fixed addresses" \
    "show did not render the wording he actually approved"

  # And the approval is consent, not execution: the card has not moved.
  assert_contains "$out" "status:   needs_review" \
    "approving a plan moved the card by itself - it must record consent and nothing else"

  pass "an approval binds to the verbatim plan it was given for, is refused against any other text, and never drifts onto an edited plan"
}

# Regression: the CLI and the raw API do not trim a plan, so a plan could be
# stored with surrounding whitespace while the approval recorded the text as
# displayed. The two then never compared equal and the card was permanently
# approved-and-stale, showing him two identical-looking texts with no way out.
test_a_plan_stored_with_surrounding_whitespace_can_still_be_approved() {
  local id json plan code
  id=$("$DASH" add --title "Padded plan" --captain firstmate --prompt "x" \
        --status needs-review --plan "   Swap the vendor and re-run the checks.  " | awk '{print $1}')
  json=$("$DASH" show "$id" --json)
  plan=$(printf '%s' "$json" | jq -r '.review_plan')
  [ "$plan" = "Swap the vendor and re-run the checks." ] \
    || fail "the card did not store one normalization of the plan: [$plan]"

  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/approve-plan" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg p "$plan" '{plan:$p}')")
  [ "$code" = "200" ] || fail "approving the plan exactly as displayed failed (got HTTP $code)"
  json=$("$DASH" show "$id" --json)
  [ "$(printf '%s' "$json" | jq -r '.plan_approved')" = "true" ] || fail "the approval was not recorded"
  [ "$(printf '%s' "$json" | jq -r '.plan_approval_stale')" = "false" ] \
    || fail "an approval of the plan as displayed was reported as covering different wording"
  assert_contains "$("$DASH" show "$id")" "APPROVAL: he approved this exact plan" \
    "show reported a card as stale that was approved with the text it displays"

  # Re-writing the same plan with different padding is the same plan, so his
  # approval still covers it.
  "$DASH" plan "$id" "  Swap the vendor and re-run the checks. " >/dev/null \
    || fail "could not rewrite the plan"
  json=$("$DASH" show "$id" --json)
  [ "$(printf '%s' "$json" | jq -r '.plan_approval_stale')" = "false" ] \
    || fail "re-writing the identical plan invalidated an approval that still covers it"

  # And the safety direction is untouched: genuinely different wording is
  # still stale, and approving text the card no longer carries is still 409.
  "$DASH" plan "$id" "Keep the vendor and re-run the checks." >/dev/null \
    || fail "could not edit the plan"
  [ "$(printf '%s' "$("$DASH" show "$id" --json)" | jq -r '.plan_approval_stale')" = "true" ] \
    || fail "an approval drifted onto genuinely different wording"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/approve-plan" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg p "$plan" '{plan:$p}')")
  [ "$code" = "409" ] || fail "approving wording the card no longer carries was not refused (got HTTP $code)"

  pass "a plan is stored under one normalization, so approving it exactly as displayed binds cleanly while different wording still reads stale"
}

# An unquoted multi-word plan would otherwise be recorded as its first word
# alone, and his approval would bind perfectly to that fragment.
test_plan_refuses_unquoted_extra_arguments_rather_than_truncating() {
  local id out rc
  id=$("$DASH" add --title "Quoting guard" --captain firstmate --prompt "x" \
        --status needs-review --plan "Order the replacement switch." | awk '{print $1}')
  out=$("$DASH" plan "$id" swap the vendor 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unquoted multi-word plan was accepted and silently truncated"
  assert_contains "$out" "quote" "the refusal did not point at quoting the plan text"
  [ "$(printf '%s' "$("$DASH" show "$id" --json)" | jq -r '.review_plan')" = "Order the replacement switch." ] \
    || fail "a refused plan call changed the card's plan anyway"

  pass "plan refuses an unquoted multi-word plan instead of recording its first word"
}

# The plan and the approval deliberately outlive the needs_review status,
# unlike the two reason columns. Work happens AFTER he approves, so the fleet
# has to still be able to read what he authorised while it is acting on it.
test_the_plan_and_its_approval_survive_leaving_needs_review() {
  local id json
  id=$("$DASH" add --title "Approval survives" --captain firstmate --prompt "x" \
        --status needs-review --plan "Print the six tags face down." | awk '{print $1}')
  curl -sS -o /dev/null -X POST "http://127.0.0.1:$PORT/api/tasks/$id/approve-plan" \
    -H 'Content-Type: application/json' -d '{"plan":"Print the six tags face down."}'

  "$DASH" status "$id" working >/dev/null || fail "could not advance the approved card"
  json=$("$DASH" show "$id" --json)
  [ "$(printf '%s' "$json" | jq -r '.review_plan')" = "Print the six tags face down." ] \
    || fail "the plan was destroyed when the card advanced - the fleet can no longer read what it is acting on"
  [ "$(printf '%s' "$json" | jq -r '.plan_approved')" = "true" ] \
    || fail "his approval was destroyed the moment work started under it"
  [ "$(printf '%s' "$json" | jq -r '.plan_approval_stale')" = "false" ] \
    || fail "an untouched plan was reported as no longer approved"

  pass "a card's recommended plan and his approval of it survive the status change, so the fleet can still read its authority while acting"
}

# Regression: needs_action and needs_review are both louder than everything
# else, and needs_action leads because it is the one he cannot clear from his
# phone in a second.
test_both_blocking_statuses_sort_above_the_rest_with_needs_action_first() {
  local review_id action_id working_id order
  working_id=$("$DASH" add --title "ZZZ sorting working" --captain firstmate --prompt "x" --status working | awk '{print $1}')
  review_id=$("$DASH" add --title "ZZZ sorting review" --captain firstmate --prompt "x" \
        --status needs-review --plan "Approve the vendor swap." | awk '{print $1}')
  action_id=$("$DASH" add --title "ZZZ sorting action" --captain firstmate --prompt "x" \
        --status needs-action --reason "sign the updated contractor agreement" | awk '{print $1}')

  order=$("$DASH" list --sort status | awk '{print $1}')
  local first second
  first=$(printf '%s\n' "$order" | grep -nE "^($action_id|$review_id|$working_id)$" | head -1 | cut -d: -f2-)
  second=$(printf '%s\n' "$order" | grep -nE "^($action_id|$review_id|$working_id)$" | sed -n 2p | cut -d: -f2-)
  [ "$first" = "$action_id" ] \
    || fail "needs-action did not sort first (got $first)"
  [ "$second" = "$review_id" ] \
    || fail "needs-review did not sort second, above ordinary work (got $second)"

  pass "needs-action sorts above needs-review, and both sort above ordinary work"
}


# The needs-action/needs-review split has to move his live board without
# losing a card, a reason, or a history entry. Proved against a database in
# the real PRE-SPLIT shape - the old column name included - because that is
# what the migration actually meets, and a fresh schema would prove nothing.
test_the_needs_attention_split_migrates_every_card_losing_nothing() {
  local mig_home mig_db mig_port mig_url out
  # Under $FM_HOME so the suite's own cleanup takes it, exactly like the
  # testing/review migration case above.
  mig_home="$FM_HOME/split-migration-case"
  mkdir -p "$mig_home/data" "$mig_home/state"
  mig_db="$mig_home/data/dashboard.db"

  python3 - "$mig_db" <<'SPLIT_SEED'
import sqlite3, sys

# The exact pre-split schema: status needs_attention, ask parked in a column
# called needs_attention_reason.
conn = sqlite3.connect(sys.argv[1])
conn.executescript("""
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, agent TEXT NOT NULL DEFAULT '',
  captain TEXT NOT NULL, status TEXT NOT NULL, waiting_on_id TEXT, waiting_reason TEXT,
  needs_attention_reason TEXT, starred INTEGER NOT NULL DEFAULT 0, backlog_ref TEXT,
  initial_prompt TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL REFERENCES tasks(id),
  tab TEXT NOT NULL, author TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', link_url TEXT,
  link_label TEXT, created_at TEXT NOT NULL);
CREATE TABLE status_history (id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL REFERENCES tasks(id), from_status TEXT, to_status TEXT NOT NULL,
  changed_at TEXT NOT NULL, note TEXT);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
""")
ts = "2020-01-02T03:04:05Z"
for tid, status, reason in (
    ("presplit-blocked-1", "needs_attention", "pick red or blue for the trim"),
    ("presplit-blocked-2", "needs_attention", "sign the updated contractor agreement"),
    ("presplit-done-1", "review", None),
):
    conn.execute(
        """INSERT INTO tasks (id, title, agent, captain, status, needs_attention_reason,
           initial_prompt, created_at, updated_at) VALUES (?, ?, '', 'firstmate', ?, ?, 'seed prompt', ?, ?)""",
        (tid, "Pre-split " + tid, status, reason, ts, ts))
    conn.execute("INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)"
                 " VALUES (?, NULL, 'not_started', ?, 'created')", (tid, ts))
    conn.execute("INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)"
                 " VALUES (?, 'not_started', ?, ?, ?)", (tid, status, ts, reason))
conn.execute("INSERT INTO notes (task_id, tab, author, text, created_at)"
             " VALUES ('presplit-blocked-1', 'communication', 'admiral', 'a note that must survive', ?)", (ts,))
conn.commit()
conn.close()
SPLIT_SEED

  mig_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
    || fail "could not allocate a port for the split migration case"
  mig_url="http://127.0.0.1:$mig_port"

  FM_HOME="$mig_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$mig_port" FM_DASHBOARD_DB="$mig_db" \
    "$DASH" start >"$mig_home/start.out" 2>&1 \
    || { cat "$mig_home/start.out" >&2; fail "split-migration server did not start"; }
  MIGRATION_SERVER_PID=$(cat "$mig_home/state/dashboard.pid" 2>/dev/null)
  [ -n "$MIGRATION_SERVER_PID" ] || fail "no pid recorded after split-migration server start"

  # Card for card: the count is unchanged and nothing landed anywhere but
  # needs_action. Nothing may reach needs_review - no pre-split card has a
  # plan, and inventing one would be fabricating a recommendation.
  [ "$(FM_DASHBOARD_URL="$mig_url" "$DASH" list --json | jq -r '.tasks | length')" = "3" ] \
    || fail "the split migration changed the number of cards on the board"
  [ "$(FM_DASHBOARD_URL="$mig_url" "$DASH" list --status needs-action --json | jq -r '.tasks | length')" = "2" ] \
    || fail "both pre-split needs_attention cards did not land in needs_action"
  [ "$(FM_DASHBOARD_URL="$mig_url" "$DASH" list --status needs-review --json | jq -r '.tasks | length')" = "0" ] \
    || fail "the migration invented a recommended plan and routed a card to needs_review"
  assert_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-done-1)" "status:   review" \
    "the migration touched a card that was never needs_attention"

  # Every reason survives, under the renamed column.
  out=$(FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-blocked-1)
  assert_contains "$out" "needs action: pick red or blue for the trim" \
    "a migrated card lost the ask it was carrying"
  assert_contains "$(FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-blocked-2)" \
    "needs action: sign the updated contractor agreement" "a migrated card lost the ask it was carrying"

  # History and notes are untouched. The old spelling STAYS in status_history:
  # the board really did say needs_attention then, and rewriting or appending
  # would reset the card's blocked-age, which is what the auditor reads.
  FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-blocked-1 --json \
    | jq -e '[.status_history[]] | length == 2' >/dev/null \
    || fail "the split migration added or removed status history entries"
  FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-blocked-1 --json \
    | jq -e '[.status_history[] | select(.to_status == "needs_attention" and .changed_at == "2020-01-02T03:04:05Z")] | length == 1' >/dev/null \
    || fail "the migration rewrote or reset the history row the card's blocked-age is read from"
  FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-blocked-1 --json \
    | jq -e '[.notes[]] | length == 1' >/dev/null || fail "the split migration lost a note"

  # A mechanical relabel is not his work changing.
  [ "$(FM_DASHBOARD_URL="$mig_url" "$DASH" show presplit-blocked-1 --json | jq -r '.updated_at')" = "2020-01-02T03:04:05Z" ] \
    || fail "the split migration bumped updated_at and would reorder his default board view"

  # It says what it did rather than running silently.
  out=$(cat "$mig_home/state/dashboard.log")
  assert_contains "$out" "migrated 2 card(s) from needs_attention to needs_action" \
    "the server did not report the split migration it performed"
  assert_contains "$out" "presplit-blocked-1" "the startup report does not name the cards it moved"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""

  # A second start must not report again, and must leave everything alone.
  FM_HOME="$mig_home" FM_DASHBOARD_HOST=127.0.0.1 FM_DASHBOARD_PORT="$mig_port" FM_DASHBOARD_DB="$mig_db" \
    "$DASH" start >"$mig_home/restart.out" 2>&1 \
    || { cat "$mig_home/restart.out" >&2; fail "split-migration server did not restart"; }
  MIGRATION_SERVER_PID=$(cat "$mig_home/state/dashboard.pid" 2>/dev/null)
  assert_not_contains "$(cat "$mig_home/state/dashboard.log")" "migrated 2 card(s) from needs_attention" \
    "a later start re-ran the split migration over an already-migrated database"
  [ "$(FM_DASHBOARD_URL="$mig_url" "$DASH" list --status needs-action --json | jq -r '.tasks | length')" = "2" ] \
    || fail "a restart disturbed the migrated cards"

  stop_dashboard_server "$MIGRATION_SERVER_PID"
  MIGRATION_SERVER_PID=""

  pass "the needs-attention split migrates every card to needs-action, keeping its reason, notes, history, and blocked-age, and runs once"
}

test_health_and_server_status
test_add_and_list_round_trip
test_status_and_captain_and_title_updates
test_testing_and_review_are_distinct_statuses
test_waiting_status_carries_target_and_reason
test_notes_tabs_and_empty_tab_semantics
test_link_policy_rejects_github_and_localhost
test_needs_action_status_carries_reason_and_sorts_first
test_needs_action_requires_a_real_ask
test_no_path_can_set_needs_action_without_an_ask
test_needs_attention_is_an_accepted_input_alias_and_never_an_output
test_needs_review_without_a_plan_is_refused_everywhere
test_an_approval_binds_to_the_plan_text_it_was_given_for
test_the_plan_and_its_approval_survive_leaving_needs_review
test_a_plan_stored_with_surrounding_whitespace_can_still_be_approved
test_plan_refuses_unquoted_extra_arguments_rather_than_truncating
test_both_blocking_statuses_sort_above_the_rest_with_needs_action_first
test_the_needs_attention_split_migrates_every_card_losing_nothing
test_a_genuine_ask_mentioning_a_report_word_is_accepted
test_add_refuses_a_reason_for_a_status_that_cannot_carry_one
test_documented_guard_rates_still_hold
test_audit_log_run_and_interval
test_bad_input_fails_with_nonzero_exit
test_help_prints_the_whole_header_through_its_last_block
test_calls_are_bounded_against_a_board_that_never_answers
test_zero_timeout_override_is_refused_like_any_other_unusable_one
test_missing_id_and_unreachable_board_have_distinct_exit_codes
test_testing_to_review_split_migration_runs_once
test_a_start_that_cannot_bind_leaves_the_migration_pending
test_restart_recovers_from_a_crashed_or_stopped_board
test_lifecycle_commands_refuse_a_recycled_pid
test_star_and_delete
test_the_captain_set_agrees_across_every_surface
