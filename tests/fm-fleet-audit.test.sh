#!/usr/bin/env bash
# tests/fm-fleet-audit.test.sh - end-to-end coverage for the fleet auditor's
# timer plumbing: the sweep lock, the tick script's due/not-due decision, the
# sweep script's mechanical checks, and the Force Audit button's HTTP
# endpoint. A real dashboard server process, driven only through
# bin/fm-dashboard.sh, the scripts under test, and the HTTP API they wrap -
# no test here asserts on implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "skipped - jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

DASH="$ROOT/bin/fm-dashboard.sh"
TICK="$ROOT/bin/fm-fleet-audit-tick.sh"
SWEEP="$ROOT/bin/fm-fleet-audit-sweep.sh"
SERVER_PID=""

fm_fleet_audit_test_cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  fm_test_cleanup
}
trap fm_fleet_audit_test_cleanup EXIT
trap 'fm_fleet_audit_test_cleanup; exit 130' INT
trap 'fm_fleet_audit_test_cleanup; exit 143' TERM

FM_HOME=$(fm_test_tmproot fm-fleet-audit-test) || fail "could not create temp FM_HOME"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
export FM_HOME
# Shrunk from the real 600s so the stale-lock self-heal path (a crashed sweep
# never released its claim) can be proven without a real 10-minute wait.
export FM_AUDIT_MAX_SWEEP_SECONDS=2
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
  || fail "could not allocate a free port"
export FM_DASHBOARD_HOST=127.0.0.1
export FM_DASHBOARD_PORT="$PORT"
BASE="http://127.0.0.1:$PORT"

"$DASH" start >"$FM_HOME/start.out" 2>&1 || { cat "$FM_HOME/start.out" >&2; fail "server did not start"; }
SERVER_PID=$(cat "$FM_HOME/state/dashboard.pid" 2>/dev/null)
[ -n "$SERVER_PID" ] || fail "no pid recorded after start"

audit_status_json() { "$DASH" audit-status --json; }

# How many discrepancy entries the Admiral-facing log currently carries for one
# card - the log is the observable output of the sweep, so the count is what a
# "flagged once, not once per sweep" claim actually means.
discrepancy_count_for() {  # <task_id>
  audit_status_json | jq --arg t "$1" '[.log[] | select(.task_id==$t and .kind=="discrepancy")] | length'
}

# Narrower: only the entries the not-started check itself writes, told apart by
# the opening the audit log actually carries for them. Lets a test say "this
# finding was raised" without an unrelated finding on the same card counting.
not_started_finding_count_for() {  # <task_id>
  audit_status_json | jq --arg t "$1" \
    '[.log[] | select(.task_id==$t and .kind=="discrepancy" and (.text | startswith("still not_started, but")))] | length'
}

# Full rows (occurrences, last_seen_at, key) for one task's discrepancies -
# what the general collapse-mechanism tests below inspect beyond mere count.
discrepancy_rows_for() {  # <task_id>
  audit_status_json | jq --arg t "$1" '[.log[] | select(.task_id==$t and .kind=="discrepancy")]'
}

test_claim_is_exclusive_and_release_frees_it() {
  "$DASH" audit-claim --json >"$FM_HOME/claim1.json" || fail "first claim failed"
  assert_contains "$(cat "$FM_HOME/claim1.json")" '"claimed": true' "first claim was not granted"

  if "$DASH" audit-claim >/dev/null 2>&1; then
    fail "a second claim while the first is still held should have been refused"
  fi
  assert_contains "$(audit_status_json)" '"running": true' "lock does not show as running after a claim"

  "$DASH" audit-release >/dev/null || fail "release failed"
  assert_contains "$(audit_status_json)" '"running": false' "lock still shows running after release"

  "$DASH" audit-claim >/dev/null || fail "a claim after release should succeed"
  "$DASH" audit-release >/dev/null || fail "cleanup release failed"
  pass "the sweep lock is exclusive and release frees it for the next claim"
}

test_audit_run_forced_flag_and_auto_release() {
  "$DASH" audit-claim --forced >/dev/null || fail "forced claim failed"
  "$DASH" audit-run --duration-seconds 0.5 --checked 4 --discrepancies 1 --forced >/dev/null \
    || fail "audit-run failed"

  local status
  status=$(audit_status_json)
  assert_contains "$status" '"forced": 1' "recorded run did not carry the forced flag"
  assert_contains "$status" '"running": false' "recording a completed run did not release the lock"
  pass "audit-run records the forced flag and releases the lock as part of recording"
}

test_audit_tick_heartbeat_and_due_interval() {
  "$DASH" audit-interval 60 >/dev/null || fail "could not set the interval"

  "$TICK" || fail "first tick failed"
  local status first_completed
  status=$(audit_status_json)
  assert_not_contains "$status" '"last_tick_at": null' "first tick did not record a heartbeat"
  first_completed=$(printf '%s' "$status" | jq -r '.last_run.completed_at // empty')
  [ -n "$first_completed" ] || fail "first tick (no prior run) should have run a sweep immediately"

  "$TICK" || fail "second tick failed"
  local second_completed
  second_completed=$(audit_status_json | jq -r '.last_run.completed_at // empty')
  [ "$second_completed" = "$first_completed" ] \
    || fail "a tick inside the interval window ran a second sweep - due-ness is not honoring the interval"
  pass "the tick script heartbeats every invocation and only sweeps once the interval has elapsed"
}

