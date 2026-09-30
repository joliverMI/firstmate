#!/usr/bin/env bash
# tests/fm-secondmate-viewer-window.test.sh - the best-effort, opt-in, local
# tmux viewer window for a live herdr-backed remote secondmate
# (bin/fm-secondmate-viewer-window.sh).
#
# Drives the real script directly against fake state/<id>.meta records and a
# fake tmux, never a real remote host or Herdr install - exactly the shape
# its own header promises. The guarantees under test:
#   - Opt-in: silently a no-op (skipped) unless config/secondmate-viewer-window
#     is present.
#   - Scoped: skipped when the meta has no remote_host/remote_herdr_session, and
#     skipped when the primary's own resolved backend is not tmux.
#   - Idempotent: a second run against the same live window reports it already
#     exists and never calls tmux new-window again.
#   - The SSH/herdr-attach command is built fresh from that secondmate's own
#     meta, never a hardcoded host or session name, and two different
#     secondmate ids never collide on the same window name.
#   - Missing tmux or ssh on PATH is reported as skipped, never a hard failure.
#   - The script always exits 0, so a caller can never let it block or fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-secondmate-viewer-window)

SCRIPT="$ROOT/bin/fm-secondmate-viewer-window.sh"

# make_tmux <dir>: a controllable fake tmux. FM_TMUX_STATE names a file that
# tracks which window names currently exist (one per line); FM_TMUX_NO_SESSION
# set to 1 makes has-session fail, as if no local tmux session were running
# yet. new-window appends the requested name to that state file and logs the
# full argv (one call per line) to FM_TMUX_CALL_LOG, so a test can assert
# exactly one creation happened. send-keys logs the literal text typed into the
# pane to FM_TMUX_KEYS_LOG, keyed by window id, so the composed SSH/herdr
# command is directly observable.
make_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_TMUX_STATE:?}
case "${1:-}" in
  has-session)
    [ "${FM_TMUX_NO_SESSION:-0}" != 1 ]
    exit $?
    ;;
  list-windows)
    [ -f "$state" ] || exit 0
    cat "$state"
    exit 0
    ;;
  new-window)
    name=
    while [ "$#" -gt 0 ]; do
      case "$1" in -n) shift; name=$1 ;; esac
      shift
    done
    printf '%s\n' "$name" >> "$state"
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    wid="@$(wc -l < "$state" | tr -d '[:space:]')"
    printf '%s\n' "$wid"
    exit 0
    ;;
  set-window-option) exit 0 ;;
  send-keys)
    target=
    text=
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift; target=$1 ;; Enter) : ;; *) text=$1 ;; esac
      shift
    done
    printf '%s\t%s\n' "$target" "$text" >> "${FM_TMUX_KEYS_LOG:?}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_case <name>: a fresh isolated home with FM_STATE_OVERRIDE/FM_CONFIG_OVERRIDE
# and fresh tmux state/log files, so cases never bleed into each other.
CASE_N=0
new_case() {
  local name=$1
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_N-$name"
  CASE_STATE="$CASE_DIR/state"
  CASE_CONFIG="$CASE_DIR/config"
  mkdir -p "$CASE_STATE" "$CASE_CONFIG"
  TMUX_STATE="$CASE_DIR/tmux-windows"
  TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log"
  TMUX_KEYS_LOG="$CASE_DIR/tmux-keys.log"
  : > "$TMUX_CALL_LOG"
  : > "$TMUX_KEYS_LOG"
}

# write_meta <id> <remote-host> <remote-session>
write_meta() {
  local id=$1 host=$2 session=$3
  {
    printf 'remote_host=%s\n' "$host"
    printf 'remote_herdr_session=%s\n' "$session"
    printf 'remote_backend=herdr\n'
    printf 'kind=secondmate\n'
  } > "$CASE_STATE/$id.meta"
}

opt_in() {
  : > "$CASE_CONFIG/secondmate-viewer-window"
}

run_viewer() {  # <id> [extra env...] -> stdout, rc always 0
  local id=$1; shift
  FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_TMUX_STATE="$TMUX_STATE" FM_TMUX_CALL_LOG="$TMUX_CALL_LOG" FM_TMUX_KEYS_LOG="$TMUX_KEYS_LOG" \
    TMUX='' \
    env "$@" "$SCRIPT" "$id"
}

# --- opt-in gating ------------------------------------------------------------

fb=$(make_tmux "$TMP_ROOT/optout")
new_case optout
write_meta sm1 serenity fm-remote
out=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux run_viewer sm1) || fail "script must always exit 0 (optout)"
case "$out" in
  "skipped: config/secondmate-viewer-window absent") pass "opt-in gate: silently skipped with no config flag present" ;;
  *) fail "opt-in gate: expected an absent-flag skip, got: $out" ;;
esac
[ ! -s "$TMUX_CALL_LOG" ] || fail "opt-in gate: tmux must never be touched while opted out"

# --- scoping: no remote route recorded ---------------------------------------

