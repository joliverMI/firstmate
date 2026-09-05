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
Starting a card at `needs-action` needs `--reason` too, and starting one at `needs-review` needs `--plan`, same rules and same server-side guards as changing to them later (see "The nine statuses" below).

When the task you are about to spawn is the thing that serves an existing card, pass `--card <card-id>` to `bin/fm-spawn.sh` instead of following up with `ref`/`agent`/`status` calls by hand: the spawn links the card's `backlog_ref`/`agent` to the task id and advances it to `working` itself, and `bin/fm-teardown.sh` later advances it to `review` from that same recorded identity once the task actually lands - see `review` under "The nine statuses" below if that landing leaves a step that is his. When you are instead handing the serving work off to a secondmate, pass that same `--card <card-id>` to `bin/fm-backlog-handoff.sh` for the one item being handed off - it links the card the same best-effort way, keyed to the secondmate rather than a task id that does not exist yet. See `docs/dashboard.md` "The mechanical card link" for both. Reach for the manual `ref`/`agent`/`status` calls below only for a card whose serving work was never spawned or handed off with `--card` (already under way before this existed, or run by hand outside those scripts).

## The nine statuses

Use exactly these, never a synonym, so the board's filters and the auditor's checks stay meaningful.

`needs-action` and `needs-review` are the two statuses that mean the Admiral himself is the next step, and they split what used to be one status called `needs-attention`.
The deciding question for reaching either of them is not how finished the work is, it is **whose the next step is.**
If nothing waits on him - he may look or not look, and nothing is lost either way - it is `review`.
Being finished does not settle it on its own: a finished print that still needs him to test-fit it is blocking on him, so it is one of these two, not `review`.
If he never looks at a `review` card, nothing is lost; if he never looks at a card in either of these, the work is stuck.

Which of the two is then decided by **what the card is asking him for**, in his own words: "the first is for when I need to actually do something, and the second is for when you present me a recommended action you will take and ask for my review."
If it needs him to DO a thing - decide, answer, sign, print, measure, supply a credential, be somewhere - it is `needs-action`, and `--reason` names that exact act.
If the fleet already knows what it wants to do and is asking permission to do it, it is `needs-review`, `--plan` carries the recommendation, and the only thing he does is approve.
The point of separating them is that a card asking permission used to read as a demand.

`needs-action` sorts above `needs-review`, and both sort above everything else.
The order between them is not arbitrary: a `needs-review` card costs him one tap from wherever he happens to be standing, while a `needs-action` card can need him at a machine, at a printer, or at a supplier, so it is the one that genuinely holds work up for longer.
The cheaper ask must not outrank the expensive one.

**`needs-review` and `review` are different statuses and the difference matters more than the one word between them.**
`needs-review` is work that has NOT happened yet and is waiting on his permission.
`review` is work that IS finished, with nothing left for him to do but look if he feels like it.
Approving a `needs-review` card starts something; ignoring a `review` card costs nothing.
The board keeps them apart structurally rather than by wording alone - different colour, its own section, and a plan box with an approve button that only `needs-review` has - and the page deliberately labels `review` "Ready to Close" so no two pills on his phone share a word.

`testing` and `review` are also easy to conflate, since both put a finished-enough card in front of a reviewer - but the reviewer differs: **`testing` means the fleet is actively exercising the work right now; `review` means the work is done, with nothing left for him to do but look if he feels like it.** A card belongs in `testing` only for as long as a real crew is actually running it - once nothing is live against it, move it on: to `needs-action` with a `--reason` naming the act when the confirmed-good work still needs something only he can do, to `needs-review` with a `--plan` when the fleet wants his permission before the next step, to `review` when it needs nothing from him at all, or elsewhere if it failed. Leaving a card in `testing` with no live crew behind it is not a quiet, harmless state the way an unopened `review` card is - see the fleet auditor's sweep below.
The two behave differently in a way worth expecting rather than mistaking for a bug: `testing` is transient and `review` accumulates.
A card passes through `testing` only while a crew is live against it, so that column is routinely empty even on a busy board, while `review` is where finished work rests and is normally the largest column on the board.
An empty `testing` column is therefore not evidence the status is unused or dead.

