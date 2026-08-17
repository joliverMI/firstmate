#!/usr/bin/env bash
# Behavior tests for the render-from-state web status board.
# Covers section order/labels, the fixed dedup rule, expandable full-detail
# rendering (untruncated body text, clickable PR links), the ready-to-merge
# reclassification, the "ready: " marker that promotes a landed item into
# Ready for you to look at, and HTML escaping of state-sourced text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-status-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/fixture-working" "$home/projects/fixture-ready"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] fixture-ready - Ready to merge task (repo: alpha) (kind: ship) (since 2026-08-01)

## Queued
- [ ] fixture-decision - Decision needed & overdue (repo: alpha) (kind: captain) (since 2026-08-01) (hold: Approve the thing) (hold-kind: captain)
  Full free-form texture paragraph, with a caveat that only belongs in the expanded detail.
- [ ] fixture-waiting - Waiting task (repo: alpha) (kind: ship) (since 2026-08-01) (hold: blocked on upstream review) (hold-kind: task)
- [ ] fixture-working - Working task <urgent> (repo: alpha) (kind: ship) (since 2026-08-01)

## Done
- [x] fixture-done - Done task https://github.com/kunchenguid/firstmate/pull/42 (repo: alpha) (kind: ship) (done 2026-08-10)
EOF
  # fixture-working is filed as still Queued in the backlog (a not-yet-updated
  # row, exactly the live drift observed in production) while its own live
  # state is genuinely working. This exercises the cross-section dedup rule:
  # in-progress (the fresher signal) must win and the stale Queued row must
  # not also double it into Waiting.
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" fixture-working)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" fixture-working busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/fixture-working.meta" \
    "window=firstmate:fm-fixture-working" \
    "worktree=$home/projects/fixture-working" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"

  # A ready-to-merge task: an idle busy record plus no matching run lets
  # fm-crew-state fall back to the status log's last recognized-verb line
  # ("done" - fm-crew-state's vocabulary for terminal passed/checks-passed).
  fm_write_meta "$home/state/fixture-ready.meta" \
    "window=firstmate:fm-fixture-ready" \
    "worktree=$home/projects/fixture-ready" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" fixture-ready)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" fixture-ready idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'done: checks green\n' > "$home/state/fixture-ready.status"
}

# fm-status-board.sh shells out to fm-fleet-snapshot.sh for detail lookups,
# which reads tmux for pane fallback; a minimal fake keeps that path quiet.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf 'zsh\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

test_empty_fleet_renders_all_empty_states() {
  local home out
  home=$(make_home empty)
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD")
  assert_contains "$out" "<h1>Fleet status</h1>" "board should render a title"
  assert_contains "$out" "Nothing needs your action right now." "empty needs-captain sentence"
  assert_contains "$out" "Nothing is ready for you to look at right now." "empty ready sentence"
  assert_contains "$out" "Nothing is in progress right now." "empty in-progress sentence"
  assert_contains "$out" "Nothing is waiting right now." "empty waiting sentence"
  assert_contains "$out" "No recent completions are in the current baseline." "empty landed sentence"
  assert_contains "$out" "What this board cannot show" "disclosure section must always render"
  pass "an empty fleet renders all five empty-state sentences plus the disclosure section"
}

test_section_order() {
  local home fakebin out i_needs i_ready i_progress i_wait i_done
  home=$(make_home order)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD")
  i_needs=$(printf '%s' "$out" | grep -bo '<section id="needs-captain"' | head -1 | cut -d: -f1)
  i_ready=$(printf '%s' "$out" | grep -bo '<section id="ready"' | head -1 | cut -d: -f1)
  i_progress=$(printf '%s' "$out" | grep -bo '<section id="in-progress"' | head -1 | cut -d: -f1)
  i_wait=$(printf '%s' "$out" | grep -bo '<section id="waiting"' | head -1 | cut -d: -f1)
  i_done=$(printf '%s' "$out" | grep -bo '<section id="recently-completed"' | head -1 | cut -d: -f1)
  [ -n "$i_needs" ] && [ -n "$i_ready" ] && [ -n "$i_progress" ] && [ -n "$i_wait" ] && [ -n "$i_done" ] \
    || fail "all five sections must be present"
  [ "$i_needs" -lt "$i_ready" ] && [ "$i_ready" -lt "$i_progress" ] && [ "$i_progress" -lt "$i_wait" ] && [ "$i_wait" -lt "$i_done" ] \
    || fail "sections must render in order: needs-captain, ready, in-progress, waiting, recently-completed"
  pass "the five sections render in the captain's fixed order"
}

