#!/usr/bin/env bash
# fm-dashboard.sh - the ONLY way an agent touches the Admiral's Fleet Dashboard.
#
# The dashboard is a purpose-built task board, not a mirror of any backlog:
# it owns its own persistent records (bin/fleet-dashboard/server/store.py),
# and every card exists only because something explicitly put it there
# through this CLI (or the equivalent HTTP call). Agents must never edit
# bin/fleet-dashboard/web/ or the database directly - see
# .agents/skills/fleet-dashboard/SKILL.md and docs/dashboard.md.
#
# Every subcommand below is exactly one call, on purpose: a command that
# needs three round-trips to record one update gets skipped by an agent
# under time pressure, and the board rots.
#
# Usage:
#   fm-dashboard.sh add --title <t> --captain <captain> \
#       (--prompt <text> | --prompt-file <path>) [--agent <name>] \
#       [--status <status>] [--ref <backlog-ref>] [--reason <text>] \
#       [--plan <text>]
#       --reason is REQUIRED when --status is needs-action (same rule and
#       same server-side guard as the `status` subcommand below), and is
#       REFUSED for every other starting status. Only `waiting` and
#       `needs-action` store a reason on the card at all; for `waiting`
#       the `status` subcommand owns it, and for the rest a reason is not
#       stored anywhere `show` will render it.
#       --plan is REQUIRED when --status is needs-review, and REFUSED for
#       every other starting status: it is the short recommended action the
#       card's approval box asks him to approve.
#   fm-dashboard.sh list [--status <status>] [--captain <c>] [--starred] \
#       [--sort updated|date|status|title] [--json]
#   fm-dashboard.sh show <id> [--json]
#   fm-dashboard.sh title <id> <new title>
#   fm-dashboard.sh agent <id> <agent name>
#   fm-dashboard.sh captain <id> <captain>
#   fm-dashboard.sh captains                          (the valid captains)
#   fm-dashboard.sh ref <id> <backlog-ref>
#   fm-dashboard.sh status <id> <status> [--waiting-on <id>] [--reason <text>] \
#       [--plan <text>]
#       --reason is what the card is waiting on for `waiting`, or what is
#       being asked of him for `needs-action`. For every other status it
#       is not stored on the card at all, only as that transition's
#       status-history note - not ignored, and load-bearing:
#       bin/fm-dashboard-link-lib.sh's advance-on-landing passes a held
#       reason back this way so the status change does not destroy it (see
#       docs/dashboard.md "The mechanical card link").
#       needs-action REQUIRES --reason: the server refuses the status
#       change with no reason, and refuses a reason it can mechanically
#       tell is only a progress report rather than an ask (see
#       bin/fleet-dashboard/server/validation.py's REPORT_SHAPED_PHRASES).
#       needs-review REQUIRES a recommended plan, either passed here as
#       --plan or already on the card from an earlier `plan` call; the
#       server refuses the status change when neither exists, because an
#       approval box with nothing in it is the failure that status exists
#       to prevent. --plan is REFUSED for every other status, exactly as
#       `add` refuses it: needs-review is the only status that puts an
#       approval box in front of him, so a plan written anywhere else is a
#       recommendation he has no way to accept.
#   fm-dashboard.sh plan <id> <recommended plan text>
#       Correct the recommended plan a needs-review card asks him to approve.
#       This command corrects a plan; it never creates the first one. The
#       server refuses a plan on a card that has never been needs-review and
#       carries none, because only the move to needs-review puts the approval
#       box in front of him - so the first plan is always written by
#       `status <id> needs-review --plan "..."` (or `add --status
#       needs-review --plan "..."`). A card that reached needs-review and has
#       since moved on still takes a correction, since its plan and his
#       approval deliberately outlive that status.
#       If he had already approved the previous wording, that
#       approval is KEPT as the durable record of his word but is no longer
#       treated as covering the new text: `show` and --json report it as
#       stale, the card shows both, and the approve button comes back.
#       There is deliberately no `approve` subcommand here. Approval is his
#       word, so it is recorded only where he himself gives it - the board's
#       own approve button - and never by an agent on his behalf.
#   fm-dashboard.sh star <id>
#   fm-dashboard.sh unstar <id>
#   fm-dashboard.sh note <id> --tab <interpretation|communication|needs> \
#       [--text <text>] [--link <url>] [--link-label <text>] [--author <a>]
#   fm-dashboard.sh link <id> --url <url> [--label <text>] [--tab <tab>]
#   fm-dashboard.sh delete <id> --confirm
#   fm-dashboard.sh audit-log (<id> | --fleet) <text> [--kind discrepancy|error] \
#       [--key <key>]
#       --key collapses a recurring identical finding into its existing row
#       (bumping its last-seen time and a seen-count) instead of appending a
#       new one every time it recurs, so a persistent condition never buries
#       every other finding under repeats of itself. It is a fingerprint for
#       the *condition*, not the wording: pass the same key every time a
#       given check re-detects the same standing problem on the same card,
#       even as `<text>` itself changes (an elapsed age, a different observed
#       state) - and a different key for every other kind of finding, so one
#       check's repeats can never collapse onto, or be mistaken for, another
#       check's finding on that same card. Omit it and every call inserts a
#       new row, the pre-existing behavior. See docs/dashboard.md "Auditor
#       integration" for the full contract, including why the caller must
#       still count a collapsed-but-outstanding finding on every run.
#   fm-dashboard.sh audit-run --duration-seconds <n> --checked <n> \
#       [--discrepancies <n>] [--forced] [--started-at <iso>]
#   fm-dashboard.sh audit-interval [get | <minutes>]
#   fm-dashboard.sh audit-status [--json]
#   fm-dashboard.sh audit-tick
#   fm-dashboard.sh audit-claim [--forced] [--json]
#   fm-dashboard.sh audit-release
#   fm-dashboard.sh start|stop|restart|server-status   (server process lifecycle)
#       `start`'s bind host defaults to $FM_DASHBOARD_HOST when set, else the
#       host already recorded in config/dashboard-url, else 127.0.0.1 - so a
#       plain restart keeps whatever address was reachable before rather than
#       reverting to localhost-only (the port still comes from
#       $FM_DASHBOARD_PORT, default 8420). `start` refuses up front, leaving
#       no pidfile, when something the pidfile does not track already answers
#       at http://<host>:<port>/api/health; otherwise it refuses to report
#       success until the API actually answers on that address (polling for
#       up to $FM_DASHBOARD_MAX_TIME seconds, default 20), stopping the
#       process and dying loudly instead of leaving a pane he cannot reach.
#   fm-dashboard.sh install-boot                       (start at host boot)
#   fm-dashboard.sh uninstall-boot
#   fm-dashboard.sh serve-foreground                   (what the boot unit runs)
#   fm-dashboard.sh --help
#
# Surviving a host reboot: `install-boot` writes and enables a systemd USER
# unit, $HOME/.config/systemd/user/fm-dashboard.service (override the directory
# with $FM_DASHBOARD_UNIT_DIR), that runs `serve-foreground` - the same server
# in the foreground, resolving host, port and database exactly the way `start`
# does. It pins ExecStart to $FM_HOME/bin/fm-dashboard.sh, the tracked root of
# the home being installed, never to whatever checkout the command was run
# from, and records the resolved FM_HOME, host, port and database as unit
# `Environment=` lines so the unit binds the address that was reachable at
# install time. It refuses when that $FM_HOME is itself a linked git worktree
# (its .git is a pointer file rather than the repository), since a unit pinned
# to a task worktree dies with it, and names the primary checkout to pass as
# FM_HOME instead; a home that is not a git checkout is unaffected. It also
# runs `loginctl enable-linger` so the unit comes up at
# boot with nobody logged in, and prints the exact command to run by hand when
# that needs privileges it does not have. `uninstall-boot` stops, disables and
# removes the unit; it deliberately leaves lingering alone, since other user
# units on the host depend on it.
#
# Once that unit exists FOR THIS $FM_HOME, it owns the lifecycle: `start`,
# `stop` and `restart` act on the unit through `systemctl --user` instead of
# the pidfile, `start` refuses rather than racing a server the unit already has
# running, and `server-status` reports the unit's state instead of "no pid
# recorded". A server hand-started before the unit existed is still tracked by
# its pidfile: `server-status` says so, and `stop` and `restart` retire it as
# well, so `restart` is the whole handover. Every one of those commands behaves
# exactly as it always did on a home with no unit installed, or when the
# installed unit names a different FM_HOME.
#
# The audit-tick/audit-claim/audit-release/audit-status quartet is the fleet
# auditor's own timer plumbing (bin/fm-fleet-audit-tick.sh and
# bin/fm-fleet-audit-sweep.sh are the actual timer and sweep executor); an
# agent doing ordinary dashboard work never needs them directly.
#
# statuses: needs-action needs-review not-started working paused waiting
#           testing review complete
#           needs-attention is still ACCEPTED as an input spelling and means
#           needs-action, so an older script keeps working; it is never
#           emitted. needs-review (the fleet proposes, he approves) and
#           review (done, nothing left for him but to look) are different
#           statuses - see .agents/skills/fleet-dashboard/SKILL.md.
# tabs:     interpretation communication needs
# captains: `fm-dashboard.sh captains` lists them, ids and shorthands both.
#           They are defined once, in bin/fleet-dashboard/web/captains.json,
#           which the server and the page read too - add one there and it is
#           live everywhere. Nothing else in this repo lists them.
#
# Server URL resolution: $FM_DASHBOARD_URL env var, else the first line of
# $FM_HOME/config/dashboard-url, else http://127.0.0.1:8420. A secondmate on
# a different host points config/dashboard-url at the primary's tailnet
# address (see docs/dashboard.md "Reaching the board from a secondmate").
#
# Every call is bounded: --connect-timeout 5s and --max-time 20s, overridable
# with $FM_DASHBOARD_CONNECT_TIMEOUT / $FM_DASHBOARD_MAX_TIME (positive
# seconds; anything else is ignored loudly and the default used).
# Exit codes: 0 success, 4 the board answered and said the id does not exist,
# 1 anything else (unreachable board, refused write, bad usage).
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DASHBOARD_DIR="$FM_ROOT/bin/fleet-dashboard"