- `needs-action` - the next step is his and it is a thing he has to do: a decision, an answer, a physical act, a credential, anything only he can supply. Work the fleet has finished still belongs here whenever the remaining step is his - a part to print, a fit to test, a setting to tick - because the thing is not done until he does it. Where such a card goes once he has acted turns on whether anything happens after his act: if work follows from it - he prints the part and measures it and those numbers come back to the fleet - the card goes back to `not_started` until a crew is genuinely on it and to `working` only once one actually is, and completion waits on that result rather than on the act itself; if nothing comes back to us, he completes it himself from where it sits. The board puts its one-tap Mark Complete on a `review` card, so in that second case he reaches `complete` through the card's own status control. `--reason` is REQUIRED - the server refuses the status change without one - and that text renders directly on the card so he can act without opening it. This and `needs-review` are the loudest statuses on the board, and this one sorts first; do not use it for routine progress or for something an agent could resolve on its own. Test every reason against what he would actually DO on reading it: if the honest answer is "read it" or "know it," it is a report, not an ask, and does not belong here - put the update in a status note instead. The server also mechanically refuses a reason that opens or closes a clause with an obvious report-shaped phrase ("being chased", "in progress", "investigating", and similar - see `bin/fleet-dashboard/server/validation.py`'s `REPORT_SHAPED_PHRASES`), but passing that check is not the same as being a real ask: it is a narrow fixed-phrase guard against carelessness, not a judge of intent, and it will let a report through if it is phrased differently. It also only reads the edges of a clause, so an ordinary noun mid-sentence ("approve the $400 monitoring subscription renewal") is left alone. The fleet auditor's sweep (below) is the check that catches those - it is not replaced by the server guard, and the server guard is not replaced by it.
- `needs-review` - the next step is his and it is one word: the fleet has a recommended action it intends to take and is asking him to approve it before acting. `--plan` is REQUIRED and carries that recommendation: the card renders it in its own box with the approve button inside that same box, so what he approves is unmistakably the text he is looking at. The server refuses this status with no plan on both the create and the status path, because an approval box with nothing in it would record his consent to nothing at all. Write the plan as the action you will take, short enough to read on a phone and specific enough that approving it means something - "swap to the other supplier and re-run the fit check", not "proceed as discussed". A plan is not an ask, so the report-shaped-phrase guard deliberately does not apply to it; whether a plan is real and specific is the auditor's judgment, exactly as it is for a `needs-action` reason.
- `not-started` - received, nothing begun yet.
- `working` - an agent is actively on it right now, not "queued" or "about to start."
- `paused` - the Admiral paused it. Only he pauses a task; do not set this because a crew went idle for another reason - that is a stalled task, not a paused one, and belongs in a status update or the auditor's discrepancy log instead.
- `waiting` - started, then blocked on something else. Pass `--waiting-on <other-id>` whenever the blocker is itself a card on this board, so the card gets the button linking to it. Use `--reason` even when there is no target card.
- `testing` - the fleet is actively testing this right now: a real agent or crew session is exercising it, not merely claiming to. This is work in flight rather than a finished result - where the result then belongs is decided when it lands, not here. A `testing` card with no live crew activity behind it is a genuine discrepancy, the same way a stale `working` card is.
- `review` - done, with nothing left for him to do but look if he feels like it. He marks it complete from here; you do not preemptively flip it to complete on his behalf. Optional to him by design - if he never opens it, nothing is lost. If there is something he must actually do before this is finished, it is not a `review` card however complete the fleet's own part is, and this is NOT the status for asking his permission to do something - that is `needs-review`. `bin/fm-teardown.sh` advances a card here on its own once the work lands (see `docs/dashboard.md` "The mechanical card link"); if that landing leaves a next step that is his, move the card to `needs-action` with a `--reason` naming that step, or to `needs-review` with a `--plan` if what is left is his permission rather than his labour, rather than leaving it sitting here. Read the ask he was already holding back out of the card's status history (`bin/fm-dashboard.sh show <id> --json`, `status_history[].note`) rather than re-deriving it; that same docs section states what the advance carries forward and where the ask does not survive at all.
- `complete` - done and approved by him. Reopening (his action, from the card) returns it to `not_started`, not back to `working` - work has to actually resume before it is `working` again.

