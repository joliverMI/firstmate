#!/usr/bin/env bash
# fm-status-board.sh - render-from-state web status board.
#
# Prints one self-contained HTML page to stdout with five sections, in this
# fixed order: Needs you to continue, Ready for you to look at, In progress,
# Waiting, Recently completed. "Ready for you to look at" sits second because
# it is the captain's own no-action-required-yet, worth-a-glance queue: less
# urgent than something that needs his word, but more worth surfacing than
# passive in-progress/waiting rows or aged Recently completed history.
# Each item is a bullet, expandable (native <details>) to its full detail.
#
# "Ready for you to look at" is deliberately NOT "landed" (merged): a merged
# change is not necessarily deployed or usable yet (self-update propagation,
# a redeploy, a service restart), and this board cannot observe any of that.
# It renders an item here ONLY when a landed backlog row's free-form body
# text (the indented note under the row, same "texture" already shown in the
# expandable detail) starts with the literal marker "ready:" (case-insensitive),
# e.g. "ready: the new tab on the home screen". Firstmate writes that note by
# hand, once it has actually confirmed the change is live and knows where the
# captain would look for it - the marker is a positive assertion, never
# inferred from merge/landed state alone. The text after the marker becomes
# the item's "where to see it" and is shown as-is; a landed row with no
# marker keeps showing only under Recently completed, same as today.
#
# A report (data/<id>/report.md) lives only in this repo's checkout today -
# there is no passive web route that maps that path to a URL. Lavish (the
# tool that already renders this repo's other rich pages for the phone) is a
# publish-one-artifact-at-a-time surface, not a static file server: it has no
# formula that would turn a report path into a working link on its own. So a
# report follows the exact same convention as "ready:" above: a backlog body
# line starting with the literal marker "report-url:" (case-insensitive)
# records the https URL firstmate got back after explicitly publishing that
# report (e.g. via lavish-axi) - a positive assertion, never guessed from the
# path. Present and a genuine https URL, it renders as a real link; absent,
# malformed, or a localhost address, the board says plainly that no link
# exists yet rather than naming the unreachable file path.
#
# Every pointer on this page is a real tappable link or an honest "not
# reachable from your phone" statement, never a bare repo path, local file
# path, or GitHub/pull-request URL:
#   - A pull request is never linked, in any section. The captain does not
#     review PRs from this page; a "READY TO MERGE" row states the outcome
#     (title, reason) so he can approve by word instead of opening GitHub.
#   - A report links only when its backlog note carries a "report-url:"
#     marker (above); otherwise it says plainly that no link exists rather
#     than naming the file path.
#   - A Ready item's "where to see it" text is replaced with an honest
#     placeholder when it looks like a filesystem path or a github.com/
#     pull-request URL, so a hand-written note can never hand the captain
#     an unreachable location.
#   - A cross-home (secondmate) item's expandable detail says plainly that
#     fuller text is not reachable from this page, instead of naming a home
#     record he cannot open.
#   - An in-progress row prefers the fuller "current state" text over the
#     shortened one-line summary, so its own expander is never a dead end.
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
#     title, full free-form backlog note, report path, completion date) for
#     the expandable panel. Cross-home detail stays bounded by whatever that
#     home's own structured summary already carries; the "What this board
#     cannot show" section on the page says so explicitly.
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
# Read-only: makes no GitHub/network call of its own and mutates no state. It
# never publishes a report itself (that would be a side effect this command
# does not have); "report-url:" above is only ever read, never written, here.
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
  sed -n '2,96p' "$0" | sed 's/^# \{0,1\}//'
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

def unreachable_text:
  type == "string" and (
    test("^/\\S") or
    test("^(data|projects)/") or
    test("github\\.com"; "i") or
    test("gitlab\\.com"; "i") or
    test("/pull/[0-9]"; "i") or
    test("/merge_requests/[0-9]"; "i")
  );

