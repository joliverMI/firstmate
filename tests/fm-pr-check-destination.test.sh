#!/usr/bin/env bash
# bin/fm-pr-check.sh must refuse to record or arm a merge watch for a GitHub PR
# reported against a repository other than the task's own project - a
# defense-in-depth backstop behind bin/fm-pr-destination-guard.sh's preventive
# pin (docs/architecture.md "Pull request destination is pinned, never gh's
# default"). No test here creates a real pull request or touches a real GitHub
# repository: every fixture project is a disposable local git repo, and gh/
# gh-axi are fakebin stubs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-destination)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# make_case <name> <origin-url>: a task home with a real git worktree fixture
# whose origin is <origin-url>, plus fakebin gh/gh-axi/guard stubs so no real
# network call or real GitHub state is ever touched.
make_case() {
  local name=$1 origin=$2 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/wt" "$fakebin" "$fake_root/bin"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" remote add origin "$origin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
esac
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/wt" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$dir"
}

run_check_entry() {  # <dir> <id> <url>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

test_refuses_a_pr_against_the_wrong_repository() {
  local dir out code
  dir=$(make_case mismatch https://github.com/joliverMI/firstmate.git)
  out=$(run_check_entry "$dir" task-a https://github.com/kunchenguid/firstmate/pull/1 2>&1)
  code=$?
  expect_code 1 "$code" "fm-pr-check.sh refuses a PR against the wrong repository" "$out"
  assert_contains "$out" "kunchenguid/firstmate" "refusal names the PR's actual (wrong) destination"
  assert_contains "$out" "joliverMI/firstmate" "refusal names the task's own project"
  assert_no_grep "pr=" "$dir/home/state/task-a.meta" \
    "a refused PR must not be recorded in task metadata"
  assert_absent "$dir/home/state/task-a.check.sh" \
    "a refused PR must not arm a merge-watch poll"
  pass "fm-pr-check.sh fails loudly instead of recording or arming a wrong-repository PR"
}

test_accepts_a_pr_against_its_own_repository() {
  local dir out code
  dir=$(make_case match https://github.com/joliverMI/firstmate.git)
  out=$(run_check_entry "$dir" task-a https://github.com/joliverMI/firstmate/pull/1 2>&1)
  code=$?
  expect_code 0 "$code" "fm-pr-check.sh accepts a PR against its own repository" "$out"
  assert_grep "pr=https://github.com/joliverMI/firstmate/pull/1" "$dir/home/state/task-a.meta" \
    "a same-repository PR must still be recorded normally"
  pass "fm-pr-check.sh proceeds normally when the PR targets the task's own repository"
}

test_skips_the_check_when_origin_cannot_be_determined() {
  local dir out code
  dir="$TMP_ROOT/no-worktree"
  mkdir -p "$dir/home/state" "$dir/fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/missing-worktree" \
    "kind=ship" \
    "mode=no-mistakes"
  out=$(run_check_entry "$dir" task-a https://github.com/kunchenguid/firstmate/pull/1 2>&1)
  code=$?
  expect_code 0 "$code" "the ownership check never blocks when the task's own origin is unknown" "$out"
  assert_grep "pr=https://github.com/kunchenguid/firstmate/pull/1" "$dir/home/state/task-a.meta" \
    "a PR must still be recorded when there is no known origin to compare against"
  pass "fm-pr-check.sh only refuses on a confirmed mismatch, never on an unknown origin"
}

# Every remote URL form below addresses exactly the same repository as the
# reported PR, so none of them may be read as a foreign destination: a trailing
# slash after .git, the scp-style and ssh:// forms, GitHub's case-insensitive
# owner/repository names, embedded userinfo (including the standard
# token-clone form), an explicit port, GitHub's documented ssh.github.com:443
# endpoint, and the git:// scheme. Refusing any of these would read a correctly
# configured project as somebody else's repository.
test_accepts_equivalent_forms_of_its_own_origin() {
  local form dir out code n=0
  for form in \
    'https://github.com/joliverMI/firstmate.git/' \
    'git@github.com:joliverMI/firstmate.git' \
    'ssh://git@github.com/joliverMI/firstmate.git' \
    'https://github.com/JoliverMI/FirstMate.git' \
    'https://user@github.com/joliverMI/firstmate.git' \
    'https://x-access-token:s3cr3t@github.com/joliverMI/firstmate.git' \
    'https://github.com:443/joliverMI/firstmate.git' \
    'ssh://git@ssh.github.com:443/joliverMI/firstmate.git' \
    'git://github.com/joliverMI/firstmate.git'; do
    n=$((n + 1))
    dir=$(make_case "own-origin-form-$n" "$form")
    out=$(run_check_entry "$dir" task-a https://github.com/joliverMI/firstmate/pull/1 2>&1)
    code=$?
    expect_code 0 "$code" "origin '$form' addresses the task's own project" "$out"
    assert_grep "pr=https://github.com/joliverMI/firstmate/pull/1" "$dir/home/state/task-a.meta" \
      "a PR on the task's own project must be recorded when origin is '$form'"
  done
  pass "the ownership check reads every equivalent form of the project's own origin as its own"
}

# The backstop only ever blocks on a confirmed mismatch, so an origin form it
# cannot read is not refused - it is silently skipped, and a wrong-repository
# PR sails through. Every form below is a legitimate spelling of this project's
# own repository, so each must be understood well enough to catch the mismatch.
test_refuses_a_wrong_repository_pr_for_every_origin_form() {
  local form dir out code n=0
  for form in \
    'https://user@github.com/joliverMI/firstmate.git' \
    'https://github.com:443/joliverMI/firstmate.git' \
    'ssh://git@ssh.github.com:443/joliverMI/firstmate.git' \
    'git://github.com/joliverMI/firstmate.git'; do
    n=$((n + 1))
    dir=$(make_case "mismatch-origin-form-$n" "$form")
    out=$(run_check_entry "$dir" task-a https://github.com/kunchenguid/firstmate/pull/1 2>&1)
    code=$?
    expect_code 1 "$code" "a wrong-repository PR must be refused when origin is '$form'" "$out"
    assert_no_grep "pr=" "$dir/home/state/task-a.meta" \
      "a refused PR must not be recorded when origin is '$form'"
  done
  pass "the ownership check catches a wrong-repository PR for every legitimate origin form"
}

test_refuses_a_pr_against_the_wrong_repository
test_accepts_a_pr_against_its_own_repository
test_accepts_equivalent_forms_of_its_own_origin
test_refuses_a_wrong_repository_pr_for_every_origin_form
test_skips_the_check_when_origin_cannot_be_determined
