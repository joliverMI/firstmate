#!/usr/bin/env bash
# bin/fm-pr-destination-guard.sh pins gh's fork-parent PR-destination default to
# this repo's own origin, in both a project checkout and its no-mistakes gate,
# and must refuse loudly rather than proceed whenever that pin cannot be
# verified. No test here ever creates a real pull request or touches a real
# GitHub repository; every fixture is a disposable local git repo, and
# no-mistakes itself is a fakebin stub reporting a fixture gate path.
#
# Two families of case live here. The live-gh cases exercise the real
# `gh repo set-default` write against this project's own repository and are
# skipped, never failed, on a host where gh is missing, unauthenticated, or
# offline - that call is an authenticated API round trip. The stub-gh cases
# cover what the destination check must refuse, which cannot be staged with a
# real gh without naming someone else's repository to it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

GUARD="$ROOT/bin/fm-pr-destination-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-destination-guard)
# `gh repo set-default origin` is an authenticated, online API round trip: it
# exits 4 unauthenticated and 1 when the remote cannot be confirmed. Neither is
# a defect in the guard, so the live cases announce a skip instead of failing.
LIVE_GH_SKIP=
if ! command -v gh >/dev/null 2>&1; then
  LIVE_GH_SKIP="gh is not installed"
elif ! gh auth status >/dev/null 2>&1; then
  LIVE_GH_SKIP="gh is installed but not authenticated or cannot reach GitHub"
fi

# new_case: a fresh <case>/proj checkout and <case>/gate.git bare gate, wired
# with a fakebin `no-mistakes status` that reports the gate path, matching the
# real CLI's "    gate:  <path>" line the guard script parses.
new_case() {
  local name=$1 case_dir proj gate fakebin
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/proj"
  gate="$case_dir/gate.git"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin https://github.com/joliverMI/firstmate.git
  git init -q --bare "$gate"
  git -C "$gate" remote add origin https://github.com/joliverMI/firstmate.git
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [ "\$1" = status ]; then
  echo "    gate:  $gate"
fi
EOF
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$proj"
}

run_guard() {  # <proj-dir> <fakebin-dir>
  PATH="$2:$PATH" "$GUARD" "$1"
}

# new_stub_case: like new_case, but with a fakebin `gh` shadowing the real one,
# so the destination check can be driven to any resolved value without ever
# naming a repository to a live GitHub API. The stub writes the same
# remote.origin.gh-resolved config the real CLI writes, and answers
# `set-default --view` from a .fake-gh-view file in the directory it runs in -
# absent means the read fails, empty means it reads back empty.
#   new_stub_case <name> <proj-origin> <proj-view> <gate-origin> <gate-view>
# A view argument of "-" leaves the .fake-gh-view file out entirely.
new_stub_case() {
  local name=$1 proj_origin=$2 proj_view=$3 gate_origin=$4 gate_view=$5
  local case_dir proj gate fakebin
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/proj"
  gate="$case_dir/gate.git"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin "$proj_origin"
  git init -q --bare "$gate"
  git -C "$gate" remote add origin "$gate_origin"
  [ "$proj_view" = - ] || printf '%s\n' "$proj_view" > "$proj/.fake-gh-view"
  [ "$gate_view" = - ] || printf '%s\n' "$gate_view" > "$gate/.fake-gh-view"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [ "\$1" = status ]; then
  echo "    gate:  $gate"
fi
EOF
  cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = repo ] && [ "$2" = set-default ] || exit 1
if [ "$3" = --view ]; then
  [ -f .fake-gh-view ] || exit 1
  cat .fake-gh-view
  exit 0
fi
git config remote.origin.gh-resolved base
EOF
  chmod +x "$fakebin/no-mistakes" "$fakebin/gh"
  printf '%s\n' "$proj"
}

test_pins_and_verifies_both_locations() {
  local proj out code
  proj=$(new_case happy)
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 0 "$code" "guard exits 0 once both locations are pinned" "$out"
  assert_contains "$out" "joliverMI/firstmate is the sole pull-request destination" \
    "guard reports the pinned destination"
  [ "$(git -C "$proj" config --get remote.origin.gh-resolved)" = base ] \
    || fail "project checkout was not pinned"
  [ "$(git -C "$(dirname "$proj")/gate.git" config --get remote.origin.gh-resolved)" = base ] \
    || fail "no-mistakes gate was not pinned"
  pass "guard pins and verifies the project checkout and its gate"
}

test_refuses_without_origin() {
  local case_dir proj out code
  case_dir="$TMP_ROOT/no-origin"
  proj="$case_dir/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  out=$("$GUARD" "$proj" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses a checkout with no origin remote" "$out"
  assert_contains "$out" "no 'origin' remote" "refusal names the missing origin"
  pass "guard fails loudly instead of proceeding without an origin remote"
}

test_skips_non_github_origin() {
  local case_dir proj out code
  case_dir="$TMP_ROOT/non-github"
  proj="$case_dir/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin https://gitlab.com/owner/repo.git
  out=$("$GUARD" "$proj" 2>&1)
  code=$?
  expect_code 0 "$code" "guard is a deliberate no-op for a non-GitHub origin" "$out"
  assert_contains "$out" "skip:" "guard names the skip explicitly rather than staying silent"
  [ -z "$(git -C "$proj" config --get remote.origin.gh-resolved 2>/dev/null || true)" ] \
    || fail "guard must not touch gh-resolved for a non-GitHub origin"
  pass "guard explicitly skips a non-GitHub origin instead of guessing"
}

