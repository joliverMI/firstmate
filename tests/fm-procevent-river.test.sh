#!/usr/bin/env bash
# Behavior tests for the River adapter of the process-to-event runner.
#
# The service under test is a local fake HTTP service with the same wire shape
# the adapter polls, including the part that makes this adapter's ordering
# load-bearing: GET /next?wait=N serves the OLDEST pending item and keeps serving
# that same item until POST /ack retires it by id. The real River service is
# never contacted, and nothing here asserts implementation source bytes: every
# claim is made through the adapter's own commands and its observable process,
# output, and request sequence.
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
# the poll starts, and the queue is ordered by file name. The head item is served
# repeatedly and removed only by an ack carrying its id, which is the real
# service's contract. Every served or acked request is appended to a request log,
# which is how the ack-before-next-read ordering is observed from the outside.
# Acks for ids listed in the ack-fail file are refused, which is how the
# at-least-once boundary is exercised without crashing a poll mid-flight.
cat > "$TMP_ROOT/fake-river.py" <<'PY'
import os, sys, time, json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

QUEUE = sys.argv[1]
AUTHLOG = sys.argv[2]
# Read through a file, never argv: the process table is itself under test here.
EXPECTED = open(sys.argv[3]).read().strip()
REQLOG = sys.argv[4]
ACKFAIL = sys.argv[5]
LOCK = threading.Lock()


def log(line):
    with open(REQLOG, "a") as fh:
        fh.write(line + "\n")


def head():
    """The oldest pending item, left in place: /next never retires anything."""
    with LOCK:
        names = sorted(os.listdir(QUEUE))
        if not names:
            return None
        with open(os.path.join(QUEUE, names[0])) as fh:
            return fh.read()


def retire(item_id):
    """Remove the pending item with this id. False if there is no such item."""
    with LOCK:
        for name in sorted(os.listdir(QUEUE)):
            path = os.path.join(QUEUE, name)
            try:
                with open(path) as fh:
                    if json.load(fh).get("id") == item_id:
                        os.remove(path)
                        return True
            except Exception:
                continue
        return False


def ack_refused(item_id):
    try:
        with open(ACKFAIL) as fh:
            return item_id in fh.read().split()
    except OSError:
        return False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def authed(self):
        with open(AUTHLOG, "a") as fh:
            fh.write((self.headers.get("Authorization") or "<none>") + "\n")
        if self.headers.get("Authorization") != "Bearer " + EXPECTED:
            self.send_response(401); self.end_headers()
            return False
        return True

    def reply(self, code, payload=None):
        raw = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        if raw:
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        if raw:
            self.wfile.write(raw)

    def do_GET(self):
        if not self.authed():
            return
        url = urlparse(self.path)
        if url.path != "/next":
            self.send_response(404); self.end_headers(); return
        wait = float((parse_qs(url.query).get("wait") or ["0"])[0])
        deadline = time.time() + wait
        while True:
            body = head()
            if body is not None:
                raw = body.encode()
                try:
                    served = json.loads(body).get("id")
                except Exception:
                    served = "<unparsed>"
                log("next %s" % served)
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            if time.time() >= deadline:
                log("next -")
                self.send_response(204); self.end_headers(); return
            time.sleep(0.05)

    def do_POST(self):
        if not self.authed():
            return
        if urlparse(self.path).path != "/ack":
            self.send_response(404); self.end_headers(); return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length).decode())
            item_id = payload["id"]
            if not isinstance(item_id, str):
                raise ValueError
        except Exception:
            self.reply(400, {"error": "id is required"}); return
        if ack_refused(item_id):
            log("ack %s refused" % item_id)
            self.reply(503, {"error": "ack refused"}); return
        # Idempotent by design: an unknown or already-retired id is a success
        # reporting retired=false, never a 404.
        retired = retire(item_id)
        log("ack %s %s" % (item_id, "retired" if retired else "repeat"))
        self.reply(200, {"id": item_id, "retired": retired})


srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

QUEUE="$TMP_ROOT/queue"
AUTHLOG="$TMP_ROOT/auth.log"
REQLOG="$TMP_ROOT/req.log"
ACKFAIL="$TMP_ROOT/ack-fail"
mkdir -p "$QUEUE"
: > "$AUTHLOG"
: > "$REQLOG"
: > "$ACKFAIL"

printf '%s\n' "$TOKEN" > "$TMP_ROOT/expected-token"
python3 "$TMP_ROOT/fake-river.py" "$QUEUE" "$AUTHLOG" "$TMP_ROOT/expected-token" \
  "$REQLOG" "$ACKFAIL" > "$TMP_ROOT/port" 2>"$TMP_ROOT/server.err" &
SERVER_PID=$!
PORT=
for _ in $(seq 1 100); do
  PORT=$(head -1 "$TMP_ROOT/port" 2>/dev/null || true)
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || fail "the fake River service did not start"
BASE="http://127.0.0.1:$PORT"

# Item ids have the real service's shape: a zero-padded decimal, a dash, and 32
# hex characters. LAST_ID carries the id a test just queued.
# It SETS LAST_ID rather than printing it: a command substitution would run it in
# a subshell and every caller would get the same first id back.
SEQ=0
LAST_ID=
next_id() {
  SEQ=$((SEQ + 1))
  LAST_ID=$(printf '%020d-%032x' "$SEQ" "$((SEQ * 2654435761))")
}

FSEQ=0
queue_raw() {  # <complete json object>
  FSEQ=$((FSEQ + 1))
  printf '%s\n' "$1" > "$QUEUE/$(printf '%06d' "$FSEQ").json"
}

queue_item() {  # <phrase> -> queues a contract-shaped item, setting LAST_ID
  next_id
  queue_raw "{\"id\": \"$LAST_ID\", \"phrase\": \"$1\"}"
}

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

# --- burst batching over a peek-until-ack service ---------------------------
# Three items queued before the poll starts. Because /next serves the head item
# until it is acked, this passes only if the adapter acks each captured item
# before asking for the next one.
HOME_A="$TMP_ROOT/home-a"
new_home "$HOME_A"
queue_item one; ID_ONE=$LAST_ID
queue_item two; ID_TWO=$LAST_ID
queue_item three; ID_THREE=$LAST_ID
: > "$REQLOG"
OUT="$TMP_ROOT/burst.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 "$ADAPTER" poll > "$OUT"
expect_code 0 "$?" "a poll with queued takeovers"
python3 - "$OUT" <<'PY' || fail "the burst was not emitted as one JSON array of all three distinct items"
import json, sys
data = json.load(open(sys.argv[1]))
assert isinstance(data, list), data
assert [d["phrase"] for d in data] == ["one", "two", "three"], data
ids = [d["id"] for d in data]
assert len(set(ids)) == 3, ids
PY
[ "$(wc -l < "$OUT")" -eq 1 ] || fail "the batched result was not a single emitted document"
pass "three concurrently queued takeovers become ONE capture holding all three, none duplicated"

# The interleaving proves the ordering rule, not just the outcome: each item is
# acked before the read that fetches the next one.
SEQUENCE=$(grep -E "$ID_ONE|$ID_TWO|$ID_THREE" "$REQLOG" \
  | sed -e "s/$ID_ONE/1/" -e "s/$ID_TWO/2/" -e "s/$ID_THREE/3/" -e 's/ retired$//' \
  | tr '\n' ' ')
[ "$SEQUENCE" = "next 1 ack 1 next 2 ack 2 next 3 ack 3 " ] \
  || fail "the poll did not ack each item before requesting the next: $SEQUENCE"
pass "each captured item is acked before the next one is requested"

