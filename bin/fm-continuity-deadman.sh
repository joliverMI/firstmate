#!/usr/bin/env bash
# fm-continuity-deadman.sh - one detached per-home process whose only job is to
# notice that this home's supervision chain has stopped, and to restart it.
#
# WHY IT EXISTS. Watcher continuity, the detection of its failure, and the alarm
# for that failure were all hosted on the SAME harness event: the primary's turn
# boundary. On 2026-09-07 that single point of failure closed. The account ran
# out of usage credits at 20:28 EDT; Claude Code v2.1.263 does not run Stop hooks
# for a turn that terminates in an API error, and both Firstmate Stop hooks (the
# synchronous turn-end guard and the asyncRewake auto-arm) live on that event.
# The watcher's own rewake turn died on the same error at 20:29:29, its Stop
# hooks were skipped, nothing re-armed, no failure marker could be written, and
# the home sat dark - session alive, lock held, looking healthy - with two
# workers in flight until 06:03. Every layer of the continuity design lived
# behind the one event that did not fire.
#
# That shape recurs deterministically in any unattended stretch that crosses a
# credit exhaustion, billing lapse, key revocation, provider outage, or extended
# network loss, because the very next turn attempted after the failure begins is
# the watcher's rewake turn, and at that instant the watcher is ALWAYS down by
# design (docs/watcher-continuity.md: the Claude Stop hook starts the successor
# arm at the next Stop after the handling turn).
#
# So this process lives OUTSIDE the harness process tree - the one narrow
# exception to Firstmate's rule that the harness owns its hooks' process group -
# and it exits on its own when the session that owns this home dies or is
# replaced by another (a relaunched primary may live in a different pane, and
# only a deadman started from that session's environment can find it), or when
# the home has nothing left to supervise. The detached procevent when-runner
# sailed through the same outage untouched; this is the same structural bet.
#
# WHAT IT DOES, every FM_CONTINUITY_DEADMAN_TICK seconds (default 60), when ALL
# of these hold:
#   - state/.afk is absent (away mode's own daemon owns supervision and its own
#     injection channel; two injectors into one pane is the hazard, not the fix)
#   - the session-lock pid is a live harness process
#   - fm_supervision_needed is true (bin/fm-supervision-lib.sh)
#   - no live `autoarm`-role owner holds state/.claude-autoarm.lock, i.e. the
#     ordinary Stop-owned recovery is NOT already under way
#   - either the watcher has been down past FM_GUARD_GRACE, or a delivered
#     rewake has gone unhandled past it (see state/.rewake-pending below)
#   - and, to OPEN a new episode, firstmate's own pane does not read mid-turn
#     through the shared busy predicate (bin/fm-supervisor-pane-lib.sh). The
#     watcher is down by design for the whole of a rewake handling turn, so a
#     long handling turn satisfies every measure above without being an outage;
#     the 2026-09-07 shape is an IDLE pane, because the woken turn had died. A
#     pane this process cannot resolve or read falls back to the measures alone.
# it, in order:
#   1. appends ONE durable `check: watcher-continuity-lost` wake per episode, so
#      the outage is a first-class record at the next drain rather than a memory;
#   2. fires the configured active-alert channels through the shared
#      bin/fm-wedge-alarm-lib.sh, so an outage can reach the captain from outside
#      every terminal surface (docs/wedge-alarm.md owns channel configuration);
#   3. SELF-RECOVERS on a bounded backoff: injects one turn-end-guard-kind
#      operational input into the primary's own pane, exactly as the away-mode
#      daemon injects its escalations. Each injection starts a real turn whose
#      normal Stop re-arms the chain. While the API is still failing that turn
#      also fails hook-less and costs nothing; the moment service returns, the
#      next injection restores supervision within minutes instead of waiting for
#      the captain. Injection stops the moment supervision is healthy again.
#
# It never kills, never tears down, and never touches another home: every path is
# scoped to this FM_HOME's own state directory and its own singleton lock.
#
# Usage:
#   fm-continuity-deadman.sh ensure    start the singleton if none is live;
#                                      idempotent, silent, always exits 0. Called
#                                      by bin/fm-watch-arm.sh on every arm and by
#                                      bin/fm-bootstrap.sh at session start.
#   fm-continuity-deadman.sh run       the loop itself (started by `ensure`)
#   fm-continuity-deadman.sh run --once
#                                      exactly one evaluation, then exit
#   fm-continuity-deadman.sh status    one line describing this home's deadman
#   fm-continuity-deadman.sh stop      stop THIS home's deadman and nothing else
#
# Environment:
#   FM_GUARD_GRACE                        beacon/down grace, default 300 (shared
#                                         with fm-watch-arm.sh and fm-guard.sh)
#   FM_CONTINUITY_DEADMAN_TICK            poll seconds, default 60
#   FM_CONTINUITY_DEADMAN_INJECT_BACKOFF  seconds between self-recovery
#                                         injections, default 600
#   FM_CONTINUITY_DEADMAN_ALARM_INTERVAL  seconds between re-alarms within one
#                                         episode, default 1800
#   FM_CONTINUITY_DEADMAN_IDLE_EXIT       exit after this many seconds with no
#                                         supervision need, default 900
#   FM_CONTINUITY_DEADMAN_INJECT_EXEC     TEST SEAM. When set, it REPLACES the
#                                         real pane submit: the resolved backend,
#                                         target, and encoded message are handed
#                                         to that command instead. The
#                                         library-mode guard at the foot of this
#                                         file defaults it to "discard" whenever
#                                         this file is SOURCED, so no test can
#                                         type into a real pane.
#   FM_CONTINUITY_DEADMAN_LOG_MAX_BYTES   log cap, default 262144
#
# Files, all under this home's state directory:
#   .continuity-deadman.lock    the singleton lock (bin/fm-wake-lib.sh's portable
#                               lock, same shape as .watch.lock) plus session-pid,
#                               the session lock pid the holder was started under
#   .continuity-deadman-alarm   the durable episode record; present exactly while
#                               an outage episode is open
#   .continuity-deadman.log     bounded diagnostic log; never a dependency
#   .continuity-deadman-last-inject, .continuity-deadman-last-alarm
#                               rate-limit stamps for the injection backoff and
#                               the re-alarm interval; retired with the episode
#   .rewake-pending             written by bin/fm-claude-stop-autoarm.sh before
#                               its exit-2 rewake and cleared by
#                               bin/fm-wake-drain.sh, so "a rewake was delivered
#                               but no handling turn ever drained the queue" is a
#                               crisp predicate rather than an inference
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-pane-lib.sh
. "$SCRIPT_DIR/fm-supervisor-pane-lib.sh"
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
BEAT="$STATE/.last-watcher-beat"
DEADMAN_LOCK="$STATE/.continuity-deadman.lock"
AUTOARM_LOCK="$STATE/.claude-autoarm.lock"
ALARM_MARKER="$STATE/.continuity-deadman-alarm"
REWAKE_PENDING="$STATE/.rewake-pending"
DEADMAN_LOG="$STATE/.continuity-deadman.log"

