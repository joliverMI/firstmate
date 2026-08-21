# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
An explicit selection is also the opt-out from Herdr or cmux runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Crew tasks become windows in that session.
`tmux display-message -p '#S'` prints its name.
If the primary harness runs outside tmux, Firstmate creates or reuses a detached session named `firstmate`:

```sh
tmux attach -t firstmate
```

Each task window is named `fm-<id>`.

```sh
tmux list-windows -t <session-name>
tmux select-window -t <session-name>:fm-<id>
```

Typing into an attached task window is authoritative direct intervention.
Routine supervision does not require attachment: `bin/fm-peek.sh <id>` captures a bounded tail and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` steers the recorded endpoint.

Verify setup by spawning a small task and confirming its `fm-<id>` window appears in the selected session.

## Current behavior and safety

### Agent liveness probe

A target-existence check proves only that the pane exists.
The deeper tmux agent-liveness probe first verifies exact window membership, then reads process names to distinguish a running harness from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse process identities as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

Existence itself is resolved through `fm_backend_tmux_exact_target_named`, the name-only resolver window removal shares, rather than a second unpinned lookup: tmux resolves a target-session by prefix exactly like it resolves a target-window, so an unpinned `list-windows -t "$session"` let a dead `dead-sess:fm-1` fall through to a live prefix-colliding `dead-sess-2`'s own window inventory and read that sibling's process under the dead session's label, reporting a nonexistent endpoint `alive`.
When the resolver refuses, an exact-pinned inventory read distinguishes a readable session that omits the window byte-exactly (`missing`) and a definitive missing-session or unreachable-server response (also `missing`) from a readable session that still lists the window, or any other read failure (both `unreadable`).
That re-confirmation matters because `missing` is a recovery-licensing verdict: a transient read failure reported as confident absence is the same lie as a false `alive`, pointed the other way.

For positive attribution, the probe combines two independent name sources rather than making either one load-bearing.
`#{pane_current_command}` and the pane tty foreground process group's kernel `comm` values expose different name fields, and which one retains executable identity is platform-dependent.
The foreground probe also reads argv[0] so an exact harness install-path component can carry the verdict when the other fields expose a rewritten process name.
Either source naming a verified harness is enough for `alive`, because a false `dead` is the one verdict that can start a duplicate agent on a live worktree, while a readable foreground process group settles the negative verdicts.

Scoping the second source to the foreground process group rather than to the pane's descendants is deliberate: a harness-named process left running in the background of an otherwise idle pane must not read as an agent.
The same scoping covers multi-process launchers without a special case, so the Pi Launcher path is attributed through its `pi-signed` wrapper and `pi` engine even though its title is the exact foreground command `pi-launcher`.
Direct executable identities `pi`, `pi-signed`, and `Pi` remain accepted exactly, and similar or prefixed process names are not accepted through those exact Pi-family entries.
Muse is likewise anchored to the exact `muse` launcher identity or the installed `muse-bin-<version>` prefix, so unrelated names such as `musescore` and `amuse` remain ambiguous.
Cursor is identified from its exact `cursor-agent` identity or versioned install tree in the foreground process path or structured argv[0]; a bare `node` or unrelated `agent` remains ambiguous.

The CI-enforced portable regression and opt-in real-harness drift guard follow the split owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the real-harness guard after any harness upgrade and before trusting refreshed evidence.

### Composer, busy state, and delivery

