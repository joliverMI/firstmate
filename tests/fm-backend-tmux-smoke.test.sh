#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# kill_window_id <window-id>: kill a window by id, but never with an empty
# target - `tmux kill-window -t ""` does not fail, it destroys the CURRENT
# window (verified on tmux 3.4), so an id that failed to resolve would silently
# take out a live window this suite is still asserting against. Mirrors the
# empty/malformed target refusal bin/backends/tmux.sh already applies before
# invoking tmux, which raw `tmux` calls here would otherwise bypass.
kill_window_id() {  # <window-id>
  local wid=${1:-}
  [ -n "$wid" ] || return 0
  tmux kill-window -t "$wid" 2>/dev/null || true
}

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- fm_backend_target_exists must not false-positive from inside a tmux client ---
# `tmux display-message -p -t <target>` silently falls back to some other live
# pane and still exits 0 when the exact target is missing but the queried
# server already has another session on it - exactly the case for every real
# firstmate process, which always runs inside its own live tmux session. A
# probe run from a shell with NO ambient tmux session reproduces nothing: the
# fallback needs a live session to fall back TO. So this assertion runs the
# actual check FROM INSIDE a real pane of the still-live "$SESSION" session
# (not from the outer test process), the one condition that makes the false
# positive reproducible; running it any other way would pass today and prove
# nothing about the bug this guards.
# The wait/assert token is deliberately never typed contiguously in the sent
# command itself (same discipline as wait_for_capture_text's own header
# comment): the format string and its substituted word are separate shell
# tokens, so the terminal's echo of the still-typed command line cannot
# false-positive-match before the command has actually run and produced it.
fm_backend_tmux_send_text_line "$TARGET" \
  "export PATH=\"$SHIM_DIR:\$PATH\" && . \"$ROOT/bin/fm-backend.sh\" && if fm_backend_target_exists tmux nosuchsession:nosuchwindow; then printf 'LIVENESS-RESULT:%s\\n' EXISTS; else printf 'LIVENESS-RESULT:%s\\n' MISSING; fi" \
  || fail "fm_backend_tmux_send_text_line failed for the in-pane liveness probe"
# Waits on the expected (fixed-code) outcome; a buggy result never satisfies
# it, so the wait harmlessly times out and the unconditional capture below
# still catches the actual EXISTS/MISSING outcome either way.
wait_for_capture_text "$TARGET" "LIVENESS-RESULT:MISSING" 150
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after the in-pane liveness probe"
case "$out" in
  *LIVENESS-RESULT:MISSING*) : ;;
  *LIVENESS-RESULT:EXISTS*) fail "fm_backend_target_exists reported a nonexistent session:window as existing when run from inside a live tmux client"$'\n'"$out" ;;
  *) fail "fm_backend_target_exists's in-pane liveness probe produced an unexpected result"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_target_exists correctly reports a nonexistent target as not-existing even when run from inside a live tmux client"

# --- fm_backend_target_exists: exact endpoint resolution, no prefix fallback ---
# tmux resolves a bare `session:window` target by PREFIX, so an exit-status
# probe of the raw target reports a destroyed endpoint as alive whenever a
# surviving session or window name merely extends the dead one - the shape of
# the reported incident (a destroyed session `remote` answered by a live
# `remote-backup`), and routine here because task windows are named
# fm-<task-id> and task ids collide by prefix all the time. Both assertions
# below run against real tmux and fail on a probe that omits tmux's
# exact-match `=` pin.
if fm_backend_target_exists tmux "${SESSION%?}:$WINDOW"; then
  fail "fm_backend_target_exists matched a dead session name that is a prefix of the live '$SESSION'"
fi
pass "real tmux: fm_backend_target_exists rejects a session name that is only a prefix of a live session"

if fm_backend_target_exists tmux "$SESSION:${WINDOW%?}"; then
  fail "fm_backend_target_exists matched a dead window name that is a prefix of the live '$WINDOW'"
fi
pass "real tmux: fm_backend_target_exists rejects a window name that is only a prefix of a live window"

fm_backend_target_exists tmux "$TARGET" \
  || fail "fm_backend_target_exists must still report the live '$TARGET' as existing"
pass "real tmux: fm_backend_target_exists still reports the exact live session:window as existing"

# --- fm_backend_target_exists: window names containing a dot ------------------
# tmux splits the last `.` off a window component as a PANE specifier before
# any name matching, and its `=` exact-match pin does not suppress that, so a
# target-string probe reports a LIVE window whose name contains a dot as dead
# (`can't find window: fm-release-1` for a live `fm-release-1.2`). Task ids
# admit dots (fm_task_id_path_safe allows [A-Za-z0-9._-]) and fm-spawn.sh
# records `window=<session>:fm-<id>`, so this shape is reachable, and a
# false-DEAD is the more damaging direction: fm-control.sh refuses further
# control actions on an endpoint it believes disappeared.
DOTTED_WINDOW="fm-release-1.2"
fm_backend_tmux_create_task "$SESSION" "$DOTTED_WINDOW" "$HOME" \
  || fail "could not create a real window whose name contains a dot"
fm_backend_target_exists tmux "$SESSION:$DOTTED_WINDOW" \
  || fail "fm_backend_target_exists reported the live dotted-name window '$SESSION:$DOTTED_WINDOW' as dead"
pass "real tmux: fm_backend_target_exists resolves a live window name containing a dot"

if fm_backend_target_exists tmux "$SESSION:fm-release-1"; then
  fail "fm_backend_target_exists matched 'fm-release-1', the pane-split prefix of the live '$DOTTED_WINDOW'"
fi
pass "real tmux: a dotted window name is matched byte-exactly, not by its pane-split prefix"

if fm_backend_target_exists tmux "$SESSION:fm-release-1.9"; then
  fail "fm_backend_target_exists matched a dotted window name that does not exist"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent dotted window name"

fm_backend_tmux_kill "$SESSION:$DOTTED_WINDOW"
# Kill by window id as well, belt and braces: fm_backend_tmux_kill now resolves
# a dotted window NAME through fm_backend_tmux_exact_target_named and really
# does remove it (asserted directly further below), but it is best-effort and
# reports success either way, so this fallback guarantees the window cannot
# leak and perturb the pane-addressing assertions that follow.
dotted_wid=$(tmux list-windows -t "=$SESSION" -F '#{window_name} #{window_id}' \
  | while read -r n i; do [ "$n" = "$DOTTED_WINDOW" ] && printf '%s' "$i" && break; done)
kill_window_id "$dotted_wid"

# --- fm_backend_target_exists: pane-qualified session:window.pane targets -----
# `session:window.pane` is a real tmux target form, and after the dotted-name
# fix above it is the COMPETING reading of the very same string, so both have
# to resolve. A live pane must never read missing: bin/fm-send.sh gates every
# explicit one-colon target through this function, so a false negative here
# refuses a send to a pane that send-keys would have reached.
PANE_WINDOW="fm-panes"
PANE_WID=$(fm_backend_tmux_create_task "$SESSION" "$PANE_WINDOW" "$HOME") \
  || fail "could not create a real window to address panes within"
tmux split-window -t "$PANE_WID" || fail "could not split a second real pane"
pane_idx=$(tmux list-panes -t "$PANE_WID" -F '#{pane_index}' | tail -1)
pane_pid=$(tmux list-panes -t "$PANE_WID" -F '#{pane_id}' | tail -1)
[ -n "$pane_idx" ] && [ -n "$pane_pid" ] || fail "could not read a real pane index/id"