GRACE=${FM_GUARD_GRACE:-300}
TICK=${FM_CONTINUITY_DEADMAN_TICK:-60}
INJECT_BACKOFF=${FM_CONTINUITY_DEADMAN_INJECT_BACKOFF:-600}
ALARM_INTERVAL=${FM_CONTINUITY_DEADMAN_ALARM_INTERVAL:-1800}
IDLE_EXIT=${FM_CONTINUITY_DEADMAN_IDLE_EXIT:-900}
LOG_MAX_BYTES=${FM_CONTINUITY_DEADMAN_LOG_MAX_BYTES:-262144}
# Injectable backends: the same verified set the away-mode daemon restricts
# itself to. zellij, orca, and cmux are real Firstmate backends with no verified
# composer/busy primitives for firstmate's OWN pane, so an unsupported backend
# alarms and records the outage but never types into a pane it cannot read.
INJECTABLE_BACKENDS="tmux herdr"
# Submit tuning, matching the away-mode daemon's confirmed-submit contract.
INJECT_CONFIRM_RETRIES=${FM_INJECT_CONFIRM_RETRIES:-3}
INJECT_CONFIRM_SLEEP=${FM_INJECT_CONFIRM_SLEEP:-0.5}

for _dm_num in GRACE TICK INJECT_BACKOFF ALARM_INTERVAL IDLE_EXIT LOG_MAX_BYTES; do
  case "${!_dm_num}" in
    ''|*[!0-9]*) printf 'continuity deadman: %s must be a whole number of seconds\n' "$_dm_num" >&2; exit 2 ;;
  esac