# Precedence: FM_DASHBOARD_URL (full override) > FM_DASHBOARD_HOST/_PORT (the
# same pair `start` launches the server with) > config/dashboard-url > default.
dash_url() {
  if [ -n "${FM_DASHBOARD_URL:-}" ]; then
    printf '%s\n' "$FM_DASHBOARD_URL"
    return 0
  fi
  if [ -n "${FM_DASHBOARD_HOST:-}${FM_DASHBOARD_PORT:-}" ]; then
    printf 'http://%s:%s\n' "${FM_DASHBOARD_HOST:-127.0.0.1}" "${FM_DASHBOARD_PORT:-8420}"
    return 0
  fi
  if [ -f "$CONFIG/dashboard-url" ]; then
    head -n1 "$CONFIG/dashboard-url"
    return 0
  fi
  printf '%s\n' "http://127.0.0.1:8420"
}

# `start`'s bind-host default. A plain restart with no env vars used to bind
# 127.0.0.1 unconditionally, which is exactly the address his phone cannot
# reach (see docs/dashboard.md "What has to be running") - so when
# $FM_DASHBOARD_HOST is unset, keep listening on the host already recorded in
# config/dashboard-url, the same file `dash_url` above falls back to for API
# calls, instead of reverting to localhost-only.
dashboard_default_host() {
  local recorded
  if [ -f "$CONFIG/dashboard-url" ]; then
    recorded=$(head -n1 "$CONFIG/dashboard-url")
    recorded=${recorded#*://}
    recorded=${recorded%%/*}
    recorded=${recorded%%:*}
    [ -n "$recorded" ] && { printf '%s' "$recorded"; return 0; }
  fi
  printf '127.0.0.1'
}

# The one resolution of what the server binds and reads. `start` launches with
# these, `serve-foreground` (what the boot unit runs) execs with these, and
# `install-boot` records their resolved values in the unit, so a board brought
# up at boot lands on exactly the address a hand `start` would have chosen.
dashboard_bind_host() { printf '%s' "${FM_DASHBOARD_HOST:-$(dashboard_default_host)}"; }
dashboard_bind_port() { printf '%s' "${FM_DASHBOARD_PORT:-8420}"; }
dashboard_db_path()   { printf '%s' "${FM_DASHBOARD_DB:-$FM_HOME/data/dashboard.db}"; }

die() { printf 'fm-dashboard.sh: %s\n' "$1" >&2; exit 1; }

need_tool() { command -v "$1" >/dev/null 2>&1 || die "requires '$1' on PATH"; }

# Exit code reserved for "the board answered, and says this id does not
# exist". Callers that must tell a definitive board rejection from a board
# they simply could not reach - bin/fm-backlog-handoff.sh's pending card
# record, which retries the second forever and must never retry the first -
# key off this instead of parsing the stderr message.
DASH_EXIT_NOT_FOUND=4

# Bound every call. The board is typically a tailnet host that can simply be
# powered off, dropping packets rather than refusing them, and these calls run
# inside held handoff locks (bin/fm-backlog-handoff.sh) and on
# bin/fm-bootstrap.sh's synchronous path, where an unbounded wait stalls the
# whole fleet rather than one card. A non-numeric override is ignored loudly
# rather than passed to curl, which would reject it and turn a bad env var
# into "the board is unreachable". A non-positive one is ignored just as
# loudly for the opposite reason: curl accepts --max-time 0 and
# --connect-timeout 0 and reads them as no timeout at all, so honouring a zero
# would silently restore exactly the unbounded wait these bounds exist to
# remove. Zero is spelled as "no [1-9] anywhere in an otherwise valid decimal",
# which catches 0, 0.0 and .0 alike; a negative value carries a '-' and is
# already non-numeric here.
dash_timeout_seconds() { # <env-name> <raw-value> <default>
  local name=$1 raw=$2 default=$3
  case "$raw" in
    '') printf '%s' "$default"; return 0 ;;
    .|*.*.*|*[!0-9.]*) : ;;
    *[1-9]*) printf '%s' "$raw"; return 0 ;;
  esac
  printf 'fm-dashboard.sh: ignoring invalid %s=%s (want positive seconds); using %s\n' "$name" "$raw" "$default" >&2
  printf '%s' "$default"
}

# dash_call METHOD PATH [JSON_BODY] - prints response body on stdout,
# prints an error message on stderr and returns non-zero on failure
# ($DASH_EXIT_NOT_FOUND for a 404, 1 otherwise). Never exits the process
# directly: a caller (cmd_server_status in particular) needs to catch
# "server unreachable" instead of the whole script dying.
dash_call() {
  local method=$1 path=$2 body=${3:-} base resp code out
  local -a bounds
  need_tool curl
  need_tool jq
  base=$(dash_url)
  bounds=(
    --connect-timeout "$(dash_timeout_seconds FM_DASHBOARD_CONNECT_TIMEOUT "${FM_DASHBOARD_CONNECT_TIMEOUT:-}" 5)"
    --max-time "$(dash_timeout_seconds FM_DASHBOARD_MAX_TIME "${FM_DASHBOARD_MAX_TIME:-}" 20)"
  )
  if [ -n "$body" ]; then
    resp=$(curl -sS "${bounds[@]}" -w '\n%{http_code}' -X "$method" "$base$path" \
      -H 'Content-Type: application/json' -d "$body" 2>&1) || {
      printf 'fm-dashboard.sh: could not reach dashboard at %s (is it running? see: fm-dashboard.sh start / server-status): %s\n' "$base" "$resp" >&2
      return 1
    }
  else
    resp=$(curl -sS "${bounds[@]}" -w '\n%{http_code}' -X "$method" "$base$path" 2>&1) || {
      printf 'fm-dashboard.sh: could not reach dashboard at %s (is it running? see: fm-dashboard.sh start / server-status): %s\n' "$base" "$resp" >&2
      return 1
    }
  fi
  code=$(printf '%s' "$resp" | tail -n1)
  out=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" -ge 400 ] 2>/dev/null; then
    printf 'fm-dashboard.sh: server refused (%s): %s\n' "$code" "$(printf '%s' "$out" | jq -r '.error // .' 2>/dev/null || printf '%s' "$out")" >&2
    [ "$code" != 404 ] || return "$DASH_EXIT_NOT_FOUND"
    return 1
  fi
  printf '%s' "$out"
}

json_escape() { need_tool jq; jq -Rs . <<<"$1"; }

# needs-attention is a deprecated INPUT alias for needs-action, accepted in
# both spellings so an older script, or an agent working from the pre-split
# doctrine, keeps working rather than failing on a status the board renamed
# under it. It is never printed back: this function's output is always the
# canonical stored spelling.
canon_status() {
  case "$1" in
    not-started|not_started) printf 'not_started' ;;
    needs-action|needs_action) printf 'needs_action' ;;
    needs-review|needs_review) printf 'needs_review' ;;
    needs-attention|needs_attention) printf 'needs_action' ;;
    working|paused|waiting|testing|review|complete) printf '%s' "$1" ;;
    *) die "unknown status '$1' - valid: needs-action needs-review not-started working paused waiting testing review complete" ;;
  esac
}

CAPTAINS_MANIFEST="$SCRIPT_DIR/fleet-dashboard/web/captains.json"

captain_ids() {
  # Ids and shorthands from the one manifest the server and the page also read.
  need_tool jq
  [ -f "$CAPTAINS_MANIFEST" ] || die "captain manifest missing: $CAPTAINS_MANIFEST"
  jq -er '.captains[] | "\(.id)\t\(.short)\t\(.label)"' "$CAPTAINS_MANIFEST" \
    || die "captain manifest unreadable: $CAPTAINS_MANIFEST"
}

captain_names() { captain_ids | cut -f2 | paste -sd' ' -; }

canon_captain() {
  # Accepts an id or its shorthand; anything else refuses rather than guessing.
  local want=$1 rows id short
  rows=$(captain_ids) || return 1
  while IFS=$'\t' read -r id short _; do
    if [ "$want" = "$id" ] || [ "$want" = "$short" ]; then
      printf '%s' "$id"
      return 0
    fi
  done <<<"$rows"
  die "unknown captain '$want' - valid: $(printf '%s' "$rows" | cut -f2 | paste -sd' ' -)"
}

cmd_captains() {
  printf '%-16s %-10s %s\n' "ID" "SHORTHAND" "LABEL"
  captain_ids | while IFS=$'\t' read -r id short label; do
    printf '%-16s %-10s %s\n' "$id" "$short" "$label"
  done
}

row_line() {
  # one-line confirmation row from a task JSON object on stdin
  jq -r '[.id, .status, .captain, (if .starred==1 then "*" else "-" end), .title] | @tsv'
}

cmd_add() {
  local title="" captain="" prompt="" prompt_file="" agent="" status="not_started" ref="" reason="" plan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=$2; shift 2 ;;
      --captain) captain=$(canon_captain "$2") || return 1; shift 2 ;;
      --prompt) prompt=$2; shift 2 ;;
      --prompt-file) prompt_file=$2; shift 2 ;;
      --agent) agent=$2; shift 2 ;;
      --status) status=$(canon_status "$2") || return 1; shift 2 ;;
      --ref) ref=$2; shift 2 ;;
      --reason) reason=$2; shift 2 ;;
      --plan) plan=$2; shift 2 ;;
      *) die "add: unknown argument '$1'" ;;
    esac
  done
  [ -n "$title" ] || die "add: --title is required"
  [ -n "$captain" ] || die "add: --captain is required - one of: $(captain_names)"
  if [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] || die "add: --prompt-file '$prompt_file' not found"
    prompt=$(cat "$prompt_file")
  fi
  [ -n "$prompt" ] || die "add: --prompt or --prompt-file is required - his own words, verbatim"
  # See cmd_status's matching checks: the server enforces both of these too,
  # but fail here rather than spend a round-trip on the obvious case.
  if [ "$status" = needs_action ] && [ -z "$reason" ]; then
    die "add: --status needs-action requires --reason - say what he needs to decide, approve, or supply"
  fi
  if [ "$status" = needs_review ] && [ -z "$plan" ]; then
    die "add: --status needs-review requires --plan - the short recommended action he is being asked to approve"
  fi
  # needs_action is the only status whose reason `add` can write. Refuse
  # rather than send a value the server will drop on the floor - and only
  # point at the `status` subcommand for a status that actually persists a
  # reason there, since for the rest that command drops it just as quietly.
  if [ "$status" != needs_action ] && [ -n "$reason" ]; then
    local why
    case "$status" in
      waiting)
        why="use 'fm-dashboard.sh status <id> $status --reason ...' instead" ;;
      needs_review)
        why="a needs-review card carries a --plan, not a --reason" ;;
      *)
        why="a reason is not stored for '$status' - drop --reason or use --status needs-action" ;;
    esac
    die "add: --reason is only accepted with --status needs-action (got status '$status'); $why"
  fi
  # Same rule for the plan, and for the same reason: only needs_review stores
  # one, so anywhere else it would be accepted and then silently dropped.
  if [ "$status" != needs_review ] && [ -n "$plan" ]; then
    die "add: --plan is only accepted with --status needs-review (got status '$status'); a recommended plan is what a needs-review card's approval box shows him"
  fi
  local body
  body=$(jq -n --arg t "$title" --arg c "$captain" --arg p "$prompt" --arg a "$agent" \
              --arg s "$status" --arg r "$ref" --arg rs "$reason" --arg pl "$plan" \
    '{title:$t, captain:$c, initial_prompt:$p, agent:$a, status:$s}
     + (if $r=="" then {} else {backlog_ref:$r} end)
     + (if $rs=="" then {} else {reason:$rs} end)
     + (if $pl=="" then {} else {plan:$pl} end)')
  dash_call POST /api/tasks "$body" | row_line
}

cmd_list() {
  local status="" captain="" starred="" sort="updated" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status=$(canon_status "$2") || return 1; shift 2 ;;
      --captain) captain=$(canon_captain "$2") || return 1; shift 2 ;;
      --starred) starred=1; shift ;;
      --sort) sort=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      *) die "list: unknown argument '$1'" ;;
    esac
  done
  local qs="?sort=$sort"
  [ -n "$status" ] && qs="$qs&status=$status"
  [ -n "$captain" ] && qs="$qs&captain=$captain"
  [ -n "$starred" ] && qs="$qs&starred=true"
  local out
  out=$(dash_call GET "/api/tasks$qs") || return 1
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '.tasks[] | [.id, .status, .captain, (if .starred==1 then "*" else "-" end), .title] | @tsv'
  fi
}

cmd_show() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "show: task id required"
  local as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) as_json=1; shift ;; *) die "show: unknown argument '$1'" ;; esac
  done
  local out
  out=$(dash_call GET "/api/tasks/$id") || return $?
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out" | jq -r '
    "id:       \(.id)",
    "title:    \(.title)",
    "status:   \(.status)",
    "captain:  \(.captain)",
    "agent:    \(.agent)",
    "starred:  \(.starred == 1)",
    (if .status == "waiting" then "waiting on: \(.waiting_on_id // "(no card)") - \(.waiting_reason // "")" else empty end),
    (if .status == "needs_action" then "needs action: \(.needs_action_reason // "(no reason recorded)")" else empty end),
    (if .review_plan then "recommended plan: \(.review_plan)" else empty end),
    (if .plan_approved then
       (if .plan_approval_stale then
          "APPROVAL: he approved at \(.plan_approved_at), but the plan has been edited since - that approval covers the OLD wording only, not the plan above",
          "approved wording: \(.plan_approved_text)"
        else
          "APPROVAL: he approved this exact plan at \(.plan_approved_at)"
        end)
     else empty end),
    (if .backlog_ref then "ref:      \(.backlog_ref)" else empty end),
    "",
    "--- prompt ---",
    .initial_prompt,
    "",
    (if ([.notes[] | select(.tab=="interpretation")] | length) > 0
      then "--- interpretation ---", (.notes[] | select(.tab=="interpretation") | "[\(.author) \(.created_at)] \(.text)\(if .link_url then " -> " + .link_url else "" end)")
      else empty end),
    (if ([.notes[] | select(.tab=="communication")] | length) > 0
      then "--- communication ---", (.notes[] | select(.tab=="communication") | "[\(.author) \(.created_at)] \(.text)\(if .link_url then " -> " + .link_url else "" end)")
      else empty end),
    (if ([.notes[] | select(.tab=="needs")] | length) > 0
      then "--- needs ---", (.notes[] | select(.tab=="needs") | "[\(.author) \(.created_at)] \(.text)\(if .link_url then " -> " + .link_url else "" end)")
      else empty end)
  '
}

cmd_title() {
  local id=${1:-} title=${2:-}
  [ -n "$id" ] && [ -n "$title" ] || die "title: usage: title <id> <new title>"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg t "$title" '{title:$t}')" | row_line
}

cmd_agent() {
  local id=${1:-} agent=${2:-}
  [ -n "$id" ] || die "agent: usage: agent <id> <agent name>"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg a "${agent:-}" '{agent:$a}')" | row_line
}

cmd_captain() {
  local id=${1:-} captain=${2:-}
  [ -n "$id" ] && [ -n "$captain" ] || die "captain: usage: captain <id> <$(captain_names | tr ' ' '|')>"
  captain=$(canon_captain "$captain") || return 1
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg c "$captain" '{captain:$c}')" | row_line
}

cmd_ref() {
  local id=${1:-} ref=${2:-}
  [ -n "$id" ] && [ -n "$ref" ] || die "ref: usage: ref <id> <backlog-ref>"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg r "$ref" '{backlog_ref:$r}')" | row_line
}

cmd_status() {
  local id=${1:-}; shift || true
  local status=${1:-}; shift || true
  [ -n "$id" ] && [ -n "$status" ] || die "status: usage: status <id> <status> [--waiting-on <id>] [--reason <text>] [--plan <text>]"
  status=$(canon_status "$status") || return 1
  local waiting_on="" reason="" plan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --waiting-on) waiting_on=$2; shift 2 ;;
      --reason) reason=$2; shift 2 ;;
      --plan) plan=$2; shift 2 ;;
      *) die "status: unknown argument '$1'" ;;
    esac
  done
  # needs_action is the loudest status on the board and claims him; the
  # server also enforces this (and further refuses a report-shaped reason),
  # but fail here too rather than spend a round-trip on the obvious case.
  if [ "$status" = needs_action ] && [ -z "$reason" ]; then
    die "status: needs-action requires --reason - say what he needs to decide, approve, or supply"
  fi
  # needs_review is not checked locally the way needs_action is: the card may
  # already carry a plan from an earlier `plan` call, and only the server
  # holds the card. Sending it and letting the server refuse is what makes
  # "he already has a plan on this card" work without a second round-trip
  # here to go and look.
  # The other direction IS checked here, exactly as `add` checks it: a plan
  # only means anything on the status that renders the approval box, so
  # writing one anywhere else would put a recommendation in front of him with
  # no way to accept it - `show` would print "recommended plan:" on a working
  # card he was never actually asked about.
  if [ "$status" != needs_review ] && [ -n "$plan" ]; then
    die "status: --plan is only accepted with needs-review (got status '$status'); a recommended plan is what a needs-review card's approval box shows him"
  fi
  local body
  body=$(jq -n --arg s "$status" --arg w "$waiting_on" --arg r "$reason" --arg pl "$plan" \
    '{status:$s}
     + (if $w=="" then {} else {waiting_on_id:$w} end)
     + (if $r=="" then {} else {reason:$r} end)
     + (if $pl=="" then {} else {plan:$pl} end)')
  dash_call POST "/api/tasks/$id/status" "$body" | row_line
}

cmd_plan() {
  local id=${1:-} plan=${2:-}
  [ -n "$id" ] && [ -n "$plan" ] || die "plan: usage: plan <id> <recommended plan text>"
  # An unquoted multi-word plan would otherwise be recorded as its first word
  # alone, and his approval would then bind perfectly to that fragment - the
  # truncation invisible on both sides. Refuse instead of guessing at his
  # wording by joining what is left.
  [ $# -le 2 ] || die "plan: too many arguments - quote the plan text: plan <id> \"<recommended plan text>\""
  dash_call PUT "/api/tasks/$id/plan" "$(jq -n --arg p "$plan" '{plan:$p}')" | row_line
}

cmd_star_toggle() {
  local on=$1 id=${2:-}
  [ -n "$id" ] || die "star: task id required"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --argjson s "$on" '{starred:$s}')" | row_line
}

cmd_note() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "note: usage: note <id> --tab <tab> [--text <text>] [--link <url>] [--link-label <text>] [--author <a>]"
  local tab="" text="" link="" link_label="" author="agent"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tab) tab=$2; shift 2 ;;
      --text) text=$2; shift 2 ;;
      --link) link=$2; shift 2 ;;
      --link-label) link_label=$2; shift 2 ;;
      --author) author=$2; shift 2 ;;
      *) die "note: unknown argument '$1'" ;;
    esac
  done
  [ -n "$tab" ] || die "note: --tab is required (interpretation|communication|needs)"
  local body
  body=$(jq -n --arg tab "$tab" --arg author "$author" --arg text "$text" \
              --arg link "$link" --arg label "$link_label" \
    '{tab:$tab, author:$author, text:$text} + (if $link=="" then {} else {link_url:$link, link_label:$label} end)')
  dash_call POST "/api/tasks/$id/notes" "$body" >/dev/null && printf '%s: note added to %s\n' "$id" "$tab"
}

cmd_link() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "link: usage: link <id> --url <url> [--label <text>] [--tab <tab>]"
  local url="" label="" tab="needs"
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url=$2; shift 2 ;;
      --label) label=$2; shift 2 ;;
      --tab) tab=$2; shift 2 ;;
      *) die "link: unknown argument '$1'" ;;
    esac
  done
  [ -n "$url" ] || die "link: --url is required"
  cmd_note "$id" --tab "$tab" --text "" --link "$url" --link-label "$label"
}

cmd_delete() {
  local id=${1:-} confirm=${2:-}
  [ -n "$id" ] || die "delete: task id required"
  [ "$confirm" = "--confirm" ] || die "delete: pass --confirm to actually delete '$id'"
  dash_call DELETE "/api/tasks/$id" >/dev/null && printf 'deleted: %s\n' "$id"
}

cmd_audit_log() {
  local target=${1:-}; shift || true
  [ -n "$target" ] || die "audit-log: usage: audit-log (<id> | --fleet) <text> [--kind discrepancy|error] [--key <key>]"
  local text=${1:-}; shift || true
  [ -n "$text" ] || die "audit-log: text is required"
  local kind="discrepancy" key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind=$2; shift 2 ;;
      --key) key=$2; shift 2 ;;
      *) die "audit-log: unknown argument '$1'" ;;
    esac
  done
  local body
  if [ "$target" = "--fleet" ]; then
    body=$(jq -n --arg k "$kind" --arg t "$text" --arg key "$key" \
      '{kind:$k, text:$t} + (if $key=="" then {} else {key:$key} end)')
  else
    body=$(jq -n --arg k "$kind" --arg t "$text" --arg id "$target" --arg key "$key" \
      '{kind:$k, text:$t, task_id:$id} + (if $key=="" then {} else {key:$key} end)')
  fi
  local out
  out=$(dash_call POST /api/audit/log "$body") || return 1
  if [ "$(printf '%s' "$out" | jq -r '.collapsed // false')" = "true" ]; then
    printf 'audit finding recorded (%s, collapsed into existing row, occurrence #%s)\n' \
      "$kind" "$(printf '%s' "$out" | jq -r '.occurrences // "?"')"
  else
    printf 'audit finding recorded (%s)\n' "$kind"
  fi
}

cmd_audit_run() {
  local duration="" checked="" discrepancies="0" forced="false" started_at=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --duration-seconds) duration=$2; shift 2 ;;
      --checked) checked=$2; shift 2 ;;
      --discrepancies) discrepancies=$2; shift 2 ;;
      --forced) forced="true"; shift ;;
      --started-at) started_at=$2; shift 2 ;;
      *) die "audit-run: unknown argument '$1'" ;;
    esac
  done
  [ -n "$duration" ] && [ -n "$checked" ] || die "audit-run: --duration-seconds and --checked are required"
  local body
  body=$(jq -n --argjson d "$duration" --argjson c "$checked" --argjson x "$discrepancies" \
              --argjson f "$forced" --arg s "$started_at" \
    '{duration_seconds:$d, tasks_checked:$c, discrepancies_found:$x, forced:$f} + (if $s=="" then {} else {started_at:$s} end)')
  dash_call POST /api/audit/run "$body" >/dev/null \
    && printf 'audit run recorded: %ss, %s task(s), %s discrepancy(ies)%s\n' \
         "$duration" "$checked" "$discrepancies" "$([ "$forced" = "true" ] && printf ' (forced)' || true)"
}

cmd_audit_interval() {
  local arg=${1:-get}
  if [ "$arg" = "get" ]; then
    dash_call GET /api/settings/audit-interval | jq -r '"every \(.minutes) minute(s)"'
  else
    case "$arg" in ''|*[!0-9]*) die "audit-interval: minutes must be a positive integer" ;; esac
    dash_call PUT /api/settings/audit-interval "$(jq -n --argjson m "$arg" '{minutes:$m}')" \
      | jq -r '"every \(.minutes) minute(s)"'
  fi
}

cmd_audit_status() {
  local as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) as_json=1; shift ;; *) die "audit-status: unknown argument '$1'" ;; esac
  done
  local out
  out=$(dash_call GET /api/audit/status) || return 1
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out" | jq -r '
    "interval_minutes: \(.interval_minutes)",
    "last_tick_at:     \(.last_tick_at // "never")",
    "sweep running:    \(.sweep_lock.running)\(if .sweep_lock.running then " (forced: \(.sweep_lock.forced), since \(.sweep_lock.started_at))" else "" end)",
    (if .last_run then
      "last_run:         \(.last_run.completed_at) - \(.last_run.duration_seconds)s, \(.last_run.tasks_checked) checked, \(.last_run.discrepancies_found) discrepancy(ies)\(if .last_run.forced==1 then " (forced)" else "" end)"
    else
      "last_run:         never"
    end)
  '
}

cmd_audit_tick() {
  dash_call POST /api/audit/tick >/dev/null && printf 'tick recorded\n'
}

cmd_audit_claim() {
  local forced="false" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --forced) forced="true"; shift ;;
      --json) as_json=1; shift ;;
      *) die "audit-claim: unknown argument '$1'" ;;
    esac
  done
  local out
  out=$(dash_call POST /api/audit/claim "$(jq -n --argjson f "$forced" '{forced:$f}')") || return 1
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r 'if .claimed then "claimed: true started_at: \(.started_at)" else "claimed: false running_since: \(.running_since) forced: \(.forced)" end'
  fi
  printf '%s' "$out" | jq -e '.claimed' >/dev/null
}

cmd_audit_release() {
  dash_call POST /api/audit/release >/dev/null && printf 'sweep lock released\n'
}

# One bounded health request. Echoes the HTTP status code, or nothing when the
# address did not answer at all; never fails, so callers read the code.
dashboard_probe_health() {  # <health-url> <connect-timeout> <attempt-max>
  # curl still writes its %{http_code} placeholder ("000") on a failed request,
  # so the exit status - not the output - is what says nothing answered.
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$2" --max-time "$3" "$1" 2>/dev/null) || code=""
  printf '%s' "$code"
}

# --- the systemd user unit that survives a host reboot ----------------------
#
# Installed by `install-boot`; see this script's header for the contract. The
# unit records the FM_HOME it manages, and every lifecycle command below routes
# through systemctl only for a unit that names THIS home - so a secondmate home
# sharing a host with the primary's installed unit keeps the pidfile lifecycle
# it has always had.
DASHBOARD_UNIT=fm-dashboard.service

dashboard_unit_dir() { printf '%s' "${FM_DASHBOARD_UNIT_DIR:-${HOME:-/nonexistent}/.config/systemd/user}"; }
dashboard_unit_path() { printf '%s/%s' "$(dashboard_unit_dir)" "$DASHBOARD_UNIT"; }

dashboard_unit_quote() {  # <value> -> the value as a double-quoted unit-file word
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//%/%%}
  printf '"%s"' "$v"
}

dashboard_unit_unquote() {  # <quoted word> -> the value dashboard_unit_quote was given
  local v=$1
  v=${v#\"}; v=${v%\"}
  v=${v//%%/%}
  v=${v//\\\"/\"}
  v=${v//\\\\/\\}
  printf '%s' "$v"
}

dashboard_unit_home() {
  local path raw; path=$(dashboard_unit_path)
  [ -f "$path" ] || return 1
  raw=$(sed -n 's/^Environment="FM_HOME=\(.*\)"$/\1/p' "$path" | head -n1)
  [ -n "$raw" ] || return 0
  dashboard_unit_unquote "\"$raw\""
}

dashboard_home_key() {  # <dir> -> its physical path, or the spelling given when it cannot be entered
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

dashboard_same_home() {  # <a> <b>
  [ -n "$1" ] && [ -n "$2" ] && [ "$(dashboard_home_key "$1")" = "$(dashboard_home_key "$2")" ]
}

dashboard_unit_manages_this_home() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local home; home=$(dashboard_unit_home) || return 1
  dashboard_same_home "$home" "$FM_HOME"
}

dashboard_primary_checkout() {  # <linked worktree> -> the checkout whose .git it links into
  local gitdir; gitdir=$(sed -n 's/^gitdir: //p' "$1/.git" | head -n1)
  [ -n "$gitdir" ] || return 1
  case "$gitdir" in /*) ;; *) gitdir="$1/$gitdir" ;; esac
  gitdir=${gitdir%/worktrees/*}
  case "$gitdir" in
    */.git) printf '%s' "${gitdir%/.git}" ;;
    *) return 1 ;;
  esac
}

