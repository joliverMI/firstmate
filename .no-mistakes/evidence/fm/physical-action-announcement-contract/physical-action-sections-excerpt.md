### Ship brief (--mode no-mistakes): status rules 4-8 as a crewmate reads them

4. Report status by appending one line:
   `echo "{state}: {one short line}" >> '/tmp/fm-brief-evidence-home/state/ship-physical-demo.status'`
   States: working, needs-decision, blocked, paused, done, failed.
   Each append can wake firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Rule 5's physical-action events are the exception to this rule and are always appended.
   A mid-task `working:` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined `done:` gate under Definition of done.
   Use `paused: {why}` - distinct from `blocked:` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use `blocked:` when you are stuck and need help.
5. If this task changes or takes control of anything in the captain's physical space (lights, audio, doors, machines), you owe firstmate the BEFORE/START/END/RELEASE announcement contract in section 9 of `/home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M1T4R6WEZ39FGC5SA9RG8X8N/AGENTS.md` as its own status line at each event.
   These events are exempt from rule 4's sparse-reporting default and are never the step-by-step FYI progress lines rule 4 forbids; report each one as it happens.
   A `working:` line does not reliably wake firstmate on its own, so firstmate watches your pane during an announced physical action; that changes nothing for you, and you still append every one of these events when it happens.
   An abort is an END, reported as promptly as a completion, never as silence.
   During an announced physical action, break any extended silence with a `working:` line saying what is currently happening, even "still working"; never fold these events into your next routine line.
   Before any status line that asks the captain for his time, presence, or consent, re-check the most recent thing that failed at its effect, not its configuration, immediately before the ask (section 9 of `/home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M1T4R6WEZ39FGC5SA9RG8X8N/AGENTS.md`); this catches recurrence only, so say so plainly if the failure that actually blocks you is a first-time one this check would not have caught.
6. If you hit the same obstacle twice, append `blocked: {why}` and stop; firstmate will help.
7. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append `needs-decision: {summary of options}` and stop. Firstmate will apply the configured authority and reply with the decision.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
8. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving

### Scout brief (--scout): status rules 4-8

4. Report status by appending one line:
   `echo "{state}: {one short line}" >> '/tmp/fm-brief-evidence-home/state/scout-physical-demo.status'`
   States: working, needs-decision, blocked, paused, done, failed.
   Each append can wake firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Rule 5's physical-action events are the exception to this rule and are always appended.
   Use `paused: {why}` - distinct from `blocked:` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use `blocked:` when you are stuck and need help.
5. If this task changes or takes control of anything in the captain's physical space (lights, audio, doors, machines), you owe firstmate the BEFORE/START/END/RELEASE announcement contract in section 9 of `/home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M1T4R6WEZ39FGC5SA9RG8X8N/AGENTS.md` as its own status line at each event.
   These events are exempt from rule 4's sparse-reporting default and are never the step-by-step FYI progress lines rule 4 forbids; report each one as it happens.
   A `working:` line does not reliably wake firstmate on its own, so firstmate watches your pane during an announced physical action; that changes nothing for you, and you still append every one of these events when it happens.
   An abort is an END, reported as promptly as a completion, never as silence.
   During an announced physical action, break any extended silence with a `working:` line saying what is currently happening, even "still working"; never fold these events into your next routine line.
   Before any status line that asks the captain for his time, presence, or consent, re-check the most recent thing that failed at its effect, not its configuration, immediately before the ask (section 9 of `/home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M1T4R6WEZ39FGC5SA9RG8X8N/AGENTS.md`); this catches recurrence only, so say so plainly if the failure that actually blocks you is a first-time one this check would not have caught.
6. If you hit the same obstacle twice, append `blocked: {why}` and stop; firstmate will help.
7. If a decision belongs to a human (product choices, destructive actions),
   append `needs-decision: {summary of options}` and stop. Firstmate will reply with the decision.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
8. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving

### Secondmate charter (--secondmate --no-projects): routed-work reporting exception

40-This is also how you return the answer to a marked from-firstmate request above.
41-A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
42-Never append `working:` merely to acknowledge receipt or announce that a marked request has started.
43:Physical-action work is the one exception to the two lines above: when routed work changes or takes control of anything in the captain's physical space (lights, audio, doors, machines), append the BEFORE, START, END, and RELEASE announcements in section 9 of your local `AGENTS.md` as their own status lines as each one happens.
44-An abort is an END, reported as promptly as a completion, never as silence, and an extended silence during an announced action is broken with a `working:` line saying what is currently happening.
45-Append these even though they are the receipts and start acknowledgements those two lines otherwise forbid; those two lines still govern every ordinary non-physical routed request.
46-When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
