#!/usr/bin/env bash
# Regression tests for the "PR must be raised via no-mistakes" gate in
# .github/workflows/no-mistakes-required.yml.
#
# Origin: PR #42 was rejected by this gate ("structured pipeline step
# attestation is missing or unparseable") even though its body carried a
# valid, completed no-mistakes-pipeline-attestation comment. The gate's own
# PR body includes an "Evidence" section that quotes this very check script's
# source (as proof of its tested behavior), and that quoted source contains
# the same literal marker text the gate searches for. The gate matched the
# FIRST occurrence of the marker - inside the quoted evidence - and then
# extracted garbage between it and the next " -->" (also inside the quoted
# source), instead of the real attestation comment the pipeline appends at
# the end of the body. Fix: match the LAST occurrence of the marker, since
# the real attestation comment is always the final thing the pipeline writes.
#
# These tests extract and run the actual `run:` shell block from the
# workflow file (not a reimplementation), so a regression in the real gate
# script is what makes them fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

# extract_run_script <workflow.yml>: print the literal-block body of the
# step's `run: |` key, dedented. This is the only `run:` block in the file.
extract_run_script() {
  awk '
    /^[[:space:]]*run: \|/ { capture=1; indent=-1; next }
    capture {
      if (indent == -1) {
        if ($0 ~ /^[[:space:]]*$/) { print ""; next }
        match($0, /^[ ]*/)
        indent = RLENGTH
      }
      line = $0
      if (length(line) >= indent) {
        print substr(line, indent + 1)
      } else {
        print ""
      }
    }
  ' "$1"
}

GATE_SCRIPT="$(fm_test_tmproot no-mistakes-required-wf)/gate.sh"
extract_run_script "$WORKFLOW" > "$GATE_SCRIPT"
[ -s "$GATE_SCRIPT" ] || fail "could not extract a run: block from $WORKFLOW"

run_gate() {  # <pr_body>
  PR_BODY="$1" PR_AUTHOR=joliverMI PR_NUMBER=42 bash "$GATE_SCRIPT" 2>&1
}

attestation() {  # <review_status> <test_status> <document_status>
  printf 'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"deadbeef","steps":[{"step":"review","status":"%s"},{"step":"test","status":"%s"},{"step":"document","status":"%s"}]} -->\n' \
    "$1" "$2" "$3"
}

test_rejects_pr_body_without_signature() {
  local out rc
  rc=0
  out=$(run_gate "just a plain PR with no pipeline marker") || rc=$?
  [ "$rc" -ne 0 ] || fail "PR body without the no-mistakes marker unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "This PR was not raised through no-mistakes" \
    "missing-signature rejection did not name the reason"
  pass "PR body without a no-mistakes signature is rejected"
}

test_rejects_signature_without_attestation_comment() {
  local out rc
  rc=0
  out=$(run_gate "Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)") || rc=$?
  [ "$rc" -ne 0 ] || fail "signature without an attestation comment unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "structured pipeline step attestation is missing or unparseable" \
    "missing-attestation rejection did not name the reason"
  pass "signature without a structured attestation comment is rejected"
}

test_rejects_incomplete_required_step() {
  local body out rc
  body=$(attestation completed skipped completed)
  rc=0
  out=$(run_gate "$body") || rc=$?
  [ "$rc" -ne 0 ] || fail "an incomplete required step unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "test=skipped" \
    "incomplete-step rejection did not name the skipped step"
  pass "an incomplete required pipeline step is rejected"
}

test_accepts_a_clean_completed_attestation() {
  local body out rc
  body=$(attestation completed completed completed)
  rc=0
  out=$(run_gate "$body") || rc=$?
  [ "$rc" -eq 0 ] || fail "a fully completed attestation was rejected"$'\n'"$out"
  assert_contains "$out" "Pipeline step attestation is valid" \
    "a valid attestation did not report success"
  pass "a PR body with a clean completed attestation is accepted"
}

# Regression for PR #42: an "Evidence" section earlier in the body quotes this
# gate script's own source (including the literal marker prefix/suffix), and
# the real attestation comment - with all required steps completed - follows
# it at the end of the body, exactly as the no-mistakes pipeline writes it.
test_accepts_real_attestation_after_body_quotes_the_gate_script() {
  local body out rc
  body=$(cat <<'BODY'
## Testing

<details>
<summary>Evidence: CI attestation gate script</summary>

```text
prefix='<!-- no-mistakes-pipeline-attestation:v1 '
suffix=' -->'
echo '    <!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"...","steps":[...]} -->'
```
</details>

## Pipeline

BODY
)
  body="${body}$(attestation completed completed completed)"
  rc=0
  out=$(run_gate "$body") || rc=$?
  [ "$rc" -eq 0 ] || fail "gate was fooled by an earlier quoted copy of its own marker text"$'\n'"$out"
  assert_contains "$out" "Pipeline step attestation is valid" \
    "gate did not validate the real (last) attestation comment"
  pass "a body that quotes the gate's own marker text before the real attestation still passes"
}

# Same shape as above, but the real (last) attestation is incomplete, proving
# the gate is reading the real trailing comment and not merely defaulting to
# success once a quoted copy is skipped.
test_rejects_when_real_trailing_attestation_is_incomplete_despite_quoted_copy() {
  local body out rc
  body=$(cat <<'BODY'
## Testing

<details>
<summary>Evidence: CI attestation gate script</summary>

```text
prefix='<!-- no-mistakes-pipeline-attestation:v1 '
suffix=' -->'
echo '    <!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"...","steps":[...]} -->'
```
</details>

## Pipeline

BODY
)
  body="${body}$(attestation completed skipped completed)"
  rc=0
  out=$(run_gate "$body") || rc=$?
  [ "$rc" -ne 0 ] || fail "gate accepted a body whose real trailing attestation had an incomplete step"$'\n'"$out"
  assert_contains "$out" "test=skipped" \
    "gate did not name the incomplete step from the real trailing attestation"
  pass "an incomplete real trailing attestation is still rejected despite an earlier quoted copy"
}

test_rejects_pr_body_without_signature
test_rejects_signature_without_attestation_comment
test_rejects_incomplete_required_step
test_accepts_a_clean_completed_attestation
test_accepts_real_attestation_after_body_quotes_the_gate_script
test_rejects_when_real_trailing_attestation_is_incomplete_despite_quoted_copy
