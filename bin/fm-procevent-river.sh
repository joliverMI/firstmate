#!/usr/bin/env bash
# River adapter for the generic process-to-event runner: a STANDING long poll on
# the River voice service, so a queued takeover wakes firstmate in seconds with
# zero periodic model activity.
#
# Usage:
#   fm-procevent-river.sh arm
#   fm-procevent-river.sh poll
#   fm-procevent-river.sh classify <result-file>
#   fm-procevent-river.sh terminal <result-file>
#   fm-procevent-river.sh source-id
#   fm-procevent-river.sh retire
#
# arm       Register the canonical source `river-takeover-stream` with
#           bin/fm-procevent.sh, whose argv is this script's own `poll` command.
#           It refuses unless this home's River configuration is present and
#           usable, so a source is never armed on a home that cannot poll.
# poll      The runner's blocking child. Long-polls until at least one takeover
#           arrives, prints ONE JSON array of every item it drained, and exits 0.
#           Never run this in a conversational turn; it blocks for as long as the
#           service does, which is what the runner exists to absorb.
# classify  Print what a captured result carries: `takeovers` (a non-empty JSON
#           array of items), `service-error` (an error object), or `unknown`.
# terminal  ALWAYS exits non-zero. This source is continuous: it never retires on
#           a result, so the runner keeps it armed and restarts it after every
#           capture. That is the whole point of this adapter. A source that
#           retired itself on its own outage warning would leave the home with no
#           voice channel the moment that warning was acknowledged - a silent
#           failure exactly one mistake deep, which is the shape this adapter
#           exists to remove. Retirement here is only ever explicit, through
#           `retire`.
# source-id Print the canonical source id.
# retire    Drop the registration through the runner's own retire.
#
# There is no `answers` command: this source carries takeovers, not keyed captain
# answers, so it is never bound to a decision origin.
#
# CONFIGURATION, per home, both required, both gitignored under config/:
#   $FM_HOME/config/river-service   one line: the service base URL, e.g.
#                                   http://198.51.100.10:8099
#   $FM_HOME/config/river-token     one line: the bearer token
# Neither value is ever hardcoded here, and the token is never placed in argv, in
# the environment, or in any output: it is written to a private 0600 header file
# that only curl reads, so `ps` and the registered argv file cannot leak it.
#
# BURST BATCHING is load-bearing. Several phrases spoken in one burst must
# produce ONE captured result and therefore ONE wake, not one wake per phrase.
# So once an item arrives, the poll immediately drains every further pending item
# with zero-wait calls until the service reports none, and emits a single array.
# A burst longer than FM_RIVER_MAX_BURST items is split across results rather than
# growing without bound; the remainder is still queued and returns at once.
#
# OUTAGES ARE LOUD. A connection failure, an unreadable configuration, or a
# rejected credential is retried with backoff, and every retry is shell work with
# no model activity. When the service has been continuously unusable for
# FM_RIVER_UNREACHABLE_WINDOW seconds, the poll emits
# {"error": "service unreachable since <ts>", ...} and exits 0, so firstmate is
# woken about the outage instead of sleeping through it. The window bounds wake
# volume too: a persistent outage produces at most one wake per window.
#
# Environment overrides (defaults in parentheses), for tests and tuning:
#   FM_RIVER_WAIT (280)                 long-poll wait seconds per request
#   FM_RIVER_UNREACHABLE_WINDOW (1800)  seconds of continuous failure before the
#                                       poll reports the outage as a result
#   FM_RIVER_RETRY_BACKOFF (5)          first retry sleep, doubling to 60
#   FM_RIVER_MAX_BURST (64)             items drained into one result
#   FM_RIVER_MAX_BYTES (262144)         bytes accepted for one item
#
# Durability boundary: see bin/fm-procevent.sh. This adapter proves nothing about
# the service side of the handoff; whether a takeover the service has already
# dequeued survives a crash of this poll is the service's property, not ours.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

SOURCE_ID=river-takeover-stream

WAIT=${FM_RIVER_WAIT:-280}
UNREACHABLE_WINDOW=${FM_RIVER_UNREACHABLE_WINDOW:-1800}
RETRY_BACKOFF=${FM_RIVER_RETRY_BACKOFF:-5}
MAX_BURST=${FM_RIVER_MAX_BURST:-64}
MAX_BYTES=${FM_RIVER_MAX_BYTES:-262144}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,71p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