fm_backend_target_exists tmux "$SESSION:$PANE_WINDOW.$pane_idx" \
  || fail "fm_backend_target_exists reported the live pane '$SESSION:$PANE_WINDOW.$pane_idx' as missing"
pass "real tmux: fm_backend_target_exists resolves a pane-qualified session:window.pane target"

fm_backend_target_exists tmux "$SESSION:$PANE_WINDOW.$pane_pid" \
  || fail "fm_backend_target_exists reported the live pane id '$SESSION:$PANE_WINDOW.$pane_pid' as missing"
pass "real tmux: a pane-qualified target also accepts a %N pane id after the dot"

if fm_backend_target_exists tmux "$SESSION:$PANE_WINDOW.99999"; then
  fail "fm_backend_target_exists reported a nonexistent pane index as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a pane-qualified target whose pane does not exist"

if fm_backend_target_exists tmux "${SESSION%?}:$PANE_WINDOW.$pane_idx"; then
  fail "a pane-qualified target resolved under a session name that is only a prefix of '$SESSION'"
fi
pass "real tmux: a pane-qualified target still requires an exact session name"

# The window component of a pane-qualified target may be an INDEX as well as a
# name - `sess:1.2` addresses pane 2 of window index 1, and tmux resolves it -
# so the same live pane must answer through either spelling. This is the shape
# a captain reaches by pinning a pane inside FM_SUPERVISOR_TARGET_DEFAULT
# ("firstmate:0", already an index): FM_SUPERVISOR_TARGET=firstmate:0.1.
pane_win_idx=$(tmux list-windows -t "=$SESSION" -F '#{window_index} #{window_name}' \
  | while read -r i n; do [ "$n" = "$PANE_WINDOW" ] && printf '%s' "$i" && break; done)
[ -n "$pane_win_idx" ] || fail "could not read the window index of the live '$PANE_WINDOW'"

fm_backend_target_exists tmux "$SESSION:$pane_win_idx.$pane_idx" \
  || fail "fm_backend_target_exists reported the live pane '$SESSION:$pane_win_idx.$pane_idx' (window addressed by INDEX) as missing"
pass "real tmux: fm_backend_target_exists resolves a pane qualified by window INDEX, not just window name"

fm_backend_target_exists tmux "$SESSION:$pane_win_idx.$pane_pid" \
  || fail "fm_backend_target_exists reported the live pane id '$SESSION:$pane_win_idx.$pane_pid' (window addressed by INDEX) as missing"
pass "real tmux: a window-INDEX-qualified target also accepts a %N pane id after the dot"

if fm_backend_target_exists tmux "$SESSION:$pane_win_idx.99999"; then
  fail "fm_backend_target_exists reported a nonexistent pane under a live window index as existing"
fi
pass "real tmux: a window-INDEX-qualified target still rejects a pane that does not exist"

if fm_backend_target_exists tmux "$SESSION:99999.$pane_idx"; then
  fail "fm_backend_target_exists reported a pane under a nonexistent window index as existing"
fi
pass "real tmux: a window-INDEX-qualified target still rejects a window index that does not exist"

# The pane inventory must be scoped to the TARGET session, not to whatever
# server object the session name happens to collide with. `list-panes` takes a
# target-window even under -s, so an unscoped `-t "=$SESSION"` resolves the
# name as a WINDOW first and enumerates a different session's panes - which
# answers wrong in both directions. This decoy session owns a window named
# exactly like the probed session and holds MORE panes than the real target
# window, so an unscoped lookup reports the target's missing pane as alive.
# The decoy owns TWO windows: one named like the probed SESSION (which is what
# makes an unscoped `-t "=$SESSION"` resolve here at all), and one named like
# the probed WINDOW carrying a pane index the real target window does not have.
# Together they make a wrong-session lookup answer a dead pane ALIVE.
DECOY_SESSION="decoy-$$"
tmux new-session -d -s "$DECOY_SESSION" -n "$SESSION" -x 200 -y 50 \
  || fail "could not create the decoy session whose window shadows the probed session name"
tmux new-window -t "=$DECOY_SESSION:" -n "$PANE_WINDOW" \
  || fail "could not create the decoy's shadow of the probed window name"
target_max_pane=$(tmux list-panes -t "=$SESSION:=$PANE_WINDOW" -F '#{pane_index}' | sort -n | tail -1)
[ -n "$target_max_pane" ] || fail "could not read the real target window's pane indexes"
absent_pane=$((target_max_pane + 1))
while [ "$(tmux list-panes -t "=$DECOY_SESSION:=$PANE_WINDOW" -F '#{pane_index}' | sort -n | tail -1)" -lt "$absent_pane" ]; do
  tmux split-window -t "=$DECOY_SESSION:=$PANE_WINDOW" \
    || fail "could not widen the decoy window's pane inventory"
done
if tmux list-panes -t "=$SESSION:=$PANE_WINDOW" -F '#{pane_index}' | grep -Fqx "$absent_pane"; then
  fail "decoy fixture is invalid: pane $absent_pane also exists in the real '$PANE_WINDOW'"
fi
tmux list-panes -t "=$DECOY_SESSION:=$PANE_WINDOW" -F '#{pane_index}' | grep -Fqx "$absent_pane" \
  || fail "decoy fixture is invalid: pane $absent_pane was never created in the decoy"

if fm_backend_target_exists tmux "$SESSION:$PANE_WINDOW.$absent_pane"; then
  fail "fm_backend_target_exists answered a pane-qualified target from a DIFFERENT session's pane inventory (session name shadowed by a window named '$SESSION' in '$DECOY_SESSION')"
fi
pass "real tmux: the pane-qualified lookup is scoped to the target session, not a window that shares its name"

# The same scoping must not break the positive answer.
fm_backend_target_exists tmux "$SESSION:$PANE_WINDOW.$pane_idx" \
  || fail "scoping the pane inventory to the session broke the live pane answer"
pass "real tmux: a live pane still resolves while a same-named decoy window exists elsewhere"

tmux kill-session -t "=$DECOY_SESSION" 2>/dev/null || true

# Precedence: when both readings are possible the window NAME wins. This window
# is named "fm-dup.9" while the sibling window "fm-dup" has no pane 9, so only
# the name reading can answer - if the pane reading were tried first or instead,
# this would report missing.
PRECEDENCE_BASE="fm-dup"
PRECEDENCE_WINDOW="fm-dup.9"
base_wid=$(fm_backend_tmux_create_task "$SESSION" "$PRECEDENCE_BASE" "$HOME") \
  || fail "could not create the precedence base window"
dup_wid=$(fm_backend_tmux_create_task "$SESSION" "$PRECEDENCE_WINDOW" "$HOME") \
  || fail "could not create a window named like a pane-qualified target"
if tmux list-panes -t "$base_wid" -F '#{pane_index}' | grep -Fqx 9; then
  fail "precedence fixture is invalid: '$PRECEDENCE_BASE' unexpectedly has a pane 9"
fi
fm_backend_target_exists tmux "$SESSION:$PRECEDENCE_WINDOW" \
  || fail "the window named '$PRECEDENCE_WINDOW' lost to the pane-qualified reading of the same string"
pass "real tmux: an exact window name wins over the pane-qualified reading of the same target string"

kill_window_id "$PANE_WID"
kill_window_id "$base_wid"
kill_window_id "$dup_wid"

