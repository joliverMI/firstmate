#!/usr/bin/env bash
# fm-dashboard-link-lib.sh - shared core for the Admiral's Fleet Dashboard's
# mechanical card link (docs/dashboard.md "The mechanical card link"), the one
# rule that connects a board card to the work actually serving it and advances
# its status accordingly. bin/fm-spawn.sh --card and bin/fm-backlog-handoff.sh
# --card both write a card's ref/agent identity and advance it from
# not_started to working; bin/fm-teardown.sh later advances an already-linked
# card onward once its work has landed. All three call sites are best-effort:
# a bad card id or an unreachable dashboard only warns loudly and best-effort
# records `fm-dashboard.sh audit-log --fleet` - it must never fail the spawn,
# handoff, or teardown that is already live, already routed, or already
# landed by the time the link runs.
#
# Every dashboard call here is a separately-failable network round trip, so a
# card's status is never assumed - only ever a value this call itself just
# read or was handed. Confirming an advance whose card state was never
# actually read is exactly the bug this shared core exists to prevent: it
# reads as a successful link on a card silently still frozen at not_started.

FM_DASHBOARD_LINK_FAILED=0
# Sentinel for fm_dashboard_link_and_advance's <known-status>: read the card's
# live status inside the call, after the ref/agent writes below have
# succeeded, rather than trust a value read earlier by the caller. Real board
# statuses are always one of the fleet-dashboard skill's eight fixed values,
# so this string can never collide with a genuine status.
FM_DASHBOARD_LINK_SELF_READ='@self-read'

# fm_dashboard_link_and_advance writes a card's ref and agent identity, then
# advances it from not_started to working - the link bin/fm-spawn.sh --card
# and bin/fm-backlog-handoff.sh --card both perform, worded identically
# ("dashboard: linked card ...", "warning: dashboard card link failed ...")
# because both really are the same operation: claim a fresh card for the work
# now serving it. A card already past not_started is left alone rather than
# overridden - only a card that answered the read at all can be confirmed
# past not_started, so the status read failing is itself a failure, never a
# license to report the link as already in place.
#
# <known-status> is either FM_DASHBOARD_LINK_SELF_READ (read it now, only
# after the ref/agent writes succeed - fm-spawn.sh's shape, which has no
# earlier read of its own) or a status string already read by the caller an
# instant earlier (fm-backlog-handoff.sh's shape: its own ownership check
# already read the card once, and a second read here would be a second
# separately-failable call inside its held lock). An empty <known-status> is
# what handoff passes when that earlier read itself failed, and is always
# treated as a failure here too, exactly like a self-read finding nothing.
#
# Sets FM_DASHBOARD_LINK_FAILED: 0 once ref, agent, and (when applicable) the
# status advance have all gone through; 1 on any single failure. This
# function's own return is always 0 - never failing the caller's already-live
# or already-landed work is a hard invariant - so FM_DASHBOARD_LINK_FAILED is
# the only way to tell confirmed from merely-attempted. Callers decide their
# own audit-log policy on that signal: fm-spawn.sh records every failure,
# while fm-backlog-handoff.sh caps its record at one per invocation and skips
# it entirely under --resume-pending, since that path runs unattended on every
# session start and must not grow the fleet discrepancy log on a cadence no
# operator controls.
fm_dashboard_link_and_advance() { # <dash> <card> <ref> <owner> <subject> <known-status|@self-read>
  local dash=$1 card=$2 ref=$3 owner=$4 subject=$5 known_status=$6
  local failed=0 out current_status
  FM_DASHBOARD_LINK_FAILED=0

  if out=$("$dash" ref "$card" "$ref" 2>&1); then
    :
  else
    failed=1
    echo "warning: dashboard card link failed for $subject -> card $card (ref): $out" >&2
  fi

  if out=$("$dash" agent "$card" "$owner" 2>&1); then
    :
  else
    failed=1
    echo "warning: dashboard card link failed for $subject -> card $card (agent): $out" >&2
  fi

  if [ "$failed" -eq 0 ]; then
    if [ "$known_status" = "$FM_DASHBOARD_LINK_SELF_READ" ]; then
      current_status=$("$dash" show "$card" --json 2>/dev/null | jq -r '.status // empty' 2>/dev/null) || current_status=
    else
      current_status=$known_status
    fi
    if [ -z "$current_status" ]; then
      failed=1
      echo "warning: dashboard card link failed for $subject -> card $card (status): the board did not answer when this card was read, so it cannot be confirmed past not_started" >&2
    elif [ "$current_status" = not_started ]; then
      if out=$("$dash" status "$card" working 2>&1); then
        echo "dashboard: linked card $card to $subject (ref=$ref, agent=$owner, status not_started -> working)"
      else
        failed=1
        echo "warning: dashboard card link failed for $subject -> card $card (status working): $out" >&2
      fi
    else
      echo "dashboard: linked card $card to $subject (ref=$ref, agent=$owner)"
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-spawn.sh, fm-backlog-handoff.sh) after sourcing.
  FM_DASHBOARD_LINK_FAILED=$failed
  return 0
}