# Regression: before the testing/review split, `testing` was optional and
# inert, and the sweep never looked at it at all. It now gets the exact same
# live-crew corroboration as `working` (docs/dashboard.md "Why `testing`
# split into `testing` and `review`") - a `testing` card is counted, and a
# card with no backlog_ref is unverifiable from here and must not be flagged
# (skill point 8, same rule `working` already gets).
test_sweep_counts_testing_cards_and_never_flags_an_unverifiable_one() {
  # Two forced sweeps back to back, with only the new card added in between,
  # so the checked-count delta is attributable to that one card alone rather
  # than whatever the rest of the suite has put on the board by this point.
  "$SWEEP" --forced || fail "baseline sweep exited non-zero"
  local before_checked before_log id after_checked after_log
  before_checked=$(audit_status_json | jq -r '.last_run.tasks_checked')

  id=$("$DASH" add --title "Live testing, no ref" --captain firstmate --prompt "testing coverage" \
    --status testing | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the testing card"
  before_log=$(audit_status_json | jq '[.log[] | select(.task_id=="'"$id"'")] | length')

  "$SWEEP" --forced || fail "sweep script exited non-zero"

  after_checked=$(audit_status_json | jq -r '.last_run.tasks_checked')
  after_log=$(audit_status_json | jq '[.log[] | select(.task_id=="'"$id"'")] | length')
  [ "$after_checked" -eq $((before_checked + 1)) ] \
    || fail "expected exactly one more checked card (the new testing one), before=$before_checked after=$after_checked"
  [ "$after_log" = "$before_log" ] || fail "a testing card with no backlog_ref was flagged, but it is not verifiable from here"
  pass "the sweep checks testing cards and never flags one it cannot verify"
}

# The flagging half of the shared live-crew check: a card whose backlog_ref
# names a local task whose crew-state reads a definite non-working state must
# produce a discrepancy. Run for both statuses that use the helper - `testing`
# is the new caller, `working` the pre-existing one - so the branch this split
# exists for is proven, not just its skip paths.
make_crew_state_case() {  # <crew-id> <status-log-line> - a meta/status pair
  # that makes bin/fm-crew-state.sh report a definite, non-working state with
  # no tmux, git or no-mistakes dependency: kind=secondmate skips the run
  # lookup and the busy probe, remote_host skips the local endpoint probe, so
  # the status log's own verb is the answer.
  local crew_id=$1 log_line=$2
  mkdir -p "$FM_HOME/wt-$crew_id"
  fm_write_meta "$FM_HOME/state/$crew_id.meta" \
    "window=remote:$crew_id" \
    "endpoint_task_id=$crew_id" \
    "worktree=$FM_HOME/wt-$crew_id" \
    "kind=secondmate" \
    "remote_host=elsewhere"
  printf '%s\n' "$log_line" > "$FM_HOME/state/$crew_id.status"
}

test_sweep_flags_a_live_crew_status_whose_linked_crew_is_not_working() {
  local status crew_id card_id state_line flagged
  for status in testing working; do
    crew_id="audit-crew-$status"
    make_crew_state_case "$crew_id" "blocked: upstream API is down"
    state_line=$("$ROOT/bin/fm-crew-state.sh" "$crew_id")
    case "$state_line" in
      "state: blocked"*) ;;
      *) fail "fixture did not produce a blocked crew state for $crew_id: $state_line" ;;
    esac

    card_id=$("$DASH" add --title "Linked $status card" --captain firstmate \
      --prompt "$status corroboration" --status "$status" --ref "$crew_id" | awk '{print $1}')
    [ -n "$card_id" ] || fail "could not add the $status card"

    "$SWEEP" --forced || fail "sweep script exited non-zero for $status"

    flagged=$(audit_status_json \
      | jq -r '[.log[] | select(.task_id=="'"$card_id"'" and .kind=="discrepancy") | .text] | join(" | ")')
    case "$flagged" in
      *"card claims $status"*"blocked"*) ;;
      *) fail "a $status card whose linked crew reads blocked was not flagged; log entries: ${flagged:-<none>}" ;;
    esac

    # Leave the board clean for the next status so the following iteration and
    # the later checked-count assertions are not perturbed by this card.
    "$DASH" status "$card_id" complete >/dev/null || fail "could not clear the $status card"
  done
  pass "the sweep flags a working or testing card whose linked crew is demonstrably not working"
}

# The general collapse mechanism (fm-dashboard.sh audit-log --key,
# store.py's record_audit_finding) proved through a real recurring check -
# the live-crew corroboration checks 1/2 use it, unlike not_started's own
# older, bespoke suppression already covered above. This is the "repeat
# collapses" half.
test_a_recurring_identical_finding_collapses_into_one_row_with_a_growing_count() {
  local crew_id card_id rows count first_seen last_seen
  crew_id="audit-collapse-repeat"
  make_crew_state_case "$crew_id" "blocked: upstream API is down"
  card_id=$("$DASH" add --title "Repeatedly blocked working card" --captain firstmate \
    --prompt "collapse test" --status working --ref "$crew_id" | awk '{print $1}')
  [ -n "$card_id" ] || fail "could not add the working card"

  "$SWEEP" --forced || fail "first sweep exited non-zero"
  [ "$(discrepancy_count_for "$card_id")" -eq 1 ] || fail "the first sweep did not log exactly one row"
  first_seen=$(discrepancy_rows_for "$card_id" | jq -r '.[0].created_at')

  sleep 1
  "$SWEEP" --forced || fail "second sweep exited non-zero"
  sleep 1
  "$SWEEP" --forced || fail "third sweep exited non-zero"

  rows=$(discrepancy_rows_for "$card_id")
  count=$(printf '%s' "$rows" | jq 'length')
  [ "$count" -eq 1 ] \
    || fail "three sweeps of one standing condition produced $count rows, expected a single collapsed row"
  [ "$(printf '%s' "$rows" | jq -r '.[0].occurrences')" -eq 3 ] \
    || fail "expected the collapsed row's seen-count to be 3 after three sweeps, got $(printf '%s' "$rows" | jq -r '.[0].occurrences')"
  last_seen=$(printf '%s' "$rows" | jq -r '.[0].last_seen_at')
  [ "$last_seen" \> "$first_seen" ] \
    || fail "the collapsed row's last-seen time did not advance across sweeps ($first_seen -> $last_seen)"

  "$DASH" status "$card_id" complete >/dev/null || fail "could not clear the test card"
  pass "a recurring identical finding updates one row's last-seen time and seen-count instead of appending"
}

# The "genuinely new finding" half: a different card hitting the same check
# must never collapse onto another card's row just because the finding looks
# similar - collapsing is scoped to the task, not merely to the check.
test_a_genuinely_new_finding_on_a_different_card_does_not_collapse() {
  local crew_a crew_b card_a card_b
  crew_a="audit-collapse-new-a"; crew_b="audit-collapse-new-b"
  make_crew_state_case "$crew_a" "blocked: reason a"
  make_crew_state_case "$crew_b" "blocked: reason b"
  card_a=$("$DASH" add --title "Blocked card A" --captain firstmate --prompt "a" \
    --status working --ref "$crew_a" | awk '{print $1}')
  card_b=$("$DASH" add --title "Blocked card B" --captain firstmate --prompt "b" \
    --status working --ref "$crew_b" | awk '{print $1}')
  [ -n "$card_a" ] && [ -n "$card_b" ] || fail "could not add both test cards"

  "$SWEEP" --forced || fail "sweep exited non-zero"

  [ "$(discrepancy_count_for "$card_a")" -eq 1 ] || fail "card A did not get its own row"
  [ "$(discrepancy_count_for "$card_b")" -eq 1 ] || fail "card B did not get its own row"

  "$DASH" status "$card_a" complete >/dev/null || fail "could not clear card A"
  "$DASH" status "$card_b" complete >/dev/null || fail "could not clear card B"
  pass "two genuinely different cards each get their own row rather than collapsing together"
}

