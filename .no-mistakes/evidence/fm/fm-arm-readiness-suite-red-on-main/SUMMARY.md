# Arm-readiness determinism: independent test-phase verification

Host: 32 cores, Linux (WSL2), node v22.23.2. "Under load" = 160 busy-loop
processes on 32 cores (5x oversubscription), 1-minute load average 56-164
during the phase. All suite runs are the whole file
`tests/fm-pi-watch-extension.test.sh` (32 assertions per run).

## 1. Repeated-run proof of the shipped tree

| Phase | Conditions | Result | Log |
|---|---|---|---|
| Idle | load avg 0.7 at start | **20/20 runs passed**, 0 failed, 32/32 assertions each | `repeat-runs-idle.log` |
| Loaded | 160 busy loops, load avg 47 -> 164 | **20/20 runs passed**, 0 failed, 32/32 assertions each | `repeat-runs-under-load.log` |
| **Total** | | **40/40** | |

Pre-fix baseline (`03bb1d8`, the red-on-main tree) under the *same* synthetic
load: **0/10 runs passed** (`repro-baseline-under-load.log`). Every failure
aborted the suite after 2 assertions on
`Pi redundant tool call must remain an ownership-based no-op with repair-only guidance`
— the harness exits on first failure, so under 5x load the baseline never even
reached the four assertions named in the report. That is a fifth case sharing
cause B, not a different problem.

## 2. Which of the four assertions share a cause

Two causes, two assertions each. Both were isolated by reverting exactly one
thing at a time, everything else at the shipped commit.

| Assertion | Cause | Isolation result |
|---|---|---|
| `OpenCode watch plugin must arm only when this session owns the fleet lock` (both occurrences) | **A — production race in `ensureArm`** | With only the `ensureArm` premise check reverted (login-shell opt-out and EPIPE guards left in), fails **deterministically on an idle machine**: `the reacquired-lock arm attempt never settled`. Shipped tree: passes. `cause-isolation-transcript.log` A1/A2 |
| `Pi must deliver the actionable wake after bounded hung-successor recovery` | **B — test window racing login-shell startup** | With only `FM_WATCH_ARM_NO_LOGIN_SHELL=1` removed from the suite: **0/10 under load**; shipped: **10/10 under the same load**. `repro-cause-b-login-shell.log` |
| `Pi must fall back without overlapping an unretired successor` | **B — same** | Same isolation, run on its own: **0/10 under load**; shipped: **10/10**. `repro-cause-b-second-assertion.log` |

Cause B is measurable directly on this host: `bash -lc true` costs ~130 ms idle,
`bash -c true` ~0 ms, against a `FM_PI_ARM_READY_TIMEOUT_MS=250` /
`FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20` window.

## 3. The fix is not a papered-over timeout, and nothing was disabled

- No readiness/retire timeout value changed anywhere in the diff: the adapter
  defaults are still 12000 (35000 on Windows), and the two timed cases still
  assert on `FM_PI_ARM_READY_TIMEOUT_MS=250` / `FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20`,
  exactly as on the base commit.
- No test invocation was removed, skipped, or marked flaky: the invocation list
  went 30 -> 32, and the two additions are new cases.
- The production login shell is still the default and is *pinned*: flipping both
  adapters to `bash -c` makes `test_watch_arm_login_shell_default_reaches_the_arm_child`
  fail (`expected marker=sourced, got: marker=absent`).
  `cause-isolation-transcript.log` A4.
- The coalescing guard is pinned in the other direction too: replacing the
  premise check with "never share" (the rejected serialize-everything shape)
  fails the new coalescing case with `must share one evaluation, got 2`.
  `cause-isolation-transcript.log` A3.

## 4. Gap found and closed by this test phase

The three unhandled-EPIPE guards shipped with no automated coverage. On the real
adapter path (`.opencode/plugins/lib/fm-operational-input.js`), an encoder that
exits before draining a body larger than the pipe buffer kills the whole host
process without the guard, and is a normal per-call rejection with it —
`epipe-guard-transcript.log`. A focused regression test for that was added to
`tests/fm-operational-input.test.sh`; it fails against the adapter with the
listener removed and passes on the shipped tree, and it is itself stable
(10/10 under the same 5x load, `new-test-stability-under-load.log`).
