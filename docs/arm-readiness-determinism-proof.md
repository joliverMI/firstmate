# Arm-readiness suite determinism proof

This record is the repeated-run proof for `tests/fm-pi-watch-extension.test.sh`, the suite that verifies the Pi and OpenCode arm-readiness contract owned by [`watcher-continuity.md`](watcher-continuity.md#actionable-wake-ordering).
The suite was red for over a day, failing a different assertion on most runs.
By the time this record was written, `main` already carried its own independent partial mitigation for two of the four assertions (see "Base state" below); the numbers here are from a full run against the tree with this change's fixes applied on top of that base, and supersede any earlier in-branch run figures produced against a different tree.

## The four originally-failing assertions, and which share a cause

Two independent causes, two assertions each.

| Assertion | Cause |
|---|---|
| `OpenCode watch plugin must arm only when this session owns the fleet lock` (both reported occurrences) | A - production race in `ensureArm` |
| `Pi must deliver the actionable wake after bounded hung-successor recovery` | B - test window racing an unrelated cost |
| `Pi must fall back without overlapping an unretired successor` | B - test window racing an unrelated cost |

**Cause A - production code was genuinely racy.**
`ensureArm` in `.opencode/plugins/fm-primary-watch-arm.js` reused a still-resolving earlier caller's `beginArm()` result unconditionally.
Every ordinary `session.idle` produces two callers - the plugin's own handler and the turn-end guard's `coordinator.ensureArmed` call - so when the fleet lock was reacquired while an earlier attempt was mid-flight, the later caller inherited that attempt's `read-only` verdict and never armed.
This diagnosis was made against the lock-ownership test as it stood at the time, using `ps`-latency fault injection to hold an attempt inside its ownership walk; the race reproduced deterministically before the `ensureArm` fix and stopped reproducing after it.

**Why this branch's inherited copy of that test can no longer witness it.**
The version of the lock test this branch inherited cannot reconstruct that interleaving, for a reason that has nothing to do with the diagnosis.
At the time of the diagnosis the case slept a fixed 120ms between starting the foreign-lock attempt and flipping the lock, so under load the flip could land while the first attempt was still inside its `git`/`ps` walk - the later caller then coalesced onto the stale `read-only` verdict and never armed, which is exactly the reported failure.
`882004e` on `main` afterwards replaced that sleep with a direct `coordinator.ensureArmed(...)` await, independently of this work and for its own reasons (a fixed sleep cannot tell when the decision has landed).
That await drains the in-flight attempt before the flip: both callers now evaluate the *same* foreign lock, and caller 1's `finally` clears `launchInFlight` in an earlier microtask than caller 2's resumption, so the flip is always evaluated by a fresh attempt.
The consequence is narrow and is only about which artifact can serve as the witness.
Cause A is real, was demonstrated when it was diagnosed, and is fixed here; what this branch's inherited test can no longer do is re-demonstrate it, which is why the race is instead pinned by a new test built for exactly that purpose - `test_opencode_primary_watch_plugin_requires_session_lock`'s `ps`-shim rewrite, which forces the lock to change while a caller is pinned mid-evaluation.
The lock assertion still belongs to cause A, but on the reproduction above rather than on a budget-headroom argument.
An earlier draft of this record also excluded cause B from it by arguing that its pre-change 5s wait had ample headroom over a `bash -lc` start of ~1150ms (at most ~1740ms).
That figure was inherited from `main`'s comment rather than re-measured at this record's own load level, and it understates this host.
Re-measured at the same 5x oversubscription the loaded phase below uses (160 busy loops on 32 cores, 1-minute load average ~151, 30 samples), a loaded `bash -lc true` is min 1096ms, median ~1620ms, max 4246ms, with two samples above 3.9s; idle is unchanged, ~131ms median here against the ~140ms `main`'s comment records.
Against a real 4246ms worst case a 5s budget leaves ~18% headroom, not ample, so that secondary exclusion is withdrawn: budget arithmetic cannot rule cause B out as a contributor to the lock assertion.
It does not need to. The attribution rests on the direct reproduction - reverting the `ensureArm` fix fails that assertion deterministically - and cause B is not what the fix for it addresses.

**Cause B - the test measured something it did not intend to.**
Both adapters spawn their arm child through `bash -lc`.
A login shell sources `/etc/profile` and `/etc/profile.d/*` in addition to the account's own profile files, and the system-wide half is not relocatable via `HOME`.
That unbounded, machine-specific, load-dependent cost sat inside the tight readiness/retire windows these two cases assert on, so under contention the arm child was SIGTERMed before the fixture could record itself.

One residual instance of this shape survives, deliberately, in exactly one case.
`test_watch_arm_login_shell_default_reaches_the_arm_child` exists to verify that the production default still reaches the arm child, so its `login` branch must pay the real `/etc/profile` cost and then wait a bounded 10s for the marker row - a bounded wait on an unbounded cost, which is the very shape the rest of this change removes.
It cannot be removed there without defeating what the case verifies; the bound is ~2.4x the 4246ms worst case re-measured above, but it is a headroom argument rather than a guarantee, and it applies to that one case only.

## Base state (already on `main` before this change)

`main` independently raised the `FM_PI_ARM_READY_TIMEOUT_MS` / `FM_OPENCODE_ARM_READY_TIMEOUT_MS` values this suite sets for its unready-arm cases from 250ms to 2000ms - per-case overrides, not the production defaults [`configuration.md`](configuration.md) owns - and rewrote `test_pi_session_transition_generation_owner`'s fixture to write its arm-log row before the pid-file row that its waiters gate on, both landed independently of this change.
`882004e` on `main` also replaced the lock test's fixed 120ms sleep with a direct `coordinator.ensureArmed(...)` await, again independently of this change; that is what stops this branch's inherited copy of that case from reconstructing cause A, as described above.
None of those addresses cause A: `ensureArm` still reused an in-flight attempt's result unconditionally, and its own comment on the timeout raise records a measured worst case of ~1740ms against the new 2000ms budget under contention - narrower headroom, not a removed confound.
The re-measurement above sharpens that second point rather than softening it: at 4246ms the loaded worst case sits *above* the raised 2000ms budget outright, so the raise narrowed the confound without removing it, which is what the opt-out below does instead.
This change does not touch any of those base fixes and does not re-litigate the timeout value; all are kept exactly as `main` has them.

## What this change adds

- **Premise-validated coalescing** (`.opencode/plugins/fm-primary-watch-arm.js`) - the fix for cause A.
  `ensureArm` reads the lock file's content synchronously at call time and shares an in-flight `beginArm()` only while that content still matches what the in-flight attempt captured; otherwise it starts its own evaluation.
  Two callers on an unchanged lock still coalesce into one `git`/`ps` walk, so the ordinary idle turn pays no extra subprocess cost.
  Serializing the callers instead would fix the same race by removing coalescing, at the price of doubling that subprocess work on every idle turn; `test_opencode_watch_arm_coalesces_callers_on_an_unchanged_lock` pins the cheaper contract.
- **`FM_WATCH_ARM_NO_LOGIN_SHELL` opt-out** (`.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts`, documented in [`configuration.md`](configuration.md)) - the fix for cause B.
  It removes the unbounded cost from inside the timed window rather than widening the window around it, which is all `main`'s own timeout raise could do; it complements that raise and does not replace it.
  Set to `1`, the arm child spawns under plain `bash -c`.
  The login shell remains the unconditional production default because `bin/fm-watch-arm.sh` and its descendants may only reach `node` through PATH additions a profile makes.
  The suite exports the opt-out so its timed windows measure only readiness-detection logic instead of racing an unbounded profile-sourcing cost against however much headroom the timeout leaves.
  Relocating `HOME` is not sufficient by itself: it removes only the account half of the cost, and `/etc/profile` is still sourced.
- **Observable-condition waits in the four fallback cases** (`tests/fm-pi-watch-extension.test.sh`) - the other half of the cause B fix, and the one that removes the elapsed-time dependence rather than shrinking it.
  Each arm attempt appends its `arm=<pid>` row as the first thing it does, long before its own readiness timeout can expire, so the row count is a genuinely observable signal for how many attempts the extension made.
  `test_pi_hung_successor_falls_back_to_typed_wake`, `test_pi_unretired_successor_falls_back_without_retry`, and their two OpenCode counterparts now wait for that row count to reach its expected total (4 and 2 respectively) and assert it, before running the pre-existing bounded wait for the wake prompt.
  That second wait stays a bound on purpose: whether the extension eventually gives up and delivers its typed failure is a negative, and a negative has no positive signal to observe - a bound is the only available instrument for it.
  What changed is what the bound now covers. With the attempt count already confirmed observably, it brackets only the bounded readiness/retire/retry sequence the extension runs itself, not an unrelated cost racing it.
  Rows are counted only once newline-terminated, so a fixture descheduled between creating the log and writing into it cannot read as an attempt that already happened.
  Because that wait exits as soon as the expected count is reached, it can only bound the count from below; all four cases therefore settle briefly after the wake assertions and re-read the log, so a stray extra arm is still caught from above.
  In the unretired cases that re-read happens before the release file lets the successor exit, which is the window where an overlapping retry would be the reported regression.
- **Three unhandled-EPIPE guards** (`.opencode/plugins/fm-primary-turnend-guard.js`, `.pi/extensions/fm-primary-turnend-guard.ts`, `.opencode/plugins/lib/fm-operational-input.js`) - unrelated to causes A and B, found while proving this change under load.
  A child that exits before the parent's `child.stdin.end(...)` write lands makes that write fail with EPIPE, which node raises on the stdin stream rather than on the `ChildProcess`.
  Unhandled, it took down the whole session process.
  These are every async `stdin.end` site in the adapters; `.pi/extensions/lib/fm-operational-input.ts` uses `spawnSync` with `input:` and has no async pipe.
  `test_adapter_surfaces_encoder_exit_instead_of_killing_the_host` in `tests/fm-operational-input.test.sh` pins the shared encoder path: an encoder that exits before reading a body larger than the pipe buffer must fail that one call and leave the host session alive.

Two regression tests were added inside the arm-readiness suite itself; the existing lock test was rewritten so that it forces cause A deterministically, which the sequencing this branch inherited could not do.

| Test | Pins |
|---|---|
| `test_opencode_primary_watch_plugin_requires_session_lock` (rewritten) | Cause A. A `ps` shim blocks the first lock-ownership walk mid-flight, so the stale-verdict race is forced deterministically rather than waited for. Also asserts two distinct lock premises produce two evaluations. Fails against the pre-change `ensureArm`: that version takes the unconditional in-flight-reuse branch, so the reacquired-lock caller blocks on the foreign attempt, which is still pinned inside the gated `ps` shim - the test releases that gate only after awaiting the owned caller - and the case fails on the 20s `settling` guard rejecting with "the reacquired-lock arm attempt never settled" rather than by observing the inherited `read-only` verdict directly. Also fails against a rejected fully-serialized variant (deadlocks); passes against the shipped premise-validated coalescing. |
| `test_opencode_watch_arm_coalesces_callers_on_an_unchanged_lock` (new) | The other half of cause A: two callers on an unchanged lock must share exactly one evaluation. Unconditional coalescing (the pre-change behavior) already passes this test; it instead guards against the rejected serialized variant, which fails it with two evaluations. |
| `test_watch_arm_login_shell_default_reaches_the_arm_child` (new) | Both branches of the `FM_WATCH_ARM_NO_LOGIN_SHELL` opt-out, for both adapters, via a temp `HOME` whose `.profile` exports a marker the arm child either does or does not observe. Its `login` branch is the one bounded-wait-on-unbounded-cost this change knowingly keeps - see the residual note under cause B. |

## Verification

- Date: 2026-08-19
- Command: `tests/fm-pi-watch-extension.test.sh`, run consecutively
- Code under proof: `a15d993`, this branch's head when the run was taken, on top of `main` at `45bd292`
- Host: 32 cores
- Assertions per run: 32, every one of them passing on every run in both phases

| Phase | Conditions | Result |
|---|---|---|
| Idle | 1-minute load average 0.66 at phase start | **20/20 passed, 0 failed** |
| Loaded | 160 busy-loop processes on 32 cores (5x oversubscription), 1-minute load average peaking at 163 | **20/20 passed, 0 failed** |
| Total | | **40/40 passed, 0 failed** |

No run was short of clean, and no assertion failed in either phase.

**Why a run stamped at `a15d993` still describes this branch's head.**
`a15d993` already carries every change this branch makes to production code and to test logic, including `5f56cc7`'s rewrite of the four fallback cases onto observable arm-row counts.
Exactly two files have changed since it: this record, and `tests/fm-pi-watch-extension.test.sh` - and that test diff is 18 lines, all of them comment lines (`9c67804`, replacing the inherited `bash -lc` contention figures with the re-measured ones cited under cause A).
No production file changed at all.
So the figures above are deliberately not re-stamped to a later commit: no executable byte under proof differs between `a15d993` and this branch's head, and a fresh run could only exercise the same tree.
Had any test-logic or production change landed after `a15d993`, this section would have required a fresh run rather than a re-dated transcription of these counts.

### Independent checks run against the same tree and host

- **Pre-change baseline control.** The base commit's copy of the suite (`git show 45bd292:tests/fm-pi-watch-extension.test.sh`) was run on this same tree and host to confirm the red behaviour is reproducible here at all: **0/10 passed under the 5x load above**, and **3/12 passed at 1.5x load** (48 busy loops, 1-minute load average ~51).
  That reproduces the reported flakiness - a different assertion failing per run - but with one nuance worth stating rather than glossing: on this host the load exposed a *different subset* of the suite than the four assertions in the original report.
  The four that failed across those 22 baseline runs were `Pi redundant tool call must remain an ownership-based no-op with repair-only guidance` (8 runs), `Pi established clean closes must honor the continuity retry limit` (5), `OpenCode established clean closes must honor the continuity retry limit` (4), and `Pi extension must surface an external healthy watcher as an owned-wake failure` (2).
  So this is evidence that the pre-change suite is load-sensitive on this host and that the post-change suite is not; it is not a re-observation of the four originally-reported assertions specifically, and the cause attributions above do not rest on it.
- **Each regression-table claim reproduced by reverting its fix.** Every "fails against" claim in the table above was checked by reverting that one fix in turn, confirming the expected failure, then restoring and confirming the suite clean again, rather than by inspection:
  - pre-change unconditional `ensureArm` in-flight reuse - `test_opencode_primary_watch_plugin_requires_session_lock` fails on its 20s settling guard with "the reacquired-lock arm attempt never settled", while `test_opencode_watch_arm_coalesces_callers_on_an_unchanged_lock` still passes, confirming the coalescing case does not itself catch cause A;
  - the rejected fully-serialized variant - the lock case deadlocks on the same guard and the coalescing case fails with "two callers on an unchanged lock must share one evaluation, got 2";
  - the `child.stdin.on("error")` EPIPE guard removed from `.opencode/plugins/lib/fm-operational-input.js` - the host node process dies with an unhandled EPIPE and `test_adapter_surfaces_encoder_exit_instead_of_killing_the_host` reports the host as dead.
- **Login-shell cost re-measurement.** The loaded `bash -lc` figure the residual-bound argument cites was re-measured here rather than inherited; see the numbers under cause A above.
