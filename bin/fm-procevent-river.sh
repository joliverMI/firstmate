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
# PEEK UNTIL ACK is the shape of this service, and it is what makes the ordering
# below load-bearing. `GET /next` retires nothing: it returns the OLDEST pending
# item and keeps returning that same item on every read until it is explicitly
# retired by `POST /ack` carrying that item's id. So the poll acks each item
# immediately after capturing it and BEFORE requesting the next one. A read
# issued before the ack would simply hand back the item just captured, which is
# how a burst of three phrases once became one result holding sixty-four copies
# of the first; and a continuous source that never acked would re-capture and
# re-wake on that item forever. The ack is idempotent by the service's own
# contract, so a retried or duplicated ack is an ordinary success, never an
# error, and an ack that fails is retried up to two more times,
# FM_RIVER_RETRY_BACKOFF seconds apart, before it counts as failed.
#
# AT LEAST ONCE is the SERVICE's side of this handoff: an item is retired only
# by an ack that lands, so an item this poll read but did not manage to ack is
# still held by the service and is served again, to this poll or to the next
# one. An item that cannot be acked is withheld and reported as an outage
# naming its id and the length of its text, rather than delivered, so a
# takeover is never delivered twice. When the ack of the FIRST item still fails
# after its retries, the failure is handled like any other outage below: the
# poll backs off and re-reads instead of emitting, so a service that serves
# items but refuses acks is reported once per FM_RIVER_UNREACHABLE_WINDOW
# rather than waking firstmate on the same unretired item every cycle. When the
# ack of a LATER item of the burst fails, the drain ends and the items already
# acked are emitted; the next poll meets the unacked item at the head of the
# queue. The gap runs the other way too: an item whose ack landed but that this
# poll had not yet emitted when it died is retired service-side and is not
# delivered. Neither this adapter nor the runner is lossless; the runner's own
# durability boundary is documented in bin/fm-procevent.sh and is not restated
# here.
#
# BURST BATCHING is load-bearing. Several phrases spoken in one burst must
# produce ONE captured result and therefore ONE wake, not one wake per phrase.
# So once an item arrives, the poll immediately drains every further pending item
# with zero-wait calls, and once the queue reads empty it keeps reading for
# FM_RIVER_BURST_GRACE_MS of idle time before emitting its single array, so a
# phrase spoken a moment after the burst joins the same result instead of
# producing a second wake. Each captured item restarts that window, and the
# window is counted as idle time between zero-wait reads rather than from a wall
# clock. A burst longer than FM_RIVER_MAX_BURST items or bigger than
# FM_RIVER_MAX_BATCH_BYTES bytes is split across results rather than growing
# without bound, which is also what stops continuous speech from holding one
# result open indefinitely; the remainder is still queued and returns at once.
# Only the zero-wait drain calls are gated by the byte budget: the first item of
# a burst is already captured and acked by the time its size is known, so it is
# always emitted even if it alone exceeds the budget.
#
# AN OVERSIZED ITEM IS RETIRED UNREAD, so it cannot wedge the queue. A read is
# capped at FM_RIVER_MAX_BYTES, and curl refuses an item over that cap before
# its body, and so its id, is seen. Nothing but an ack retires it, so left alone
# it would sit at the head of the queue and block every takeover behind it for
# good. So the poll reads that head item again, uncapped but cut to a short
# prefix, which by the contract's key order carries the id; acks it; and emits
# {"error": "oversized item retired unread", "item_id": ..., "bytes": ...} in
# place of the item, so firstmate learns that a takeover was dropped for size
# instead of never hearing of it. Its text is never delivered. If even that
# prefix yields no id to ack, the condition is reported through the outage path
# below rather than retried in a tight loop.
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
#   FM_RIVER_RETRY_BACKOFF (5)          first retry sleep, doubling to 60; also
#                                       the pause between retries of one ack
#   FM_RIVER_MAX_BURST (64)             items drained into one result
#   FM_RIVER_BURST_GRACE_MS (500)       idle milliseconds the drain keeps reading
#                                       after the queue empties, before emitting;
#                                       0 emits as soon as the queue reads empty
#   FM_RIVER_MAX_BYTES (262144)         bytes accepted for one item; a bigger
#                                       item is retired unread and reported
#   FM_RIVER_MAX_BATCH_BYTES (1048576)  byte budget for one emitted batch,
#                                       counted over the whole emitted array
#                                       including the JSON framing this adapter
#                                       adds: the two brackets, one comma between
#                                       adjacent items, and the trailing newline.
#                                       The default equals the runner's durable
#                                       capture cap (bin/fm-procevent.sh's
#                                       FM_PROCEVENT_MAX_OUTPUT_BYTES, 1 MiB), so
#                                       a batch this poll emits is never
#                                       truncated in the captured result.
#
# Durability boundary: this adapter's own side is the AT LEAST ONCE paragraph
# above; the runner's side is documented in bin/fm-procevent.sh.
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
BURST_GRACE_MS=${FM_RIVER_BURST_GRACE_MS:-500}
MAX_BYTES=${FM_RIVER_MAX_BYTES:-262144}
MAX_BATCH_BYTES=${FM_RIVER_MAX_BATCH_BYTES:-1048576}

