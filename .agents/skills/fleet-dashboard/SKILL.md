---
name: fleet-dashboard
description: >-
  Agent-only reference for the Admiral's Fleet Dashboard, the task board that replaced the Lavish status page.
  Use before adding a card, changing a card's status/agent/title/captain, adding a link or a note to one of its tabs, or starring it.
  Use on every fleet-auditor sweep, to read the board's claimed state and to record what the sweep found.
  Whether working as firstmate directly or as a crewmate or secondmate briefed on dashboard-facing work.
user-invocable: false
metadata:
  internal: true
---

# fleet-dashboard

The dashboard is a purpose-built task board for the Admiral, not a mirror of any backlog.
It owns its own persistent records; nothing here is scraped or generated from `data/backlog.md`.
A card exists on it only because something explicitly put it there through `bin/fm-dashboard.sh` (or the HTTP API it wraps) - see `docs/dashboard.md` for the full architecture and the drift-risk that choice implies.

**Agents never touch `bin/fleet-dashboard/web/` or the database directly.**
Every change goes through `bin/fm-dashboard.sh`, which is deliberately one command per action.
A command that needs three round-trips to record one update gets skipped under time pressure, and the board rots exactly like the duplicate backlog that once hid the Admiral's largest project from him.
Run `bin/fm-dashboard.sh --help` for the exact current flag syntax; this skill is about *when* and *why*, not a second copy of that syntax.

## Before you can talk to the board

The server has to be running and reachable.
`bin/fm-dashboard.sh server-status` tells you both the process state and whether the API answers.
If it is down and you are the one responsible for this home's dashboard, `bin/fm-dashboard.sh start` brings it up; otherwise treat an unreachable board the same way the board's own UI does - loudly, not as "nothing to report."
If you are on a secondmate host, the board lives on the primary; point `config/dashboard-url` (or `$FM_DASHBOARD_URL`) at the primary's reachable address rather than assuming localhost.

## Putting a task up

Use `add` the moment a task is received and belongs on the board - this is what "you put it up on the dashboard" means in the Admiral's own words.
Always pass `--prompt` (or `--prompt-file`) with his own words, unedited: that becomes the card's first tab and must never be paraphrased.
`--captain` takes whoever is actually driving the work; `bin/fm-dashboard.sh captains` lists the valid ids and their shorthands, and is the only place to look - the set is not restated here or anywhere else in prose, so it cannot go stale.
New cards default to `not_started`; only set `--status` explicitly if work is already under way.
Starting a card at `needs-attention` needs `--reason` too, same rule and same server-side guard as changing to it later (see "The eight statuses" below).

When the task you are about to spawn is the thing that serves an existing card, pass `--card <card-id>` to `bin/fm-spawn.sh` instead of following up with `ref`/`agent`/`status` calls by hand: the spawn links the card's `backlog_ref`/`agent` to the task id and advances it to `working` itself, and `bin/fm-teardown.sh` later advances it to `review` from that same recorded identity once the task actually lands - see `review` under "The eight statuses" below if that landing leaves a step that is his. When you are instead handing the serving work off to a secondmate, pass that same `--card <card-id>` to `bin/fm-backlog-handoff.sh` for the one item being handed off - it links the card the same best-effort way, keyed to the secondmate rather than a task id that does not exist yet. See `docs/dashboard.md` "The mechanical card link" for both. Reach for the manual `ref`/`agent`/`status` calls below only for a card whose serving work was never spawned or handed off with `--card` (already under way before this existed, or run by hand outside those scripts).

## The eight statuses

Use exactly these, never a synonym, so the board's filters and the auditor's checks stay meaningful.

`needs-attention` and `review` are easy to conflate and are opposite in the one way that matters: **`review` is optional to him; `needs-attention` is blocking on him.**
The deciding question is not how finished the work is, it is **whose the next step is.**
If the next step is his - a decision, an answer, an approval, a physical act, a print, a test-fit, a measurement, anything only he can do or judge - the card is `needs-attention`, and `--reason` names that exact action.
If nothing waits on him - he may look or not look, and nothing is lost either way - it is `review`.
Being finished does not settle it on its own: a finished print that still needs him to test-fit it is blocking on him, so it is `needs-attention`, not `review`.
If he never looks at a `review` card, nothing is lost; if he never looks at a `needs-attention` card, the work is stuck.

