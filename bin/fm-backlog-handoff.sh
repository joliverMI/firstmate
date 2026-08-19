#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format. Delegating the move is the durability end-state: it removes the awk
# that used to re-implement block extraction and insertion here, so the format
# has exactly one parser and cannot drift out of sync (the body-orphaning class
# of bug fixed in PR #401 was exactly that drift).
#
# What this script still owns (never delegated):
#   - resolving the secondmate home from data/secondmates.md;
#   - proving the destination is a genuine seeded secondmate home
#     (.fm-secondmate-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the firstmate repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the secondmate backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved;
#   - warning, after a successful move, when a moved key still owes a public
#     relay reply bound to main/<key>, because that binding no longer names the
#     home that owns the work. The move is not blocked: rebinding the commitment
#     to secondmate:<id> is a relay-side decision the caller makes.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# byte-exact (header, body lines, blank separators, and indented pseudo-headings
# such as `  ## Intent`), preserving destination section placement, and moving a
# whole connected set (a blocker and its dependents) atomically with blocked-by
# links preserved. It refuses a move that would strand a dependency across the
# two files; that error is surfaced verbatim and nothing is moved.
#
# Item bodies must use at least two leading spaces. The helper refuses a selected
# item with a single-space or tab-indented continuation rather than risk leaving
# it orphaned, because tasks-axi treats only two-or-more-space lines as body.
# The move needs compatible `tasks-axi` on PATH, including atomic multi-ID `mv`
# support. Bootstrap requires a compatible build fleet-wide, so this works
# everywhere; the `config/backlog-backend=manual` knob only governs firstmate's
# own hand-editing of its own backlog, not this validated helper. Idempotent:
# re-running converges. Atomic: on any move failure nothing moves.
# See AGENTS.md project management and task lifecycle.
# Remote routes use an outbox handoff: one atomic local tasks-axi mv removes the
# selected set from the dispatchable backlog into data/handoff/<id>.outbox.md,
# then an idempotent confined transfer and fm-backlog-receive.sh deliver it.
# A present outbox is the whole recovery record for the item move itself (a
# --card link keeps its own, below). No two-phase journal exists.
#
# --card <card-id> names the Admiral's Fleet Dashboard card (bin/fm-dashboard.sh)
# this single handed-off item serves, the same best-effort link
# bin/fm-spawn.sh --card already gives a locally spawned task
# (docs/dashboard.md "The mechanical card link"). Requires exactly one
# item-key: a card names one deliverable. Once the item has genuinely landed
# in the secondmate's backlog (local move confirmed, or remote delivery
# confirmed), this best-effort sets the card's ref to "<secondmate-id>:<item-
# key>" and its agent to the secondmate id, advancing a not_started card to
# working - all through bin/fm-dashboard.sh, never a second store. A handed-off
# item has no local state/<id>.meta to hold dashboard_card= the way a spawned
# task does, so the pairing is held in this home's own state directory instead
# (state/handoff-cards/<secondmate-id>, one "<item-key>\t<card-id>" line per
# item), recorded whenever --card names an item this run routes - including a
# re-run that moved nothing because the item was already present, since a
# re-run states which card the item serves just as well as the first run did.
# That record is retired per pair, and only once the board has genuinely
# ANSWERED for that pair - the link confirmed, or a more precise claim found
# already in place - never on the strength of having merely attempted it.
# A pair whose link fails (an unreachable board, a refused write, or a host
# that says it has no such card) stays recorded, exactly where it was, for
# the next arrival at this secondmate - a later handoff's delivery, or
# --resume-pending - to retry; deleting it on a failed attempt would silently
# orphan the card for good, which is the audit finding this whole mechanism
# exists to fix. A card the host says it does not have is kept for the same
# reason: a 404 proves only that some host answered, never that the answering
# host was the board. What
# is bounded there is the noise, not the record - each such pair is reported
# once, not on every arrival.
# The handed-off item itself is never rewritten:
# which card a deliverable serves is firstmate-local bookkeeping, and
# recording it in the item's body would mean this script performing a
# read-modify-write on backlog content it does not own, where any
# disagreement with tasks-axi about where a body ends silently destroys the
# rest of it.
# Because handoffs are idempotent, the path where nothing actually moved does
# not claim a card carrying an identity that is not this mechanism's own: by
# then the secondmate may already have spawned against it with a more precise
# identity, and a re-run is not new evidence about who owns the card. The test
# is identity, not mere presence - a card still blank, or already carrying
# exactly the "<secondmate-id>:<item-key>" ref and "<secondmate-id>" agent
# this pair itself stages, is finished rather than abandoned, because
# ref and agent are two separate calls and a half-written attempt of our own
# must not read as somebody else's claim. A card id that
# does not resolve, or an
# unreachable dashboard, never fails the handoff; it is reported loudly on
# stderr and, when the dashboard answers at all, recorded through
# `fm-dashboard.sh audit-log --fleet`. No --card is the default and stages
# nothing on the board. Its one point of contact is completing a link an
# earlier --card call already staged and could not finish: every confirmed
# arrival sweeps and links every card it can, not just the one this command
# line named.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>... [--card <card-id>]
#        fm-backlog-handoff.sh --resume-pending
set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ACTIVE_HANDOFF_LOCK=
ACTIVE_REGISTRY_LOCK=
release_remote_locks() {
  if [ -n "$ACTIVE_HANDOFF_LOCK" ]; then
    fm_lock_release "$ACTIVE_HANDOFF_LOCK"
    ACTIVE_HANDOFF_LOCK=
  fi
  if [ -n "$ACTIVE_REGISTRY_LOCK" ]; then
    fm_lock_release "$ACTIVE_REGISTRY_LOCK"
    ACTIVE_REGISTRY_LOCK=
  fi
}
trap release_remote_locks EXIT
trap 'exit 1' HUP INT TERM

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

RESUME_PENDING=0
CARD_ARG=
CARD_SET=0
if [ "${1:-}" = --resume-pending ]; then
  [ "$#" -eq 1 ] || { echo "usage: fm-backlog-handoff.sh --resume-pending" >&2; exit 1; }
  RESUME_PENDING=1
  ID=
  shift