# Longest single idle sleep inside the grace window. The window is spent in these
# steps so a grace of any size still notices an arriving item promptly.
GRACE_TICK_MS=100

# Seconds allowed for one ack request. The ack is a tiny local-network call with
# no long-poll semantics, so this only has to be generous enough for a stall.
ACK_TIMEOUT=20

# Attempts made to retire one item before its ack counts as failed. The ack is
# idempotent, so every retry is safe; the bound keeps a dead ack endpoint from
# holding a captured burst open indefinitely.
ACK_ATTEMPTS=3

# Bytes read of an item that exceeded FM_RIVER_MAX_BYTES, just enough to carry
# its id (the object's first member by contract) so it can be retired.
OVERSIZED_PROBE_BYTES=4096

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,137p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

require_number() {  # <name> <value>
  case "$2" in ''|*[!0-9]*) die "$1 must be a nonnegative integer: $2" ;; esac
}

# Read a single-line private config value. A missing, empty, symlinked, or
# multi-line file is a refusal, never a guessed default.
read_config_line() {  # <file>
  local file=$1 content value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  content=$(head -c 8192 "$file"; printf x)
  content=${content%x}
  case "$content" in *$'\n'?*) return 1 ;; esac
  value=${content%%$'\n'*}
  value=${value//$'\r'/}
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
    *[[:space:]]*|*'"'*|*"'"*|*\\*|*'?'*|*'#'*) return 1 ;;
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
  cleanup_arm() { [ -z "$AUTH_FILE" ] || rm -f -- "$AUTH_FILE"; }
  trap cleanup_arm EXIT
  trap 'cleanup_arm; exit 143' HUP INT TERM
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

# The item's "id" member, still in its raw escaped JSON string form so it can be
# placed straight back into the ack body with no decode-then-re-encode round
# trip that could alter the bytes the service matches on. Empty output means the
# item carried no usable id.
item_id_raw() {  # <item-file>
  perl -e '
    local $/;
    my $text = <STDIN>;
    $text = "" unless defined $text;
    if ($text =~ /"id"\s*:\s*"((?:[^"\\]|\\.)*)"/) { print $1 }
  ' < "$1"
}

# The length in characters of the item's "text" member, decoded, or nothing
# when the item carries no such member. Only the length ever leaves this
# function: an outage report must say how much was withheld, never what.
item_text_length() {  # <item-file>
  perl -e '
    local $/;
    my $text = <STDIN>;
    $text = "" unless defined $text;
    if ($text =~ /"text"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
      my $t = $1;
      $t =~ s/\\u([0-9a-fA-F]{4})/chr(hex($1))/ge;
      $t =~ s/\\(.)/$1/g;
      print length($t);
    }
  ' < "$1"
}

# What an outage report says about an item this poll is holding back: which
# item, by id, and how much text it carries, never the text itself.
withheld_item_detail() {  # <item-file>
  local id len
  id=$(item_id_raw "$1")
  len=$(item_text_length "$1")
  if [ -n "$id" ]; then id="item $id"; else id="an item whose id could not be extracted"; fi
  if [ -n "$len" ]; then len="text length $len"; else len="text length unknown"; fi
  printf 'withholding %s (%s)' "$id" "$len"
}

ACK_ERROR=