# --- fm_backend_target_exists: other exact tmux target handles ----------------
# `%N` pane ids, `@N` window ids and `$N` session ids are all ids tmux resolves
# exactly - verified that live ids succeed and %999/@999/$999 all fail - so
# each is a sound probe on its own and the shape guard must not reject it.
# docs/configuration.md describes FM_SUPERVISOR_TARGET generically as "a tmux
# target", and bin/fm-supervisor-target-lib.sh passes it through verbatim.
win_id=$(tmux list-windows -t "$SESSION" -F '#{window_id}' | head -1)
[ -n "$win_id" ] || fail "could not read a real window id for the live session"
fm_backend_target_exists tmux "$win_id" \
  || fail "fm_backend_target_exists rejected the live window id '$win_id'"
pass "real tmux: fm_backend_target_exists accepts an @N window id for a live window"

if fm_backend_target_exists tmux "@99999"; then
  fail "fm_backend_target_exists reported a nonexistent window id as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent @N window id"

ses_id=$(tmux list-sessions -F '#{session_id}' | head -1)
[ -n "$ses_id" ] || fail "could not read a real session id for the live session"
fm_backend_target_exists tmux "$ses_id" \
  || fail "fm_backend_target_exists rejected the live session id '$ses_id'"
pass "real tmux: fm_backend_target_exists accepts a \$N session id for a live session"

if fm_backend_target_exists tmux "\$99999"; then
  fail "fm_backend_target_exists reported a nonexistent session id as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent \$N session id"

# A bare session NAME is deliberately NOT treated as an id: tmux prefix-resolves
# it (`list-panes -t alpha` exits 0 when only `alphabet` is live) and ignores the
# `=` pin in the bare form, so it is answered from the exact session inventory.
fm_backend_target_exists tmux "$SESSION" \
  || fail "fm_backend_target_exists rejected the live bare session name '$SESSION'"
pass "real tmux: fm_backend_target_exists accepts a bare session name for a live session"

if fm_backend_target_exists tmux "${SESSION%?}"; then
  fail "fm_backend_target_exists matched a bare session name that is only a prefix of the live '$SESSION'"
fi
pass "real tmux: a bare session name is matched exactly, never by prefix"

if fm_backend_target_exists tmux "no-such-session-xyz"; then
  fail "fm_backend_target_exists reported a nonexistent bare session name as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent bare session name"

# A bare target can also be a WINDOW name, resolved across ANY session - a
# distinct tmux grammar path from the session-name case above, and the `=`
# pin does not make a bare target exact the way it does the session component
# of a session:window target (verified live: `list-panes -t "=alpha"` still
# exits 0 when only session `alphabet` is live), so this must be answered from
# exact inventory just like the session case, not by re-trusting `=`.
fm_backend_target_exists tmux "$WINDOW" \
  || fail "fm_backend_target_exists rejected the live bare window name '$WINDOW' (no session prefix)"
pass "real tmux: fm_backend_target_exists accepts a bare window name for a live window, searched across sessions"

if fm_backend_target_exists tmux "${WINDOW%?}"; then
  fail "fm_backend_target_exists matched a bare window name that is only a prefix of the live '$WINDOW'"
fi
pass "real tmux: a bare window name is matched exactly, never by prefix"

if fm_backend_target_exists tmux "no-such-window-xyz"; then
  fail "fm_backend_target_exists reported a nonexistent bare window name as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent bare window name"

# --- fm_backend_target_exists: legacy session:<window-index> targets ----------
# FM_SUPERVISOR_TARGET_DEFAULT (bin/fm-supervisor-target-lib.sh) is
# "firstmate:0" - a window INDEX, not a window name - so pinning the window
# component to an exact NAME must not silently stop resolving index targets.
window_index=$(tmux list-windows -t "$SESSION" -F '#{window_index}' | head -1)
[ -n "$window_index" ] || fail "could not read a real window index for the live session"
fm_backend_target_exists tmux "$SESSION:$window_index" \
  || fail "fm_backend_target_exists rejected the live window index target '$SESSION:$window_index'"
pass "real tmux: fm_backend_target_exists resolves a legacy session:<window-index> target"

if fm_backend_target_exists tmux "${SESSION%?}:$window_index"; then
  fail "fm_backend_target_exists matched a window index under a session name that is only a prefix of '$SESSION'"
fi
pass "real tmux: a session:<window-index> target still requires an exact session name"

if fm_backend_target_exists tmux "$SESSION:99999"; then
  fail "fm_backend_target_exists reported a nonexistent window index as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent window index"

# --- fm_backend_target_exists: bare %N pane-id targets ------------------------
# discover_supervisor_target (bin/fm-supervisor-target-lib.sh) hands the
# away-mode supervise daemon $TMUX_PANE verbatim - a bare pane id with no
# colon - so rejecting that shape would abort daemon startup, escalation
# injection, and the pane-gone guard for the default in-tmux configuration.
# A pane id is exactly resolved by tmux, so it needs no session:window shape.
pane_id=$(tmux list-panes -t "$TARGET" -F '#{pane_id}' | head -1)
[ -n "$pane_id" ] || fail "could not read a real pane id for the live target"
fm_backend_target_exists tmux "$pane_id" \
  || fail "fm_backend_target_exists rejected the live pane id '$pane_id' (the supervise daemon's default target shape)"
pass "real tmux: fm_backend_target_exists accepts a bare %N pane id for a live pane"

if fm_backend_target_exists tmux "%99999"; then
  fail "fm_backend_target_exists reported a nonexistent pane id as existing"
fi
pass "real tmux: fm_backend_target_exists rejects a nonexistent pane id"

# --- fm_backend_tmux_send_key: refuses a target it cannot resolve exactly -----
# A send is the damaging direction of the same prefix-resolution flaw the
# assertions above cover for liveness. The old pre-send guard was
# `tmux display-message -p -t "$T" '#{pane_id}'`, whose exit status this suite
# already proves is not an existence answer, and the send that followed was an
# unpinned `send-keys -t "$T"`: with a destroyed `session:fm-decoy` and a live
# sibling `session:fm-decoy-2`, the guard exits 0 AND tmux delivers the
# keystrokes into the SIBLING crew's pane. So this asserts both halves - the
# call must REFUSE (nonzero, no send-keys at all), and the live decoy must
# never receive the Enter.
# The proof that the Enter did not merely arrive late: a marker command is
# TYPED into the decoy without submitting it, the refused Enter is attempted,
# and only then is a sentinel driven through the decoy to completion. tmux
# delivers keys in order, so a sentinel that has already executed means any
# misdelivered Enter would have executed the marker first. The marker's output
# token is never typed contiguously in the command line itself (same discipline
# as wait_for_capture_text's header), so the echo of the typed-but-unsubmitted
# command cannot false-positive.
DECOY_LIVE="fm-decoy-2"
DECOY_DEAD="$SESSION:fm-decoy"
decoy_wid=$(fm_backend_tmux_create_task "$SESSION" "$DECOY_LIVE" "$HOME") \
  || fail "could not create the live decoy window for the send-key refusal check"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "fm-decoy"; then
  fail "decoy fixture is invalid: the supposedly destroyed 'fm-decoy' window actually exists"
fi