# The strictness requirement: an older, unrelated finding already on the same
# card (as if left by a different check) must never be silenced, merged, or
# have its own seen-count bumped by a check it has nothing to do with - the
# same bar the not_started check's own suppression already had to clear.
test_an_unrelated_finding_on_the_same_card_never_suppresses_a_general_collapse() {
  local crew_id card_id rows
  crew_id="audit-collapse-unrelated"
  make_crew_state_case "$crew_id" "blocked: reason"
  card_id=$("$DASH" add --title "Card with an unrelated older finding" --captain firstmate \
    --prompt "unrelated" --status working --ref "$crew_id" | awk '{print $1}')
  [ -n "$card_id" ] || fail "could not add the test card"
  "$DASH" audit-log "$card_id" "an unrelated finding from a different check" --key "some-other-check" \
    >/dev/null || fail "could not seed the unrelated finding"

  "$SWEEP" --forced || fail "first sweep exited non-zero"
  "$SWEEP" --forced || fail "second sweep exited non-zero"

  rows=$(discrepancy_rows_for "$card_id")
  [ "$(printf '%s' "$rows" | jq 'length')" -eq 2 ] \
    || fail "expected exactly two rows (the seeded unrelated one plus the live-crew one), got: $rows"
  [ "$(printf '%s' "$rows" | jq -r '[.[] | select(.key=="some-other-check")] | length')" -eq 1 ] \
    || fail "the unrelated finding's own row was touched by the live-crew check"
  [ "$(printf '%s' "$rows" | jq -r '[.[] | select(.key=="some-other-check")][0].occurrences')" -eq 1 ] \
    || fail "the unrelated finding's seen-count was bumped by an unrelated check"
  [ "$(printf '%s' "$rows" | jq -r '[.[] | select(.key=="live-crew:working")][0].occurrences')" -eq 2 ] \
    || fail "the live-crew finding did not collapse across its own two sweeps"

  "$DASH" status "$card_id" complete >/dev/null || fail "could not clear the test card"
  pass "an unrelated finding on the same card is never silenced by, or merged into, a different check's collapse"
}

# The hard requirement: holding the text back must never be mistaken for the
# condition clearing. Mirrors test_a_quiet_but_outstanding_block_still_counts_
# toward_the_run_total above, but for the general mechanism rather than
# not_started's bespoke one.
test_a_collapsed_but_outstanding_finding_still_counts_and_never_reads_clean() {
  local crew_id card_id baseline first second
  "$SWEEP" --forced || fail "baseline sweep exited non-zero"
  baseline=$(audit_status_json | jq -r '.last_run.discrepancies_found')

  crew_id="audit-collapse-outstanding"
  make_crew_state_case "$crew_id" "blocked: still down"
  card_id=$("$DASH" add --title "Outstanding blocked card" --captain firstmate --prompt "outstanding" \
    --status working --ref "$crew_id" | awk '{print $1}')
  [ -n "$card_id" ] || fail "could not add the test card"

  "$SWEEP" --forced || fail "first sweep exited non-zero"
  first=$(audit_status_json | jq -r '.last_run.discrepancies_found')
  [ "$first" -eq $((baseline + 1)) ] \
    || fail "the new outstanding finding did not add exactly one to the run total (baseline=$baseline, now=$first)"
  [ "$first" -gt 0 ] || fail "a sweep with a genuine outstanding finding reported zero discrepancies"

  "$SWEEP" --forced || fail "second sweep exited non-zero"
  second=$(audit_status_json | jq -r '.last_run.discrepancies_found')
  [ "$second" -eq "$first" ] \
    || fail "a still-outstanding, now-collapsed finding stopped counting toward the run total (was $first, now $second)"
  [ "$second" -gt 0 ] \
    || fail "the run read as clean (0 discrepancies) while a collapsed finding is still outstanding"
  [ "$(discrepancy_count_for "$card_id")" -eq 1 ] \
    || fail "the second sweep appended a new row instead of collapsing into the first"

  "$DASH" status "$card_id" complete >/dev/null || fail "could not clear the test card"
  pass "a collapsed but still-outstanding finding keeps counting toward the run total and never reads clean"
}

# fail_sweep's own error entry is fleet-scoped (no card) and kind=error, so it
# collapses on a NULL task_id - a distinct SQL path from every task-scoped
# discrepancy above. It matters because a condition that fails one read while
# the small audit-log POST still lands recurs on the timer's cadence, and the
# log matters most exactly when the sweep is failing.
test_a_repeating_fleet_level_error_collapses_and_a_different_one_does_not() {
  local rows
  "$DASH" audit-log --fleet "sweep failed listing paused cards" --kind error \
    --key "fail-sweep:sweep failed listing paused cards" >/dev/null || fail "first error entry was refused"
  sleep 1
  "$DASH" audit-log --fleet "sweep failed listing paused cards" --kind error \
    --key "fail-sweep:sweep failed listing paused cards" >/dev/null || fail "repeat error entry was refused"
  "$DASH" audit-log --fleet "sweep failed reading the audit log" --kind error \
    --key "fail-sweep:sweep failed reading the audit log" >/dev/null || fail "distinct error entry was refused"

  rows=$(audit_status_json | jq '[.log[] | select(.task_id == null and .kind == "error")]')
  [ "$(printf '%s' "$rows" | jq 'length')" -eq 2 ] \
    || fail "expected the repeat to collapse and the distinct failure to stand alone, got $(printf '%s' "$rows" | jq -c '[.[] | {text, occurrences}]')"
  [ "$(printf '%s' "$rows" | jq -r '[.[] | select(.text == "sweep failed listing paused cards")] | .[0].occurrences')" -eq 2 ] \
    || fail "the repeated fleet-level failure did not collapse into one row with a growing seen-count"
  [ "$(printf '%s' "$rows" | jq -r '[.[] | select(.text == "sweep failed reading the audit log")] | .[0].occurrences')" -eq 1 ] \
    || fail "a genuinely different failure message collapsed onto an unrelated failure's row"
  pass "a repeating sweep failure updates one fleet-level row while a different failure still opens its own"
}

test_sweep_flags_waiting_on_completed_card() {
  "$DASH" audit-interval 1 >/dev/null || fail "could not reset the interval"
  local done_id waiter_id
  done_id=$("$DASH" add --title "Already finished" --captain firstmate --prompt "done card" --status complete \
    | awk '{print $1}')
  [ -n "$done_id" ] || fail "could not add the done card"
  waiter_id=$("$DASH" add --title "Stale wait" --captain firstmate --prompt "waits on a finished card" \
    | awk '{print $1}')
  "$DASH" status "$waiter_id" waiting --waiting-on "$done_id" --reason "should have cleared" >/dev/null \
    || fail "could not set waiting status"

  "$SWEEP" || fail "sweep script exited non-zero"

  local status
  status=$(audit_status_json)
  assert_contains "$status" "already complete" "sweep did not flag a card waiting on an already-complete card"
  assert_contains "$status" "$waiter_id" "discrepancy log did not name the stale-waiting card"
  pass "the sweep flags a card waiting on a card that is already complete"
}