# --- the credential is presented, and never observable ----------------------
assert_grep "Bearer $TOKEN" "$AUTHLOG" "the adapter did not present the bearer credential"
pass "the poll authenticates with the home's configured bearer token"

CLASSIFIED=$(river "$HOME_A" classify "$OUT")
[ "$CLASSIFIED" = takeovers ] || fail "a non-empty item array classified as '$CLASSIFIED'"
pass "a non-empty item array classifies as takeovers"

# --- nothing is ever served twice across successive polls -------------------
queue_item first-poll; ID_FIRST=$LAST_ID
POLL1="$TMP_ROOT/dedupe-1.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 "$ADAPTER" poll > "$POLL1"
expect_code 0 "$?" "the first of two successive polls"
queue_item second-poll; ID_SECOND=$LAST_ID
POLL2="$TMP_ROOT/dedupe-2.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 "$ADAPTER" poll > "$POLL2"
expect_code 0 "$?" "the second of two successive polls"
python3 - "$POLL1" "$POLL2" "$ID_FIRST" "$ID_SECOND" <<'PY' || fail "an item was captured twice across two successive polls"
import json, sys
first = [d["id"] for d in json.load(open(sys.argv[1]))]
second = [d["id"] for d in json.load(open(sys.argv[2]))]
assert first == [sys.argv[3]], first
assert second == [sys.argv[4]], second
assert not set(first) & set(second), (first, second)
PY
pass "an acked takeover is never served again, so two successive polls share no item"

# --- the at-least-once boundary: a failed ack re-serves the item ------------
# The service refuses this item's ack, so it stays pending. The item was still
# captured, so it must be emitted; and the drain must stop rather than spin on
# an item the service keeps re-serving.
queue_item ack-fails; ID_STUCK=$LAST_ID
queue_item behind-the-stuck-one; ID_BEHIND=$LAST_ID
printf '%s\n' "$ID_STUCK" > "$ACKFAIL"
: > "$REQLOG"
STUCK1="$TMP_ROOT/stuck-1.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 "$ADAPTER" poll > "$STUCK1"
expect_code 0 "$?" "a poll whose captured item could not be acked"
python3 - "$STUCK1" "$ID_STUCK" <<'PY' || fail "an item whose ack failed was not emitted, or the drain ran past it"
import json, sys
data = json.load(open(sys.argv[1]))
assert [d["id"] for d in data] == [sys.argv[2]], data
PY
[ "$(grep -c "^next " "$REQLOG")" -eq 1 ] \
  || fail "the poll kept reading after an ack failure instead of emitting what it had"
pass "an ack failure still emits the captured item and stops the drain instead of spinning"

# Now let the ack through: the still-pending item is served again, which is the
# at-least-once boundary stated in the adapter's header.
: > "$ACKFAIL"
STUCK2="$TMP_ROOT/stuck-2.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 "$ADAPTER" poll > "$STUCK2"
expect_code 0 "$?" "the poll that re-serves the unacked item"
python3 - "$STUCK2" "$ID_STUCK" "$ID_BEHIND" <<'PY' || fail "the unacked item was not re-served on the next poll"
import json, sys
ids = [d["id"] for d in json.load(open(sys.argv[1]))]
assert ids == [sys.argv[2], sys.argv[3]], ids
PY
pass "an item captured but not acked is re-served on the next poll, never dropped"

# --- the grace window batches a takeover that arrives just behind the burst --
GRACE_OUT="$TMP_ROOT/grace.json"
queue_item grace-first
( sleep 0.4; queue_item grace-second ) &
GRACE_BG=$!
GRACE_START=$SECONDS
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 FM_RIVER_BURST_GRACE_MS=2000 "$ADAPTER" poll > "$GRACE_OUT"
expect_code 0 "$?" "a poll spanning the burst grace window"
GRACE_ELAPSED=$((SECONDS - GRACE_START))
wait "$GRACE_BG" 2>/dev/null || true
python3 - "$GRACE_OUT" <<'PY' || fail "the grace window did not batch the takeover that arrived just behind the first"
import json, sys
phrases = [d["phrase"] for d in json.load(open(sys.argv[1]))]
assert phrases == ["grace-first", "grace-second"], phrases
PY
[ "$GRACE_ELAPSED" -le 10 ] || fail "the graced poll ran for ${GRACE_ELAPSED}s, well past its window"
pass "a takeover arriving inside the grace window joins the same wake"

