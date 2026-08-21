#!/usr/bin/env bash
# fm-fleet-audit-sweep.sh - one fleet-auditor sweep of the Admiral's Fleet
# Dashboard: claim the sweep slot, run the checks, record the result.
#
# This is the single implementation both the timer (fm-fleet-audit-tick.sh,
# on the interval read from the dashboard) and the Force Audit button
# (bin/fleet-dashboard/server/api.py's audit_force, launching this detached)
# invoke, so a forced run and a scheduled run are never two different code
# paths that could quietly drift apart - see docs/dashboard.md "Auditor
# integration".
#
# Scope: this implements the deterministic subset of the eight-status
# procedure in .agents/skills/fleet-dashboard/SKILL.md "The fleet auditor's
# sweep" - the checks that are genuinely a mechanical comparison, not a
# judgment call:
#   1. working  - corroborated against bin/fm-crew-state.sh, but ONLY for a
#      card whose backlog_ref names a task in THIS FM_HOME; a ref naming
#      another home, or no ref at all, is not verifiable from here and is
#      skipped, never logged as a discrepancy (skill point 8).
#   2. testing  - the fleet must genuinely be exercising it right now, so it
#      gets the exact same live-crew corroboration as working (a testing card
#      is not inert the way a review card is).
#   3. waiting  - flags a card whose waiting_on_id card is already complete.
#   4. paused is left to a live agent's judgment (the skill itself notes it is
#      usually unverifiable from state alone: "confirm each is still
#      genuinely paused by the Admiral's own word") - this script counts a
#      paused card as checked but never flags one.
#   5. needs_attention - flags a card that has sat past
#      FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES (default 60) with no
#      admiral-authored communication note since it was flagged.
#   6. not_started - counted for every not-started card, but flagged only
#      when a currently-waiting card's own waiting_on_id names it: that
#      column is only ever non-null while the referencing card is itself
#      `waiting` (store.py's set_status clears it on every other status), so
#      it is a structural fact that live work is genuinely blocked on this
#      one, not a guess. Age alone is never the signal here - most
#      not-started cards are legitimately queued, and unlike needs_attention
#      above this check applies no age threshold at all. Every outstanding
#      block counts toward the run's discrepancy total on every sweep, so the
#      board can never read "clean" while one still stands; what is said once
#      rather than every sweep is the log *text*. It stays quiet while one of
#      this check's own earlier entries for the card is dated at or after the
#      later of the waiting card's last move into `waiting` and the target's
#      own last move out of `not_started` - so a block that clears, repoints,
#      or is started and abandoned speaks again, while an unchanged one does
#      not. A finding some other check wrote about the same card never
#      silences it, and two waiting cards naming one target are one finding
#      within a sweep.
#   review is optional to him by design (the skill's own asymmetry), so it is
#   never checked here at all - see "Why `needs-attention` is a separate
#   status from `review`" in docs/dashboard.md.
#
# Usage: fm-fleet-audit-sweep.sh [--forced] [--already-claimed]
#   --forced           mark the recorded run as forced (the Force Audit
#                       button), not scheduled.
#   --already-claimed  the caller already claimed the sweep slot atomically
#                       (audit_force does, before launching this script) - do
#                       not claim again. Without this flag (the normal path,
#                       used by fm-fleet-audit-tick.sh), this script claims
#                       for itself and exits 0 with no recorded run if the
#                       slot is already held.
#
# Exit 0: a sweep was recorded, or the slot was already held (a clean no-op,
# not a failure - something else is already sweeping).
# Exit 1: an internal failure. When the dashboard was reachable, the failure
# is also recorded via audit-log/audit-release so a broken sweep never looks
# identical to a clean one (see docs/dashboard.md "Connectivity failure is
# loud"). When the dashboard itself is unreachable there is nothing to record
# it in; the caller's own exit-code handling and the tick script's separate
# heartbeat call are what surface that outage instead.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DASH="$SCRIPT_DIR/fm-dashboard.sh"
CREW_STATE="$SCRIPT_DIR/fm-crew-state.sh"

