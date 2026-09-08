# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its loop bounds and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

## Continuity deadman

Every layer above is hosted on the primary's own turn boundary, which makes that one event a single point of failure for continuity, for detecting its loss, and for alarming on it.
Claude Code v2.1.263 does not run Stop hooks for a turn that terminates in an API error, so an outage that begins between two turns takes the whole chain down silently: the watcher's rewake turn is the very next turn attempted, the watcher is always down at that instant by design, and its hook-less end re-arms nothing and writes no failure marker.
The session keeps running and keeps looking healthy, so no restart and no session-start recovery ever happens either.

`bin/fm-continuity-deadman.sh` is the backstop that does not live on that event.
It is one detached singleton process per home, started by `bin/fm-watch-arm.sh` on every arm and by `bin/fm-bootstrap.sh` at session start, holding `state/.continuity-deadman.lock` under the same portable lock and process-identity rules as `state/.watch.lock`.
It is the one deliberate exception to the rule that the harness owns its hooks' process group, and it retires itself when the session-lock pid stops being a live harness process or the home has had nothing to supervise for `FM_CONTINUITY_DEADMAN_IDLE_EXIT`.

Its predicate runs about every minute and requires all of: `state/.afk` absent, a live session-lock harness pid, `fm_supervision_needed`, no live `autoarm`-role owner of `state/.claude-autoarm.lock`, and either no watcher beat within `FM_GUARD_GRACE` with no healthy watcher now, or a delivered rewake unhandled past that same window.
Away mode is excluded because `bin/fm-supervise-daemon.sh` owns supervision and the injection channel there, and two injectors into one pane is a hazard rather than a fix.
A deadman never alarms inside the first grace window of its own life, so a session start whose first watcher has not come up yet is not mistaken for an outage.

When the predicate holds it appends exactly one `check: watcher-continuity-lost` wake per episode, writes the durable episode record `state/.continuity-deadman-alarm`, fires the configured active-alert channels through `bin/fm-wedge-alarm-lib.sh` ([`wedge-alarm.md`](wedge-alarm.md) owns channel configuration), and then attempts self-recovery on a bounded backoff.
Self-recovery injects one `turn-end-guard`-kind operational input into firstmate's own pane through the shared supervisor-pane safety predicates in `bin/fm-supervisor-pane-lib.sh`, so it never types into a pane that is mid-turn, whose composer is not positively proven empty, or whose backend has no verified primitives for firstmate's own pane.
Each injection starts a real turn whose ordinary turn end re-arms the chain; while the API is still failing that turn also ends hook-less and costs nothing, and the moment service returns the next injection restores supervision without waiting for the captain.
Recovery closes the episode and stops the injections.

`state/.rewake-pending` is the second trigger and separates a DELIVERED rewake from a HANDLED one.
`bin/fm-claude-stop-autoarm.sh` writes it immediately before its exit-2 rewake and `bin/fm-wake-drain.sh` clears it at the top of the handling turn, so a marker older than the grace window is direct evidence that the woken turn never ran even when some beacon is still fresh.

`bin/fm-continuity-deadman.sh status` reports this home's deadman and any open episode; its own header owns every environment knob and file.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
For every supported arm path, a successor that observes an accepted down stretch emits `check: rearm-resurface` through the ordinary durable handling path before settling into its live wait.
That recovery presentation includes all unacknowledged queue rows, the cursor-folded OPEN DECISIONS set, and still-unread informational status lines, so a still-open decision or a buried `note:` answer reappears even when recovery has no queue row of its own.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence, while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies that concurrent callers coalesce into one arm evaluation only while the fleet lock they read is unchanged, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.
`tests/fm-continuity-deadman.test.sh` covers the deadman end to end over real processes with no harness installed: the full predicate and each of its negative controls, one durable wake and one alert per episode, the unhandled-rewake trigger behind a live watcher, a single typed injection per backoff window, an unconfirmed submit that is recorded and still spends that window rather than retyping, deferral to a busy pane and to a composer that is not proven empty, episode closure on recovery, singleton `ensure` starting a deadman in a different process group from its starter, self-retirement when the session is gone, inertness in a linked task worktree, and the drain retiring the delivered-rewake marker.
`tests/fm-claude-stop-autoarm.test.sh` additionally pins that only a delivered rewake records `state/.rewake-pending` and that claiming the home sweeps its own day-old arm-output temp files.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
The continuity deadman detects an outage within roughly a grace window plus one tick, not instantly, and its self-recovery can only reach a pane this machine can identify and read: a home with no resolvable pane, or a supervisor backend with no verified primitives for firstmate's own pane, still records the outage and alarms but cannot restart the chain by itself.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
[`arm-readiness-determinism-proof.md`](arm-readiness-determinism-proof.md) records the repeated-run determinism proof for the Pi and OpenCode arm-readiness suite under idle and loaded conditions.
