# The Admiral's Fleet Dashboard

A purpose-built task board, styled to match Spectra, that replaced the generated Lavish status page (`bin/fm-status-board.sh`) as the Admiral's primary fleet surface.
One card per task the fleet has been given; seven statuses; a captain tag for who is driving it; four tabs per card; a bottom-of-page discrepancy log kept by the fleet auditor.

For exact current command syntax, run `bin/fm-dashboard.sh --help`.
For when and why an agent calls which command, see [`fleet-dashboard`](../.agents/skills/fleet-dashboard/SKILL.md) - that skill is the single owner of agent-facing usage guidance; this page stays architecture, setup, and the decisions behind the shape.

## What has to be running

One process: `bin/fm-dashboard.sh start` (wraps `python3 bin/fleet-dashboard/server/main.py`).
It serves both the API and the built page from the same port - there is no separate frontend build or server to keep up.
`bin/fm-dashboard.sh server-status` reports the process state and whether the API answers; `stop` and `restart` round out the lifecycle.
The process is not currently registered with a supervisor (systemd, cron `@reboot`, or equivalent) - that registration is a deliberate follow-up for whoever deploys this, done once on the host that will run it continuously, not part of this change. Until it is, the board does not survive a host reboot even though its *data* does (see "Persistence" below).

Reachable from the Admiral's phone the same way Lavish already is: bind to the host's tailnet address rather than `127.0.0.1`.

```sh
FM_DASHBOARD_HOST=<tailnet-ip> FM_DASHBOARD_PORT=8420 bin/fm-dashboard.sh start
```

There is no login and no per-request auth - the same trust model the existing Lavish pages already use, appropriate for a tailnet-only surface with a single operator. If the board is ever exposed beyond the tailnet, that assumption needs revisiting before deploy, not after.

## Persistence

Every card, note, status change, and audit finding lives in a SQLite database (default `$FM_HOME/data/dashboard.db`, override with `--db` or `$FM_DASHBOARD_DB`).
`data/` is already durable, private, gitignored fleet storage per `AGENTS.md` section 2, so the board survives a process restart or host reboot exactly as the rest of firstmate's private state does.
The schema (`bin/fleet-dashboard/server/store.py`) is the single owner of the exact shape; this page does not duplicate it.

## Why stdlib Python instead of FastAPI

The backend uses only the Python 3 standard library (`http.server`, `sqlite3`) - no `pip install`, no virtualenv to keep current, no dependency version to drift.
Every other piece of this fleet's tooling runs with zero extra runtime dependencies; a task board that suddenly needs a pip environment to deploy would be the one piece that breaks that pattern for no functional gain at this scale (a single operator, low request volume, a couple dozen endpoints).
If the API surface grows enough that hand-rolled routing becomes the bottleneck, that is a concrete, revisitable reason - not a reason to default to a framework up front.

## Why vendored React + htm instead of a CDN or a build step

The frontend is React, per the Admiral's stated preference, but loaded as vendored UMD builds (`bin/fleet-dashboard/web/vendor/`) rather than pulled from a live CDN at page-load time, and written with [htm](https://github.com/developit/htm) tagged templates instead of JSX so there is no Babel/Vite build step between editing `web/app.js` and it being servable.
Two concrete reasons, not a style preference:

- This fleet already has a documented CDN-fragility failure mode: a Lavish page that imported an ES module from a CDN silently never connected (`data/learnings.md`, 2026-08-12). Vendoring removes that exact class of failure for a page the Admiral needs to load reliably from his phone.
- A build step means a new host dependency (Node + npm + the React/Vite toolchain) on whatever machine deploys this, and a rebuild step to remember on every frontend change. Serving `web/` directly, as-authored, keeps the deploy step to "run one Python file" with nothing to install and nothing to build.

Styling is deliberately fixed (`web/styles.css`) - no theme switcher, no runtime style configuration - per the Admiral's own instruction; it does not need to be dynamic to be a dynamic *dashboard*.

## Why the board owns its own records

The dashboard does not read or scrape `data/backlog.md`, any secondmate's backlog, or decision-hold records, and it does not write to them either. It keeps its own SQLite tables, populated only through explicit `bin/fm-dashboard.sh` calls.

This was a deliberate choice among three options - read live from the backlog, own separate records, or both - made for two reasons:

1. **The vocabulary doesn't match.** The board's six statuses (Working / Paused / Not Started / Waiting / Testing / Complete) and its four tabs (prompt / interpretation / communication / needs) are not a relabeling of `tasks-axi` states; they are the Admiral's own review workflow. Deriving them automatically from backlog state would require a lossy, guessed mapping - exactly the kind of silent inference this fleet's own incident history warns against.
2. **The auditor needs something to check.** If the board mechanically mirrored live state, there would be nothing for the fleet auditor to catch - "Working" would always be exactly as true as the source it was copied from, by construction. Because the board is a separate, explicitly-maintained claim, "the card says Working" and "an agent is actually working" are genuinely two different facts, and the auditor's whole job is reconciling them.