`testing` and `review` are also easy to conflate, since both put a finished-enough card in front of a reviewer - but the reviewer differs: **`testing` means the fleet is actively exercising the work right now; `review` means the work is done, with nothing left for him to do but look if he feels like it.** A card belongs in `testing` only for as long as a real crew is actually running it - once nothing is live against it, move it on: to `needs-attention` with a `--reason` naming the act when the confirmed-good work still needs something only he can do, to `review` when it needs nothing from him at all, or elsewhere if it failed. Leaving a card in `testing` with no live crew behind it is not a quiet, harmless state the way an unopened `review` card is - see the fleet auditor's sweep below.

- `needs-attention` - the next step is his: a decision, an answer, a physical action, anything only he can supply. Work the fleet has finished still belongs here whenever the remaining step is his - a part to print, a fit to test, a setting to tick - because the thing is not done until he does it. `--reason` is REQUIRED - the server refuses the status change without one - and that text renders directly on the card so he can act without opening it. This is the loudest status on the board and sorts first; do not use it for routine progress or for something an agent could resolve on its own. Test every reason against what he would actually DO on reading it: if the honest answer is "read it" or "know it," it is a report, not an ask, and does not belong here - put the update in a status note instead. The server also mechanically refuses a reason that opens or closes a clause with an obvious report-shaped phrase ("being chased", "in progress", "investigating", and similar - see `bin/fleet-dashboard/server/validation.py`'s `REPORT_SHAPED_PHRASES`), but passing that check is not the same as being a real ask: it is a narrow fixed-phrase guard against carelessness, not a judge of intent, and it will let a report through if it is phrased differently. It also only reads the edges of a clause, so an ordinary noun mid-sentence ("approve the $400 monitoring subscription renewal") is left alone. The fleet auditor's age-based sweep (below) is the check that catches those - it is not replaced by the server guard, and the server guard is not replaced by it.
- `not-started` - received, nothing begun yet.
- `working` - an agent is actively on it right now, not "queued" or "about to start."
- `paused` - the Admiral paused it. Only he pauses a task; do not set this because a crew went idle for another reason - that is a stalled task, not a paused one, and belongs in a status update or the auditor's discrepancy log instead.
- `waiting` - started, then blocked on something else. Pass `--waiting-on <other-id>` whenever the blocker is itself a card on this board, so the card gets the button linking to it. Use `--reason` even when there is no target card.
- `testing` - the fleet is actively testing this right now: a real agent or crew session is exercising it, not merely claiming to. This is work in flight rather than a finished result - which of the done statuses the result then belongs in is decided when it lands, not here. A `testing` card with no live crew activity behind it is a genuine discrepancy, the same way a stale `working` card is.
- `review` - done, with nothing left for him to do but look if he feels like it. He marks it complete from here; you do not preemptively flip it to complete on his behalf. Optional to him by design - if he never opens it, nothing is lost. If there is something he must actually do before this is finished, it is not a `review` card however complete the fleet's own part is. `bin/fm-teardown.sh` advances a card here on its own once the work lands (see `docs/dashboard.md` "The mechanical card link"); if that landing leaves a next step that is his, move the card to `needs-attention` with a `--reason` naming that step rather than leaving it sitting here. That advance clears the card's own `needs-attention` reason, but what he was originally asked is not lost: teardown passes the held text back as the transition's status-history note, so read it with `bin/fm-dashboard.sh show <id> --json` (`status_history[].note`) instead of re-deriving it. That recovery holds for a card the teardown advance moved, since it carries the live reason column forward into the note; it does not hold for a card created straight into `needs-attention` and later moved by an ordinary `status` call carrying no `--reason` of its own, whose first history note is the literal string `created` and whose reason column that write nulls - there the ask survives nowhere, and finding nothing is that known gap rather than a mistake of yours.
- `complete` - done and approved by him. Reopening (his action, from the card) returns it to `not_started`, not back to `working` - work has to actually resume before it is `working` again.

## The four tabs

Every `note` call names a `--tab`: `interpretation`, `communication`, or `needs`.
The prompt is not a tab you write to - it is set once at `add` time.

- **Interpretation**: your read on what he meant, only when you genuinely have one worth recording. Do not add an interpretation note just to fill the tab - an empty tab is the correct, honest state when there is nothing to add, and the board renders that calmly rather than as a problem.
- **Communication**: the ongoing back-and-forth about this specific task. He can also post here directly from the card; read it before assuming he has not responded.
- **Needs**: a succinct list of what you need from him, with a link wherever there is one. This is also where a file or a build goes up for his review - attach it as a link here (or via the `link` shorthand), not by writing a path or "see the PR" into the text.

## Links: how he receives anything to review

`bin/fm-dashboard.sh link <id> --url <url> [--label <text>]` is how the fleet sends the Admiral something to look at.
The server rejects (400) any link that is not a full `http(s)://` URL, any link whose host is local-only and will not resolve on his phone, and **any GitHub or pull-request link at all** - standing order 17, enforced structurally so it cannot slip through as a copy-paste habit.
If a link is rejected, that is not a bug to route around - find or make a URL that actually opens on his phone and report the outcome in words if nothing else exists yet.

## Reading the board

`list` (optionally `--status`, `--captain`, `--starred`, `--sort`) and `show <id>` are read-only and safe to call as often as you need.
Add `--json` to either for machine-readable output when scripting a sweep.

## The fleet auditor's sweep

If you are the fleet auditor (or standing in for it), your job every cycle is to check the board's claims against live reality, not to trust the board's own text:

1. `bin/fm-dashboard.sh list --status working --json` - for each, confirm a real agent is actually on it (live crew/session state, not the card's own say-so). Anything claiming `working` with no corroborating live activity is a genuine discrepancy.
2. `bin/fm-dashboard.sh list --status testing --json` - the same check as `working`: confirm a real agent or crew session is actually exercising it right now. `testing` is not inert the way `review` is, so a card claiming `testing` with no corroborating live activity is a genuine discrepancy too.
3. `bin/fm-dashboard.sh list --status waiting --json` - confirm the blocker is still real. If a `waiting_on_id` card is already `complete`, or the external condition it names has cleared, that is a discrepancy: the card is stale, not honestly waiting.
4. `bin/fm-dashboard.sh list --status paused --json` - confirm each is still genuinely paused by the Admiral's own word, not just quiet. If one has been unpaused, confirm it is *actually being worked* - an unpaused-but-idle task is exactly the failure this check exists to catch.
5. `bin/fm-dashboard.sh list --status needs-attention --json` - check each `needs_attention` card's own `show <id>` for how long it has actually sat in that status (its status history has the timestamp it last changed to `needs_attention`). **Age itself is the finding here, asymmetrically with every other status**: a `needs-attention` card that has sat for hours with no reply from him means he was not asked clearly, or the ask never reached him - log it even when the card's claim is otherwise accurate. A `review` card sitting for the same length of time is not a discrepancy at all - `review` is optional to him by design, so its age proves nothing. Do not apply this age check to any status but `needs-attention`. Separately, read the reason itself and judge whether it is a genuine ask by the same "what would he DO" test from the statuses section above - the server's mechanical guard only catches a fixed list of report-shaped phrases, so a reason that dodges that list but still only reports progress will reach the board unflagged; log it here as a discrepancy the way you would any other false claim, since this judgment call is exactly what the mechanical guard cannot make and does not replace.
6. `bin/fm-dashboard.sh list --status not-started --json` - a `not_started` card is not itself suspicious; plenty are legitimately queued, and unlike `needs-attention` above, age is never the signal here - do not flag one for merely sitting a while. The genuine discrepancy is structural: a `waiting` card whose own `waiting_on_id` names this one. That column only ever holds a value while the referencing card is itself `waiting`, so it is a live thread of work that has already said, in the board's own data, that it cannot proceed without this card - yet nothing has begun on it. Flag it on the not-started card itself (its claim of "nothing begun" is the one that is wrong), not on the waiting card (its claim of "blocked on this" is accurate). A not-started card nothing currently names this way is not a discrepancy - same silence rule as point 8 below. Say it once, not once per sweep:
   - **When to stay quiet.** If the log already carries *this* finding for that card - one that names it as not started while something waits on it - dated at or after the later of the waiting card's last move into `waiting` and the card's own last move out of `not_started`, it has already been reported, so stay quiet, the same way point 5 stops re-flagging a `needs-attention` card once he has answered it.
   - **When it speaks again.** It speaks again when the block clears, repoints, or the card is started and then abandoned back to `not_started` - that last one is a fresh occurrence, not the old one still running.
   - **Quiet is never clean.** Holding the text back is never the same as saying the board is clean: an outstanding block still counts toward the run you record in point 9, on every sweep, for as long as it stands.
   - **Two cards waiting on one.** Two cards waiting on the same one is a single finding within a sweep; if the second one starts waiting later, it can raise its own entry once before both settle quiet, which is self-limiting rather than a guarantee of exactly one entry forever.
   - **What is not this finding.** A finding some *other* check raised about the same card is not this one and must never silence it - a card can be put back to `not_started` from any status, and it carries its old findings with it.
   - **Why it is said once.** This one legitimately persists for days, and a finding that repeats every cycle buries every other finding in the log, which is the same always-red failure point 8 guards against.
7. For anything you log as a discrepancy, use `bin/fm-dashboard.sh audit-log <id> "<what you found>"`. Be concrete: state what the card claims and what you actually observed, so firstmate can act without re-deriving it. If a live/manual sweep re-checks the same standing condition across multiple passes (a cross-home verification you repeat, for example), pass the same `--key` each time so it collapses into one updated row instead of repeating point 6's not-started problem for a check outside this script - see `bin/fm-dashboard.sh audit-log`'s own help for the exact contract.
8. If you cannot verify a card at all (no linked reference, no way to check from where you sit), that is **not** a discrepancy - do not log it as one. Silence on an unverifiable card is correct; a false "wrong" trains the Admiral to ignore the log exactly the way an always-red marker already has once.
9. When the sweep finishes, always call `bin/fm-dashboard.sh audit-run --duration-seconds <n> --checked <n> --discrepancies <n>`, even when nothing was wrong. This is what lets the page show "clean" as a real, timed answer instead of an absence.
10. If the sweep itself fails partway (a source you needed was unreadable, a check errored out), log that with `--kind error` via `audit-log --fleet "<what broke>"` rather than silently posting a shorter, quieter run. A failed check must never look identical to a clean one.
11. Read the current cadence with `bin/fm-dashboard.sh audit-interval get` at the start of each cycle rather than assuming the last-known value; the Admiral can change it from the page at any time.

The routine, on-interval cadence above runs on its own now, on a host timer, whether or not any agent is present to remember it - see `docs/dashboard.md` "The timer". Doing a live sweep by hand is still the right move for the judgment calls that timer cannot make mechanically (cross-home `working`/`testing` verification, whether a paused card is still genuinely paused), or when the Admiral asks for one directly; record it through the same `audit-log`/`audit-run` commands either way.

## What not to do

- Do not write to `bin/fleet-dashboard/web/*` or the SQLite file to "fix" a card faster - that is exactly the bypass this skill and the API exist to prevent.
- Do not invent an interpretation, a need, or a communication entry that did not happen, to make a tab look complete.
- Do not report a status the underlying work does not actually match, even briefly "to keep the board tidy."
- Do not treat the dashboard as a second backlog to keep in sync by hand across two systems - if you are duplicating backlog content onto a card, stop and read `docs/dashboard.md`'s "Why the board owns its own records" section first.
