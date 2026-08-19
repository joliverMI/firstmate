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
# Kill by window id as well: fm_backend_tmux_kill addresses the window with the
# same `=$session:=$window` pin whose pane-split flaw is described above, so it
# cannot remove a dotted window name and is best-effort (it reports success
# either way). That is a pre-existing sibling gap, tracked separately and NOT
# fixed here; this line only stops the leaked window from perturbing the
# pane-addressing assertions below.
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
