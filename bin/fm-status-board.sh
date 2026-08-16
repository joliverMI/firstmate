#!/usr/bin/env bash
# fm-status-board.sh - render-from-state web status board.
#
# Prints one self-contained HTML page to stdout with four sections, in this
# fixed order: Needs you to continue, In progress, Waiting, Recently completed.
# Each item is a bullet, expandable (native <details>) to its full detail.
#
# This command intentionally does not maintain its own store. It reads two
# existing read-only structured sources and renders them:
#   - fm-bearings-snapshot.sh --json owns the four-bucket classification
#     (which decisions are captain-actionable, which work is active, which
#     queued item is genuinely waiting, what recently landed) across the main
#     fleet AND every registered secondmate home, local and remote. This
#     command does not reclassify state a second time; it consumes bearings'
#     buckets as authoritative and only maps them onto this page's section
#     order and labels.
#   - fm-fleet-snapshot.sh --json supplies untruncated per-item detail (full
#     title, full free-form backlog note, PR url, report path, completion
#     date) for the expandable panel. Cross-home detail stays bounded by
#     whatever that home's own structured summary already carries; the "What
#     this board cannot show" section on the page says so explicitly.
# Both are fetched read-only and independently; see docs in this repo on
# fm-bearings-snapshot.sh and fm-fleet-snapshot.sh for their own contracts.
#
# An id that both bearings' own live task state and a not-yet-updated backlog
# row disagree about (a known eventual-consistency gap, not a bug here) is
# shown once: the earlier section in the fixed order above wins and later
# duplicates of the same id are dropped, so a stale "Queued" row never doubles
# a task that is already visibly working.
#
# A task whose current run-step is terminal ("done" in fm-crew-state.sh's
# vocabulary - checks passed, not yet merged or torn down) is treated as
# "needs you to continue" (ready to merge), not "in progress": AGENTS.md hard
# rule 2 means a green PR always waits on the captain's word, never on a
# worker.
#
# Read-only: makes no GitHub/network call of its own and mutates no state.
# fm-bearings-snapshot.sh's own away-mode return catch-up guard applies here
# too, since this command surfaces the same captain-facing state.
#
# Usage:
#   fm-status-board.sh           print the HTML page to stdout
#   fm-status-board.sh --json    print the two source snapshots this page was
#                                 built from ({bearings, fleet}), for debugging
#   fm-status-board.sh --help    usage
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEARINGS="$SCRIPT_DIR/fm-bearings-snapshot.sh"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

FORMAT=html
case "${1:-}" in
  --json) FORMAT=json ;;
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-status-board: jq not found" >&2; exit 1; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

BEARINGS_JSON=$(FM_BEARINGS_NOW="$NOW" "$BEARINGS" --json \
  --all-in-flight --all-decisions --all-queued --all-landed --all-secondmates \
  --fields bodies,paths,actions,endpoints) || exit $?
FLEET_JSON=$(FM_SNAPSHOT_NOW="$NOW" "$FLEET" --json) || exit $?

if [ "$FORMAT" = json ]; then
  jq -n --argjson bearings "$BEARINGS_JSON" --argjson fleet "$FLEET_JSON" \
    '{bearings:$bearings,fleet:$fleet}'
  exit 0
fi

