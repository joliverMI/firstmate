# Targeted suite results for the lineage-unification merge (HEAD 6bfdd22, merge df9d8e7)

## First pass (26 suites, before the fleet-audit fixture port) - targeted-suites.log
    tests/fm-decision-hold-lifecycle.test.sh exit=0
    tests/fm-crew-state.test.sh exit=0
    tests/fm-send-remote-delivery.test.sh exit=0
    tests/fm-procevent.test.sh exit=0
    tests/fm-procevent-river.test.sh exit=0
    tests/fm-test-run.test.sh exit=0
    tests/fm-backlog-handoff.test.sh exit=0
    tests/fm-remote-backlog-handoff.test.sh exit=0
    tests/fm-bearings-board.test.sh exit=0
    tests/fm-pending-reply.test.sh exit=0
    tests/fm-remote-reply.test.sh exit=0
    tests/fm-peek-remote.test.sh exit=0
    tests/fm-dashboard.test.sh exit=0
    tests/fm-status-board.test.sh exit=0
    tests/fm-fleet-audit.test.sh exit=1
    tests/fm-remote-update-follows-fork.test.sh exit=0
    tests/fm-pr-destination-guard.test.sh exit=0
    tests/fm-watch-arm.test.sh exit=0
    tests/fm-watch-triage.test.sh exit=0
    tests/fm-send-secondmate-marker.test.sh exit=0
    tests/fm-send-resolve-key.test.sh exit=0
    tests/fm-send-strict.test.sh exit=0
    tests/fm-backend-herdr.test.sh exit=0
    tests/fm-documentation-audiences.test.sh exit=0
    tests/fm-spawn-pool-worktree-collision.test.sh exit=0
    tests/fm-lint.test.sh exit=0

## Failing assertion on the first pass
    not ok - fixture did not produce a blocked crew state for audit-crew-testing: state: unknown · source: remote-endpoint · unknown-remote: elsewhere unreachable or endpoint unreadable (not proof of death)
    cause: the fork's fleet-audit fixture used remote_host=elsewhere with no transport, relying on the old
           local-read workaround; the merged truthful-remote-read reports unknown-remote for an unreachable host
           (the behaviour the plan requires), so the fixture no longer produced a definite blocked state.
    fix:   tests/fm-fleet-audit.test.sh now stubs fm-on.sh's ssh transport (FM_SSH_BIN) to answer alive and
           registers each fixture crew in data/secondmates.md, mirroring tests/fm-crew-state.test.sh's remote suite.

## tests/fm-fleet-audit.test.sh after the fixture port
    rerun 1 (fleet-audit-rerun.log):  crew-state fixture assertion now passes; one later timing-sensitive
      assertion (force endpoint refusal under FM_AUDIT_MAX_SWEEP_SECONDS=2) missed once
      not ok - force endpoint should have refused while a sweep is already claimed
      FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=54489
    rerun 2 (fleet-audit-rerun2.log): FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=55066
    fork parent 879fd1e baseline, temp copy (fleet-audit-fork-parent.log): FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=59106

## Not reproducible here
    The plan's equivalence check against trial resolution b93cc26 could not be re-run: that scratch commit is not
    present in this worktree's object store (git cat-file -t b93cc26 -> not a valid object name).