dashboard_unit_active() { systemctl --user is-active --quiet "$DASHBOARD_UNIT" 2>/dev/null; }

# `is-active`/`is-enabled` exit non-zero for every state but the good one, and
# their words are the reportable answer either way.
dashboard_unit_state() { systemctl --user is-active "$DASHBOARD_UNIT" 2>/dev/null || true; }
dashboard_unit_enabled() { systemctl --user is-enabled "$DASHBOARD_UNIT" 2>/dev/null || true; }

dashboard_linger_enabled() {
  command -v loginctl >/dev/null 2>&1 || return 1
  loginctl show-user "${USER:-$(id -un)}" --property=Linger 2>/dev/null | grep -qx 'Linger=yes'
}

pidfile() { printf '%s/state/dashboard.pid' "$FM_HOME"; }

# A recorded pid only means "the board" if the process behind it is still the
# dashboard entrypoint: a crash leaves the pidfile behind, and the host's pid
# counter can hand that number to something unrelated before anyone runs
# stop/restart. Where ps cannot answer, fall back to trusting the pidfile
# rather than refusing to manage the board at all.
dashboard_pid_is_ours() {  # <pid>
  local pid=${1:-} cmd
  [ -n "$pid" ] || return 1
  command -v ps >/dev/null 2>&1 || return 0
  cmd=$(ps -ww -p "$pid" -o command= 2>/dev/null) \
    || cmd=$(ps -p "$pid" -o command= 2>/dev/null) \
    || return 0
  case "$cmd" in
    *fleet-dashboard/server/main.py*) return 0 ;;
    *) return 1 ;;
  esac
}

