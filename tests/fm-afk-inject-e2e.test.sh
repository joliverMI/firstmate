#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's injection path. It covers three operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line is typed into the
#     supervisor pane with NO Enter, then an escalation fires. The daemon must
#     DEFER (not merge the digest into the human's text). After the pane goes
#     idle, the digest arrives as a separate, clean submission.
#
#   Scenario B (swallowed-Enter): the first Enter the daemon sends is dropped.
#     The daemon must retry Enter (NOT retype the digest) and deliver exactly
#     ONE clean submission: no concatenation, no duplicate.
#
#   Scenario C (normal digest): no human input and no swallowed Enter.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (FM_STATE_OVERRIDE)
# and the test pane (FM_SUPERVISOR_TARGET). Nothing touches the live fleet.
# FM_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      rm -f "$STATE_DIR/.swallow-enter"
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake crewmate window (the watcher lists fm-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses cursor_y + capture-pane) can detect
# typed text in this tmux environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this tmux environment" >&2
  local _cy _line
  _cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{cursor_y}' 2>/dev/null)
  echo "  cursor_y=$_cy" >&2
  echo "  pane capture (first 10 lines):" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | head -10 | sed 's/^/    /' >&2
  _line=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | sed -n "$((_cy + 1))p")
  echo "  cursor line: '$_line'" >&2
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  fail "pane_input_pending self-check failed"
}