else
  [ "$#" -ge 2 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>... [--card <card-id>]" >&2; exit 1; }
  ID=$1
  shift
  ITEM_KEYS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --card) [ "$#" -ge 2 ] || { echo "error: --card requires a non-empty value" >&2; exit 1; }; CARD_ARG=$2; CARD_SET=1; shift 2 ;;
      --card=*) CARD_ARG=${1#--card=}; CARD_SET=1; shift ;;
      --) shift; while [ "$#" -gt 0 ]; do ITEM_KEYS+=("$1"); shift; done ;;
      -*) echo "error: unknown flag: $1" >&2; exit 1 ;;
      *) ITEM_KEYS+=("$1"); shift ;;
    esac
  done
  [ "${#ITEM_KEYS[@]}" -ge 1 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>... [--card <card-id>]" >&2; exit 1; }
  [ "$CARD_SET" -eq 0 ] || [ -n "$CARD_ARG" ] || { echo "error: --card requires a non-empty value" >&2; exit 1; }
  if [ "$CARD_SET" -eq 1 ]; then
    case "$CARD_ARG" in
      *[$'\t\n']*)
        echo "error: --card value must not contain a tab or newline; the pending card record and the superseded ledger hold one tab-delimited <item-key>\\t<card-id> line per pair, and either character would silently corrupt that state" >&2
        exit 1
        ;;
    esac
  fi
  [ "$CARD_SET" -eq 0 ] || [ "${#ITEM_KEYS[@]}" -eq 1 ] || {
    echo "error: --card applies only to a single-item handoff (a card names one deliverable); hand off ${ITEM_KEYS[*]} without --card, or one item at a time" >&2
    exit 1
  }
  set -- "${ITEM_KEYS[@]}"
fi

secondmate_home() {
  local id=$1 home
  [ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; return 1; }
  home=$(secondmate_registry_field "$REG" "$id" home || true)
  [ -n "$home" ] || { echo "error: secondmate $id has no home in $REG" >&2; return 1; }
  printf '%s\n' "$home"
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

# Classify a single key by the section it lives under (## In flight /
# ## Queued / ## Done), or return non-zero if no `- [ ] <key>` / `- [x] <key>`
# header exists in the file. This reads only section headings and item header
# lines - never item bodies - so it drives the fleet-level classification (in-
# flight refusal, already-present idempotency, missing-key abort) without
# re-implementing the block/body move semantics that tasks-axi mv owns.
backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

# Durable record of which dashboard card a handed-off item serves, kept in this
# home's own state directory as one "<item-key>\t<card-id>" line per item under
# handoff-cards/<secondmate-id>. A handed-off item has no local state/<id>.meta
# to hold dashboard_card= the way a spawned task does, and the item's own body
# is deliberately NOT used for it: recording the card there would mean this
# script rewriting an item body it does not own, through a read-modify-write
# whose reader has to agree with tasks-axi about where a body ends, and any
# disagreement silently writes away backlog content. The card link is
# firstmate-local bookkeeping, so it lives in firstmate-local state and the
# backlog item is never rewritten at all.
#
# Written once staging has actually succeeded (the local move landed, or the
# item reached the outbox), so a record only ever names an item that is really
# on its way. Read at the two points that confirm arrival - a completed local
# move or remote delivery, and the --resume-pending recovery path, which takes
# no keys or card id at all and has nothing else to work from.
handoff_card_record() { # <secondmate-id>
  local id=$1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$STATE/handoff-cards/$id"
}

# Re-recording a key with a DIFFERENT card keeps both pairs rather than
# replacing the old one, and says so loudly. Of the two ways to stop a silent
# overwrite - keep both, or refuse the new card while one is unresolved -
# keeping both is the one consistent with the rest of this mechanism, whose
# whole rule is that a durable record is discarded only on a genuine answer
# from the board: an unresolved old pair may already carry a half-written link
# on its card, and dropping it leaves that card dangling with nothing left to
# finish it. Refusing the new card instead would also block the corrected card
# behind an old one that may never resolve (a card the board does not have is
# never retired either). Keeping the old pair does NOT mean it gets linked:
# the newest card recorded for a key is the only one the sweep ever writes to,
# so a card the operator has disowned is never marked as served (see
# link_delivered_card_pairs). The pair survives only as the reminder that it
# may still carry a half-written link. Re-recording the SAME pair is the
# idempotent case: it is rewritten as the newest entry for its key, so the
# last card a --card actually named is always the one that gets linked.
handoff_card_record_put() { # <secondmate-id> <item-key> <card-id>
  local id=$1 key=$2 card=$3 record tmp pending revived
  local -a displaced=()
  case "$key" in ''|*[$'\t\n']*) return 1 ;; esac
  case "$card" in ''|*[$'\t\n']*) return 1 ;; esac
  record=$(handoff_card_record "$id") || return 1
  mkdir -p "$(dirname "$record")" || return 1
  tmp=$(umask 077; mktemp "$(dirname "$record")/.card.XXXXXX") || return 1
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    awk -F'\t' -v key="$key" -v card="$card" '!($1 == key && $2 == card)' "$record" > "$tmp" \
      || { rm -f "$tmp"; return 1; }
    while IFS= read -r pending; do
      [ -n "$pending" ] || continue
      [ "${pending%%$'\t'*}" = "$key" ] || continue
      displaced+=("$pending")
    done < "$tmp"
  fi
  printf '%s\t%s\n' "$key" "$card" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$record" || { rm -f "$tmp"; return 1; }
  if [ "${#displaced[@]}" -gt 0 ]; then
    for pending in "${displaced[@]}"; do
      printf 'warning: %s still has an unresolved dashboard card pairing to %s; keeping it alongside the newly named card %s rather than dropping a link that may already be half-written on the board, but it will never be linked again - check %s by hand.\n' \
        "$key" "${pending#*$'\t'}" "$card" "${pending#*$'\t'}" >&2
      handoff_card_superseded_add "$id" "$pending" \
        || printf 'warning: could not mark %s as superseded for %s; it may be linked by a later sweep\n' \
             "${pending#*$'\t'}" "$key" >&2
    done
  fi
  revived=$(printf '%s\t%s' "$key" "$card")
  handoff_card_superseded_forget "$id" "$revived" || true
  return 0
}