# Regression: the sweep used to skip not_started entirely, so an approved
# card nobody ever started looked identical to one legitimately still queued.
# Age is deliberately not the signal (see the fleet-dashboard skill and the
# sweep script's own header) - only a currently-waiting card's own
# waiting_on_id naming a not-started card is a genuine, structural
# discrepancy. This is the quiet half: a not-started card nothing references
# must be counted but never flagged, the same unverifiable-stays-silent rule
# the testing-card test above already proves for a different status.
test_sweep_counts_not_started_cards_and_never_flags_an_unverifiable_one() {
  "$SWEEP" --forced || fail "baseline sweep exited non-zero"
  local before_checked before_log id after_checked after_log
  before_checked=$(audit_status_json | jq -r '.last_run.tasks_checked')

  id=$("$DASH" add --title "Queued, nothing points at it" --captain firstmate \
    --prompt "legitimately queued, not started yet" | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the not-started card"
  before_log=$(audit_status_json | jq '[.log[] | select(.task_id=="'"$id"'")] | length')

  "$SWEEP" --forced || fail "sweep script exited non-zero"

  after_checked=$(audit_status_json | jq -r '.last_run.tasks_checked')
  after_log=$(audit_status_json | jq '[.log[] | select(.task_id=="'"$id"'")] | length')
  [ "$after_checked" -eq $((before_checked + 1)) ] \
    || fail "expected exactly one more checked card (the new not-started one), before=$before_checked after=$after_checked"
  [ "$after_log" = "$before_log" ] \
    || fail "an unreferenced not-started card was flagged; age/queueing alone must not be a discrepancy"
  pass "the sweep checks not-started cards and never flags one nothing currently references"
}

# The flagging half: a not-started card that a currently-waiting card is
# genuinely blocked on - the one structural signal that a not-started card
# is stuck rather than merely queued.
test_sweep_flags_a_not_started_card_that_live_work_is_waiting_on() {
  local target_id waiter_id flagged
  target_id=$("$DASH" add --title "Approved, never started" --captain firstmate \
    --prompt "not-started target" | awk '{print $1}')
  [ -n "$target_id" ] || fail "could not add the not-started target card"
  waiter_id=$("$DASH" add --title "Blocked on the unstarted card" --captain firstmate \
    --prompt "blocked" | awk '{print $1}')
  [ -n "$waiter_id" ] || fail "could not add the waiting card"
  "$DASH" status "$waiter_id" waiting --waiting-on "$target_id" --reason "needs that work first" >/dev/null \
    || fail "could not set waiting status"

  "$SWEEP" --forced || fail "sweep script exited non-zero"

  flagged=$(audit_status_json \
    | jq -r '[.log[] | select(.task_id=="'"$target_id"'" and .kind=="discrepancy") | .text] | join(" | ")')
  case "$flagged" in
    *"not_started"*"$waiter_id"*) ;;
    *) fail "a not-started card that live work is waiting on was not flagged; log entries: ${flagged:-<none>}" ;;
  esac
  pass "the sweep flags a not-started card that a currently-waiting card is blocked on"
}

# Regression: a blocked not-started card is exactly the condition that
# legitimately persists for days, so flagging it on every sweep would fill the
# Admiral's 100-entry log with one repeating finding and bury every other one -
# the always-red-marker failure the fleet-dashboard skill exists to prevent.
# The sweep must speak once per pairing and then stay quiet while nothing
# changes, and speak again for a genuinely new pairing.
test_sweep_flags_a_blocked_not_started_card_once_not_once_per_sweep() {
  local target_id waiter_id second_target_id after_first after_second final_first final_second
  target_id=$("$DASH" add --title "Approved, never started, swept twice" --captain firstmate \
    --prompt "not-started target of a repeated sweep" | awk '{print $1}')
  [ -n "$target_id" ] || fail "could not add the not-started target card"
  waiter_id=$("$DASH" add --title "Blocked across two sweeps" --captain firstmate \
    --prompt "blocked" | awk '{print $1}')
  [ -n "$waiter_id" ] || fail "could not add the waiting card"
  "$DASH" status "$waiter_id" waiting --waiting-on "$target_id" --reason "needs that work first" >/dev/null \
    || fail "could not set waiting status"

  "$SWEEP" --forced || fail "first sweep exited non-zero"
  after_first=$(discrepancy_count_for "$target_id")
  [ "$after_first" -ge 1 ] || fail "the first sweep did not flag the blocked not-started card at all"

  # Nothing at all changes between the two sweeps: same target, same waiter,
  # same block.
  "$SWEEP" --forced || fail "second sweep exited non-zero"
  after_second=$(discrepancy_count_for "$target_id")
  [ "$after_second" -eq "$after_first" ] \
    || fail "an unchanged not-started/waiting pairing was re-logged on the next sweep (was $after_first, now $after_second)"

  # ...but a genuinely different pairing is its own finding and must still be
  # heard, so the suppression is per-pairing rather than a blanket silence.
  second_target_id=$("$DASH" add --title "A second approved, never-started card" --captain firstmate \
    --prompt "the new blocker" | awk '{print $1}')
  [ -n "$second_target_id" ] || fail "could not add the second not-started target"
  "$DASH" status "$waiter_id" waiting --waiting-on "$second_target_id" --reason "actually blocked on this one" >/dev/null \
    || fail "could not repoint the waiting card"

  "$SWEEP" --forced || fail "third sweep exited non-zero"
  final_second=$(discrepancy_count_for "$second_target_id")
  final_first=$(discrepancy_count_for "$target_id")
  [ "$final_second" -ge 1 ] \
    || fail "repointing the block at a different not-started card was never flagged"
  [ "$final_first" -eq "$after_first" ] \
    || fail "the no-longer-referenced not-started card was flagged again (was $after_first, now $final_first)"
  pass "the sweep flags a blocked not-started card once per pairing, not once per sweep"
}

# Regression: the board lets a card go back to `not_started` from any status,
# so it can arrive here still carrying a finding some earlier check raised
# about it. Keying the stay-quiet rule on the card alone made that old,
# unrelated entry silence this check for good - a card invisible by
# construction, the exact failure the not-started check exists to end.
test_an_unrelated_finding_on_the_card_does_not_silence_the_not_started_check() {
  local target_id waiter_id flagged
  target_id=$("$DASH" add --title "Put back to never-started" --captain firstmate \
    --prompt "already carries an older finding from another check" | awk '{print $1}')
  [ -n "$target_id" ] || fail "could not add the not-started target card"
  waiter_id=$("$DASH" add --title "Blocked on the card that was put back" --captain firstmate \
    --prompt "blocked" | awk '{print $1}')
  [ -n "$waiter_id" ] || fail "could not add the waiting card"
  "$DASH" status "$waiter_id" waiting --waiting-on "$target_id" --reason "needs that work first" >/dev/null \
    || fail "could not set waiting status"
  # What a card that was flagged while it claimed `working` and then reset
  # carries into not_started: a discrepancy of its own, newer than the block.
  "$DASH" audit-log "$target_id" "card claims working, but the linked crew reads: state: idle" \
    --kind discrepancy >/dev/null || fail "could not record the unrelated finding"

  "$SWEEP" --forced || fail "sweep script exited non-zero"

  flagged=$(not_started_finding_count_for "$target_id")
  [ "$flagged" -ge 1 ] \
    || fail "an unrelated finding already on the card silenced the not-started check entirely"
  pass "a finding another check raised about the same card never silences the not-started check"
}

