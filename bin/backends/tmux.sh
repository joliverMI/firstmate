#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-cursor-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# Input delivery, destruction, and exact targets.
#
# This file contains four primitives that put input into a pane, one that
# destroys a window, and one recovery-grade state read - and every one of them
# is now gated by an exact-target resolver:
#
#   fm_backend_tmux_send_key         - gated (below), TARGET-KIND aware
#   fm_backend_tmux_send_text_submit - gated (below), TARGET-KIND aware; the
#                                      submit core in bin/fm-tmux-lib.sh
#                                      receives the already resolved target
#   fm_backend_tmux_send_text_line   - gated (below), TARGET-KIND aware
#   fm_backend_tmux_send_literal     - gated (below), TARGET-KIND aware
#   fm_backend_tmux_kill             - gated (below), always NAME-only
#   fm_backend_tmux_agent_state      - gated (below), always NAME-only; still
#                                      needs one extra exact-pinned read of its
#                                      own to keep its missing/unreadable
#                                      split, see that function's header
#
# There are TWO resolvers, and which one applies is decided by where the
# target came from - never by inspecting the target string, because inferring
# the kind from the string is the whole bug:
#
#   fm_backend_tmux_exact_target       (bin/fm-backend.sh) - the general one,
#     the same function fm_backend_target_exists answers with. It also reads a
#     dotted component that matches no window name as `window.pane`, which an
#     operator-declared address legitimately uses.
#   fm_backend_tmux_exact_target_named (below) - that resolver minus the
#     pane-qualified fallback: a window component is matched as a literal NAME
#     and nothing else.
#
# kill and agent_state are always NAME-only: both resolve a RECORDED task's own
# `<session>:<window>` metadata field, which is only ever a name. The four
# sends take BOTH kinds, so each declares its own with a trailing target-kind
# argument (`named`, the default, or `general`) that its caller sets from the
# provenance of the target it holds - fm-send.sh's recorded-metadata paths and
# fm-control.sh's validated task endpoint are `named`, fm-send.sh's ad hoc
# verified-at-send-time string and fm-supervise-daemon.sh's FM_SUPERVISOR_TARGET
# are `general`, and fm-spawn.sh types into a window it just created, so
# `named`. Omitting the kind means `named`, so an un-updated call site fails
# toward refusal rather than toward pane reinterpretation.
#
# Re-reading an unmatched dotted name as some other window's pane answers (or,
# for kill, destroys, or for a send, TYPES INTO) an unrelated task's endpoint
# under the dead task's label, which is the false-positive class this gating
# exists to remove; see fm_backend_tmux_exact_target_named's header for the
# verified shape.
#
# That distinction is
# not cosmetic: while an earlier send re-derived `=$session:=$window` on its
# own, a dotted window NAME that the probe had matched in the session
# inventory sent into a SIBLING window's pane, because tmux splits the
# trailing `.` off as a pane specifier before matching the name (verified on
# tmux 3.4 under `tmux -f /dev/null`: with live windows `fm-1.2` and `fm-1`,
# `send-keys -t '=s:=fm-1.2'` landed in fm-1's pane 2). The resolver answers
# that shape with the window's `@N` id instead.
#
# Why a gate at all: the old pre-send probe was
# `tmux display-message -p -t "$T" '#{pane_id}'`, whose exit status this
# backend no longer trusts anywhere. With `sess:fm-alpha` destroyed and
# `sess:fm-alpha-2` alive it exits 0, and the unpinned send that followed
# DELIVERED into fm-alpha-2's pane - one crew's keystrokes, or a whole steer,
# landing in a DIFFERENT live crew's composer. Prefix-colliding task ids (1 and
# 10, 2 and 20) are routine, so that shape needs no dotted id at all.
# fm_backend_tmux_agent_state carried the identical defect for its own SESSION
# component (unpinned `list-windows -t "$session"`, and tmux resolves a
# target-session by prefix exactly like a target-window): a task recorded as
# `dead-session:fm-1` fell through to a live prefix-colliding
# `dead-session-2`'s own window inventory, found a same-named window there,
# and read THAT window's process under the dead session's label - reporting a
# nonexistent endpoint `alive`, the one verdict that licenses the fleet to act
# on a liveness line that was never actually verified. fm_backend_tmux_kill
# carried the dotted-window-name gap instead: its own hand-built
# `=$session:=$window` pin cannot express a dotted window NAME, so
# `kill-window` split the trailing `.` off as a pane specifier and could
# remove a DIFFERENT live window entirely rather than merely fail to remove
# the one it was asked to. Resolving by NAME alone closes both directions of
# that gap: the dotted name is matched literally when the window is live, and
# refused - not reinterpreted as a sibling's pane - when it is already gone.
#
# What remains UNPINNED, derived mechanically rather than from memory - every
# raw `tmux <subcommand> ... -t <target>` under bin/ that takes a
# caller-supplied target, minus the resolver's own calls and the primitives
# gated above; re-derive it with:
#
#   grep -rnE '(^|[^#])[[:space:]]*(LC_ALL=C )?tmux [a-z-]+' --include='*.sh' bin/ \
#     | grep -vE ':[0-9]+:[[:space:]]*#' | grep -E '\-t '
#
# Excluded from the list as not caller-supplied: the container-session checks
# that address this process's OWN session or the literal `firstmate` (this
# file's container_ensure, bin/fm-spawn.sh's worker-env read), and the
# creation-time `new-window`/`set-window-option` calls that address a window id
# this process just created.
#
# docs/tmux-backend.md ("Crew messaging is delivered only to an exactly
# resolved endpoint") owns the categorized remainder and the rationale for
# leaving it unpinned for now: read-only reads that can describe the wrong
# pane (fm_backend_tmux_capture, current_path, current_command, the two
# foreground-process probes, and fm_backend_tmux_create_task's duplicate-name
# check, all in this file, plus fm-tmux-lib.sh's composer/cursor/busy/
# pane-identity reads), two destructive callers outside this file
# (fm-teardown.sh's process-group reaper and fm-afk-launch.sh's
# daemon-session kill), and fm-supervise-daemon.sh's wedged-escalation
# status-line flash. None of them license recovery or deliver input the way
# the primitives above do; they are reported as an adjacent, not-yet-fixed
# gap rather than folded into this change.