dashboard_server_running() {  # <pid>
  local pid=${1:-}
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  dashboard_pid_is_ours "$pid"
}

cmd_server_start() {
  need_tool curl
  if dashboard_unit_manages_this_home; then
    dashboard_unit_start
    return
  fi
  local pf; pf=$(pidfile)
  if [ -f "$pf" ] && dashboard_server_running "$(cat "$pf")"; then
    die "already running (pid $(cat "$pf")) - see: fm-dashboard.sh server-status"
  fi
  local host port db
  host=$(dashboard_bind_host); port=$(dashboard_bind_port); db=$(dashboard_db_path)
  local health="http://$host:$port/api/health" code=""
  local connect_timeout max_time attempt_max budget_whole deadline
  connect_timeout=$(dash_timeout_seconds FM_DASHBOARD_CONNECT_TIMEOUT "${FM_DASHBOARD_CONNECT_TIMEOUT:-}" 5)
  max_time=$(dash_timeout_seconds FM_DASHBOARD_MAX_TIME "${FM_DASHBOARD_MAX_TIME:-}" 20)
  # Each attempt is capped short so a socket that accepts but never answers
  # (a port the previous owner still holds) cannot eat the whole budget
  # before the loop notices the process has already died on it.
  attempt_max=$(awk -v m="$max_time" 'BEGIN { print (m < 2) ? m : 2 }')
  # Anything already answering on the address would answer the post-start
  # probe too, before the new interpreter has even reached its bind - and
  # that bind is going to fail. Refuse up front rather than report a healthy
  # start for a process that is dying on EADDRINUSE behind a stranger.
  code=$(dashboard_probe_health "$health" "$connect_timeout" "$attempt_max")
  if [ -n "$code" ]; then
    die "something already answers at $health (HTTP $code) that this pidfile does not track - refusing to start a second server on that address. See: fm-dashboard.sh server-status"
  fi
  mkdir -p "$(dirname "$pf")"
  nohup python3 "$DASHBOARD_DIR/server/main.py" --host "$host" --port "$port" --db "$db" \
    > "$FM_HOME/state/dashboard.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$pf"
  # A live process is not the same thing as an address his phone can reach:
  # prove the API actually answers on the address just bound rather than
  # reporting a healthy start he later finds unreachable. A refused
  # connection returns instantly, and a loaded host can take longer than a
  # second to reach the bind, so keep asking for the whole max-time budget
  # (giving up early only once the process itself is gone) before deciding
  # the address is unreachable.
  budget_whole=${max_time%%.*}
  deadline=$((SECONDS + 10#${budget_whole:-0} + 1))
  while kill -0 "$pid" 2>/dev/null; do
    code=$(dashboard_probe_health "$health" "$connect_timeout" "$attempt_max")
    case "$code" in 2??) break ;; esac
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 0.25
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pf"
    die "failed to start - see $FM_HOME/state/dashboard.log"
  fi
  case "$code" in
    2??) ;;
    *)
      local rc=0 left=""
      dashboard_server_terminate "$pid" || rc=$?
      if [ "$rc" -eq 1 ]; then
        left=" It also ignored SIGTERM and SIGKILL, so the pidfile is left for: fm-dashboard.sh stop."
      else
        rm -f "$pf"
      fi
      die "started (pid $pid) but $health did not answer within ${max_time}s - his phone could not have reached it; stopped it rather than reporting a healthy start.${left} See $FM_HOME/state/dashboard.log"
      ;;
  esac
  printf 'fleet dashboard started (pid %s) - http://%s:%s/  api reachable at %s  log: %s/state/dashboard.log\n' \
    "$pid" "$host" "$port" "$health" "$FM_HOME"
}