# Two waiting cards can be blocked on one not-started card. The finding is
# about that card's own claim, so it is one finding, not one per waiter - and
# the log snapshot the sweep reads predates its own writes, so the run has to
# remember what it already said.
test_two_waiting_cards_on_one_not_started_card_produce_one_finding_per_sweep() {
  local target_id first_waiter second_waiter before after
  target_id=$("$DASH" add --title "One blocker, two blocked cards" --captain firstmate \
    --prompt "named by two waiting cards" | awk '{print $1}')
  [ -n "$target_id" ] || fail "could not add the shared not-started target"
  first_waiter=$("$DASH" add --title "First card blocked on it" --captain firstmate \
    --prompt "blocked" | awk '{print $1}')
  second_waiter=$("$DASH" add --title "Second card blocked on it" --captain firstmate \
    --prompt "blocked too" | awk '{print $1}')
  [ -n "$first_waiter" ] && [ -n "$second_waiter" ] || fail "could not add both waiting cards"
  "$DASH" status "$first_waiter" waiting --waiting-on "$target_id" --reason "needs it first" >/dev/null \
    || fail "could not set the first waiting status"
  "$DASH" status "$second_waiter" waiting --waiting-on "$target_id" --reason "needs it too" >/dev/null \
    || fail "could not set the second waiting status"
  before=$(not_started_finding_count_for "$target_id")

  "$SWEEP" --forced || fail "sweep script exited non-zero"

  after=$(not_started_finding_count_for "$target_id")
  [ "$after" -eq $((before + 1)) ] \
    || fail "one sweep logged $((after - before)) findings for a card two waiting cards name; expected exactly one"
  pass "two waiting cards blocked on one not-started card are a single finding in one sweep"
}

# Regression: holding the log text back must never be mistaken for the block
# resolving. `discrepancies_found` is what turns the Admiral's "Last sweep
# result" tile green ("Clean - nothing caught"), so a still-outstanding block
# has to keep counting on every sweep even though its text is written once.
test_a_quiet_but_outstanding_block_still_counts_toward_the_run_total() {
  local target_id waiter_id baseline first second logged_first logged_second
  "$SWEEP" --forced || fail "baseline sweep exited non-zero"
  baseline=$(audit_status_json | jq -r '.last_run.discrepancies_found')

  target_id=$("$DASH" add --title "Outstanding across sweeps" --captain firstmate \
    --prompt "never started, still blocking" | awk '{print $1}')
  [ -n "$target_id" ] || fail "could not add the not-started target card"
  waiter_id=$("$DASH" add --title "Still blocked on it" --captain firstmate \
    --prompt "blocked" | awk '{print $1}')
  [ -n "$waiter_id" ] || fail "could not add the waiting card"
  "$DASH" status "$waiter_id" waiting --waiting-on "$target_id" --reason "needs that work first" >/dev/null \
    || fail "could not set waiting status"

  "$SWEEP" --forced || fail "first sweep exited non-zero"
  first=$(audit_status_json | jq -r '.last_run.discrepancies_found')
  logged_first=$(not_started_finding_count_for "$target_id")
  [ "$first" -eq $((baseline + 1)) ] \
    || fail "the new block did not add exactly one to the run total (baseline=$baseline, now=$first)"

  # Nothing changes; the text is already on record, the block is not.
  "$SWEEP" --forced || fail "second sweep exited non-zero"
  second=$(audit_status_json | jq -r '.last_run.discrepancies_found')
  logged_second=$(not_started_finding_count_for "$target_id")
  [ "$second" -eq "$first" ] \
    || fail "a still-outstanding block stopped counting once its text was on record (was $first, now $second)"
  [ "$logged_second" -eq "$logged_first" ] \
    || fail "the block's text was written again on the second sweep; it should have been said once"
  pass "a block that is quiet because it was already described still counts toward the run total"
}

# Regression: a card that is started and then abandoned back to not_started is
# a fresh occurrence of the condition, not the old one still running. Keying
# the quiet period on the waiting card alone let the entry written before the
# card was ever started answer for the second occurrence too.
test_a_target_started_then_abandoned_is_flagged_again() {
  local target_id waiter_id after_first after_restart
  target_id=$("$DASH" add --title "Started once, then abandoned" --captain firstmate \
    --prompt "goes working and comes back" | awk '{print $1}')
  [ -n "$target_id" ] || fail "could not add the not-started target card"
  waiter_id=$("$DASH" add --title "Blocked across the whole cycle" --captain firstmate \
    --prompt "blocked" | awk '{print $1}')
  [ -n "$waiter_id" ] || fail "could not add the waiting card"
  "$DASH" status "$waiter_id" waiting --waiting-on "$target_id" --reason "needs that work first" >/dev/null \
    || fail "could not set waiting status"

  "$SWEEP" --forced || fail "first sweep exited non-zero"
  after_first=$(not_started_finding_count_for "$target_id")
  [ "$after_first" -ge 1 ] || fail "the first sweep did not flag the blocked not-started card at all"

  # The card is picked up, then abandoned back to not_started. The waiting
  # card is never touched, so its own waiting-since is unchanged. Board
  # timestamps are whole seconds, so the cycle has to land in a later second
  # than the entry above for "afterwards" to be expressible at all.
  sleep 1
  "$DASH" status "$target_id" working >/dev/null || fail "could not start the target card"
  "$DASH" status "$target_id" not-started >/dev/null || fail "could not abandon the target card"

  "$SWEEP" --forced || fail "sweep after the restart exited non-zero"
  after_restart=$(not_started_finding_count_for "$target_id")
  [ "$after_restart" -gt "$after_first" ] \
    || fail "a card started and then abandoned back to not-started was never flagged again (still $after_restart)"
  pass "a not-started card that was started and abandoned is flagged again, not answered for by the old entry"
}

