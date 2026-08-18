#!/usr/bin/env bash
# fm-fleet-audit-tick.sh - the fleet auditor's actual timer.
#
# Meant to be installed as a host cron entry (or an equivalent OS-level
# scheduler - a systemd timer works identically) firing every minute, forever:
#   * * * * *  FM_HOME=/path/to/home  /path/to/firstmate/bin/fm-fleet-audit-tick.sh
#
# Why cron and not another wake mechanism already in this fleet: every other
# trigger this fleet has (bin/fm-watch.sh, the process-event-source runner in
# bin/fm-procevent.sh) is polled BY a live supervision cycle - see the
# `process-event-sources` skill. That is exactly the shape that broke here:
# the auditor registered a durable check, correctly, but nothing was polling
# it because its home had no live session running the watcher. A trigger that
# depends on a live chat session cannot be the fix for "a live chat session
# was the single point of failure." Host cron is already running on this
# machine independent of any firstmate session (see `systemctl status cron`)
# and needs no new daemon, no new persistent store, and no agent to remember
# anything - it fires whether or not anyone is watching, survives a restart of
# any agent, and survives a reboot of the machine because cron re-reads its
# table on start.
#
# On every invocation, regardless of whether a sweep runs, this records a
# heartbeat (bin/fm-dashboard.sh audit-tick) - this is the "am I still
# ticking at all" signal the dashboard page shows separately from "when did a
# sweep last complete", because the two can legitimately disagree (a 15-minute
# audit interval means up to 15 minutes between completed sweeps even with a
# perfectly healthy once-a-minute timer) and only the heartbeat catches a
# timer that has silently stopped altogether.
#
# The interval itself is read fresh from the dashboard every tick, never
# cached, so a change the Admiral makes from the page takes effect on the very
# next tick with nobody told to re-arm anything.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH="$SCRIPT_DIR/fm-dashboard.sh"
SWEEP="$SCRIPT_DIR/fm-fleet-audit-sweep.sh"

iso_to_epoch() {  # <iso8601>
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

# Record the heartbeat first, unconditionally: even a tick that decides no
# sweep is due yet proves the timer itself is alive.
"$DASH" audit-tick >/dev/null 2>&1 || exit 0

status_json=$("$DASH" audit-status --json 2>/dev/null) || exit 0

# Due-ness only gates whether this tick ATTEMPTS a sweep; it deliberately does
# not also skip on `sweep_lock.running` here. The sweep script's own claim
# (bin/fm-dashboard.sh audit-claim, via Store.claim_audit_sweep) is what
# reclaims an abandoned lock past MAX_SWEEP_SECONDS - if a tick could give up
# before ever reaching that claim, a lock stuck by a crashed sweep would never
# get a chance to heal itself, and this timer would look alive (the heartbeat
# below still fires) while quietly never sweeping again. A due-but-genuinely-
# still-running attempt just costs one cheap claim call that fails fast.
interval_minutes=$(printf '%s' "$status_json" | jq -r '.interval_minutes')
case "$interval_minutes" in ''|*[!0-9]*) exit 0 ;; esac

last_completed=$(printf '%s' "$status_json" | jq -r '.last_run.completed_at // empty')

now_epoch=$(date +%s)
due=1
if [ -n "$last_completed" ]; then
  last_epoch=$(iso_to_epoch "$last_completed") || last_epoch=""
  if [ -n "$last_epoch" ]; then
    elapsed_min=$(( (now_epoch - last_epoch) / 60 ))
    [ "$elapsed_min" -ge "$interval_minutes" ] || due=0
  fi
fi

[ "$due" -eq 1 ] || exit 0

exec "$SWEEP"
