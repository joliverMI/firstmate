#!/usr/bin/env bash
# fm-supervisor-pane-lib.sh - the single owner of "is firstmate's own pane safe
# to type into right now?".
#
# bin/fm-supervisor-target-lib.sh answers WHICH pane runs firstmate. This file
# answers whether that pane may be written to at this instant, which is the
# safety half of every operational injection: a busy pane means a turn is
# already running, and a non-empty composer means real unsubmitted text (a
# half-typed captain line, or a previous injection whose Enter was swallowed)
# that an injection would silently concatenate itself onto.
#
# It has two callers, and they inject under opposite presence conditions -
# bin/fm-supervise-daemon.sh only while away mode is ON, bin/fm-continuity-
# deadman.sh only while it is OFF - so this predicate must not live inside
# either one. The classification contracts themselves stay where they already
# live: bin/fm-backend.sh dispatches per backend and bin/fm-composer-lib.sh owns
# both composer-content classification and the harness-scoped busy-line match.
# This file only asks them the question.
#
# This file is sourced by scripts and has no side effects on source.

FM_SUPERVISOR_PANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Self-sufficient sourcing: a caller that already pulled these in (the away-mode
# daemon does) is left alone, so nothing is sourced twice.
if ! declare -F fm_backend_busy_state >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$FM_SUPERVISOR_PANE_LIB_DIR/fm-backend.sh"
fi
if ! declare -F fm_busy_lines_match >/dev/null 2>&1; then
  # shellcheck source=bin/fm-composer-lib.sh disable=SC1091
  . "$FM_SUPERVISOR_PANE_LIB_DIR/fm-composer-lib.sh"
fi

# Both predicates are BACKEND-AWARE: dispatch goes through bin/fm-backend.sh's
# generic per-backend primitives rather than a hand-rolled case statement, and
# <backend> defaults to tmux when omitted so a caller that passes only <target>
# behaves as it always has.
#
# This rendered reader applies only to firstmate's OWN pane. It never classifies
# a recorded worker task. The detected primary harness selects exactly one busy
# signature, so output from another harness cannot make the primary read busy.
#
# The harness is resolved lazily and memoized: detection walks process ancestry,
# which is too heavy to pay on every source of this library (unit tests and the
# away launcher source their callers purely for pure functions).
# bin/fm-harness.sh is the single detection owner; an unresolvable harness
# becomes "unknown" rather than an error. FM_SUPERVISOR_PANE_HARNESS presets it.
FM_SUPERVISOR_PANE_HARNESS=${FM_SUPERVISOR_PANE_HARNESS:-}
fm_supervisor_pane_harness() {
  if [ -z "${FM_SUPERVISOR_PANE_HARNESS:-}" ]; then
    FM_SUPERVISOR_PANE_HARNESS=$("$FM_SUPERVISOR_PANE_LIB_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
    [ -n "$FM_SUPERVISOR_PANE_HARNESS" ] || FM_SUPERVISOR_PANE_HARNESS=unknown
  fi
  printf '%s' "$FM_SUPERVISOR_PANE_HARNESS"
}

# True when the supervisor pane is mid-turn. A backend with native agent state
# answers directly; otherwise fall back to the harness-scoped match over the
# pane tail. An unreadable pane is NOT busy here - the composer check below is
# the positive-proof gate that refuses an unreadable pane.
fm_supervisor_pane_is_busy() {  # <target> [backend]
  local target=$1 backend=${2:-tmux} native tail40 harness
  harness=$(fm_supervisor_pane_harness)
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$native" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match "$harness"
}

# True unless the composer is POSITIVELY PROVEN empty. Everything else is unsafe:
# real unsubmitted text, ambiguous structure, unreadable state, and blank or
# otherwise unidentified rows (the strict container-proof rule owned by
# bin/fm-composer-lib.sh), plus any future verdict. `unknown` covers a bare
# dead-shell prompt, where typing the message could EXECUTE it. That detector
# drops dim/faint ghost text and strips the harness's composer box borders, so an
# aligned ghost-only or idle bordered claude composer ("| > ... |") is correctly
# proven empty while a modal dialog or dead shell never is.
fm_supervisor_pane_input_pending() {  # <target> [backend]
  local target=$1 backend=${2:-tmux}
  [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]
}
