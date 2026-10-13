#!/usr/bin/env bash
# fm-secondmate-viewer-window.sh - best-effort local tmux viewer window for the
# LIVE herdr-backed remote secondmate(s) that share one (remote_host,
# remote_herdr_session) pair, presentation-only and never authoritative.
#
# Usage:
#   bin/fm-secondmate-viewer-window.sh <secondmate-id>
#
# Opt-in only: this no-ops silently unless the local, gitignored
# config/secondmate-viewer-window presence flag exists (docs/configuration.md
# "Secondmate viewer window"). It is called from bin/fm-bootstrap.sh's
# secondmate_liveness_one, once per session-start/recovery sweep, only after
# that sweep has already confirmed the secondmate's remote endpoint is alive
# and routed on the herdr backend - this script trusts that gating and never
# re-probes liveness itself.
#
# One remote host commonly hosts several secondmates inside the same Herdr
# session (state/<id>.meta's remote_host and remote_herdr_session), so this
# creates, or on a later sweep leaves alone, exactly one tmux window per
# DISTINCT (remote_host, remote_herdr_session) pair rather than one per
# secondmate id. The distinct-pair set is read fresh from every registered
# secondmate's own state/<id>.meta (kind=secondmate, remote_backend=herdr),
# not only the id passed on this invocation, so the window name stays stable
# across a sweep regardless of call order or of a sibling secondmate's
# transient liveness. When exactly one pair is registered - the common case -
# the window is named the stable, greppable "captains"; a second or further
# distinct pair gets its own stable "captains-<host>-<session>" name (host and
# session sanitized for a tmux window name), so pairs never collide and a
# repeated sweep never accumulates duplicates.
#
# The window runs `ssh -t <host> 'PATH=$HOME/.local/bin:$PATH herdr session
# attach <session>'` - $HOME expands on the REMOTE side, inside Herdr's own
# clickable multi-session sidebar (`herdr session attach`), exactly the
# command the captain ran by hand after every restart before this existed.
# Unlike a single secondmate's own `--session <session>` CLI view, `session
# attach` is what surfaces every secondmate sharing that Herdr session in one
# sidebar.
#
# Never touches state/<id>.meta, is never a target for fm-send.sh,
# fm-control.sh, or fm-peek.sh, and adds no new control surface. A failure
# here - SSH unreachable, herdr or tmux missing, the primary not on the tmux
# backend, window creation refused - is always best-effort: this script
# reports the outcome on stdout and always exits 0, so a caller can never let
# it fail, block, or slow anything.
#
# Output protocol, one line, stable for script/test consumers:
#   created: <session>:<window>     a new viewer window was made
#   exists: <session>:<window>      the viewer window was already present and alive (idempotent no-op)
#   respawned: <session>:<window>   the viewer window existed but its pane had died; it was respawned in place
#   skipped: <reason>               opted out, wrong backend, missing tool, no route, etc.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

id=${1:-}
if [ -z "$id" ]; then
  echo "skipped: no secondmate id given"
  exit 0
fi

if [ ! -e "$CONFIG/secondmate-viewer-window" ]; then
  echo "skipped: config/secondmate-viewer-window absent"
  exit 0
fi

meta="$STATE/$id.meta"
if [ ! -f "$meta" ]; then
  echo "skipped: no metadata for $id"
  exit 0
fi

remote_host=$(fm_meta_get "$meta" remote_host)
remote_session=$(fm_meta_get "$meta" remote_herdr_session)
if [ -z "$remote_host" ] || [ -z "$remote_session" ]; then
  echo "skipped: $id has no recorded remote_host/remote_herdr_session"
  exit 0
fi

case "$remote_host" in
  ''|-*|*[!A-Za-z0-9._-]*)
    echo "skipped: $id has an unsafe recorded remote_host: $remote_host"
    exit 0
    ;;
esac

backend=$(fm_backend_name 2>/dev/null)
if [ "$backend" != tmux ]; then
  echo "skipped: primary backend is '${backend:-unknown}', not tmux"
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "skipped: tmux not installed"
  exit 0
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "skipped: ssh not installed"
  exit 0
fi

# sanitize_for_window_name <text>: tmux window names tolerate most bytes, but
# we keep the fallback multi-pair name boringly greppable and shell-safe.
sanitize_for_window_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# Distinct (remote_host, remote_herdr_session) pairs across every registered
# secondmate, read fresh every call so the window name is stable regardless
# of which secondmate triggered this run or which siblings are live right now.
distinct_pairs=$(
  for other_meta in "$STATE"/*.meta; do
    [ -f "$other_meta" ] || continue
    grep -q '^kind=secondmate$' "$other_meta" 2>/dev/null || continue
    [ "$(fm_meta_get "$other_meta" remote_backend)" = herdr ] || continue
    other_host=$(fm_meta_get "$other_meta" remote_host)
    other_session=$(fm_meta_get "$other_meta" remote_herdr_session)
    [ -n "$other_host" ] && [ -n "$other_session" ] || continue
    printf '%s\t%s\n' "$other_host" "$other_session"
  done | sort -u
)
pair_count=$(printf '%s\n' "$distinct_pairs" | grep -c .)

if [ "$pair_count" -le 1 ]; then
  wname=captains
else
  wname="captains-$(sanitize_for_window_name "$remote_host")-$(sanitize_for_window_name "$remote_session")"
fi

ses=firstmate
if [ -n "${TMUX:-}" ]; then
  ses=$(tmux display-message -p '#S' 2>/dev/null) || ses=firstmate
  [ -n "$ses" ] || ses=firstmate
fi

if ! tmux has-session -t "$ses" 2>/dev/null; then
  echo "skipped: no local tmux session '$ses' to host the viewer window"
  exit 0
fi

# shellcheck disable=SC2016 # $HOME is meant to expand on the remote side, not here.
remote_cmd='PATH=$HOME/.local/bin:$PATH herdr session attach '"$(printf '%q' "$remote_session")"
ssh_line="ssh -t $(printf '%q' "$remote_host") $(printf '%q' "$remote_cmd")"

if tmux list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qx "$wname"; then
  pane_dead=$(tmux list-panes -t "$ses:$wname" -F '#{pane_dead}' 2>/dev/null | head -1)
  if [ "$pane_dead" = 1 ]; then
    tmux respawn-window -t "$ses:$wname" 2>/dev/null || true
    tmux send-keys -t "$ses:$wname" "$ssh_line" Enter 2>/dev/null || true
    echo "respawned: $ses:$wname"
    exit 0
  fi
  echo "exists: $ses:$wname"
  exit 0
fi

wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" 2>/dev/null) || {
  echo "skipped: tmux window creation failed in session '$ses'"
  exit 0
}
tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
# remain-on-exit so a dropped ssh/herdr session leaves a respawn-able dead
# pane behind instead of silently closing the whole window.
tmux set-window-option -t "$wid" remain-on-exit on 2>/dev/null || true
tmux send-keys -t "$wid" "$ssh_line" Enter 2>/dev/null || true

echo "created: $ses:$wname"
