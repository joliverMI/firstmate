#!/usr/bin/env bash
# Behavior tests for the per-home continuity deadman
# (bin/fm-continuity-deadman.sh, docs/watcher-continuity.md "Continuity
# deadman"), plus the delivered-rewake marker it reads
# (bin/fm-claude-stop-autoarm.sh writes it, bin/fm-wake-drain.sh clears it).
#
# Everything runs hermetically against fixture homes: a real bash process
# renamed `claude` stands in for the session that owns the home, a fake tmux
# binary stands in for firstmate's own pane, and a recorder stands in for the
# pane submit and for every alarm channel. NO test can type into a real pane or
# post a real notification - both seams are exported before the first case and
# the deadman itself defaults them to "discard" whenever it is sourced.
#
# The deadman's own clock is not faked; the windows it measures are compressed
# to test scale through the same environment knobs production uses
# (FM_GUARD_GRACE, FM_CONTINUITY_DEADMAN_*), and every durable measure it reads
# is a real file mtime.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-continuity-deadman)
fm_git_identity fmtest fmtest@example.invalid

# --- safety seams -----------------------------------------------------------
# The pane-submit recorder replaces the real backend submit; the alarm recorder
# replaces every notifier channel. Both are on disk so a deadman a test spawns
# detached inherits them too.
SEAM_DIR=$(fm_test_tmproot fm-continuity-deadman-seams)
cat > "$SEAM_DIR/inject-rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" >> "${FM_INJECT_LOG:-/dev/null}"
case "${FM_INJECT_FAIL:-}" in 1) exit 1 ;; esac
exit 0
REC
cat > "$SEAM_DIR/alarm-rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_ALARM_LOG:-/dev/null}"
exit 0
REC
chmod +x "$SEAM_DIR/inject-rec" "$SEAM_DIR/alarm-rec"
export FM_CONTINUITY_DEADMAN_INJECT_EXEC="$SEAM_DIR/inject-rec"
export FM_WEDGE_ALARM_EXEC="$SEAM_DIR/alarm-rec"
# Pin one alert channel so the recorder is reached on every platform; `auto`
# resolves to no channel at all off macOS, which would assert nothing.
export FM_WEDGE_ALARM_CHANNEL=osascript

# --- small local helpers -----------------------------------------------------
pid_alive() { kill -0 "${1:-}" 2>/dev/null; }