test_refuses_when_gate_is_undiscoverable() {
  local case_dir proj fakebin out code
  case_dir="$TMP_ROOT/no-gate"
  proj="$case_dir/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin https://github.com/joliverMI/firstmate.git
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
[ "$1" = status ] && echo "no gate configured here"
EOF
  chmod +x "$fakebin/no-mistakes"
  out=$(run_guard "$proj" "$fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses when the gate cannot be discovered" "$out"
  assert_contains "$out" "no-mistakes gate" "refusal names the undiscoverable gate"
  assert_contains "$out" "no-mistakes init" "refusal tells the caller how to recover"
  pass "guard fails loudly instead of proceeding when the gate is undiscoverable"
}

test_refuses_when_gate_pin_fails() {
  local case_dir proj fakebin bogus_gate out code
  case_dir="$TMP_ROOT/bogus-gate"
  proj="$case_dir/proj"
  bogus_gate="$case_dir/not-a-repo"
  mkdir -p "$proj" "$bogus_gate"
  git -C "$proj" init -q
  git -C "$proj" remote add origin https://github.com/joliverMI/firstmate.git
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [ "\$1" = status ]; then
  echo "    gate:  $bogus_gate"
fi
EOF
  chmod +x "$fakebin/no-mistakes"
  out=$(run_guard "$proj" "$fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses when the reported gate is not a usable git repo" "$out"
  assert_contains "$out" "no-mistakes gate" "refusal names the gate as the failure point"
  [ "$(git -C "$proj" config --get remote.origin.gh-resolved)" = base ] \
    || fail "the project checkout should still be pinned even though the gate failed"
  pass "guard fails loudly when the gate itself cannot be pinned"
}

test_refuses_when_the_checkout_resolves_elsewhere() {
  local proj out code
  proj=$(new_stub_case checkout-elsewhere \
    https://github.com/joliverMI/firstmate.git kunchenguid/firstmate \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses a checkout pinned to another repository" "$out"
  assert_contains "$out" "kunchenguid/firstmate" "refusal names the wrong destination it found"
  assert_contains "$out" "joliverMI/firstmate" "refusal names the project's own repository"
  assert_not_contains "$out" "sole pull-request destination" \
    "a wrong destination must never be reported as pinned"
  pass "guard refuses a pin that exists but names a repository other than the project's own"
}

test_refuses_when_the_gate_resolves_to_the_fork_parent() {
  local proj out code
  proj=$(new_stub_case gate-elsewhere \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate \
    https://github.com/kunchenguid/firstmate.git kunchenguid/firstmate)
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses a gate that resolves to a different repository" "$out"
  assert_contains "$out" "no-mistakes gate" "refusal names the gate as the failure point"
  assert_contains "$out" "kunchenguid/firstmate" "refusal names where the gate would open the PR"
  assert_not_contains "$out" "sole pull-request destination" \
    "a drifted gate must never be reported as pinned"
  pass "guard refuses a correctly pinned checkout whose gate still resolves to the fork parent"
}

test_refuses_an_unreadable_or_empty_destination_read() {
  local proj out code
  proj=$(new_stub_case empty-view \
    https://github.com/joliverMI/firstmate.git "" \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses a destination that reads back empty" "$out"
  assert_not_contains "$out" "sole pull-request destination" \
    "an empty read-back must never be reported as pinned"

  proj=$(new_stub_case unreadable-view \
    https://github.com/joliverMI/firstmate.git - \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses when the destination cannot be read back at all" "$out"
  assert_not_contains "$out" "sole pull-request destination" \
    "a failed read-back must never be reported as pinned"
  pass "guard treats an empty or failed destination read as a refusal, never as a pass"
}

test_accepts_a_destination_matching_the_origin_case_insensitively() {
  local proj out code
  proj=$(new_stub_case case-insensitive \
    https://github.com/joliverMI/firstmate.git JoliverMI/FirstMate \
    https://github.com/joliverMI/firstmate.git JOLIVERMI/FIRSTMATE)
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 0 "$code" "guard accepts a destination differing only in case" "$out"
  assert_contains "$out" "sole pull-request destination" "guard reports the verified destination"
  pass "guard compares owner/repository case-insensitively, as GitHub itself does"
}

if [ -n "$LIVE_GH_SKIP" ]; then
  pass "skipped: live gh pin cases ($LIVE_GH_SKIP)"
else
  test_pins_and_verifies_both_locations
  test_refuses_when_gate_is_undiscoverable
  test_refuses_when_gate_pin_fails
fi
test_refuses_without_origin
test_skips_non_github_origin
test_refuses_when_the_checkout_resolves_elsewhere
test_refuses_when_the_gate_resolves_to_the_fork_parent
test_refuses_an_unreadable_or_empty_destination_read
test_accepts_a_destination_matching_the_origin_case_insensitively
