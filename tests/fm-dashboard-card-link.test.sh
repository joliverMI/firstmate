#!/usr/bin/env bash
# tests/fm-dashboard-card-link.test.sh - end-to-end coverage for the mechanical
# link between a task and its Admiral's Fleet Dashboard card (docs/dashboard.md
# "The mechanical card link"): bin/fm-spawn.sh's --card populates the card's
# ref/agent identity and advances a not_started card to working;
# bin/fm-teardown.sh consumes that identity from state/<id>.meta and advances
# the card to review once cleanup actually succeeds; bin/fm-backlog-handoff.sh's
# --card gives a handed-off backlog item the same link, with the item/card
# pairing held in the handing-off home's own state/handoff-cards/<secondmate-id>
# record - never in the backlog item, which the handoff does not own - since a
# handed-off item has no local task metadata to hold it. All three scripts and a
# real dashboard server are driven only through their public CLIs.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v jq >/dev/null 2>&1 || { pass "skipped - jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"
DASH="$ROOT/bin/fm-dashboard.sh"
DASHLIB="$ROOT/bin/fm-dashboard-link-lib.sh"
# shellcheck source=bin/fm-dashboard-link-lib.sh
. "$DASHLIB"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-card-link)

# --- shared dashboard server -------------------------------------------------
# One real server for the whole file, exactly like tests/fm-dashboard.test.sh.
# FM_DASHBOARD_HOST/PORT are exported so every subprocess this file spawns -
# this test's own $DASH calls, fm-spawn.sh's internal link, and
# fm-teardown.sh's internal advance - resolves the same server regardless of
# what FM_HOME each of those scripts otherwise runs with.
DASHBOARD_HOME="$TMP_ROOT/dashboard-home"
mkdir -p "$DASHBOARD_HOME/state" "$DASHBOARD_HOME/data"
SERVER_PID=""

fm_card_link_test_cleanup() {
  local worker_pid i
  if [ -n "${CARD_READ_FAIL_PID:-}" ] && kill -0 "$CARD_READ_FAIL_PID" 2>/dev/null; then
    kill "$CARD_READ_FAIL_PID" 2>/dev/null
    wait "$CARD_READ_FAIL_PID" 2>/dev/null
  fi
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  # The remote-route coverage below stages jobs through a detached remote job
  # worker; wait for it to actually exit so it cannot still be writing into
  # $TMP_ROOT while fm_test_cleanup removes it.
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid" 2>/dev/null || true)
    if [ -n "$worker_pid" ]; then
      kill "$worker_pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 500 ] && kill -0 "$worker_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
    fi
  fi
  fm_test_cleanup
}
trap fm_card_link_test_cleanup EXIT
trap 'fm_card_link_test_cleanup; exit 130' INT
trap 'fm_card_link_test_cleanup; exit 143' TERM

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
  || fail "could not allocate a free port"
export FM_DASHBOARD_HOST=127.0.0.1
export FM_DASHBOARD_PORT="$PORT"
FM_HOME="$DASHBOARD_HOME" "$DASH" start >"$DASHBOARD_HOME/start.out" 2>&1 || {
  cat "$DASHBOARD_HOME/start.out" >&2
  fail "dashboard server did not start"
}
SERVER_PID=$(cat "$DASHBOARD_HOME/state/dashboard.pid" 2>/dev/null)
[ -n "$SERVER_PID" ] || fail "no pid recorded after dashboard start"

# "$DASH" start only confirms the server process is still alive one second
# after launch (bin/fm-dashboard.sh's cmd_server_start), not that it has
# actually bound its socket and is answering requests yet - on a fast, idle
# machine that race is never visible, but a busier CI runner can still be
# mid-startup a second in. Poll the real readiness signal (the same
# /api/health check "$DASH" server-status itself uses) before trusting the
# server for anything, so this file never depends on how fast a listener
# happens to come up on whatever machine runs it.
i=0
until "$DASH" server-status 2>/dev/null | grep -qF 'api:     reachable'; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "dashboard server never became reachable within 10s of starting"
  kill -0 "$SERVER_PID" 2>/dev/null || fail "dashboard server process died while waiting for it to become reachable"
  sleep 0.1
done

wait_for_port_file() {  # <portfile> <pid> <label>
  local portfile=$1 pid=$2 label=$3 i=0
  until [ -s "$portfile" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || { kill "$pid" 2>/dev/null; fail "$label never bound a port"; }
    kill -0 "$pid" 2>/dev/null || fail "$label died before binding a port"
    sleep 0.05
  done
}

# A real HTTP peer that forwards every write to the real board but fails every
# card READ. That is the mid-sequence outage shape - a board restarting, a
# transient 5xx, or a GET that alone hits the call timeout - and it is the only
# way to drive the paths where the link's own ownership and status decisions
# have no answer to work from. Sets CARD_READ_FAIL_PORT for the caller.
CARD_READ_FAIL_PID=
CARD_READ_FAIL_PORT=
start_card_read_failing_proxy() {  # <label>
  local portfile="$TMP_ROOT/card-read-fail-$1.port"
  rm -f "$portfile"
  python3 - "$portfile" "$FM_DASHBOARD_HOST" "$FM_DASHBOARD_PORT" >/dev/null 2>&1 <<'PY' &
import http.server, os, socketserver, sys, urllib.error, urllib.request

portfile, up_host, up_port = sys.argv[1], sys.argv[2], sys.argv[3]
UPSTREAM = "http://%s:%s" % (up_host, up_port)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def _reply(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _relay(self):
        if self.command == "GET" and self.path.startswith("/api/tasks/"):
            self._reply(500, b'{"error":"card read deliberately failed by the test proxy"}')
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        request = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command)
        content_type = self.headers.get("Content-Type")
        if content_type:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request) as response:
                self._reply(response.status, response.read())
        except urllib.error.HTTPError as exc:
            self._reply(exc.code, exc.read())
        except Exception:
            self._reply(502, b'{"error":"proxy could not reach the board"}')

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _relay


socketserver.TCPServer.allow_reuse_address = True
server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(portfile + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(portfile + ".tmp", portfile)
server.serve_forever()
PY
  CARD_READ_FAIL_PID=$!
  wait_for_port_file "$portfile" "$CARD_READ_FAIL_PID" "the card-read-failing proxy"
  CARD_READ_FAIL_PORT=$(cat "$portfile")
}

stop_card_read_failing_proxy() {
  [ -n "$CARD_READ_FAIL_PID" ] || return 0
  kill "$CARD_READ_FAIL_PID" 2>/dev/null
  wait "$CARD_READ_FAIL_PID" 2>/dev/null
  CARD_READ_FAIL_PID=
}

# The inverse of the read-failing proxy above: forwards a card READ but fails
# every ref/agent/status WRITE. dashboard_link_card's own transport-failure
# audit-log rule only fires once the read has already succeeded (probe==0),
# so exercising it needs writes that fail after a genuine read, not a board
# that is unreachable outright. Sets CARD_WRITE_FAIL_PORT for the caller.
CARD_WRITE_FAIL_PID=
CARD_WRITE_FAIL_PORT=
start_card_write_failing_proxy() {  # <label>
  local portfile="$TMP_ROOT/card-write-fail-$1.port"
  rm -f "$portfile"
  python3 - "$portfile" "$FM_DASHBOARD_HOST" "$FM_DASHBOARD_PORT" >/dev/null 2>&1 <<'PY' &
import http.server, os, re, socketserver, sys, urllib.error, urllib.request

portfile, up_host, up_port = sys.argv[1], sys.argv[2], sys.argv[3]
UPSTREAM = "http://%s:%s" % (up_host, up_port)
WRITE_PATH = re.compile(r"^/api/tasks/[^/]+(/status)?$")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def _reply(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _relay(self):
        if self.command in ("PATCH", "POST") and WRITE_PATH.match(self.path):
            self._reply(500, b'{"error":"card write deliberately failed by the test proxy"}')
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        request = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command)
        content_type = self.headers.get("Content-Type")
        if content_type:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request) as response:
                self._reply(response.status, response.read())
        except urllib.error.HTTPError as exc:
            self._reply(exc.code, exc.read())
        except Exception:
            self._reply(502, b'{"error":"proxy could not reach the board"}')

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _relay


socketserver.TCPServer.allow_reuse_address = True
server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
with open(portfile + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(portfile + ".tmp", portfile)
server.serve_forever()
PY
  CARD_WRITE_FAIL_PID=$!
  wait_for_port_file "$portfile" "$CARD_WRITE_FAIL_PID" "the card-write-failing proxy"
  CARD_WRITE_FAIL_PORT=$(cat "$portfile")
}

stop_card_write_failing_proxy() {
  [ -n "$CARD_WRITE_FAIL_PID" ] || return 0
  kill "$CARD_WRITE_FAIL_PID" 2>/dev/null
  wait "$CARD_WRITE_FAIL_PID" 2>/dev/null
  CARD_WRITE_FAIL_PID=
}

card_status() {  # <card-id>
  "$DASH" show "$1" --json 2>/dev/null | jq -r '.status // empty'
}
card_field() {  # <card-id> <field>
  "$DASH" show "$1" --json 2>/dev/null | jq -r --arg f "$2" '.[$f] // empty'
}
add_card() {  # <title> [--status <status>]
  "$DASH" add --title "$1" --captain firstmate --prompt "coverage prompt" "${@:2}" | awk '{print $1}'
}

# --- direct unit coverage for fm-dashboard-link-lib.sh --------------------
# The suites above drive the shared helper only indirectly, through its three
# real call sites against a real dashboard server. These call the two
# functions it exports directly, against a fake "$dash" that logs every
# invocation and answers each subcommand from env-var-controlled canned
# results, to pin the helper's own branching contract in isolation: which
# calls it makes, in what order, and what it prints, independent of any of
# the three callers' own surrounding policy (audit-log caps, card-record
# recovery, KIND/--force gating) that layers on top of it.

FAKE_DASH="$TMP_ROOT/fake-dash.sh"
FAKE_DASH_LOG="$TMP_ROOT/fake-dash.log"
cat > "$FAKE_DASH" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_DASH_LOG"
case "$1" in
  ref)
    [ "${FAKE_DASH_REF_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_DASH_REF_ERR:-ref failed}" >&2; exit "${FAKE_DASH_REF_RC}"; }
    ;;
  agent)
    [ "${FAKE_DASH_AGENT_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_DASH_AGENT_ERR:-agent failed}" >&2; exit "${FAKE_DASH_AGENT_RC}"; }
    ;;
  show)
    [ "${FAKE_DASH_SHOW_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_DASH_SHOW_ERR:-show failed}" >&2; exit "${FAKE_DASH_SHOW_RC}"; }
    printf '%s\n' "$FAKE_DASH_SHOW_JSON"
    ;;
  status)
    [ "${FAKE_DASH_STATUS_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_DASH_STATUS_ERR:-status failed}" >&2; exit "${FAKE_DASH_STATUS_RC}"; }
    ;;
  audit-log) ;;
  *) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKE_DASH"
export FAKE_DASH_LOG
# Exported once by name so a later plain VAR=value assignment in a test stays
# visible to the fake dash's own process - it runs as a separate script, not a
# function in this shell, so an unexported control variable would silently
# read back empty there no matter what this shell just set it to.
export FAKE_DASH_REF_RC FAKE_DASH_REF_ERR FAKE_DASH_AGENT_RC FAKE_DASH_AGENT_ERR \
  FAKE_DASH_SHOW_RC FAKE_DASH_SHOW_ERR FAKE_DASH_SHOW_JSON \
  FAKE_DASH_STATUS_RC FAKE_DASH_STATUS_ERR

reset_fake_dash() {
  : > "$FAKE_DASH_LOG"
  FAKE_DASH_REF_RC='' FAKE_DASH_REF_ERR='' FAKE_DASH_AGENT_RC='' FAKE_DASH_AGENT_ERR='' \
  FAKE_DASH_SHOW_RC='' FAKE_DASH_SHOW_ERR='' FAKE_DASH_SHOW_JSON='{}' \
  FAKE_DASH_STATUS_RC='' FAKE_DASH_STATUS_ERR=''
}

# Runs a shared-helper function directly in THIS shell (never inside a $(...)
# subshell, which would fork before FM_DASHBOARD_LINK_FAILED could be read
# back) and captures its combined output to $LIB_OUT for assertions.
LIB_OUT=
run_lib() {
  local outfile="$TMP_ROOT/lib-call.out"
  "$@" >"$outfile" 2>&1
  LIB_OUT=$(cat "$outfile")
}

test_lib_link_self_reads_status_and_advances_not_started() {
  reset_fake_dash
  FAKE_DASH_SHOW_JSON='{"status":"not_started"}'
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-1 home:t1 t1 t1 "$FM_DASHBOARD_LINK_SELF_READ"
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 0 ] || fail "self-read not_started should not report a failure: $LIB_OUT"
  assert_grep 'show card-1 --json' "$FAKE_DASH_LOG" "the self-read sentinel did not trigger its own show call"
  assert_contains "$LIB_OUT" "dashboard: linked card card-1 to t1 (ref=home:t1, agent=t1, status not_started -> working)" \
    "the self-read path did not report the not_started -> working advance"
  assert_grep_line 'status card-1 working' "$FAKE_DASH_LOG" "the advance did not call status working, or called it with arguments it was never given"
  pass "fm_dashboard_link_and_advance self-reads status and advances a not_started card"
}