Agent liveness and composer safety are separate checks.
The tmux reader is a thin adapter over the fleet-wide classifier in `bin/fm-composer-lib.sh`: it contributes one styled full-pane capture, the `#{cursor_y}` cursor row, and foreground-process identity probes, and the shape containing the cursor - a complete bordered box (titled bottom borders tolerated), a bare agent-glyph row with its wrapped input, opencode's left bar, or Pi's identity-corroborated separator pair - normally decides the verdict.
Real text in an identified shape is pending, while only positively proven emptiness reads empty.
A blank or otherwise unidentified cursor row is `unknown` and every consumer defers, except that a foreground process proven to be Cursor is re-read cursorlessly because Cursor parks its terminal cursor below its footer.
That identity-gated exception preserves the strict container-proof rule for every other pane, so a modal dialog, a dead shell between stale rules, or a mid-redraw pane is never an injection target.
The shared classifier accepts a shell glyph as an empty agent composer only inside a bordered container.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Busy state is not read from rendered text on this backend.
A task's busy, idle, unknown, or dead verdict comes from the semantic busy-state contract owned by `bin/fm-busy-lib.sh`; [architecture](architecture.md#busy-state-is-semantic-per-adapter) owns its boundaries.
The one remaining rendered-tail reader is Grok's isolated fallback inside that contract, which can only classify a Grok task.
The submit acknowledgement and away-mode supervisor-pane busy guard below still consult rendered output, but only to decide whether input can be delivered, never to decide recorded task state.
The supervisor guard selects only the detected primary harness's signature rather than a global union of vendor patterns.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a proven empty composer is a positive delivery acknowledgement.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
`fm-send.sh` reports every unconfirmed verdict as a failure instead of retyping or assuming delivery.

Crew messaging, window destruction, and the recovery-grade agent-state read are all delivered only to an exactly resolved endpoint.
tmux resolves a bare `session:window` target by prefix, so the target of a destroyed window is answered by any live window whose name merely extends it: with `sess:fm-1` gone and `sess:fm-10` live, an unpinned `send-keys -t sess:fm-1` delivers into `fm-10`'s pane, and prefix-colliding task ids are routine.
Six primitives - the named-key path (`fm_backend_tmux_send_key`), the type-and-submit text path (`fm_backend_tmux_send_text_submit`), the two spawn-time typing primitives (`fm_backend_tmux_send_text_line`, `fm_backend_tmux_send_literal`), window removal (`fm_backend_tmux_kill`), and the recovery-grade state read (`fm_backend_tmux_agent_state`) - therefore address their target with what a shared resolver resolved, never a second string derived from the target independently.
There are two resolvers, and which one applies is decided by where the target came from, never by inspecting the target string - because inferring the kind from the string is the defect itself: a recorded `sess:fm-1.0` and an operator's pane address `sess:fm-1.0` are byte-identical.
`fm_backend_tmux_exact_target`, the same function `fm_backend_target_exists` answers with, also accepts an explicitly pane-qualified `session:window.pane` target because an operator-declared endpoint may legitimately name a pane.
`fm_backend_tmux_exact_target_named` is that resolver minus the pane-qualified reading: a window component is matched as a literal name and nothing else.
Window removal and the agent-state read always use the name-only resolver, because both resolve a *recorded* task's own `session:window` metadata field, where the window component is only ever a name.
The four send primitives take both kinds, so each call declares its own with a trailing target-kind argument (`named`, the default, or `general`), threaded from the provenance of the target the caller holds: `fm-send.sh`'s recorded-metadata paths, `fm-control.sh`'s validated task endpoint and `fm-spawn.sh`'s just-created window are `named`; `fm-send.sh`'s ad hoc explicit string, verified live at send time, and `fm-supervise-daemon.sh`'s `FM_SUPERVISOR_TARGET` are `general`.
Omitting the kind means `named`, so a call site that has not been classified refuses rather than reinterpreting a dead window as a live stranger's pane.
The two kinds differ over exactly one shape - a colon-bearing `session:window`, the only one tmux's own parser would split a trailing `.` off; a colon-free `%N`/`@N`/`$N` id is exact by construction and a colon-free bare name is refused when ambiguous, so both resolve identically under either kind.
What that reinterpretation costs is not uniform across the consumers: for the agent-state read a dead `sess:fm-1.0` read as pane 0 of a live `fm-1` reports an unrelated task's process as this task's `alive`; for removal it destroys that unrelated task's whole window, since `kill-window` on a pane id removes the pane's entire window; and for a send it types an ordinary steer into that crew's composer mid-turn and, once their composer clears, reports delivery *confirmed* for a task that never received it.
Sharing one resolution is the point: while a send once re-derived its own `=$session:=$window` address, a dotted window name that the probe had matched in the session inventory still sent into a sibling window's pane, because tmux splits a trailing `.` off as a pane specifier before matching the name; `fm_backend_tmux_kill` carried the identical gap for window removal, and could destroy a *different* live window rather than merely fail to remove the one it was asked to - in both the case where the dotted window was still live and the case where it was already gone.
The resolver answers each shape with the address it verified - a `session:window` pair with the `=`-pinned string it probed, a dotted or pane-qualified target and a bare name with the `@N`, `%N` or `$N` id read from the inventory listing that matched - so no shape is addressable only by a name tmux cannot express.
A target that does not resolve is refused: nothing is sent or removed, the call returns nonzero (`fm_backend_tmux_kill` alone stays best-effort and simply skips the tmux call, matching its "removing an already-gone window is not an error" contract), and the text path reports `target-unresolved` rather than a verdict a caller could read as delivered.