done
unset _dm_num
[ "$TICK" -gt 0 ] || TICK=60

# The active alert names this home, because the captain may run several.
FM_WEDGE_ALARM_TITLE="firstmate: supervision continuity LOST"

# --- logging ----------------------------------------------------------------
# Bounded and best-effort. This log is diagnostic evidence, never a supervision
# dependency: losing it costs a later diagnosis, not a recovery.
dm_log() {
  local size
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$DEADMAN_LOG" 2>/dev/null || return 0
  size=$(wc -c < "$DEADMAN_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$size" -ge "$LOG_MAX_BYTES" ] || return 0
  tail -c "$((LOG_MAX_BYTES / 2))" "$DEADMAN_LOG" > "$DEADMAN_LOG.trim" 2>/dev/null \
    && mv -f "$DEADMAN_LOG.trim" "$DEADMAN_LOG" 2>/dev/null
  rm -f "$DEADMAN_LOG.trim" 2>/dev/null || true
  return 0
}

# The shared alarm library logs through this file's log() when one exists.
# shellcheck disable=SC2329 # Called indirectly by bin/fm-wedge-alarm-lib.sh.
log() { dm_log "$@"; }

# --- singleton identity ------------------------------------------------------
# Same shape as the watcher lock: a live pid whose recorded process identity and
# home still match. A recycled pid, another home's record, or a dead holder is
# not a live deadman.
deadman_live_pid() {
  local pid lock_home lock_identity current_identity
  pid=$(cat "$DEADMAN_LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  lock_home=$(cat "$DEADMAN_LOCK/fm-home" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  lock_identity=$(cat "$DEADMAN_LOCK/pid-identity" 2>/dev/null || true)
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ] || return 1
  printf '%s' "$pid"
}

# The session-lock pid the live deadman was started under. A deadman only knows
# the pane of the session whose environment spawned it, so `ensure` from a later
# session treats a holder recorded under a different pid as not-this-session.
deadman_session_pid() {
  tr -d '[:space:]' < "$DEADMAN_LOCK/session-pid" 2>/dev/null || true
}

# Retire this home's live deadman from a caller that does not own it, and wait
# for its lock to clear. Returns 0 once no live holder remains.
retire_live_deadman() {  # <pid>
  local pid=$1 i=0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ]; do
    deadman_live_pid >/dev/null 2>&1 || return 0
    sleep 0.1
    i=$((i + 1))
  done
  ! deadman_live_pid >/dev/null 2>&1
}

# --- predicates --------------------------------------------------------------

# The session that owns this home. A missing or malformed lock, or a pid that is
# no longer a live harness process, means there is nothing left to keep alive
# for. The caller confirms a negative a second later before acting on it, because
# a transient `ps` failure must not retire the one process watching the watcher.
session_alive() {
  local pid
  pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid"
}

session_lock_pid() {
  tr -d '[:space:]' < "$STATE/.lock" 2>/dev/null || true
}

# Ordinary Stop-owned recovery already holds this home. Mirrors the turn-end
# guard's own claim check (bin/fm-turnend-guard.sh autoarm_owns_recovery).
autoarm_owns_recovery() {
  local pid role
  pid=$(cat "$AUTOARM_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$AUTOARM_LOCK" 2>/dev/null || true)
  fm_pid_alive "$pid" && [ "$role" = autoarm ]
}

