# CI-red merge blind spot on `main`

Audience: maintainer verification.

This record answers a report that `joliverMI/firstmate`'s `main` had been failing CI on the portable serial shards for at least 11 hours, with merges continuing to land on top of it.
The report was already stale by the time it was investigated (2026-08-21): `main` was green, and the underlying test failure had already been root-caused and fixed - see [`arm-readiness-determinism-proof.md`](../arm-readiness-determinism-proof.md) for that cause analysis.
What survives as durable knowledge is not the fix - it is that nothing in this fork's own configuration tells anyone when `main` goes red, and nothing stops a merge from landing on top of it while it is red.
That gap is unchanged today and is this record's subject.
Run-by-run and job-by-job chronology for the incident that prompted this record stays in that task's PR evidence; only the durable structural facts and the few numbers that size the gap are kept here.

## The gap: nothing here can stop or announce a red merge

`main` has no branch protection and no required status checks configured at all: `GET repos/joliverMI/firstmate/branches/main/protection` returns 404 `Branch not protected` (verified 2026-08-21).
`.github/workflows/ci.yml` runs on `push` to `main` (after a merge already landed) and on `pull_request`, and neither is a gate: with no required status check configured, nothing blocks a merge regardless of what either run reported.

A `pull_request` run is not blind to `main`, and this record does not claim otherwise.
`actions/checkout@v6` in `.github/workflows/ci.yml` sets no `ref:`, so the run checks out `refs/pull/N/merge` - the PR's head already merged into `main`'s tip at that moment.
PR #6's pre-merge job log shows exactly that: `HEAD is now at b57e38c Merge 213584d... into 4f0a4f5...`, where `4f0a4f5` was `main`'s red tip.

PR #12 shows what that mechanism actually produced, with the timing that makes it count.
Its pre-merge run `32226547720` checked out `Merge 7e98282... into 3c8f796...`, and `3c8f796` was `main`'s red tip at the time - that commit's own push run `32150616824` had failed.
All four serial shards passed, and the run concluded `success` at `2026-08-19T07:22:15Z`, 1m52s before PR #12 merged at `07:24:07Z`.
A completed green verdict against a red `main` therefore did exist before that merge, and PR #12's own post-merge push run `32227657272` then went red again immediately.
A pre-merge run against a red `main` is real evidence that can still read "green", because the failure was intermittent rather than deterministic.
That is a harder problem than an unchecked merge would be.

Nor does a PR's own run have to finish before its merge lands.
PR #6 merged at `2026-08-17T21:03:36Z` while its own CI run `32068680937` was still in progress; that run did not complete until `21:11:16Z`, 7m40s after the merge.
Push-triggered CI is necessarily later still: PR #1 merged at `2026-08-16T23:28:25Z` and its post-merge checks did not start until `2026-08-16T23:28:30Z`.

