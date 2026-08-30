#!/usr/bin/env bash
# Behavior tests for the River adapter of the process-to-event runner.
#
# The service under test is a local fake HTTP service with the same wire shape
# the adapter polls (GET /next?wait=N, 200 with one item, 204 when empty, 401
# without the bearer credential). The real River service is never contacted, and
# nothing here asserts implementation source bytes: every claim is made through
# the adapter's own commands and its observable process and output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-river-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# Pin the runner and its adapter lookup to the checkout under test, so an
# operator's ambient home settings cannot make this suite exercise another tree.
export FM_ROOT_OVERRIDE="$ROOT"

ADAPTER="$ROOT/bin/fm-procevent-river.sh"
TOKEN="river-test-token-$$-$RANDOM"
SERVER_PID=
ARMED_HOME=

river_teardown() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
  if [ -n "$ARMED_HOME" ]; then
    FM_HOME="$ARMED_HOME" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap river_teardown EXIT

# --- the fake River service -------------------------------------------------
#
# Items are supplied through a queue directory so a test can seed a burst before
# the poll starts. Each served request appends its Authorization header to a log,
# which is how the credential presentation is observed from the outside.
cat > "$TMP_ROOT/fake-river.py" <<'PY'
import os, sys, time, json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

QUEUE = sys.argv[1]
AUTHLOG = sys.argv[2]
# Read through a file, never argv: the process table is itself under test here.
EXPECTED = open(sys.argv[3]).read().strip()
LOCK = threading.Lock()

def take():
    with LOCK:
        names = sorted(os.listdir(QUEUE))
        if not names:
            return None
        path = os.path.join(QUEUE, names[0])
        with open(path) as fh:
            body = fh.read()
        os.remove(path)
        return body

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        with open(AUTHLOG, "a") as fh:
            fh.write((self.headers.get("Authorization") or "<none>") + "\n")
        if self.headers.get("Authorization") != "Bearer " + EXPECTED:
            self.send_response(401); self.end_headers(); return
        if url.path != "/next":
            self.send_response(404); self.end_headers(); return
        wait = float((parse_qs(url.query).get("wait") or ["0"])[0])
        deadline = time.time() + wait
        while True:
            body = take()
            if body is not None:
                raw = body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            if time.time() >= deadline:
                self.send_response(204); self.end_headers(); return
            time.sleep(0.05)

srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

QUEUE="$TMP_ROOT/queue"
AUTHLOG="$TMP_ROOT/auth.log"
mkdir -p "$QUEUE"
: > "$AUTHLOG"

printf '%s\n' "$TOKEN" > "$TMP_ROOT/expected-token"
python3 "$TMP_ROOT/fake-river.py" "$QUEUE" "$AUTHLOG" "$TMP_ROOT/expected-token" > "$TMP_ROOT/port" 2>"$TMP_ROOT/server.err" &
SERVER_PID=$!
PORT=
for _ in $(seq 1 100); do
  PORT=$(head -1 "$TMP_ROOT/port" 2>/dev/null || true)
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || fail "the fake River service did not start"
BASE="http://127.0.0.1:$PORT"

queue_item() { printf '%s\n' "$1" > "$QUEUE/$(date +%s%N)-$RANDOM.json"; }

new_home() {  # <dir> [base-url]
  local home=$1 base=${2-$BASE}
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$base" > "$home/config/river-service"
  printf '%s\n' "$TOKEN" > "$home/config/river-token"
}

river() {  # <home> <args>...
  local home=$1; shift
  FM_HOME="$home" "$ADAPTER" "$@"
}

# --- burst batching ---------------------------------------------------------
HOME_A="$TMP_ROOT/home-a"
new_home "$HOME_A"
queue_item '{"phrase":"one"}'
queue_item '{"phrase":"two"}'
queue_item '{"phrase":"three"}'
OUT="$TMP_ROOT/burst.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 "$ADAPTER" poll > "$OUT"
expect_code 0 "$?" "a poll with queued takeovers"
python3 - "$OUT" <<'PY' || fail "the burst was not emitted as one JSON array of all three items"
import json, sys
data = json.load(open(sys.argv[1]))
assert isinstance(data, list), data
assert [d["phrase"] for d in data] == ["one", "two", "three"], data
PY
[ "$(wc -l < "$OUT")" -eq 1 ] || fail "the batched result was not a single emitted document"
pass "a burst of three queued takeovers becomes ONE captured result, not three"