# fm_backend_tmux_send_target: the single owner of which resolver a send uses.
# <target-kind> is the caller's declaration of where its target came from, and
# it is the ONLY input to that choice - the target string itself is never
# inspected to guess the kind, because guessing is precisely the defect this
# closes: `sess:fm-1.0` is a recorded window NAME when fm-send.sh read it out
# of a task's metadata and a pane address when an operator wrote it into
# FM_SUPERVISOR_TARGET, and the two are byte-identical.
#
#   named   - a recorded task's own `<session>:<window>` field, or a window
#             this process just created. Resolved by literal name only; a
#             window that is gone REFUSES instead of collapsing onto whatever
#             live sibling its trailing `.N` happens to address.
#   general - an explicit, operator-declared address, which may legitimately be
#             pane-qualified (`firstmate:0.1`). Full PR #12 behavior, unchanged.
#
# An omitted kind is `named`: a call site that has not been classified yet must
# fail toward refusing a live send, never toward typing into a stranger's pane.
# An unrecognized kind refuses outright rather than picking a default, so a
# typo cannot silently buy the permissive reading.
# Only ONE target shape reads two ways, and it is the only one the kinds
# disagree about: a colon-bearing `session:window`, whose window component
# tmux's own parser would split a trailing `.` off. Every other shape has
# exactly one reading and is answered by the shared resolver under both kinds -
# a colon-free `%N`/`@N`/`$N` id is exact by construction (fm-spawn.sh types
# into the `@N` of the window it just created), and a colon-free bare name is
# matched against the live inventory and REFUSED when ambiguous, never split
# into a pane. So `named` narrows exactly the dotted-window reading and nothing
# else, which is why routing a self-created window id through it stays correct.
fm_backend_tmux_send_target() {  # <target> [target-kind] -> prints an addressable target
  case "${2:-named}" in
    named)
      case "$1" in
        *:*) fm_backend_tmux_exact_target_named "$1" ;;
        *)   fm_backend_tmux_exact_target "$1" ;;
      esac
      ;;
    general) fm_backend_tmux_exact_target "$1" ;;
    *)
      echo "error: unknown tmux target kind '${2:-}' (expected 'named' or 'general')" >&2
      return 1
      ;;
  esac
}

