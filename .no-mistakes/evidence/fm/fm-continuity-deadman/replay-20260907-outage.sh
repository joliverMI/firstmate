#!/usr/bin/env bash
# Manual end-to-end replay of the 2026-09-07 outage shape against a fixture home.
# A fake `claude` process owns the home's session lock, a fake tmux stands in for
# firstmate's own pane (idle composer), the beacon and the delivered-rewake marker
# are both aged past the grace window, and the REAL bin/fm-continuity-deadman.sh
# is started detached through `ensure` exactly as bin/fm-watch-arm.sh does.
# The alarm goes through the REAL command: channel (no notifier seam); only the
# final pane submit is routed to a recorder so nothing is typed into a real pane.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKTREE=${WORKTREE:?set WORKTREE to the checkout under test}
EVID=$ROOT
HOME_DIR=$(mktemp -d /tmp/fm-deadman-replay.XXXXXX)
say() { printf '\n### %s\n' "$*"; }

say "1. fixture home: plain checkout with the real bin/, one task in flight, fake claude session, idle fake pane"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/fakebin"
git init -q "$HOME_DIR" && git -C "$HOME_DIR" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp -R "$WORKTREE/bin" "$HOME_DIR/bin"
printf 'window=sess:fm-t1\nbackend=tmux\n' > "$HOME_DIR/state/t1.meta"
ln -s /bin/bash "$HOME_DIR/fakebin/claude"
cat > "$HOME_DIR/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys|list-panes) exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n'
    printf '\xe2\x94\x82 >  \xe2\x94\x82\n'
    printf '\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n'
    exit 0 ;;
esac
exit 0
SH
cat > "$HOME_DIR/fakebin/pane-submit-recorder" <<'SH'
#!/usr/bin/env bash
printf 'backend=%s target=%s\n' "$1" "$2" >> "${FM_INJECT_LOG:?}"
printf '%s' "$3" > "${FM_INJECT_LOG}.encoded"
exit 0
SH
chmod +x "$HOME_DIR/fakebin/tmux" "$HOME_DIR/fakebin/pane-submit-recorder"
"$HOME_DIR/fakebin/claude" -c 'echo $$ > "$1/state/.lock"; sleep 900; :' _ "$HOME_DIR" >/dev/null 2>&1 </dev/null &
SESSION_BG=$!
sleep 0.5
SESSION_PID=$(cat "$HOME_DIR/state/.lock")
printf 'session-lock pid=%s comm=%s\n' "$SESSION_PID" "$(ps -o comm= -p "$SESSION_PID")"

say "2. the 2026-09-07 shape: watcher beacon 6 min old, rewake delivered 6 min ago and never drained, pane idle"
touch -d "@$(( $(date +%s) - 360 ))" "$HOME_DIR/state/.last-watcher-beat"
: > "$HOME_DIR/state/.rewake-pending"
touch -d "@$(( $(date +%s) - 360 ))" "$HOME_DIR/state/.rewake-pending"
ls -la --time-style=+%H:%M:%S "$HOME_DIR/state/.last-watcher-beat" "$HOME_DIR/state/.rewake-pending" | awk '{print $6, $7}'
printf 'now: %s\n' "$(date +%H:%M:%S)"

export PATH="$HOME_DIR/fakebin:$PATH"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR"
export FM_GUARD_GRACE=20 FM_CONTINUITY_DEADMAN_TICK=2
export FM_SUPERVISOR_TARGET=sess:win FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_PANE_HARNESS=claude
export FM_WEDGE_ALARM_CHANNEL="command:cat >> $HOME_DIR/alarm-received.txt"
export FM_CONTINUITY_DEADMAN_INJECT_EXEC="$HOME_DIR/fakebin/pane-submit-recorder"
export FM_INJECT_LOG="$HOME_DIR/pane-submit.log"
DM="$HOME_DIR/bin/fm-continuity-deadman.sh"