handoff_card_record_pairs() { # <secondmate-id>
  local id=$1 record
  record=$(handoff_card_record "$id") || return 0
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  cat -- "$record"
}

# Rewrite one of this mechanism's line-per-entry state files without exactly
# the named lines, leaving every other line untouched. Sole owner of the
# filter, shared by the durable pair record and the superseded ledger below so
# the two can never drift apart on what "this exact entry" means. Every write
# it makes is checked: a rewrite that cannot be completed leaves the original
# file exactly as it was and says so, rather than reporting a removal that did
# not happen.
handoff_card_lines_remove() { # <file> <line>...
  local file=$1 tmp line keep drop
  shift
  [ "$#" -gt 0 ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  tmp=$(umask 077; mktemp "$(dirname "$file")/.card.XXXXXX") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    keep=1
    for drop in "$@"; do
      [ "$line" != "$drop" ] || { keep=0; break; }
    done
    if [ "$keep" -eq 1 ]; then
      printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
  done < "$file"
  if [ -s "$tmp" ]; then
    mv -f -- "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  else
    rm -f -- "$tmp" "$file" || return 1
  fi
  return 0
}

# Remove exactly the named "<key>\t<card>" pairs from this secondmate's
# durable record, leaving any other pair - one whose link attempt failed, or
# one staged by a call that raced this read - untouched. A pending card
# record is retired per pair, only once the board has genuinely confirmed
# that pair's link; this is the only way anything is ever removed from it.
handoff_card_record_remove_pairs() { # <secondmate-id> <pair>...
  local id=$1 record
  shift
  [ "$#" -gt 0 ] || return 0
  record=$(handoff_card_record "$id") || return 1
  handoff_card_lines_remove "$record" "$@"
}

# Pairs this run has already reported on. A plain in-memory set, scoped to
# this one process and persisted nowhere.
#
# All three per-pair reports route through it - a pair a later --card has
# superseded, a pair the board says names no such card, and a pair whose card
# could not be read at all - and every one of them is a fact about a REPORT,
# not about the pairing, so none was ever worth durable state. A ledger on
# disk has to be written, cleared, and kept honest against the record it
# describes, and every one of those edges was a place for the two to disagree;
# nothing it bought was worth more than the warning it suppressed.
#
# The mark is keyed by REASON as well as by pair, because the three are not
# interchangeable and one command can legitimately owe two of them about the
# same pair. --resume-pending sweeps a delivered outbox's record twice; if the
# board is down for the first sweep and back for the second, that pair is owed
# an unreadable-card report and then a genuinely different "no such card" one.
# A single mark per pair would swallow the second.
#
# What this buys is the repeat inside one command: without it, that same
# double sweep lands each identical warning - and each identical audit-log
# --fleet finding - twice for a single invocation.
#
# The deliberate tradeoff: a LATER, separate invocation reports the same pair
# again rather than staying silent forever. A repeated warning about a link
# that really is still pending is honest noise - unlike a durable mark that
# can outlive, or contradict, the record it was written about.
declare -A CARD_PAIR_REPORTED=()
card_pair_report_once() { # <reason> <secondmate-id> <pair>
  local mark=$1$'\t'$2$'\t'$3
  [ -z "${CARD_PAIR_REPORTED[$mark]:-}" ] || return 1
  CARD_PAIR_REPORTED[$mark]=1
  return 0
}

# The one durable side ledger, a plain "<key>\t<card>" line per pair: pairs a
# later --card naming the same item has replaced. This is not noise
# suppression and cannot be held in memory - it is the standing decision that
# a card the operator has disowned must never be written to again, on this
# arrival or any later one. They stay in the record because they may already
# carry a half-written link somebody has to unpick; linking one anyway would
# mark a disowned card as served under an agent that is not serving it, which
# is the board drift this whole mechanism exists to remove.
#
# It holds exactly one kind of entry for exactly one reason, so nothing can
# write a mark here that another reader will take to mean something else. An
# entry is dropped when the operator names that same card again for that item
# - so the decision is reversible from the CLI alone, and a --card typo in the
# correction costs nothing - or when its pair is retired outright.
#
# Advisory: losing it costs a disowned card being linked once, which the
# operator's own re-naming warning already flagged on stderr.
handoff_card_superseded_file() { # <secondmate-id>
  local id=$1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$STATE/handoff-card-superseded/$id"
}

handoff_card_superseded_has() { # <secondmate-id> <pair>
  local id=$1 pair=$2 file
  file=$(handoff_card_superseded_file "$id") || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  grep -Fqx -- "$pair" "$file" 2>/dev/null
}

handoff_card_superseded_add() { # <secondmate-id> <pair>
  local id=$1 pair=$2 file
  if handoff_card_superseded_has "$id" "$pair"; then return 0; fi
  file=$(handoff_card_superseded_file "$id") || return 1
  mkdir -p "$(dirname "$file")" || return 1
  ( umask 077; printf '%s\n' "$pair" >> "$file" ) || return 1
  return 0
}

handoff_card_superseded_forget() { # <secondmate-id> <pair>...
  local id=$1 file
  shift
  [ "$#" -gt 0 ] || return 0
  file=$(handoff_card_superseded_file "$id") || return 1
  handoff_card_lines_remove "$file" "$@"
}

# Best-effort mechanical link to the Admiral's Fleet Dashboard
# (docs/dashboard.md "The mechanical card link"), extended from
# bin/fm-spawn.sh --card to the handoff path: only called when --card named a
# card and the item has genuinely landed in the secondmate's backlog, so an
# ordinary handoff never touches the dashboard. Pure board mutation - never
# touches the backlog file itself, so it is safe to call after a remote
# outbox has already been delivered and deleted. Every dashboard call is
# guarded so a bad card id or an unreachable dashboard can only warn - the
# handoff itself is already complete by the time this runs, and this function
# must never turn that success into a failure. A failure still gets a
# fleet-visible record via audit-log --fleet, exactly like fm-spawn.sh's own
# link.
#
# Sets DASHBOARD_LINK_CONFIRMED for the caller: 1 once the board has actually
# confirmed this link, 0 on any failure. This function's own return is always
# 0 - never failing the handoff is a hard invariant - so DASHBOARD_LINK_CONFIRMED
# is the only way a caller can tell confirmed from merely-attempted without
# weakening that. link_delivered_card_pairs below is that caller: it uses this
# to decide which pairs a pending record may actually retire.
#
# <known-status> is the status card_claim_probe already read from the board an
# instant earlier, passed in rather than re-fetched: a second read here would
# be a second separately-failable call inside the held handoff lock, and an
# unreadable one is indistinguishable from "already past not_started" - which
# would confirm, and so retire, a pair whose card is still frozen at
# not_started. An empty <known-status> means the board never answered, and is
# therefore a failure, never a licence to skip the advance.
DASHBOARD_LINK_CONFIRMED=0
dashboard_link_card() { # <secondmate-id> <item-key> <card-id> <known-status|''>
  local sm_id=$1 key=$2 card=$3 known_status=$4
  local dash ref failed=0 out
  DASHBOARD_LINK_CONFIRMED=0
  dash="$SCRIPT_DIR/fm-dashboard.sh"
  ref="$sm_id:$key"

  if out=$("$dash" ref "$card" "$ref" 2>&1); then
    :
  else
    failed=1
    echo "warning: dashboard card link failed for $key -> card $card (ref): $out" >&2
  fi

  if out=$("$dash" agent "$card" "$sm_id" 2>&1); then
    :
  else
    failed=1
    echo "warning: dashboard card link failed for $key -> card $card (agent): $out" >&2
  fi

  if [ "$failed" -eq 0 ]; then
    if [ -z "$known_status" ]; then
      failed=1
      echo "warning: dashboard card link failed for $key -> card $card (status): the board did not answer when this card was read, so it cannot be confirmed past not_started" >&2
    elif [ "$known_status" = not_started ]; then
      if out=$("$dash" status "$card" working 2>&1); then
        echo "dashboard: linked card $card to $key (ref=$ref, agent=$sm_id, status not_started -> working)"
      else
        failed=1
        echo "warning: dashboard card link failed for $key -> card $card (status working): $out" >&2
      fi
    else
      echo "dashboard: linked card $card to $key (ref=$ref, agent=$sm_id)"
    fi
  fi

  if [ "$failed" -eq 1 ]; then
    "$dash" audit-log --fleet "dashboard link failed for handoff item $key -> card $card to secondmate $sm_id; ref/agent/status may be stale" --kind error >/dev/null 2>&1 || true
  else
    DASHBOARD_LINK_CONFIRMED=1
  fi
  return 0
}

# Read the board's own view of a card, distinguishing the two failures a
# pending link must treat completely differently:
#   0 - the board answered and the card exists; CARD_EXISTING_REF,
#       CARD_EXISTING_AGENT and CARD_EXISTING_STATUS hold what it currently
#       carries (ref and agent possibly empty).
#   2 - the host answered and says this card id does not exist. Reported so
#       the caller can say something more useful than "unreachable", but NOT
#       treated as a verdict that the card is gone: a 404 only proves some
#       host answered, and a stale dashboard-url pointing at a machine that
#       still serves HTTP would 404 every card alike.
#   1 - the board could not be read at all (unreachable, timed out, any other
#       refusal). The caller still attempts the write and fails the same loud,
#       recorded, never-fatal way an unreachable board always has.
# fm-dashboard.sh reserves exit code 4 for the answered-but-missing case
# precisely so this can be told apart without parsing its stderr.
#
# This is the single read of the card in the whole sweep: everything the link
# below needs about the card's current state comes from here, so no decision
# rests on a second call that could fail on its own.
CARD_EXISTING_REF=
CARD_EXISTING_AGENT=
CARD_EXISTING_STATUS=
DASH_EXIT_NOT_FOUND=4
card_claim_probe() { # <card-id>
  local card=$1 out rc=0
  CARD_EXISTING_REF=
  CARD_EXISTING_AGENT=
  CARD_EXISTING_STATUS=
  out=$("$SCRIPT_DIR/fm-dashboard.sh" show "$card" --json 2>/dev/null) || rc=$?
  [ "$rc" -ne "$DASH_EXIT_NOT_FOUND" ] || return 2
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 1
  CARD_EXISTING_REF=$(printf '%s' "$out" | jq -r '.backlog_ref // empty' 2>/dev/null) || return 1
  CARD_EXISTING_AGENT=$(printf '%s' "$out" | jq -r '.agent // empty' 2>/dev/null) || return 1
  CARD_EXISTING_STATUS=$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null) || return 1
  return 0
}