# The window is a bound, not an open door: an item arriving well after it comes
# back as its own capture rather than holding the first one open.
BOUND1="$TMP_ROOT/bound-1.json"
BOUND2="$TMP_ROOT/bound-2.json"
queue_item bound-first
( sleep 1.5; queue_item bound-late ) &
BOUND_BG=$!
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 FM_RIVER_BURST_GRACE_MS=100 "$ADAPTER" poll > "$BOUND1"
expect_code 0 "$?" "a poll with a short grace window"
wait "$BOUND_BG" 2>/dev/null || true
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 FM_RIVER_BURST_GRACE_MS=100 "$ADAPTER" poll > "$BOUND2"
expect_code 0 "$?" "the poll that collects the late arrival"
python3 - "$BOUND1" "$BOUND2" <<'PY' || fail "the grace window did not bound how long the first capture stayed open"
import json, sys
first = [d["phrase"] for d in json.load(open(sys.argv[1]))]
second = [d["phrase"] for d in json.load(open(sys.argv[2]))]
assert first == ["bound-first"], first
assert second == ["bound-late"], second
PY
pass "an arrival past the grace window becomes its own capture, so the window stays bounded"

# --- an over-budget burst splits across captures with zero loss --------------
# The batch byte budget is shrunk through its env override and the item sizes
# are pinned, so the drain must stop mid-burst. Every queued item must come
# back exactly once across the two captures, and each captured array must fit
# the budget.
pad_item() {  # <phrase> <id> -> one 160-character contract-shaped JSON object
  python3 - "$1" "$2" <<'PY'
import json, sys
obj = {"id": sys.argv[2], "phrase": sys.argv[1], "pad": ""}
obj["pad"] = "x" * (160 - len(json.dumps(obj, separators=(",", ":"))))
print(json.dumps(obj, separators=(",", ":")))
PY
}
for p in split-a split-b split-c split-d; do next_id; queue_raw "$(pad_item "$p" "$LAST_ID")"; done
SPLIT1="$TMP_ROOT/split-1.json"
SPLIT2="$TMP_ROOT/split-2.json"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 FM_RIVER_MAX_BYTES=200 FM_RIVER_MAX_BATCH_BYTES=400 \
  "$ADAPTER" poll > "$SPLIT1"
expect_code 0 "$?" "the first poll of an over-budget burst"
FM_HOME="$HOME_A" FM_RIVER_WAIT=5 FM_RIVER_MAX_BYTES=200 FM_RIVER_MAX_BATCH_BYTES=400 \
  "$ADAPTER" poll > "$SPLIT2"
expect_code 0 "$?" "the second poll, which must return the still-queued remainder"
[ "$(wc -c < "$SPLIT1")" -le 400 ] || fail "the first capture exceeded the batch byte budget"
[ "$(wc -c < "$SPLIT2")" -le 400 ] || fail "the second capture exceeded the batch byte budget"
python3 - "$SPLIT1" "$SPLIT2" <<'PY' || fail "the split burst lost or duplicated an item"
import json, sys
first = json.load(open(sys.argv[1]))
second = json.load(open(sys.argv[2]))
assert isinstance(first, list) and isinstance(second, list)
assert first and second, (first, second)
phrases = [d["phrase"] for d in first + second]
assert sorted(phrases) == ["split-a", "split-b", "split-c", "split-d"], phrases
ids = [d["id"] for d in first + second]
assert len(set(ids)) == 4, ids
PY
pass "an over-budget burst splits into two captures, every item delivered exactly once"