# The split gave the board two blocking statuses, and the age check exists
# because a card sitting on him is evidence the ask never landed. That
# reasoning is about being blocked, not about the word "action", so it has to
# cover needs_review too - a plan nobody has approved is holding work up just
# as surely as an unanswered ask.
# Regression for the failure firstmate hit repeatedly in live use: re-setting a
# card he is already blocked on, with an updated reason, is the ONLY way to
# change the ask on such a card, and store.set_status records it as a
# same-status row. Measuring age from the newest such row restarted his waiting
# clock on every re-ask - so the sweep that exists to catch cards he has been
# left waiting on went permanently quiet on the card being re-asked most.
#
# The age must run from when he FIRST became blocked and survive a re-ask,
# while a reply is still measured against the NEWEST ask, so an answer to an
# earlier question never silences a later one.
test_a_re_ask_does_not_restart_his_waiting_clock() {
  local id first_age second_age rows
  id=$("$DASH" add --title "Re-asked twice" --captain firstmate --prompt "re-ask clock" | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the card"
  "$DASH" status "$id" needs-action --reason "pick red or blue for the trim" >/dev/null \
    || fail "could not block the card"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "first sweep exited non-zero"
  rows=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$rows" | jq 'length')" -eq 1 ] \
    || fail "expected one row for the blocked card, got $(printf '%s' "$rows" | jq 'length')"
  first_age=$(printf '%s' "$rows" | jq -r '.[0].text')

  # Re-ask him something new on the card he is already blocked on.
  sleep 2
  "$DASH" status "$id" needs-action --reason "actually, pick the darker shade instead" >/dev/null \
    || fail "could not re-ask on the already-blocked card"
  assert_contains "$("$DASH" show "$id")" "needs action: actually, pick the darker shade instead" \
    "the re-ask did not update the ask the card displays"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "post-re-ask sweep exited non-zero"
  rows=$(discrepancy_rows_for "$id")
  # Still one row: one blocked period is one finding, so a re-ask updates the
  # standing row rather than opening a second beside it.
  [ "$(printf '%s' "$rows" | jq 'length')" -eq 1 ] \
    || fail "a re-ask opened a second row instead of updating the standing one"
  [ "$(printf '%s' "$rows" | jq -r '.[0].occurrences')" -gt 1 ] \
    || fail "the re-asked card was not flagged again - the re-ask silenced the check"
  second_age=$(printf '%s' "$rows" | jq -r '.[0].text')

  # The clock must still run from the ORIGINAL block. With the threshold at 0
  # a restarted clock still flags, so age alone cannot discriminate - and over
  # a two-second re-ask the rendered minutes are identical either way. The
  # discriminating observable is the row's own collapse key, which the sweep
  # builds from the timestamp it measured the age from.
  local block_at newest_ask row_key
  block_at=$("$DASH" show "$id" --json \
    | jq -r '[.status_history[] | select(.to_status=="needs_action" and (.from_status != "needs_action"))] | last | .changed_at')
  newest_ask=$("$DASH" show "$id" --json \
    | jq -r '[.status_history[] | select(.to_status=="needs_action")] | last | .changed_at')
  [ "$block_at" != "$newest_ask" ] \
    || fail "setup did not actually produce a same-status re-ask row, so this test proves nothing"
  row_key=$(printf '%s' "$rows" | jq -r '.[0].key')
  [ "$row_key" = "needs-action-stale:$block_at" ] \
    || fail "after the re-ask the sweep measured from [$row_key], not from the original block at $block_at - his waiting clock was restarted"
  [ -n "$second_age" ] || fail "the re-asked card's finding lost its text"

  # A reply is measured against the NEWEST ask: a reply predating it must not
  # silence the card, and one after it must.
  "$DASH" note "$id" --tab communication --author admiral --text "blue" >/dev/null \
    || fail "could not add his reply"
  sleep 1
  rows=$(discrepancy_rows_for "$id")
  local before_occ
  before_occ=$(printf '%s' "$rows" | jq -r '.[0].occurrences')
  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "post-reply sweep exited non-zero"
  [ "$(discrepancy_rows_for "$id" | jq -r '.[0].occurrences')" = "$before_occ" ] \
    || fail "a card he has now answered was flagged again"

  pass "a re-ask keeps his waiting clock running from the original block while the card shows the newest ask, and his reply still closes it"
}

# The twin of the above, on the other side: an answer he gave to an EARLIER
# question must not silence a later one. Without measuring the reply against
# the newest ask, his old reply would answer every future re-ask forever.
test_an_old_reply_does_not_answer_a_later_re_ask() {
  local id before after
  id=$("$DASH" add --title "Answered then re-asked" --captain firstmate --prompt "stale reply" | awk '{print $1}')
  "$DASH" status "$id" needs-action --reason "pick red or blue" >/dev/null || fail "could not block the card"
  sleep 1
  "$DASH" note "$id" --tab communication --author admiral --text "blue" >/dev/null \
    || fail "could not add his reply"
  sleep 1
  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep exited non-zero"
  before=$(discrepancy_rows_for "$id" | jq 'length')

  # Now ask him something new. His earlier reply says nothing about this.
  sleep 2
  "$DASH" status "$id" needs-action --reason "and confirm the hinge finish" >/dev/null \
    || fail "could not re-ask"
  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "post-re-ask sweep exited non-zero"
  after=$(discrepancy_rows_for "$id" | jq 'length')
  local occ
  occ=$(discrepancy_rows_for "$id" | jq -r 'map(.occurrences) | add')
  [ "$after" -gt "$before" ] || [ "$occ" -gt 1 ] \
    || fail "a reply to an earlier question silenced a later, unanswered re-ask"

  pass "an answer he gave to an earlier ask does not silence a later one"
}

test_sweep_flags_a_stale_needs_review_card_the_same_way() {
  local id
  id=$("$DASH" add --title "Awaiting approval" --captain firstmate --prompt "needs-review aging" \
        --status needs-review --plan "Swap the vendor and re-run the checks." | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the needs-review card"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep script exited non-zero (needs-review case)"
  assert_contains "$(audit_status_json)" "$id" "an unapproved stale needs-review card was not flagged"
  local rows
  rows=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$rows" | jq -r '.[0].text')" != "null" ] || fail "the needs-review finding has no text"
  case "$(printf '%s' "$rows" | jq -r '.[0].text')" in
    needs-review*) : ;;
    *) fail "the needs-review finding does not name the status it is about: $(printf '%s' "$rows" | jq -r '.[0].text')" ;;
  esac
  pass "the sweep ages a needs-review card exactly like a needs-action one, because both mean he is the next step"
}