# wait_until <seconds> <command...>: poll until the command succeeds.
wait_until() {
  local limit=$1 i=0
  shift
  while [ "$i" -lt $((limit * 10)) ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- fake session harness ---------------------------------------------------
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"

# start_fake_session <home> -> echoes the pid it wrote into <home>/state/.lock.
# The trailing `:` matters: without it bash exec-replaces itself with `sleep`
# and the process stops looking like a harness. Its stdio is detached so a
# caller may capture this function's output without waiting on the child.
start_fake_session() {
  local home=$1 pid
  # shellcheck disable=SC2016 # $$ must expand inside the fake harness child, not here.
  "$FAKEBIN/claude" -c 'echo $$ > "$1/state/.lock"; sleep 600; :' _ "$home" >/dev/null 2>&1 </dev/null &
  pid=$!
  wait_until 5 test -s "$home/state/.lock" || fail "fake session never wrote the lock"
  printf '%s\n' "$pid"
}

# A fake tmux good enough for firstmate's own pane: an addressable
# `sess:win` target, a numeric cursor row, and a pane body the test chooses.
# The default body is an idle bordered composer, which the real classifier
# reads as confirmed-empty.
install_fake_tmux() {  # <fakebin-dir>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  list-panes) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_PANE_BODY:-}" ] && [ -f "${FM_FAKE_PANE_BODY:-}" ]; then
      cat "$FM_FAKE_PANE_BODY"
    else
      # The border rows must be at least as wide as the content row, or the real
      # classifier cannot prove the box is a composer at all.
      printf '\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n'
      printf '\xe2\x94\x82 >  \xe2\x94\x82\n'
      printf '\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n'
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}
install_fake_tmux "$FAKEBIN"

# --- fixture homes ----------------------------------------------------------

# make_home <name> [--no-work] -> echoes the home dir. A genuine plain checkout
# with the real bin/, one in-flight task so supervision is needed, and a live
# session lock.
make_home() {
  local name=$1 work=${2:-with-work} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  [ "$work" = --no-work ] || fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "backend=tmux"
  start_fake_session "$dir" > "$dir/session.pid"
  printf '%s\n' "$dir"
}

session_pid() { cat "$1/session.pid"; }

stop_home() {  # <home>
  local pid
  "$1/bin/fm-continuity-deadman.sh" stop >/dev/null 2>&1 || true
  pid=$(cat "$1/session.pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  return 0
}

# run_deadman <home> <mode...> - runs the real executable with the fixture home,
# the fake pane, and the compressed windows. Extra env comes from the caller's
# already-exported variables.
#
# The grace window stays comfortably longer than one process start: a case that
# stages a HEALTHY watcher touches its beacon during setup, so too short a grace
# would let that beacon age out mid-run and turn a real assertion into a race.
# Cases that need an EXPIRED window get there by absent state or a backdated
# marker instead, which no amount of startup time can undo.
run_deadman() {
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
  FM_GUARD_GRACE="${FM_GUARD_GRACE:-30}" \
  FM_CONTINUITY_DEADMAN_TICK="${FM_CONTINUITY_DEADMAN_TICK:-1}" \
  FM_CONTINUITY_DEADMAN_INJECT_BACKOFF="${FM_CONTINUITY_DEADMAN_INJECT_BACKOFF:-3600}" \
  FM_CONTINUITY_DEADMAN_ALARM_INTERVAL="${FM_CONTINUITY_DEADMAN_ALARM_INTERVAL:-3600}" \
  FM_SUPERVISOR_TARGET=sess:win FM_SUPERVISOR_BACKEND=tmux \
  FM_SUPERVISOR_PANE_HARNESS=claude \
    "$home/bin/fm-continuity-deadman.sh" "$@"
}

# install_live_watcher <home> - a watcher lock and beacon that satisfy the real
# fm_watcher_healthy: a live identity-matched holder for this home's own watcher
# path, with a fresh beat.
LIVE_WATCHER_PIDS=()
install_live_watcher() {
  local home=$1 pid identity lock="$1/state/.watch.lock"
  sleep 600 &
  pid=$!
  LIVE_WATCHER_PIDS+=("$pid")
  identity=$(fm_test_pid_identity "$pid")
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$lock/watcher-path"
  printf '%s\n' "$identity" > "$lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

AUTOARM_PIDS=()
install_autoarm_owner() {  # <home>
  local home=$1 pid lock="$1/state/.claude-autoarm.lock"
  sleep 600 &
  pid=$!
  AUTOARM_PIDS+=("$pid")
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf 'autoarm\n' > "$lock/role"
}

cleanup_all() {
  local pid
  for pid in "${LIVE_WATCHER_PIDS[@]:-}" "${AUTOARM_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_all EXIT INT TERM

# lock_owner_dirs <home>: the deadman lock's owner directories still on disk.
# The lock is a symlink to one such directory; a released lock leaves none.
lock_owner_dirs() {
  find "$1/state" -maxdepth 1 -name '.continuity-deadman.lock.owner.*' 2>/dev/null
}

queue_rows() {  # <home> [key]
  local home=$1 key=${2:-}
  if [ -n "$key" ]; then
    grep -c "	$key	" "$home/state/.wake-queue" 2>/dev/null || printf '0\n'
  else
    grep -c . "$home/state/.wake-queue" 2>/dev/null || printf '0\n'
  fi
}

# --- cases ------------------------------------------------------------------

test_records_outage_when_the_chain_is_silent() {
  local dir
  dir=$(make_home records-outage)
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman run --once exited non-zero"

  [ "$(queue_rows "$dir" watcher-continuity-lost)" = 1 ] \
    || fail "expected exactly one durable watcher-continuity-lost wake"
  grep -q 'check: watcher-continuity-lost since=[0-9][0-9]*' "$dir/state/.wake-queue" \
    || fail "durable wake payload did not carry the episode timestamp: $(cat "$dir/state/.wake-queue")"
  [ -f "$dir/state/.continuity-deadman-alarm" ] || fail "no durable episode record was written"
  grep -q '^since=[0-9][0-9]*$' "$dir/state/.continuity-deadman-alarm" \
    || fail "episode record has no since= stamp"
  grep -q '^osascript	' "$dir/alarm.log" || fail "the active alert channel never fired: $(cat "$dir/alarm.log" 2>/dev/null)"
  stop_home "$dir"
  pass "a silent supervision chain becomes one durable wake, one episode record, and an active alert"
}

test_one_wake_per_episode() {
  local dir
  dir=$(make_home one-wake-per-episode)
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "first run failed"
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "second run failed"
  [ "$(queue_rows "$dir" watcher-continuity-lost)" = 1 ] \
    || fail "a still-open episode appended a second durable wake"
  [ "$(grep -c . "$dir/alarm.log")" = 1 ] \
    || fail "the alert re-fired inside its own interval: $(cat "$dir/alarm.log")"
  stop_home "$dir"
  pass "an open episode appends one wake and alerts once per interval, not once per tick"
}

test_silent_while_away_mode_owns_supervision() {
  local dir
  dir=$(make_home away-mode-owns)
  : > "$dir/state/.afk"
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed under away mode"
  [ "$(queue_rows "$dir")" = 0 ] || fail "away mode did not suppress the durable wake"
  [ ! -e "$dir/state/.continuity-deadman-alarm" ] || fail "away mode did not suppress the episode record"
  [ ! -s "$dir/inject.log" ] || fail "away mode did not suppress injection: $(cat "$dir/inject.log")"
  stop_home "$dir"
  pass "away mode keeps the deadman inert, so only one process ever injects into the pane"
}

test_silent_while_autoarm_owns_recovery() {
  local dir
  dir=$(make_home autoarm-owns)
  install_autoarm_owner "$dir"
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed with a live auto-arm owner"
  [ "$(queue_rows "$dir")" = 0 ] || fail "a live autoarm owner did not suppress the wake"
  [ ! -s "$dir/inject.log" ] || fail "a live autoarm owner did not suppress injection"
  stop_home "$dir"
  pass "ordinary Stop-owned recovery already under way keeps the deadman out of the way"
}

test_silent_while_a_watcher_is_beating() {
  local dir
  dir=$(make_home watcher-beating)
  install_live_watcher "$dir"
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed with a healthy watcher"
  [ "$(queue_rows "$dir")" = 0 ] || fail "a healthy watcher did not keep the deadman silent"
  [ ! -e "$dir/state/.continuity-deadman-alarm" ] || fail "a healthy watcher still opened an episode"
  stop_home "$dir"
  pass "a live identity-matched watcher with a fresh beat is healthy and never alarms"
}

test_silent_when_nothing_needs_supervision() {
  local dir
  dir=$(make_home nothing-to-supervise --no-work)
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed on an idle home"
  [ "$(queue_rows "$dir")" = 0 ] || fail "an idle home alarmed"
  [ ! -e "$dir/state/.continuity-deadman-alarm" ] || fail "an idle home opened an episode"
  stop_home "$dir"
  pass "a home with nothing in flight is not an outage"
}

test_unhandled_rewake_is_its_own_trigger() {
  local dir
  dir=$(make_home unhandled-rewake)
  # A healthy, beating watcher: the beacon trigger is OFF, so only the delivered
  # rewake can fire. Age the marker past the grace window.
  install_live_watcher "$dir"
  : > "$dir/state/.rewake-pending"
  fm_test_age_file "$dir/state/.rewake-pending" 3600 || fail "could not backdate the rewake marker"
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed on the rewake trigger"
  [ "$(queue_rows "$dir" watcher-continuity-lost)" = 1 ] \
    || fail "a delivered-but-unhandled rewake did not raise the outage"
  grep -q 'rewake' "$dir/state/.continuity-deadman-alarm" \
    || fail "the episode record did not name the rewake as its reason: $(cat "$dir/state/.continuity-deadman-alarm")"
  stop_home "$dir"
  pass "a delivered rewake that no turn ever handled is a trigger on its own, even behind a live watcher"
}

test_self_recovery_injects_one_typed_input_on_the_backoff() {
  local dir encoded kind
  dir=$(make_home self-recovery)
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "first deadman run failed"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] \
    || fail "expected exactly one injection, got: $(cat "$dir/inject.log")"
  case "$(cut -f1,2 "$dir/inject.log")" in
    "tmux	sess:win") ;;
    *) fail "injection went to an unexpected pane: $(cut -f1,2 "$dir/inject.log")" ;;
  esac
  encoded=$(cut -f3 "$dir/inject.log")
  kind=$(printf '%s' "$encoded" | "$ROOT/bin/fm-operational-input.sh" kind) \
    || fail "the injected text is not a recognized operational input"
  [ "$kind" = turn-end-guard ] || fail "injected input has kind '$kind', expected turn-end-guard"

  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "second deadman run failed"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] \
    || fail "the backoff did not bound self-recovery: $(cat "$dir/inject.log")"
  stop_home "$dir"
  pass "self-recovery sends exactly one turn-end-guard input into firstmate's pane per backoff window"
}

test_unconfirmed_submit_still_spends_its_backoff_window() {
  local dir
  dir=$(make_home unconfirmed-submit)
  FM_INJECT_FAIL=1 FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed when the submit could not be confirmed"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] || fail "expected one attempted submit"
  grep -q 'submit unconfirmed' "$dir/state/.continuity-deadman.log" \
    || fail "an unconfirmed submit was not recorded: $(cat "$dir/state/.continuity-deadman.log")"
  # An unconfirmed submit may already have typed into the pane, so retrying it
  # immediately could concatenate two inputs into one corrupted turn. The backoff
  # is spent by the ATTEMPT, not by its success.
  FM_INJECT_FAIL=1 FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "second deadman run failed"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] \
    || fail "an unconfirmed submit was retried inside its backoff window: $(cat "$dir/inject.log")"
  stop_home "$dir"
  pass "an unconfirmed submit is recorded and still spends its backoff window rather than retyping"
}

