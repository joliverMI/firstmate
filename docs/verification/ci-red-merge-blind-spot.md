# CI-red merge blind spot on `main`

Audience: maintainer verification.

This record answers a report that `joliverMI/firstmate`'s `main` had been failing CI on the portable serial shards for at least 11 hours, with merges continuing to land on top of it.
The report was already stale by the time it was investigated (2026-08-21): `main` was green, and the underlying test failure had already been root-caused and fixed - see [`arm-readiness-determinism-proof.md`](../arm-readiness-determinism-proof.md) for that cause analysis.
What survives as durable knowledge is not the fix - it is that nothing in this fork tells anyone when `main` goes red, and nothing stops a merge from landing on top of it while it is red.
That gap is unchanged today and is this record's subject.

## The gap: nothing here can stop or announce a red merge

`main` has no branch protection and no required status checks configured at all: `GET repos/joliverMI/firstmate/branches/main/protection` returns 404 `Branch not protected` (verified 2026-08-21).
`.github/workflows/ci.yml` runs on `push` to `main` (after a merge already landed) and on `pull_request` (against the PR's own diff, before merge) - there is no required-status-check gate on `main` itself, so by construction no merge here can ever be blocked by "is `main` currently red".

This is not hypothetical. PR #1 merged at `2026-08-16T23:28:25Z`; its own post-merge check runs did not start until `2026-08-16T23:28:30Z`, five seconds later - there was no possible way to see that check's result before the merge that produced it landed.
The same structure applies to every merge in this fork: a PR's own `pull_request`-triggered CI can be green while an unrelated, already-red `main` sits unchecked, because nothing prompts anyone to look at `main`'s own CI state before merging into it.

No push-based or scheduled signal surfaces a red `main` run to anyone either.
The only way to learn `main` went red is to open the Actions tab or query the API for `main` specifically, and nothing in this fork's workflow currently prompts that.

A second, compounding hazard was discovered firsthand while investigating this report: checking CI status with `gh-axi run list` / `gh-axi run view` (and plain `gh run list`) without an explicit `--repo` flag silently resolves to the public upstream `kunchenguid/firstmate`, not this fork - even though `git remote -v` and `gh repo view` both correctly identify this fork as `origin`.
An unqualified `gh-axi run list --branch main` returned run IDs and titles belonging to `kunchenguid/firstmate`; the same command with `--repo joliverMI/firstmate` returned this fork's real, much shorter history.
Anyone checking "is `main` red" this way - human or agent - can be shown a different repository's CI entirely, in either direction: missing a real problem here, or mistaking upstream's unrelated failures for this fork's.

## How long it actually went unnoticed

The red period was not one continuous 11-hour stretch; it was two separate windows, separated by two fully green runs:

| Window | Start | End | Duration | Runs |
|---|---|---|---|---|
| A | 2026-08-16T23:28:28Z (`31979227412`) | 2026-08-17T21:03:40Z (`32069112707`, green) | ~21h35m | 4 red runs, then green |
| (green interlude) | 2026-08-17T21:03Z | 2026-08-18T13:22Z | ~16h19m | 2 green runs (`32069112707`, `32086156100`) |
| B | 2026-08-18T13:22:30Z (`32141985026`) | 2026-08-19T13:06:48Z (`32256268913`, green) | ~23h44m | 3 red runs, then green |

Total: roughly 45 hours red across a ~62-hour span, in two separate windows each longer than the reported 11 hours - not a single, shorter incident.
Window A contains a roughly 7-hour gap (2026-08-17T14:08Z to 21:03Z) with no pushes at all: `main` simply sat red, unremediated, because nobody happened to look, not because anyone was blocked by it.

Both windows ended only because a later, unrelated push happened to land on a lucky (non-failing) run of the same flaky suite, not because anything detected or fixed the problem at the time.
The actual fix (PR #14) landed on 2026-08-20, after both windows had already closed on their own.

## What the red runs actually looked like (the visible symptom)

Across the two windows, `main`'s push-triggered CI failed 7 times, with 8 failing serial jobs.
Six of those eight failed on assertions in `tests/fm-pi-watch-extension.test.sh` that PR #14's cause table attributes and fixes (jobs `95243266311`, `95243272968`, `95249497126`, `95412020616`, `95726593907`, `95990618501`) - a different assertion nearly every time, which is what made each individual red run easy to read as an isolated flake rather than a systemic defect.
The other two jobs, both in run `32150616824`, are outside that suite and are not attributed to any specific fix here: `not ok - next bounded scan did not resume with the following child` in `tests/fm-inactive-reconcile.test.sh` (job `95755272021`), and `not ok - spawn with --card should succeed` in `tests/fm-dashboard-card-link.test.sh` (job `95755272024`, which also logged `OpenCode watch plugin must not treat external healthy output as an owned arm` - in the same suite as the attributed causes, but not one of the two the cause table covers).
Neither of the two non-suite tests has failed in any run since.

A separate, unexplained anomaly co-occurred but is not attributed to the same cause: two CI jobs on unrelated shards each hit `ci.yml`'s 15-minute `tests-portable-serial` timeout, confirmed by an identical GitHub check-run annotation ("The job has exceeded the maximum execution time of 15m0s") - `Behavior portable serial 3` in run `32037964172` (2026-08-17, inside window A) and `Behavior portable serial 2` in run `32441040308` (2026-08-21, after the fix, and itself followed by a clean run).

## Current state

`main` is green: HEAD `e2786ac` (PR #17), CI run [`32443727353`](https://github.com/joliverMI/firstmate/actions/runs/32443727353), 12/12 jobs including both `Behavior portable serial 3` and `4`.
`git diff --stat b98e098..e2786ac -- .opencode .pi tests/fm-pi-watch-extension.test.sh` is empty: nothing has touched the fixed code since PR #14 merged.
`main` has run green continuously since `32256268913` (2026-08-19T13:06Z, PR #11), spanning several further merges.

## Named remaining work

None of the following is implemented here; each is a decision or a follow-up, not a defect fixed by this record.

- **No branch protection on `main`.** Whether to add required status checks (and which ones) is a policy decision that changes how every future merge to this fork works - left to the captain/Admiral rather than decided unilaterally here.
- **No red-`main` notification of any kind.** This record deliberately does not propose or build one; it only names the gap, per instruction.
- **The `gh` / `gh-axi` default-repo-resolution hazard** should be flagged to whoever owns tooling defaults for this fleet: an unqualified `run list`/`run view` silently targets the upstream parent instead of the configured fork.
- **Two non-suite test failures** (`tests/fm-inactive-reconcile.test.sh`, `tests/fm-dashboard-card-link.test.sh`) **and two 15-minute shard timeouts** remain unattributed to any specific cause. Neither class has recurred since - evidence of absence, not proof of a fix.