def ready_pointer($d):
  (($d.body_lines // []) | join(" ")) as $body
  | if ($body | ascii_downcase | startswith("ready:"))
    then ($body[6:] | sub("^[ \t]+"; ""))
    else null end;

def report_url_pointer($lines):
  ($lines // []) | map(select(ascii_downcase | startswith("report-url:")))
  | if length > 0 then (.[0][11:] | sub("^[ \t]+"; "")) else null end;

def valid_https_url:
  type == "string"
  and test("^https://"; "i")
  and (test("localhost"; "i") | not)
  and (test("127\\.0\\.0\\.1") | not)
  and (test("0\\.0\\.0\\.0") | not);

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
          report_path: ($b.report_path // null),
          report_url: report_url_pointer($b.body_lines // []),
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
          report_path: null, report_url: null, local_note: null, repo: null,
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
          report_path: ($d.report_path // null),
          report_url: null,
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

def report_row($path; $url):
  if ($path == null or $path == "") and ($url == null or $url == "") then empty
  else
    (if ($url | valid_https_url) then ($url | link_html)
     else "<span class=\"unreachable\">Not reachable from your phone yet - no web link exists for it.</span>"
     end) as $value
    | "<div class=\"kv\"><span>Report</span> " + $value + "</div>"
  end;

def detail_block($owner; $d):
  [
    (if $d.repo or $d.kind then "<div class=\"kv\"><span>Repo/kind</span> \((($d.repo // "-") | esc)) / \((($d.kind // "-") | esc))</div>" else empty end),
    (if $d.hold_reason then "<div class=\"kv\"><span>Reason</span> \($d.hold_reason | esc)</div>" else empty end),
    (if $d.blocked_reason and $d.blocked_reason != $d.hold_reason then "<div class=\"kv\"><span>Blocked on</span> \($d.blocked_reason | esc)</div>" else empty end),
    (if $d.current_detail then "<div class=\"kv\"><span>Current state</span> \($d.current_detail | esc)</div>" else empty end),
    (if ($d.active_children // [] | length) > 0 then
       "<div class=\"kv\"><span>Active work</span> " + (($d.active_children | map(esc) | join("; "))) + "</div>"
     else empty end),
    report_row($d.report_path; $d.report_url),
    (if $d.local_note then "<div class=\"kv\"><span>Note</span> \($d.local_note | esc)</div>" else empty end),
    (if $d.completion_date then "<div class=\"kv\"><span>Completed</span> \($d.completion_date | esc)</div>" else empty end),
    (($d.body_lines // []) | if length > 0 then
       "<div class=\"texture\">" + (map("<p>" + esc + "</p>") | join("")) + "</div>"
     else empty end),
    (if $d.bounded and $owner != "(main)" then "<div class=\"bound\">This is a shortened summary from the " + ($owner | esc) + " team. The rest is not reachable from this page - there is no phone-openable link for it yet.</div>" else empty end)
  ] | map(select(. != null)) | join("");

def detail_block_ready($owner; $d):
  [
    (if $d.repo or $d.kind then "<div class=\"kv\"><span>Repo/kind</span> \((($d.repo // "-") | esc)) / \((($d.kind // "-") | esc))</div>" else empty end),
    (if $d.completion_date then "<div class=\"kv\"><span>Landed</span> \($d.completion_date | esc)</div>" else empty end),
    (if $d.bounded and $owner != "(main)" then "<div class=\"bound\">This is a shortened summary from the " + ($owner | esc) + " team. The rest is not reachable from this page - there is no phone-openable link for it yet.</div>" else empty end)
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
| ([$completed_all[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}]) as $completed_all_d
| ([$completed_all_d[] | ready_pointer(.detail) as $rp | select($rp != null and $rp != "") | . + {ready_pointer: $rp}]) as $ready_all
| (reduce $needs_captain_all[] as $it ({}; .[$it.id] = true)) as $seen1
| ([$ready_all[] | select(($seen1[.id] // false) | not)]) as $ready
| (reduce $ready[] as $it ($seen1; .[$it.id] = true)) as $seen1r
| ([$in_progress_all[] | select(($seen1r[.id] // false) | not)]) as $in_progress_dd
| (reduce $in_progress_dd[] as $it ($seen1r; .[$it.id] = true)) as $seen2
| ([$waiting_all[] | select(($seen2[.id] // false) | not)]) as $waiting_dd
| (reduce $waiting_dd[] as $it ($seen2; .[$it.id] = true)) as $seen3
| ([$completed_all_d[] | select(($seen3[.id] // false) | not)]) as $completed
| [$needs_captain_all[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $needs_captain
| [$in_progress_dd[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $in_progress
| [$waiting_dd[] | . + {owner: owner_of(.), detail: detail_for($main_backlog; $main_tasks; $mates; .)}] as $waiting
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

section_html("ready"; "Ready for you to look at";
  "Nothing is ready for you to look at right now.";
  $ready;
  (. as $it | ($it.owner | owner_label) as $ownerlabel
   | (if ($it.ready_pointer | unreachable_text)
      then "Not phone-reachable - this pointer looks like a file path or pull-request link. Ask your first mate."
      else $it.ready_pointer end) as $where
   | ("<b>" + ($ownerlabel|esc) + "</b> " + (($it.detail.title // $it.what // $it.id) | esc)
      + " &mdash; " + ($where | esc)) as $bullet
   | item_html("ready"; $bullet; detail_block_ready($it.owner; $it.detail)))),

section_html("in-progress"; "In progress";
  "Nothing is in progress right now.";
  $in_progress;
  (. as $it | ($it.owner | owner_label) as $ownerlabel
   | ($it.detail.current_detail // $it.doing) as $doing_text
   | ("<b>" + ($ownerlabel|esc) + "</b> " + (($it.detail.title // $it.doing // $it.id) | esc)
      + (if $doing_text then " &mdash; " + ($doing_text | esc) else "" end)) as $bullet
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
    "Detail for a secondmate-owned item is bounded by what its cross-home summary carries; fuller texture lives directly in that home, not reachable from this page.",
    "Ready for you to look at only shows a landed change once firstmate has explicitly confirmed it is deployed and recorded where to find it; a merged change with no such confirmation still only shows up under Recently completed, never here.",
    "Pull requests and GitHub links are never shown on this page; a ready-to-merge row states the outcome so you can approve by word instead of opening GitHub.",
    "A report links only when its backlog note carries an explicit report-url: marker firstmate wrote after actually publishing it; without one it says plainly that no link exists rather than naming a file path.",
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
:root{color-scheme:light dark;--bg:#0d0d0f;--surface:#17171a;--border:#2c2c30;--text:#e7e7ea;--muted:#9a9aa2;--accent:#7aa2ff;--red:#e5636b;--amber:#e0a940;--blue:#5b8cff;--green:#3fbf72;--purple:#b98eff;}
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
details.item.ready{border-left-color:var(--purple)}
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
.unreachable{font-style:italic}
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