# Retire one captured item, so the next read returns the NEXT item rather than
# this one again. Idempotent by the service's contract: a repeat of an ack that
# already landed is a success, which is why a lost ack response is simply
# retried here. Non-zero means the item is still pending service-side after
# ACK_ATTEMPTS tries, with the reason left in ACK_ERROR (a variable, not stdout,
# for the same subshell reason load_config gives).
river_ack() {  # <item-file> <ack-body-file>
  local id code rc attempt=1
  ACK_ERROR=
  id=$(item_id_raw "$1")
  if [ -z "$id" ]; then
    ACK_ERROR="a captured item carried no usable id, so it cannot be retired"
    return 1
  fi
  if ! printf '{"id": "%s"}' "$id" > "$2" 2>/dev/null; then
    ACK_ERROR="cannot stage the ack body for item $id"
    return 1
  fi
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -m "$ACK_TIMEOUT" \
      -H "@$AUTH_FILE" \
      -H 'Content-Type: application/json' \
      --data-binary "@$2" \
      "$BASE/ack" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      ACK_ERROR="the ack of item $id could not reach the River service (curl exit $rc)"
    else
      ACK_ERROR="the River service answered HTTP $code to the ack of item $id"
    fi
    [ "$attempt" -lt "$ACK_ATTEMPTS" ] || return 1
    attempt=$((attempt + 1))
    [ "$RETRY_BACKOFF" -eq 0 ] || sleep "$RETRY_BACKOFF"
  done
}

# Read the head item again with no size cap, keeping only a short prefix so its
# id can be extracted and acked. The response headers land in <header-file> so
# the item's declared size can be reported.
oversized_probe() {  # <prefix-file> <header-file>
  : > "$1"
  : > "$2"
  curl -s -D "$2" -o - \
    -m "$ACK_TIMEOUT" \
    -H "@$AUTH_FILE" \
    -H 'Accept: application/json' \
    "$BASE/next?wait=0" 2>/dev/null | head -c "$OVERSIZED_PROBE_BYTES" > "$1"
}

# The declared body size from a saved response header block, or nothing.
response_length() {  # <header-file>
  tr -d '\r' < "$1" | awk 'tolower($1) == "content-length:" { n = $2 } END { if (n != "") print n }'
}

# The final HTTP status from a saved response header block, or nothing.
response_status() {  # <header-file>
  tr -d '\r' < "$1" | awk '$1 ~ /^HTTP\// { s = $2 } END { if (s != "") print s }'
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
    "$1" "$SOURCE_ID" "$(printf '%s' "$2" | tr -d '\042\134' | tr -d '\000-\037')"
}

# The result emitted in place of an item too big to read: its id (already in
# raw JSON string form) and its declared size, or null when the service sent no
# Content-Length.
emit_oversized_error() {  # <item-id-raw> <bytes>
  local bytes=$2
  case "$bytes" in ''|*[!0-9]*) bytes=null ;; esac
  printf '{"error": "oversized item retired unread", "source": "%s", "item_id": "%s", "bytes": %s, "limit": %s}\n' \
    "$SOURCE_ID" "$1" "$bytes" "$MAX_BYTES"
}