**The drift risk this creates is real and explicit, not hidden:** if firstmate (or a crew) forgets to call `bin/fm-dashboard.sh status` after a real change, the card goes stale silently from the board's own point of view - there is no automatic correction.
The fleet auditor exists specifically to bound that risk: every sweep re-derives ground truth from live crew/session state and the real backlog, compares it to what each card claims, and logs a discrepancy the moment the two disagree, with a timed record of how long the check took so a silently-skipped sweep is itself visible (see "Auditor integration" below).
An optional `backlog_ref` field on a card (`bin/fm-dashboard.sh ref <id> <home:task-id>`) lets the auditor cross-check a specific card against a specific backlog entry when one exists; a card with no ref is not treated as wrong for that - see the next section.

## Why `needs-attention` is a separate status from `testing`

Both statuses put a finished-enough card in front of the Admiral, which is why they used to get conflated - and why doing so once buried several of his genuinely open decisions in a place he had no reason to check closely.
The two are opposite on the one axis that matters: whether the work still needs him to move forward.
`testing` is done and optional - if he never opens the card, nothing is lost, it is otherwise complete.
`needs-attention` is stuck without him - a decision, an answer, or a physical action only he can supply.
That asymmetry is why `needs-attention` sorts first and renders loudest on the page, and why the fleet auditor treats its age as a finding in a way it never does for `testing` (see the [`fleet-dashboard`](../.agents/skills/fleet-dashboard/SKILL.md) skill for the exact status definitions and the auditor's per-status procedure).

## Link policy (standing order 17)

`bin/fm-dashboard.sh link` and the underlying `POST /api/tasks/{id}/notes` endpoint reject, structurally, any link whose host contains `github`, any link that is not a full `http(s)://` URL, and any link whose host is local-only and will not resolve from the Admiral's phone (`bin/fleet-dashboard/server/validation.py`).
This is enforcement, not just a written rule an agent has to remember: "never a GitHub or pull-request link" and "a link he can open on his phone" are the two things this board sends the Admiral, so both are checked server-side on every write, not left to habit.

## Auditor integration

The fleet auditor (secondmate `fleet-auditor`) treats the board as its reference for what the fleet claims is happening, and is the authority on whether that claim is actually true - the board does not judge itself.
Its exact per-cycle procedure, including how to distinguish a genuine discrepancy from a card it simply cannot verify, lives in the [`fleet-dashboard`](../.agents/skills/fleet-dashboard/SKILL.md) skill rather than here, so there is one place agents read it from.

Two page-visible outcomes matter for how the Admiral reads this surface:

- **The discrepancy log** (bottom of the page) only ever shows something the auditor actually confirmed was wrong, timestamped. An empty log and a log that has never run are shown differently on purpose (see the next point) - an absence of findings is not the same claim as an absence of *checking*.
- **The last-check indicator** shows when the last full sweep completed, how long it took, and how many tasks it covered, sourced from `bin/fm-dashboard.sh audit-run`. A sweep that never completes (crashes, hangs, or is simply never run) shows as "never run" rather than silently reusing the last good timestamp - this is the same "loud, not a quiet omission" principle applied to the auditor's own liveness, not just to its findings.

Audit frequency is a stored setting (`bin/fm-dashboard.sh audit-interval`), starting at 15 minutes, editable from the page itself.
The dashboard stores and serves that setting; it does not itself schedule the auditor's wake cadence - wiring the fleet-auditor secondmate's actual run schedule to read and honor it is a deliberate follow-up outside this change's file scope (a secondmate's charter and schedule are firstmate-owned private state, not shared tracked material).

## Reaching the board from a secondmate

A secondmate host is not where the board's server runs; it calls the primary's instance over the network.
Point it at the primary with either `$FM_DASHBOARD_URL` (a full base URL) or `$FM_DASHBOARD_HOST` / `$FM_DASHBOARD_PORT`, or persist the choice in `config/dashboard-url` (first line, gitignored, one URL) so every `bin/fm-dashboard.sh` call on that host resolves correctly without repeating the environment variable.

## Connectivity failure is loud, not a quiet empty board

If the page's fetch to its own API fails - the server is down, a network hiccup, anything - the page shows a persistent, unmissable banner distinguishing "cannot confirm current state" from "confirmed empty," and keeps the last known-good data visible underneath rather than blanking to what would look like a healthy, empty queue.
This mirrors the auditor's own "never run" vs. "ran clean" distinction: absence of confirmation is never rendered the same as a confirmed good state, anywhere on this page.
