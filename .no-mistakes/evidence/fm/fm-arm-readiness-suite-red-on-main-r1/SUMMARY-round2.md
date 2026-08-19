# Round 2 - re-validation after the stale-figure correction (`9c67804`)

Branch `fm/fm-arm-readiness-suite-red-on-main-r1` @ `9c67804`, base `main` @ `45bd292`.
Host: 32 cores (WSL2), node v22.23.2. Date 2026-08-19. Suite: `tests/fm-pi-watch-extension.test.sh`, 32 assertions per run.

Round 1's only finding was that the change's headroom arguments rested on an inherited, understated
`bash -lc` contention figure (`~1150ms`, max `1740ms`). `9c67804` re-states those figures and rewords the
arguments built on them. This round re-ran the whole proof from scratch against the corrected commit.

## 1. Determinism, re-run independently (exact counts)

| Phase | Conditions | Passed | Failed |
|---|---|---|---|
| Idle | 1-min load average 0.9 at phase start | **20** | **0** |
| Loaded | 160 busy loops on 32 cores (5x oversubscription), load average 141 -> 162 | **20** | **0** |
| **Total** | | **40** | **0** |
| Control: pre-change suite (`45bd292` copy), same host, same 5x load | | **0** | **4** |

Every control run failed on `Pi redundant tool call must remain an ownership-based no-op with repair-only
guidance` - the same assertion round 1 recorded as this host's most frequent baseline failure (8 of 22),
and consistent with the doc's stated nuance that this host exposes a different subset than the original report.
Raw counts: `determinism-run-counts.txt`.

## 2. The corrected figures re-measured independently

| Measurement | Cited by `9c67804` | Re-measured this round | Verdict |
|---|---|---|---|
| `bash -lc` idle | ~131ms median (min 129 / max 140) | 130ms median (min 128 / max 139) | matches |
| `bash -lc` at 5x load | min 1096 / median ~1620 / max 4246ms | min 1289 / median 1740 / max 4527ms | matches within load-to-load variance; worst case 6.6% higher |
| `bash -c` | ~1ms idle, 4-20ms loaded | 1ms idle, 1-20ms loaded (median 5ms) | matches |

Every conclusion the change now draws from those figures still holds on the fresh numbers: the loaded worst
case sits above `main`'s raised 2000ms budget (4527 > 2000); a 5s budget leaves ~10% headroom, so withdrawing
the old "ample headroom" exclusion was correct; and the residual 10s login-shell bound is ~2.2x the worst case,
which the doc labels a headroom argument rather than a guarantee. Detail: `login-shell-cost-remeasurement.txt`.

## 3. Regression claims re-reproduced by reverting each fix

| Reverted | Expected per the change's own regression table | Observed |
|---|---|---|
| `ensureArm` premise check -> unconditional in-flight reuse | lock case fails its 20s settling guard with "the reacquired-lock arm attempt never settled" | reproduced verbatim |
| same revert, coalescing case only | still passes (so it does not itself catch cause A) | reproduced |
| `child.stdin.on("error")` EPIPE guard removed | host node process dies with unhandled EPIPE; test reports the host as dead | reproduced |

Restoring each fix returned both suites to green. Detail: `regression-revert-reproduction.txt`.
The third table row (the rejected fully-serialized variant) was reproduced in round 1 and is unchanged by
`9c67804`: see `negative-control-serialized-variant.log` and `negative-control-serialized-coalescing.log`.