cmd_poll() {
  [ "$#" -eq 0 ] || usage
  require_number FM_RIVER_WAIT "$WAIT"
  require_number FM_RIVER_UNREACHABLE_WINDOW "$UNREACHABLE_WINDOW"
  require_number FM_RIVER_RETRY_BACKOFF "$RETRY_BACKOFF"
  require_number FM_RIVER_MAX_BURST "$MAX_BURST"
  require_number FM_RIVER_BURST_GRACE_MS "$BURST_GRACE_MS"
  require_number FM_RIVER_MAX_BYTES "$MAX_BYTES"
  require_number FM_RIVER_MAX_BATCH_BYTES "$MAX_BATCH_BYTES"
  [ "$MAX_BURST" -ge 1 ] || die "FM_RIVER_MAX_BURST must be at least 1"
  command -v curl >/dev/null 2>&1 || die "curl is not installed"

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-river.XXXXXX") || die "cannot stage the poll workspace"
  chmod 700 "$work" 2>/dev/null || true
  cleanup_poll() { rm -rf -- "$work"; [ -z "$AUTH_FILE" ] || rm -f -- "$AUTH_FILE"; }
  trap cleanup_poll EXIT
  trap 'cleanup_poll; exit 143' HUP INT TERM

  local body="$work/body"
  local fail_since='' fail_since_iso='' backoff=$RETRY_BACKOFF code rc
  local probe_status='' probe_length=''
  local items=() count=0 n=0 batch_bytes=0 grace_left=0

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

  # Spend one step of the grace window. It mutates grace_left in place rather
  # than returning a remainder, for the same reason note_failure does: a command
  # substitution would run it in a subshell and lose the accounting.
  grace_sleep() {
    local step=$GRACE_TICK_MS
    [ "$step" -le "$grace_left" ] || step=$grace_left
    sleep "$(printf '%d.%03d' "$((step / 1000))" "$((step % 1000))")"
    grace_left=$((grace_left - step))
  }

  while :; do
    if ! load_config; then
      note_failure "${CONFIG_ERROR:-the River configuration is unusable}" || exit 0
      continue
    fi
    code=$(river_get "$WAIT" "$body"); rc=$?
    if [ "$rc" -eq 63 ]; then
      # The head item is over the read cap, and nothing but an ack retires it.
      # Learn its id from a short uncapped prefix, retire it, and report it in
      # place of delivering it, so the takeovers behind it are not blocked.
      oversized_probe "$work/item.0" "$work/headers"
      probe_status=$(response_status "$work/headers")
      probe_length=$(response_length "$work/headers")
      case "$probe_status" in
        200) ;;
        204) clear_failure; continue ;;
        *)
          note_failure "the River service answered HTTP ${probe_status:-none} to the re-read of an item over FM_RIVER_MAX_BYTES ($MAX_BYTES)" || exit 0
          continue
          ;;
      esac
      if [ -n "$probe_length" ] && [ "$probe_length" -le "$MAX_BYTES" ]; then
        continue
      fi
      if river_ack "$work/item.0" "$work/ack"; then
        emit_oversized_error "$(item_id_raw "$work/item.0")" "$probe_length"
        exit 0
      fi
      note_failure "an item over FM_RIVER_MAX_BYTES ($MAX_BYTES) heads the queue and could not be retired: $ACK_ERROR" || exit 0
      continue
    fi
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

    # An item arrived: ack it, then burst-batch everything else already queued
    # with zero-wait calls, so one burst of speech is one wake. Every captured
    # item is acked before the next read, because an unacked item is simply
    # served again, and an item joins the batch only once its ack has landed. A
    # first item whose ack still fails after its retries is an outage: the poll
    # backs off and re-reads rather than emitting an item the service will
    # serve again on every cycle. The drain only continues while even a
    # maximum-size next item would still fit the batch byte budget, so nothing
    # is taken that the emitted array cannot carry, and an ack failure there
    # ends the drain rather than letting it spin on an item the service still
    # holds.
    cp -- "$body" "$work/item.0" || die "cannot stage the captured item"
    if ! river_ack "$work/item.0" "$work/ack"; then
      note_failure "$ACK_ERROR; $(withheld_item_detail "$work/item.0")" || exit 0
      continue
    fi
    items=("$work/item.0"); count=1; n=0
    batch_bytes=$((3 + $(wc -c < "$work/item.0")))
    grace_left=$BURST_GRACE_MS
    while [ "$count" -lt "$MAX_BURST" ]; do
      [ "$((batch_bytes + 1 + MAX_BYTES))" -le "$MAX_BATCH_BYTES" ] || break
      code=$(river_get 0 "$body") || break
      if [ "$code" = 200 ] && [ -s "$body" ]; then
        n=$count
        cp -- "$body" "$work/item.$n" || break
        river_ack "$work/item.$n" "$work/ack" || break
        items+=("$work/item.$n")
        count=$((count + 1))
        batch_bytes=$((batch_bytes + 1 + $(wc -c < "$work/item.$n")))
        grace_left=$BURST_GRACE_MS
        continue
      fi
      # Nothing pending. Linger for the rest of the grace window so a phrase
      # spoken just behind this burst lands in the same wake; any other answer
      # ends the drain and the batch is emitted as it stands.
      [ "$code" = 200 ] || [ "$code" = 204 ] || break
      [ "$grace_left" -gt 0 ] || break
      grace_sleep
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