# --- the credential is presented, and never observable ----------------------
assert_grep "Bearer $TOKEN" "$AUTHLOG" "the adapter did not present the bearer credential"
pass "the poll authenticates with the home's configured bearer token"

CLASSIFIED=$(river "$HOME_A" classify "$OUT")
[ "$CLASSIFIED" = takeovers ] || fail "a non-empty item array classified as '$CLASSIFIED'"
pass "a non-empty item array classifies as takeovers"

# --- 204 re-poll ------------------------------------------------------------
# Nothing is queued, so the first request times out with 204; the adapter must
# poll again rather than exit, and return the item that arrives afterwards.
: > "$AUTHLOG"
OUT2="$TMP_ROOT/repoll.json"
( sleep 1.5; queue_item '{"phrase":"late"}' ) &
LATE=$!
FM_HOME="$HOME_A" FM_RIVER_WAIT=1 "$ADAPTER" poll > "$OUT2"
expect_code 0 "$?" "a poll that had to wait through an empty window"
wait "$LATE" 2>/dev/null || true
assert_grep '"late"' "$OUT2" "the adapter did not return the item that arrived after an empty window"
[ "$(wc -l < "$AUTHLOG")" -ge 2 ] || fail "the adapter did not re-poll after a 204 timeout"
pass "an empty long-poll window re-polls instead of ending the source"

# --- the token never reaches argv or the registered registration ------------
HOME_B="$TMP_ROOT/home-b"
new_home "$HOME_B"
ARMED_HOME=$HOME_B
ARM_OUT=$(river "$HOME_B" arm 2>&1) || fail "arm failed on a configured home: $ARM_OUT"
assert_contains "$ARM_OUT" "armed: river-takeover-stream" "arm did not report the canonical source"
assert_not_contains "$ARM_OUT" "$TOKEN" "arm printed the bearer token"
[ "$(river "$HOME_B" source-id)" = river-takeover-stream ] || fail "the canonical source id changed"

SOURCE_FILE=$(find "$HOME_B/state" -name 'river-takeover-stream.source' | head -1)
[ -n "$SOURCE_FILE" ] || fail "arm did not register the source with the runner"
assert_grep "$ADAPTER" "$SOURCE_FILE" "the registered argv does not run this adapter's poll"
assert_grep "poll" "$SOURCE_FILE" "the registered argv does not run the poll command"
assert_no_grep "$TOKEN" "$SOURCE_FILE" "the bearer token was written into the registered argv"

# A live poll must not expose the token in its own or any child's argv.
FM_HOME="$HOME_B" FM_RIVER_WAIT=8 "$ADAPTER" poll > "$TMP_ROOT/live.json" 2>/dev/null &
POLL_PID=$!
PS_SEEN=
for _ in $(seq 1 40); do
  PS_SEEN=$(ps -eo args 2>/dev/null || true)
  case "$PS_SEEN" in *"/next?wait="*) break ;; esac
  sleep 0.1
done
case "$PS_SEEN" in
  *"/next?wait="*) : ;;
  *) fail "the live poll's request was never observable in the process table" ;;
esac
case "$PS_SEEN" in
  *"$TOKEN"*) fail "the bearer token is observable in the process table" ;;
esac
kill "$POLL_PID" 2>/dev/null || true
pkill -P "$POLL_PID" 2>/dev/null || true
wait "$POLL_PID" 2>/dev/null || true
pass "the bearer token appears in neither the registered argv nor any live process argument"