# start_composer_loop <pane-target> <log-file>: run another copy of the
# supervisor composer loop in <pane-target>, logging every submitted line to its
# OWN file, and wait until it has drawn the agent prompt glyph the composer
# classifier proves as an empty agent composer. A second, independently logged
# composer is what lets Scenario D tell "delivered to the addressed pane" apart
# from "delivered to the window", which is the whole point of a pane-qualified
# address.
start_composer_loop() {  # <pane-target> <log-file>
  local target=$1 logfile=$2 i=0
  : > "$logfile"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" \
    "bash '$LOOP_SCRIPT' '$logfile'" Enter
  while [ "$i" -lt 50 ]; do
    case "$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null)" in
      *❯*) return 0 ;;
    esac
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  # Assert: the digest was NOT injected while the pane had pending input.
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while pane had pending input (merged with human text?)"
  fi

  # Assert: no merged line (human text + digest) was submitted.
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  # Now submit the human's text (Enter). The pane goes idle.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  sleep 0.5

  # Wait for the daemon to retry injection (housekeeping tick = 1s).
  sleep 6

  # Assert: human text was submitted alone (as a user message).
  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"

  # Assert: digest arrived after the pane went idle.
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not injected after pane went idle"

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;  # correct
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;  # correct
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  # Arm the swallow: the daemon's first Enter will be dropped by the shim.
  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Wait for the daemon to process the escalation and attempt inject (with the
  # swallowed Enter, the retry path fires).
  sleep 8

  # Assert: exactly ONE terminal-safe marker in the log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;  # correct: starts with the terminal-safe sentinel marker
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: exactly ONE user-message line was submitted (no spurious empty lines
  # from extra Enters). The log should have exactly 1 injection line and 0 user
  # lines.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted empty line?)"

  stop_daemon
  pass "Scenario B: swallowed Enter produces exactly one clean digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# No human input, no swallowed Enter: a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract that the deleted
# fake-tmux units used to assert via internal send-keys counts.

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 6

  # Exactly one terminal-safe marker in the submitted log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would log >1 line),
  # and no spurious user-classified lines were submitted.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

# --- Scenario D: the away channel's own supervisor-target shapes -------------
# Scenarios A-C address the supervisor pane by a colon-free `%N` pane id, which
# every tmux target resolver answers identically - so none of them can tell
# whether inject_msg still asks for the resolution its target actually needs.
# The two shapes that DO depend on it are exactly the two the away channel is
# configured with in production:
#
#   FM_SUPERVISOR_TARGET="firstmate:0.1" - an operator-declared, pane-qualified
#     address for the captain's own pane.
#   FM_SUPERVISOR_TARGET unset           - FM_SUPERVISOR_TARGET_DEFAULT, the
#     literal "firstmate:0", a session plus a window INDEX.
#
# bin/backends/tmux.sh resolves a recorded task window by exact NAME and refuses
# anything else, because a dead `sess:fm-1.0` re-read as pane 0 of a live `fm-1`
# types a steer into an unrelated crew's composer. Neither shape above is a
# window name, so both are refused under that (default) reading, and the away
# channel opts in to the general resolver instead. If that opt-in is ever
# dropped from inject_msg's own call, the daemon keeps passing its upstream
# existence gate - that probe still uses the general resolver - and then fails
# at the submit, logging "inject failed" and buffering every escalation
# indefinitely: the fleet's only route to the Admiral closes silently. This
# scenario is what makes that regression loud.
#
# The daemon is deliberately NOT running here: inject_msg is invoked directly,
# so what is under test is the injector's own argument list rather than any
# scheduling around it.
test_scenario_d() {
  reset_state
  afk_enter "$STATE_DIR"

  local win pane_idx pane_target pane_log rc out
  local fm_win fm_log fm_pane

  win=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{window_index}')
  [ -n "$win" ] || fail "Scenario D: could not read the supervisor window index"

  # (i) Operator-declared, pane-qualified: a REAL second pane, so that a
  # delivery which landed on the window (or its first/active pane) instead of
  # the addressed one shows up as a miss in this pane's log and a stray line in
  # the original pane's.
  "$REAL_TMUX" -L "$SOCKET" split-window -d -t "$SUPERVISOR_PANE" \
    || fail "Scenario D: could not split a second supervisor pane"
  pane_idx=$("$REAL_TMUX" -L "$SOCKET" list-panes -t "supervisor:$win" -F '#{pane_index}' | tail -1)
  [ -n "$pane_idx" ] || fail "Scenario D: could not read the second pane's index"
  pane_target="supervisor:$win.$pane_idx"
  pane_log="$STATE_DIR/submitted-pane.log"

  # Fixture proof: the address is genuinely pane-qualified, not a window whose
  # NAME happens to be "<win>.<pane>" (which would resolve under either reading
  # and prove nothing).
  if "$REAL_TMUX" -L "$SOCKET" list-windows -t '=supervisor' -F '#{window_name}' \
     | grep -Fqx "$win.$pane_idx"; then
    fail "Scenario D: fixture invalid - a window is literally named '$win.$pane_idx'"
  fi

  start_composer_loop "$pane_target" "$pane_log" \
    || fail "Scenario D: the second supervisor pane's composer never became ready"
  : > "$LOG_FILE"

  rc=0
  # shellcheck disable=SC2030,SC2031 # Subshell-local by design: each call
  # runs inject_msg under exactly one supervisor-target configuration, and
  # neither may leak into the other or back into the surrounding test.
  (
    export PATH="$TMUX_SHIM_DIR:$PATH"
    export FM_SUPERVISOR_TARGET="$pane_target"
    export FM_SUPERVISOR_BACKEND=tmux
    export FM_INJECT_CONFIRM_SLEEP=0.3
    export FM_INJECT_CONFIRM_RETRIES=5
    export LOG="$STATE_DIR/inject-pane.log"
    inject_msg "Supervisor escalate: away channel reaches a pane-qualified target" "$STATE_DIR"
  ) || rc=$?
  out=$(cat "$STATE_DIR/inject-pane.log" 2>/dev/null || true)
  [ "$rc" -eq 0 ] \
    || fail "Scenario D: inject_msg refused the pane-qualified '$pane_target' (rc=$rc); the away channel cannot reach an operator-declared pane"$'\n'"$out"

  grep -q 'away channel reaches a pane-qualified target' "$pane_log" \
    || fail "Scenario D: the digest never reached the addressed pane '$pane_target'"$'\n'"$out"
  local pane_line pane_hex
  pane_line=$(grep 'away channel reaches a pane-qualified target' "$pane_log" | head -1)
  case "$pane_line" in
    *injection) ;;
    *) fail "Scenario D: pane-qualified digest misclassified (expected injection): $pane_line" ;;
  esac
  pane_hex=$(printf '%s' "$pane_line" | cut -f1)
  case "$pane_hex" in
    e281a3*) ;;
    *) fail "Scenario D: pane-qualified digest does not start with the sentinel marker (hex: $pane_hex)" ;;
  esac
  if grep -q 'away channel reaches a pane-qualified target' "$LOG_FILE"; then
    fail "Scenario D: the digest addressed to pane $pane_idx was delivered into the window's OTHER pane"$'\n'"$(cat "$LOG_FILE")"
  fi
  pass "Scenario D: the away-mode injector delivers to an operator-declared session:window.pane target, and only to that pane"

  # (ii) The built-in default, with FM_SUPERVISOR_TARGET unset: the literal
  # "firstmate:0" of FM_SUPERVISOR_TARGET_DEFAULT - a session plus a window
  # INDEX, not a window name. The window is renumbered to index 0 so the
  # default's own address is exercised verbatim regardless of this machine's
  # base-index setting.
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -x 200 -y 50 \
    || fail "Scenario D: could not create the default-target session"
  fm_win=$("$REAL_TMUX" -L "$SOCKET" list-windows -t '=firstmate' -F '#{window_index}' | head -1)
  [ -n "$fm_win" ] || fail "Scenario D: could not read the default-target window index"
  if [ "$fm_win" != 0 ]; then
    "$REAL_TMUX" -L "$SOCKET" move-window -s "firstmate:$fm_win" -t firstmate:0 \
      || fail "Scenario D: could not renumber the default-target window to index 0"
  fi
  [ "$FM_SUPERVISOR_TARGET_DEFAULT" = "firstmate:0" ] \
    || fail "Scenario D: FM_SUPERVISOR_TARGET_DEFAULT is '$FM_SUPERVISOR_TARGET_DEFAULT'; this fixture builds the session its old value named"
  if "$REAL_TMUX" -L "$SOCKET" list-windows -t '=firstmate' -F '#{window_name}' | grep -Fqx 0; then
    fail "Scenario D: fixture invalid - the default target's window is literally NAMED '0'"
  fi
  fm_pane=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t firstmate:0 '#{pane_id}')
  [ -n "$fm_pane" ] || fail "Scenario D: could not read the default-target pane id"
  fm_log="$STATE_DIR/submitted-default.log"
  start_composer_loop "$fm_pane" "$fm_log" \
    || fail "Scenario D: the default-target composer never became ready"

  rc=0
  # shellcheck disable=SC2030,SC2031 # Subshell-local by design: each call
  # runs inject_msg under exactly one supervisor-target configuration, and
  # neither may leak into the other or back into the surrounding test.
  (
    export PATH="$TMUX_SHIM_DIR:$PATH"
    unset FM_SUPERVISOR_TARGET
    export FM_SUPERVISOR_BACKEND=tmux
    export FM_INJECT_CONFIRM_SLEEP=0.3
    export FM_INJECT_CONFIRM_RETRIES=5
    export LOG="$STATE_DIR/inject-default.log"
    inject_msg "Supervisor escalate: away channel reaches its default target" "$STATE_DIR"
  ) || rc=$?
  out=$(cat "$STATE_DIR/inject-default.log" 2>/dev/null || true)
  [ "$rc" -eq 0 ] \
    || fail "Scenario D: inject_msg refused FM_SUPERVISOR_TARGET_DEFAULT ('$FM_SUPERVISOR_TARGET_DEFAULT') (rc=$rc); an unconfigured away channel cannot reach the captain at all"$'\n'"$out"
  grep -q 'away channel reaches its default target' "$fm_log" \
    || fail "Scenario D: the digest never reached the default target '$FM_SUPERVISOR_TARGET_DEFAULT'"$'\n'"$out"
  local fm_line
  fm_line=$(grep 'away channel reaches its default target' "$fm_log" | head -1)
  case "$fm_line" in
    *injection) ;;
    *) fail "Scenario D: default-target digest misclassified (expected injection): $fm_line" ;;
  esac
  pass "Scenario D: the away-mode injector still delivers to its own unconfigured default target"

  "$REAL_TMUX" -L "$SOCKET" kill-session -t '=firstmate' 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" kill-pane -t "$pane_target" 2>/dev/null || true
  afk_exit "$STATE_DIR"
}

test_scenario_a
test_scenario_b
test_scenario_c
test_scenario_d

echo "all e2e injection tests passed"