# fm_backend_tmux_send_key: one named key, delivered only to an endpoint that
# resolves exactly. Anything else is refused before send-keys runs at all: a
# keystroke that goes nowhere is a nuisance, a keystroke in the wrong pane can
# be anything.
fm_backend_tmux_send_key() {  # <target> <key> [target-kind]
  local target
  target=$(fm_backend_tmux_send_target "$1" "${3:-}") || {
    echo "error: refusing to send key '$2': tmux target '$1' does not resolve to exactly one live endpoint" >&2
    return 1
  }
  tmux send-keys -t "$target" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Delegates to fm_tmux_submit_core (bin/fm-tmux-lib.sh); see that file
# for the composer-verification contract and echoed verdicts.
#
# This is the same-shaped refusal as fm_backend_tmux_send_key above, and the
# more consequential one: text is how every ordinary steer reaches every crew,
# so an unresolvable target that fell through to a live neighbour would type a
# whole message into the wrong worker's composer and submit it - and if that
# neighbour's composer then cleared, the verdict would read `empty` and report
# delivery CONFIRMED for a task that never received it. The resolved target is
# handed to the submit core, so the core's own composer and busy reads describe
# the same pane the text goes to. A refusal sends nothing, returns nonzero, and
# still echoes a verdict, because callers that read only the verdict
# (bin/fm-supervise-daemon.sh's injector) must not see `empty`.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [target-kind]
  local target
  target=$(fm_backend_tmux_send_target "$1" "${6:-}") || {
    echo "error: refusing to send text: tmux target '$1' does not resolve to exactly one live endpoint" >&2
    printf 'target-unresolved'
    return 1
  }
  fm_tmux_submit_core "$target" "$2" "$3" "$4" "$5"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`. Gated
# like fm_backend_tmux_send_key above: a target that does not resolve to
# exactly one live endpoint is refused before send-keys runs at all.
fm_backend_tmux_send_text_line() {  # <target> <text> [target-kind]
  local target
  target=$(fm_backend_tmux_send_target "$1" "${3:-}") || {
    echo "error: refusing to send text line: tmux target '$1' does not resolve to exactly one live endpoint" >&2
    return 1
  }
  tmux send-keys -t "$target" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`. Gated like
# fm_backend_tmux_send_text_line above.
fm_backend_tmux_send_literal() {  # <target> <text> [target-kind]
  local target
  target=$(fm_backend_tmux_send_target "$1" "${3:-}") || {
    echo "error: refusing to send literal text: tmux target '$1' does not resolve to exactly one live endpoint" >&2
    return 1
  }
  tmux send-keys -t "$target" -l "$2"
}

# fm_backend_tmux_exact_target_named: the NAME-only sibling of
# fm_backend_tmux_exact_target, and the resolver every consumer holding a
# RECORDED (or self-created) `<session>:<window>` reaches - fm_backend_tmux_kill
# and fm_backend_tmux_agent_state always, and the four send primitives whenever
# their caller declares target-kind `named`. It prints the addressed window's
# own `@N` id when the window component matches a live window NAME byte-exactly
# inside the exact-pinned session, and returns nonzero otherwise, with no
# further interpretation.
#
# The one difference from the general resolver is the pane-qualified fallback,
# and it is the whole point. fm_backend_tmux_exact_target answers a dotted
# window component that matches no window name by re-reading it as
# `window.pane`. That reading is correct for an operator-declared address - an
# explicit FM_SUPERVISOR_TARGET may legitimately address pane N of window W -
# but it is wrong for a RECORDED window, which is only ever a name: task ids
# admit dots (fm_task_id_path_safe) and pane index 0 always exists, so a dead
# `sess:fm-1.0` beside a live `fm-1` resolved to fm-1's pane 0. agent_state
# then read that unrelated task's foreground process under the dead task's
# label - `alive` for a window that does not exist - kill escalated the same
# pane-scoped answer into destroying the whole live `fm-1`, because
# `kill-window -t %N` removes the pane's entire window (verified on tmux 3.4) -
# and a send TYPED A STEER into that live stranger's composer and, once its
# composer cleared, reported delivery CONFIRMED for a task that never got it.
# Matching the name here byte-exactly against the session's own inventory is
# safe for a dotted name precisely because that name is never handed to tmux as
# a `-t` target string, so tmux's `.`-splitting parser never gets to reinterpret
# it; the `@N` id printed back is an address tmux cannot misread either.
fm_backend_tmux_exact_target_named() {  # <session:window> -> prints the window id
  local target=$1 session window listing line id rest
  case "$target" in
    *:*:*|'':*|*:'') return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  listing=$(LC_ALL=C tmux list-windows -t "=$session" -F '#{window_id} #{window_name}' 2>/dev/null) \
    || return 1
  while IFS= read -r line; do
    id=${line%% *}
    rest=${line#* }
    if [ -n "$id" ] && [ "$rest" = "$window" ]; then
      printf '%s' "$id"
      return 0
    fi
  done <<EOF
$listing
EOF
  return 1
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking
# anything so tmux can never interpret an empty target as the caller's
# current window - the same shape gate as before. A well-formed target is
# then resolved through fm_backend_tmux_exact_target_named rather than a
# hand-built `=$session:=$window` pin: that pin cannot express a dotted window
# NAME - tmux splits the trailing `.` off as a pane specifier before matching
# the name - so a task window named `fm-release-1.2` made
# `kill-window -t '=sess:=fm-release-1.2'` remove a DIFFERENT live window,
# `fm-release-1`, rather than merely fail to remove the one it was asked to
# (verified live on tmux 3.4). The named resolver answers a dotted name with
# the window's own `@N` id instead, which tmux cannot misread, and it refuses
# rather than re-reading an unmatched dotted name as some other window's pane -
# a reading that would put this function right back to killing a live sibling
# whenever the recorded window is already gone. A target that fails to resolve
# (already gone, or ambiguous) stays best-effort like the rest of this
# function: no tmux call is made, and the function still returns success,
# because a caller cleaning up an endpoint that is already dead - or that a
# recorded id no longer names uniquely - must not treat that as an error.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window exact
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  exact=$(fm_backend_tmux_exact_target_named "$target") || return 0
  tmux kill-window -t "$exact" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_classify_process_name: the single owner of the process-name
# vocabulary shared by every liveness signal below - `agent` for a verified
# harness, `shell` for an idle login/interactive shell, `other` for anything
# else. Keeping one classifier means the two independent name sources can never
# drift into disagreeing about what a given name means.
fm_backend_tmux_classify_process_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers above fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Existence is resolved through
# fm_backend_tmux_exact_target_named - the name-only resolver kill shares -
# rather than a second, independent lookup: the OLD code here validated
# existence with unpinned `list-windows -t "$session"`, and tmux resolves a
# target-session by PREFIX exactly like it resolves a target-window, so a
# recorded `dead-session:fm-1` fell through to a live prefix-colliding
# `dead-session-2`'s own window inventory, found a same-named window there, and
# read THAT window's foreground process under the dead session's label -
# reporting a nonexistent endpoint `alive` whenever its name merely prefixed a
# live sibling's, which is routine for fm-<task-id> windows (verified live on
# tmux 3.4: `list-windows -t dead-session` exits 0 off a live `dead-session-2`
# alone, and `display-message -t dead-session:fm-1` reads that same sibling's
# pane). The NAME-only resolver rather than the general one, because a
# recorded window component is a name and nothing else: the general resolver's
# pane-qualified fallback would answer a dead `sess:fm-1.0` with pane 0 of a
# live `fm-1` and hand this function the very same false `alive`, just reached
# by a different reading.
#
# When the resolver refuses, an exact-pinned `list-windows -t "=$session"`
# classifies why, and the classification re-confirms the window's own absence
# rather than inferring it: a readable inventory that still omits the window
# byte-exactly, or a definitive missing-session/server response, is `missing`;
# a readable inventory that DOES list the window means the resolver's refusal
# came from something other than absence, so that reads `unreadable`, as does
# any other read failure. `missing` licenses recovery and `unreadable` does
# not, so the two must never collapse into each other: a transient tmux
# problem reported as confident absence is the same lie as a false `alive`,
# pointed the other way.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window exact windows
  local foreground argv0s name fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if ! exact=$(fm_backend_tmux_exact_target_named "$target"); then
    if windows=$(LC_ALL=C tmux list-windows -t "=$session" -F '#{window_name}' 2>&1); then
      # A readable exact-session inventory settles that the SESSION is not
      # what is absent; the window's own byte-exact absence from it is what
      # makes `missing` an authoritative verdict. The resolver reads the same
      # inventory, so it can only refuse a listed window when its own read
      # failed - which is `unreadable`, never confirmed absence.
      if printf '%s\n' "$windows" | grep -Fqx "$window"; then
        printf 'unreadable'
      else
        printf 'missing'
      fi
    else
      case "$windows" in
        *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
          printf 'missing'
          ;;
        *)
          printf 'unreadable'
          ;;
      esac
    fi
    return 0
  fi
  target=$exact

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_backend_tmux_classify_process_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_backend_tmux_classify_process_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_backend_tmux_classify_process_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