test_lib_link_known_status_skips_its_own_read() {
  reset_fake_dash
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-2 sm:key2 sm key2 not_started
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 0 ] || fail "a known not_started status should not report a failure: $LIB_OUT"
  assert_no_grep 'show card-2' "$FAKE_DASH_LOG" "a pre-known status still triggered its own show call"
  assert_contains "$LIB_OUT" "dashboard: linked card card-2 to key2 (ref=sm:key2, agent=sm, status not_started -> working)" \
    "a pre-known not_started status did not advance"
  pass "fm_dashboard_link_and_advance trusts a caller-supplied known status instead of re-reading it"
}

test_lib_link_already_past_not_started_reports_without_advancing() {
  reset_fake_dash
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-3 sm:key3 sm key3 working
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 0 ] || fail "a card already past not_started should not report a failure: $LIB_OUT"
  assert_no_grep 'status card-3' "$FAKE_DASH_LOG" "a card already past not_started was advanced anyway"
  assert_contains "$LIB_OUT" "dashboard: linked card card-3 to key3 (ref=sm:key3, agent=sm)" \
    "a card already past not_started did not report the link"
  pass "fm_dashboard_link_and_advance links a card past not_started without touching its status"
}

test_lib_link_empty_known_status_is_a_failure_with_no_advance_attempt() {
  reset_fake_dash
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-4 sm:key4 sm key4 ''
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 1 ] || fail "an empty known status must be treated as a failure"
  assert_no_grep 'status card-4' "$FAKE_DASH_LOG" "an unread status was advanced anyway"
  assert_contains "$LIB_OUT" "warning: dashboard card link failed for key4 -> card card-4 (status):" \
    "an empty known status did not report the (status) failure"
  pass "fm_dashboard_link_and_advance never confirms a link whose status was never actually read"
}

test_lib_link_ref_failure_still_attempts_agent_and_skips_status() {
  reset_fake_dash
  FAKE_DASH_REF_RC=1
  FAKE_DASH_REF_ERR='boom: ref rejected'
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-5 sm:key5 sm key5 not_started
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 1 ] || fail "a failed ref write must report a failure"
  assert_contains "$LIB_OUT" "warning: dashboard card link failed for key5 -> card card-5 (ref): boom: ref rejected" \
    "a failed ref write did not report its own error text"
  assert_grep 'agent card-5 sm' "$FAKE_DASH_LOG" "the agent write was skipped after the ref write failed"
  assert_no_grep 'status card-5' "$FAKE_DASH_LOG" "the status was still advanced after the ref write failed"
  pass "fm_dashboard_link_and_advance still attempts the agent write after a failed ref write, but never the status advance"
}

test_lib_link_agent_failure_is_reported() {
  reset_fake_dash
  FAKE_DASH_AGENT_RC=1
  FAKE_DASH_AGENT_ERR='boom: agent rejected'
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-6 sm:key6 sm key6 not_started
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 1 ] || fail "a failed agent write must report a failure"
  assert_contains "$LIB_OUT" "warning: dashboard card link failed for key6 -> card card-6 (agent): boom: agent rejected" \
    "a failed agent write did not report its own error text"
  pass "fm_dashboard_link_and_advance reports a failed agent write"
}

test_lib_link_status_advance_failure_is_reported() {
  reset_fake_dash
  FAKE_DASH_STATUS_RC=1
  FAKE_DASH_STATUS_ERR='boom: status rejected'
  run_lib fm_dashboard_link_and_advance "$FAKE_DASH" card-7 sm:key7 sm key7 not_started
  [ "$FM_DASHBOARD_LINK_FAILED" -eq 1 ] || fail "a failed status advance must report a failure"
  assert_contains "$LIB_OUT" "warning: dashboard card link failed for key7 -> card card-7 (status working): boom: status rejected" \
    "a failed status advance did not report its own error text"
  pass "fm_dashboard_link_and_advance reports a failed status advance"
}

test_lib_advance_after_landing_skips_a_complete_card() {
  reset_fake_dash
  FAKE_DASH_SHOW_JSON='{"status":"complete"}'
  run_lib fm_dashboard_advance_after_landing "$FAKE_DASH" card-8 t8 review "audit msg t8"
  [ -z "$LIB_OUT" ] || fail "an already-complete card must produce no output at all: $LIB_OUT"
  assert_no_grep 'status card-8' "$FAKE_DASH_LOG" "an already-complete card was advanced anyway"
  assert_no_grep 'audit-log' "$FAKE_DASH_LOG" "an already-complete card wrote to the fleet audit log"
  pass "fm_dashboard_advance_after_landing silently leaves an already-complete card alone"
}

test_lib_advance_after_landing_advances_an_ordinary_status_with_no_reason() {
  reset_fake_dash
  FAKE_DASH_SHOW_JSON='{"status":"working"}'
  run_lib fm_dashboard_advance_after_landing "$FAKE_DASH" card-9 t9 review "audit msg t9"
  assert_contains "$LIB_OUT" "dashboard: advanced card card-9 to review for t9" \
    "an ordinary landed status did not advance to the target"
  assert_grep_line 'status card-9 review' "$FAKE_DASH_LOG" \
    "an ordinary status advance carried a --reason it was never given"
  pass "fm_dashboard_advance_after_landing advances an ordinary status with no --reason"
}

# The defect this whole extraction was scoped to fix: a card still
# needs_attention when its work lands must still advance (freezing it is its
# own stale-card failure), but the status change itself is what discards
# needs_attention_reason - so the advance call must carry it forward as its
# own --reason instead of letting it vanish with no trace.
test_lib_advance_after_landing_carries_needs_attention_reason_forward() {
  reset_fake_dash
  FAKE_DASH_SHOW_JSON='{"status":"needs_attention","needs_attention_reason":"approve the new vendor"}'
  run_lib fm_dashboard_advance_after_landing "$FAKE_DASH" card-10 t10 review "audit msg t10"
  assert_contains "$LIB_OUT" "dashboard: advanced card card-10 to review for t10" \
    "a needs_attention card whose work landed was not advanced to review"
  assert_grep_line "status card-10 review --reason approve the new vendor" "$FAKE_DASH_LOG" \
    "the needs_attention reason was not carried forward as the advance call's own --reason"
  pass "fm_dashboard_advance_after_landing carries a needs_attention card's reason forward instead of discarding it"
}

# The exact same defect on the sibling status: store.py's set_status nulls
# waiting_reason on any write whose target status is not waiting, by the same
# unconditional rule that clears needs_attention_reason, and teardown's guard
# (advance from anything but complete) reaches a waiting card just as readily.
# Which of the two columns is live is the only thing that differs.
test_lib_advance_after_landing_carries_waiting_reason_forward() {
  reset_fake_dash
  FAKE_DASH_SHOW_JSON='{"status":"waiting","waiting_reason":"the vendor to countersign"}'
  run_lib fm_dashboard_advance_after_landing "$FAKE_DASH" card-13 t13 review "audit msg t13"
  assert_contains "$LIB_OUT" "dashboard: advanced card card-13 to review for t13" \
    "a waiting card whose work landed was not advanced to review"
  assert_grep_line "status card-13 review --reason the vendor to countersign" "$FAKE_DASH_LOG" \
    "the waiting reason was not carried forward as the advance call's own --reason"
  pass "fm_dashboard_advance_after_landing carries a waiting card's reason forward instead of discarding it"
}

test_lib_advance_after_landing_show_failure_warns_and_audit_logs() {
  reset_fake_dash
  FAKE_DASH_SHOW_RC=1
  run_lib fm_dashboard_advance_after_landing "$FAKE_DASH" card-11 t11 review "audit msg t11"
  assert_contains "$LIB_OUT" "warning: dashboard card advance failed for t11 -> card card-11 (show):" \
    "an unreadable card did not report the (show) failure"
  assert_grep 'audit-log --fleet audit msg t11 --kind error' "$FAKE_DASH_LOG" \
    "an unreadable card did not record a fleet audit-log finding"
  assert_no_grep 'status card-11' "$FAKE_DASH_LOG" "an unreadable card was advanced anyway"
  pass "fm_dashboard_advance_after_landing warns and audit-logs when the card cannot be read"
}

test_lib_advance_after_landing_status_failure_warns_and_audit_logs() {
  reset_fake_dash
  FAKE_DASH_SHOW_JSON='{"status":"working"}'
  FAKE_DASH_STATUS_RC=1
  FAKE_DASH_STATUS_ERR='boom: review rejected'
  run_lib fm_dashboard_advance_after_landing "$FAKE_DASH" card-12 t12 review "audit msg t12"
  assert_contains "$LIB_OUT" "warning: dashboard card advance failed for t12 -> card card-12 (status review): boom: review rejected" \
    "a failed advance did not report its own error text"
  assert_grep 'audit-log --fleet audit msg t12 --kind error' "$FAKE_DASH_LOG" \
    "a failed advance did not record a fleet audit-log finding"
  pass "fm_dashboard_advance_after_landing warns and audit-logs when the status advance call itself fails"
}

# --- spawn-side fake tmux/treehouse (adapted from fm-spawn-worktree-settle.test.sh) ---