test_self_recovery_defers_to_a_busy_pane() {
  local dir
  dir=$(make_home busy-pane)
  # Open the episode against an idle pane first, then let the pane go busy (the
  # injected recovery turn itself, say) with the backoff already spent.
  FM_CONTINUITY_DEADMAN_INJECT_BACKOFF=0 FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed opening the episode"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] || fail "expected the opening run to inject once"
  printf 'esc to interrupt\n' > "$dir/busy-body"
  FM_CONTINUITY_DEADMAN_INJECT_BACKOFF=0 FM_FAKE_PANE_BODY="$dir/busy-body" \
    FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed against a busy pane"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] \
    || fail "the deadman typed into a pane that was mid-turn: $(cat "$dir/inject.log")"
  [ "$(queue_rows "$dir" watcher-continuity-lost)" = 1 ] \
    || fail "a deferred injection must not disturb the durable record"
  [ -f "$dir/state/.continuity-deadman-alarm" ] || fail "a busy pane closed an open episode"
  grep -q 'a turn is already running' "$dir/state/.continuity-deadman.log" \
    || fail "the deferral was not recorded: $(cat "$dir/state/.continuity-deadman.log")"
  stop_home "$dir"
  pass "self-recovery defers to a running turn and keeps the open episode's record"
}

