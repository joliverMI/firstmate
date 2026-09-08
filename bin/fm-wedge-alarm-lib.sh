#!/usr/bin/env bash
# fm-wedge-alarm-lib.sh - the single owner of firstmate's backend-independent
# active alert channels.
#
# A supervision failure that nobody hears is the failure. This library owns the
# configurable, pane-independent alert used when firstmate must reach the
# captain from outside every terminal surface: an OS-level macOS notification, a
# herdr notification, or a captain-supplied command (push to a phone, etc.).
#
# It has two callers today and no side effects on source:
#   - bin/fm-supervise-daemon.sh's away-mode inject_wedge_alarm (its original
#     home), which alarms when buffered escalations cannot be delivered.
#   - bin/fm-continuity-deadman.sh, which alarms in ATTENDED mode when this
#     home's supervision chain has been dead past the grace window. Factoring
#     these helpers out is what makes the attended caller possible: the alarm
#     must not be reachable only from the away-mode daemon, because the outage
#     it now covers (docs/watcher-continuity.md "Continuity deadman") happens
#     precisely while away mode is OFF.
#
# Set FM_WEDGE_ALARM_TITLE before calling to name the alert; callers own their
# own wording, and the default preserves the away-mode daemon's original title.
#
# docs/wedge-alarm.md owns the operator-facing channel configuration.

FM_WEDGE_ALARM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WEDGE_ALARM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$FM_WEDGE_ALARM_LIB_DIR/.." && pwd)}}"

WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10
WEDGE_ALARM_NOTIFIER_PID=
# Alert title. Callers set this before wedge_alarm_notify; the default is the
# away-mode daemon's original wording so its behavior is unchanged.
FM_WEDGE_ALARM_TITLE=${FM_WEDGE_ALARM_TITLE:-"firstmate: away-mode escalations WEDGED"}

# Diagnostic logging seam. The away-mode daemon defines its own log() writing to
# its daemon log, and that definition wins whenever these helpers run inside it,
# so its log lines are byte-identical to before. A caller with no log() sends
# lines to FM_WEDGE_ALARM_LOG_FILE when it names one, and otherwise discards
# them: a logging failure must never abort an alarm.
fm_wedge_alarm_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
    return 0
  fi
  [ -n "${FM_WEDGE_ALARM_LOG_FILE:-}" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$FM_WEDGE_ALARM_LOG_FILE" 2>/dev/null || true
  return 0
}

# A caller's own tmux status-line flash is a cosmetic, client-side OSD with no
# cross-backend equivalent, so a wedged non-tmux primary (the 2026-07-10
# overnight incident: a claude-on-herdr primary) got NO active signal - only a
# passive durable marker, which nothing surfaces until the next fleet action
# (that night, 20 escalations sat buffered for 8.5h). These helpers add a
# configurable active alert that does not depend on any pane or its backend
# status-line: an OS-level macOS notification, a herdr notification, or a
# captain-supplied command (push to a phone, etc.).
# Every channel is best-effort - a missing or failing channel logs and is
# skipped, never crashing the caller's loop - and each caller's durable marker
# stays exactly as before.
#
# Config: config/wedge-alarm (local, gitignored), one channel directive per
# non-empty, non-comment line. FM_WEDGE_ALARM_CHANNEL overrides the file with a
# single directive. Directives:
#   off              disable the active alert entirely, regardless of position
#                    (marker + flash remain)
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner (backend-independent)
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via `sh -c`, summary on $1 and on stdin
# An absent config means auto, i.e. default-ON on macOS: the alarm's whole
# purpose is to never be silent, so the reachable OS channel fires unless the
# captain explicitly disables it.