`needs-attention` no longer exists as a status, but it is still ACCEPTED as an input spelling everywhere a status is read, and always means `needs-action`.
That is deliberate, so an older script or an agent working from an older copy of this file keeps working rather than failing on a rename.
Do not write it in new work, and do not expect to read it back: the board never emits it.
Old `status_history` rows still carry it, because the board really did say that at the time.

## What he approves, and what an approval is worth

The approve button records his consent and does nothing else.
It does not merge, deploy, delete, spend, or start the work - the fleet acts afterwards, under exactly the boundaries it already had.
Never wire an action onto it, and never treat an approval as authority for anything wider than the plan text itself.

An approval is bound to the exact wording it was given for.
The board records that he approved, when, and the verbatim plan as displayed at that moment, and refuses an approval whose text no longer matches the card - so a plan edited between what he read and what he tapped cannot collect his consent.
If the plan is edited afterwards, the approval is NOT carried over: the record of his word survives, but the card, `show`, and `--json` all report it as covering the old wording only, show both texts, and ask him again.
Read `plan_approved`, `plan_approval_stale`, and `plan_approved_text` together before acting on an approval, never `plan_approved` alone.
A stale approval is not permission; it is evidence he was asked something else.

Correct a plan with `bin/fm-dashboard.sh plan <id> <text>` rather than by deleting and re-making the card, so the history of what he was asked stays on one record.
There is deliberately no CLI command that records an approval.
His word is captured only where he himself gives it - the board's own button - and never by an agent on his behalf, however clearly he said it elsewhere.
If he approves a plan in conversation, act on that as you would any other instruction he gives you; do not go and tick his box for him.

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
5. `bin/fm-dashboard.sh list --status needs-action --json` and `--status needs-review --json` - check each card's own `show <id>` for how long he has actually been blocked on it. **Age is the finding here only for an ask he can act on from wherever he happens to be, and that asymmetry holds against every other status**: read the reason or the plan before anything else, because whether he can reach the thing at all from where he stands is the axis - not whether the ask is an answer or an act, not how long the act itself takes, and not which of the two statuses the card carries. Where nothing comes back to us, the card is his to close from where it sits - so he may have done the thing and simply not closed it, and its age is not evidence that he was not asked well. Do not log that one on age.
   This check covers BOTH blocking statuses, because what it is for is that he is the next step, and he is equally the next step either way. Applying it by status name rather than by that reason is how it would quietly switch itself off the moment a status is renamed or split.
   - **The ask he can settle from anywhere.** Except where the lead above excludes it: a decision, an approval, a yes or a no that has instead sat for hours with no reply from him since it was flagged is the case the check is for: nothing but him and a moment was ever needed, so the age really is evidence that it was not put clearly or never reached him at all, and that one is logged even when the card's claim is otherwise accurate. Every `needs-review` card is this kind by construction - the whole status is one tap - so the exclusions below effectively only ever apply to `needs-action`.
   - **What a reply settles, and what it does not.** A reply of his dated after the ask settles the reached-him half on its own, whatever the card's status still says, so stop flagging the card on age alone - but read the reply before concluding the ask was clear, since a reply asking what was meant is evidence that it was not, and log that one as an ask that was not put clearly, on the evidence of the reply rather than on age. And when the reply settles the ask outright and work follows from it, while the card still sits in a blocking status, that is itself the finding: the card claims to block on him and no longer does - and that one is yours alone to catch. On a `needs-review` card his approval is the reply, so the same reasoning applies to an approval; an approval left stale by a later edit to the plan settles nothing, because he has not been asked that question yet.
   - **The ask he has to reach.** An ask that needs him to be somewhere, at something, or holding something - printing, fitting, measuring, buying a part in person, collecting a delivered part, ticking a setting on a machine he has to be sitting at - is not the case this check is for, however brief the act itself: it takes as long as it takes him to get to it, leaving it for the weekend is a perfectly reasonable thing for him to do, and its age alone proves nothing about whether he was asked well or heard at all. Do not log that one on age; a finding that says he was asked badly when he was asked perfectly well is a false wrong on his own log, which is the always-red failure point 8 guards against.
   - **A re-ask does not restart his clock.** Changing the reason or the plan on a card he is already blocked on is a new question, not a new wait: he has been sitting on that card since he first became blocked, and the sweep measures from there. Read the age as how long HE has been waiting, never as how long since the text was last edited - those two only coincide when nobody re-asks, and re-asking on a card he is already blocked on is the ordinary thing an attentive firstmate does most.
   - **What the scripted sweep does regardless.** The scripted sweep in `bin/fm-fleet-audit-sweep.sh`, whether the timer or the Force Audit button ran it, does not draw the reach-it distinction for you: it reads timestamps and the approval state, never the reason or the plan text, so it writes its own row, and counts it toward its own run's discrepancy total, on age alone. What bounds it is worth knowing: it fires nothing before `FM_AUDIT_STALE_NEEDS_ATTENTION_MINUTES` has elapsed; it ages from when he first became blocked and keeps that clock running across re-asks; and it stops once he leaves a communication note dated after the NEWEST ask, or - on a `needs-review` card - once he has approved the plan the card currently displays. What it stops is the next sweep writing the row again and counting it, while the row already written stays on the log. It reads only the communication tab, so a reply he leaves on the interpretation or needs tab does not stop it writing the row and counting it. A row of that shape against a card this check does not log on age is expected rather than evidence the ask failed - do not confirm it as a discrepancy, and do not add an age row of your own beside it.
   - **Only where he is blocked, and only on age.** A `review` card sitting for the same length of time is not a discrepancy at all - `review` is optional to him by design, so its age proves nothing, and the one word it shares with `needs-review` changes nothing about that. Apply this age check where he is blocked and nowhere else: the two blocking statuses, and no other, however long anything else has sat.
   - **The reason or the plan is a separate judgment.** Read it and judge whether it is a genuine ask, or a genuine and specific recommendation, by the same "what would he DO" test from the statuses section above - the server's mechanical guard only catches a fixed list of report-shaped phrases on a `needs-action` reason, and deliberately does not run on a plan at all, so a reason that dodges that list but still only reports progress, or a plan too vague to approve ("proceed as discussed"), will reach the board unflagged; log either here as a discrepancy the way you would any other false claim, since this judgment call is exactly what the mechanical guard cannot make and does not replace.