FORCED=0
ALREADY_CLAIMED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --forced) FORCED=1; shift ;;
    --already-claimed) ALREADY_CLAIMED=1; shift ;;
    *) echo "fm-fleet-audit-sweep.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

iso_to_epoch() {  # <iso8601>
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

fail_sweep() {  # <text>
  "$DASH" audit-log --fleet "$1" --kind error >/dev/null 2>&1 || true
  "$DASH" audit-release >/dev/null 2>&1 || true
  exit 1
}

write_discrepancy() {  # <task_id> <text> - record the text, count nothing
  "$DASH" audit-log "$1" "$2" --kind discrepancy >/dev/null 2>&1
}

log_discrepancy() {  # <task_id> <text>
  write_discrepancy "$1" "$2" && DISCREPANCIES=$((DISCREPANCIES + 1))
}

# Shared by the working and testing checks: both statuses claim a real crew is
# actively on the card right now, so both are corroborated the same way -
# against bin/fm-crew-state.sh, and ONLY for a card whose backlog_ref names a
# task in THIS FM_HOME (skill point 8: a ref naming another home, or no ref at
# all, is not verifiable from here and is skipped, never logged).
check_live_crew_status() {  # <status-flag>
  local status_flag=$1 json id ref ref_home ref_task state_line state
  json=$("$DASH" list --status "$status_flag" --json) \
    || fail_sweep "sweep failed listing $status_flag cards: dashboard unreachable mid-sweep"
  while IFS=$'\t' read -r id ref; do
    [ -n "$id" ] || continue
    CHECKED=$((CHECKED + 1))
    [ -n "$ref" ] && [ "$ref" != "null" ] || continue
    ref_home="local"
    ref_task="$ref"
    case "$ref" in
      *:*) ref_home="${ref%%:*}"; ref_task="${ref#*:}" ;;
    esac
    [ "$ref_home" = "local" ] || [ "$ref_home" = "$HOME_NAME" ] || continue
    state_line=$("$CREW_STATE" "$ref_task" 2>/dev/null) || continue
    state=$(printf '%s\n' "$state_line" | sed -n 's/^state: \([a-z]*\).*/\1/p')
    case "$state" in
      working|unknown|"") ;;  # corroborated, or crew-state itself has nothing to say - not a discrepancy
      *) log_discrepancy "$id" "card claims $status_flag, but the linked crew reads: $state_line" ;;
    esac
  done < <(printf '%s' "$json" | jq -r '.tasks[] | [.id, (.backlog_ref // "")] | @tsv')
}

if [ "$ALREADY_CLAIMED" -eq 0 ]; then
  claim_args=()
  [ "$FORCED" -eq 1 ] && claim_args=(--forced)
  "$DASH" audit-claim "${claim_args[@]}" >/dev/null 2>&1 || exit 0
fi

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_EPOCH=$(iso_to_epoch "$STARTED_AT")
[ -n "$START_EPOCH" ] || START_EPOCH=$(date +%s)

CHECKED=0
DISCREPANCIES=0
HOME_NAME=$(basename "$FM_HOME")

# ---- 1. working: corroborate against a local backlog_ref only ----
check_live_crew_status working

# ---- 2. testing: the fleet must genuinely be exercising it right now, same
# corroboration as working - a testing card is not inert the way review is ----
check_live_crew_status testing

# ---- 3. waiting: is the named blocker card actually still open? ----
WAITING_JSON=$("$DASH" list --status waiting --json) \
  || fail_sweep "sweep failed listing waiting cards: dashboard unreachable mid-sweep"