test_decision_and_texture_and_dedup() {
  local home fakebin out count in_progress_block waiting_block
  home=$(make_home content)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD")
  assert_contains "$out" "DECISION" "a captain-hold decision should be tagged"
  assert_contains "$out" "Decision needed &amp; overdue" "decision title must be HTML-escaped"
  assert_contains "$out" "Full free-form texture paragraph, with a caveat that only belongs in the expanded detail." \
    "the backlog free-form note must appear untruncated in the expandable detail"
  assert_contains "$out" "Working task &lt;urgent&gt;" "in-progress title must be HTML-escaped, not raw HTML"
  assert_contains "$out" "blocked on upstream review" "a plain queued hold reason should render"
  count=$(printf '%s' "$out" | grep -o "Working task &lt;urgent&gt;" | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a task that is both in-progress and still filed as Queued must render exactly once, got $count: $out"
  in_progress_block=$(printf '%s' "$out" | sed -n '/<section id="in-progress">/,/<\/section>/p')
  waiting_block=$(printf '%s' "$out" | sed -n '/<section id="waiting">/,/<\/section>/p')
  assert_contains "$in_progress_block" "Working task &lt;urgent&gt;" "the fresher in-progress signal must win the dedup"
  assert_not_contains "$waiting_block" "Working task &lt;urgent&gt;" \
    "a stale Queued row for an already-working task must not double it into Waiting"
  pass "decisions render with a tag, HTML is escaped, full texture appears, and a stale duplicate is deduped in favor of in-progress"
}

test_ready_to_merge_reclassified() {
  local home fakebin out i_needs i_ready
  home=$(make_home ready)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD")
  assert_contains "$out" "READY TO MERGE" "a checks-passed task must be tagged ready to merge"
  i_needs=$(printf '%s' "$out" | grep -bo '<section id="needs-captain"' | head -1 | cut -d: -f1)
  i_ready=$(printf '%s' "$out" | grep -bo 'Ready to merge task' | head -1 | cut -d: -f1)
  [ -n "$i_ready" ] && [ "$i_ready" -gt "$i_needs" ] \
    || fail "the ready-to-merge task must appear inside the needs-captain section: $out"
  pass "a task whose validation finished (state=done) is reclassified as needs-captain, not in-progress"
}

test_pr_link_is_clickable_full_url() {
  local home out
  home=$(make_home landed)
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] fixture-done - Done task https://github.com/kunchenguid/firstmate/pull/42 (repo: alpha) (kind: ship) (done 2026-08-10)
EOF
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD")
  assert_contains "$out" '<a class="link" href="https://github.com/kunchenguid/firstmate/pull/42" target="_blank" rel="noopener noreferrer">https://github.com/kunchenguid/firstmate/pull/42</a>' \
    "a landed PR must render as a real full-URL link that opens in a new tab"
  assert_contains "$out" "2026-08-10" "the completion date should appear in the expandable detail"
  pass "a recorded PR renders as a clickable full https link with target=_blank"
}

test_ready_marker_promotes_landed_item() {
  local home out ready_block completed_block
  home=$(make_home readymarker)
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] fixture-marked - Approvals tab shipped https://github.com/kunchenguid/firstmate/pull/77 (repo: alpha) (kind: ship) (done 2026-08-15)
  ready: the new Approvals tab on the home screen
- [x] fixture-unmarked - Plain merged thing https://github.com/kunchenguid/firstmate/pull/78 (repo: alpha) (kind: ship) (done 2026-08-14)
  just a regular note, nothing special
EOF
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD")
  ready_block=$(printf '%s' "$out" | sed -n '/<section id="ready">/,/<\/section>/p')
  completed_block=$(printf '%s' "$out" | sed -n '/<section id="recently-completed">/,/<\/section>/p')
  assert_contains "$ready_block" "Approvals tab shipped" "a ready:-marked landed item must appear under Ready for you to look at"
  assert_contains "$ready_block" "the new Approvals tab on the home screen" "the text after the ready: marker must render as where to see it"
  assert_not_contains "$ready_block" "pull/77" "a ready:-marked item must never show its pull request in this section"
  assert_not_contains "$completed_block" "Approvals tab shipped" "a ready:-marked item must not double into Recently completed"
  assert_contains "$completed_block" "Plain merged thing" "a landed item with no ready: marker must still appear under Recently completed"
  assert_not_contains "$ready_block" "Plain merged thing" "a landed item with no ready: marker must not appear under Ready for you to look at"
  pass "a landed item's ready: marker promotes it into Ready for you to look at with its pointer text, never its PR, and dedupes out of Recently completed"
}

test_help_and_bad_flag() {
  local out code
  out=$("$BOARD" --help)
  assert_contains "$out" "fm-status-board.sh" "help text should name the command"
  "$BOARD" --bogus >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "an unrecognized flag should exit 2"
  pass "--help prints usage and an unrecognized flag exits 2"
}

test_json_debug_format() {
  local home out
  home=$(make_home debugjson)
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$BOARD" --json)
  printf '%s' "$out" | jq -e '(.bearings | type) == "object" and (.fleet | type) == "object"' >/dev/null \
    || fail "--json must print the two source snapshots this page was built from: $out"
  pass "--json prints the underlying bearings and fleet snapshots for debugging"
}

test_empty_fleet_renders_all_empty_states
test_section_order
test_decision_and_texture_and_dedup
test_ready_to_merge_reclassified
test_pr_link_is_clickable_full_url
test_ready_marker_promotes_landed_item
test_help_and_bad_flag
test_json_debug_format