test_long_handling_turn_opens_no_episode() {
  local dir
  dir=$(make_home long-handling-turn)
  # Production grace, a beacon six minutes old, and a pane mid-turn: the shape of
  # every rewake handling turn that runs long, since the watcher is down by
  # design for the whole of it.
  : > "$dir/state/.last-watcher-beat"
  fm_test_age_file "$dir/state/.last-watcher-beat" 360 || fail "could not backdate the beacon"
  printf 'esc to interrupt\n' > "$dir/busy-body"
  FM_GUARD_GRACE=300 FM_FAKE_PANE_BODY="$dir/busy-body" \
    FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed during a long handling turn"
  [ "$(queue_rows "$dir")" = 0 ] || fail "a long handling turn queued an outage wake"
  [ ! -e "$dir/state/.continuity-deadman-alarm" ] || fail "a long handling turn opened an episode"
  [ ! -s "$dir/alarm.log" ] || fail "a long handling turn fired the active alert: $(cat "$dir/alarm.log")"
  [ ! -s "$dir/inject.log" ] || fail "a long handling turn was injected into: $(cat "$dir/inject.log")"
  grep -q 'mid-turn' "$dir/state/.continuity-deadman.log" \
    || fail "the running turn was not recorded as the reason for silence: $(cat "$dir/state/.continuity-deadman.log")"
  stop_home "$dir"
  pass "a six-minute handling turn with the pane mid-turn is not an outage"
}