fb=$(make_tmux "$TMP_ROOT/noroute")
new_case noroute
opt_in
: > "$CASE_STATE/sm1.meta"
out=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux run_viewer sm1) || fail "script must always exit 0 (noroute)"
case "$out" in
  skipped:*"remote_host/remote_herdr_session"*) pass "scoping: skipped when meta has no remote route" ;;
  *) fail "scoping: expected a no-remote-route skip, got: $out" ;;
esac

# --- scoping: primary backend is not tmux ------------------------------------

fb=$(make_tmux "$TMP_ROOT/notmux")
new_case notmux
opt_in
write_meta sm1 serenity fm-remote
out=$(PATH="$fb:$BASE_PATH" FM_BACKEND=herdr run_viewer sm1) || fail "script must always exit 0 (notmux)"
case "$out" in
  "skipped: primary backend is 'herdr', not tmux") pass "scoping: skipped when the primary's own resolved backend is not tmux" ;;
  *) fail "scoping: expected a wrong-backend skip, got: $out" ;;
esac
[ ! -s "$TMUX_CALL_LOG" ] || fail "scoping: tmux must never be touched on a non-tmux backend"

# --- scoping: no local tmux session to host the window ------------------------

fb=$(make_tmux "$TMP_ROOT/nosession")
new_case nosession
opt_in
write_meta sm1 serenity fm-remote
out=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux FM_TMUX_NO_SESSION=1 run_viewer sm1) || fail "script must always exit 0 (nosession)"
case "$out" in
  skipped:*"no local tmux session"*) pass "scoping: skipped when no local tmux session exists yet" ;;
  *) fail "scoping: expected a no-session skip, got: $out" ;;
esac

# --- missing tools are reported, never a hard failure -------------------------

new_case notools
opt_in
write_meta sm1 serenity fm-remote
notools_fb=$(fm_fakebin "$TMP_ROOT/notools")
core_fb=$(fm_fakebin "$TMP_ROOT/core")
ln -sf "$(command -v env)" "$core_fb/env"
ln -sf "$(command -v bash)" "$core_fb/bash"
ln -sf "$(command -v dirname)" "$core_fb/dirname"
out=$(PATH="$core_fb:$notools_fb" FM_BACKEND=tmux run_viewer sm1) || fail "script must always exit 0 (notools)"
case "$out" in
  "skipped: tmux not installed") pass "tool presence: missing tmux is reported as skipped, not a crash" ;;
  *) fail "tool presence: expected a tmux-missing skip, got: $out" ;;
esac

# --- create then idempotent no-op on a repeat run ------------------------------

fb=$(make_tmux "$TMP_ROOT/create")
new_case create
opt_in
write_meta sm1 serenity.example fm-remote
out=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux run_viewer sm1) || fail "script must always exit 0 (create)"
case "$out" in
  "created: firstmate:2ndmate-sm1-view") pass "create: makes exactly the expected stable window name on first run" ;;
  *) fail "create: expected a created line for the new window, got: $out" ;;
esac
[ "$(wc -l < "$TMUX_CALL_LOG" | tr -d '[:space:]')" = 1 ] || fail "create: exactly one tmux new-window call expected, got: $(cat "$TMUX_CALL_LOG")"

keys_line=$(cat "$TMUX_KEYS_LOG")
case "$keys_line" in
  *"serenity.example"*"fm-remote"*) pass "create: the ssh/herdr command is built from this secondmate's own recorded host and session" ;;
  *) fail "create: expected the composed command to reference serenity.example and fm-remote, got: $keys_line" ;;
esac
case "$keys_line" in
  *"spotfx"*|*"homelab"*|*"fm-remote-secondmate-control"*) fail "create: command must never reference an unrelated hardcoded secondmate name" ;;
  *) : ;;
esac

out2=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux run_viewer sm1) || fail "script must always exit 0 (repeat)"
case "$out2" in
  "exists: firstmate:2ndmate-sm1-view") pass "idempotent: a repeat run detects the live window and reports exists" ;;
  *) fail "idempotent: expected an exists line on the second run, got: $out2" ;;
esac
[ "$(wc -l < "$TMUX_CALL_LOG" | tr -d '[:space:]')" = 1 ] || fail "idempotent: a repeat run must never call tmux new-window again"

# --- scoping: two different secondmate ids never collide ----------------------

fb=$(make_tmux "$TMP_ROOT/twoids")
new_case twoids
opt_in
write_meta alpha host-a fm-remote
write_meta bravo host-b fm-remote
out_a=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux run_viewer alpha) || fail "script must always exit 0 (alpha)"
out_b=$(PATH="$fb:$BASE_PATH" FM_BACKEND=tmux run_viewer bravo) || fail "script must always exit 0 (bravo)"
[ "$out_a" = "created: firstmate:2ndmate-alpha-view" ] || fail "two-ids: expected alpha's own window name, got: $out_a"
[ "$out_b" = "created: firstmate:2ndmate-bravo-view" ] || fail "two-ids: expected bravo's own window name, got: $out_b"
[ "$(wc -l < "$TMUX_CALL_LOG" | tr -d '[:space:]')" = 2 ] || fail "two-ids: expected exactly two distinct window creations"
pass "scoping: two different secondmate ids never collide on the same viewer window name"

exit 0