while IFS=$'\t' read -r id waiting_on; do
  [ -n "$id" ] || continue
  CHECKED=$((CHECKED + 1))
  [ -n "$waiting_on" ] && [ "$waiting_on" != "null" ] || continue
  target_status=$("$DASH" show "$waiting_on" --json 2>/dev/null | jq -r '.status // empty')
  [ -n "$target_status" ] || continue
  if [ "$target_status" = "complete" ]; then
    log_discrepancy "$id" "card is waiting on $waiting_on, but that card is already complete"
  fi
done < <(printf '%s' "$WAITING_JSON" | jq -r '.tasks[] | [.id, (.waiting_on_id // "")] | @tsv')

# ---- 4. paused: counted as checked, never flagged (see header) ----
PAUSED_JSON=$("$DASH" list --status paused --json) \
  || fail_sweep "sweep failed listing paused cards: dashboard unreachable mid-sweep"
CHECKED=$((CHECKED + $(printf '%s' "$PAUSED_JSON" | jq '.tasks | length')))

# ---- 5. needs_attention: age since flagged, with no reply since ----
STALE_MINUTES=${FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES:-60}
case "$STALE_MINUTES" in ''|*[!0-9]*) STALE_MINUTES=60 ;; esac
NA_JSON=$("$DASH" list --status needs-attention --json) \
  || fail_sweep "sweep failed listing needs-attention cards: dashboard unreachable mid-sweep"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  CHECKED=$((CHECKED + 1))
  detail_json=$("$DASH" show "$id" --json 2>/dev/null) || continue
  changed_at=$(printf '%s' "$detail_json" \
    | jq -r '[.status_history[] | select(.to_status=="needs_attention")] | last | .changed_at // empty')
  [ -n "$changed_at" ] || continue
  changed_epoch=$(iso_to_epoch "$changed_at") || continue
  [ -n "$changed_epoch" ] || continue
  age_min=$(( (START_EPOCH - changed_epoch) / 60 ))
  [ "$age_min" -ge "$STALE_MINUTES" ] || continue
  replied=$(printf '%s' "$detail_json" | jq -r --arg since "$changed_at" \
    '([.notes[] | select(.tab=="communication" and .author=="admiral" and .created_at > $since)] | length) > 0')
  [ "$replied" = "true" ] && continue
  log_discrepancy "$id" "needs-attention for ${age_min}m with no reply from him since it was flagged"
done < <(printf '%s' "$NA_JSON" | jq -r '.tasks[].id')

# ---- 6. not_started: counted for every not-started card, but flagged only
# when a currently-waiting card's own waiting_on_id names it (see header).
# Reuses the waiting snapshot already fetched in step 3 above rather than
# re-listing it, since that is the exact same live-ness fact either way. The
# match is one jq pass over the two snapshots, so a board with thousands of
# queued cards never becomes a rescan of the whole id list per waiting card.
NOT_STARTED_JSON=$("$DASH" list --status not-started --json) \
  || fail_sweep "sweep failed listing not-started cards: dashboard unreachable mid-sweep"