test_idle_pane_after_a_dead_turn_still_alarms() {
  local dir
  dir=$(make_home idle-dead-turn)
  # The 2026-09-07 shape at production grace: the rewake was delivered, its turn
  # died on the API error, the beacon and the marker both aged past grace, and
  # the pane sits at an idle composer.
  : > "$dir/state/.last-watcher-beat"
  fm_test_age_file "$dir/state/.last-watcher-beat" 360 || fail "could not backdate the beacon"
  : > "$dir/state/.rewake-pending"
  fm_test_age_file "$dir/state/.rewake-pending" 360 || fail "could not backdate the rewake marker"
  FM_GUARD_GRACE=300 FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed on the dead-turn shape"
  [ "$(queue_rows "$dir" watcher-continuity-lost)" = 1 ] \
    || fail "an idle pane after a dead turn did not raise the outage"
  [ -f "$dir/state/.continuity-deadman-alarm" ] || fail "no episode was opened for the dead turn"
  grep -q '^osascript	' "$dir/alarm.log" || fail "the active alert never fired: $(cat "$dir/alarm.log" 2>/dev/null)"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] || fail "self-recovery did not inject into the idle pane"
  stop_home "$dir"
  pass "an idle pane after a dead rewake turn still alarms, records, and self-recovers"
}

test_self_recovery_defers_to_an_unreadable_composer() {
  local dir
  dir=$(make_home dead-shell-pane)
  # A bare shell prompt: no agent composer to prove empty, and typing there
  # could execute the message.
  printf 'user@host:~$ \n' > "$dir/shell-body"
  FM_FAKE_PANE_BODY="$dir/shell-body" FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "deadman failed against a dead-shell pane"
  [ ! -s "$dir/inject.log" ] || fail "the deadman typed into a pane with no proven agent composer"
  grep -q 'composer not confirmed empty' "$dir/state/.continuity-deadman.log" \
    || fail "the composer deferral was not recorded: $(cat "$dir/state/.continuity-deadman.log")"
  stop_home "$dir"
  pass "self-recovery refuses any pane whose composer is not positively proven empty"
}

test_episode_closes_when_supervision_returns() {
  local dir
  dir=$(make_home episode-closes)
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "first deadman run failed"
  [ -f "$dir/state/.continuity-deadman-alarm" ] || fail "no episode was opened"

  install_live_watcher "$dir"
  FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    run_deadman "$dir" run --once || fail "recovery run failed"
  [ ! -e "$dir/state/.continuity-deadman-alarm" ] || fail "the episode stayed open after recovery"
  grep -q 'recovered: supervision is running again' "$dir/state/.continuity-deadman.log" \
    || fail "recovery was not recorded: $(cat "$dir/state/.continuity-deadman.log")"
  [ "$(grep -c . "$dir/inject.log")" = 1 ] \
    || fail "injection continued after recovery: $(cat "$dir/inject.log")"
  stop_home "$dir"
  pass "recovery closes the episode and stops the injections"
}