6. `bin/fm-dashboard.sh list --status not-started --json` - a `not_started` card is not itself suspicious; plenty are legitimately queued, and unlike the two blocking statuses above, age is never the signal here - do not flag one for merely sitting a while. The genuine discrepancy is structural: a `waiting` card whose own `waiting_on_id` names this one. That column only ever holds a value while the referencing card is itself `waiting`, so it is a live thread of work that has already said, in the board's own data, that it cannot proceed without this card - yet nothing has begun on it. Flag it on the not-started card itself (its claim of "nothing begun" is the one that is wrong), not on the waiting card (its claim of "blocked on this" is accurate). A not-started card nothing currently names this way is not a discrepancy - same silence rule as point 8 below. Say it once, not once per sweep:
   - **When to stay quiet.** If the log already carries *this* finding for that card - one that names it as not started while something waits on it - dated at or after the later of the waiting card's last move into `waiting` and the card's own last move out of `not_started`, it has already been reported, so stay quiet, the same way point 5 stops re-flagging a card once he has answered it.
   - **When it speaks again.** It speaks again when the block clears, repoints, or the card is started and then abandoned back to `not_started` - that last one is a fresh occurrence, not the old one still running.
   - **Quiet is never clean.** Holding the text back is never the same as saying the board is clean: an outstanding block still counts toward the run you record in point 9, on every sweep, for as long as it stands.
   - **Two cards waiting on one.** Two cards waiting on the same one is a single finding within a sweep; if the second one starts waiting later, it can raise its own entry once before both settle quiet, which is self-limiting rather than a guarantee of exactly one entry forever.
   - **What is not this finding.** A finding some *other* check raised about the same card is not this one and must never silence it - a card can be put back to `not_started` from any status, and it carries its old findings with it.
   - **Why it is said once.** This one legitimately persists for days, and a finding that repeats every cycle buries every other finding in the log, which is the same always-red failure point 8 guards against.