# No watcher has beaten within the grace window AND none is healthy right now.
# The beacon mtime is the durable half, so this measure survives a deadman
# restart instead of resetting an in-memory timer that a restart would clear.
watcher_down_past_grace() {
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 1
  [ "$(fm_path_age "$BEAT")" -ge "$GRACE" ]
}

# A rewake was delivered to the primary and no handling turn ever drained the
# queue. bin/fm-claude-stop-autoarm.sh writes the marker immediately before its
# exit-2 rewake and bin/fm-wake-drain.sh clears it, so an aged marker is direct
# evidence that the woken turn never ran - the exact 2026-09-07 shape, where the
# rewake was delivered and its turn died on the API error.
rewake_unhandled_past_grace() {
  [ -e "$REWAKE_PENDING" ] || return 1
  [ "$(fm_path_age "$REWAKE_PENDING")" -ge "$GRACE" ]
}

# Sets DEADMAN_REASON when continuity is lost. Away mode, a home with nothing to
# supervise, and recovery already under way each return false: this process is a
# backstop for a silent chain, never a competitor to a working one.
DEADMAN_REASON=
continuity_lost() {
  DEADMAN_REASON=
  [ -e "$STATE/.afk" ] && return 1
  fm_supervision_needed "$STATE" "$GRACE" || return 1
  autoarm_owns_recovery && return 1
  if watcher_down_past_grace; then
    if [ -e "$BEAT" ]; then
      DEADMAN_REASON="no watcher has beaten for $(fm_path_age "$BEAT")s"
    else
      DEADMAN_REASON="no watcher has ever beaten in this home"
    fi
    return 0
  fi
  if rewake_unhandled_past_grace; then
    DEADMAN_REASON="a delivered watcher rewake has gone unhandled for $(fm_path_age "$REWAKE_PENDING")s"
    return 0
  fi
  return 1
}

# --- episode record ----------------------------------------------------------

episode_since() {
  local since
  since=$(sed -n 's/^since=\([0-9][0-9]*\)$/\1/p' "$ALARM_MARKER" 2>/dev/null | head -1)
  case "$since" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$since"
}

episode_open() {  # <now> <reason>
  local now=$1 reason=$2
  {
    printf 'since=%s\n' "$now"
    printf 'detected_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'reason=%s\n' "$reason"
    printf 'home=%s\n' "$FM_HOME"
    printf 'note=firstmate supervision is not running here; see docs/watcher-continuity.md "Continuity deadman"\n'
  } > "$ALARM_MARKER" 2>/dev/null || true
}

episode_close() {
  rm -f "$ALARM_MARKER" "$STATE/.continuity-deadman-last-inject" \
    "$STATE/.continuity-deadman-last-alarm" 2>/dev/null || true
}

# --- actions -----------------------------------------------------------------

# ONE durable wake per episode. The queue dedups by kind and key, and the record
# stays queued until the handling turn acknowledges it, so a single append is
# what makes the outage survive to the next drain.
append_continuity_wake() {  # <since>
  local since=$1
  fm_wake_append check watcher-continuity-lost \
    "check: watcher-continuity-lost since=$since - supervision stopped here and was not automatically restored; run bin/fm-wake-drain.sh, handle every queued wake, and confirm a live watcher before continuing" \
    || { dm_log "durable wake append FAILED for episode since=$since"; return 1; }
  dm_log "durable wake appended: watcher-continuity-lost since=$since"
  return 0
}

fire_alarm() {  # <since> <reason>
  local since=$1 reason=$2 stamp="$STATE/.continuity-deadman-last-alarm"
  if [ -e "$stamp" ] && [ "$(fm_path_age "$stamp")" -lt "$ALARM_INTERVAL" ]; then
    return 0
  fi
  : > "$stamp" 2>/dev/null || true
  dm_log "ALARM: supervision continuity lost ($reason); episode since=$since"
  wedge_alarm_notify \
    "firstmate supervision is NOT running in $FM_HOME - $reason. Queued work is safe; nothing is watching it." \
    "$ALARM_MARKER"
}

