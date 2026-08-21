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

  local before after
  before=$("$DASH" audit-status --json | jq '[.log[] | select(.task_id=="'"$id"'")] | length')
  FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES=0 "$SWEEP" --forced || fail "sweep script exited non-zero (replied case)"
  after=$("$DASH" audit-status --json | jq '[.log[] | select(.task_id=="'"$id"'")] | length')
  [ "$after" = "$before" ] || fail "a needs-attention card the admiral already replied to was flagged again"
  pass "the sweep flags a stale unreplied needs-attention card and stops once he has replied"
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
test_sweep_flags_waiting_on_completed_card
test_sweep_counts_not_started_cards_and_never_flags_an_unverifiable_one
test_sweep_flags_a_not_started_card_that_live_work_is_waiting_on
test_sweep_flags_a_blocked_not_started_card_once_not_once_per_sweep
test_sweep_flags_stale_unreplied_needs_attention_but_not_a_reply
test_force_button_endpoint_runs_a_real_sweep
test_force_button_refuses_while_a_sweep_is_already_running
test_stale_claim_is_reclaimed_after_max_sweep_seconds