require_number() {  # <name> <value>
  case "$2" in ''|*[!0-9]*) die "$1 must be a nonnegative integer: $2" ;; esac
}

# Read a single-line private config value. A missing, empty, symlinked, or
# multi-line file is a refusal, never a guessed default.
read_config_line() {  # <file>
  local file=$1 value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  value=$(head -c 8192 "$file" | sed -n '1p' | tr -d '\r')
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# The base URL must be an ordinary absolute http(s) URL with no shell or curl
# argument surface: nothing that could turn into a second curl option or a
# second header.
valid_base_url() {  # <url>
  case "$1" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:]]*|*'"'*|*"'"*|*'\'*|*'?'*|*'#'*) return 1 ;;
  esac
  return 0
}

BASE=
AUTH_FILE=
CONFIG_ERROR=

# Load this home's River configuration and (re)write the private header file the
# poll's curl invocations read. Returns non-zero and leaves the reason in
# CONFIG_ERROR. It deliberately reports through a variable rather than stdout,
# because a command substitution would run it in a subshell and lose the
# credential file it just staged.
load_config() {
  local base token
  CONFIG_ERROR=
  if ! base=$(read_config_line "$CONFIG/river-service"); then
    CONFIG_ERROR="the River service URL is missing from this home (config/river-service)"
    return 1
  fi
  if ! valid_base_url "$base"; then
    CONFIG_ERROR="the River service URL is not a usable http(s) URL (config/river-service)"
    return 1
  fi
  if ! token=$(read_config_line "$CONFIG/river-token"); then
    CONFIG_ERROR="the River bearer token is missing from this home (config/river-token)"
    return 1
  fi
  BASE=${base%/}
  if [ -z "$AUTH_FILE" ]; then
    if ! AUTH_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-river-auth.XXXXXX"); then
      AUTH_FILE=
      CONFIG_ERROR="cannot stage the private credential file"
      return 1
    fi
  fi
  if ! chmod 600 "$AUTH_FILE" 2>/dev/null \
    || ! printf 'Authorization: Bearer %s\n' "$token" > "$AUTH_FILE" 2>/dev/null; then
    CONFIG_ERROR="cannot write the private credential file"
    return 1
  fi
  return 0
}

cmd_source_id() {
  [ "$#" -eq 0 ] || usage
  printf '%s\n' "$SOURCE_ID"
}

cmd_arm() {
  [ "$#" -eq 0 ] || usage
  command -v curl >/dev/null 2>&1 || die "curl is not installed"
  if ! load_config; then
    die "${CONFIG_ERROR:-the River configuration is unusable}"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" register river "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-river.sh" poll || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
  printf 'service: %s\n' "$BASE"
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
}

# One request for the next item. Prints the HTTP status; the body lands in
# <body-file>. The credential travels only in the private header file.
river_get() {  # <wait-seconds> <body-file>
  local wait=$1 body=$2 timeout
  timeout=$((wait + 20))
  curl -s -o "$body" -w '%{http_code}' \
    -m "$timeout" \
    --max-filesize "$MAX_BYTES" \
    -H "@$AUTH_FILE" \
    -H 'Accept: application/json' \
    "$BASE/next?wait=$wait" 2>/dev/null
}

# Emit one JSON array of the drained item bodies, exactly one captured result for
# the whole burst.
emit_items() {  # <item-file>...
  local first=1 file
  printf '['
  for file in "$@"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    perl -e 'local $/; my $t = <STDIN>; $t =~ s/\s+\z//; print $t' < "$file"
  done
  printf ']\n'
}

emit_service_error() {  # <since-iso8601> <detail>
  printf '{"error": "service unreachable since %s", "source": "%s", "detail": "%s"}\n' \
    "$1" "$SOURCE_ID" "$(printf '%s' "$2" | tr -d '"\\' | tr -d '\000-\037')"
}