# --- end to end through the real runner -------------------------------------
# One captured takeover must leave the source ARMED, because this channel is
# continuous: the runner asks the adapter whether the result ends the source, and
# the answer is always no.
queue_item '{"phrase":"end-to-end"}'
FM_HOME="$HOME_B" FM_RIVER_WAIT=5 "$ROOT/bin/fm-procevent.sh" start river-takeover-stream >/dev/null   || fail "the runner could not run the river source to completion"
RESULT=$(find "$HOME_B/state/procevent-inbox" -name 'river-takeover-stream.*.result' | head -1)
[ -n "$RESULT" ] || fail "the runner captured no durable result for the river source"
assert_grep '"end-to-end"' "$RESULT" "the captured result does not carry the takeover"
assert_grep 'procevent river river-takeover-stream' "$HOME_B/state/.wake-queue"   "a captured takeover did not publish a wake"
assert_present "$SOURCE_FILE" "the runner retired a continuous source after one result"
[ "$(river "$HOME_B" classify "$RESULT")" = takeovers ]   || fail "the durable result did not classify as takeovers"
pass "a captured takeover wakes firstmate and leaves the standing source armed"

river "$HOME_B" retire >/dev/null || fail "retire did not delegate cleanly to the runner"
ARMED_HOME=
pass "arm registers the continuous source and retire drops it"

# --- arming fails closed without configuration ------------------------------
HOME_C="$TMP_ROOT/home-c"
mkdir -p "$HOME_C/state" "$HOME_C/config"
ARM_ERR=$(river "$HOME_C" arm 2>&1) && fail "arm succeeded on a home with no River configuration"
assert_contains "$ARM_ERR" "config/river-service" "arm did not name the missing service configuration"
printf '%s\n' "$BASE" > "$HOME_C/config/river-service"
ARM_ERR=$(river "$HOME_C" arm 2>&1) && fail "arm succeeded with no bearer token"
assert_contains "$ARM_ERR" "config/river-token" "arm did not name the missing credential"
pass "arming refuses a home whose River configuration is incomplete"

# --- a bounded unreachable window reports the outage as a result ------------
DEAD="$TMP_ROOT/home-dead"
new_home "$DEAD" "http://127.0.0.1:1"
ERR_OUT="$TMP_ROOT/outage.json"
FM_HOME="$DEAD" FM_RIVER_WAIT=1 FM_RIVER_UNREACHABLE_WINDOW=1 FM_RIVER_RETRY_BACKOFF=0 \
  "$ADAPTER" poll > "$ERR_OUT"
expect_code 0 "$?" "an unreachable service"
assert_grep '"error"' "$ERR_OUT" "an unreachable service produced no error result"
assert_grep 'service unreachable since' "$ERR_OUT" "the outage result did not report when the outage began"
CLASSIFIED=$(river "$DEAD" classify "$ERR_OUT")
[ "$CLASSIFIED" = service-error ] || fail "an outage result classified as '$CLASSIFIED'"
pass "a bounded unreachable window wakes firstmate loudly instead of sleeping through an outage"

# --- classify's third shape -------------------------------------------------
printf '[]\n' > "$TMP_ROOT/empty.json"
[ "$(river "$HOME_A" classify "$TMP_ROOT/empty.json")" = unknown ] \
  || fail "an empty array did not classify as unknown"
printf 'not json at all\n' > "$TMP_ROOT/junk.json"
[ "$(river "$HOME_A" classify "$TMP_ROOT/junk.json")" = unknown ] \
  || fail "an unreadable result did not classify as unknown"
pass "an empty batch and an unreadable result both classify as unknown"

# --- the source is continuous: nothing is ever terminal ---------------------
for shape in "$OUT" "$ERR_OUT" "$TMP_ROOT/empty.json" "$TMP_ROOT/junk.json"; do
  river "$HOME_A" terminal "$shape" && fail "a captured result was reported terminal: $shape"
done
river "$HOME_A" terminal /nonexistent-result && fail "a missing result was reported terminal"
pass "no result ever retires this source, so an acknowledged outage cannot silently end it"

help_out=$("$ADAPTER" --help 2>&1 || true)
assert_contains "$help_out" "ALWAYS exits non-zero" "the published help does not state the never-terminal contract"
assert_contains "$help_out" "config/river-service" "the published help does not name the per-home configuration"
pass "the published interface owns the adapter's mechanics"

printf '\nall procevent river tests passed\n'