# True when the identity the card currently carries is one THIS mechanism
# would itself have staged for this pair - either still blank, or exactly the
# "<secondmate-id>:<item-key>" / "<secondmate-id>" pair dashboard_link_card
# writes. "Does the card carry anything at all" cannot answer the question
# that matters here, because dashboard_link_card writes ref and agent in two
# separate calls: a half-written attempt of our own leaves exactly one of them
# set, and mistaking that for someone else's claim retires the record while
# the card is still stuck at not_started - the very freeze this mechanism
# exists to prevent. Anything else present is a genuinely more precise claim
# (a secondmate's own fm-spawn.sh --card writes <home>:<task-id> and the task
# id), which is never overwritten.
card_claim_is_ours() { # <secondmate-id> <item-key>
  local sm_id=$1 key=$2
  [ -z "$CARD_EXISTING_REF" ] || [ "$CARD_EXISTING_REF" = "$sm_id:$key" ] || return 1
  [ -z "$CARD_EXISTING_AGENT" ] || [ "$CARD_EXISTING_AGENT" = "$sm_id" ] || return 1
  return 0
}

# Link every card this arrival actually landed, not just the one the current
# command line named. A remote outbox is delivered as a whole, so it can carry
# items an earlier run staged and could not link; the same is true of any
# record an earlier run wrote and died before consuming. Those cards were
# deliberately left unlinked then, and the record is cleared once arrival is
# confirmed, so this is the last moment they can be linked at all.
# <unguarded-card> is the one card this run is actively claiming and may
# overwrite; every other pair is a leftover completion that only fills in a
# card nothing has claimed yet.
#
# Populates RETIRABLE_CARD_PAIRS for the caller: one "<key>\t<card>" entry per
# pair the board has now given a genuine, final answer about - freshly linked,
# or already claimed by something more precise - so the durable record can
# retire exactly those. A pair whose link attempt merely failed is never added
# here, so it is never retired either: it stays recorded for the next arrival
# (a later handoff's delivery, or --resume-pending) to retry, instead of being
# thrown away on the strength of having merely tried.
RETIRABLE_CARD_PAIRS=()
link_delivered_card_pairs() { # <secondmate-id> <unguarded-card|''> <pair>...
  local sm_id=$1 unguarded=$2 pair key card probe
  shift 2
  RETIRABLE_CARD_PAIRS=()
  for pair in "$@"; do
    [ -n "$pair" ] || continue
    key=${pair%%$'\t'*}
    card=${pair#*$'\t'}
    # A later --card naming the same item superseded this pair. The record
    # keeps it (it may still carry a half-written link somebody has to look
    # at) but it is never written to again: linking it too would mark a card
    # the operator has already disowned as served, which is the board drift
    # this mechanism exists to remove.
    if handoff_card_superseded_has "$sm_id" "$pair"; then
      if card_pair_report_once superseded "$sm_id" "$pair"; then
        echo "warning: card $card for $key was superseded by a later --card naming the same item, so it is never linked; it stays recorded because it may already carry a half-written link that has to be checked by hand" >&2
      fi
      continue
    fi
    probe=0
    card_claim_probe "$card" || probe=$?
    # A card the host says it does not have is kept and retried like any other
    # unanswerable link - the record is the only evidence the link is still
    # owed, and a 404 does not prove the answering host was the board. Only
    # the noise is bounded: report each such pair once, not on every arrival,
    # so an unresolvable id cannot bury the fleet log it is recorded in.
    if [ "$probe" -eq 2 ]; then
      if card_pair_report_once no-such-card "$sm_id" "$pair"; then
        echo "warning: the dashboard host has no card $card, so the pending link for $key cannot be completed; it stays recorded and will be retried on the next arrival" >&2
        "$SCRIPT_DIR/fm-dashboard.sh" audit-log --fleet "handoff item $key to secondmate $sm_id names dashboard card $card, which the dashboard host says it does not have; the link is still pending and will be retried, but check whether the card id is wrong or the board url is stale" --kind error >/dev/null 2>&1 || true
      fi
      continue
    fi
    # The ownership check fails CLOSED. A guarded pair is one this run has no
    # claim of its own to, so writing to it is only ever allowed after the
    # board has confirmed nothing more precise is already there; a card that
    # could not be read has confirmed nothing, and writing anyway would
    # overwrite exactly the claim the check exists to protect. Leave it for
    # the next arrival to retry with a working read - the same end state a
    # failed link reaches anyway, minus the damage.
    if [ "$card" != "$unguarded" ]; then
      if [ "$probe" -ne 0 ]; then
        if card_pair_report_once unreadable-card "$sm_id" "$pair"; then
          echo "warning: could not read dashboard card $card, so the pending link for $key cannot be checked against whatever may already claim it; nothing was written and it stays recorded for the next arrival to retry" >&2
        fi
        continue
      fi
      if ! card_claim_is_ours "$sm_id" "$key"; then
        echo "dashboard: card $card already links to ${CARD_EXISTING_REF:-(no ref)} (agent=${CARD_EXISTING_AGENT:-none}); left unchanged"
        RETIRABLE_CARD_PAIRS+=("$pair")
        continue
      fi
    fi
    dashboard_link_card "$sm_id" "$key" "$card" "$CARD_EXISTING_STATUS"
    [ "$DASHBOARD_LINK_CONFIRMED" -eq 0 ] || RETIRABLE_CARD_PAIRS+=("$pair")
  done
}

# The one place arrival is turned into board state: read this secondmate's
# whole record, link every pair it names, and retire only the pairs the board
# actually answered for. <unguarded-card> is the card this run staged itself
# and may therefore claim outright; passing it empty makes every pair guarded,
# which is what a run that staged nothing new needs - a re-run of an
# idempotent handoff is not new evidence about who owns a card the secondmate
# may since have spawned against. A pair that fails to link - an unreachable
# board, a refused write - is left exactly where it was: the record is the
# only surviving evidence of a still-pending link, and deleting it on a
# merely-attempted link would silently orphan the card for good.
#
# Callers must hold this secondmate's handoff lock: the record is a
# read-modify-write, and the sweep reads it, then writes back a filtered
# snapshot of it.
#
# Always returns 0. The handoff (or the delivery) is already complete and
# already reported by the time this runs, and this is purely firstmate-local
# bookkeeping, so a full disk or an unwritable state directory here warns and
# is never allowed to reach the caller's exit status - which on every route is
# the script's own.
#
# <undelivered-outbox> names an outbox whose delivery has NOT been confirmed,
# and holds back exactly the pairs whose item is still staged in it: those have
# not arrived anywhere yet, and linking them would mark a card as being worked
# before the item exists at the secondmate. Arrival is a property of one item,
# never of the secondmate, so this is a per-pair hold and not a per-record one -
# a record routinely also carries pairs from earlier deliveries that did land,
# and those stay linkable while a later delivery is still stuck.
consume_handoff_card_record() { # <secondmate-id> <unguarded-card|''> [<undelivered-outbox|''>]
  local id=$1 unguarded=$2 staged=${3:-} pair
  local -a pairs=()
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    if [ -n "$staged" ] && backlog_key_section "$staged" "${pair%%$'\t'*}" >/dev/null 2>&1; then
      continue
    fi
    pairs+=("$pair")
  done < <(handoff_card_record_pairs "$id")
  [ "${#pairs[@]}" -eq 0 ] && return 0
  link_delivered_card_pairs "$id" "$unguarded" "${pairs[@]}"
  if [ "${#RETIRABLE_CARD_PAIRS[@]}" -gt 0 ]; then
    handoff_card_record_remove_pairs "$id" "${RETIRABLE_CARD_PAIRS[@]}" \
      || echo "warning: could not retire ${#RETIRABLE_CARD_PAIRS[@]} confirmed card pairing(s) for $id; the next arrival will re-check them against the board" >&2
    handoff_card_superseded_forget "$id" "${RETIRABLE_CARD_PAIRS[@]}" || true
  fi
  return 0
}

# Stage this run's own pair (if it named a card) and sweep the whole record in
# one step, so both halves of the read-modify-write happen under one hold of
# the caller's lock.
record_and_sweep_card_pairs() { # <secondmate-id> <staged-key|''> <unguarded-card|''>
  local id=$1 key=$2 unguarded=$3
  if [ "$CARD_SET" -eq 1 ] && [ -n "$key" ]; then
    handoff_card_record_put "$id" "$key" "$CARD_ARG" \
      || echo "warning: could not record card $CARD_ARG for $key; a crash before the board is reached would lose the link" >&2
  fi
  consume_handoff_card_record "$id" "$unguarded"
}

# The local route holds no lock by the time it reaches the record, unlike the
# remote route which is already inside with_remote_route_locks. Without this,
# two concurrent local handoffs to the same secondmate interleave a put and a
# filtered rewrite over the same snapshot of state/handoff-cards/<id> and one
# silently loses the other's pair, orphaning that card with no record left to
# retry from. Same lock the remote route uses, so the two routes serialize
# against each other too.
with_handoff_card_lock() { # <secondmate-id> <function> <args...>
  local id=$1 rc
  shift
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    # handoff_card_record refuses these ids outright, so no record can exist
    # to serialize against; run unlocked and let its own guard report.
    if "$@"; then return 0; else return $?; fi
    ;;
  esac
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$id.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  return "$rc"
}

seed_backlog_scaffold() { # <path>
  mkdir -p "$(dirname "$1")"
  [ -f "$1" ] || printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A public commitment made through the relay binds its work by home AND id, so an
# item that leaves this home takes that binding out of sync: reconciliation would
# still look for main/<key> while the work now lives in the secondmate's home.
# The move itself stays safe and is never blocked - rebinding is a relay-side
# decision the caller owns - but this is the one moment the staleness is
# detectable, so report it loudly instead of letting the promise go quiet.
# A home that never opted into the relay pays one presence check per key here.
warn_stale_public_commitments() { # <secondmate-id> <moved-key>...
  local id=$1 key out rc
  shift
  for key in "$@"; do
    rc=0
    out=$("$SCRIPT_DIR/fm-public-followup.sh" guard-work main "$key" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ] || continue
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'warning: %s still owes a public reply bound to main/%s; rebind it to secondmate:%s (tasks-axi public-followup bind-work, then bin/fm-public-followup.sh register <obligation-id> --relation <relation-id> --work-home secondmate:%s --work-id %s --generation <n>) or the promised reply will be reconciled against work this home no longer owns.\n' \
      "$key" "$key" "$id" "$id" "$key" >&2
  done
  # Reporting never changes the handoff's own success: the move already landed.
  return 0
}

outbox_item_count() { # <path>
  awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$1"
}

remote_deliver_outbox() { # <secondmate-id> <outbox-path>
  local id=$1 outbox=$2 remote_rel receive_out snapshot bytes hash generation counter counter_tmp current
  [ -f "$outbox" ] && [ ! -L "$outbox" ] || {
    echo "error: pending outbox is unavailable or unsafe: $outbox" >&2
    return 1
  }
  snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-handoff-payload.XXXXXX") || return 1
  if ! cp -p -- "$outbox" "$snapshot"; then
    rm -f -- "$snapshot"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
  hash=$(sha256_file "$snapshot") || { rm -f -- "$snapshot"; return 1; }
  counter="$STATE/.remote-handoff-$id.generation"
  current=0
  if [ -e "$counter" ] || [ -L "$counter" ]; then
    [ -f "$counter" ] && [ ! -L "$counter" ] || { rm -f -- "$snapshot"; return 1; }
    IFS= read -r current < "$counter" || { rm -f -- "$snapshot"; return 1; }
    case "$current" in ''|*[!0-9]*) rm -f -- "$snapshot"; return 1 ;; esac
    [ "${#current}" -le 17 ] || { rm -f -- "$snapshot"; return 1; }
  fi
  generation=$((current + 1))
  counter_tmp=$(umask 077; mktemp "$STATE/.remote-handoff-generation.XXXXXX") \
    || { rm -f -- "$snapshot"; return 1; }
  printf '%s\n' "$generation" > "$counter_tmp" \
    || { rm -f -- "$snapshot" "$counter_tmp"; return 1; }
  chmod 600 "$counter_tmp" \
    || { rm -f -- "$snapshot" "$counter_tmp"; return 1; }
  mv -f -- "$counter_tmp" "$counter" \
    || { rm -f -- "$snapshot" "$counter_tmp"; return 1; }
  remote_rel="state/handoff/$id.outbox.md"
  if ! "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh put "$remote_rel" 1048576 \
    "$bytes" "$hash" "$generation" < "$snapshot"; then
    rm -f -- "$snapshot"
    echo "error: handoff transfer to $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  rm -f -- "$snapshot"
  if ! receive_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-backlog-receive.sh \
    "$remote_rel" "$bytes" "$hash" "$generation" < /dev/null 2>&1); then
    [ -z "$receive_out" ] || printf '%s\n' "$receive_out" >&2
    echo "error: handoff receipt by $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  rm -f -- "$outbox" || {
    echo "error: remote receipt was confirmed but local outbox cleanup failed: $outbox" >&2
    return 1
  }
  printf '%s\n' "$receive_out"
}