Repository configuration surfaces nothing on its own: there is no branch protection, and no workflow here wires up any notification, issue-filing, or alert step.
Beyond the repository, GitHub Actions does notify by default - the actor who triggered a run is emailed when that run fails, which here is the account performing each merge to `main`.
That path is unverified: it depends on per-account notification settings this investigation had no access to.
If it behaved as documented, a failure notification most likely reached that account on each of the seven red pushes, and nothing was acted on for roughly 45 hours regardless.
That is the more serious of the two available readings.
Either nobody was told, which is a tooling gap, or somebody probably was told and it changed nothing, which is a process gap - and the evidence better supports the second.

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
Window A ended by luck: its closing merge (PR #6) touched none of the failing code or its tests, so an unrelated push simply happened to land on a non-failing run of the same intermittent suite.
Window B ended because the test that could see the failure stopped being able to see it.
Two of window B's three failures from that suite were `OpenCode watch plugin must arm only when this session owns the fleet lock`, and the first green run that closed the window was PR #11 (`882004e`), which replaced that exact case's fixed 120ms sleep with a direct `coordinator.ensureArmed(...)` await.
[`arm-readiness-determinism-proof.md`](../arm-readiness-determinism-proof.md) records what that did and did not do: the await "is what stops this branch's inherited copy of that case from reconstructing cause A", and of the changes already on `main` at that point, "None of those addresses cause A".
The production `ensureArm` race was still there; only the test's ability to reproduce it had changed.
Nobody noticed that shift either, which is the same blind spot in a more damaging form - the window closed because the witness was removed, not because the defect was.
PR #14 (merged `2026-08-19T22:11:31Z`) is what actually fixed the race, after both windows had already closed.

PR #12 (`b19134b`) does not belong in that story, even though it landed inside window B and raised `FM_PI_ARM_READY_TIMEOUT_MS` / `FM_OPENCODE_ARM_READY_TIMEOUT_MS` in `tests/fm-pi-watch-extension.test.sh` from 250ms to 2000ms.
Its own push run was window B's last red run, and the raise applies only to this suite's six unready-arm cases, none of whose assertions failed anywhere in window B.
The only one of those that ever failed on `main` at all - `Pi must deliver the actionable wake after bounded hung-successor recovery` - is window A's failure signature.

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
  That job also logged `not ok - OpenCode watch plugin must not treat external healthy output as an owned arm`, which is in `tests/fm-pi-watch-extension.test.sh` but is not one of the assertions PR #14's cause table covers.
  No mechanism has been found for it.
  An earlier revision of this record proposed one - PR #14's suite-wide `export FM_WATCH_ARM_NO_LOGIN_SHELL=1` stripping a profile-sourcing cost out of this case's bounded wait - and it is wrong on inspection, on two independent grounds.
  The 250-by-20ms guard-log loop runs only after `await guardHooks.event(...)` has already resolved, and the arm spawn lives inside that awaited call via `letWatchArmRun` into `coordinator.ensureArmed`, so a slow profile lengthens the await rather than expiring the later loop.
  And overrunning the readiness budget (the 12s default, which this case does not override) resolves `"timeout"`, which `letWatchArmRun` does not accept, so the guard would have run rather than been suppressed - the opposite of the failure actually logged.
  This is the second such withdrawal in drafting this record: an earlier round made the same kind of unsupported-mechanism claim about a load-dependent `FM_HOME` failure and dropped it once the reasoning was checked, with the detail kept in this task's PR evidence.
  The corrected practice is to record that no mechanism is known rather than reason toward a plausible one, since a story that merely sounds right is the same substitute for verification this record exists to name.
- `not ok - next bounded scan did not resume with the following child` in `tests/fm-inactive-reconcile.test.sh` remains genuinely unattributed to any cause, and has not recurred.

Separately, two CI jobs hit `ci.yml`'s 15-minute `tests-portable-serial` timeout, confirmed by an identical GitHub check-run annotation ("The job has exceeded the maximum execution time of 15m0s").
Neither is attributed to any cause, and they fall on different shards relative to the original report.
The first is job `95412020578`, `Behavior portable serial 3` - one of the two shards the report named - cancelled at `2026-08-17T14:23:26Z`, not beside the red runs but inside one of them, red run `32037964172`, whose shard 4 failed an assertion in the same run.
It is the only shard-3 non-success anywhere in window A: all four of window A's assertion failures were shard 4 (jobs `95243266311`, `95243272968`, `95249497126`, `95412020616`).
It is not, however, the whole of the "shard 3" half of the reported premise, because shard 3 also failed on real assertions twice inside window B: jobs `95755272024` (run `32150616824`, 2026-08-18T14:48Z) and `95990618501` (run `32227657272`, 2026-08-19T07:24Z).
This timeout also concluded `cancelled` rather than `failure`, so the count of 8 failing serial jobs above excludes it; a maintainer tallying every non-green serial job across the two windows will count 9.
The second is job `96651633862`, `Behavior portable serial 2` - a shard the report did not name - on 2026-08-21, after both windows and after PR #14, and itself followed by a clean run, which shows the class is still live.

## Current state

Observed 2026-08-21; this section is a dated snapshot, not a standing claim.
`main` was green at HEAD `e2786ac` (PR #17), CI run [`32443727353`](https://github.com/joliverMI/firstmate/actions/runs/32443727353), 12/12 jobs including both `Behavior portable serial 3` and `4`.
`main` has since advanced to `5a53eee`, whose push run [`32493420147`](https://github.com/joliverMI/firstmate/actions/runs/32493420147) (2026-08-21T14:40Z) also succeeded.
`git diff --stat b98e098..e2786ac -- .opencode .pi tests/fm-pi-watch-extension.test.sh` is empty: nothing has touched the fixed code since PR #14 merged.
Every run since `32256268913` (2026-08-19T13:06Z, PR #11) that reached a test result has been green, spanning several further merges.
The one exception in that span is not a test failure: run `32441040308` (2026-08-21T02:46Z, PR #16) concluded `cancelled` because `Behavior portable serial 2` hit the 15-minute job cap, the second of the two timeouts noted above.

## Named remaining work

None of the following is implemented here; each is a decision or a follow-up, not a defect fixed by this record.

- **No branch protection on `main`.** Whether to add required status checks (and which ones) is a policy decision that changes how every future merge to this fork works - left to the captain/Admiral rather than decided unilaterally here.
- **No red-`main` notification wired in this repository.** This record deliberately does not propose or build one; it only names the gap, per instruction. GitHub's own default actor notification may already cover the "was anyone told" half, in which case the gap left to close is response rather than delivery.
- **The `gh` / `gh-axi` default-repo-resolution hazard** should be flagged to whoever owns tooling defaults for this fleet: an unqualified `run list`/`run view` silently targets the upstream parent instead of the configured fork in any clone that has not pinned `remote.origin.gh-resolved`.
- **Two test failures and the 15-minute shard timeouts** remain without a confirmed cause. Neither `tests/fm-inactive-reconcile.test.sh` nor `OpenCode watch plugin must not treat external healthy output as an owned arm` has any surviving candidate explanation; the one drafted for the latter was checked against the source and disproved, as described above. Neither test failure has recurred, which is evidence of absence rather than proof of a fix; the timeout class demonstrably did recur (job `96651633862`, run `32441040308`, 2026-08-21T02:46Z), after both windows and after PR #14.
