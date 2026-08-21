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

run_guard() {  # <proj-dir> <fakebin-dir> [<guard-arg>...]
  local proj=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" "$GUARD" "$proj" "$@"
}

# new_stub_case: like new_case, but with a fakebin `gh` shadowing the real one,
# so the destination check can be driven to any resolved value without ever
# naming a repository to a live GitHub API. The stub writes the same
# remote.origin.gh-resolved config the real CLI writes, and answers
# `set-default --view` from a .fake-gh-view file in the directory it runs in -
# absent means the read fails, empty means it reads back empty. Any invocation
# that is not `--view` is the destination WRITE, and the stub records it by
# touching .fake-gh-wrote, so a case can assert whether the network write
# happened at all rather than only what the destination ended up being.
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
  [ -f .fake-gh-view ] || { echo "no default repository has been set" >&2; exit 1; }
  cat .fake-gh-view
  exit 0
fi
: > .fake-gh-wrote
if [ -f .fake-gh-pin-fails ]; then
  echo "could not lock config file .git/config: File exists" >&2
  exit 1
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

# The write is an authenticated online round trip that also takes the shared
# common git config lock, and this guard runs in the Setup step of every
# no-mistakes task, from concurrent crewmate worktrees of one checkout. An API
# blip or a lock collision must not block a task whose destination was already
# correct: the verified destination is the invariant, not the write.
test_accepts_an_already_correct_destination_without_writing() {
  local proj gate out code
  proj=$(new_stub_case already-pinned \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
  gate="$(dirname "$proj")/gate.git"
  git -C "$proj" config remote.origin.gh-resolved base
  git -C "$gate" config remote.origin.gh-resolved base
  : > "$proj/.fake-gh-pin-fails"
  : > "$gate/.fake-gh-pin-fails"
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 0 "$code" "an already-correct destination must survive a failed pin write" "$out"
  assert_contains "$out" "sole pull-request destination" "guard reports the verified destination"
  assert_absent "$proj/.fake-gh-wrote" \
    "an already-correct checkout must not take the shared config lock to rewrite its pin"
  assert_absent "$gate/.fake-gh-wrote" \
    "an already-correct gate must not take the shared config lock to rewrite its pin"
  pass "guard verifies an already-correct destination without writing it again"
}

test_writes_the_pin_when_the_destination_is_not_yet_set() {
  local proj gate out code
  proj=$(new_stub_case unpinned-writes \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
  gate="$(dirname "$proj")/gate.git"
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 0 "$code" "an unpinned destination must be pinned and verified" "$out"
  assert_present "$proj/.fake-gh-wrote" "an unpinned checkout must actually be pinned"
  assert_present "$gate/.fake-gh-wrote" "an unpinned gate must actually be pinned"
  pass "guard still writes the pin when the destination is not already set"
}

# Each origin below is a legitimate, correctly configured spelling of this
# project's own GitHub repository. Refusing one would permanently block every
# no-mistakes task on that project, since bin/fm-brief.sh tells the crewmate to
# treat this guard's non-zero exit as a blocker with no recovery step.
test_accepts_every_legitimate_github_origin_form() {
  local form proj out code n=0
  for form in \
    'https://user@github.com/joliverMI/firstmate.git' \
    'https://x-access-token:s3cr3t@github.com/joliverMI/firstmate.git' \
    'https://github.com:443/joliverMI/firstmate.git' \
    'ssh://git@ssh.github.com:443/joliverMI/firstmate.git' \
    'git://github.com/joliverMI/firstmate.git' \
    'git@github.com:joliverMI/firstmate.git'; do
    n=$((n + 1))
    proj=$(new_stub_case "origin-form-$n" \
      "$form" joliverMI/firstmate \
      https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
    out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
    code=$?
    expect_code 0 "$code" "origin form $n names this project's own repository" "$out"
  done
  pass "guard accepts every legitimate spelling of the project's own GitHub origin"
}

# --print-destination is the machine-readable contract a direct-PR task
# substitutes straight into `gh-axi pr create --repo`, where an empty value is
# dropped and falls back to gh's fork-parent default. So stdout must carry the
# destination and nothing else on success, and nothing at all on failure - a
# blank line or a stray diagnostic on stdout would be substituted as a
# destination. It must also work with no gh at all, since it is a local config
# read: the fixture puts a gh on PATH that fails loudly if it is ever called.
new_print_case() {  # <name> <origin-or-"-">
  local name=$1 origin=$2 case_dir proj fakebin
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  [ "$origin" = - ] || git -C "$proj" remote add origin "$origin"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
: > "$case_dir/gh-was-called"
echo "gh must never be called to name a destination" >&2
exit 1
EOF
  chmod +x "$fakebin/gh"
  printf '%s\n' "$proj"
}

test_print_destination_names_the_origin_repository() {
  local form proj out code n=0
  for form in \
    'https://github.com/joliverMI/firstmate.git' \
    'git@github.com:joliverMI/firstmate.git' \
    'git@github.com:/joliverMI/firstmate.git' \
    'https://x-access-token:s3cr3t@github.com/joliverMI/firstmate.git' \
    'ssh://git@ssh.github.com:443/joliverMI/firstmate.git' \
    'git://github.com/joliverMI/firstmate.git'; do
    n=$((n + 1))
    proj=$(new_print_case "print-ok-$n" "$form")
    out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" --print-destination 2>/dev/null)
    code=$?
    expect_code 0 "$code" "origin form $n must name a destination" "$out"
    [ "$out" = joliverMI/firstmate ] \
      || fail "origin form $n printed '$out', not exactly joliverMI/firstmate"
    assert_absent "$(dirname "$proj")/gh-was-called" \
      "naming a destination must not call gh for origin form $n"
  done
  pass "guard --print-destination names the project's own repository from origin alone"
}

test_print_destination_prints_nothing_when_it_cannot_name_one() {
  local name proj stdout stderr code
  for name in no-origin unparseable; do
    case $name in
      no-origin) proj=$(new_print_case print-no-origin -) ;;
      unparseable) proj=$(new_print_case print-unparseable 'https://x-access-token:s3cr3tt0ken@github.com/') ;;
    esac
    stderr="$(dirname "$proj")/stderr"
    stdout=$(run_guard "$proj" "$(dirname "$proj")/fakebin" --print-destination 2>"$stderr")
    code=$?
    [ "$code" = 1 ] || fail "$name must exit 1 - the hazard is real here and the destination is undetermined (got $code)"
    [ -z "$stdout" ] \
      || fail "$name printed '$stdout' on stdout; a caller would substitute that as a destination"
    [ -s "$stderr" ] || fail "$name must explain on stderr why no destination could be named"
    assert_not_contains "$(cat "$stderr")" "s3cr3tt0ken" \
      "$name must not publish an origin credential"
  done
  pass "guard --print-destination refuses with an empty stdout instead of naming a guess"
}

# "Not GitHub" and "GitHub but undetermined" are different answers with
# different consequences: the fork-parent default is a gh behaviour on GitHub
# forks, so a GitLab or self-hosted project was never exposed to it and must
# not be blocked as though it were. Its caller distinguishes the two by exit
# code, so the codes are the contract.
test_a_non_github_origin_is_not_applicable_rather_than_blocked() {
  local entry form host proj out code n=0
  for entry in \
    'https://gitlab.com/owner/repo.git|gitlab.com' \
    'https://gitlab.com/me/github.com-mirror.git|gitlab.com' \
    'git@git.example.invalid:owner/repo.git|git.example.invalid'; do
    form=${entry%|*}
    host=${entry#*|}
    n=$((n + 1))
    proj=$(new_print_case "not-applicable-$n" "$form")
    out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" --print-destination 2>/dev/null)
    code=$?
    [ "$code" = 3 ] \
      || fail "origin $n is not on a GitHub host, so --print-destination must exit 3, not $code"
    [ -z "$out" ] || fail "origin $n printed '$out'; there is no GitHub destination to name"
    out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
    code=$?
    expect_code 0 "$code" "origin $n must be skipped, not refused, when pinning" "$out"
    assert_contains "$out" "skip:" "origin $n must say it is out of scope rather than fail"
    assert_contains "$out" "$host" \
      "the skip must name the host it did not recognize, so the gap is audible on first use"
  done
  pass "guard treats a non-GitHub origin as out of scope, never as a blocked project"
}

# git@github.com-work:owner/repo.git is the ~/.ssh/config Host-alias pattern for
# holding several GitHub accounts on one machine. Naming its repository is a
# text parse, so --print-destination answers it; verifying the pin is not, and
# real gh refuses an alias host outright ("none of the git remotes configured
# for this repository point to a known GitHub host", gh 2.97.0), so the two
# halves legitimately disagree and each is asserted against what its own tool
# can actually do.
test_print_destination_names_an_ssh_host_alias_origin() {
  local proj out code
  proj=$(new_print_case alias-print 'git@github.com-work:joliverMI/firstmate.git')
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" --print-destination 2>/dev/null)
  code=$?
  expect_code 0 "$code" "an ssh-alias origin names this project's own repository" "$out"
  [ "$out" = joliverMI/firstmate ] \
    || fail "an ssh-alias origin printed '$out', not joliverMI/firstmate"
  assert_absent "$(dirname "$proj")/gh-was-called" \
    "naming an ssh-alias destination is a parse, so it must not need gh at all"
  pass "guard --print-destination names an ssh-alias GitHub origin from the URL alone"
}

# The stub here models what real gh does for an alias host - it cannot resolve
# one, so both the write and the read-back fail - and the assertion is that the
# guard refuses rather than reporting an unverified destination as pinned.
test_verify_refuses_an_ssh_host_alias_gh_cannot_resolve() {
  local proj gate out code
  proj=$(new_stub_case alias-verify \
    'git@github.com-work:joliverMI/firstmate.git' - \
    'git@github.com-work:joliverMI/firstmate.git' -)
  gate="$(dirname "$proj")/gate.git"
  : > "$proj/.fake-gh-pin-fails"
  : > "$gate/.fake-gh-pin-fails"
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "a destination gh cannot resolve must be refused, not assumed" "$out"
  assert_not_contains "$out" "sole pull-request destination" \
    "an unverifiable destination must never be reported as pinned"
  pass "guard refuses to call an ssh-alias destination verified when gh cannot resolve it"
}

# A host that merely starts with "github.com-" is not an alias, it is a
# different domain: naming owner/repo for github.com-mirror.example.net would
# aim a pull request at an unrelated repository on github.com itself.
test_a_github_lookalike_host_is_not_a_github_destination() {
  local form proj out code n=0
  for form in \
    'https://github.com-mirror.example.net/owner/repo.git' \
    'git@github.com-eu.gitlab-mirror.io:owner/repo.git' \
    'https://github.com.example.invalid/owner/repo.git'; do
    n=$((n + 1))
    proj=$(new_print_case "lookalike-$n" "$form")
    out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" --print-destination 2>/dev/null)
    code=$?
    [ "$code" = 3 ] \
      || fail "lookalike host $n must not be named as a GitHub destination (exit $code, printed '$out')"
    [ -z "$out" ] || fail "lookalike host $n printed '$out'; that would target github.com"
    out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
    code=$?
    expect_code 0 "$code" "lookalike host $n is out of scope, not a failure" "$out"
    assert_contains "$out" "skip:" "lookalike host $n must be skipped rather than pinned"
  done
  pass "guard does not read a github.com-lookalike domain as a GitHub destination"
}


# A remote can legitimately carry a credential, and this guard's stderr is
# copied verbatim into a crewmate's `blocked:` status line and into
# provisioning logs, so a refusal must never publish one.
test_refusal_never_echoes_an_origin_credential() {
  local case_dir proj out code
  case_dir="$TMP_ROOT/credentialed-origin"
  proj="$case_dir/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" remote add origin 'https://x-access-token:s3cr3tt0ken@github.com/'
  out=$("$GUARD" "$proj" 2>&1)
  code=$?
  expect_code 1 "$code" "guard refuses a github.com origin that names no repository" "$out"
  assert_not_contains "$out" "s3cr3tt0ken" "a refusal must never publish an origin credential"
  assert_contains "$out" "$proj" "the refusal must still name the directory that failed"
  pass "guard names the failing directory without echoing its origin credential"
}

test_refusal_carries_ghs_own_reason() {
  local proj out code
  proj=$(new_stub_case pin-fails-unpinned \
    https://github.com/joliverMI/firstmate.git - \
    https://github.com/joliverMI/firstmate.git joliverMI/firstmate)
  : > "$proj/.fake-gh-pin-fails"
  out=$(run_guard "$proj" "$(dirname "$proj")/fakebin" 2>&1)
  code=$?
  expect_code 1 "$code" "guard still refuses when an unpinned destination cannot be pinned" "$out"
  assert_contains "$out" "could not lock config file" \
    "the refusal must carry gh's own reason, not just what failed"
  assert_contains "$out" "the project checkout" "the refusal must still name what failed"
  pass "guard reports gh's own diagnostic so a blocked crewmate records the real cause"
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
test_accepts_an_already_correct_destination_without_writing
test_writes_the_pin_when_the_destination_is_not_yet_set
test_refusal_carries_ghs_own_reason
test_accepts_every_legitimate_github_origin_form
test_refusal_never_echoes_an_origin_credential
test_print_destination_names_the_origin_repository
test_print_destination_prints_nothing_when_it_cannot_name_one
test_a_non_github_origin_is_not_applicable_rather_than_blocked
test_print_destination_names_an_ssh_host_alias_origin
test_verify_refuses_an_ssh_host_alias_gh_cannot_resolve
test_a_github_lookalike_host_is_not_a_github_destination
