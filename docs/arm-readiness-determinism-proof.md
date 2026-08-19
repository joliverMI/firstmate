# Arm-readiness suite determinism proof

This record is the repeated-run proof for `tests/fm-pi-watch-extension.test.sh`, the suite that verifies the Pi and OpenCode arm-readiness contract owned by [`watcher-continuity.md`](watcher-continuity.md#actionable-wake-ordering).
The suite was red for over a day, failing a different assertion on most runs.
The numbers below were produced against the implementation described in "What actually ships" and supersede any earlier in-branch run figures.

## The four failing assertions, and which share a cause

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
That unbounded, machine-specific, load-dependent cost sat inside the tight `FM_PI_ARM_READY_TIMEOUT_MS=250` / `FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20` windows these two cases assert on, so under contention the arm child was SIGTERMed before the fixture could record itself.

## What actually ships

- **Premise-validated coalescing** (`.opencode/plugins/fm-primary-watch-arm.js`).
  `ensureArm` reads the lock file's content synchronously at call time and shares an in-flight `beginArm()` only while that content still matches what the in-flight attempt captured; otherwise it starts its own evaluation.
  Two callers on an unchanged lock still coalesce into one `git`/`ps` walk, so the ordinary idle turn pays no extra subprocess cost.
  Serializing the callers instead would fix the same race by removing coalescing, at the price of doubling that subprocess work on every idle turn; `test_opencode_watch_arm_coalesces_callers_on_an_unchanged_lock` pins the cheaper contract.
- **`FM_WATCH_ARM_NO_LOGIN_SHELL` opt-out** (`.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts`, documented in [`configuration.md`](configuration.md)).
  Set to `1`, the arm child spawns under plain `bash -c`.
  The login shell remains the unconditional production default because `bin/fm-watch-arm.sh` and its descendants may only reach `node` through PATH additions a profile makes.
  The suite exports the opt-out so its timed windows measure only readiness-detection logic.
  Relocating `HOME` is not sufficient: it removes only the account half of the cost, and `/etc/profile` is still sourced.
- **Three unhandled-EPIPE guards** (`.opencode/plugins/fm-primary-turnend-guard.js`, `.pi/extensions/fm-primary-turnend-guard.ts`, `.opencode/plugins/lib/fm-operational-input.js`).
  A child that exits before the parent's `child.stdin.end(...)` write lands makes that write fail with EPIPE, which node raises on the stdin stream rather than on the `ChildProcess`.
  Unhandled, it took down the whole session process.
  These are every async `stdin.end` site in the adapters; `.pi/extensions/lib/fm-operational-input.ts` uses `spawnSync` with `input:` and has no async pipe.
  `test_adapter_surfaces_encoder_exit_instead_of_killing_the_host` in `tests/fm-operational-input.test.sh` pins the shared encoder path: an encoder that exits before reading a body larger than the pipe buffer must fail that one call and leave the host session alive.
- **Fixture ordering fix** (`test_pi_session_transition_generation_owner`).
  The arm-log row is now written before the pid-file row that every `waitFor()` gates on, so a waiter cannot proceed into an assertion that counts a log row the child has not written yet.

Three regression tests were added or rewritten inside the arm-readiness suite itself.
Each was confirmed to fail against the pre-fix code and pass after it.

| Test | Pins |
|---|---|
| `test_opencode_primary_watch_plugin_requires_session_lock` | Cause A. A `ps` shim blocks the first lock-ownership walk mid-flight, so the stale-verdict race is forced deterministically rather than waited for. Also asserts two distinct lock premises produce two evaluations. |
| `test_opencode_watch_arm_coalesces_callers_on_an_unchanged_lock` | The other half of cause A: two callers on an unchanged lock must share exactly one evaluation, so reintroducing the doubled subprocess walk fails the suite. |
| `test_watch_arm_login_shell_default_reaches_the_arm_child` | Both branches of the cause-B opt-out, for both adapters, via a temp `HOME` whose `.profile` exports a marker the arm child either does or does not observe. |

## Verification

- Date: 2026-08-19
- Command: `tests/fm-pi-watch-extension.test.sh`, run consecutively
- Code under proof: the implementation described above; this record adds no code
- Host: 32 cores
- Assertions per run: 32

| Phase | Conditions | Result |
|---|---|---|
| Idle | 1-minute load average 3.55 at phase start | **20/20 passed, 0 failed** |
| Loaded | 160 busy-loop processes on 32 cores (5x oversubscription) | **20/20 passed, 0 failed** |
| Total | | **40/40** |

No run was short of clean, and no assertion failed in either phase.

One caveat is recorded rather than dropped.
An earlier round run against a tree that was still missing one of the three EPIPE guards recorded 19/20 idle and 20/20 loaded.
That single idle failure recorded no failed assertion - the harness process terminated after 6 of 32 assertions with no output - and its cause was not established.
The 40/40 above is from the later round against the complete implementation and does not by itself explain that earlier termination.