test_ensure_starts_one_detached_singleton() {
  local dir pid second own_pgid dm_pgid
  dir=$(make_home ensure-singleton)
  install_live_watcher "$dir"
  run_deadman "$dir" ensure || fail "ensure exited non-zero"
  wait_until 5 test -e "$dir/state/.continuity-deadman.lock/pid" \
    || fail "ensure did not start a deadman"
  pid=$(cat "$dir/state/.continuity-deadman.lock/pid")
  pid_alive "$pid" || fail "the started deadman is not running"

  # Detachment is the whole point: the deadman must not share the process group
  # that started it, or the harness teardown that kills its hooks kills it too.
  own_pgid=$(ps -o pgid= -p $$ | tr -d '[:space:]')
  dm_pgid=$(ps -o pgid= -p "$pid" | tr -d '[:space:]')
  [ -n "$dm_pgid" ] || fail "could not read the deadman's process group"
  [ "$dm_pgid" != "$own_pgid" ] \
    || fail "the deadman shares its starter's process group ($dm_pgid) and would die with it"

  run_deadman "$dir" ensure || fail "second ensure exited non-zero"
  second=$(cat "$dir/state/.continuity-deadman.lock/pid")
  [ "$second" = "$pid" ] || fail "ensure started a second deadman ($second != $pid)"

  run_deadman "$dir" status | grep -q "running pid=$pid" || fail "status did not report the live deadman"
  run_deadman "$dir" stop >/dev/null || fail "stop exited non-zero"
  ! pid_alive "$pid" || fail "stop left the deadman running"
  stop_home "$dir"
  pass "ensure starts exactly one deadman, detached from its starter's process group, and stop retires it"
}

test_deadman_exits_when_the_session_is_gone() {
  local dir pid
  dir=$(make_home session-gone)
  install_live_watcher "$dir"
  run_deadman "$dir" ensure || fail "ensure exited non-zero"
  wait_until 5 test -e "$dir/state/.continuity-deadman.lock/pid" \
    || fail "ensure did not start a deadman"
  pid=$(cat "$dir/state/.continuity-deadman.lock/pid")

  kill "$(session_pid "$dir")" 2>/dev/null
  wait_until 20 sh -c "! kill -0 $pid 2>/dev/null" \
    || fail "the deadman outlived the session that owned its home"
  grep -q 'exiting: the session that owned this home is gone' "$dir/state/.continuity-deadman.log" \
    || fail "the exit was not recorded: $(cat "$dir/state/.continuity-deadman.log")"
  stop_home "$dir"
  pass "the deadman retires itself when the session that owned its home is gone"
}

test_deadman_retires_when_the_session_is_replaced() {
  local dir pid old_session new_session
  dir=$(make_home session-replaced)
  install_live_watcher "$dir"
  run_deadman "$dir" ensure || fail "ensure exited non-zero"
  wait_until 5 test -e "$dir/state/.continuity-deadman.lock/pid" \
    || fail "ensure did not start a deadman"
  pid=$(cat "$dir/state/.continuity-deadman.lock/pid")
  old_session=$(session_pid "$dir")

  # A relaunched primary writes its own pid into the same home's lock while the
  # old harness is still winding down. The deadman was started from the OLD
  # session's environment, so the pane it would inject into may no longer be
  # the one running firstmate; only a fresh deadman can learn the new one.
  new_session=$(start_fake_session "$dir")
  wait_until 5 sh -c "[ \"\$(cat '$dir/state/.lock')\" = $new_session ]" \
    || fail "the second session never took over the lock"
  wait_until 20 sh -c "! kill -0 $pid 2>/dev/null" \
    || fail "the deadman kept running for a session it was not started from"
  pid_alive "$old_session" || fail "the old session died on its own, so this case proved nothing"
  grep -q 'exiting: the session that owned this home changed' "$dir/state/.continuity-deadman.log" \
    || fail "the exit was not recorded: $(cat "$dir/state/.continuity-deadman.log")"
  kill "$new_session" 2>/dev/null
  stop_home "$dir"
  pass "a deadman retires when a different session takes over its home, so the next arm starts one from that session"
}