DECOY_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$decoy_wid" C-c
  tmux send-keys -t "$decoy_wid" -l "printf 'decoy-%s\\n' ready"
  tmux send-keys -t "$decoy_wid" Enter
  if wait_for_capture_text "$decoy_wid" "decoy-ready" 10; then
    DECOY_READY=true
    break
  fi
done
[ "$DECOY_READY" = true ] || fail "the decoy shell never became ready to execute a misdelivered Enter"

fm_backend_tmux_send_literal "$decoy_wid" "printf 'MISDELIVERED-%s\\n' KEYSTROKE" \
  || fail "could not type the unsubmitted marker command into the decoy pane"

if fm_backend_tmux_send_key "$DECOY_DEAD" Enter 2>/dev/null; then
  fail "fm_backend_tmux_send_key accepted '$DECOY_DEAD', a destroyed target whose name is only a prefix of the live '$DECOY_LIVE'"
fi
pass "real tmux: fm_backend_tmux_send_key refuses a target that does not resolve exactly"

tmux send-keys -t "$decoy_wid" C-c
tmux send-keys -t "$decoy_wid" -l "printf 'decoy-%s\\n' sentinel"
fm_backend_tmux_send_key "$decoy_wid" Enter \
  || fail "fm_backend_tmux_send_key refused the LIVE decoy window id; the guard must not block a resolvable target"
wait_for_capture_text "$decoy_wid" "decoy-sentinel" \
  || fail "the decoy sentinel never executed, so the misdelivery assertion below would prove nothing"
decoy_out=$(fm_backend_tmux_capture "$decoy_wid" 200) \
  || fail "fm_backend_tmux_capture failed for the decoy pane"
case "$decoy_out" in
  *MISDELIVERED-KEYSTROKE*)
    fail "keys addressed to the destroyed '$DECOY_DEAD' were delivered into the live '$DECOY_LIVE' pane"$'\n'"$decoy_out" ;;
esac
pass "real tmux: a key addressed to a destroyed prefix-colliding target never lands in the live sibling's pane"

kill_window_id "$decoy_wid"

# --- fm_backend_tmux_send_text_submit: the same refusal on the TEXT path ------
# Text is the larger blast radius of the identical defect: it is how every
# ordinary steer reaches every crew, and the submit core types the whole
# message and then presses Enter. Against a destroyed `session:fm-textdecoy`
# with a live sibling `session:fm-textdecoy-2`, the unguarded core typed AND
# executed the message in the SIBLING's pane - and had that pane's composer
# then read clear, the verdict would have been `empty`, reporting delivery
# confirmed for a task that never received it. Both halves are asserted: the
# call refuses (nonzero, and a verdict that is not `empty`), and the live
# sibling never receives the text.
TEXT_DECOY_LIVE="fm-textdecoy-2"
TEXT_DECOY_DEAD="$SESSION:fm-textdecoy"
text_decoy_wid=$(fm_backend_tmux_create_task "$SESSION" "$TEXT_DECOY_LIVE" "$HOME") \
  || fail "could not create the live decoy window for the text-send refusal check"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "fm-textdecoy"; then
  fail "decoy fixture is invalid: the supposedly destroyed 'fm-textdecoy' window actually exists"
fi

TEXT_DECOY_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$text_decoy_wid" C-c
  tmux send-keys -t "$text_decoy_wid" -l "printf 'textdecoy-%s\\n' ready"
  tmux send-keys -t "$text_decoy_wid" Enter
  if wait_for_capture_text "$text_decoy_wid" "textdecoy-ready" 10; then
    TEXT_DECOY_READY=true
    break
  fi
done
[ "$TEXT_DECOY_READY" = true ] || fail "the text decoy shell never became ready to execute a misdelivered message"

text_verdict=$(fm_backend_tmux_send_text_submit "$TEXT_DECOY_DEAD" "printf 'TEXTLEAK-%s\\n' ARRIVED" 2 0.1 0.1 2>/dev/null)
text_rc=$?
[ "$text_rc" -ne 0 ] \
  || fail "fm_backend_tmux_send_text_submit accepted '$TEXT_DECOY_DEAD', a destroyed target whose name is only a prefix of the live '$TEXT_DECOY_LIVE'"
[ "$text_verdict" != empty ] \
  || fail "fm_backend_tmux_send_text_submit reported delivery CONFIRMED (verdict 'empty') for the destroyed '$TEXT_DECOY_DEAD'"
pass "real tmux: fm_backend_tmux_send_text_submit refuses a target that does not resolve exactly, and never reports it delivered"

# Ordering proof, and the positive half in one step: a message sent through the
# SAME primitive to the live decoy must execute there. tmux delivers in order,
# so once this sentinel has run, a misdelivered earlier message would already
# have run too.
fm_backend_tmux_send_text_submit "$SESSION:$TEXT_DECOY_LIVE" "printf 'textdecoy-%s\\n' sentinel" 2 0.1 0.1 >/dev/null \
  || fail "fm_backend_tmux_send_text_submit refused the LIVE '$SESSION:$TEXT_DECOY_LIVE'; the guard must not block a resolvable target"
wait_for_capture_text "$text_decoy_wid" "textdecoy-sentinel" \
  || fail "the exact-pinned text send did not reach the live decoy pane"
pass "real tmux: fm_backend_tmux_send_text_submit still delivers to an exactly resolvable session:window target"

text_decoy_out=$(fm_backend_tmux_capture "$text_decoy_wid" 200) \
  || fail "fm_backend_tmux_capture failed for the text decoy pane"
case "$text_decoy_out" in
  *TEXTLEAK-ARRIVED*)
    fail "text addressed to the destroyed '$TEXT_DECOY_DEAD' was typed into the live '$TEXT_DECOY_LIVE' pane"$'\n'"$text_decoy_out" ;;
esac
pass "real tmux: a message addressed to a destroyed prefix-colliding target never lands in the live sibling's pane"

kill_window_id "$text_decoy_wid"

# --- a dotted window NAME is delivered to, not merely answered for -----------
# The probe and the send used to resolve this shape by two different
# implementations. The probe matched the dotted string against the session's
# window-name inventory and answered alive; the send re-derived
# `=$session:=$window`, which tmux resolves by splitting the trailing `.` off
# as a PANE specifier before matching the name - so the message went into the
# sibling window's pane of that index instead. A gate that answers one way
# while the send resolves another is worse than no gate, because it reads as
# protection while still misdelivering.
# The fixture is the failing shape itself: a live window named `<sibling>.<n>`
# beside a live sibling `<sibling>` that really does own pane index <n>, so
# both readings of the target string are live and only the correct one may
# receive the text. The pane index is read from the sibling rather than
# hardcoded, because `pane-base-index` decides whether panes start at 0 or 1.
DOT_SIBLING="fm-dotsib"
dot_sib_wid=$(fm_backend_tmux_create_task "$SESSION" "$DOT_SIBLING" "$HOME") \
  || fail "could not create the dotted-name sibling window"
tmux split-window -t "$dot_sib_wid" || fail "could not split a second pane in the dotted-name sibling"
dot_pane_idx=$(tmux list-panes -t "$dot_sib_wid" -F '#{pane_index}' | tail -1)
[ -n "$dot_pane_idx" ] || fail "could not read the sibling's pane index"
DOT_WINDOW="$DOT_SIBLING.$dot_pane_idx"
dot_wid=$(fm_backend_tmux_create_task "$SESSION" "$DOT_WINDOW" "$HOME") \
  || fail "could not create a live window whose name collides with a pane-qualified target"