make_spawn_fakebin() {
  local dir=$1 fakebin wt=$2
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    # A recorded-target send, the window kill and the agent-state read all
    # resolve through an exact-NAME match: they ask \`-t "=<session>"\` for
    # '#{window_id} #{window_name}' and compare only the NAME half before
    # addressing the ID half. This stub's other answers model "the recorded
    # task endpoints are live", so that is the inventory it reports here, and
    # the synthetic @N id it pairs with each name is deliberately NOT the name,
    # so a regression that addressed the name where the id belongs cannot pass
    # by coincidence. Any other -F keeps the previous silent success.
    fm_fake_ses=
    fm_fake_prev=
    fm_fake_fmt=name
    for fm_fake_arg in "\$@"; do
      [ "\$fm_fake_prev" = -t ] && fm_fake_ses=\${fm_fake_arg#=}
      fm_fake_prev=\$fm_fake_arg
      case "\$fm_fake_arg" in *'#{window_id}'*) fm_fake_fmt=id ;; esac
    done
    [ "\$fm_fake_fmt" = id ] || exit 0
    fm_fake_ses=\${fm_fake_ses%%:*}
    fm_fake_n=0
    for fm_fake_meta in "\${FM_STATE_OVERRIDE:-\${FM_HOME:-/nonexistent}/state}"/*.meta; do
      [ -f "\$fm_fake_meta" ] || continue
      fm_fake_win=\$(sed -n 's/^window=//p' "\$fm_fake_meta" | head -1)
      case "\$fm_fake_win" in "\$fm_fake_ses":*) ;; *) continue ;; esac
      fm_fake_win=\${fm_fake_win#*:}
      case "\$fm_fake_win" in *:*|'') continue ;; esac
      fm_fake_n=\$((fm_fake_n + 1))
      printf '@%s %s\\n' "\$fm_fake_n" "\$fm_fake_win"
    done
    exit 0 ;;
  new-window)
    # Real tmux answers \`new-window -dP -F '#{window_id}'\` with the new
    # window's id, which fm_backend_tmux_create_task captures as the
    # rename-safe handle spawn-time typing then addresses. A stub that
    # printed nothing left that handle empty, so spawn silently fell back
    # to the name form for reads the id exists to make rename-proof.
    for fm_fake_arg in "\$@"; do
      case "\$fm_fake_arg" in -*P*) printf '@1\\n'; break ;; esac
    done
    exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id> - a home, a project with a real worktree, and a
# fake tmux that already reports the settled worktree path (no staleness to
# simulate here; that is fm-spawn-worktree-settle.test.sh's own concern).
# Echoes "<home>|<proj>|<wt>|<fakebin>".
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/data/$id"
  # Pin the crew harness. Without config/crew-harness, bin/fm-spawn.sh resolves
  # the harness from bin/fm-harness.sh's OWN-process detection, so the fixture
  # would inherit whatever harness happens to run the suite: a developer running
  # it under Claude Code gets claude and spawns fine, while a bare CI runner
  # detects `unknown`, finds no launch template, and fails every spawn here.
  # codex matches tests/fm-spawn-worktree-settle.test.sh and needs no executable
  # on PATH (its launch template is only typed into the fake pane).
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" "$wt")
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn() {  # <home> <proj> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 fakebin=$3 id=$4; shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode local-only --yolo off "$@" 2>&1
}

test_spawn_links_card_and_advances_not_started_to_working() {
  local rec home proj wt fakebin id card home_name out
  id=spawn-link-a1
  rec=$(make_spawn_case spawn-link "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=$(add_card "Spawn-link coverage")
  [ -n "$card" ] || fail "add_card returned no id"

  out=$(run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn with --card should succeed" "$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$out" "dashboard: linked card $card" "spawn did not report the dashboard link firing"
  assert_grep "dashboard_card=$card" "$home/state/$id.meta" "meta did not record dashboard_card="

  home_name=$(basename "$home")
  [ "$(card_field "$card" backlog_ref)" = "$home_name:$id" ] \
    || fail "card ref was not set to $home_name:$id"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "card agent was not set to the task id"
  [ "$(card_status "$card")" = working ] || fail "not_started card did not advance to working at spawn"
  pass "spawn --card links a not_started card's ref/agent and advances it to working"
}

test_spawn_without_card_flag_never_touches_the_dashboard() {
  local rec home proj wt fakebin id out
  id=spawn-nocard-a2
  rec=$(make_spawn_case spawn-nocard "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  out=$(run_spawn "$home" "$proj" "$fakebin" "$id")
  expect_code 0 "$?" "spawn without --card should succeed" "$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "dashboard:" "a card-less spawn printed a dashboard line"
  assert_no_grep "dashboard_card=" "$home/state/$id.meta" "meta recorded dashboard_card= with no --card given"
  pass "spawn without --card is a complete dashboard no-op (the normal case)"
}

test_spawn_with_unreachable_dashboard_still_succeeds_and_warns() {
  local rec home proj wt fakebin id card out
  id=spawn-unreach-a3
  rec=$(make_spawn_case spawn-unreach "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=some-card-id

  out=$(FM_DASHBOARD_PORT=1 run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn must not fail just because the dashboard is unreachable" "$out"
  assert_contains "$out" "spawned $id" "spawn did not report success despite the unreachable dashboard"
  assert_contains "$out" "warning: dashboard card link failed" "spawn did not warn about the failed link"
  assert_grep "dashboard_card=$card" "$home/state/$id.meta" \
    "meta should still record the requested card id even when the link call failed"
  pass "spawn --card never fails the spawn when the dashboard is unreachable, but warns loudly"
}

test_spawn_with_unknown_card_id_warns_and_records_a_fleet_finding() {
  local rec home proj wt fakebin id card out status_json
  id=spawn-unknown-a4
  rec=$(make_spawn_case spawn-unknown "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=does-not-exist-zzzz

  out=$(run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn must not fail just because --card names an unknown card" "$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for an unknown card id"
  assert_contains "$out" "warning: dashboard card link failed" "spawn did not warn about the unknown card"

  status_json=$("$DASH" audit-status --json)
  assert_contains "$status_json" "$id" "a failed link for an unknown card id was not recorded to the fleet audit log"
  assert_contains "$status_json" "$card" "the fleet audit log finding did not name the unresolved card"
  pass "spawn --card with an unknown card id warns and leaves a fleet-visible finding, not a silent drop"
}

# Regression, the spawn-side twin of the handoff bug below: the status read
# confirmed a link whose card state it never actually read. The show|jq
# pipeline's exit status is jq's, not the board's, so a failed GET left
# current_status empty, the not_started test was merely false, and control fell
# through to the branch that prints the link as confirmed - no advance, no
# warning, and no fleet finding, on a card still frozen at not_started with
# nothing left to say so. Driven by the same real proxy: every write reaches
# the real board, every card read fails.
test_spawn_never_confirms_a_link_whose_card_state_it_could_not_read() {
  local rec home proj wt fakebin id card out home_name status_json
  id=spawn-blindstatus-a5
  rec=$(make_spawn_case spawn-blindstatus "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  card=$(add_card "Spawn blind status coverage")
  [ -n "$card" ] || fail "add_card returned no id"

  start_card_read_failing_proxy spawnblindstatus
  out=$(FM_DASHBOARD_URL="http://127.0.0.1:$CARD_READ_FAIL_PORT" \
    run_spawn "$home" "$proj" "$fakebin" "$id" --card "$card")
  expect_code 0 "$?" "spawn must not fail because the card could not be read" "$out"
  stop_card_read_failing_proxy

  assert_contains "$out" "spawned $id" "the spawn itself did not succeed"
  assert_not_contains "$out" "dashboard: linked card" \
    "the link reported success while the card's own state was never readable"
  assert_contains "$out" "warning: dashboard card link failed" \
    "an unreadable card state was not reported as a failed link"

  home_name=$(basename "$home")
  [ "$(card_field "$card" backlog_ref)" = "$home_name:$id" ] \
    || fail "setup: the ref write should still have reached the real board through the proxy"
  [ "$(card_status "$card")" = not_started ] \
    || fail "the card advanced despite its state never being read"

  status_json=$("$DASH" audit-status --json)
  assert_contains "$status_json" "$card" \
    "a link left unconfirmed by an unreadable card state left no fleet-visible finding"
  pass "spawn never reports a link confirmed when the card's own state could not be read"
}

# --- teardown-side fake project/worktree (adapted from tests/fm-teardown.test.sh) ---

make_teardown_case() {
  local name=$1 id=$2 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

land_teardown_case() {  # <case_dir> <id> - commit on the worktree branch, then
  # fast-forward local main to it so the landed-work check passes with no PR.
  local case_dir=$1 id=$2 wt_head
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "land $id"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
}

run_teardown_case() {  # <case_dir> <id> [extra args...]
  local case_dir=$1 id=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

test_teardown_advances_linked_card_to_review_on_landed_work() {
  local id case_dir card out home_name
  id=teardown-link-b1
  card=$(add_card "Teardown-link coverage" --status working)
  case_dir=$(make_teardown_case teardown-link "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed local-only teardown should succeed" "$out"
  assert_contains "$out" "teardown $id complete" "teardown did not report completion"
  assert_contains "$out" "dashboard: advanced card $card to review" "teardown did not report the dashboard advance firing"
  [ "$(card_status "$card")" = review ] || fail "linked card did not advance to review on landed teardown"
  pass "teardown advances a linked card to review once landed cleanup actually succeeds"
}

test_teardown_without_dashboard_card_meta_is_a_noop() {
  local id case_dir out
  id=teardown-nocard-b2
  case_dir=$(make_teardown_case teardown-nocard "$id")
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed teardown with no linked card should still succeed" "$out"
  assert_not_contains "$out" "dashboard:" "a card-less teardown printed a dashboard line"
  pass "teardown with no dashboard_card= recorded is a complete dashboard no-op"
}

test_teardown_force_discard_never_advances_the_card() {
  local id case_dir card out
  id=teardown-force-b3
  card=$(add_card "Force-discard coverage" --status working)
  case_dir=$(make_teardown_case teardown-force "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  # Truly unpushed, not landed - only --force can tear this down, and a forced
  # discard must never be read as a landing.
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unlanded work"

  out=$(run_teardown_case "$case_dir" "$id" --force)
  expect_code 0 "$?" "forced teardown of unlanded work should still succeed" "$out"
  assert_not_contains "$out" "dashboard:" "a --force teardown reported advancing the card"
  [ "$(card_status "$card")" = working ] || fail "a --force (discard) teardown must never advance the linked card"
  pass "teardown --force never advances the linked card, since a forced discard is not a landing"
}

test_teardown_never_downgrades_an_already_complete_card() {
  local id case_dir card out
  id=teardown-complete-b4
  card=$(add_card "Already-approved coverage" --status working)
  "$DASH" status "$card" review >/dev/null || fail "setup: could not move card to review"
  "$DASH" status "$card" complete >/dev/null || fail "setup: could not move card to complete"
  case_dir=$(make_teardown_case teardown-complete "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed teardown should succeed" "$out"
  assert_not_contains "$out" "dashboard:" "teardown reported advancing an already-complete card"
  [ "$(card_status "$card")" = complete ] || fail "an already-complete card must never be downgraded back to review"
  pass "teardown never downgrades a card the Admiral already marked complete"
}

# Regression: a card still needs_attention when its serving task finally lands
# used to be advanced to review exactly like any other status - correct, since
# freezing it at needs_attention forever would just be a different stale-card
# failure - but the status change itself silently discarded
# needs_attention_reason with no trace at all (store.py's set_status keeps
# that column only while status stays needs_attention, and teardown never
# passed a --reason to carry it anywhere else). The Admiral could no longer
# tell what he had been asked, even though the card's own status history is
# exactly where that answer belongs.
test_teardown_preserves_needs_attention_reason_in_history_on_landing() {
  local id case_dir card out shown
  id=teardown-keepreason-b6
  card=$(add_card "Needs-attention reason coverage" --status working)
  "$DASH" status "$card" needs_attention --reason "approve the \$400 renewal" >/dev/null \
    || fail "setup: could not move card to needs_attention"
  case_dir=$(make_teardown_case teardown-keepreason "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed teardown should succeed" "$out"
  assert_contains "$out" "dashboard: advanced card $card to review" "teardown did not advance a needs_attention card whose work had actually landed"
  [ "$(card_status "$card")" = review ] \
    || fail "a needs_attention card must still advance once its work has landed - freezing it is its own stale-card bug"
  [ -z "$(card_field "$card" needs_attention_reason)" ] \
    || fail "needs_attention_reason must clear once the card leaves needs_attention (store.py's own contract)"

  # The reason text is ALSO present in an earlier status_history row (the
  # needs_attention transition set up above), regardless of what teardown
  # does - asserting only "the JSON blob contains this text somewhere" would
  # pass unchanged against the old code that discarded it, since that earlier
  # row survives either way. The thing that actually distinguishes old from
  # new behavior is whether THIS transition - needs_attention -> review, the
  # one teardown itself just made - carries the reason as its own note.
  shown=$("$DASH" show "$card" --json)
  local last_to last_note
  last_to=$(printf '%s' "$shown" | jq -r '.status_history[-1].to_status // empty')
  last_note=$(printf '%s' "$shown" | jq -r '.status_history[-1].note // empty')
  [ "$last_to" = review ] || fail "the most recent status history entry was not the needs_attention -> review transition (got to_status=$last_to)"
  [ "$last_note" = "approve the \$400 renewal" ] \
    || fail "the needs_attention -> review transition's own history note did not carry the reason forward (got note=[$last_note]) - the reason was silently discarded instead of carried into the card's status history"
  pass "teardown preserves a needs_attention card's reason in its status history instead of silently nulling it"
}

# The same regression on the sibling status, end to end against a real server:
# `waiting` is the other status with a reason column, store.py's set_status
# nulls it by the identical unconditional rule, and teardown's advance guard
# (anything but complete) reaches a waiting card exactly as it reaches a
# needs_attention one. Asserted the same discriminating way: on the note of the
# most recent status_history row, which is the waiting -> review transition
# teardown itself just made, not on the reason text appearing somewhere in the
# card's JSON (the earlier waiting-setting row carries that either way).
test_teardown_preserves_waiting_reason_in_history_on_landing() {
  local id case_dir card out shown
  id=teardown-keepwait-b7
  card=$(add_card "Waiting reason coverage" --status working)
  "$DASH" status "$card" waiting --reason "the vendor to countersign the \$400 renewal" >/dev/null \
    || fail "setup: could not move card to waiting"
  case_dir=$(make_teardown_case teardown-keepwait "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "landed teardown should succeed" "$out"
  assert_contains "$out" "dashboard: advanced card $card to review" "teardown did not advance a waiting card whose work had actually landed"
  [ "$(card_status "$card")" = review ] \
    || fail "a waiting card must still advance once its work has landed - freezing it is its own stale-card bug"
  [ -z "$(card_field "$card" waiting_reason)" ] \
    || fail "waiting_reason must clear once the card leaves waiting (store.py's own contract)"

  shown=$("$DASH" show "$card" --json)
  local last_to last_note
  last_to=$(printf '%s' "$shown" | jq -r '.status_history[-1].to_status // empty')
  last_note=$(printf '%s' "$shown" | jq -r '.status_history[-1].note // empty')
  [ "$last_to" = review ] || fail "the most recent status history entry was not the waiting -> review transition (got to_status=$last_to)"
  [ "$last_note" = "the vendor to countersign the \$400 renewal" ] \
    || fail "the waiting -> review transition's own history note did not carry the reason forward (got note=[$last_note]) - the reason was silently discarded instead of carried into the card's status history"
  pass "teardown preserves a waiting card's reason in its status history instead of silently nulling it"
}

test_teardown_with_unreachable_dashboard_still_succeeds_and_warns() {
  local id case_dir card out
  id=teardown-unreach-b5
  card=some-card-id
  case_dir=$(make_teardown_case teardown-unreach "$id")
  printf 'dashboard_card=%s\n' "$card" >> "$case_dir/state/$id.meta"
  land_teardown_case "$case_dir" "$id"

  out=$(FM_DASHBOARD_PORT=1 run_teardown_case "$case_dir" "$id")
  expect_code 0 "$?" "teardown must not fail just because the dashboard is unreachable" "$out"
  assert_contains "$out" "teardown $id complete" "teardown did not report completion despite the unreachable dashboard"
  assert_contains "$out" "warning: dashboard card advance failed" "teardown did not warn about the failed advance"
  pass "teardown --card advance never fails the teardown when the dashboard is unreachable, but warns loudly"
}

# --- handoff-side coverage (bin/fm-backlog-handoff.sh --card) ---------------
# A handed-off item has no local task metadata to hold dashboard_card= the way
# state/<id>.meta does, so the pairing lives in the handing-off home's own
# state directory and is consumed when arrival is confirmed. The handed-off
# item itself is never rewritten, which these tests assert directly: the
# secondmate's backlog must carry the item exactly as the main backlog held it.

setup_handoff_homes() {  # <main-home> <secondmate-home> [<secondmate-id>]
  local home=$1 sub=$2 id=${3:-design} sub_abs
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$sub" "$id"
  sub_abs=$(cd "$sub" && pwd -P)
  printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
    "$id" "$sub_abs" > "$home/data/secondmates.md"
}

test_handoff_links_card_and_advances_not_started_to_working() {
  local home sub id card out
  home="$TMP_ROOT/handoff-link-main"
  sub="$TMP_ROOT/handoff-link-sub"
  id=handoff-link-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a1 - fix the thing (repo: alpha)

## Done
EOF
  card=$(add_card "Handoff-link coverage")
  [ -n "$card" ] || fail "add_card returned no id"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff with --card should succeed" "$out"
  assert_contains "$out" "handed off 1 item(s)" "handoff did not report success"
  assert_contains "$out" "dashboard: linked card $card" "handoff did not report the dashboard link firing"

  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-a1" ] \
    || fail "card ref was not set to $id:handoff-item-a1"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "card agent was not set to the secondmate id"
  [ "$(card_status "$card")" = working ] || fail "not_started card did not advance to working at handoff"
  pass "handoff --card links a not_started card's ref/agent and advances it to working"
}

test_handoff_without_card_flag_never_touches_the_dashboard() {
  local home sub id out
  home="$TMP_ROOT/handoff-nocard-main"
  sub="$TMP_ROOT/handoff-nocard-sub"
  id=handoff-nocard-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a2 - unrelated queued work (repo: alpha)

## Done
EOF

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a2 2>&1)
  expect_code 0 "$?" "handoff without --card should succeed" "$out"
  assert_contains "$out" "handed off 1 item(s)" "handoff did not report success"
  assert_not_contains "$out" "dashboard:" "a card-less handoff printed a dashboard line"
  pass "handoff without --card is a complete dashboard no-op (the normal case)"
}

test_handoff_with_unreachable_dashboard_still_succeeds_and_warns() {
  local home sub id card out
  home="$TMP_ROOT/handoff-unreach-main"
  sub="$TMP_ROOT/handoff-unreach-sub"
  id=handoff-unreach-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a3 - fix the other thing (repo: alpha)

## Done
EOF
  card=some-card-id

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a3 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_contains "$out" "handed off 1 item(s)" "handoff did not report success despite the unreachable dashboard"
  assert_contains "$out" "warning: dashboard card link failed" "handoff did not warn about the failed link"
  assert_grep 'handoff-item-a3' "$sub/data/backlog.md" "the item did not land despite the link failing"
  pass "handoff --card never fails the handoff when the dashboard is unreachable, but warns loudly"
}

# The whole card-record-lifecycle bug in one test: a pending record must be
# retired only on a CONFIRMED link, never on a merely-attempted one. Reproduce
# it with a genuinely unreachable board (not just a wrong card id), confirm
# the record survives that failure untouched, then let the secondmate's next
# ordinary handoff - the same unconditional consume_handoff_card_record every
# local move already runs, the local twin of the remote outbox's own recovery
# - complete the stranded link once the board is reachable again.
test_handoff_card_record_survives_a_failed_link_and_completes_on_the_next_handoff() {
  local home sub id card out record
  home="$TMP_ROOT/handoff-survive-main"
  sub="$TMP_ROOT/handoff-survive-sub"
  id=handoff-survive-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-b1 - fix the survive case (repo: alpha)
- [ ] handoff-item-b2 - a later unrelated handoff (repo: alpha)

## Done
EOF
  card=$(add_card "Card-record-survives coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-b1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_contains "$out" "warning: dashboard card link failed" "handoff did not warn about the failed link"
  assert_grep "$(printf 'handoff-item-b1\t%s' "$card")" "$record" \
    "a failed link must leave the pending card record in place, not delete it"
  [ "$(card_status "$card")" = not_started ] \
    || fail "a card whose link merely failed must not read as linked"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-b2 2>&1)
  expect_code 0 "$?" "the next ordinary handoff should succeed" "$out"
  assert_contains "$out" "dashboard: linked card $card" \
    "the next handoff to this secondmate did not complete the earlier stranded link"
  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-b1" ] \
    || fail "completed link did not set ref to the originally staged item, not the later one"
  [ "$(card_status "$card")" = working ] \
    || fail "the stranded card did not advance to working once the board became reachable"
  [ ! -e "$record" ] || fail "the card record should be retired once the board confirmed the link"
  pass "a card record survives a failed link and completes on the secondmate's next handoff"
}

# The fleet audit log is never written from a machine-cadence path. This is
# --resume-pending's own twin of the general transport-failure rule already
# covered for spawn/handoff above: the card read succeeds (probe==0, and the
# card is still blank, so it is ours to write), but the ref/agent/status write
# calls themselves fail. bin/fm-bootstrap.sh runs --resume-pending unattended
# on every session start, so that failure must warn on stderr only and never
# reach bin/fm-dashboard.sh audit-log --fleet.
test_resume_pending_never_writes_the_fleet_audit_log_for_a_transport_failure() {
  local home sub id card out record findings
  home="$TMP_ROOT/handoff-resume-writefail-main"
  sub="$TMP_ROOT/handoff-resume-writefail-sub"
  id=handoff-resume-writefail-sm
  setup_handoff_homes "$home" "$sub" "$id"
  card=$(add_card "Resume write-fail coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"
  mkdir -p "$(dirname "$record")"
  printf 'resume-writefail-item\t%s' "$card" > "$record"

  start_card_write_failing_proxy resumewritefail
  out=$(FM_DASHBOARD_PORT="$CARD_WRITE_FAIL_PORT" FM_HOME="$home" "$HANDOFF" --resume-pending 2>&1)
  expect_code 0 "$?" "--resume-pending should succeed even when the board rejects the write" "$out"
  stop_card_write_failing_proxy
  assert_contains "$out" "warning: dashboard card link failed" \
    "resume did not warn about the transport failure"
  [ "$(card_status "$card")" = not_started ] \
    || fail "a card whose write genuinely failed must not read as linked"
  assert_grep "$(printf 'resume-writefail-item\t%s' "$card")" "$record" \
    "a failed write must leave the pending card record in place"

  findings=$("$DASH" audit-status --json | jq --arg c "$card" '[.log[] | select(.text | contains($c))] | length')
  [ "$findings" -eq 0 ] \
    || fail "--resume-pending's own transport failure must never reach the fleet audit log"
  pass "--resume-pending never writes the fleet audit log for a transport failure, only stderr"
}

# The operator-initiated counterpart: this same transport failure IS allowed
# to reach the fleet audit log for a direct (non --resume-pending) handoff,
# but at most once per invocation, even when the sweep hits it twice - once
# for a leftover pair from an earlier crashed attempt, once for the pair this
# call itself just staged.
test_operator_handoff_writes_the_fleet_audit_log_once_per_invocation_for_two_transport_failures() {
  local home sub id leftover_card new_card out record findings
  home="$TMP_ROOT/handoff-operator-writefail-main"
  sub="$TMP_ROOT/handoff-operator-writefail-sub"
  id=handoff-operator-writefail-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] operator-writefail-item - hand this one off too (repo: alpha)

## Done
EOF
  leftover_card=$(add_card "Operator write-fail leftover coverage")
  [ -n "$leftover_card" ] || fail "add_card returned no id for the leftover pair"
  new_card=$(add_card "Operator write-fail new coverage")
  [ -n "$new_card" ] || fail "add_card returned no id for the new pair"
  record="$home/state/handoff-cards/$id"
  mkdir -p "$(dirname "$record")"
  printf 'operator-writefail-leftover\t%s' "$leftover_card" > "$record"

  start_card_write_failing_proxy operatorwritefail
  out=$(FM_DASHBOARD_PORT="$CARD_WRITE_FAIL_PORT" FM_HOME="$home" \
    "$HANDOFF" "$id" operator-writefail-item --card "$new_card" 2>&1)
  expect_code 0 "$?" "the handoff should succeed even when the board rejects both writes" "$out"
  stop_card_write_failing_proxy
  assert_contains "$out" "operator-writefail-leftover -> card $leftover_card" \
    "no transport-failure warning named the leftover pair"
  assert_contains "$out" "operator-writefail-item -> card $new_card" \
    "no transport-failure warning named the newly staged pair"
  [ "$(card_status "$leftover_card")" = not_started ] \
    || fail "the leftover card whose write failed must not read as linked"
  [ "$(card_status "$new_card")" = not_started ] \
    || fail "the newly staged card whose write failed must not read as linked"

  findings=$("$DASH" audit-status --json | jq \
    --arg a "$leftover_card" --arg b "$new_card" \
    '[.log[] | select((.text | contains($a)) or (.text | contains($b)))] | length')
  [ "$findings" -eq 1 ] \
    || fail "an operator-initiated handoff must write the fleet audit log at most once per invocation, got $findings"
  pass "an operator-initiated handoff caps its fleet audit log write at one per invocation"
}

# Regression: --resume-pending is the documented recovery command for a link
# that could not be completed, but a locally handed-off item never writes an
# outbox, so a sweep that only walks pending outboxes never reaches it - the
# card stays frozen until some unrelated later handoff to the same secondmate
# happens to sweep the record. --resume-pending has to mean every pending
# link, not the remote half of them.
test_resume_pending_completes_a_stranded_local_card_link() {
  local home sub id card out record
  home="$TMP_ROOT/handoff-local-resume-main"
  sub="$TMP_ROOT/handoff-local-resume-sub"
  id=handoff-local-resume-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-l1 - stranded by a board that was down (repo: alpha)

## Done
EOF
  card=$(add_card "Local resume-pending coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-l1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_grep 'handoff-item-l1' "$sub/data/backlog.md" "the local move did not land"
  assert_grep "$(printf 'handoff-item-l1\t%s' "$card")" "$record" \
    "a failed link must leave the pending card record in place"
  [ "$(card_status "$card")" = not_started ] || fail "a card whose link merely failed must not read as linked"
  assert_absent "$home/data/handoff/$id.outbox.md" "a local handoff must not write a remote outbox"

  out=$(FM_HOME="$home" "$HANDOFF" --resume-pending 2>&1)
  expect_code 0 "$?" "--resume-pending should succeed with only a local record pending" "$out"
  assert_contains "$out" "dashboard: linked card $card" \
    "--resume-pending did not complete the stranded local link"
  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-l1" ] \
    || fail "--resume-pending did not set the card ref to the stranded pair's item"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "--resume-pending did not set the card agent"
  [ "$(card_status "$card")" = working ] || fail "the stranded card did not advance to working on resume"
  assert_absent "$record" "the card record should be retired once the board confirmed the link"
  pass "--resume-pending completes a local secondmate's stranded card link, not just a remote outbox's"
}

# Regression: --resume-pending is not something an operator remembers to run -
# bin/fm-bootstrap.sh runs it on every session start, and that is the whole
# "card reaches review without a human remembering" half of the mechanism. Its
# gate used to require a pending remote outbox, which a purely local secondmate
# never has, so a link stranded by a board that was down stayed stranded across
# every subsequent session start. Driven through bin/fm-bootstrap.sh itself
# rather than the handoff script, because the gate is bootstrap's own.
test_session_start_completes_a_stranded_local_card_link() {
  local home sub id card out record fakebin
  home="$TMP_ROOT/handoff-bootstrap-resume-main"
  sub="$TMP_ROOT/handoff-bootstrap-resume-sub"
  id=handoff-bootstrap-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-b1 - stranded by a board that was down (repo: alpha)

## Done
EOF
  card=$(add_card "Session-start resume coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-b1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_grep "$(printf 'handoff-item-b1\t%s' "$card")" "$record" \
    "a failed link must leave the pending card record in place"
  assert_absent "$home/data/handoff" "a local handoff must not create a remote outbox directory"
  [ "$(card_status "$card")" = not_started ] || fail "a card whose link merely failed must not read as linked"

  # gh is the only other thing bootstrap's network half reaches for here, and
  # what it answers is owned elsewhere; stub it so this case stays hermetic.
  # FM_ROOT_OVERRIDE points bootstrap's own repo-relative sweeps at the fixture
  # home, which has no clones to refresh - the resume it invokes resolves this
  # repo's scripts from its own location either way.
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_NETWORK=only "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  expect_code 0 "$?" "session start should succeed while sweeping a pending card record" "$out"
  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-b1" ] \
    || fail "session start did not complete the stranded link's card ref"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "session start did not set the card agent"
  [ "$(card_status "$card")" = working ] || fail "the stranded card did not advance to working at session start"
  assert_absent "$record" "the card record should be retired once the board confirmed the link"

  # And with the pair retired, the marker that reported it goes quiet.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_not_contains "$out" 'pending card link(s)' \
    "session start still reported a card link the board had already confirmed"
  pass "a session start sweeps a purely local secondmate's stranded card link to completion"
}

# Regression: docs/dashboard.md and this mechanism's own warnings send the
# operator to state/handoff-cards/<secondmate-id> to unpick a half-written link
# by hand, so a record saved by an editor that does not terminate its last line
# is an anticipated input, not a hypothetical one. Both loops over that file
# used to stop before an unterminated final line: the sweep never linked the
# pair it named, and the retiring rewrite silently deleted it, losing the only
# evidence the link was still owed. Two pairs, the last one unterminated, so
# the rewrite that retires the first has to carry the second through.
test_handoff_record_without_a_trailing_newline_loses_no_pair() {
  local home sub id card record out
  home="$TMP_ROOT/handoff-unterminated-main"
  sub="$TMP_ROOT/handoff-unterminated-sub"
  id=handoff-unterminated-sm
  setup_handoff_homes "$home" "$sub" "$id"
  card=$(add_card "Unterminated record coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"
  mkdir -p "$(dirname "$record")"
  printf 'hand-item-h1\t%s\nhand-item-h2\tdefinitely-no-such-card' "$card" > "$record"

  out=$(FM_HOME="$home" "$HANDOFF" --resume-pending 2>&1)
  expect_code 0 "$?" "--resume-pending should succeed on a hand-edited record" "$out"
  assert_contains "$out" "has no card definitely-no-such-card" \
    "the unterminated final pair was never swept at all"
  [ "$(card_field "$card" backlog_ref)" = "$id:hand-item-h1" ] \
    || fail "the terminated pair's card was not linked"
  [ "$(card_status "$card")" = working ] || fail "the linked card did not advance to working"
  assert_grep "$(printf 'hand-item-h2\tdefinitely-no-such-card')" "$record" \
    "retiring the confirmed pair silently deleted the unterminated final line"
  assert_no_grep "$(printf 'hand-item-h1\t%s' "$card")" "$record" \
    "the confirmed pair was not retired from the record"
  pass "a hand-edited record whose last line has no trailing newline loses no pending pair"
}

# Regression: the link writes ref and agent as two separate board calls, so a
# link of the handoff's own that fails between them leaves the card carrying
# OUR ref and nothing else. Asking only "does this card carry anything at all"
# reads that half-written attempt as somebody else's claim, retires the
# pending record, and leaves the card frozen at not_started with nothing left
# to retry from - the exact failure the record exists to prevent. The guard
# has to test identity: never overwrite another writer's link, always finish
# your own.
test_handoff_finishes_its_own_half_written_card_link() {
  local home sub id card out record
  home="$TMP_ROOT/handoff-halfwritten-main"
  sub="$TMP_ROOT/handoff-halfwritten-sub"
  id=handoff-halfwritten-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-c1 - the half-linked item (repo: alpha)
- [ ] handoff-item-c2 - a later unrelated handoff (repo: alpha)

## Done
EOF
  card=$(add_card "Half-written link coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  # Stage the pair against an unreachable board, so the pending record is
  # written and survives exactly as a real interrupted link leaves it.
  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-c1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_grep "$(printf 'handoff-item-c1\t%s' "$card")" "$record" \
    "the pending card record was not staged"

  # The board state a link that set ref and then failed leaves behind: our own
  # ref present, no agent, still not_started.
  "$DASH" ref "$card" "$id:handoff-item-c1" >/dev/null || fail "setup: could not set the card ref"
  [ -z "$(card_field "$card" agent)" ] || fail "setup: the card should not carry an agent yet"
  [ "$(card_status "$card")" = not_started ] || fail "setup: the card should still be not_started"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-c2 2>&1)
  expect_code 0 "$?" "the next ordinary handoff should succeed" "$out"
  assert_not_contains "$out" "left unchanged" \
    "the sweep mistook this mechanism's own half-written link for somebody else's claim"
  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-c1" ] \
    || fail "finishing our own link changed the ref it had already staged"
  [ "$(card_field "$card" agent)" = "$id" ] \
    || fail "a half-written link of our own was abandoned instead of finished"
  [ "$(card_status "$card")" = working ] \
    || fail "the half-linked card never advanced past not_started"
  [ ! -e "$record" ] || fail "the record should retire once the link is genuinely complete"
  pass "a handoff finishes its own half-written card link instead of retiring it as somebody else's"
}

# A host that answers "no such card" has NOT proved it is the board - a stale
# dashboard url pointing at a machine that still serves HTTP 404s every card
# alike - so the pending record survives it exactly like an unreachable board.
# The stderr report is bounded per command, not forever: an arrival that finds
# the link still owed says so again, deliberately. It never reaches the fleet
# audit log at all - bin/fm-bootstrap.sh's own --resume-pending sweep runs
# this same branch on every session start with no operator behind it, and a
# durable, cumulative entry there would cost the Admiral's trust in that log
# on a cadence nobody controls; surfacing a permanently unlinkable pair to him
# is the fleet auditor's job, raised once through its own sweep, not this
# path's on every boot.
test_handoff_keeps_and_retries_a_pair_the_host_says_names_no_such_card() {
  local home sub id card out record findings
  home="$TMP_ROOT/handoff-nocard-id-main"
  sub="$TMP_ROOT/handoff-nocard-id-sub"
  id=handoff-nocardid-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-d1 - names a card that does not exist (repo: alpha)
- [ ] handoff-item-d2 - a later unrelated handoff (repo: alpha)

## Done
EOF
  card=does-not-exist-handoff-zzzz
  record="$home/state/handoff-cards/$id"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-d1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because --card names an unknown card" "$out"
  assert_contains "$out" "handed off 1 item(s)" "the handoff itself did not succeed"
  assert_contains "$out" "has no card $card" "the handoff did not report the unlinkable card"
  assert_grep 'handoff-item-d1' "$sub/data/backlog.md" "the item did not land"
  assert_grep "$(printf 'handoff-item-d1\t%s' "$card")" "$record" \
    "a card the host merely says it does not have must stay recorded, like any other failed link"
  [ "$(grep -c "has no card $card" <<<"$out")" -eq 1 ] \
    || fail "one handoff reported the same unlinkable pair more than once"

  findings=$("$DASH" audit-status --json | jq --arg c "$card" '[.log[] | select(.text | contains($c))] | length')
  [ "$findings" = 0 ] \
    || fail "an unlinkable card must never reach the fleet audit log - bootstrap sweeps it on every boot, got $findings finding(s)"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-d2 2>&1)
  expect_code 0 "$?" "the next ordinary handoff should succeed" "$out"
  assert_contains "$out" "has no card $card" \
    "a later arrival stayed silent about a link that is still genuinely owed"
  findings=$("$DASH" audit-status --json | jq --arg c "$card" '[.log[] | select(.text | contains($c))] | length')
  [ "$findings" = 0 ] \
    || fail "a second arrival must still never write to the fleet audit log, got $findings finding(s)"
  assert_grep "$(printf 'handoff-item-d1\t%s' "$card")" "$record" \
    "the pending pair was dropped by a later arrival instead of staying retriable"
  pass "an unlinkable card id stays recorded and retriable on stderr only, never reaching the fleet audit log"
}

# Regression: the status advance used to re-read the card through a second
# `show`, whose failure was masked by the missing pipefail - an unread status
# is indistinguishable from "already past not_started", so the link reported
# itself CONFIRMED, the record was retired, and the card stayed frozen at
# not_started with nothing left to retry it. Drive that with a real proxy that
# forwards the writes to the real board but fails every card read, which is
# exactly the mid-sequence outage the original report describes.
test_handoff_never_confirms_a_link_whose_card_state_it_could_not_read() {
  local home sub id card out record
  home="$TMP_ROOT/handoff-blindstatus-main"
  sub="$TMP_ROOT/handoff-blindstatus-sub"
  id=handoff-blindstatus-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-e1 - linked while the card is unreadable (repo: alpha)
- [ ] handoff-item-e2 - a later handoff once the board is whole again (repo: alpha)

## Done
EOF
  card=$(add_card "Blind status coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  start_card_read_failing_proxy blindstatus

  out=$(FM_DASHBOARD_URL="http://127.0.0.1:$CARD_READ_FAIL_PORT" FM_HOME="$home" \
    "$HANDOFF" "$id" handoff-item-e1 --card "$card" 2>&1)
  expect_code 0 "$?" "the handoff must not fail because the card could not be read" "$out"
  assert_contains "$out" "handed off 1 item(s)" "the handoff itself did not succeed"
  assert_not_contains "$out" "dashboard: linked card" \
    "the link reported success while the card's own state was never readable"
  assert_contains "$out" "warning: dashboard card link failed" \
    "an unreadable card state was not reported as a failed link"
  [ "$(card_status "$card")" = not_started ] \
    || fail "the card advanced despite its state never being read"
  assert_grep "$(printf 'handoff-item-e1\t%s' "$card")" "$record" \
    "a link that never confirmed the card's status retired the only record that could retry it"

  stop_card_read_failing_proxy

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-e2 2>&1)
  expect_code 0 "$?" "the next ordinary handoff should succeed" "$out"
  [ "$(card_status "$card")" = working ] \
    || fail "the stranded card never advanced once the board was whole again"
  [ ! -e "$record" ] || fail "the record should retire once the link is genuinely complete"
  pass "a link whose card state could not be read is never confirmed, so its record stays retriable"
}

# Regression, two halves of the same rule. Re-recording a key with a corrected
# card id used to replace the old pair outright, discarding a link that may
# already be half-written on the old card; keeping it must not swing the other
# way either, because linking BOTH would mark a card the operator has already
# disowned as served under an agent that is not serving it. Only the newest
# card recorded for an item key is ever written to.
test_handoff_supersedes_rather_than_also_linking_a_corrected_card() {
  local home sub id first second out record
  home="$TMP_ROOT/handoff-recard-main"
  sub="$TMP_ROOT/handoff-recard-sub"
  id=handoff-recard-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-f1 - first named the wrong card (repo: alpha)
- [ ] handoff-item-f2 - a later handoff that sweeps with the board up (repo: alpha)

## Done
EOF
  first=$(add_card "Mistyped card coverage")
  second=$(add_card "Corrected card coverage")
  [ -n "$first" ] && [ -n "$second" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-f1 --card "$first" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_grep "$(printf 'handoff-item-f1\t%s' "$first")" "$record" "the first pairing was not recorded"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-f1 --card "$second" 2>&1)
  expect_code 0 "$?" "re-running an already-landed handoff should still succeed" "$out"
  assert_contains "$out" "still has an unresolved dashboard card pairing to $first" \
    "re-naming the card said nothing about the pairing already pending for that item"
  assert_grep "$(printf 'handoff-item-f1\t%s' "$first")" "$record" \
    "a still-unresolved pairing was silently dropped when a different card was named"
  assert_grep "$(printf 'handoff-item-f1\t%s' "$second")" "$record" \
    "the newly named card was not recorded"
  assert_contains "$out" "was superseded by a later --card" \
    "the sweep said nothing about skipping the superseded card"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-f2 2>&1)
  expect_code 0 "$?" "the next ordinary handoff should succeed" "$out"
  [ "$(card_field "$second" backlog_ref)" = "$id:handoff-item-f1" ] \
    || fail "the corrected card was not linked"
  [ "$(card_status "$second")" = working ] || fail "the corrected card did not advance to working"
  [ -z "$(card_field "$first" backlog_ref)" ] \
    || fail "a card the operator already disowned was linked anyway"
  [ -z "$(card_field "$first" agent)" ] \
    || fail "a card the operator already disowned had an agent written to it"
  [ "$(card_status "$first")" = not_started ] \
    || fail "a card the operator already disowned was advanced as if it were being served"
  assert_contains "$out" "was superseded by a later --card" \
    "the disowned pair stopped being reported while it is still sitting in the record"
  assert_grep "$(printf 'handoff-item-f1\t%s' "$first")" "$record" \
    "the superseded pair should stay recorded as the reminder to check that card by hand"
  pass "only the newest card recorded for an item is linked; the superseded one is reported but never written"
}

# The superseded ledger is the one durable mark here and is appended to, so a
# crash or a hand edit can leave its last entry without a trailing newline. An
# append onto that file used to run straight onto the partial line, fusing two
# standing decisions into one string that matches neither - and a mark that no
# longer matches is a card the operator has already disowned being written to
# on the next sweep, which is the exact drift the mark exists to prevent.
test_superseded_mark_survives_an_append_onto_an_unterminated_ledger() {
  local home sub id kept first second out ledger
  home="$TMP_ROOT/handoff-ledger-tail-main"
  sub="$TMP_ROOT/handoff-ledger-tail-sub"
  id=handoff-ledger-tail-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-n1 - the item whose card gets corrected (repo: alpha)
- [ ] handoff-item-n2 - the item already marked in the ledger (repo: alpha)

## Done
EOF
  first=$(add_card "Ledger-tail mistyped coverage")
  second=$(add_card "Ledger-tail corrected coverage")
  kept=$(add_card "Ledger-tail pre-marked coverage")
  [ -n "$first" ] && [ -n "$second" ] && [ -n "$kept" ] || fail "add_card returned no id"
  ledger="$home/state/handoff-card-superseded/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-n1 --card "$first" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-n2 --card "$kept" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  mkdir -p "$(dirname "$ledger")"
  printf 'handoff-item-n2\t%s' "$kept" > "$ledger"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-n1 --card "$second" 2>&1)
  expect_code 0 "$?" "re-running an already-landed handoff should still succeed" "$out"

  out=$(FM_HOME="$home" "$HANDOFF" --resume-pending 2>&1)
  expect_code 0 "$?" "--resume-pending should succeed with the board back up" "$out"
  [ "$(card_field "$second" backlog_ref)" = "$id:handoff-item-n1" ] \
    || fail "the corrected card was not linked"
  [ -z "$(card_field "$first" backlog_ref)" ] \
    || fail "the mark appended onto an unterminated ledger did not take, so a disowned card was linked"
  [ -z "$(card_field "$kept" backlog_ref)" ] \
    || fail "an appended mark ran onto the ledger's unterminated last entry and destroyed it"
  [ "$(card_status "$kept")" = not_started ] \
    || fail "a card disowned by the ledger's last entry was advanced as if it were being served"
  pass "an appended superseded mark neither destroys nor is destroyed by an unterminated last ledger entry"
}

# The other half of that rule, and the only escape from it. Being superseded is
# the one durable mark this mechanism keeps, and nothing the board can answer
# ever retires it - so if naming that card again did not clear it, a --card typo
# in the *correction* would strand the right card permanently, linkable by
# nothing and warning on every sweep, with hand-editing state the only way out.
# docs/dashboard.md states the reversibility as a guarantee; this pins it.
test_renaming_a_superseded_card_makes_it_linkable_again() {
  local home sub id first second out record
  home="$TMP_ROOT/handoff-revive-main"
  sub="$TMP_ROOT/handoff-revive-sub"
  id=handoff-revive-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-v1 - named right, then wrong, then right again (repo: alpha)
- [ ] handoff-item-v2 - a later handoff that sweeps with the board up (repo: alpha)

## Done
EOF
  first=$(add_card "Revive target coverage")
  second=$(add_card "Mistyped correction coverage")
  [ -n "$first" ] && [ -n "$second" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-v1 --card "$first" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-v1 --card "$second" 2>&1)
  expect_code 0 "$?" "re-naming the card should still succeed" "$out"
  assert_contains "$out" "was superseded by a later --card" \
    "setup: the first card was never disowned, so there is nothing to reverse"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-v1 --card "$first" 2>&1)
  expect_code 0 "$?" "naming the original card again should still succeed" "$out"
  assert_grep "$(printf 'handoff-item-v1\t%s' "$first")" "$record" "the revived pair was not recorded"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-v2 2>&1)
  expect_code 0 "$?" "the next ordinary handoff should succeed" "$out"
  [ "$(card_field "$first" backlog_ref)" = "$id:handoff-item-v1" ] \
    || fail "a card whose supersession the operator reversed from the CLI was still never linked"
  [ "$(card_field "$first" agent)" = "$id" ] || fail "the revived card was not given the secondmate as its agent"
  [ "$(card_status "$first")" = working ] || fail "the revived card did not advance to working"
  [ -z "$(card_field "$second" backlog_ref)" ] \
    || fail "the mistyped correction was linked even though it is now the disowned one"
  [ "$(card_status "$second")" = not_started ] \
    || fail "the mistyped correction was advanced as if it were being served"
  pass "naming a superseded card again clears the mark, so a typo in the correction is recoverable from the CLI"
}

# The report set has to tell its entries apart, not merely remember that it saw
# something. One command owing reports about two distinct pairs must emit both:
# a set that collapsed its keys - which is exactly what a string-subscripted
# bash 3.2 array does, silently indexing every mark to 0 - would swallow the
# second and leave a genuinely unlinkable card with nothing said about it.
test_one_command_reports_every_distinct_unlinkable_pair_not_just_the_first() {
  local home sub id first second out findings
  home="$TMP_ROOT/handoff-twopair-main"
  sub="$TMP_ROOT/handoff-twopair-sub"
  id=handoff-twopair-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-w1 - first unlinkable card (repo: alpha)
- [ ] handoff-item-w2 - second unlinkable card (repo: alpha)
- [ ] handoff-item-w3 - a later handoff that sweeps both (repo: alpha)

## Done
EOF
  first=does-not-exist-twopair-aaaa
  second=does-not-exist-twopair-bbbb

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-w1 --card "$first" 2>&1)
  expect_code 0 "$?" "staging the first pair should succeed" "$out"
  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-w2 --card "$second" 2>&1)
  expect_code 0 "$?" "staging the second pair should succeed" "$out"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-w3 2>&1)
  expect_code 0 "$?" "the sweeping handoff should succeed" "$out"
  assert_contains "$out" "has no card $first" "the first unlinkable pair went unreported"
  assert_contains "$out" "has no card $second" \
    "the second unlinkable pair was swallowed, so the report set cannot tell its entries apart"
  findings=$("$DASH" audit-status --json \
    | jq --arg a "$first" --arg b "$second" \
      '[.log[] | select(.text | contains($a) or contains($b))] | length')
  [ "$findings" = 0 ] \
    || fail "an unlinkable pair must never reach the fleet audit log, even a second distinct one in the same sweep - got $findings finding(s)"
  pass "one command reports every distinct unlinkable pair it sweeps on stderr, not just the first, and never on the fleet audit log"
}

# Regression: the ownership guard was gated on a successful card read, so a
# read failure skipped the identity check entirely and the link wrote ref and
# agent blind - destroying the precise <home>:<task-id> claim a secondmate's
# own fm-spawn.sh --card had since made, which is the one thing the rule
# "never overwrite another writer's link" forbids. The guard has to fail
# closed: no read, no write.
test_handoff_never_writes_a_guarded_card_it_could_not_read() {
  local home sub id card out record
  home="$TMP_ROOT/handoff-blindguard-main"
  sub="$TMP_ROOT/handoff-blindguard-sub"
  id=handoff-blindguard-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-h1 - staged before the secondmate spawned against the card (repo: alpha)
- [ ] handoff-item-h2 - a later handoff that sweeps while reads fail (repo: alpha)

## Done
EOF
  card=$(add_card "Blind guard coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$home/state/handoff-cards/$id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-h1 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff must not fail just because the dashboard is unreachable" "$out"
  assert_grep "$(printf 'handoff-item-h1\t%s' "$card")" "$record" "the pending pair was not recorded"

  # Exactly what the secondmate's own fm-spawn.sh --card writes once it picks
  # the item up: a precise <home>:<task-id> ref and the task id as agent.
  "$DASH" ref "$card" "sm-home:task-9" >/dev/null || fail "setup: could not set the card ref"
  "$DASH" agent "$card" task-9 >/dev/null || fail "setup: could not set the card agent"
  "$DASH" status "$card" working >/dev/null || fail "setup: could not move the card to working"

  start_card_read_failing_proxy blindguard
  out=$(FM_DASHBOARD_URL="http://127.0.0.1:$CARD_READ_FAIL_PORT" FM_HOME="$home" \
    "$HANDOFF" "$id" handoff-item-h2 2>&1)
  expect_code 0 "$?" "the card-less handoff must not fail because a card could not be read" "$out"
  stop_card_read_failing_proxy

  assert_contains "$out" "could not read dashboard card $card" \
    "the sweep did not report that it could not check the card before writing"
  [ "$(card_field "$card" backlog_ref)" = "sm-home:task-9" ] \
    || fail "an unreadable card was overwritten with the coarse handoff ref"
  [ "$(card_field "$card" agent)" = task-9 ] \
    || fail "an unreadable card was overwritten with the coarse handoff agent"
  assert_grep "$(printf 'handoff-item-h1\t%s' "$card")" "$record" \
    "a pair whose card could not be read was retired instead of left for the next arrival"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-h2 2>&1)
  expect_code 0 "$?" "the retry should succeed once reads work again" "$out"
  assert_contains "$out" "already links to sm-home:task-9" \
    "the retry did not report leaving the more precise claim alone"
  [ ! -e "$record" ] || fail "the pair should retire once the board confirmed a more precise claim"
  pass "a guarded card that could not be read is never written to, and stays recorded for the retry"
}

# The card link is firstmate-local bookkeeping done after the move has already
# landed and been reported, so a failure to write it must never retroactively
# turn that reported success into a non-zero exit.
test_handoff_record_bookkeeping_failure_never_fails_the_handoff() {
  local home sub id card out rc
  [ "$(id -u)" -ne 0 ] || { pass "skipped record-bookkeeping-failure coverage - running as root ignores permissions"; return 0; }
  home="$TMP_ROOT/handoff-bookkeeping-main"
  sub="$TMP_ROOT/handoff-bookkeeping-sub"
  id=handoff-bookkeeping-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-g1 - staged while the record is writable (repo: alpha)
- [ ] handoff-item-g2 - swept once the record cannot be rewritten (repo: alpha)

## Done
EOF
  card=$(add_card "Unwritable record coverage")
  [ -n "$card" ] || fail "add_card returned no id"

  out=$(FM_DASHBOARD_PORT=1 FM_HOME="$home" "$HANDOFF" "$id" handoff-item-g1 --card "$card" 2>&1)
  expect_code 0 "$?" "staging the pending pair should succeed" "$out"

  chmod 500 "$home/state/handoff-cards" || fail "could not make the record directory unwritable"
  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-g2 2>&1) && rc=0 || rc=$?
  chmod 700 "$home/state/handoff-cards"

  expect_code 0 "$rc" "a purely local bookkeeping failure turned a completed handoff into a reported failure" "$out"
  assert_contains "$out" "handed off 1 item(s)" "the handoff itself did not complete"
  assert_grep 'handoff-item-g2' "$sub/data/backlog.md" "the item did not land"
  pass "a card-record write failure warns without failing a handoff that already landed"
}

test_handoff_refuses_card_with_more_than_one_item() {
  local home sub id out rc
  home="$TMP_ROOT/handoff-multi-main"
  sub="$TMP_ROOT/handoff-multi-sub"
  id=handoff-multi-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-m1 - first (repo: alpha)
- [ ] handoff-item-m2 - second (repo: alpha)

## Done
EOF

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-m1 handoff-item-m2 --card some-card 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a multi-item --card handoff should be refused" "$out"
  assert_contains "$out" "--card applies only to a single-item handoff" "the refusal did not name the single-item rule"
  assert_grep 'handoff-item-m1' "$home/data/backlog.md" "the refused handoff moved handoff-item-m1 anyway"
  assert_grep 'handoff-item-m2' "$home/data/backlog.md" "the refused handoff moved handoff-item-m2 anyway"
  pass "handoff refuses --card with more than one item and moves nothing"
}

# Regression: the pending record and the superseded ledger are one
# tab-delimited "<item-key>\t<card-id>" line per pair, and --card was checked
# only for being non-empty. A tab in the value split the pair at the wrong place; a newline
# forged a whole second line with no tab at all, whose key and card then parse
# as the same string. Either bogus pair is guarded, so no arrival can ever
# confirm and retire it - it re-warns on every later handoff and every resume
# sweep, clearable only by hand-editing state, which is exactly the corner the
# record's "reversible from the CLI alone" rule exists to keep the operator out
# of. Refuse the value up front instead, before anything moves.
test_handoff_refuses_a_card_id_that_would_corrupt_the_pending_record() {
  local home sub id out rc record
  home="$TMP_ROOT/handoff-cardsep-main"
  sub="$TMP_ROOT/handoff-cardsep-sub"
  id=handoff-cardsep-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-s1 - named with a separator-bearing card (repo: alpha)
- [ ] handoff-item-s2 - named with a newline-bearing card (repo: alpha)

## Done
EOF
  record="$home/state/handoff-cards/$id"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-s1 --card "$(printf 't-abc\tx')" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a --card value carrying a tab should be refused" "$out"
  assert_contains "$out" "must not contain a tab or newline" "the refusal did not name the reason"
  assert_grep 'handoff-item-s1' "$home/data/backlog.md" "the refused handoff moved the item anyway"
  [ ! -e "$sub/data/backlog.md" ] \
    || assert_no_grep 'handoff-item-s1' "$sub/data/backlog.md" "the refused handoff landed the item at the secondmate"
  [ ! -e "$record" ] || fail "a refused --card still wrote a pending card record"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-s2 --card "$(printf 't-abc\nt-def')" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a --card value carrying a newline should be refused" "$out"
  assert_contains "$out" "must not contain a tab or newline" "the refusal did not name the reason"
  assert_grep 'handoff-item-s2' "$home/data/backlog.md" "the refused handoff moved the item anyway"
  [ ! -e "$record" ] || fail "a refused --card still wrote a pending card record"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-s1 --card t-abc 2>&1)
  expect_code 0 "$?" "an ordinary card id should still be accepted" "$out"
  [ "$(wc -l < "$record")" -eq 1 ] \
    || fail "the record should hold exactly one pair line for one accepted --card"
  pass "a --card id that would corrupt the tab-delimited pending record is refused before anything moves"
}

# Regression: a handoff is documented as idempotent, so the same command is
# expected to be re-run. By then the secondmate may already have spawned
# against the card, replacing the coarse handoff identity with a precise
# per-task one - re-running must not reset the board to the stale identity.
test_handoff_already_present_never_overwrites_an_existing_card_link() {
  local home sub id card out
  home="$TMP_ROOT/handoff-relink-main"
  sub="$TMP_ROOT/handoff-relink-sub"
  id=handoff-relink-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued

## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a4 - already landed here (repo: alpha)

## Done
EOF
  card=$(add_card "Already-linked coverage")
  # Exactly what the secondmate's own fm-spawn.sh --card writes once it picks
  # the item up: a precise <home>:<task-id> ref and the task id as agent.
  "$DASH" ref "$card" "sm-home:task-99" >/dev/null || fail "setup: could not set the card ref"
  "$DASH" agent "$card" task-99 >/dev/null || fail "setup: could not set the card agent"
  "$DASH" status "$card" working >/dev/null || fail "setup: could not move the card to working"

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a4 --card "$card" 2>&1)
  expect_code 0 "$?" "re-running an already-landed handoff should still succeed" "$out"
  assert_contains "$out" "nothing to move" "the re-run did not report the idempotent no-op"
  assert_contains "$out" "already links to sm-home:task-99" "the re-run did not report leaving the existing link alone"
  assert_not_contains "$out" "dashboard: linked card" "the re-run claimed it linked a card that was already linked"

  [ "$(card_field "$card" backlog_ref)" = "sm-home:task-99" ] \
    || fail "a handoff re-run overwrote a newer, more precise card ref"
  [ "$(card_field "$card" agent)" = task-99 ] \
    || fail "a handoff re-run overwrote a newer, more precise card agent"
  pass "a handoff re-run never overwrites a card link something more precise already claimed"
}

# The common case three earlier rounds never covered: every other fixture hands
# off into an EMPTY destination queue. A non-empty one is what an established
# secondmate always has, and it is the shape in which a body-rewriting card
# store silently failed - so assert the board end state, not just the absence
# of a warning.
test_handoff_into_a_non_empty_destination_queue_links_the_card() {
  local home sub id card out
  home="$TMP_ROOT/handoff-nonempty-main"
  sub="$TMP_ROOT/handoff-nonempty-sub"
  id=handoff-nonempty-sm
  setup_handoff_homes "$home" "$sub" "$id"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] handoff-item-a5 - the new work (repo: alpha)
  intent: keep this body line

## Done
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sub-item-already - work this secondmate already owns (repo: alpha)

## Done
EOF
  card=$(add_card "Non-empty destination coverage")

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a5 --card "$card" 2>&1)
  expect_code 0 "$?" "handoff into a non-empty destination queue should succeed" "$out"
  assert_not_contains "$out" "warning:" "handoff warned on an operation that succeeded"
  assert_grep 'sub-item-already' "$sub/data/backlog.md" "the handoff disturbed the item already queued there"
  assert_grep "intent: keep this body line" "$sub/data/backlog.md" "the handed-off item lost its body"

  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-a5" ] \
    || fail "the card was not linked when the destination queue already held an item"
  [ "$(card_field "$card" agent)" = "$id" ] || fail "the card agent was not set"
  [ "$(card_status "$card")" = working ] || fail "the not_started card did not advance to working"
  pass "a handoff into a non-empty destination queue links its card like any other"
}

# The handed-off item is backlog content this script does not own, so --card
# must leave it byte-identical: the card pairing lives in the handing-off
# home's own state, never in the item. A body carrying whitespace-only lines
# and a tab-indented continuation is the shape a read-modify-write store
# truncated, so it is the shape worth pinning.
test_handoff_card_leaves_the_item_body_byte_identical() {
  local home sub id card out before after
  home="$TMP_ROOT/handoff-bodykeep-main"
  sub="$TMP_ROOT/handoff-bodykeep-sub"
  id=handoff-bodykeep-sm
  setup_handoff_homes "$home" "$sub" "$id"
  printf '## Queued\n\n## Done\n' > "$home/data/backlog.md"
  {
    printf '## Queued\n'
    printf -- '- [ ] handoff-item-a6 - already landed, awkward body (repo: alpha)\n'
    printf '  intent: first body line\n'
    printf ' \n'
    printf '  more: important detail\n'
    printf '\tnote: tab indented detail\n'
    printf '  owner: someone\n'
    printf '\n## Done\n'
  } > "$sub/data/backlog.md"
  before=$(cat "$sub/data/backlog.md")
  card=$(add_card "Untouched body coverage")

  out=$(FM_HOME="$home" "$HANDOFF" "$id" handoff-item-a6 --card "$card" 2>&1)
  expect_code 0 "$?" "an already-present handoff should still succeed" "$out"
  assert_contains "$out" "nothing to move" "the re-run did not report the idempotent no-op"
  assert_not_contains "$out" "warning:" "--card warned on an item it had no business rewriting in the first place"
  after=$(cat "$sub/data/backlog.md")
  [ "$before" = "$after" ] || {
    printf 'before:\n%s\nafter:\n%s\n' "$before" "$after" >&2
    fail "--card rewrote the handed-off item instead of recording the pairing in this home's own state"
  }

  [ "$(card_field "$card" backlog_ref)" = "$id:handoff-item-a6" ] \
    || fail "the card was not linked"
  pass "--card records the pairing without rewriting a single byte of the handed-off item"
}

# --- remote-route handoff coverage ------------------------------------------
# A remote handoff stages the item into data/handoff/<id>.outbox.md, records
# the card pairing in this home's own state, and links the card only once
# delivery is confirmed. A crash in between leaves that record as the sole
# statement of which card to link, which is what --resume-pending reads back.
# Both paths run through the same fake-ssh + real remote entrypoint shape
# tests/fm-remote-backlog-handoff.test.sh uses.

REMOTE_SM='remote-card-sm'
REMOTE_PARENT="$TMP_ROOT/remote-parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_SM_HOME="$TMP_ROOT/remote-home"
REMOTE_FAKEBIN=

setup_remote_route() {
  mkdir -p "$REMOTE_PARENT/data" "$REMOTE_PARENT/state" "$REMOTE_ROOT/bin" \
    "$REMOTE_SM_HOME/data" "$REMOTE_SM_HOME/state" "$REMOTE_SM_HOME/config" "$REMOTE_SM_HOME/bin"
  REMOTE_FAKEBIN=$(fm_fakebin "$TMP_ROOT/remote-fake")
  printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
  cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
    "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-file.sh" \
    "$ROOT/bin/fm-backlog-receive.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$REMOTE_ROOT/bin/"
  ln -s "$(command -v tasks-axi)" "$REMOTE_ROOT/bin/tasks-axi"
  ln -s "$(command -v node)" "$REMOTE_ROOT/bin/node"
  chmod +x "$REMOTE_ROOT/bin"/*.sh
  git -C "$REMOTE_ROOT" init -q -b main
  git -C "$REMOTE_ROOT" add AGENTS.md bin
  git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'
  printf 'fixture\n' > "$REMOTE_SM_HOME/AGENTS.md"
  printf '%s\n' "$REMOTE_SM" > "$REMOTE_SM_HOME/.fm-secondmate-home"
  printf -- '- %s - remote delivery (host: remote-mac; root: %s; home: %s; scope: remote work; projects: alpha; added 2026-08-02)\n' \
    "$REMOTE_SM" "$REMOTE_ROOT" "$REMOTE_SM_HOME" > "$REMOTE_PARENT/data/secondmates.md"
  cat > "$REMOTE_FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
[ "${FM_FAKE_SSH_MODE:-normal}" != unreachable ] || exit 255
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
  chmod +x "$REMOTE_FAKEBIN/fake-ssh"
}

write_remote_parent_backlog() {  # <queued-line>
  cat > "$REMOTE_PARENT/data/backlog.md" <<EOF
## In flight

## Queued
$1

## Done
EOF
}

run_remote_handoff() {  # <handoff args...>
  FM_HOME="$REMOTE_PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_SSH_BIN="$REMOTE_FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
    "$HANDOFF" "$@" 2>&1
}

test_remote_handoff_links_card_only_after_confirmed_delivery() {
  local card out
  card=$(add_card "Remote handoff coverage")
  write_remote_parent_backlog '- [ ] remote-item-r1 - remote card work (repo: alpha)'

  out=$(run_remote_handoff "$REMOTE_SM" remote-item-r1 --card "$card")
  expect_code 0 "$?" "remote handoff with --card should succeed" "$out"
  assert_contains "$out" "handed off 1 item(s) to remote secondmate $REMOTE_SM" "remote handoff did not report success"
  assert_contains "$out" "dashboard: linked card $card" "remote handoff did not report the dashboard link firing"
  assert_absent "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "confirmed remote delivery left a pending outbox"
  assert_grep 'remote-item-r1' "$REMOTE_SM_HOME/data/backlog.md" "remote delivery lost the item"
  assert_absent "$REMOTE_PARENT/state/handoff-cards/$REMOTE_SM" \
    "confirmed delivery left the card record behind instead of consuming it"

  [ "$(card_field "$card" backlog_ref)" = "$REMOTE_SM:remote-item-r1" ] \
    || fail "remote card ref was not set to $REMOTE_SM:remote-item-r1"
  [ "$(card_field "$card" agent)" = "$REMOTE_SM" ] || fail "remote card agent was not set to the secondmate id"
  [ "$(card_status "$card")" = working ] || fail "not_started card did not advance to working after confirmed remote delivery"
  pass "a remote handoff links the card once delivery is confirmed, carrying the card id through the outbox"
}

test_resume_pending_links_the_card_recorded_in_the_staged_outbox() {
  local card out rc outbox
  card=$(add_card "Remote resume coverage")
  outbox="$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md"
  write_remote_parent_backlog '- [ ] remote-item-r2 - survives an unreachable secondmate (repo: alpha)'

  out=$(FM_FAKE_SSH_MODE=unreachable run_remote_handoff "$REMOTE_SM" remote-item-r2 --card "$card") && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "handoff to an unreachable remote claimed success"
  assert_present "$outbox" "the unreachable handoff lost its durable outbox"
  assert_grep "$card" "$REMOTE_PARENT/state/handoff-cards/$REMOTE_SM" \
    "staging did not record which card to link on recovery"
  [ -z "$(card_field "$card" backlog_ref)" ] || fail "the card was linked before delivery was ever confirmed"
  [ "$(card_status "$card")" = not_started ] || fail "the card advanced before delivery was ever confirmed"

  # --resume-pending takes no keys and no --card: the record staging wrote is
  # the only surviving statement of which card this delivery serves.
  out=$(run_remote_handoff --resume-pending)
  expect_code 0 "$?" "resuming the pending outbox should succeed" "$out"
  assert_absent "$outbox" "confirmed resume did not clean the local outbox"
  assert_grep 'remote-item-r2' "$REMOTE_SM_HOME/data/backlog.md" "resume did not deliver the item"

  [ "$(card_field "$card" backlog_ref)" = "$REMOTE_SM:remote-item-r2" ] \
    || fail "resume did not link the card the staging record named"
  [ "$(card_field "$card" agent)" = "$REMOTE_SM" ] || fail "resume did not set the card agent"
  [ "$(card_status "$card")" = working ] || fail "resume did not advance the not_started card to working"
  pass "a crash-recovered delivery links its card from the staging record alone, with no --card on the command line"
}

# stage_unreachable_card_item <key> <card-id> - leave one staged-but-unlinked
# item in the pending outbox by handing it off to an unreachable remote, the
# state a failed delivery genuinely leaves behind.
stage_unreachable_card_item() {
  local key=$1 card=$2 rc
  write_remote_parent_backlog "- [ ] $key - staged before the remote came back (repo: alpha)"
  FM_FAKE_SSH_MODE=unreachable run_remote_handoff "$REMOTE_SM" "$key" --card "$card" >/dev/null && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "handoff to an unreachable remote claimed success"
  assert_present "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "the unreachable handoff lost its outbox"
}

# The remote twin of the non-empty-destination case: staging into an outbox
# that already holds an item is the shape a body-rewriting card store failed
# in, and a card lost there can never be recovered once delivery deletes the
# outbox.
test_remote_handoff_into_a_non_empty_outbox_links_both_cards() {
  local first second out
  first=$(add_card "Non-empty outbox first")
  second=$(add_card "Non-empty outbox second")
  stage_unreachable_card_item remote-item-r7 "$first"

  write_remote_parent_backlog '- [ ] remote-item-r8 - staged beside an item already in the outbox (repo: alpha)'
  out=$(FM_FAKE_SSH_MODE=unreachable run_remote_handoff "$REMOTE_SM" remote-item-r8 --card "$second") || true
  assert_grep 'remote-item-r7' "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "the outbox lost its first item"
  assert_grep 'remote-item-r8' "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "the second item was not staged"

  out=$(run_remote_handoff --resume-pending)
  expect_code 0 "$?" "resuming the two-item outbox should succeed" "$out"
  assert_grep 'remote-item-r7' "$REMOTE_SM_HOME/data/backlog.md" "the first item was not delivered"
  assert_grep 'remote-item-r8' "$REMOTE_SM_HOME/data/backlog.md" "the second item was not delivered"

  [ "$(card_field "$first" backlog_ref)" = "$REMOTE_SM:remote-item-r7" ] \
    || fail "the card staged first was not linked"
  [ "$(card_field "$second" backlog_ref)" = "$REMOTE_SM:remote-item-r8" ] \
    || fail "the card staged into an already-occupied outbox was not linked"
  [ "$(card_status "$first")" = working ] || fail "the first card never advanced to working"
  [ "$(card_status "$second")" = working ] || fail "the second card never advanced to working"
  pass "staging into an outbox that already holds an item records and links both cards"
}

# Regression: an outbox is transferred and deleted as a WHOLE, so a later
# handoff lands every item an earlier failed run left staged. Linking only the
# key this command line named orphans those cards permanently - the deleted
# outbox was the only record of them - which is the freeze-at-not-started bug
# this whole mechanism exists to prevent.
test_remote_handoff_links_every_card_its_delivery_lands() {
  local stranded fresh out
  stranded=$(add_card "Stranded co-staged coverage")
  fresh=$(add_card "Fresh remote coverage")
  stage_unreachable_card_item remote-item-r3 "$stranded"

  write_remote_parent_backlog '- [ ] remote-item-r4 - handed off once the remote is back (repo: alpha)'
  out=$(run_remote_handoff "$REMOTE_SM" remote-item-r4 --card "$fresh")
  expect_code 0 "$?" "the later handoff should succeed" "$out"
  assert_absent "$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md" "confirmed delivery left a pending outbox"
  assert_grep 'remote-item-r3' "$REMOTE_SM_HOME/data/backlog.md" "the co-staged item was not delivered"
  assert_grep 'remote-item-r4' "$REMOTE_SM_HOME/data/backlog.md" "the newly staged item was not delivered"

  [ "$(card_field "$fresh" backlog_ref)" = "$REMOTE_SM:remote-item-r4" ] \
    || fail "the card this run named was not linked"
  [ "$(card_field "$stranded" backlog_ref)" = "$REMOTE_SM:remote-item-r3" ] \
    || fail "a co-staged card the same delivery landed was left orphaned at not_started"
  [ "$(card_field "$stranded" agent)" = "$REMOTE_SM" ] || fail "the co-staged card's agent was not set"
  [ "$(card_status "$stranded")" = working ] || fail "the co-staged card never advanced to working"
  pass "a remote handoff links every card its delivery landed, not only the one it was asked about"
}

# A pending outbox holds back only what it actually still carries. Arrival is
# a property of one item, never of the secondmate: a delivery that landed long
# ago and could not be linked is owed its link now, even while a LATER delivery
# to the same secondmate is still stuck behind an unreachable host. Skipping
# the whole record whenever any outbox exists freezes that earlier card for as
# long as the remote stays down, with no command left to complete it.
test_resume_pending_links_a_landed_pair_while_a_later_delivery_is_still_stuck() {
  local landed staged out rc record outbox
  landed=$(add_card "Landed-while-stuck coverage")
  staged=$(add_card "Still-staged coverage")
  record="$REMOTE_PARENT/state/handoff-cards/$REMOTE_SM"
  outbox="$REMOTE_PARENT/data/handoff/$REMOTE_SM.outbox.md"

  # Delivered, but the board was down, so the pair stays owed with no outbox
  # left to find it by.
  write_remote_parent_backlog '- [ ] remote-item-r7 - lands while the board is down (repo: alpha)'
  out=$(FM_DASHBOARD_PORT=1 run_remote_handoff "$REMOTE_SM" remote-item-r7 --card "$landed")
  expect_code 0 "$?" "the delivery itself should succeed with only the board down" "$out"
  assert_grep 'remote-item-r7' "$REMOTE_SM_HOME/data/backlog.md" "the item was not delivered"
  assert_absent "$outbox" "a confirmed delivery left a pending outbox"
  assert_grep "$(printf 'remote-item-r7\t%s' "$landed")" "$record" "the failed link was not kept for retry"

  # A later handoff to the same secondmate stages an outbox the unreachable
  # host never takes, so the record now holds one landed pair and one staged.
  stage_unreachable_card_item remote-item-r8 "$staged"
  assert_grep "$(printf 'remote-item-r8\t%s' "$staged")" "$record" "the staged pair was not recorded"

  # Board back, remote still down.
  out=$(FM_FAKE_SSH_MODE=unreachable run_remote_handoff --resume-pending) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "--resume-pending claimed success while the outbox delivery was still failing"
  assert_present "$outbox" "the still-undelivered outbox was cleaned up"

  [ "$(card_field "$landed" backlog_ref)" = "$REMOTE_SM:remote-item-r7" ] \
    || fail "the pair whose item landed long ago was not linked while a later delivery was stuck"
  [ "$(card_status "$landed")" = working ] || fail "the landed pair's card did not advance to working"
  assert_no_grep "$(printf 'remote-item-r7\t%s' "$landed")" "$record" \
    "the confirmed pair was not retired from the record"

  [ -z "$(card_field "$staged" backlog_ref)" ] \
    || fail "a pair still staged in an undelivered outbox was linked before it arrived anywhere"
  [ "$(card_status "$staged")" = not_started ] \
    || fail "a pair still staged in an undelivered outbox advanced its card before arrival"
  assert_grep "$(printf 'remote-item-r8\t%s' "$staged")" "$record" \
    "the still-staged pair was dropped from the record"
  pass "--resume-pending links a pair whose delivery landed even while a later delivery to the same secondmate is stuck"
}

# The one repeat a single command really can produce. --resume-pending sweeps a
# delivered outbox's record in its outbox pass and then reads that same record
# again in its card-record pass - both deliberate, since either pass alone has
# to be able to finish a link the other never reaches. A pair the host says it
# does not have is owed its stderr report once per command, not once per pass:
# two identical warnings out of one invocation is exactly the noise the bound
# exists to prevent, and it is the only repeat left now that the report is
# remembered in memory for the life of the process rather than on disk. It
# never reaches the fleet audit log at all, on any pass - bootstrap's own
# unattended sweep on every boot is exactly why.
test_resume_pending_reports_an_unlinkable_pair_once_per_command_not_once_per_sweep() {
  local card out findings record
  card=does-not-exist-resume-zzzz
  record="$REMOTE_PARENT/state/handoff-cards/$REMOTE_SM"
  stage_unreachable_card_item remote-item-r9 "$card"

  out=$(run_remote_handoff --resume-pending)
  expect_code 0 "$?" "resuming the pending outbox should succeed" "$out"
  assert_grep 'remote-item-r9' "$REMOTE_SM_HOME/data/backlog.md" "resume did not deliver the item"
  assert_contains "$out" "has no card $card" "the resume never reported the unlinkable pair at all"
  [ "$(grep -c "has no card $card" <<<"$out")" -eq 1 ] \
    || fail "one command reported the same unlinkable pair on each of its two sweeps"
  findings=$("$DASH" audit-status --json | jq --arg c "$card" '[.log[] | select(.text | contains($c))] | length')
  [ "$findings" = 0 ] \
    || fail "an unlinkable pair must never reach the fleet audit log, got $findings finding(s)"
  assert_grep "$(printf 'remote-item-r9\t%s' "$card")" "$record" \
    "the unlinkable pair was dropped instead of staying recorded and retriable"
  pass "one command reports an unlinkable pair once on stderr, even though --resume-pending sweeps its record twice, and never on the fleet audit log"
}

# Regression: the unreadable-card warning was the one report of the three that
# never routed through the in-memory gate, and it is the one the double sweep
# actually duplicates. A delivery that lands while the board is down warns once
# in --resume-pending's outbox pass, then again in its card-record pass, which
# re-reads the very same record now that the outbox is gone - two identical
# warnings for one pair out of one command.
test_resume_pending_reports_an_unreadable_card_once_per_command_not_once_per_sweep() {
  local card out record
  card=$(add_card "Unreadable sweep coverage")
  [ -n "$card" ] || fail "add_card returned no id"
  record="$REMOTE_PARENT/state/handoff-cards/$REMOTE_SM"
  stage_unreachable_card_item remote-item-r10 "$card"

  out=$(FM_DASHBOARD_PORT=1 run_remote_handoff --resume-pending)
  expect_code 0 "$?" "resuming should succeed even with the board unreachable" "$out"
  assert_grep 'remote-item-r10' "$REMOTE_SM_HOME/data/backlog.md" "resume did not deliver the item"
  assert_contains "$out" "could not read dashboard card $card" \
    "the resume never reported that the card could not be read"
  [ "$(grep -c "could not read dashboard card $card" <<<"$out")" -eq 1 ] \
    || fail "one command warned about the same unreadable card on each of its two sweeps"
  [ "$(card_status "$card")" = not_started ] \
    || fail "a card that could never be read was written to anyway"
  assert_grep "$(printf 'remote-item-r10\t%s' "$card")" "$record" \
    "the unreadable pair was dropped instead of staying recorded and retriable"
  pass "one command warns about an unreadable card once, even though --resume-pending sweeps its record twice"
}

# The same boundary reached with no --card at all: the run stages nothing on
# the board of its own, it only completes a link an earlier --card call staged
# and would otherwise destroy by deleting the delivered outbox.
test_card_less_remote_handoff_completes_a_link_its_delivery_lands() {
  local stranded out
  stranded=$(add_card "Card-less flush coverage")
  stage_unreachable_card_item remote-item-r5 "$stranded"

  write_remote_parent_backlog '- [ ] remote-item-r6 - ordinary card-less handoff (repo: alpha)'
  out=$(run_remote_handoff "$REMOTE_SM" remote-item-r6)
  expect_code 0 "$?" "the card-less handoff should succeed" "$out"
  assert_grep 'remote-item-r5' "$REMOTE_SM_HOME/data/backlog.md" "the co-staged item was not delivered"
  assert_grep 'remote-item-r6' "$REMOTE_SM_HOME/data/backlog.md" "the card-less item was not delivered"

  [ "$(card_field "$stranded" backlog_ref)" = "$REMOTE_SM:remote-item-r5" ] \
    || fail "a card-less handoff dropped the link its own delivery made recoverable-never-again"
  [ "$(card_status "$stranded")" = working ] || fail "the co-staged card never advanced to working"
  pass "a card-less remote handoff still completes a link an earlier --card call staged"
}

test_lib_link_self_reads_status_and_advances_not_started
test_lib_link_known_status_skips_its_own_read
test_lib_link_already_past_not_started_reports_without_advancing
test_lib_link_empty_known_status_is_a_failure_with_no_advance_attempt
test_lib_link_ref_failure_still_attempts_agent_and_skips_status
test_lib_link_agent_failure_is_reported
test_lib_link_status_advance_failure_is_reported
test_lib_advance_after_landing_skips_a_complete_card
test_lib_advance_after_landing_advances_an_ordinary_status_with_no_reason
test_lib_advance_after_landing_carries_needs_attention_reason_forward
test_lib_advance_after_landing_carries_waiting_reason_forward
test_lib_advance_after_landing_show_failure_warns_and_audit_logs
test_lib_advance_after_landing_status_failure_warns_and_audit_logs
test_spawn_links_card_and_advances_not_started_to_working
test_spawn_without_card_flag_never_touches_the_dashboard
test_spawn_with_unreachable_dashboard_still_succeeds_and_warns
test_spawn_with_unknown_card_id_warns_and_records_a_fleet_finding
test_spawn_never_confirms_a_link_whose_card_state_it_could_not_read
test_teardown_advances_linked_card_to_review_on_landed_work
test_teardown_with_unreachable_dashboard_still_succeeds_and_warns
test_teardown_without_dashboard_card_meta_is_a_noop
test_teardown_force_discard_never_advances_the_card
test_teardown_never_downgrades_an_already_complete_card
test_teardown_preserves_needs_attention_reason_in_history_on_landing
test_teardown_preserves_waiting_reason_in_history_on_landing
# Only the handoff cases move backlog items, which bin/fm-backlog-handoff.sh
# delegates to tasks-axi; the spawn/teardown cases above need none of it, so
# they keep running on a machine without it.
if command -v tasks-axi >/dev/null 2>&1; then
  test_handoff_links_card_and_advances_not_started_to_working
  test_handoff_without_card_flag_never_touches_the_dashboard
  test_handoff_with_unreachable_dashboard_still_succeeds_and_warns
  test_handoff_card_record_survives_a_failed_link_and_completes_on_the_next_handoff
  test_resume_pending_never_writes_the_fleet_audit_log_for_a_transport_failure
  test_operator_handoff_writes_the_fleet_audit_log_once_per_invocation_for_two_transport_failures
  test_handoff_record_without_a_trailing_newline_loses_no_pair
  test_resume_pending_completes_a_stranded_local_card_link
  test_session_start_completes_a_stranded_local_card_link
  test_handoff_finishes_its_own_half_written_card_link
  test_handoff_keeps_and_retries_a_pair_the_host_says_names_no_such_card
  test_handoff_never_confirms_a_link_whose_card_state_it_could_not_read
  test_handoff_never_writes_a_guarded_card_it_could_not_read
  test_handoff_supersedes_rather_than_also_linking_a_corrected_card
  test_superseded_mark_survives_an_append_onto_an_unterminated_ledger
  test_renaming_a_superseded_card_makes_it_linkable_again
  test_one_command_reports_every_distinct_unlinkable_pair_not_just_the_first
  test_handoff_record_bookkeeping_failure_never_fails_the_handoff
  test_handoff_refuses_card_with_more_than_one_item
  test_handoff_refuses_a_card_id_that_would_corrupt_the_pending_record
  test_handoff_already_present_never_overwrites_an_existing_card_link
  test_handoff_into_a_non_empty_destination_queue_links_the_card
  test_handoff_card_leaves_the_item_body_byte_identical
else
  pass "skipped handoff card-link coverage - tasks-axi not available for the backlog move"
fi
if command -v tasks-axi >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  setup_remote_route
  test_remote_handoff_links_card_only_after_confirmed_delivery
  test_resume_pending_links_the_card_recorded_in_the_staged_outbox
  test_remote_handoff_into_a_non_empty_outbox_links_both_cards
  test_remote_handoff_links_every_card_its_delivery_lands
  test_card_less_remote_handoff_completes_a_link_its_delivery_lands
  test_resume_pending_links_a_landed_pair_while_a_later_delivery_is_still_stuck
  test_resume_pending_reports_an_unlinkable_pair_once_per_command_not_once_per_sweep
  test_resume_pending_reports_an_unreadable_card_once_per_command_not_once_per_sweep
else
  pass "skipped remote-route card coverage - tasks-axi or node not available for the remote fixture"
fi

echo "# all fm-dashboard-card-link tests passed"