test_ensure_hands_the_detached_deadman_its_harness() {
  local dir
  dir=$(make_home detached-harness)
  printf 'esc to interrupt\n' > "$dir/busy-body"
  # No harness marker and no preset: the only evidence of which harness runs
  # firstmate is the fake `claude` in ensure's own ancestry, which the detached
  # child cannot see. The grace is short because every measure here is absent
  # state, which no amount of startup time can undo.
  # shellcheck disable=SC2016 # $1 must expand inside the fake harness child, not here.
  env -u CLAUDECODE -u FM_SUPERVISOR_PANE_HARNESS \
    PATH="$FAKEBIN:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_GUARD_GRACE=3 FM_CONTINUITY_DEADMAN_TICK=1 \
    FM_CONTINUITY_DEADMAN_INJECT_BACKOFF=3600 FM_CONTINUITY_DEADMAN_ALARM_INTERVAL=3600 \
    FM_SUPERVISOR_TARGET=sess:win FM_SUPERVISOR_BACKEND=tmux \
    FM_FAKE_PANE_BODY="$dir/busy-body" FM_INJECT_LOG="$dir/inject.log" FM_ALARM_LOG="$dir/alarm.log" \
    "$FAKEBIN/claude" -c '"$1" ensure; :' _ "$dir/bin/fm-continuity-deadman.sh" \
    || fail "ensure exited non-zero under the fake harness"
  wait_until 5 test -e "$dir/state/.continuity-deadman.lock/pid" \
    || fail "ensure did not start a deadman"
  wait_until 20 grep -q 'mid-turn' "$dir/state/.continuity-deadman.log" \
    || fail "the detached deadman never read the pane as mid-turn: $(cat "$dir/state/.continuity-deadman.log")"
  [ ! -e "$dir/state/.continuity-deadman-alarm" ] \
    || fail "the detached deadman opened an episode against a mid-turn pane: $(cat "$dir/state/.continuity-deadman-alarm")"
  [ "$(queue_rows "$dir")" = 0 ] || fail "the detached deadman queued an outage wake against a mid-turn pane"
  [ ! -s "$dir/alarm.log" ] || fail "the detached deadman alarmed against a mid-turn pane: $(cat "$dir/alarm.log")"
  [ ! -s "$dir/inject.log" ] || fail "the detached deadman typed into a mid-turn pane: $(cat "$dir/inject.log")"
  stop_home "$dir"
  pass "ensure resolves firstmate's harness from its own ancestry and hands it to the detached deadman, so a mid-turn pane still reads busy there"
}

test_ensure_replaces_a_superseded_sessions_deadman() {
  local dir old_pid new_pid old_session new_session
  dir=$(make_home session-superseded)
  install_live_watcher "$dir"
  FM_CONTINUITY_DEADMAN_TICK=600 run_deadman "$dir" ensure || fail "ensure exited non-zero"
  wait_until 5 test -e "$dir/state/.continuity-deadman.lock/pid" \
    || fail "ensure did not start a deadman"
  old_pid=$(cat "$dir/state/.continuity-deadman.lock/pid")
  old_session=$(session_pid "$dir")

  # The new session's bootstrap runs `ensure` the moment it holds the lock; the
  # old deadman is deep inside a tick and cannot notice the change on its own.
  new_session=$(start_fake_session "$dir")
  wait_until 5 sh -c "[ \"\$(cat '$dir/state/.lock')\" = $new_session ]" \
    || fail "the second session never took over the lock"
  FM_CONTINUITY_DEADMAN_TICK=600 run_deadman "$dir" ensure || fail "ensure exited non-zero for the new session"
  ! pid_alive "$old_pid" || fail "ensure left the old session's deadman running"
  pid_alive "$old_session" || fail "the old session died on its own, so this case proved nothing"
  [ "$(lock_owner_dirs "$dir" | grep -c .)" -le 1 ] \
    || fail "the retired deadman left its lock owner directory behind: $(lock_owner_dirs "$dir")"
  new_pid=$(cat "$dir/state/.continuity-deadman.lock/pid" 2>/dev/null || true)
  [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] \
    || fail "ensure did not start a deadman for the new session (lock pid: '$new_pid')"
  pid_alive "$new_pid" || fail "the replacement deadman is not running"
  run_deadman "$dir" status | grep -q "running pid=$new_pid" \
    || fail "status does not report the replacement deadman"

  FM_CONTINUITY_DEADMAN_TICK=600 run_deadman "$dir" ensure || fail "third ensure exited non-zero"
  [ "$(cat "$dir/state/.continuity-deadman.lock/pid")" = "$new_pid" ] \
    || fail "ensure replaced a deadman that already belonged to the current session"
  kill "$new_session" 2>/dev/null
  stop_home "$dir"
  pass "ensure retires a deadman started under a superseded session and starts one for the current session at once"
}