BODY=$(printf '%s' "$BEARINGS_JSON" | jq -r --argjson fleet "$FLEET_JSON" '
def esc:
  if . == null then "" else
    tostring
    | gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;")
  end;

def esc_attr: esc | gsub("\""; "&quot;");

def owner_label:
  if . == "(main)" then "main fleet" else . end;

def owner_of($item):
  if ($item.owner != null) then $item.owner
  elif ($item.kind == "secondmate") then $item.id
  else "(main)" end;

def strip_owner_prefix($owner; $raw_id):
  ($owner + "/") as $pfx
  | if ($raw_id | .[0:($pfx | length)]) == $pfx
    then $raw_id[($pfx | length):]
    else $raw_id end;

def mate_detail($mates; $owner; $child):
  ($mates[$owner] // {}) as $m
  | ([$m.decisions_open[]?, $m.holds[]?, $m.queued[]?, $m.landed[]?]
     | map(select(.id == $child))) as $cands
  | reduce $cands[] as $c ({}; . * $c);

def detail_for($main_backlog; $main_tasks; $mates; $item):
  owner_of($item) as $owner
  | if $owner == "(main)" then
      ($main_backlog[$item.id] // {}) as $b
      | ($main_tasks[$item.id] // {}) as $t
      | {
          title: ($b.title // $item.title // $item.doing // null),
          hold_reason: ($b.hold_reason // null),
          blocked_reason: ($b.blocked_reason // null),
          body_lines: ($b.body_lines // []),
          pr_url: ($b.pr_url // null),
          report_path: ($b.report_path // null),
          local_note: ($b.local_note // null),
          repo: ($b.repo // null),
          kind: ($b.kind // $item.kind // null),
          completion_date: ($b.completion.date // null),
          current_detail: ($t.current_state.detail // null),
          active_children: null,
          bounded: false
        }
    elif $item.kind == "secondmate" then
      ($mates[$item.id] // {}) as $m
      | {
          title: null, hold_reason: null, blocked_reason: null, body_lines: [],
          pr_url: null, report_path: null, local_note: null, repo: null,
          kind: "secondmate", completion_date: null, current_detail: null,
          active_children: ($m.active_children // []), bounded: true
        }
    else
      strip_owner_prefix($owner; $item.id) as $child
      | mate_detail($mates; $owner; $child) as $d
      | {
          title: ($d.title // $item.title // $item.summary // null),
          hold_reason: ($d.hold_reason // null),
          blocked_reason: ($d.blocked_reason // $d.reason // null),
          body_lines: [],
          pr_url: ($d.pr_url // null),
          report_path: ($d.report_path // null),
          local_note: ($d.local_note // null),
          repo: ($d.repo // null),
          kind: ($d.kind // null),
          completion_date: ($d.completion.date // null),
          current_detail: null,
          active_children: null,
          bounded: true
        }
    end;

def link_html:
  if . == null or . == "" then empty
  else "<a class=\"link\" href=\"\(esc_attr)\" target=\"_blank\" rel=\"noopener noreferrer\">\(esc)</a>" end;

def detail_block($owner; $d):
  [
    (if $d.repo or $d.kind then "<div class=\"kv\"><span>Repo/kind</span> \((($d.repo // "-") | esc)) / \((($d.kind // "-") | esc))</div>" else empty end),
    (if $d.hold_reason then "<div class=\"kv\"><span>Reason</span> \($d.hold_reason | esc)</div>" else empty end),
    (if $d.blocked_reason and $d.blocked_reason != $d.hold_reason then "<div class=\"kv\"><span>Blocked on</span> \($d.blocked_reason | esc)</div>" else empty end),
    (if $d.current_detail then "<div class=\"kv\"><span>Current state</span> \($d.current_detail | esc)</div>" else empty end),
    (if ($d.active_children // [] | length) > 0 then
       "<div class=\"kv\"><span>Active work</span> " + (($d.active_children | map(esc) | join("; "))) + "</div>"
     else empty end),
    (if $d.pr_url then "<div class=\"kv\"><span>PR</span> " + ($d.pr_url | link_html) + "</div>" else empty end),
    (if $d.report_path then "<div class=\"kv\"><span>Report</span> <code>\($d.report_path | esc)</code></div>" else empty end),
    (if $d.local_note then "<div class=\"kv\"><span>Note</span> \($d.local_note | esc)</div>" else empty end),
    (if $d.completion_date then "<div class=\"kv\"><span>Completed</span> \($d.completion_date | esc)</div>" else empty end),
    (($d.body_lines // []) | if length > 0 then
       "<div class=\"texture\">" + (map("<p>" + esc + "</p>") | join("")) + "</div>"
     else empty end),
    (if $d.bounded and $owner != "(main)" then "<div class=\"bound\">Fuller detail lives in the " + ($owner | esc) + " home record; this cross-home view is bounded.</div>" else empty end)
  ] | map(select(. != null)) | join("");

def item_html($cls; $bullet; $detail_html):
  "<details class=\"item " + $cls + "\"><summary>" + $bullet + "</summary><div class=\"detail\">" + $detail_html + "</div></details>";

def section_html($id; $label; $empty_sentence; $items; render_item):
  [
    "<section id=\"" + $id + "\">",
    "<h2>" + $label + "</h2>",
    (if ($items | length) == 0 then "<p class=\"empty\">" + $empty_sentence + "</p>"
     else ($items | map(render_item) | join("")) end),
    "</section>"
  ] | join("");

. as $bearings
| ($fleet.backlog.records // []) | map({key:.id, value:.}) | from_entries as $main_backlog
| ($fleet.tasks // []) | map({key:.id, value:.}) | from_entries as $main_tasks
| ($fleet.secondmate_current.records // []) | map({key:.id, value:.}) | from_entries as $mates
| ($bearings.decisions_open // []) as $decisions_raw
| ($bearings.in_flight // []) as $in_flight_raw
| ($bearings.gates // []) as $gates_raw
| ($bearings.landed // []) as $landed_raw
| ([$in_flight_raw[] | select(.state == "done") | . + {reason_kind:"ready_to_merge"}]) as $ready_to_merge
| ($decisions_raw | map(. + {reason_kind:"decision"})) as $decisions_tagged
| ($decisions_tagged + $ready_to_merge) as $needs_captain_all
| ([$in_flight_raw[] | select(.state != "done")]) as $in_progress_all
| $gates_raw as $waiting_all
| $landed_raw as $completed_all
| (reduce $needs_captain_all[] as $it ({}; .[$it.id] = true)) as $seen1
| ([$in_progress_all[] | select(($seen1[.id] // false) | not)]) as $in_progress_dd
| (reduce $in_progress_dd[] as $it ($seen1; .[$it.id] = true)) as $seen2
| ([$waiting_all[] | select(($seen2[.id] // false) | not)]) as $waiting_dd
| (reduce $waiting_dd[] as $it ($seen2; .[$it.id] = true)) as $seen3
| ([$completed_all[] | select(($seen3[.id] // false) | not)]) as $completed_dd
| [$needs_captain_all[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $needs_captain
| [$in_progress_dd[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $in_progress
| [$waiting_dd[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $waiting
| [$completed_dd[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $completed
|
"<h1>Fleet status</h1>",
"<p class=\"meta\">Home: <code>" + ($bearings.home | esc) + "</code> &middot; generated " + ($bearings.generated | esc) + "</p>",

section_html("needs-captain"; "Needs you to continue";
  "Nothing needs your action right now.";
  $needs_captain;
  (. as $it | ($it.owner | owner_label) as $ownerlabel
   | (if $it.reason_kind == "ready_to_merge" then "READY TO MERGE" else "DECISION" end) as $tag
   | ("<span class=\"tag\">" + $tag + "</span> <b>" + ($ownerlabel|esc) + "</b> "
      + (($it.detail.title // $it.summary // $it.id) | esc)
      + (if $it.detail.hold_reason then " &mdash; " + ($it.detail.hold_reason | esc) else "" end)) as $bullet
   | item_html("needs-captain"; $bullet; detail_block($it.owner; $it.detail)))),

section_html("in-progress"; "In progress";
  "Nothing is in progress right now.";
  $in_progress;
  (. as $it | ($it.owner | owner_label) as $ownerlabel
   | ("<b>" + ($ownerlabel|esc) + "</b> " + (($it.detail.title // $it.doing // $it.id) | esc)
      + (if $it.doing then " &mdash; " + ($it.doing | esc) else "" end)) as $bullet
   | item_html("in-progress"; $bullet; detail_block($it.owner; $it.detail)))),

section_html("waiting"; "Waiting";
  "Nothing is waiting right now.";
  $waiting;
  (. as $it | ($it.owner | owner_label) as $ownerlabel
   | ("<b>" + ($ownerlabel|esc) + "</b> " + (($it.detail.title // $it.title // $it.id) | esc)
      + (if $it.detail.hold_reason then " &mdash; " + ($it.detail.hold_reason | esc)
         elif $it.detail.blocked_reason then " &mdash; " + ($it.detail.blocked_reason | esc)
         else "" end)) as $bullet
   | item_html("waiting"; $bullet; detail_block($it.owner; $it.detail)))),

section_html("recently-completed"; "Recently completed";
  "No recent completions are in the current baseline.";
  $completed;
  (. as $it | ($it.owner | owner_label) as $ownerlabel
   | ("<b>" + ($ownerlabel|esc) + "</b> " + (($it.detail.title // $it.what // $it.id) | esc)
      + (if $it.detail.completion_date then " &mdash; " + ($it.detail.completion_date | esc) else "" end)) as $bullet
   | item_html("recently-completed"; $bullet; detail_block($it.owner; $it.detail)))),

(($bearings.omitted // [])
 | map(select(.surface != "full scout-report inventory" and .surface != "live PR discovery + checks"))
 | map(.surface)) as $dynamic_gaps
| ([
    "Ready-to-merge is a local signal only (validation finished on this machine); it is not a live GitHub review or mergeability check.",
    "A needed credential or login has no distinct marker here; if one is stuck on that, it shows up as an ordinary waiting or in-progress item with whatever reason was recorded.",
    "Detail for a secondmate-owned item is bounded by what its cross-home summary carries; fuller texture lives directly in that home.",
    "This is a snapshot as of the generated time above; it does not update itself, so re-run the command for a fresh read."
  ] + $dynamic_gaps) as $gaps
|
"<section id=\"cannot-show\"><h2>What this board cannot show</h2><ul>"
  + ($gaps | map("<li>" + esc + "</li>") | join(""))
  + "</ul></section>"
') || exit $?

cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fleet status</title>
<style>
:root{color-scheme:light dark;--bg:#0d0d0f;--surface:#17171a;--border:#2c2c30;--text:#e7e7ea;--muted:#9a9aa2;--accent:#7aa2ff;--red:#e5636b;--amber:#e0a940;--blue:#5b8cff;--green:#3fbf72;}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-size:15px;line-height:1.5;margin:0;padding:24px 16px 64px}
.wrap{max-width:880px;margin:0 auto}
h1{font-size:24px;margin:0 0 4px}
.meta{color:var(--muted);font-size:13px;margin:0 0 28px}
.meta code{color:var(--text)}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:32px 0 10px;display:flex;align-items:center;gap:8px}
h2::after{content:"";flex:1;height:1px;background:var(--border)}
section{margin-bottom:8px}
.empty{color:var(--muted);font-size:14px;margin:6px 0 18px}
details.item{background:var(--surface);border:1px solid var(--border);border-left:3px solid var(--border);border-radius:6px;padding:10px 14px;margin-bottom:8px}
details.item.needs-captain{border-left-color:var(--red)}
details.item.in-progress{border-left-color:var(--blue)}
details.item.waiting{border-left-color:var(--amber)}
details.item.recently-completed{border-left-color:var(--green)}
summary{cursor:pointer;font-size:14.5px}
summary::marker{color:var(--muted)}
.tag{font-size:10px;font-weight:700;letter-spacing:.05em;padding:1px 6px;border-radius:99px;border:1px solid var(--red);color:var(--red);margin-right:4px}
.detail{margin-top:10px;padding-top:10px;border-top:1px solid var(--border);font-size:13.5px;color:var(--muted)}
.kv{margin:4px 0}
.kv span{color:var(--text);font-weight:600;margin-right:4px}
.texture p{margin:8px 0;color:var(--text)}
.bound{margin-top:8px;font-style:italic;font-size:12.5px}
.link{color:var(--accent)}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px}
#cannot-show{margin-top:36px}
#cannot-show ul{margin:6px 0 0;padding-left:20px;color:var(--muted);font-size:13px}
#cannot-show li{margin:4px 0}
</style>
</head>
<body>
<div class="wrap">
$BODY
</div>
</body>
</html>
HTML