# Bringing up a unit-managed board is `systemctl --user start` - never a second
# process racing the unit for the same port. The refusals and the "prove the API
# answers before reporting success" contract are the pidfile path's, unchanged:
# an address he cannot reach is the failure either way.
dashboard_unit_start() {
  local host port health connect_timeout max_time attempt_max code budget_whole deadline
  host=$(dashboard_bind_host); port=$(dashboard_bind_port)
  health="http://$host:$port/api/health"
  connect_timeout=$(dash_timeout_seconds FM_DASHBOARD_CONNECT_TIMEOUT "${FM_DASHBOARD_CONNECT_TIMEOUT:-}" 5)
  max_time=$(dash_timeout_seconds FM_DASHBOARD_MAX_TIME "${FM_DASHBOARD_MAX_TIME:-}" 20)
  attempt_max=$(awk -v m="$max_time" 'BEGIN { print (m < 2) ? m : 2 }')
  if dashboard_unit_active; then
    die "already running under the systemd user unit $DASHBOARD_UNIT - see: fm-dashboard.sh server-status"
  fi
  code=$(dashboard_probe_health "$health" "$connect_timeout" "$attempt_max")
  if [ -n "$code" ]; then
    die "something already answers at $health (HTTP $code) that $DASHBOARD_UNIT does not manage - refusing to start a second server on that address. See: fm-dashboard.sh server-status"
  fi
  systemctl --user start "$DASHBOARD_UNIT" \
    || die "systemctl --user start $DASHBOARD_UNIT failed - see: journalctl --user -u $DASHBOARD_UNIT"
  budget_whole=${max_time%%.*}
  deadline=$((SECONDS + 10#${budget_whole:-0} + 1))
  while :; do
    code=$(dashboard_probe_health "$health" "$connect_timeout" "$attempt_max")
    case "$code" in 2??) break ;; esac
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 0.25
  done
  case "$code" in
    2??) ;;
    *) die "$DASHBOARD_UNIT started but $health did not answer within ${max_time}s - his phone could not have reached it. See: journalctl --user -u $DASHBOARD_UNIT" ;;
  esac
  printf 'fleet dashboard started by %s - http://%s:%s/  api reachable at %s\n' \
    "$DASHBOARD_UNIT" "$host" "$port" "$health"
}