A bare, colon-free window name that is live in more than one session is refused rather than resolved, because an ambiguous name has no correct answer; a session name is unique per tmux server and so still resolves.

Everything else that hands tmux a caller-supplied target is still unpinned.
The list below is mechanically derived from every raw `tmux <subcommand> ... -t <target>` under `bin/`, minus the resolver's own calls and the six gated primitives above; the header comment in `bin/backends/tmux.sh` carries the `grep` that reproduces it, and excludes the container-session checks that address this process's own session or the literal `firstmate`, and the creation-time calls that address a window id the same process just created.

- **Destructive** - acts on the wrong endpoint rather than merely reporting one: `fm-teardown.sh`'s process-group reaper, whose raw `display-message -p -t "$T" '#{pane_pid}'` result is SIGTERMed and SIGKILLed as a process group with no live check on the recorded endpoint (reached when `lsof` is unavailable); and `fm-afk-launch.sh`'s `kill-session` on the recorded daemon-session name.
- **Input-delivering but ungated**: `fm-supervise-daemon.sh`'s wedged-escalation status-line flash.
- **Reads that can describe the wrong pane**: `fm_backend_tmux_capture` (`fm-peek.sh` and `fm-watch.sh` capture with no existence gate, so a destroyed endpoint can print a live sibling's pane under the dead task's label), `fm_backend_tmux_current_path`, `fm_backend_tmux_current_command`, the two foreground-process probes, `fm_backend_tmux_create_task`'s duplicate-name check, and `fm-tmux-lib.sh`'s composer, cursor, busy and pane-identity reads.

None of these license recovery or deliver input the way the six gated primitives above do; they remain a reported, not-yet-fixed gap rather than folded into this pass.
`tests/fm-backend-tmux-smoke.test.sh` asserts, against a real tmux server: the send/kill/agent-state refusals and that a live decoy pane never receives a misdelivered keystroke, message, or destruction; that a dotted window name receives its own text (and, for kill, is itself removed) rather than affecting a sibling, and that an already-gone dotted name is neither killed as, nor read as `alive` from, the sibling pane its trailing `.N` would otherwise address; that an exactly resolvable target still delivers or is still removed; that a session-name prefix collision cannot make `fm_backend_agent_state` read a live sibling's process and report a nonexistent session `alive`; that `fm_backend_tmux_exact_target` itself, not merely one of its callers, refuses a nonexistent target from inside a live tmux client; that all four sends refuse an already-gone dotted recorded window instead of resolving it to a live sibling's pane, with a decoy shell that would have executed a misdelivered line proving nothing landed there; and that target-kind `general` still delivers text, a submit through the away-mode injector's own dispatcher call shape, and a key to an explicitly pane-qualified `session:window.pane` target, and only to that pane.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.
A second, baseline-gated conversion covers harnesses whose mid-turn screen the classifier cannot identify (Pi replaces its separated composer while working): when and only when the pane was idle before the text was typed, an idle-to-busy transition across the submit's own Enter confirms delivery, the same turn-started signal Herdr reads natively.
Without that baseline, an `unknown` verdict is preserved untouched, so a busy-looking pane can never convert an unread composer into a confirmation.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.
- The OpenCode busy-queue exception is tmux-specific; Herdr retains its separately documented gap.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-tmux-agent-liveness.test.sh
tests/fm-harness-liveness-drift-live-e2e.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-cursor-harness.test.sh
tests/fm-muse-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