# --- 204 re-poll ------------------------------------------------------------
# Nothing is queued, so the first request times out with 204; the adapter must
# poll again rather than exit, and return the item that arrives afterwards.
: > "$AUTHLOG"
OUT2="$TMP_ROOT/repoll.json"
( sleep 1.5; queue_item late ) &
LATE=$!
FM_HOME="$HOME_A" FM_RIVER_WAIT=1 "$ADAPTER" poll > "$OUT2"
expect_code 0 "$?" "a poll that had to wait through an empty window"
wait "$LATE" 2>/dev/null || true
assert_grep '"late"' "$OUT2" "the adapter did not return the item that arrived after an empty window"
[ "$(grep -c . "$AUTHLOG")" -ge 2 ] || fail "the adapter did not re-poll after a 204 timeout"
pass "an empty long-poll window re-polls instead of ending the source"

# --- the token never reaches argv or the registered registration ------------
HOME_B="$TMP_ROOT/home-b"
new_home "$HOME_B"
ARMED_HOME=$HOME_B
ARM_TMP="$TMP_ROOT/arm-tmp"
mkdir -p "$ARM_TMP"
ARM_OUT=$(TMPDIR="$ARM_TMP" river "$HOME_B" arm 2>&1) || fail "arm failed on a configured home: $ARM_OUT"
assert_contains "$ARM_OUT" "armed: river-takeover-stream" "arm did not report the canonical source"
assert_not_contains "$ARM_OUT" "$TOKEN" "arm printed the bearer token"
[ -z "$(ls -A "$ARM_TMP")" ] || fail "arm left its staged credential file on disk"
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
queue_item end-to-end
FM_HOME="$HOME_B" FM_RIVER_WAIT=5 "$ROOT/bin/fm-procevent.sh" start river-takeover-stream >/dev/null \
  || fail "the runner could not run the river source to completion"
RESULT=$(find "$HOME_B/state/procevent-inbox" -name 'river-takeover-stream.*.result' | head -1)
[ -n "$RESULT" ] || fail "the runner captured no durable result for the river source"
assert_grep '"end-to-end"' "$RESULT" "the captured result does not carry the takeover"
assert_grep 'procevent river river-takeover-stream' "$HOME_B/state/.wake-queue" \
  "a captured takeover did not publish a wake"
assert_present "$SOURCE_FILE" "the runner retired a continuous source after one result"
[ "$(river "$HOME_B" classify "$RESULT")" = takeovers ] \
  || fail "the durable result did not classify as takeovers"
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
printf 'line-one\nline-two\n' > "$HOME_C/config/river-token"
ARM_ERR=$(river "$HOME_C" arm 2>&1) && fail "arm accepted a multi-line credential file"
assert_contains "$ARM_ERR" "config/river-token" "arm did not name the multi-line credential file"
pass "arming refuses a home whose River configuration is incomplete or multi-line"

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

# --- a malformed grace window is refused, like every other knob -------------
GRACE_ERR=$(FM_HOME="$HOME_A" FM_RIVER_BURST_GRACE_MS=soon "$ADAPTER" poll 2>&1) \
  && fail "the poll accepted a non-numeric grace window"
assert_contains "$GRACE_ERR" "FM_RIVER_BURST_GRACE_MS" "the refusal did not name the bad knob"
pass "a non-numeric grace window is refused rather than guessed"

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
assert_contains "$help_out" "PEEK UNTIL ACK" "the published help does not state the peek-until-ack service contract"
assert_contains "$help_out" "AT LEAST ONCE" "the published help does not state the at-least-once boundary"
assert_contains "$help_out" "FM_RIVER_BURST_GRACE_MS" "the published help does not document the grace window"
pass "the published interface owns the adapter's mechanics"

printf '\nall procevent river tests passed\n'