7. For anything you log as a discrepancy, use `bin/fm-dashboard.sh audit-log <id> "<what you found>"`. Be concrete: state what the card claims and what you actually observed, so firstmate can act without re-deriving it. If a live/manual sweep re-checks the same standing condition across multiple passes (a cross-home verification you repeat, for example), pass the same `--key` each time so it collapses into one updated row instead of repeating point 6's not-started problem for a check outside this script - see `bin/fm-dashboard.sh audit-log`'s own help for the exact contract.
8. If you cannot verify a card at all (no linked reference, no way to check from where you sit), that is **not** a discrepancy - do not log it as one. Silence on an unverifiable card is correct; a false "wrong" trains the Admiral to ignore the log exactly the way an always-red marker already has once.
9. When the sweep finishes, always call `bin/fm-dashboard.sh audit-run --duration-seconds <n> --checked <n> --discrepancies <n>`, even when nothing was wrong. This is what lets the page show "clean" as a real, timed answer instead of an absence. Count what your own sweep actually stands behind; the scripted sweep's count follows a rule of its own, stated in point 5.
10. If the sweep itself fails partway (a source you needed was unreadable, a check errored out), log that with `--kind error` via `audit-log --fleet "<what broke>"` rather than silently posting a shorter, quieter run. A failed check must never look identical to a clean one.
11. Read the current cadence with `bin/fm-dashboard.sh audit-interval get` at the start of each cycle rather than assuming the last-known value; the Admiral can change it from the page at any time.
12. **Every morning, try to consolidate cards.** This is a standing instruction from the Admiral in his own words - "every morning, try to consolidate cards if possible" - and it is a real sweep step, not a tidy-up you get to when there is time. A board he has to read past is a board he stops reading. Look for three shapes: exact or near-duplicate cards covering the same request; a card another card has superseded; and several cards that are really one piece of work he would describe in one sentence. Fold each group into ONE card, moving across anything the survivor is missing - his own prompt wording, the reason or plan, the links, the notes.
    - **Keep the record with the linkage, not the one that reads better.** When choosing which card survives, keep the one carrying the mechanical link to real work - `backlog_ref` and `agent`, set by `bin/fm-spawn.sh --card` or `bin/fm-backlog-handoff.sh --card`. That linkage cannot be recreated by hand: it is what lets teardown advance the card when the work lands, and what lets the auditor corroborate a `working` claim at all. Prose can be rewritten in a minute; a broken link makes the card permanently unverifiable, which is point 8's silence for the rest of its life. If the better-written card is the unlinked one, keep the linked card and move the better wording onto it.
    - **Consolidating is not deleting his work.** Never fold a card whose request is genuinely distinct just because two titles look alike, and never drop his own prompt text - it is the one thing on the card that is his and must never be paraphrased away. If two cards are near-duplicates but ask for different things, they are two cards.
    - **A card he has approved or been asked about is not a merge candidate on age alone.** Folding a `needs-review` card discards the exact plan text an approval is bound to, and folding a `needs-action` card discards the ask he is currently sitting on. Resolve those with him rather than around him.

The routine, on-interval cadence above runs on its own now, on a host timer, whether or not any agent is present to remember it - see `docs/dashboard.md` "The timer". Doing a live sweep by hand is still the right move for the judgment calls that timer cannot make mechanically (cross-home `working`/`testing` verification, whether a paused card is still genuinely paused, reading a blocking card's own reason or plan as point 5 requires, and the morning consolidation in point 12, none of which the script attempts), or when the Admiral asks for one directly; record it through the same `audit-log`/`audit-run` commands either way.

## What not to do

- Do not write to `bin/fleet-dashboard/web/*` or the SQLite file to "fix" a card faster - that is exactly the bypass this skill and the API exist to prevent.
- Do not invent an interpretation, a need, or a communication entry that did not happen, to make a tab look complete.
- Do not report a status the underlying work does not actually match, even briefly "to keep the board tidy."
- Do not treat the dashboard as a second backlog to keep in sync by hand across two systems - if you are duplicating backlog content onto a card, stop and read `docs/dashboard.md`'s "Why the board owns its own records" section first.