# fm_dashboard_advance_after_landing consumes an identity a spawn or handoff
# already established and advances the card onward now that the work it names
# has actually landed - bin/fm-teardown.sh's own half of the mechanical link.
# Unlike fm_dashboard_link_and_advance above, it never writes ref or agent
# (that identity was set at dispatch, not at completion) and its transition
# rule is the opposite shape: advance from anywhere except a status the
# Admiral's own action made terminal, rather than only from one specific
# starting status. An already-complete card is left alone rather than
# downgraded back - his approval is terminal until he reopens it from the
# card - and the same is now true of a card the Admiral's own action left
# needs_attention: the underlying work landing does not answer whatever he was
# actually asked, so the card still advances (freezing it forever would be its
# own new stale-card failure), but its needs_attention_reason is about to be
# discarded by the status change itself (store.py's set_status keeps that
# column only while status stays needs_attention) - carrying it forward as
# this call's own --reason keeps it in the card's status history instead of
# silently nulling it with no trace, which is the specific defect this
# function exists to close.
#
# Every dashboard call is guarded exactly like fm_dashboard_link_and_advance:
# a missing card, an unreachable dashboard, or any other failure only warns on
# stderr and best-effort records `fm-dashboard.sh audit-log --fleet` via the
# caller-supplied <audit-message> - it never turns cleanup that has already
# succeeded into a reported failure.
fm_dashboard_advance_after_landing() { # <dash> <card> <subject> <target-status> <audit-message>
  local dash=$1 card=$2 subject=$3 target=$4 audit_msg=$5
  local shown current_status held_reason out reason_args

  shown=$("$dash" show "$card" --json 2>/dev/null) || shown=
  current_status=$(printf '%s' "$shown" | jq -r '.status // empty' 2>/dev/null) || current_status=
  if [ -z "$current_status" ]; then
    echo "warning: dashboard card advance failed for $subject -> card $card (show): the board did not answer when this card was read" >&2
    "$dash" audit-log --fleet "$audit_msg" --kind error >/dev/null 2>&1 || true
    return 0
  fi

  [ "$current_status" != complete ] || return 0

  held_reason=
  if [ "$current_status" = needs_attention ]; then
    held_reason=$(printf '%s' "$shown" | jq -r '.needs_attention_reason // empty' 2>/dev/null) || held_reason=
  fi
  reason_args=()
  [ -z "$held_reason" ] || reason_args=(--reason "$held_reason")

  if out=$("$dash" status "$card" "$target" "${reason_args[@]+"${reason_args[@]}"}" 2>&1); then
    echo "dashboard: advanced card $card to $target for $subject"
  else
    echo "warning: dashboard card advance failed for $subject -> card $card (status $target): $out" >&2
    "$dash" audit-log --fleet "$audit_msg" --kind error >/dev/null 2>&1 || true
  fi
  return 0
}
