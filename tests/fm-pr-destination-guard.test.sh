#!/usr/bin/env bash
# bin/fm-pr-destination-guard.sh pins gh's fork-parent PR-destination default to
# this repo's own origin, in both a project checkout and its no-mistakes gate,
# and must refuse loudly rather than proceed whenever that pin cannot be
# verified. No test here ever creates a real pull request or touches a real
# GitHub repository; every fixture is a disposable local git repo, and
# no-mistakes itself is a fakebin stub reporting a fixture gate path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

GUARD="$ROOT/bin/fm-pr-destination-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-destination-guard)
command -v gh >/dev/null 2>&1 || { pass "skipped: gh is not installed"; exit 0; }

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

test_pins_and_verifies_both_locations
test_refuses_without_origin
test_skips_non_github_origin
test_refuses_when_gate_is_undiscoverable
test_refuses_when_gate_pin_fails