CHECKED=$((CHECKED + $(printf '%s' "$NOT_STARTED_JSON" | jq '.tasks | length')))
BLOCKED_PAIRS=$(jq -nr --argjson ns "$NOT_STARTED_JSON" --argjson w "$WAITING_JSON" '
  ($ns.tasks | map(.id)) as $ids
  | $w.tasks[]
  | (.waiting_on_id // "") as $wo
  | select($wo != "" and ($ids | index($wo)) != null)
  | [.id, $wo] | @tsv') \
  || fail_sweep "sweep failed matching waiting cards against the not-started snapshot"
if [ -n "$BLOCKED_PAIRS" ]; then
  # Unlike a stale blocker (a board bug that gets corrected), "nothing has
  # begun on this yet" legitimately persists for days, and at the default
  # cadence re-writing that text every sweep would fill the Admiral's whole
  # 100-entry log inside a day and push every other finding out of it - the
  # exact always-red-marker failure this sweep exists to avoid. So the text is
  # said once and then held; the *count* is not. An outstanding block is
  # counted on every sweep, because the run total is what turns the board's
  # result tile green, and a block that still stands has not resolved just
  # because it has already been described.
  AUDIT_LOG_JSON=$("$DASH" audit-status --json) \
    || fail_sweep "sweep failed reading the audit log: dashboard unreachable mid-sweep"
  # Only this check's own past entries count as "already reported", matched by
  # the exact opening this check writes. Any card can be put back to
  # not_started from any status, so a card that collected an unrelated finding
  # while it was `working` would otherwise arrive here pre-silenced - a card
  # invisible by construction, which is the failure this whole check exists to
  # end rather than reproduce.
  NOT_STARTED_FINDING_OPENER="still not_started, but"
  seen_this_sweep=""
  while IFS=$'\t' read -r waiter_id target_id; do
    [ -n "$waiter_id" ] && [ -n "$target_id" ] || continue
    # Two waiting cards can name the same target; the finding is about the
    # target's own claim, so it is one finding either way. The log snapshot
    # above predates this run's own writes, so the run tracks them itself.
    case " $seen_this_sweep " in *" $target_id "*) continue ;; esac
    seen_this_sweep="$seen_this_sweep $target_id"
    DISCREPANCIES=$((DISCREPANCIES + 1))
    waiter_json=$("$DASH" show "$waiter_id" --json 2>/dev/null) || continue
    quiet_since=$(printf '%s' "$waiter_json" \
      | jq -r '[.status_history[] | select(.to_status=="waiting")] | last | .changed_at // empty')
    # No readable boundary means no way to tell an already-reported block from
    # a fresh one, which is skill point 8's unverifiable case: stay quiet.
    [ -n "$quiet_since" ] || continue
    # The target's own last move out of not_started counts too, and the later
    # of the two wins. A card that was started and then abandoned back to
    # not_started is a genuinely new occurrence of the same condition, and the
    # entry written before it was ever started must not answer for it.
    target_json=$("$DASH" show "$target_id" --json 2>/dev/null) || target_json=""
    if [ -n "$target_json" ]; then
      restarted_since=$(printf '%s' "$target_json" \
        | jq -r '[.status_history[] | select(.from_status=="not_started")] | last | .changed_at // empty')
      if [ -n "$restarted_since" ] && [ "$restarted_since" \> "$quiet_since" ]; then
        quiet_since=$restarted_since
      fi
    fi
    # Inclusive on the boundary itself: both timestamps are whole seconds, and
    # the first entry for a block is normally written in the same second the
    # block was recorded, so a strict > would let that first entry re-log.
    already=$(printf '%s' "$AUDIT_LOG_JSON" \
      | jq -r --arg t "$target_id" --arg since "$quiet_since" --arg opener "$NOT_STARTED_FINDING_OPENER" \
        '([.log[] | select(.task_id==$t and .kind=="discrepancy" and .created_at >= $since
                            and ((.text // "") | startswith($opener)))] | length) > 0')
    [ "$already" = "true" ] && continue
    write_discrepancy "$target_id" "$NOT_STARTED_FINDING_OPENER $waiter_id is waiting specifically on it"
  done <<<"$BLOCKED_PAIRS"
fi

COMPLETED_EPOCH=$(date +%s)
DURATION=$((COMPLETED_EPOCH - START_EPOCH))
[ "$DURATION" -ge 0 ] || DURATION=0

run_args=(--duration-seconds "$DURATION" --checked "$CHECKED" --discrepancies "$DISCREPANCIES" --started-at "$STARTED_AT")
[ "$FORCED" -eq 1 ] && run_args+=(--forced)
"$DASH" audit-run "${run_args[@]}" >/dev/null \
  || fail_sweep "sweep completed ($CHECKED checked, $DISCREPANCIES discrepancy(ies)) but audit-run could not record it"