# Resolve the pane running firstmate. Both discovery helpers return non-zero when
# they fell through to the bare "firstmate:0"/tmux default, i.e. nothing in this
# process's environment actually identified a pane. That is not a pane we have
# any evidence for, so injection stands down rather than typing into a guess.
INJECT_TARGET=
INJECT_BACKEND=
resolve_inject_pane() {
  local target backend
  INJECT_TARGET=
  INJECT_BACKEND=
  target=$(discover_supervisor_target) || return 1
  backend=$(discover_supervisor_backend) || return 1
  [ -n "$target" ] && [ -n "$backend" ] || return 1
  INJECT_BACKEND=$backend
  fm_backend_list_contains "$INJECTABLE_BACKENDS" "$backend" || return 2
  INJECT_TARGET=$target
  return 0
}

# True only when firstmate's pane is resolvable, exists, and reads mid-turn. The
# watcher is always down for the whole of a rewake handling turn, so a running
# turn is the ordinary shape of "watcher down past grace", not an outage; the
# outage this file exists for left an IDLE pane behind. Anything short of a
# readable busy pane returns false so the durable measures alone still decide.
primary_turn_running() {
  resolve_inject_pane || return 1
  fm_backend_target_exists "$INJECT_BACKEND" "$INJECT_TARGET" || return 1
  fm_supervisor_pane_is_busy "$INJECT_TARGET" "$INJECT_BACKEND"
}

# Hand the encoded input to the pane. FM_CONTINUITY_DEADMAN_INJECT_EXEC replaces
# this one call so a test can prove the whole decision path without a real
# submit; unset means production and the real backend primitive runs.
submit_encoded() {  # <encoded>
  local encoded=$1 exec_override=${FM_CONTINUITY_DEADMAN_INJECT_EXEC:-} verdict
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      "$exec_override" "$INJECT_BACKEND" "$INJECT_TARGET" "$encoded" >/dev/null 2>&1
      return $?
      ;;
  esac
  verdict=$(fm_backend_send_text_submit "$INJECT_BACKEND" "$INJECT_TARGET" "$encoded" \
    "$INJECT_CONFIRM_RETRIES" "$INJECT_CONFIRM_SLEEP" "$INJECT_CONFIRM_SLEEP" "" general)
  [ "$verdict" = empty ]
}

# One bounded self-recovery injection. Every guard here is the away-mode
# daemon's: an existing target, an idle pane, and a positively-empty composer,
# because typing into a busy pane corrupts a running turn and typing into an
# unreadable one could reach a shell. A deferred injection simply retries on the
# next tick; only an actual submit attempt spends the backoff window.
try_self_recovery() {  # <reason>
  local reason=$1 stamp="$STATE/.continuity-deadman-last-inject" body encoded rc
  if [ -e "$stamp" ] && [ "$(fm_path_age "$stamp")" -lt "$INJECT_BACKOFF" ]; then
    return 0
  fi
  resolve_inject_pane
  rc=$?
  if [ "$rc" -eq 1 ]; then
    dm_log "self-recovery skipped: this process has no evidence of which pane runs firstmate"
    return 1
  fi
  if [ "$rc" -eq 2 ]; then
    dm_log "self-recovery skipped: backend '$INJECT_BACKEND' has no verified primitives for firstmate's own pane"
    return 1
  fi
  fm_backend_target_exists "$INJECT_BACKEND" "$INJECT_TARGET" || {
    dm_log "self-recovery skipped: firstmate's pane no longer exists"
    return 1
  }
  if fm_supervisor_pane_is_busy "$INJECT_TARGET" "$INJECT_BACKEND"; then
    dm_log "self-recovery deferred: a turn is already running"
    return 1
  fi
  if fm_supervisor_pane_input_pending "$INJECT_TARGET" "$INJECT_BACKEND"; then
    dm_log "self-recovery deferred: composer not confirmed empty"
    return 1
  fi
  body="SUPERVISION CONTINUITY LOST - $reason, supervision is still needed here, and no automatic recovery is under way. A turn that ends in an API error skips the Stop hooks that re-arm the watcher, so this input exists to start a real turn whose ordinary turn end restores it. Run bin/fm-wake-drain.sh first, handle every queued wake and run its exact WAKE_ACK_REQUIRED command, then end the turn normally."
  fm_operational_input_encode turn-end-guard "$body" encoded || {
    dm_log "self-recovery skipped: operational input could not be encoded"
    return 1
  }
  : > "$stamp" 2>/dev/null || true
  if submit_encoded "$encoded"; then
    dm_log "self-recovery injected one turn-end-guard input into firstmate's pane"
    return 0
  fi
  dm_log "self-recovery submit unconfirmed; retrying after the backoff window"
  return 1
}