say "3. start the deadman the way an arm does: \`ensure\` (silent, exit 0), grace compressed to ${FM_GUARD_GRACE}s, tick ${FM_CONTINUITY_DEADMAN_TICK}s"
"$DM" ensure; printf 'ensure exit=%s, stdout/stderr empty=%s\n' "$?" "$([ -z "$("$DM" ensure 2>&1)" ] && echo yes || echo no)"
sleep 0.5
"$DM" status
DM_PID=$(cat "$HOME_DIR/state/.continuity-deadman.lock/pid")
printf 'process tree isolation: my pgid=%s sid=%s | deadman pgid=%s sid=%s ppid=%s\n' \
  "$(ps -o pgid= -p $$ | tr -d ' ')" "$(ps -o sid= -p $$ | tr -d ' ')" \
  "$(ps -o pgid= -p "$DM_PID" | tr -d ' ')" "$(ps -o sid= -p "$DM_PID" | tr -d ' ')" "$(ps -o ppid= -p "$DM_PID" | tr -d ' ')"

say "4. wait through the startup settle window; the episode must open on its own"
i=0
while [ "$i" -lt 60 ] && [ ! -e "$HOME_DIR/state/.continuity-deadman-alarm" ]; do sleep 1; i=$((i+1)); done
printf 'episode opened after ~%ss (now %s)\n' "$i" "$(date +%H:%M:%S)"
"$DM" status

say "5a. durable wake record in state/.wake-queue"
cat "$HOME_DIR/state/.wake-queue"

say "5b. active alert delivered through the real command: channel (what a phone-push command would receive)"
cat "$HOME_DIR/alarm-received.txt"

say "5c. self-recovery: one operational input handed to firstmate's own pane"
sleep 3
cat "$FM_INJECT_LOG"
printf 'operational-input kind: %s\n' "$("$HOME_DIR/bin/fm-operational-input.sh" kind < "$FM_INJECT_LOG.encoded")"
printf 'decoded body: %s\n' "$(sed 's/^[^:]*: //' "$FM_INJECT_LOG.encoded" | cut -c1-160)..."
printf 'submit attempts so far: %s (backoff default 600s, so exactly one)\n' "$(grep -c . "$FM_INJECT_LOG")"

say "6. the woken turn drains the queue: real bin/fm-wake-drain.sh (what the primary sees at the top of its turn)"
"$HOME_DIR/bin/fm-wake-drain.sh" 2>&1 | grep -E 'watcher-continuity-lost|WAKE_ACK_REQUIRED|check:' | cut -c1-220
printf 'state/.rewake-pending after drain: %s\n' "$([ -e "$HOME_DIR/state/.rewake-pending" ] && echo still-present || echo cleared)"

say "7. the turn's Stop re-arms a watcher (fresh identity-matched lock + beat); episode must close"
sleep 900 & W=$!
IDENT=$(FM_STATE_OVERRIDE=/tmp bash -c '. "$1"; fm_pid_identity "$2"' _ "$HOME_DIR/bin/fm-wake-lib.sh" "$W")
mkdir -p "$HOME_DIR/state/.watch.lock"
printf '%s\n' "$W" > "$HOME_DIR/state/.watch.lock/pid"
printf '%s\n' "$HOME_DIR" > "$HOME_DIR/state/.watch.lock/fm-home"
printf '%s\n' "$HOME_DIR/bin/fm-watch.sh" > "$HOME_DIR/state/.watch.lock/watcher-path"
printf '%s\n' "$IDENT" > "$HOME_DIR/state/.watch.lock/pid-identity"
touch "$HOME_DIR/state/.last-watcher-beat"
i=0
while [ "$i" -lt 30 ] && [ -e "$HOME_DIR/state/.continuity-deadman-alarm" ]; do sleep 1; i=$((i+1)); done
printf 'episode closed after ~%ss\n' "$i"
"$DM" status
printf 'submit attempts total: %s (no injection after recovery)\n' "$(grep -c . "$FM_INJECT_LOG")"

say "8. the session ends; the deadman must retire itself without anyone stopping it"
kill "$SESSION_PID" 2>/dev/null; wait "$SESSION_BG" 2>/dev/null
i=0
while [ "$i" -lt 30 ] && kill -0 "$DM_PID" 2>/dev/null; do sleep 1; i=$((i+1)); done
printf 'deadman pid %s alive after session death: %s (after ~%ss)\n' "$DM_PID" "$(kill -0 "$DM_PID" 2>/dev/null && echo yes || echo no)" "$i"
"$DM" status

say "9. deadman diagnostic log (state/.continuity-deadman.log)"
cat "$HOME_DIR/state/.continuity-deadman.log"

kill "$W" 2>/dev/null
rm -rf "$HOME_DIR"
