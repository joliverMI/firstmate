#!/usr/bin/env bash
# fm-secondmate-viewer-window.sh - best-effort local tmux viewer window for one
# LIVE remote secondmate, presentation-only and never authoritative.
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
# It creates, or on a later sweep leaves alone, exactly one tmux window in the
# PRIMARY's own local tmux session per secondmate id, named "2ndmate-<id>-view"
# (stable and greppable, so a repeated sweep detects it and never accumulates
# duplicates). The window runs an SSH command that attaches to that
# secondmate's own recorded Herdr session - state/<id>.meta's remote_host and
# remote_herdr_session, read fresh every call, never a hardcoded host or
# session name - using the same HERDR_SESSION=<session> ... --session
# <session> targeting pattern bin/backends/herdr.sh's fm_backend_herdr_cli
# uses for every other herdr call in this repo.
#
# Herdr's interactive TUI attach has no other documented CLI entry point
# anywhere in this repository - every existing herdr call here is a headless
# JSON-RPC subcommand. This deliberately does not invent or guess a flag to
# force an initial workspace switch: the captain lands on Herdr's own bare
# session view in the new window and switches to that secondmate's own
# "2ndmate-<id>" workspace exactly as with any other Herdr session
# (docs/herdr-backend.md).
#
# Never touches state/<id>.meta, is never a target for fm-send.sh,
# fm-control.sh, or fm-peek.sh, and adds no new control surface. A failure
# here - SSH unreachable, herdr or tmux missing, the primary not on the tmux
# backend, window creation refused - is always best-effort: this script
# reports the outcome on stdout and always exits 0, so a caller can never let
# it fail, block, or slow anything.
#
# Output protocol, one line, stable for script/test consumers:
#   created: <session>:<window>   a new viewer window was made
#   exists: <session>:<window>    the viewer window was already present (idempotent no-op)
#   skipped: <reason>             opted out, wrong backend, missing tool, no route, etc.
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

wname="2ndmate-$id-view"

ses=firstmate
if [ -n "${TMUX:-}" ]; then
  ses=$(tmux display-message -p '#S' 2>/dev/null) || ses=firstmate
  [ -n "$ses" ] || ses=firstmate
fi

if ! tmux has-session -t "$ses" 2>/dev/null; then
  echo "skipped: no local tmux session '$ses' to host the viewer window"
  exit 0
fi

if tmux list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qx "$wname"; then
  echo "exists: $ses:$wname"
  exit 0
fi

remote_cmd="HERDR_SESSION=$(printf '%q' "$remote_session") herdr --session $(printf '%q' "$remote_session")"
ssh_line="ssh -t $(printf '%q' "$remote_host") $(printf '%q' "$remote_cmd")"

wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" 2>/dev/null) || {
  echo "skipped: tmux window creation failed in session '$ses'"
  exit 0
}
tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
tmux send-keys -t "$wid" "$ssh_line" Enter 2>/dev/null || true

echo "created: $ses:$wname"
