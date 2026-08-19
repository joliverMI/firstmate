# Arm-readiness determinism - independent test evidence

Branch `fm/fm-arm-readiness-suite-red-on-main-r1` @ `a15d993`, base `main` @ `45bd292`.
Host: 32 cores, Linux (WSL2), node v22.23.2, bash 5.2.21. Date 2026-08-19.
Suite under proof: `tests/fm-pi-watch-extension.test.sh` (32 assertions per run).

## Repeated-run proof of the fixed tree (exact counts)

| Phase | Conditions | Runs passed | Runs failed | Per-run assertions ok |
|---|---|---|---|---|
| Idle | loadavg 0.29-1.05 throughout | **20** | **0** | 32/32 every run |
| Loaded | 160 busy-loop processes on 32 cores (5x oversubscription), loadavg 113 -> 163 | **20** | **0** | 32/32 every run |
| Total | | **40** | **0** | |

Raw per-run logs: `idle-phase.txt`, `loaded-phase.txt`, `logs/idle-run*.log`, `logs/loaded-run*.log`.
Idle runs took ~34s each; loaded runs ~51-55s each. No run was short of clean.

## Pre-change controls (the regressions actually reproduce)

| Control | Change applied to the tree | Result |
|---|---|---|
| Cause A - production race | `ensureArm` reverted to unconditional in-flight reuse (`if (launchInFlight)`) | `not ok - OpenCode watch plugin must arm only when this session owns the fleet lock`, failing on the 20s guard with `the reacquired-lock arm attempt never settled` - exactly as the proof doc predicts (`negative-control-cause-a.log`) |
| Cause A - coalescing half | same pre-change `ensureArm`, lock case skipped | `ok - OpenCode watcher plugin coalesces callers that share a lock premise` - the new coalescing test does NOT catch cause A, as documented (`negative-control-cause-a-coalescing.log`) |
| Rejected serialized variant | `ensureArm` rewritten to queue callers (no sharing) | lock case deadlocks (`never settled`); coalescing case fails with `two callers on an unchanged lock must share one evaluation, got 2` - both documented claims confirmed (`negative-control-serialized-*.log`) |
| EPIPE guard | `child.stdin.on("error")` removed from `.opencode/plugins/lib/fm-operational-input.js` | host node process dies with an unhandled `EPIPE` on the stdin socket; `not ok - OpenCode adapter host died (exit 1)...` (`negative-control-epipe.log`). With the guard: `ok - an encoder that exits before reading fails one call, not the host session` |
| Cause B - pre-change suite file | base `45bd292` copy of the suite file on the same tree, under load | 5x load: **0/10 runs passed**; 1.5x load (48 loops): **3/12 runs passed**, and the failing assertion differed by run and by load level (`baseline-control.txt`, `baseline-control-moderate.txt`) |

Pre-change failing assertions observed across the 22 baseline runs:
`Pi extension must surface an external healthy watcher as an owned-wake failure` (2),
`Pi redundant tool call must remain an ownership-based no-op with repair-only guidance` (8),
`Pi established clean closes must honor the continuity retry limit` (5),
`OpenCode established clean closes must honor the continuity retry limit` (4).
Same signature the report describes (a different assertion most runs); on this host the load
happened to expose different members of the same suite-wide login-shell dependence than the four
originally reported.

## Login-shell cost re-measurement (the figure the proof doc's headroom arguments rest on)

`bash -lc true` vs `bash -c true`, wall clock in ms:

| Conditions | `bash -lc true` | `bash -c true` |
|---|---|---|
| Idle (20 samples) | min 129 / median 131 / max 140 | 1 / 1 / 1 |
| 160 loops on 32 cores, loadavg ~151 (30 samples) | min 1096 / median ~1620 / max **4246** (two samples above 3.9s) | 4 / 8 / 20 |

The idle figure matches the documented `~140ms`. The loaded worst case does not: the suite header
and `docs/arm-readiness-determinism-proof.md` both state `~1150ms (max 1740ms)` under contention.
Raw samples in `login-shell-cost-idle.txt` and `login-shell-cost-loaded-steady.txt`.

## Constraint checks

- No timeout value is raised by this change: no `FM_*_TIMEOUT_MS` default or export is modified in the diff.
- No test is deleted, skipped, or marked flaky: the base suite ran 30 assertions per run, this one runs 32 (two added cases).
- Tree restored after every control; `git status --porcelain` clean and HEAD still `a15d993`, suite green on the restored tree (`post-experiment-verification.log`).