remove_interrupted_source_duplicates() { # <outbox> <keys...>
  local outbox=$1 key progress remaining pass=0
  shift
  while :; do
    remaining=0
    progress=0
    for key in "$@"; do
      backlog_key_section "$outbox" "$key" >/dev/null 2>&1 || continue
      if backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1; then
        remaining=$((remaining + 1))
        if tasks-axi rm "$key" --file "$MAIN_BACKLOG" >/dev/null 2>&1; then
          progress=$((progress + 1))
        fi
      fi
    done
    [ "$remaining" -gt 0 ] || return 0
    [ "$progress" -gt 0 ] || {
      echo "error: could not complete interrupted source removal; outbox remains authoritative at $outbox" >&2
      return 1
    }
    pass=$((pass + 1))
    [ "$pass" -le "$#" ] || return 1
  done
}

remote_handoff() { # <secondmate-id> <keys...>
  local id=$1 outbox section main_section out_section key mv_out unguarded
  local -a requested to_move already missing in_flight done_items not_queued
  shift
  requested=("$@")
  outbox="$DATA/handoff/$id.outbox.md"
  validate_backlog_file "main backlog" "$MAIN_BACKLOG" || return 1
  validate_backlog_file "remote handoff outbox" "$outbox" || return 1
  fm_tasks_axi_compatible || {
    echo "error: a compatible tasks-axi with atomic multi-ID mv support is required to stage remote handoffs; run bin/fm-bootstrap.sh for the required version" >&2
    return 1
  }
  to_move=()
  already=()
  missing=()
  in_flight=()
  done_items=()
  not_queued=()
  for key in "${requested[@]}"; do
    out_section=$(backlog_key_section "$outbox" "$key" 2>/dev/null || true)
    main_section=$(backlog_key_section "$MAIN_BACKLOG" "$key" 2>/dev/null || true)
    if [ -n "$out_section" ]; then
      [ "$out_section" = '## Queued' ] || not_queued+=("$key")
      already+=("$key")
      continue
    fi
    case "$main_section" in
      '## Queued') to_move+=("$key") ;;
      '## In flight') in_flight+=("$key") ;;
      '## Done') done_items+=("$key") ;;
      '') missing+=("$key") ;;
      *) not_queued+=("$key") ;;
    esac
  done
  if [ "${#in_flight[@]}" -gt 0 ] || [ "${#done_items[@]}" -gt 0 ] \
    || [ "${#not_queued[@]}" -gt 0 ] || [ "${#missing[@]}" -gt 0 ]; then
    [ "${#in_flight[@]}" -eq 0 ] || echo "error: refusing to hand off in-flight backlog items: ${in_flight[*]}" >&2
    [ "${#done_items[@]}" -eq 0 ] || echo "error: refusing to hand off Done backlog items: ${done_items[*]}" >&2
    [ "${#not_queued[@]}" -eq 0 ] || echo "error: refusing to hand off non-Queued outbox or backlog items: ${not_queued[*]}" >&2
    [ "${#missing[@]}" -eq 0 ] || echo "error: no backlog or pending outbox item matched: ${missing[*]}" >&2
    echo "       nothing new was staged." >&2
    return 1
  fi
  for key in "${to_move[@]}"; do
    while IFS= read -r line; do
      printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' "$key" "$line" >&2
      return 1
    done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
  done
  seed_backlog_scaffold "$outbox"
  if [ "${#to_move[@]}" -gt 0 ]; then
    if ! mv_out=$(tasks-axi mv "${to_move[@]}" --file "$MAIN_BACKLOG" --to "$outbox" 2>&1); then
      [ -z "$mv_out" ] || printf '%s\n' "$mv_out" >&2
      echo "error: atomic outbox staging failed; nothing new was handed off" >&2
      return 1
    fi
  fi
  # A hard local kill can land tasks-axi's target persist before its source
  # persist. The outbox is already authoritative in that state, so converge by
  # deleting only duplicates that tasks-axi itself confirms are dependency-safe.
  remove_interrupted_source_duplicates "$outbox" "${requested[@]}" || return 1
  # --card requires exactly one requested key, so this records the outbox's
  # single staged item now that staging has actually landed; the card link
  # itself only fires once delivery is confirmed below. Both this write and
  # the sweep below are already inside with_remote_route_locks' hold of this
  # secondmate's handoff lock.
  if [ "$CARD_SET" -eq 1 ]; then
    handoff_card_record_put "$id" "${requested[0]}" "$CARD_ARG" \
      || echo "warning: could not record card $CARD_ARG for ${requested[0]}; a crash before delivery would lose the link" >&2
  fi
  remote_deliver_outbox "$id" "$outbox" || return 1
  echo "handed off ${#requested[@]} item(s) to remote secondmate $id: ${requested[*]}"
  [ "${#already[@]}" -eq 0 ] || echo "  already staged (recovered): ${already[*]}"
  warn_stale_public_commitments "$id" "${requested[@]}"
  # Nothing newly staged means this run only re-delivered an already-staged
  # outbox, the remote twin of the local already-present path: never overwrite
  # a link something more precise has since claimed.
  unguarded=
  if [ "$CARD_SET" -eq 1 ] && [ "${#to_move[@]}" -gt 0 ]; then
    unguarded=$CARD_ARG
  fi
  consume_handoff_card_record "$id" "$unguarded"
}