cmd_poll() {
  [ "$#" -eq 0 ] || usage
  require_number FM_RIVER_WAIT "$WAIT"
  require_number FM_RIVER_UNREACHABLE_WINDOW "$UNREACHABLE_WINDOW"
  require_number FM_RIVER_RETRY_BACKOFF "$RETRY_BACKOFF"
  require_number FM_RIVER_MAX_BURST "$MAX_BURST"
  require_number FM_RIVER_MAX_BYTES "$MAX_BYTES"
  [ "$MAX_BURST" -ge 1 ] || die "FM_RIVER_MAX_BURST must be at least 1"
  command -v curl >/dev/null 2>&1 || die "curl is not installed"

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-river.XXXXXX") || die "cannot stage the poll workspace"
  chmod 700 "$work" 2>/dev/null || true
  cleanup_poll() { rm -rf -- "$work"; [ -z "$AUTH_FILE" ] || rm -f -- "$AUTH_FILE"; }
  trap cleanup_poll EXIT
  trap 'cleanup_poll; exit 143' HUP INT TERM

  local body="$work/body"
  local fail_since= fail_since_iso= backoff=$RETRY_BACKOFF code rc
  local items=() count=0 n=0

  # One failed attempt. Reports the outage as a result once the whole
  # unreachable window has passed with nothing usable, otherwise backs off and
  # lets the caller retry. Every retry is shell work: no model activity.
  note_failure() {  # <reason>
    local now
    now=$(date +%s)
    if [ -z "$fail_since" ]; then
      fail_since=$now
      fail_since_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      backoff=$RETRY_BACKOFF
    fi
    if [ "$((now - fail_since))" -ge "$UNREACHABLE_WINDOW" ]; then
      emit_service_error "$fail_since_iso" "$1"
      return 1
    fi
    [ "$backoff" -eq 0 ] || sleep "$backoff"
    backoff=$((backoff * 2))
    [ "$backoff" -le 60 ] || backoff=60
    return 0
  }

  clear_failure() { fail_since=; fail_since_iso=; backoff=$RETRY_BACKOFF; }

  while :; do
    if ! load_config; then
      note_failure "${CONFIG_ERROR:-the River configuration is unusable}" || exit 0
      continue
    fi
    code=$(river_get "$WAIT" "$body"); rc=$?
    if [ "$rc" -ne 0 ]; then
      note_failure "the River service could not be reached (curl exit $rc)" || exit 0
      continue
    fi
    case "$code" in
      200)
        if [ ! -s "$body" ]; then
          clear_failure
          continue
        fi
        ;;
      204)
        clear_failure
        continue
        ;;
      *)
        note_failure "the River service answered HTTP $code" || exit 0
        continue
        ;;
    esac

    # An item arrived: burst-batch everything else already queued, with
    # zero-wait calls, so one burst of speech is one wake.
    items=(); count=0; n=0
    cp -- "$body" "$work/item.0" || die "cannot stage the captured item"
    items+=("$work/item.0")
    count=1
    while [ "$count" -lt "$MAX_BURST" ]; do
      code=$(river_get 0 "$body") || break
      [ "$code" = 200 ] || break
      [ -s "$body" ] || break
      n=$count
      cp -- "$body" "$work/item.$n" || break
      items+=("$work/item.$n")
      count=$((count + 1))
    done
    emit_items "${items[@]}"
    exit 0
  done
}

# What a captured result carries. The shapes are the two this adapter emits, read
# structurally rather than by trusting item text: a JSON array with at least one
# element is a takeover batch, a top-level object carrying an "error" member is an
# outage report, and anything else is unknown.
cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ "$#" -eq 1 ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -e '
    use strict; use warnings;
    local $/;
    open my $fh, "<", $ARGV[0] or exit 1;
    my $text = <$fh>;
    close $fh;
    $text = "" unless defined $text;
    $text =~ s/\A\s+//;
    if ($text =~ /\A\[\s*\]/)        { print "unknown\n"; exit 0 }
    if ($text =~ /\A\[/)             { print "takeovers\n"; exit 0 }
    if ($text =~ /\A\{/ && $text =~ /\A\{\s*"error"\s*:/) { print "service-error\n"; exit 0 }
    print "unknown\n";
  ' "$file"
}

# Never terminal, by design; see the header. The runner treats any non-zero exit
# as "keep this source armed", so this is the one line that keeps the voice
# channel standing across every captured takeover and every reported outage.
cmd_terminal() {
  return 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