# SIGTERM, then SIGKILL after ~10s of being ignored. Returns 0 when it exited
# on SIGTERM, 2 when SIGKILL was needed, 1 when it is still alive after ~15s
# and the port must be assumed held. Prints nothing; callers own the wording.
dashboard_server_terminate() {  # <pid>
  local pid=$1 waited=0 forced=false
  kill "$pid" 2>/dev/null
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -eq 200 ]; then kill -9 "$pid" 2>/dev/null; forced=true; fi
    [ "$waited" -gt 300 ] && return 1
    sleep 0.05
  done
  if $forced; then return 2; fi
  return 0
}

# `--if-running` is what `restart` passes: having nothing to stop is not a
# failure when the point of the command is to end up with a board running, but
# a stop that actually refused still has to say so on stderr and report it.
cmd_server_stop() {
  if dashboard_unit_manages_this_home; then
    dashboard_unit_stop "${1:-}"
    return
  fi
  dashboard_stop_pidfile_server "${1:-}"
}

# Stopping a unit-managed board also retires a server hand-started before the
# unit existed: that process holds the port the unit needs, so `restart` is the
# whole handover rather than a step in one.
dashboard_unit_stop() {
  local lenient=false stopped=false pf
  [ "${1:-}" = "--if-running" ] && lenient=true
  pf=$(pidfile)
  if [ -f "$pf" ]; then
    dashboard_server_running "$(cat "$pf")" && stopped=true
    dashboard_stop_pidfile_server --if-running || return 1
  fi
  if dashboard_unit_active; then
    systemctl --user stop "$DASHBOARD_UNIT" \
      || die "systemctl --user stop $DASHBOARD_UNIT failed - see: journalctl --user -u $DASHBOARD_UNIT"
    printf 'stopped (systemd user unit %s)\n' "$DASHBOARD_UNIT"
    stopped=true
  fi
  if ! $stopped; then
    $lenient && return 0
    die "$DASHBOARD_UNIT is not running (see: fm-dashboard.sh server-status)"
  fi
  return 0
}

