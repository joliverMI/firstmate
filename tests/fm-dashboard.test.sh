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

test_needs_attention_status_carries_reason_and_sorts_first() {
  local id working_id out
  id=$("$DASH" add --title "Needs a decision" --captain firstmate --prompt "checking needs-attention" | awk '{print $1}')
  working_id=$("$DASH" add --title "Being actively worked" --captain firstmate --prompt "sort-order control" --status working | awk '{print $1}')

  "$DASH" status "$id" needs-attention --reason "pick red or blue for the trim" >/dev/null \
    || fail "status transition to needs-attention failed"
  out=$("$DASH" show "$id")
  assert_contains "$out" "status:   needs_attention" "needs-attention status did not persist"
  assert_contains "$out" "needs attention: pick red or blue for the trim" "needs-attention reason did not persist"

  local first_id
  first_id=$("$DASH" list --sort status | head -n1 | awk '{print $1}')
  [ "$first_id" = "$id" ] || fail "needs-attention ($id) did not sort above a working card ($working_id) under --sort status, got: $first_id"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-attention failed"
  assert_not_contains "$("$DASH" show "$id")" "needs attention:" "needs-attention reason was not cleared on status change"

  pass "needs-attention status carries a reason and sorts above every other status"
}

test_needs_attention_requires_a_real_ask() {
  local id out rc
  id=$("$DASH" add --title "Reason guard coverage" --captain firstmate --prompt "checking the needs-attention guard" | awk '{print $1}')

  # The CLI refuses locally, before any network round-trip, on the obvious
  # missing-reason case.
  out=$("$DASH" status "$id" needs-attention 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "needs-attention with no --reason was accepted"
  assert_contains "$out" "requires --reason" "missing-reason rejection did not explain the requirement"

  # The server enforces the same rule structurally, not just the CLI's
  # local check: a direct call with an empty reason must also be refused.
  local raw_code
  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks/$id/status" \
    -H 'Content-Type: application/json' -d '{"status":"needs_attention"}')
  [ "$raw_code" = "400" ] || fail "the API accepted needs_attention with no reason (got HTTP $raw_code)"

  # A reason that only reports progress is refused too, even though it is
  # non-empty.
  out=$("$DASH" status "$id" needs-attention --reason "You reported flares not changing the lights - being chased now" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a report-shaped needs-attention reason was accepted"
  assert_contains "$out" "reads as a progress report" "report-shaped rejection did not explain why"

  # A genuine ask is accepted and persists.
  "$DASH" status "$id" needs-attention --reason "approve the trim color before the install" >/dev/null \
    || fail "a genuine ask was rejected as report-shaped"
  assert_contains "$("$DASH" show "$id")" "needs attention: approve the trim color before the install" \
    "a genuine ask did not persist after the guard ran"

  # Creating a card straight into needs-attention is governed the same way.
  out=$("$DASH" add --title "Bad create" --captain firstmate --prompt "x" --status needs-attention 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs-attention with no --reason was accepted"
  assert_contains "$out" "requires --reason" "add's missing-reason rejection did not explain the requirement"

  out=$("$DASH" add --title "Reporty create" --captain firstmate --prompt "x" \
    --status needs-attention --reason "looking into the checkout timeout" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "add --status needs-attention with a report-shaped reason was accepted"
  assert_contains "$out" "reads as a progress report" "add's report-shaped rejection did not explain why"

  # And the create path is enforced by the server itself, not only by the
  # CLI's local pre-check - the same treatment the status path gets above.
  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Direct bad create","captain":"firstmate","initial_prompt":"x","status":"needs_attention"}')
  [ "$raw_code" = "400" ] || fail "the API accepted a created needs_attention card with no reason (got HTTP $raw_code)"

  raw_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/api/tasks" -H 'Content-Type: application/json' \
    -d '{"title":"Direct reporty create","captain":"firstmate","initial_prompt":"x","status":"needs_attention","reason":"still chasing the supplier"}')
  [ "$raw_code" = "400" ] || fail "the API accepted a created needs_attention card with a report-shaped reason (got HTTP $raw_code)"

  local created
  created=$("$DASH" add --title "Good create" --captain firstmate --prompt "x" \
    --status needs-attention --reason "sign the updated contractor agreement" | awk '{print $1}')
  [ -n "$created" ] || fail "add --status needs-attention with a real ask should have succeeded"
  assert_contains "$("$DASH" show "$created")" "needs attention: sign the updated contractor agreement" \
    "a card created straight into needs-attention did not carry its reason"

  pass "needs-attention refuses a missing or report-shaped reason, on both status and add, and the server enforces both independently of the CLI"
}

# A genuine ask that merely mentions one of the report phrases mid-sentence
# ("approve the $400 monitoring subscription renewal") must still reach the
# board: refusing it leaves the card stuck in `working` and never asks him,
# which is the inverse of the failure the guard exists to prevent.
test_a_genuine_ask_mentioning_a_report_word_is_accepted() {
  local id
  id=$("$DASH" add --title "Mid-sentence report word" --captain firstmate --prompt "checking edge anchoring" | awk '{print $1}')

  "$DASH" status "$id" needs-attention --reason "approve the \$400 monitoring subscription renewal" >/dev/null \
    || fail "a genuine ask containing 'monitoring' mid-sentence was refused"
  assert_contains "$("$DASH" show "$id")" "monitoring subscription renewal" \
    "the accepted mid-sentence ask did not persist"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-attention failed"
  "$DASH" status "$id" needs-attention --reason "pick which contractor keeps working on the deck" >/dev/null \
    || fail "a genuine ask containing 'working on' mid-sentence was refused"

  "$DASH" status "$id" working >/dev/null || fail "leaving needs-attention failed"
  "$DASH" status "$id" needs-attention --reason "approve the invoice for the in progress work" >/dev/null \
    || fail "a genuine ask containing 'in progress' mid-sentence was refused"

  pass "a report phrase buried mid-clause does not refuse a genuine ask"
}

# docs/dashboard.md publishes exact catch/miss/false-positive counts for this
# guard, and the fleet auditor is told to compensate for precisely that
# documented blind spot. Pin the numbers to executed behaviour so narrowing or
# extending REPORT_SHAPED_PHRASES cannot silently make the prose false.
test_documented_guard_rates_still_hold() {
  python3 - "$ROOT/bin/fleet-dashboard/server" <<'GUARD_RATES' || fail "the documented needs-attention guard rates no longer hold"
import sys

sys.path.insert(0, sys.argv[1])
from validation import InvalidReasonError, validate_needs_attention_reason

# The three corpora documented in docs/dashboard.md, "The needs-attention
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
    "We are investigating the checkout timeout",
    "I was digging into the bounced payouts",
    "We were keeping an eye on the disk usage",
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
]


def refused(reason):
    try:
        validate_needs_attention_reason(reason)
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
if counts != (18, 0, 0):
    failures.append(
        f"documented rates drifted: caught/missed/false-positive counts are {counts}, "
        "docs/dashboard.md says 18/18 caught, 0/12 reworded caught, 0/12 false positives"
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

test_health_and_server_status
test_add_and_list_round_trip
test_status_and_captain_and_title_updates
test_testing_and_review_are_distinct_statuses
test_waiting_status_carries_target_and_reason
test_notes_tabs_and_empty_tab_semantics
test_link_policy_rejects_github_and_localhost
test_needs_attention_status_carries_reason_and_sorts_first
test_needs_attention_requires_a_real_ask
test_a_genuine_ask_mentioning_a_report_word_is_accepted
test_documented_guard_rates_still_hold
test_audit_log_run_and_interval
test_bad_input_fails_with_nonzero_exit
test_calls_are_bounded_against_a_board_that_never_answers
test_zero_timeout_override_is_refused_like_any_other_unusable_one
test_missing_id_and_unreachable_board_have_distinct_exit_codes
test_testing_to_review_split_migration_runs_once
test_a_start_that_cannot_bind_leaves_the_migration_pending
test_restart_recovers_from_a_crashed_or_stopped_board
test_lifecycle_commands_refuse_a_recycled_pid
test_star_and_delete