fm_backend_target_exists tmux "$SESSION:$DOT_WINDOW" \
  || fail "fm_backend_target_exists reported the live dotted-name window '$SESSION:$DOT_WINDOW' as dead"

fm_backend_tmux_send_text_submit "$SESSION:$DOT_WINDOW" "dotted-target-marker" 1 0.1 0.1 >/dev/null \
  || fail "fm_backend_tmux_send_text_submit refused the live dotted-name window '$SESSION:$DOT_WINDOW'"
wait_for_capture_text "$dot_wid" "dotted-target-marker" \
  || fail "text addressed to the live dotted-name window '$SESSION:$DOT_WINDOW' never reached it"
for dot_pane in $(tmux list-panes -t "$dot_sib_wid" -F '#{pane_id}'); do
  case "$(fm_backend_tmux_capture "$dot_pane" 200)" in
    *dotted-target-marker*)
      fail "text addressed to the window named '$DOT_WINDOW' landed in sibling window '$DOT_SIBLING' pane $dot_pane" ;;
  esac
done
pass "real tmux: a window NAME containing a dot receives its own text, not the sibling pane the target string also reads as"

kill_window_id "$dot_wid"
kill_window_id "$dot_sib_wid"

# --- an ambiguous bare window name is refused, not silently picked -----------
# A bare, colon-free target is answered from the window-name inventory, and
# that inventory spans EVERY session - the same fm-<id> window name can be live
# in two of them at once. Returning the first listed match would make the
# resolver's answer depend on tmux's listing order while the refusal messages
# claim the target resolved "to exactly one live endpoint", and that answer is
# now the SEND address too, so a send would type into an arbitrary one of the
# two. An ambiguous name has no correct answer, so it must resolve to nothing.
AMBIG_NAME="fm-ambig"
AMBIG_SESSION="ambig-$$"
ambig_wid=$(fm_backend_tmux_create_task "$SESSION" "$AMBIG_NAME" "$HOME") \
  || fail "could not create the first window of the ambiguous bare-name pair"

fm_backend_target_exists tmux "$AMBIG_NAME" \
  || fail "a bare window name live in exactly one session must still resolve"
pass "real tmux: an unambiguous bare window name still resolves"

tmux new-session -d -s "$AMBIG_SESSION" -n "$AMBIG_NAME" -x 200 -y 50 \
  || fail "could not create the second session holding the same window name"
[ "$(tmux list-windows -a -F '#{window_name}' | grep -Fxc "$AMBIG_NAME")" -eq 2 ] \
  || fail "ambiguity fixture is invalid: '$AMBIG_NAME' is not live in exactly two sessions"

if fm_backend_target_exists tmux "$AMBIG_NAME"; then
  fail "fm_backend_target_exists resolved the bare name '$AMBIG_NAME' that is live in two sessions"
fi
if fm_backend_tmux_send_key "$AMBIG_NAME" Enter 2>/dev/null; then
  fail "fm_backend_tmux_send_key delivered to one of two windows both named '$AMBIG_NAME'"
fi
pass "real tmux: a bare window name live in two sessions is refused rather than resolved to either one"

tmux kill-session -t "=$AMBIG_SESSION" 2>/dev/null || true
kill_window_id "$ambig_wid"

# --- fm_backend_tmux_exact_target (the resolver itself), from inside a client -
# fm_backend_target_exists is a thin wrapper around fm_backend_tmux_exact_target
# (bin/fm-backend.sh); every other gated primitive in this file - the sends,
# the kill, and the recovery-grade agent-state read below - shares that exact
# same resolver call, so this proves the resolver itself, not just one of its
# callers, refuses a nonexistent target from inside a live tmux client. Run
# from outside a client this passes today and proves nothing, exactly like the
# fm_backend_target_exists case above (same discipline: the fallback needs a
# live session to fall back TO).
fm_backend_tmux_send_text_line "$TARGET" \
  "export PATH=\"$SHIM_DIR:\$PATH\" && . \"$ROOT/bin/fm-backend.sh\" && if fm_backend_tmux_exact_target nosuchsession2:nosuchwindow2 >/dev/null 2>&1; then printf 'RESOLVER-RESULT:%s\\n' EXISTS; else printf 'RESOLVER-RESULT:%s\\n' MISSING; fi" \
  || fail "fm_backend_tmux_send_text_line failed for the in-pane resolver probe"
wait_for_capture_text "$TARGET" "RESOLVER-RESULT:MISSING" 150
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after the in-pane resolver probe"
case "$out" in
  *RESOLVER-RESULT:MISSING*) : ;;
  *RESOLVER-RESULT:EXISTS*) fail "fm_backend_tmux_exact_target resolved a nonexistent session:window when run from inside a live tmux client"$'\n'"$out" ;;
  *) fail "fm_backend_tmux_exact_target's in-pane resolver probe produced an unexpected result"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_exact_target (the resolver itself) refuses a nonexistent target even when run from inside a live tmux client"

# --- fm_backend_tmux_agent_state: no session-component prefix fallback -------
# fm_backend_tmux_agent_state used to validate existence with unpinned
# `list-windows -t "$session"`, and tmux resolves a target-session by PREFIX
# exactly like it resolves a target-window (proven above for
# fm_backend_target_exists), so a dead `dead-sess:fm-x` fell through to a live
# PREFIX-colliding `dead-sess-2`'s own window inventory, found a same-named
# window there, and read THAT window's foreground process under the dead
# session's label. This is the defect fm-tmux-agent-state-session-prefix-match
# exists to fix: a fleet that acts on "endpoint: alive" for an endpoint that
# was never actually verified.
# The fixture makes the misdelivery provable rather than theoretical: the live
# sibling's pane runs a process whose ARGV[0] the classifier recognizes as a
# harness (`exec -a claude sleep 300` - argv[0]=claude, comm=sleep, exactly
# the shape fm_backend_tmux_foreground_argv0s exists to catch when a title is
# rewritten), so the old code's misdelivery would read back a false ALIVE, not
# merely something non-missing.
AGENT_DEAD_SESSION="agent-dead"
AGENT_LIVE_SESSION="agent-dead-2"
AGENT_WINDOW="fm-x"
tmux new-session -d -s "$AGENT_LIVE_SESSION" -x 200 -y 50 \
  || fail "could not create the live prefix-colliding sibling session"
fm_backend_tmux_create_task "$AGENT_LIVE_SESSION" "$AGENT_WINDOW" "$HOME" >/dev/null \
  || fail "could not create the sibling's window"
if tmux has-session -t "=$AGENT_DEAD_SESSION" 2>/dev/null; then
  fail "fixture is invalid: the supposedly dead '$AGENT_DEAD_SESSION' session actually exists"
fi

fm_backend_tmux_send_text_line "$AGENT_LIVE_SESSION:$AGENT_WINDOW" "exec -a claude sleep 300" \
  || fail "could not start the fake harness process (argv0=claude) in the live sibling pane"
AGENT_READY=false
for _ in $(seq 1 50); do
  case "$(fm_backend_tmux_foreground_argv0s "$AGENT_LIVE_SESSION:$AGENT_WINDOW" 2>/dev/null)" in
    *claude*) AGENT_READY=true; break ;;
  esac
  sleep 0.1
done
[ "$AGENT_READY" = true ] || fail "the fake harness process (argv0=claude) never became the sibling pane's foreground process"