dashboard_stop_pidfile_server() {
  local lenient=false
  [ "${1:-}" = "--if-running" ] && lenient=true
  local pf; pf=$(pidfile)
  if [ ! -f "$pf" ]; then
    if $lenient; then return 0; fi
    die "no pidfile - not started via this script (see: fm-dashboard.sh server-status)"
  fi
  local pid; pid=$(cat "$pf")
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pf"
    if $lenient; then return 0; fi
    die "recorded pid $pid is not running"
  fi
  if ! dashboard_pid_is_ours "$pid"; then
    rm -f "$pf"
    local not_ours="recorded pid $pid is not a fleet dashboard server - left it alone and dropped the stale pidfile"
    if $lenient; then printf 'fm-dashboard.sh: %s\n' "$not_ours" >&2; return 0; fi
    die "$not_ours"
  fi
  local rc=0 forced=false
  dashboard_server_terminate "$pid" || rc=$?
  if [ "$rc" -eq 1 ]; then
    local wedged="pid $pid did not exit - port still held, refusing to leave a stale pidfile"
    if $lenient; then printf 'fm-dashboard.sh: %s\n' "$wedged" >&2; return 1; fi
    die "$wedged"
  fi
  [ "$rc" -eq 2 ] && forced=true
  rm -f "$pf"
  if $forced; then
    printf 'stopped (pid %s - forced with SIGKILL after it ignored SIGTERM)\n' "$pid"
  else
    printf 'stopped (pid %s)\n' "$pid"
  fi
}

cmd_server_status() {
  local pf; pf=$(pidfile)
  if dashboard_unit_manages_this_home; then
    printf 'process: unit-managed by %s (%s, %s)\n' \
      "$DASHBOARD_UNIT" "$(dashboard_unit_state)" "$(dashboard_unit_enabled)"
    local user="${USER:-$(id -un)}"
    if dashboard_linger_enabled; then
      printf 'boot:    lingering on for %s - the unit comes up with the host\n' "$user"
    else
      printf 'boot:    lingering OFF for %s - the board waits for a login instead of coming up with the host: loginctl enable-linger %s\n' \
        "$user" "$user"
    fi
    if [ -f "$pf" ] && dashboard_server_running "$(cat "$pf")"; then
      printf 'process: ALSO running from a pidfile (pid %s), hand-started before the unit - hand it over with: fm-dashboard.sh restart\n' \
        "$(cat "$pf")"
    fi
  elif [ -f "$pf" ] && dashboard_server_running "$(cat "$pf")"; then
    printf 'process: running (pid %s)\n' "$(cat "$pf")"
  else
    printf 'process: not running (no active pid recorded by this script)\n'
  fi
  if dash_call GET /api/health >/dev/null 2>&1; then
    printf 'api:     reachable at %s\n' "$(dash_url)"
  else
    printf 'api:     UNREACHABLE at %s\n' "$(dash_url)"
  fi
}