# His approval IS the reply a needs_review card asks for - one tap, no note -
# so it has to close the age finding the way a written reply does. And the
# hole that would open if it closed it unconditionally: an approval for
# wording the plan no longer carries has NOT answered the plan on the card,
# so that card must keep flagging.
test_an_approval_quiets_the_sweep_but_a_stale_one_does_not() {
  local id before after
  id=$("$DASH" add --title "Approve to quiet" --captain firstmate --prompt "approval closes the finding" \
        --status needs-review --plan "Reserve fixed addresses for the six lights." | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the needs-review card"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "first sweep exited non-zero"
  before=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$before" | jq 'length')" -eq 1 ] \
    || fail "expected exactly one row for the unapproved card, got $(printf '%s' "$before" | jq 'length')"

  sleep 1
  curl -sS -o /dev/null -X POST "$BASE/api/tasks/$id/approve-plan" \
    -H 'Content-Type: application/json' \
    -d '{"plan":"Reserve fixed addresses for the six lights."}' \
    || fail "could not record the approval"
  sleep 1

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "post-approval sweep exited non-zero"
  after=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$after" | jq -r '.[0].occurrences')" = "$(printf '%s' "$before" | jq -r '.[0].occurrences')" ] \
    || fail "an approved needs-review card was flagged again - his approval did not close the finding"
  [ "$(printf '%s' "$after" | jq -r '.[0].last_seen_at')" = "$(printf '%s' "$before" | jq -r '.[0].last_seen_at')" ] \
    || fail "an approved needs-review card's row had its last-seen time advanced, so it was re-flagged"

  # Now edit the plan. His approval stands as a record, but it no longer
  # covers what the card displays, so the card is genuinely waiting on him
  # again and the sweep must say so.
  sleep 1
  "$DASH" plan "$id" "Change the software to find devices by hardware ID." >/dev/null \
    || fail "could not edit the plan"
  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "post-edit sweep exited non-zero"
  local edited
  edited=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$edited" | jq -r '.[0].occurrences')" -gt "$(printf '%s' "$after" | jq -r '.[0].occurrences')" ] \
    || fail "a card whose plan was edited after approval stayed quiet - a stale approval silenced a card genuinely waiting on him"

  pass "a current approval closes the sweep's age finding, and an approval left stale by an edited plan does not"
}

# The plan and its approval deliberately survive a status change, so a card
# can sit in needs_action carrying an approval that answered an entirely
# different question. An approval is the reply a needs_review card asks for
# and nothing else; a needs_action card is closed only by his written reply.
test_an_approval_never_quiets_a_needs_action_card() {
  local id rows
  id=$("$DASH" add --title "Approved elsewhere" --captain firstmate --prompt "an approval must not silence an ask" \
        --status needs-review --plan "Reserve the loading dock for Thursday." | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the card"
  "$DASH" status "$id" needs-action --reason "sign the dock permit at the supplier office" >/dev/null \
    || fail "could not move the card into needs-action"
  sleep 1
  curl -sS -o /dev/null -X POST "$BASE/api/tasks/$id/approve-plan" \
    -H 'Content-Type: application/json' \
    -d '{"plan":"Reserve the loading dock for Thursday."}' \
    || fail "could not record the approval"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep exited non-zero"
  rows=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$rows" | jq 'length')" -ge 1 ] \
    || fail "an approval recorded on a needs-action card silenced the ask he has never answered"
  case "$(printf '%s' "$rows" | jq -r '.[0].text')" in
    needs-action*) : ;;
    *) fail "the finding does not name the status it is about: $(printf '%s' "$rows" | jq -r '.[0].text')" ;;
  esac

  pass "an approval never quiets a needs-action card - only his own reply does"
}

test_sweep_flags_stale_unreplied_needs_attention_but_not_a_reply() {
  local id
  id=$("$DASH" add --title "Needs a call" --captain firstmate --prompt "needs-attention aging" | awk '{print $1}')
  "$DASH" status "$id" needs-attention --reason "pick a name" >/dev/null || fail "could not set needs-attention"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep script exited non-zero (unreplied case)"
  assert_contains "$(audit_status_json)" "$id" "an unreplied stale needs-attention card was not flagged"

  sleep 1
  "$DASH" note "$id" --tab communication --author admiral --text "picked blue" >/dev/null \
    || fail "could not add the admiral's reply"
  sleep 1

  # Row count alone cannot prove this: the check is keyed on the card's
  # needs_attention changed_at, and his reply is a note rather than a status
  # change, so a broken reply short-circuit would collapse onto the very row
  # already standing - same count, higher seen-count. The row must be
  # untouched, not merely un-duplicated.
  local before after
  before=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$before" | jq 'length')" -eq 1 ] \
    || fail "expected exactly one row for the card before the post-reply sweep, got $(printf '%s' "$before" | jq 'length')"
  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep script exited non-zero (replied case)"
  after=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$after" | jq 'length')" = "$(printf '%s' "$before" | jq 'length')" ] \
    || fail "a needs-attention card the admiral already replied to was flagged again"
  [ "$(printf '%s' "$after" | jq -r '.[0].occurrences')" = "$(printf '%s' "$before" | jq -r '.[0].occurrences')" ] \
    || fail "the replied card's existing row had its seen-count bumped, so it was re-flagged into the same row"
  [ "$(printf '%s' "$after" | jq -r '.[0].last_seen_at')" = "$(printf '%s' "$before" | jq -r '.[0].last_seen_at')" ] \
    || fail "the replied card's existing row had its last-seen time advanced, so it was re-flagged into the same row"
  pass "the sweep flags a stale unreplied needs-attention card and stops once he has replied"
}

# Regression, the needs_attention twin of "started then abandoned is flagged
# again" above: the needs-attention key deliberately embeds the card's own
# last move into needs_attention rather than being flat, so a card he replied
# to that later genuinely cycles back into needs_attention is a fresh
# occurrence. Without the boundary in the key it would collapse onto - and so
# be silenced by - the very row his earlier reply already closed.
test_a_needs_attention_card_that_cycles_back_in_gets_a_fresh_row() {
  local id rows first_key second_key
  id=$("$DASH" add --title "Asked twice" --captain firstmate --prompt "cycles back in" | awk '{print $1}')
  [ -n "$id" ] || fail "could not add the needs-attention card"
  "$DASH" status "$id" needs-attention --reason "pick a name" >/dev/null || fail "could not set needs-attention"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "first sweep exited non-zero"
  rows=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$rows" | jq 'length')" -eq 1 ] \
    || fail "the first ask did not produce exactly one row, got $(printf '%s' "$rows" | jq 'length')"
  first_key=$(printf '%s' "$rows" | jq -r '.[0].key')
  [ -n "$first_key" ] && [ "$first_key" != "null" ] || fail "the needs-attention finding was written with no key"

  # He answers, the card moves on, and only later is he asked something new.
  # Board timestamps are whole seconds, so the second ask has to land in a
  # later second than the first for the boundary to move at all.
  "$DASH" note "$id" --tab communication --author admiral --text "call it blue" >/dev/null \
    || fail "could not add the admiral's reply"
  "$DASH" status "$id" working >/dev/null || fail "could not move the card off needs-attention"
  sleep 1
  "$DASH" status "$id" needs-attention --reason "now pick a shade" >/dev/null \
    || fail "could not put the card back into needs-attention"

  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep after the second ask exited non-zero"
  rows=$(discrepancy_rows_for "$id")
  [ "$(printf '%s' "$rows" | jq 'length')" -eq 2 ] \
    || fail "a card asked a second time did not get a fresh row; rows: $(printf '%s' "$rows" | jq -c '[.[] | {key, occurrences}]')"
  second_key=$(printf '%s' "$rows" | jq -r --arg k "$first_key" '[.[] | select(.key != $k)] | .[0].key')
  [ -n "$second_key" ] && [ "$second_key" != "null" ] \
    || fail "the second ask reused the first ask's key instead of opening its own"
  [ "$(printf '%s' "$rows" | jq -r --arg k "$second_key" '[.[] | select(.key == $k)] | .[0].occurrences')" -eq 1 ] \
    || fail "the second ask's row did not start a fresh seen-count"
  [ "$(printf '%s' "$rows" | jq -r --arg k "$first_key" '[.[] | select(.key == $k)] | .[0].occurrences')" -eq 1 ] \
    || fail "the row his earlier reply already closed was reopened by the second ask"

  "$DASH" status "$id" complete >/dev/null || fail "could not clear the cycled card"
  pass "a needs-attention card that cycles back in after a reply gets a fresh row, not the closed one"
}