agent_state_out=$(fm_backend_agent_state tmux "$AGENT_DEAD_SESSION:$AGENT_WINDOW")
[ "$agent_state_out" != alive ] \
  || fail "fm_backend_agent_state reported '$AGENT_DEAD_SESSION:$AGENT_WINDOW' alive by reading the live prefix-colliding sibling '$AGENT_LIVE_SESSION:$AGENT_WINDOW'"
[ "$agent_state_out" = missing ] \
  || fail "fm_backend_agent_state should classify a session that does not exist as missing, got '$agent_state_out'"
pass "real tmux: fm_backend_agent_state does not fall through to a live prefix-colliding sibling session, and reports the dead session missing rather than reading the sibling alive"

fm_backend_tmux_kill "$AGENT_LIVE_SESSION:$AGENT_WINDOW"
tmux kill-session -t "=$AGENT_LIVE_SESSION" 2>/dev/null || true

# --- fm_backend_tmux_kill and a dotted window NAME: never a sibling ----------
# fm_backend_tmux_kill used to hand-build `=$session:=$window`, and tmux splits
# a dotted window component's trailing `.` off as a PANE specifier before
# matching the name, so `kill-window -t '=sess:=fm-killsib.2'` could remove the
# SIBLING window `fm-killsib` (whichever one owns pane 2) instead of the
# dotted-name window it was actually asked to remove - a destructive misfire,
# not merely a failed removal. The fixture is the failing shape itself: a live
# sibling window that really owns the pane index the dotted string reads as,
# beside the dotted-name window kill is actually asked to remove.
KILL_SIBLING="fm-killsib"
kill_sib_wid=$(fm_backend_tmux_create_task "$SESSION" "$KILL_SIBLING" "$HOME") \
  || fail "could not create the kill-safety sibling window"
tmux split-window -t "$kill_sib_wid" || fail "could not split a second pane in the kill-safety sibling"
kill_pane_idx=$(tmux list-panes -t "$kill_sib_wid" -F '#{pane_index}' | tail -1)
[ -n "$kill_pane_idx" ] || fail "could not read the kill-safety sibling's pane index"
KILL_DOTTED="$KILL_SIBLING.$kill_pane_idx"
kill_dotted_wid=$(fm_backend_tmux_create_task "$SESSION" "$KILL_DOTTED" "$HOME") \
  || fail "could not create the dotted-name window to kill"

fm_backend_tmux_kill "$SESSION:$KILL_DOTTED"

if ! tmux list-windows -t "=$SESSION" -F '#{window_name}' 2>/dev/null | grep -Fqx "$KILL_SIBLING"; then
  fail "fm_backend_tmux_kill removed the SIBLING window '$KILL_SIBLING' instead of the dotted-name window '$KILL_DOTTED' it was asked to remove"
fi
if tmux list-windows -t "=$SESSION" -F '#{window_name}' 2>/dev/null | grep -Fqx "$KILL_DOTTED"; then
  fail "fm_backend_tmux_kill did not remove the dotted-name window '$KILL_DOTTED' it was asked to remove"
fi
pass "real tmux: fm_backend_tmux_kill removes a window named with a dot without destroying a same-pane-indexed sibling window"

kill_window_id "$kill_sib_wid"
kill_window_id "$kill_dotted_wid"

# --- an ALREADY-GONE dotted name is never read as, nor killed as, its sibling -
# The residual half of the same defect, and the more dangerous one: when the
# dotted window is already gone, a resolver that falls back to reading
# `<window>.<pane>` answers with a real pane of the truncated sibling, because
# the sibling's FIRST pane index always exists - no split needed. A recorded
# `sess:fm-<id>.0` whose window has since been removed then resolves to pane 0
# of the live `fm-<id>`, and the two consumers that resolve a RECORDED
# session:window field escalate that from there: fm_backend_tmux_agent_state
# reads the sibling task's foreground process and reports the dead endpoint
# `alive`, and fm_backend_tmux_kill destroys the sibling's ENTIRE window,
# because `kill-window` on a pane id removes the window that pane belongs to
# (verified on tmux 3.4). Task ids admit dots (fm_task_id_path_safe allows
# [A-Za-z0-9._-]) and fm-spawn.sh records `window=<session>:fm-<id>`, so a
# recorded name ending `.0` needs nothing exotic to occur.
# As in the prefix-collision proof above, the sibling pane runs a process the
# classifier recognizes as a harness by ARGV[0] (`exec -a claude sleep 300`),
# so a misresolved read would come back a false ALIVE rather than merely
# something non-missing.
GONE_SIBLING="fm-gonesib"
gone_sib_wid=$(fm_backend_tmux_create_task "$SESSION" "$GONE_SIBLING" "$HOME") \
  || fail "could not create the already-gone-dotted-target sibling window"
gone_pane_idx=$(tmux list-panes -t "$gone_sib_wid" -F '#{pane_index}' | head -1)
[ -n "$gone_pane_idx" ] || fail "could not read the already-gone-dotted-target sibling's first pane index"
GONE_DOTTED="$GONE_SIBLING.$gone_pane_idx"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "$GONE_DOTTED"; then
  fail "fixture is invalid: the supposedly already-gone window '$GONE_DOTTED' actually exists"
fi

fm_backend_tmux_send_text_line "$SESSION:$GONE_SIBLING" "exec -a claude sleep 300" \
  || fail "could not start the fake harness process (argv0=claude) in the already-gone-dotted-target sibling pane"
GONE_READY=false
for _ in $(seq 1 50); do
  case "$(fm_backend_tmux_foreground_argv0s "$gone_sib_wid" 2>/dev/null)" in
    *claude*) GONE_READY=true; break ;;
  esac
  sleep 0.1
done
[ "$GONE_READY" = true ] || fail "the fake harness process (argv0=claude) never became the already-gone-dotted-target sibling's foreground process"

gone_state=$(fm_backend_agent_state tmux "$SESSION:$GONE_DOTTED")
[ "$gone_state" != alive ] \
  || fail "fm_backend_agent_state reported the already-gone '$SESSION:$GONE_DOTTED' alive by reading pane $gone_pane_idx of the live sibling '$GONE_SIBLING'"
[ "$gone_state" = missing ] \
  || fail "fm_backend_agent_state should classify an already-gone dotted window in a readable session as missing, got '$gone_state'"
pass "real tmux: fm_backend_agent_state reads an already-gone dotted window name as missing, never as its same-pane-indexed sibling's live harness"

fm_backend_tmux_kill "$SESSION:$GONE_DOTTED" \
  || fail "fm_backend_tmux_kill on an already-gone dotted target must stay best-effort (never fail)"
if ! tmux list-windows -t "=$SESSION" -F '#{window_name}' 2>/dev/null | grep -Fqx "$GONE_SIBLING"; then
  fail "fm_backend_tmux_kill destroyed the live sibling '$GONE_SIBLING' when asked to remove the already-gone '$GONE_DOTTED'"
fi
pass "real tmux: fm_backend_tmux_kill leaves a live sibling intact when the dotted-name window it is asked to remove is already gone"

kill_window_id "$gone_sib_wid"