with_remote_route_locks() { # <secondmate-id> <function> <args...>
  local id=$1 operation=$2 rc
  shift 2
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe remote handoff id: $id" >&2; return 1 ;; esac
  ACTIVE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
  if [ "$(secondmate_registry_field "$REG" "$id" remote 2>/dev/null || true)" != 1 ]; then
    echo "error: pending outbox has no matching remote secondmate route: $id" >&2
    release_remote_locks
    return 1
  fi
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$id.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if "$operation" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  return "$rc"
}

resume_remote_outbox() { # <secondmate-id> <outbox-path>
  local id=$1 outbox=$2
  [ -e "$outbox" ] || [ -L "$outbox" ] || return 0
  if [ ! -f "$outbox" ] || [ -L "$outbox" ]; then
    echo "error: unsafe pending handoff outbox: $outbox" >&2
    return 1
  fi
  # A crash between staging and delivery loses the CLI's own $CARD_ARG/$CARD_SET
  # context - --resume-pending takes no keys or card id at all - so the record
  # this home wrote at staging time is the only surviving statement of which
  # card(s) to link once delivery actually completes. Nothing here is claiming
  # a card on its own behalf, so every pair stays guarded.
  remote_deliver_outbox "$id" "$outbox" || return 1
  consume_handoff_card_record "$id" ''
}