test_force_button_endpoint_runs_a_real_sweep() {
  local resp started
  resp=$(curl -sS -X POST "$BASE/api/audit/force")
  started=$(printf '%s' "$resp" | jq -r '.started')
  [ "$started" = "true" ] || fail "force endpoint did not report started:true (got: $resp)"

  local status running last_completed forced
  last_completed=""
  for _ in $(seq 1 20); do
    status=$("$DASH" audit-status --json)
    running=$(printf '%s' "$status" | jq -r '.sweep_lock.running')
    [ "$running" = "false" ] && break
    sleep 0.5
  done
  [ "$running" = "false" ] || fail "forced sweep never released the lock within the wait budget"

  last_completed=$(printf '%s' "$status" | jq -r '.last_run.completed_at // empty')
  forced=$(printf '%s' "$status" | jq -r '.last_run.forced')
  [ -n "$last_completed" ] || fail "forced sweep left no recorded run"
  [ "$forced" = "1" ] || fail "the run the button triggered was not recorded as forced"
  pass "POST /api/audit/force launches a real sweep that records itself as forced"
}

test_force_button_refuses_while_a_sweep_is_already_running() {
  "$DASH" audit-claim --forced >/dev/null || fail "setup claim failed"
  local resp started
  resp=$(curl -sS -X POST "$BASE/api/audit/force")
  started=$(printf '%s' "$resp" | jq -r '.started')
  [ "$started" = "false" ] || fail "force endpoint should have refused while a sweep is already claimed"
  assert_contains "$resp" "already in progress" "refusal did not explain why"
  "$DASH" audit-release >/dev/null || fail "cleanup release failed"
  pass "the button refuses to stack a second sweep onto one already in progress"
}

test_stale_claim_is_reclaimed_after_max_sweep_seconds() {
  "$DASH" audit-claim --forced >/dev/null || fail "setup claim failed"
  sleep 3

  "$DASH" audit-claim >/dev/null 2>&1 \
    || fail "a claim held past FM_AUDIT_MAX_SWEEP_SECONDS should have been treated as abandoned and reclaimed"
  "$DASH" audit-release >/dev/null || fail "cleanup release failed"
  pass "a claim abandoned by a crashed sweep is reclaimed once it outlives the max sweep duration"
}

test_tick_heals_a_stuck_lock_left_by_a_crashed_sweep() {
  "$DASH" audit-interval 1 >/dev/null || fail "could not reset the interval"
  # Simulate a sweep that crashed mid-run and never released its claim - the
  # exact scenario fm-fleet-audit-tick.sh must not get permanently stuck on.
  "$DASH" audit-claim >/dev/null || fail "setup claim failed"
  sleep 3

  local before
  before=$(audit_status_json | jq -r '.last_run.completed_at // empty')

  "$TICK" || fail "tick failed while healing a stuck lock"

  local after running
  after=$(audit_status_json | jq -r '.last_run.completed_at // empty')
  running=$(audit_status_json | jq -r '.sweep_lock.running')
  [ "$running" = "false" ] || fail "the tick did not release the reclaimed lock"
  [ -n "$after" ] && [ "$after" != "$before" ] \
    || fail "the tick did not run a fresh sweep after reclaiming the stuck lock"
  pass "a tick reclaims and heals a lock abandoned by a crashed sweep, instead of staying stuck forever"
}

test_claim_is_exclusive_and_release_frees_it
# Must run before any test below records a run: it relies on last_run still
# being absent so the tick it drives is unconditionally due, regardless of
# the configured interval, without needing a real wait for one to elapse.
test_tick_heals_a_stuck_lock_left_by_a_crashed_sweep
test_audit_run_forced_flag_and_auto_release
test_audit_tick_heartbeat_and_due_interval
test_sweep_counts_testing_cards_and_never_flags_an_unverifiable_one
test_sweep_flags_a_live_crew_status_whose_linked_crew_is_not_working
test_a_recurring_identical_finding_collapses_into_one_row_with_a_growing_count
test_a_genuinely_new_finding_on_a_different_card_does_not_collapse
test_an_unrelated_finding_on_the_same_card_never_suppresses_a_general_collapse
test_a_collapsed_but_outstanding_finding_still_counts_and_never_reads_clean
test_a_repeating_fleet_level_error_collapses_and_a_different_one_does_not
test_sweep_flags_waiting_on_completed_card
test_sweep_counts_not_started_cards_and_never_flags_an_unverifiable_one
test_sweep_flags_a_not_started_card_that_live_work_is_waiting_on
test_sweep_flags_a_blocked_not_started_card_once_not_once_per_sweep
test_an_unrelated_finding_on_the_card_does_not_silence_the_not_started_check
test_two_waiting_cards_on_one_not_started_card_produce_one_finding_per_sweep
test_a_quiet_but_outstanding_block_still_counts_toward_the_run_total
test_a_target_started_then_abandoned_is_flagged_again
test_sweep_flags_stale_unreplied_needs_attention_but_not_a_reply
test_a_needs_attention_card_that_cycles_back_in_gets_a_fresh_row
test_sweep_flags_a_stale_needs_review_card_the_same_way
test_an_approval_quiets_the_sweep_but_a_stale_one_does_not
test_a_re_ask_does_not_restart_his_waiting_clock
test_an_old_reply_does_not_answer_a_later_re_ask
test_an_approval_never_quiets_a_needs_action_card
test_force_button_endpoint_runs_a_real_sweep
test_force_button_refuses_while_a_sweep_is_already_running
test_stale_claim_is_reclaimed_after_max_sweep_seconds