# --- target-kind `named`: an already-gone dotted RECORDED window never sends --
# The send half of the same defect, and the worst-consequence half. A recorded
# `sess:fm-<id>.0` whose window is gone, beside a live `fm-<id>` whose first
# pane index always exists, resolved through the general resolver's
# pane-qualified fallback to a real pane of that live sibling - so an ordinary
# steer was TYPED AND SUBMITTED into a different crew's composer while that
# crew was mid-turn, and if their composer then cleared, the verdict read
# `empty`, reporting delivery CONFIRMED for a task that never received it.
# The four sends take both kinds of target, so the kind is declared by the
# caller, never inferred from the string: fm-send.sh's recorded-metadata paths,
# fm-control.sh's validated endpoint and fm-spawn.sh's just-created window are
# `named`, and `named` is the default so an unclassified caller refuses.
# The fixture is a decoy shell that would EXECUTE a misdelivered line, and the
# ordering sentinel below drives a real send through the same primitives to
# completion afterwards - tmux delivers in order, so a sentinel that has run
# means any misdelivered earlier byte would already have run too. Marker tokens
# are never typed contiguously in their own command line, so the echo of a
# typed-but-unsubmitted command cannot false-positive.
SEND_GONE_LIVE="fm-sendgone"
send_gone_wid=$(fm_backend_tmux_create_task "$SESSION" "$SEND_GONE_LIVE" "$HOME") \
  || fail "could not create the live sibling window for the already-gone dotted send check"
send_gone_pane=$(tmux list-panes -t "$send_gone_wid" -F '#{pane_index}' | head -1)
[ -n "$send_gone_pane" ] || fail "could not read the already-gone dotted send sibling's first pane index"
SEND_GONE_DOTTED="$SESSION:$SEND_GONE_LIVE.$send_gone_pane"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "$SEND_GONE_LIVE.$send_gone_pane"; then
  fail "fixture is invalid: the supposedly already-gone window '$SEND_GONE_LIVE.$send_gone_pane' actually exists"
fi

SEND_GONE_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$send_gone_wid" C-c
  tmux send-keys -t "$send_gone_wid" -l "printf 'sendgone-%s\\n' ready"
  tmux send-keys -t "$send_gone_wid" Enter
  if wait_for_capture_text "$send_gone_wid" "sendgone-ready" 10; then
    SEND_GONE_READY=true
    break
  fi
done
[ "$SEND_GONE_READY" = true ] || fail "the already-gone dotted send decoy shell never became ready to execute a misdelivered line"

# Every call below omits the kind, so it also proves the DEFAULT is the safe
# one: a call site that was never classified refuses rather than reinterpreting.
if fm_backend_tmux_send_text_line "$SEND_GONE_DOTTED" "printf 'GONELINELEAK-%s\\n' ARRIVED" 2>/dev/null; then
  fail "fm_backend_tmux_send_text_line accepted the already-gone '$SEND_GONE_DOTTED' instead of refusing it"
fi
if fm_backend_tmux_send_literal "$SEND_GONE_DOTTED" "printf 'GONELITERALLEAK-%s\\n' ARRIVED" 2>/dev/null; then
  fail "fm_backend_tmux_send_literal accepted the already-gone '$SEND_GONE_DOTTED' instead of refusing it"
fi
send_gone_verdict=$(fm_backend_tmux_send_text_submit "$SEND_GONE_DOTTED" "printf 'GONETEXTLEAK-%s\\n' ARRIVED" 2 0.1 0.1 2>/dev/null)
send_gone_rc=$?
[ "$send_gone_rc" -ne 0 ] \
  || fail "fm_backend_tmux_send_text_submit accepted the already-gone '$SEND_GONE_DOTTED' instead of refusing it"
[ "$send_gone_verdict" != empty ] \
  || fail "fm_backend_tmux_send_text_submit reported delivery CONFIRMED (verdict 'empty') for the already-gone '$SEND_GONE_DOTTED'"

# send_key's misdelivery is only observable if there is something for a stray
# Enter to submit, so a marker command is typed into the live sibling first.
fm_backend_tmux_send_literal "$send_gone_wid" "printf 'GONEKEYLEAK-%s\\n' ARRIVED" \
  || fail "could not type the unsubmitted marker command into the already-gone dotted send decoy pane"
if fm_backend_tmux_send_key "$SEND_GONE_DOTTED" Enter 2>/dev/null; then
  fail "fm_backend_tmux_send_key accepted the already-gone '$SEND_GONE_DOTTED' instead of refusing it"
fi
pass "real tmux: all four send primitives refuse an already-gone dotted recorded window rather than resolving it to a live sibling's pane"

tmux send-keys -t "$send_gone_wid" C-u
fm_backend_tmux_send_text_line "$SESSION:$SEND_GONE_LIVE" "printf 'sendgone-%s\\n' sentinel" named \
  || fail "fm_backend_tmux_send_text_line refused the LIVE '$SESSION:$SEND_GONE_LIVE' under target-kind named; the guard must not block a resolvable recorded window"
wait_for_capture_text "$send_gone_wid" "sendgone-sentinel" \
  || fail "the named-kind sentinel never executed, so the misdelivery assertion below would prove nothing"
send_gone_out=$(fm_backend_tmux_capture "$send_gone_wid" 200) \
  || fail "fm_backend_tmux_capture failed for the already-gone dotted send decoy pane"
case "$send_gone_out" in
  *GONELINELEAK-ARRIVED*|*GONELITERALLEAK-ARRIVED*|*GONETEXTLEAK-ARRIVED*|*GONEKEYLEAK-ARRIVED*)
    fail "input addressed to the already-gone '$SEND_GONE_DOTTED' was delivered into the live sibling '$SEND_GONE_LIVE'"$'\n'"$send_gone_out" ;;
esac
pass "real tmux: nothing addressed to an already-gone dotted recorded window ever lands in its same-pane-indexed live sibling"

kill_window_id "$send_gone_wid"

# --- target-kind `general`: pane-qualified delivery must keep working --------
# The other side of the same boundary, and the one that must NOT regress. An
# operator-declared FM_SUPERVISOR_TARGET ("firstmate:0.1") legitimately
# addresses pane N of window W, and it is how the away-mode escalation channel
# reaches the Admiral. `named` is the default precisely because it refuses that
# reading, so bin/fm-supervise-daemon.sh opts in to `general` explicitly - and
# this asserts the whole chain that path uses, including the dispatcher's
# argument positions, by sending through fm_backend_send_text_submit exactly as
# the injector does and checking the bytes land in the ADDRESSED pane and not
# its sibling.
PANEGEN_WINDOW="fm-panegen"
panegen_wid=$(fm_backend_tmux_create_task "$SESSION" "$PANEGEN_WINDOW" "$HOME") \
  || fail "could not create the pane-qualified general-kind window"
tmux split-window -t "$panegen_wid" || fail "could not split a second pane for the general-kind check"
panegen_first_pid=$(tmux list-panes -t "$panegen_wid" -F '#{pane_id}' | head -1)
panegen_target_idx=$(tmux list-panes -t "$panegen_wid" -F '#{pane_index}' | tail -1)
panegen_target_pid=$(tmux list-panes -t "$panegen_wid" -F '#{pane_id}' | tail -1)
[ -n "$panegen_first_pid" ] && [ -n "$panegen_target_idx" ] && [ -n "$panegen_target_pid" ] \
  || fail "could not read the general-kind window's pane index/ids"
[ "$panegen_first_pid" != "$panegen_target_pid" ] \
  || fail "the general-kind fixture needs two distinct panes to prove delivery landed in the addressed one"
PANEGEN_TARGET="$SESSION:$PANEGEN_WINDOW.$panegen_target_idx"