# What the boot unit runs: the same server in the FOREGROUND, resolved through
# the same three functions `start` uses, and exec'd so systemd supervises the
# server itself rather than this wrapper. It writes no pidfile - the unit is
# the record of what is running.
cmd_serve_foreground() {
  local host port db
  host=$(dashboard_bind_host); port=$(dashboard_bind_port); db=$(dashboard_db_path)
  mkdir -p "$(dirname "$db")"
  exec python3 "$DASHBOARD_DIR/server/main.py" --host "$host" --port "$port" --db "$db"
}

cmd_install_boot() {
  command -v systemctl >/dev/null 2>&1 \
    || die "requires 'systemctl' on PATH - without a systemd user manager there is no unit to install"
  FM_HOME=$(dashboard_home_key "$FM_HOME")
  if [ -f "$FM_HOME/.git" ]; then
    local primary
    primary=$(dashboard_primary_checkout "$FM_HOME") || primary='<primary checkout>'
    die "FM_HOME=$FM_HOME is a linked git worktree ($FM_HOME/.git is a pointer file, not the repository) - a unit pinned there dies with the worktree. Install from the tracked root instead: FM_HOME=$primary fm-dashboard.sh install-boot"
  fi
  local exec_path="$FM_HOME/bin/fm-dashboard.sh"
  [ -x "$exec_path" ] \
    || die "no runnable dashboard script at $exec_path - the unit is pinned to \$FM_HOME's own checkout, never to the copy this command was run from"
  local path; path=$(dashboard_unit_path)
  if [ -f "$path" ]; then
    local existing; existing=$(dashboard_unit_home)
    if [ -z "$existing" ]; then
      die "$path already exists and records no FM_HOME - remove it by hand, then run install-boot again"
    fi
    dashboard_same_home "$existing" "$FM_HOME" \
      || die "$path already manages FM_HOME=$existing - run uninstall-boot from that home before installing this one"
  fi
  local host port db dir
  host=$(dashboard_bind_host); port=$(dashboard_bind_port); db=$(dashboard_db_path)
  dir=$(dashboard_unit_dir)
  mkdir -p "$dir" || die "could not create $dir"
  cat > "$path" <<UNIT || die "could not write $path"
[Unit]
Description=Admiral's Fleet Dashboard (firstmate)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=$(dashboard_unit_quote "FM_HOME=$FM_HOME")
Environment=$(dashboard_unit_quote "FM_DASHBOARD_HOST=$host")
Environment=$(dashboard_unit_quote "FM_DASHBOARD_PORT=$port")
Environment=$(dashboard_unit_quote "FM_DASHBOARD_DB=$db")
ExecStart=$(dashboard_unit_quote "$exec_path") serve-foreground
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload || die "systemctl --user daemon-reload failed - $path is written but not loaded"
  systemctl --user enable "$DASHBOARD_UNIT" >/dev/null 2>&1 \
    || die "systemctl --user enable $DASHBOARD_UNIT failed - $path is written but will not start at boot"
  local user="${USER:-$(id -un)}" linger
  if dashboard_linger_enabled; then
    linger="lingering already on for $user"
  elif command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$user" >/dev/null 2>&1; then
    linger="lingering enabled for $user"
  else
    linger="lingering NOT enabled - the board will wait for a login instead of coming up with the host. Run this yourself: sudo loginctl enable-linger $user"
  fi
  printf 'installed %s -> %s\n' "$DASHBOARD_UNIT" "$path"
  printf 'binds http://%s:%s/  db %s  home %s\n' "$host" "$port" "$db" "$FM_HOME"
  printf '%s\n' "$linger"
  local pf; pf=$(pidfile)
  if [ -f "$pf" ] && dashboard_server_running "$(cat "$pf")"; then
    printf 'a hand-started board (pid %s) still holds that address - hand it over with: fm-dashboard.sh restart\n' "$(cat "$pf")"
  else
    printf 'bring it up now with: fm-dashboard.sh start\n'
  fi
}

cmd_uninstall_boot() {
  command -v systemctl >/dev/null 2>&1 || die "requires 'systemctl' on PATH"
  local path; path=$(dashboard_unit_path)
  [ -f "$path" ] || die "no unit installed at $path"
  local existing; existing=$(dashboard_unit_home)
  dashboard_same_home "$existing" "$FM_HOME" \
    || die "$path manages FM_HOME=${existing:-<none recorded>}, not $FM_HOME - run uninstall-boot from that home"
  if dashboard_unit_active; then
    systemctl --user stop "$DASHBOARD_UNIT" \
      || die "systemctl --user stop $DASHBOARD_UNIT failed - refusing to remove a unit file still supervising a running board"
  fi
  systemctl --user disable "$DASHBOARD_UNIT" >/dev/null 2>&1 || true
  rm -f "$path"
  systemctl --user daemon-reload || true
  printf 'removed %s (%s) - the board no longer starts at boot, and start/stop/restart go back to the pidfile\n' \
    "$DASHBOARD_UNIT" "$path"
  printf 'lingering left as it is: other user units on this host depend on it\n'
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] && shift || true
  case "$cmd" in
    add) cmd_add "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    title) cmd_title "$@" ;;
    agent) cmd_agent "$@" ;;
    captain) cmd_captain "$@" ;;
    captains) cmd_captains "$@" ;;
    ref) cmd_ref "$@" ;;
    status) cmd_status "$@" ;;
    plan) cmd_plan "$@" ;;
    star) cmd_star_toggle true "$@" ;;
    unstar) cmd_star_toggle false "$@" ;;
    note) cmd_note "$@" ;;
    link) cmd_link "$@" ;;
    delete) cmd_delete "$@" ;;
    audit-log) cmd_audit_log "$@" ;;
    audit-run) cmd_audit_run "$@" ;;
    audit-interval) cmd_audit_interval "$@" ;;
    audit-status) cmd_audit_status "$@" ;;
    audit-tick) cmd_audit_tick "$@" ;;
    audit-claim) cmd_audit_claim "$@" ;;
    audit-release) cmd_audit_release "$@" ;;
    start) cmd_server_start ;;
    stop) cmd_server_stop ;;
    restart) cmd_server_stop --if-running || true; cmd_server_start ;;
    server-status) cmd_server_status ;;
    install-boot) cmd_install_boot ;;
    uninstall-boot) cmd_uninstall_boot ;;
    serve-foreground) cmd_serve_foreground ;;
    # Help is the header comment block itself: everything from line 2 (past the
    # shebang) up to the first non-comment line. Derived, not a fixed range, so
    # editing the header can never silently truncate --help.
    ""|--help|-h|help)
      awk 'NR == 1 { next } !/^#/ { exit } { print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd' - run: fm-dashboard.sh --help" ;;
  esac
}

main "$@"