resume_pending_outboxes() {
  local outbox id failed=0
  [ -d "$DATA/handoff" ] || return 0
  for outbox in "$DATA/handoff"/*.outbox.md; do
    [ -e "$outbox" ] || [ -L "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe pending handoff id: $id" >&2; failed=1; continue ;; esac
    with_remote_route_locks "$id" resume_remote_outbox "$id" "$outbox" || failed=1
  done
  return "$failed"
}

# An outbox is only the remote route's recovery record. The local route stages
# a pending pair too and never writes an outbox, so a local secondmate whose
# link failed while the board was down is invisible to the sweep above and
# would have no recovery command at all - only the accident of some later
# handoff to that same secondmate. Sweep the records themselves as well, so
# --resume-pending means every pending link rather than the remote half of
# them.
#
# A still-present outbox is what keeps the two sweeps from disagreeing, but it
# holds back only the pairs it actually still carries: an item staged in an
# undelivered outbox has NOT arrived - that is precisely what the pass above
# tries and may have failed to confirm - while every other pair recorded for
# the same secondmate names an item that landed at some earlier delivery and is
# owed its link now. Re-read here under the lock rather than trusted from the
# loop below, since the pass above runs unlocked between the two. An outbox
# that exists but is not a plain file cannot be read for what it stages, so
# nothing is swept for that id at all - the pass above already reports it.
# Nothing here stages a card of its own, so every pair stays guarded, exactly
# as the remote resume path leaves them.
resume_pending_card_record() { # <secondmate-id>
  local id=$1 outbox="$DATA/handoff/$1.outbox.md"
  if [ ! -e "$outbox" ] && [ ! -L "$outbox" ]; then
    consume_handoff_card_record "$id" ''
    return 0
  fi
  [ -f "$outbox" ] && [ ! -L "$outbox" ] || return 0
  consume_handoff_card_record "$id" '' "$outbox"
}

# Known and accepted: a record the outbox pass above already swept - a
# delivery that completed while the board would not answer - is read a second
# time here in the same command. The pairs it re-reads are exactly the ones
# still owed a link, so the retry is correct, merely redundant: it costs one
# more bounded attempt per pair. Cheaper than tracking swept ids across two
# passes that must stay independently correct, since either pass alone has to
# be able to complete a link the other never reaches. This double sweep is
# what CARD_PAIR_REPORTED exists for: the report a pair is owed is owed once
# per command, not once per pass.
resume_pending_card_records() {
  local record id failed=0
  [ -d "$STATE/handoff-cards" ] || return 0
  for record in "$STATE/handoff-cards"/*; do
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    id=$(basename "$record")
    case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe pending handoff card record: $record" >&2; failed=1; continue ;; esac
    with_handoff_card_lock "$id" resume_pending_card_record "$id" || failed=1
  done
  return "$failed"
}

if [ "$RESUME_PENDING" -eq 1 ]; then
  rc=0
  resume_pending_outboxes || rc=1
  resume_pending_card_records || rc=1
  exit "$rc"
fi

ACTIVE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
fm_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
REMOTE=$(secondmate_registry_field "$REG" "$ID" remote 2>/dev/null || true)
if [ "$REMOTE" = 1 ]; then
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  if remote_handoff "$ID" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  exit "$rc"
fi
release_remote_locks

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
SUB_HOME=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_BACKLOG="$SUB_HOME/data/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
for key in "$@"; do
  if backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
      "## Queued") TO_MOVE+=("$key") ;;
      "## In flight") IN_FLIGHT+=("$key") ;;
      "## Done") DONE+=("$key") ;;
      *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  # A --card here is still recorded - the pair is durable evidence of a link
  # that is owed, and a re-run is as good a statement of which card the item
  # serves as the first run was - but nothing was staged, so this run has no
  # claim of its own to make: every pair, this card included, stays guarded
  # against a link the secondmate may since have made more precise by spawning
  # against it.
  with_handoff_card_lock "$ID" record_and_sweep_card_pairs "$ID" "${ALREADY[0]:-}" ''
  exit 0
fi

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if ! fm_tasks_axi_compatible; then
  echo "error: a compatible tasks-axi with atomic multi-ID mv support is required to move backlog items; run bin/fm-bootstrap.sh for the required version" >&2
  exit 1
fi

# Seed the destination with firstmate's standard three-section scaffold when it
# does not exist yet, so the moved item lands under the right section. (Left to
# create the file itself, tasks-axi mv writes its own `# Backlog` title format,
# which is not firstmate's home-backlog convention.)
mkdir -p "$SUB_HOME/data"
SUB_CREATED=0
if [ ! -f "$SUB_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB_BACKLOG"
  SUB_CREATED=1
fi

# Delegate the move to tasks-axi. Passing the whole in-scope set to one call is a
# single atomic transaction, so a connected set (blocker + dependents) moves
# together and, on any failure, neither backlog's content changes - the only
# cleanup is a scaffold we just created. tasks-axi writes both its success and
# error output to stdout, so capture it and surface it only on failure.
if ! MV_OUT=$(tasks-axi mv "${TO_MOVE[@]}" --file "$MAIN_BACKLOG" --to "$SUB_BACKLOG" 2>&1); then
  if [ "$SUB_CREATED" -eq 1 ]; then
    rm -f "$SUB_BACKLOG"
  fi
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  echo "error: tasks-axi mv failed; nothing was moved." >&2
  exit 1
fi

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $SUB_BACKLOG"
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
warn_stale_public_commitments "$ID" "${TO_MOVE[@]}"
# The move has landed, so record the card before consuming: a crash between
# here and the board leaves a statement the next handoff to this secondmate
# completes, the local twin of the remote outbox's own recovery.
with_handoff_card_lock "$ID" record_and_sweep_card_pairs "$ID" "${TO_MOVE[0]}" "$CARD_ARG"