PANEGEN_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$panegen_target_pid" C-c
  tmux send-keys -t "$panegen_target_pid" -l "printf 'panegen-%s\\n' ready"
  tmux send-keys -t "$panegen_target_pid" Enter
  if wait_for_capture_text "$panegen_target_pid" "panegen-ready" 10; then
    PANEGEN_READY=true
    break
  fi
done
[ "$PANEGEN_READY" = true ] || fail "the pane-qualified general-kind shell never became ready"

if fm_backend_tmux_send_text_line "$PANEGEN_TARGET" "printf 'panegen-%s\\n' refused" 2>/dev/null; then
  fail "the default target-kind accepted the pane-qualified '$PANEGEN_TARGET'; the named kind must refuse a pane reading so that opting in to general is a real, explicit decision"
fi
pass "real tmux: a pane-qualified target is refused under the default target-kind, so the general kind is an explicit opt-in rather than an accident"

fm_backend_tmux_send_text_line "$PANEGEN_TARGET" "printf 'panegen-%s\\n' vialine" general \
  || fail "fm_backend_tmux_send_text_line refused the pane-qualified '$PANEGEN_TARGET' under target-kind general"
wait_for_capture_text "$panegen_target_pid" "panegen-vialine" \
  || fail "target-kind general did not deliver a line to the addressed pane '$PANEGEN_TARGET'"

# The away-mode injector's exact call shape: through the generic dispatcher,
# with an empty expected-label and an explicit `general` kind.
panegen_verdict=$(fm_backend_send_text_submit tmux "$PANEGEN_TARGET" "printf 'panegen-%s\\n' viasubmit" 2 0.1 0.1 "" general) \
  || fail "fm_backend_send_text_submit refused the pane-qualified '$PANEGEN_TARGET' under target-kind general (verdict '$panegen_verdict'); this is the away-mode escalation channel"
[ "$panegen_verdict" != target-unresolved ] \
  || fail "fm_backend_send_text_submit reported the live pane-qualified '$PANEGEN_TARGET' unresolved under target-kind general"
wait_for_capture_text "$panegen_target_pid" "panegen-viasubmit" \
  || fail "the away-mode dispatcher shape did not deliver to the addressed pane '$PANEGEN_TARGET'"

tmux send-keys -t "$panegen_target_pid" -l "printf 'panegen-%s\\n' viakey"
fm_backend_tmux_send_key "$PANEGEN_TARGET" Enter general \
  || fail "fm_backend_tmux_send_key refused the pane-qualified '$PANEGEN_TARGET' under target-kind general"
wait_for_capture_text "$panegen_target_pid" "panegen-viakey" \
  || fail "target-kind general did not deliver a key to the addressed pane '$PANEGEN_TARGET'"

panegen_other=$(fm_backend_tmux_capture "$panegen_first_pid" 200) \
  || fail "fm_backend_tmux_capture failed for the general-kind window's other pane"
case "$panegen_other" in
  *panegen-vialine*|*panegen-viasubmit*|*panegen-viakey*)
    fail "general-kind delivery addressed to pane $panegen_target_idx landed in the window's OTHER pane"$'\n'"$panegen_other" ;;
esac
pass "real tmux: target-kind general still delivers text, a submit through the away-mode dispatcher shape, and a key to an explicitly pane-qualified target, and only to that pane"

kill_window_id "$panegen_wid"

# --- fm_backend_tmux_send_text_line / fm_backend_tmux_send_literal: gated too -
# These two were the last unpinned senders, used only by bin/fm-spawn.sh to
# type setup commands and the harness launch command into a pane it just
# created. Same shape as the send_key/send_text_submit refusal proofs above: a
# destroyed session:window whose name is only a PREFIX of a live sibling must
# not deliver into that sibling.
LINE_DECOY_LIVE="fm-linedecoy-2"
LINE_DECOY_DEAD="$SESSION:fm-linedecoy"
line_decoy_wid=$(fm_backend_tmux_create_task "$SESSION" "$LINE_DECOY_LIVE" "$HOME") \
  || fail "could not create the live decoy window for the send_text_line/send_literal refusal check"
if tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "fm-linedecoy"; then
  fail "decoy fixture is invalid: the supposedly destroyed 'fm-linedecoy' window actually exists"
fi

LINE_DECOY_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$line_decoy_wid" C-c
  tmux send-keys -t "$line_decoy_wid" -l "printf 'linedecoy-%s\\n' ready"
  tmux send-keys -t "$line_decoy_wid" Enter
  if wait_for_capture_text "$line_decoy_wid" "linedecoy-ready" 10; then
    LINE_DECOY_READY=true
    break
  fi
done
[ "$LINE_DECOY_READY" = true ] || fail "the line/literal decoy shell never became ready"

if fm_backend_tmux_send_text_line "$LINE_DECOY_DEAD" "printf 'LINELEAK-%s\\n' ARRIVED" 2>/dev/null; then
  fail "fm_backend_tmux_send_text_line accepted '$LINE_DECOY_DEAD', a destroyed target whose name is only a prefix of the live '$LINE_DECOY_LIVE'"
fi
if fm_backend_tmux_send_literal "$LINE_DECOY_DEAD" "printf 'LITERALLEAK-%s\\n' ARRIVED" 2>/dev/null; then
  fail "fm_backend_tmux_send_literal accepted '$LINE_DECOY_DEAD', a destroyed target whose name is only a prefix of the live '$LINE_DECOY_LIVE'"
fi
pass "real tmux: fm_backend_tmux_send_text_line and fm_backend_tmux_send_literal refuse a target that does not resolve exactly"

tmux send-keys -t "$line_decoy_wid" C-c
tmux send-keys -t "$line_decoy_wid" -l "printf 'linedecoy-%s\\n' sentinel"
fm_backend_tmux_send_key "$line_decoy_wid" Enter \
  || fail "fm_backend_tmux_send_key refused the LIVE line/literal decoy window id; the guard must not block a resolvable target"
wait_for_capture_text "$line_decoy_wid" "linedecoy-sentinel" \
  || fail "the line/literal decoy sentinel never executed, so the misdelivery assertion below would prove nothing"
line_decoy_out=$(fm_backend_tmux_capture "$line_decoy_wid" 200) \
  || fail "fm_backend_tmux_capture failed for the line/literal decoy pane"
case "$line_decoy_out" in
  *LINELEAK-ARRIVED*|*LITERALLEAK-ARRIVED*)
    fail "text addressed to the destroyed '$LINE_DECOY_DEAD' was delivered into the live '$LINE_DECOY_LIVE' pane"$'\n'"$line_decoy_out" ;;
esac
pass "real tmux: a message addressed to a destroyed prefix-colliding target via send_text_line/send_literal never lands in the live sibling's pane"

fm_backend_tmux_send_text_line "$SESSION:$LINE_DECOY_LIVE" "printf 'linedecoy-%s\\n' vialine" \
  || fail "fm_backend_tmux_send_text_line refused the LIVE '$SESSION:$LINE_DECOY_LIVE'; the guard must not block a resolvable target"
wait_for_capture_text "$line_decoy_wid" "linedecoy-vialine" \
  || fail "fm_backend_tmux_send_text_line did not deliver to an exactly resolvable target"
pass "real tmux: fm_backend_tmux_send_text_line still delivers to an exactly resolvable session:window target"

kill_window_id "$line_decoy_wid"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

cleanup_all
trap - EXIT