# Print the configured channel directives, one per line. FM_WEDGE_ALARM_CHANNEL
# wins (a single directive); else each non-empty, non-comment line of
# config/wedge-alarm; else "auto".
wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${FM_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  # Resolved per call, not at source time, so a caller that sets FM_HOME after
  # sourcing this library still reads its own home's configuration.
  cfg="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_WEDGE_ALARM_ROOT}/config}/wedge-alarm"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

# Resolve the platform's default OS-level channel for `auto`. macOS reaches the
# captain via an osascript Notification Center banner; other platforms have no
# built-in OS channel (the captain wires a command: directive), so this prints
# nothing and wedge_alarm_notify logs that the marker is the only signal.
wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

wedge_alarm_run_bounded() {
  local channel=$1 timeout monitor_was_on=0 pid start elapsed rc
  shift
  timeout=${FM_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  case $- in
    *m*) ;;
    *) fm_wedge_alarm_log "wedge alarm: ${channel} notifier skipped because its watchdog could not start"; return 125 ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "-$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fm_wedge_alarm_log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# The single execution seam for every configured notifier channel.
# FM_WEDGE_ALARM_EXEC, when set, REPLACES the real notifier: the resolved channel
# name and summary are handed to that command instead of ever invoking osascript
# or herdr or a captain-supplied command. This is the one injection point the test harness forces to a recorder
# so no test can post a real desktop notification - the library-mode guard at the
# foot of this file defaults it to "discard" whenever the daemon is SOURCED
# rather than executed, which is the only way a test reaches these functions. The
# special value "discard" fires nothing; unset means production (the executed
# daemon), so the real channels fire.
wedge_alarm_os_notifier_override() {  # <channel> <summary>
  local channel=$1 summary=$2 rc exec_override=${FM_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      fm_wedge_alarm_log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# Post a macOS Notification Center banner. `display notification` is OS-level,
# independent of any terminal pane or multiplexer status-line. The summary is
# passed as an argv item (never interpolated into the AppleScript source) so its
# text can never break the script, and the caller-supplied title is passed the
# same way for the same reason. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_osascript() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override osascript "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v osascript >/dev/null 2>&1 || {
    fm_wedge_alarm_log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Basso"' \
    -e 'end run' "$summary" "$FM_WEDGE_ALARM_TITLE" >/dev/null 2>&1 && return 0
  fm_wedge_alarm_log "wedge alarm: osascript notification failed"
  return 1
}

# Post a herdr UI notification - herdr's own surface, separate from the pane and
# its status-line. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_herdr() {  # <summary>
  local summary=$1 rc
  wedge_alarm_os_notifier_override herdr "$summary"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  command -v herdr >/dev/null 2>&1 || {
    fm_wedge_alarm_log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show "$FM_WEDGE_ALARM_TITLE" \
    --body "$summary" --sound request >/dev/null 2>&1 && return 0
  fm_wedge_alarm_log "wedge alarm: herdr notification failed"
  return 1
}

# Run a captain-supplied command with the summary on $1 and on stdin, so an
# alert can reach a phone/pager (ntfy, Slack, SMS) even when the captain is away
# from the machine entirely. Best-effort: logs and returns 1 on failure.
wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  if [ "${WEDGE_ALARM_EMIT_ACTIVE:-}" != 1 ]; then
    wedge_alarm_emit command "$summary" "$cmd"
    return $?
  fi
  [ -n "$cmd" ] || { fm_wedge_alarm_log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" fm-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  fm_wedge_alarm_log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

wedge_alarm_emit() {  # <channel> <summary>
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${FM_WEDGE_ALARM_EXEC:-} WEDGE_ALARM_EMIT_ACTIVE=1
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      fm_wedge_alarm_log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire every configured active-alert channel, best-effort. Always returns 0: a
# channel failure can never abort inject_wedge_alarm or the daemon loop. Any
# `off` directive disables the alert, regardless of position; an unresolvable
# `auto` (no OS channel on this platform) logs that the durable marker is the
# only signal. Every notifier routes through the test-forced recorder seam.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') fm_wedge_alarm_log "wedge alarm: no OS-level alert channel on $(uname); durable marker $marker is the only signal - set config/wedge-alarm (e.g. a command: directive)" ;;
      osascript|herdr) wedge_alarm_emit "$ch" "$summary" || true ;;
      command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true ;;
      *) fm_wedge_alarm_log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}