# --- one evaluation ----------------------------------------------------------

DEADMAN_STARTED_AT=0
DEADMAN_SESSION_PID=
NEED_ABSENT_SINCE=0
TURN_DEFERRAL_LOGGED=0

# Returns 0 to keep looping, 1 to exit the loop.
deadman_tick() {
  local now since reason
  now=$(date +%s)

  if ! session_alive; then
    sleep 1
    if ! session_alive; then
      dm_log "exiting: the session that owned this home is gone"
      return 1
    fi
  fi
  if [ "$(session_lock_pid)" != "$DEADMAN_SESSION_PID" ]; then
    dm_log "exiting: the session that owned this home changed (pid $DEADMAN_SESSION_PID -> $(session_lock_pid)); the next arm starts a deadman from the new session"
    return 1
  fi

  if ! fm_supervision_needed "$STATE" "$GRACE"; then
    [ "$NEED_ABSENT_SINCE" -ne 0 ] || NEED_ABSENT_SINCE=$now
    if [ $((now - NEED_ABSENT_SINCE)) -ge "$IDLE_EXIT" ]; then
      dm_log "exiting: this home has had nothing to supervise for ${IDLE_EXIT}s"
      return 1
    fi
  else
    NEED_ABSENT_SINCE=0
  fi

  if ! continuity_lost; then
    TURN_DEFERRAL_LOGGED=0
    if [ -e "$ALARM_MARKER" ]; then
      if [ -e "$STATE/.afk" ]; then
        dm_log "episode closed: away mode now owns supervision here"
      else
        dm_log "recovered: supervision is running again"
      fi
      episode_close
    fi
    return 0
  fi
  reason=$DEADMAN_REASON

  # Startup settle: never alarm inside the first grace window of this process's
  # own life. A home whose first watcher has not started yet - a session start
  # with work already in flight - is not an outage, and one grace window of
  # latency is only ever paid by a deadman that just started, never by the one
  # already running when a chain dies under it.
  if [ $((now - DEADMAN_STARTED_AT)) -lt "$GRACE" ]; then
    return 0
  fi

  if [ ! -e "$ALARM_MARKER" ]; then
    if primary_turn_running; then
      if [ "$TURN_DEFERRAL_LOGGED" -eq 0 ]; then
        dm_log "not an outage yet: $reason, but firstmate's pane is mid-turn (the watcher is down by design during a handling turn)"
        TURN_DEFERRAL_LOGGED=1
      fi
      return 0
    fi
    TURN_DEFERRAL_LOGGED=0
    episode_open "$now" "$reason"
    append_continuity_wake "$now" || true
  fi
  since=$(episode_since) || since=$now
  fire_alarm "$since" "$reason"
  try_self_recovery "$reason" || true
  return 0
}

# --- modes -------------------------------------------------------------------

DEADMAN_HOLDS_LOCK=0
DEADMAN_SLEEPER=
# shellcheck disable=SC2317,SC2329 # Invoked by the traps below.
deadman_cleanup() {
  local status=$?
  [ -z "$DEADMAN_SLEEPER" ] || kill "$DEADMAN_SLEEPER" 2>/dev/null
  [ "$DEADMAN_HOLDS_LOCK" -eq 1 ] && fm_lock_release "$DEADMAN_LOCK"
  exit "$status"
}

