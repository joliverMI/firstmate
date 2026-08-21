# CI-red merge blind spot on `main`

Audience: maintainer verification.

This record answers a report that `joliverMI/firstmate`'s `main` had been failing CI on the portable serial shards for at least 11 hours, with merges continuing to land on top of it.
The report was already stale by the time it was investigated (2026-08-21): `main` was green, and the underlying test failure had already been root-caused and fixed - see [`arm-readiness-determinism-proof.md`](../arm-readiness-determinism-proof.md) for that cause analysis.
What survives as durable knowledge is not the fix - it is that nothing in this fork tells anyone when `main` goes red, and nothing stops a merge from landing on top of it while it is red.
That gap is unchanged today and is this record's subject.
Run-by-run and job-by-job chronology for the incident that prompted this record stays in that task's PR evidence; only the durable structural facts and the few numbers that size the gap are kept here.

## The gap: nothing here can stop or announce a red merge

`main` has no branch protection and no required status checks configured at all: `GET repos/joliverMI/firstmate/branches/main/protection` returns 404 `Branch not protected` (verified 2026-08-21).
`.github/workflows/ci.yml` runs on `push` to `main` (after a merge already landed) and on `pull_request` (against the PR's own diff, before merge) - there is no required-status-check gate on `main` itself, so by construction no merge here can ever be blocked by "is `main` currently red".

This is not hypothetical.
PR #1 merged at `2026-08-16T23:28:25Z`; its own post-merge check runs did not start until `2026-08-16T23:28:30Z`, five seconds later - there was no possible way to see that check's result before the merge that produced it landed.
The same structure applies to every merge in this fork: a PR's own `pull_request`-triggered CI can be green while an unrelated, already-red `main` sits unchecked, because nothing prompts anyone to look at `main`'s own CI state before merging into it.

No push-based or scheduled signal surfaces a red `main` run to anyone either.
The only way to learn `main` went red is to open the Actions tab or query the API for `main` specifically, and nothing in this fork's workflow currently prompts that.

## The compounding hazard: unqualified `gh` / `gh-axi` can target the wrong repository

`gh` resolves an unpinned fork clone's default repository to the fork's parent, so `gh run list` / `gh run view` (and `gh-axi`'s wrappers) without an explicit `--repo` report the public upstream `kunchenguid/firstmate` rather than this fork - even though `git remote -v` and `gh repo view` both correctly identify this fork as `origin`.
Anyone checking "is `main` red" that way - human or agent - can be shown a different repository's CI entirely, in either direction: missing a real problem here, or mistaking upstream's unrelated failures for this fork's.

This does not reproduce from a local checkout today.
As of 2026-08-21, `remote.origin.gh-resolved=base` is already set in both `/home/joliv/firstmate` and this task's worktree, so an unqualified `gh run list --branch main` / `gh-axi run list --branch main` returns this fork's runs and `gh repo set-default --view` reports `joliverMI/firstmate`.
The hazard is unchanged for any clone of this fork that has not been pinned that way, which is the default state of a fresh clone.

## How long it went unnoticed

The red period was not one continuous 11-hour stretch.
It was two separate windows, `2026-08-16T23:28Z` to `2026-08-17T21:03Z` (4 red runs) and `2026-08-18T13:22Z` to `2026-08-19T13:06Z` (3 red runs), separated by two fully green runs.
That is roughly 45 hours red across a ~62-hour span, in two windows each individually longer than the reported 11 hours.
The longest stretch inside window A with no pushes at all is `2026-08-17T00:19:36Z` (`e9e3d0c`, which itself pushed a red run) to `2026-08-17T14:08:03Z` (`4f0a4f5`): about 13h49m during which `main` simply sat red, unremediated, because nobody happened to look, not because anyone was blocked by it.
That single gap is longer than the 11 hours the original report claimed for the whole incident.

The two windows ended for different reasons, and the contrast matters.
Window A ended by luck: its closing merge (PR #6) touched none of the failing code or its tests, so an unrelated push simply happened to land on a non-failing run of the same flaky suite.
Window B ended by partial mitigation: PR #12 (`b19134b`) raised `FM_PI_ARM_READY_TIMEOUT_MS` / `FM_OPENCODE_ARM_READY_TIMEOUT_MS` in `tests/fm-pi-watch-extension.test.sh` from 250ms to 2000ms, and PR #11 (`882004e`, the first green run) replaced that suite's lock case's fixed 120ms sleep with a direct `coordinator.ensureArmed(...)` await.
[`arm-readiness-determinism-proof.md`](../arm-readiness-determinism-proof.md) calls those two changes `main`'s own independent partial mitigation for two of the four failing assertions.
Neither addressed the underlying `ensureArm` coalescing defect; the actual fix (PR #14, merged `2026-08-19T22:11:31Z`) landed after both windows had already closed.

## What the red runs actually looked like

Across the two windows, `main`'s push-triggered CI failed 7 times, with 8 failing serial jobs.

Six of those eight failed on assertions in `tests/fm-pi-watch-extension.test.sh` that PR #14's cause table attributes and fixes, and the logs show only two distinct assertions across all six:
`Pi must deliver the actionable wake after bounded hung-successor recovery` failed four times in a row (jobs `95243266311`, `95243272968`, `95249497126`, `95412020616`), then `OpenCode watch plugin must arm only when this session owns the fleet lock` failed twice (jobs `95726593907`, `95990618501`).
The same named assertion failing on four consecutive pushes to `main` and still going unnoticed is a stronger blind-spot finding than a rotating symptom would be, not a weaker one: this was not a hard-to-see signal that needed correlation across dissimilar failures, it was the identical line repeating, and nothing surfaced it.

The remaining two jobs, both in one run, are outside that suite's attributed causes:

- `not ok - spawn with --card should succeed` in `tests/fm-dashboard-card-link.test.sh` is explained and fixed.
  PR #11 (`882004e`) records that this suite's server-start wait "previously trusted `bin/fm-dashboard.sh`'s 1-second process-liveness sleep as proof the server was ready, which flakes on a busier CI runner (confirmed pre-existing on `main`, not introduced here)", and replaced it with a poll of the real `/api/health` check.
  The same PR added captured-output reporting to `tests/lib.sh`'s exit-code assertion, precisely because this failure could only ever report `expected exit 0, got 1`.
  The failure predates that merge and has not recurred since it.
  That job also logged `not ok - OpenCode watch plugin must not treat external healthy output as an owned arm`, which is in `tests/fm-pi-watch-extension.test.sh` but is not one of the two assertions PR #14's cause table covers.
- `not ok - next bounded scan did not resume with the following child` in `tests/fm-inactive-reconcile.test.sh` remains genuinely unattributed to any cause, and has not recurred.

Separately, two CI jobs on unrelated shards each hit `ci.yml`'s 15-minute `tests-portable-serial` timeout, confirmed by an identical GitHub check-run annotation ("The job has exceeded the maximum execution time of 15m0s"): one on 2026-08-17 inside window A, and one on 2026-08-21 (after the fix, and itself followed by a clean run).
Neither is attributed to the same cause as the suite failures.

## Current state

`main` is green: HEAD `e2786ac` (PR #17), CI run [`32443727353`](https://github.com/joliverMI/firstmate/actions/runs/32443727353), 12/12 jobs including both `Behavior portable serial 3` and `4`.
`git diff --stat b98e098..e2786ac -- .opencode .pi tests/fm-pi-watch-extension.test.sh` is empty: nothing has touched the fixed code since PR #14 merged.
Every run since `32256268913` (2026-08-19T13:06Z, PR #11) that reached a test result has been green, spanning several further merges.
The one exception in that span is not a test failure: run `32441040308` (2026-08-21T02:46Z, PR #16) concluded `cancelled` because `Behavior portable serial 2` hit the 15-minute job cap, the second of the two timeouts noted above.

## Named remaining work

None of the following is implemented here; each is a decision or a follow-up, not a defect fixed by this record.

- **No branch protection on `main`.** Whether to add required status checks (and which ones) is a policy decision that changes how every future merge to this fork works - left to the captain/Admiral rather than decided unilaterally here.
- **No red-`main` notification of any kind.** This record deliberately does not propose or build one; it only names the gap, per instruction.
- **The `gh` / `gh-axi` default-repo-resolution hazard** should be flagged to whoever owns tooling defaults for this fleet: an unqualified `run list`/`run view` silently targets the upstream parent instead of the configured fork in any clone that has not pinned `remote.origin.gh-resolved`.
- **One non-suite test failure** (`tests/fm-inactive-reconcile.test.sh`) **and two 15-minute shard timeouts** remain unattributed to any specific cause. Neither class has recurred since - evidence of absence, not proof of a fix.
