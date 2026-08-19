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

**Cause B - the test measured something it did not intend to.**
Both adapters spawn their arm child through `bash -lc`.
A login shell sources `/etc/profile` and `/etc/profile.d/*` in addition to the account's own profile files, and the system-wide half is not relocatable via `HOME`.
That unbounded, machine-specific, load-dependent cost sat inside the tight readiness/retire windows these two cases assert on, so under contention the arm child was SIGTERMed before the fixture could record itself.

## Base state (already on `main` before this change)

`main` independently raised `FM_PI_ARM_READY_TIMEOUT_MS` / `FM_OPENCODE_ARM_READY_TIMEOUT_MS` from 250ms to 2000ms and rewrote `test_pi_session_transition_generation_owner`'s fixture to write its arm-log row before the pid-file row that its waiters gate on, both landed independently of this change.
Neither addresses cause A: `ensureArm` still reused an in-flight attempt's result unconditionally, and its own comment on the timeout raise records a measured worst case of ~1740ms against the new 2000ms budget under contention - narrower headroom, not a removed confound.
This change does not touch either of those base fixes and does not re-litigate the timeout value; both are kept exactly as `main` has them.

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

Two regression tests were added inside the arm-readiness suite itself; the existing lock test was rewritten to prove cause A deterministically rather than by waiting for it.

| Test | Pins |
|---|---|
| `test_opencode_primary_watch_plugin_requires_session_lock` (rewritten) | Cause A. A `ps` shim blocks the first lock-ownership walk mid-flight, so the stale-verdict race is forced deterministically rather than waited for. Also asserts two distinct lock premises produce two evaluations. Fails against the pre-change `ensureArm`: that version takes the unconditional in-flight-reuse branch, so the reacquired-lock caller blocks on the foreign attempt, which is still pinned inside the gated `ps` shim - the test releases that gate only after awaiting the owned caller - and the case fails on the 20s `settling` guard rejecting with "the reacquired-lock arm attempt never settled" rather than by observing the inherited `read-only` verdict directly. Also fails against a rejected fully-serialized variant (deadlocks); passes against the shipped premise-validated coalescing. |
| `test_opencode_watch_arm_coalesces_callers_on_an_unchanged_lock` (new) | The other half of cause A: two callers on an unchanged lock must share exactly one evaluation. Unconditional coalescing (the pre-change behavior) already passes this test; it instead guards against the rejected serialized variant, which fails it with two evaluations. |
| `test_watch_arm_login_shell_default_reaches_the_arm_child` (new) | Both branches of the `FM_WATCH_ARM_NO_LOGIN_SHELL` opt-out, for both adapters, via a temp `HOME` whose `.profile` exports a marker the arm child either does or does not observe. |

## Verification

- Date: 2026-08-19
- Command: `tests/fm-pi-watch-extension.test.sh`, run consecutively
- Code under proof: this branch's commit, built directly on `main` at `45bd292`
- Host: 32 cores
- Assertions per run: 32

| Phase | Conditions | Result |
|---|---|---|
| Idle | 1-minute load average 0.66 at phase start | **20/20 passed, 0 failed** |
| Loaded | 160 busy-loop processes on 32 cores (5x oversubscription), load average climbing to 163 | **20/20 passed, 0 failed** |
| Total | | **40/40** |

No run was short of clean, and no assertion failed in either phase.