cmd_run() {
  local once=0 pid identity
  case "${1:-}" in
    '') ;;
    --once) once=1 ;;
    *) usage ;;
  esac
  [ "$#" -le 1 ] || usage

  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  fm_lock_try_acquire "$DEADMAN_LOCK" || exit 0
  DEADMAN_HOLDS_LOCK=1
  trap deadman_cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  pid=${BASHPID:-$$}
  # Publish the identity `ensure` and `stop` verify against. If it cannot be
  # written and read back, this process would run invisibly - every later arm
  # would spawn another doomed child and `status` would report nothing running -
  # so stand down instead and leave the next arm a clean attempt.
  identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
  DEADMAN_SESSION_PID=$(session_lock_pid)
  if [ -z "$identity" ] \
    || ! printf '%s\n' "$FM_HOME" > "$DEADMAN_LOCK/fm-home" 2>/dev/null \
    || ! printf '%s\n' "$DEADMAN_SESSION_PID" > "$DEADMAN_LOCK/session-pid" 2>/dev/null \
    || ! printf '%s\n' "$identity" > "$DEADMAN_LOCK/pid-identity" 2>/dev/null \
    || [ "$(cat "$DEADMAN_LOCK/pid-identity" 2>/dev/null || true)" != "$identity" ]; then
    dm_log "standing down: this home's deadman lock could not record a verifiable identity"
    exit 0
  fi

  DEADMAN_STARTED_AT=$(date +%s)
  dm_log "started pid=$pid session=${DEADMAN_SESSION_PID:-none} grace=${GRACE}s tick=${TICK}s"
  if [ "$once" -eq 1 ]; then
    # One evaluation with no settle window: a single-shot run is a caller asking
    # for the verdict now, not a fresh daemon that might be watching a home whose
    # first watcher has not come up yet.
    DEADMAN_STARTED_AT=$((DEADMAN_STARTED_AT - GRACE))
    deadman_tick || true
    exit 0
  fi
  # The sleeper runs in the background and is waited on, because bash defers a
  # trapped signal until a foreground child returns: a foreground sleep would
  # make `stop` wait up to a whole tick for the TERM to land.
  while :; do
    deadman_tick || exit 0
    sleep "$TICK" &
    DEADMAN_SLEEPER=$!
    wait "$DEADMAN_SLEEPER" || true
    DEADMAN_SLEEPER=
  done
}

# Start the singleton, detached from the harness's process group and session.
# setsid(1) is the mechanism; macOS has no setsid, so it falls back to the same
# perl fork+setpgrp isolation bin/fm-procevent.sh already relies on for its
# detached runners, which is why that runner survived the outage this file
# exists for.
# The child is handed this process's ALREADY RESOLVED home so it can never
# re-derive a different one: `ensure` proved primary scope against exactly these
# paths, and the deadman must supervise that same home or nothing.
spawn_detached() {
  local program
  export FM_HOME
  export FM_ROOT_OVERRIDE="$FM_ROOT"
  [ -z "${FM_STATE_OVERRIDE:-}" ] || export FM_STATE_OVERRIDE
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SCRIPT_DIR/fm-continuity-deadman.sh" run >/dev/null 2>&1 </dev/null &
    return 0
  fi
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  program='defined(my $pid = fork) or exit 125;
    if ($pid == 0) {
      setpgrp(0, 0) or exit 125;
      exec @ARGV;
      exit 125;
    }
    exit 0;'
  perl -e "$program" "$SCRIPT_DIR/fm-continuity-deadman.sh" run >/dev/null 2>&1 </dev/null &
  return 0
}