test_stop_is_prompt_inside_a_long_tick() {
  local dir pid
  dir=$(make_home stop-prompt)
  install_live_watcher "$dir"
  FM_CONTINUITY_DEADMAN_TICK=600 run_deadman "$dir" ensure || fail "ensure exited non-zero"
  wait_until 5 test -e "$dir/state/.continuity-deadman.lock/pid" \
    || fail "ensure did not start a deadman"
  pid=$(cat "$dir/state/.continuity-deadman.lock/pid")
  # Let the loop settle into its sleep before asking it to stop.
  sleep 1
  run_deadman "$dir" stop >/dev/null 2>&1 || fail "stop reported failure while the deadman was inside its tick"
  ! pid_alive "$pid" || fail "stop returned with the deadman still running"
  [ ! -e "$dir/state/.continuity-deadman.lock/pid" ] || fail "stop left the lock behind"
  [ -z "$(lock_owner_dirs "$dir")" ] \
    || fail "the released lock left an owner directory behind: $(lock_owner_dirs "$dir")"
  stop_home "$dir"
  pass "stop lands immediately even when the deadman is deep inside a production-length tick, and releases its lock completely"
}

test_ensure_is_inert_outside_a_primary_home() {
  local base worktree
  base="$TMP_ROOT/worktree-base"
  worktree="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$worktree" fm/deadman-test-branch
  mkdir -p "$worktree/state"
  : > "$worktree/AGENTS.md"
  cp -R "$ROOT/bin" "$worktree/bin"
  fm_write_meta "$worktree/state/t1.meta" "window=sess:fm-t1" "backend=tmux"
  PATH="$FAKEBIN:$PATH" FM_HOME="$worktree" FM_ROOT_OVERRIDE="$worktree" \
    "$worktree/bin/fm-continuity-deadman.sh" ensure || fail "ensure exited non-zero in a task worktree"
  [ ! -e "$worktree/state/.continuity-deadman.lock" ] \
    || fail "a crewmate task worktree started a deadman"
  pass "a linked task worktree never starts a deadman"
}

test_wake_drain_clears_the_delivered_rewake_marker() {
  local dir
  dir=$(make_home drain-clears-rewake --no-work)
  : > "$dir/state/.rewake-pending"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "wake drain exited non-zero"
  [ ! -e "$dir/state/.rewake-pending" ] \
    || fail "the drain left a delivered-rewake marker behind, so a handled rewake would read as unhandled"
  stop_home "$dir"
  pass "a handling turn's drain retires the delivered-rewake marker"
}

test_records_outage_when_the_chain_is_silent
test_one_wake_per_episode
test_silent_while_away_mode_owns_supervision
test_silent_while_autoarm_owns_recovery
test_silent_while_a_watcher_is_beating
test_silent_when_nothing_needs_supervision
test_unhandled_rewake_is_its_own_trigger
test_self_recovery_injects_one_typed_input_on_the_backoff
test_unconfirmed_submit_still_spends_its_backoff_window
test_self_recovery_defers_to_a_busy_pane
test_long_handling_turn_opens_no_episode
test_idle_pane_after_a_dead_turn_still_alarms
test_self_recovery_defers_to_an_unreadable_composer
test_episode_closes_when_supervision_returns
test_ensure_starts_one_detached_singleton
test_deadman_exits_when_the_session_is_gone
test_deadman_retires_when_the_session_is_replaced
test_ensure_hands_the_detached_deadman_its_harness
test_ensure_replaces_a_superseded_sessions_deadman
test_stop_is_prompt_inside_a_long_tick
test_ensure_is_inert_outside_a_primary_home
test_wake_drain_clears_the_delivered_rewake_marker