# Always silent, always exit 0: this runs on every arm and at session start, and
# a diagnostic printed here would land in the arm's classified output. A failure
# to start is recorded in the deadman log and reported by `status`. A live
# deadman started under a different session-lock pid is retired and replaced
# here rather than left to notice at its own next tick, because a deadman knows
# only the pane of the session that spawned it and the new session's bootstrap
# and first arm are the earliest callers with the right environment.
cmd_ensure() {
  local i=0 live recorded current
  [ "$#" -eq 0 ] || usage
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  [ -e "$STATE/.afk" ] && exit 0
  if live=$(deadman_live_pid); then
    recorded=$(deadman_session_pid)
    current=$(session_lock_pid)
    [ -n "$current" ] && [ "$recorded" != "$current" ] || exit 0
    if ! retire_live_deadman "$live"; then
      dm_log "ensure: deadman pid=$live from session ${recorded:-none} would not retire; session $current stays with it"
      exit 0
    fi
    dm_log "ensure: retired deadman pid=$live from session ${recorded:-none}; starting one for session $current"
  fi
  spawn_detached
  while [ "$i" -lt 30 ]; do
    deadman_live_pid >/dev/null && exit 0
    sleep 0.1
    i=$((i + 1))
  done
  dm_log "ensure: could not confirm a live continuity deadman after starting one"
  exit 0
}

cmd_status() {
  local pid
  [ "$#" -eq 0 ] || usage
  if pid=$(deadman_live_pid); then
    printf 'continuity deadman: running pid=%s\n' "$pid"
  else
    printf 'continuity deadman: not running\n'
  fi
  if [ -e "$ALARM_MARKER" ]; then
    printf 'continuity deadman: OPEN OUTAGE EPISODE - %s\n' "$ALARM_MARKER"
    sed 's/^/  /' "$ALARM_MARKER" 2>/dev/null || true
  fi
  return 0
}

# Home-scoped stop: only the pid recorded in THIS home's deadman lock, verified
# by process identity first, so it can never signal another home's process or a
# recycled pid.
cmd_stop() {
  local pid i=0
  [ "$#" -eq 0 ] || usage
  pid=$(deadman_live_pid) || { printf 'continuity deadman: not running\n'; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid"; then
    printf 'continuity deadman: pid %s did not stop\n' "$pid" >&2
    return 1
  fi
  printf 'continuity deadman: stopped pid=%s\n' "$pid"
  return 0
}

usage() {  # [exit-code]
  local code=${1:-2} stream=2
  [ "$code" -eq 0 ] && stream=1
  {
    cat <<'EOF'
Usage:
  fm-continuity-deadman.sh ensure          start this home's singleton deadman if none is live
  fm-continuity-deadman.sh run [--once]    run the loop, or exactly one evaluation
  fm-continuity-deadman.sh status          report this home's deadman and any open outage episode
  fm-continuity-deadman.sh stop            stop this home's deadman and nothing else

`ensure` is idempotent and silent, and is called by bin/fm-watch-arm.sh on every
arm and by bin/fm-bootstrap.sh at session start. Read this file's header for the
full predicate, its environment knobs, and the state files it owns; the outage it
covers is described in docs/watcher-continuity.md "Continuity deadman".
EOF
  } >&"$stream"
  exit "$code"
}

deadman_main() {
  local mode=${1:-}
  [ "$#" -eq 0 ] || shift
  case "$mode" in
    ensure) cmd_ensure "$@" ;;
    run) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    stop) cmd_stop "$@" ;;
    -h|--help|help) usage 0 ;;
    *) usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  deadman_main "$@"
  exit $?
else
  # Library mode: only a test sources this file. Make it structurally impossible
  # for a sourced context to type into a real pane or fire a real desktop
  # notification, and export both so a deadman such a test later spawns inherits
  # the safe defaults. The executed branch above never runs this.
  : "${FM_CONTINUITY_DEADMAN_INJECT_EXEC:=discard}"
  : "${FM_WEDGE_ALARM_EXEC:=discard}"
  export FM_CONTINUITY_DEADMAN_INJECT_EXEC FM_WEDGE_ALARM_EXEC
fi
