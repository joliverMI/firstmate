#!/usr/bin/env bash
# Reproduce the 2026-09-17 live failure against the contract-faithful fake River
# service, then show the fixed adapter on the same three-item queue.
set -u
WT=$1; BASE_SHA=$2; EV=$3
W=$(mktemp -d /tmp/river-repro.XXXXXX)
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
# The fake service is the one the colocated test owns; lift it verbatim.
sed -n "/^cat > \"\$TMP_ROOT\/fake-river.py\" <<'PY'$/,/^PY$/p" "$WT/tests/fm-procevent-river.test.sh" | sed '1d;$d' > "$W/fake-river.py"
mkdir -p "$W/queue" "$W/home/config" "$W/home/state"
TOKEN=repro-token-$$
printf '%s\n' "$TOKEN" > "$W/expected-token"
: > "$W/auth.log"; : > "$W/req.log"; : > "$W/ack-fail"
python3 "$W/fake-river.py" "$W/queue" "$W/auth.log" "$W/expected-token" "$W/req.log" "$W/ack-fail" > "$W/port" 2>"$W/srv.err" &
SRV=$!
for _ in $(seq 1 100); do PORT=$(head -1 "$W/port" 2>/dev/null); [ -n "$PORT" ] && break; sleep 0.1; done
printf 'http://127.0.0.1:%s\n' "$PORT" > "$W/home/config/river-service"
printf '%s\n' "$TOKEN" > "$W/home/config/river-token"
git -C "$WT" show "$BASE_SHA:bin/fm-procevent-river.sh" > "$W/old-adapter.sh"; chmod +x "$W/old-adapter.sh"

seed() {
  rm -f "$W/queue"/*; : > "$W/req.log"
  i=0
  for phrase in "turn on the porch light" "lock the front door" "what is the weather"; do
    i=$((i+1))
    printf '{"id": "%020d-%032x", "text": "%s", "conversation_id": "c1", "device_id": "kitchen", "language": "en", "ts": 1789999999, "received_at": 1789999999}\n' "$i" "$((i * 2654435761))" "$phrase" > "$W/queue/$(printf '%06d' "$i").json"
  done
}
summarize() {  # <capture> -> item count, distinct ids, phrases
  python3 - "$1" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1]))
print("  items in capture : %d" % len(d))
print("  distinct ids     : %d" % len({x["id"] for x in d}))
for t, n in collections.Counter(x["text"] for x in d).items():
    print("  %-28s x%d" % (t, n))
PY
}

echo "=== BEFORE (adapter at base commit ${BASE_SHA:0:7}) ==="
echo "queue: three phrases posted concurrently; /next peeks the head until it is acked"
seed
FM_HOME="$W/home" FM_RIVER_WAIT=5 timeout 120 "$W/old-adapter.sh" poll > "$W/before.json"; echo "poll exit: $?"
summarize "$W/before.json"
echo "  items still pending service-side after the poll: $(ls "$W/queue" | wc -l)"
echo "  ack requests seen by the service: $(grep -c '^ack' "$W/req.log")"
cp "$W/before.json" "$EV/capture-before-fix.json"

echo
echo "=== AFTER (adapter at HEAD $(git -C "$WT" rev-parse --short HEAD)) ==="
seed
FM_HOME="$W/home" FM_RIVER_WAIT=5 timeout 120 "$WT/bin/fm-procevent-river.sh" poll > "$W/after.json"; echo "poll exit: $?"
summarize "$W/after.json"
echo "  items still pending service-side after the poll: $(ls "$W/queue" | wc -l)"
echo "  service request log (ack lands before the next read):"
sed 's/^/    /' "$W/req.log"
cp "$W/after.json" "$EV/capture-after-fix.json"
echo
echo "emitted capture after the fix:"
cat "$W/after.json"

echo
echo "=== grace window: second phrase 0.4s behind the first joins the same wake ==="
rm -f "$W/queue"/*; : > "$W/req.log"
printf '{"id": "%020d-%032x", "text": "first phrase"}\n' 11 11 > "$W/queue/000011.json"
( sleep 0.4; printf '{"id": "%020d-%032x", "text": "second phrase, a beat later"}\n' 12 12 > "$W/queue/000012.json" ) &
LATER=$!
t0=$(date +%s%N)
FM_HOME="$W/home" FM_RIVER_WAIT=5 timeout 60 "$WT/bin/fm-procevent-river.sh" poll > "$W/grace.json"
t1=$(date +%s%N)
wait "$LATER"
echo "poll wall time with the default 500ms grace: $(( (t1 - t0) / 1000000 )) ms"
cat "$W/grace.json"
summarize "$W/grace.json"

echo
echo "=== at-least-once: an item whose ack is refused is withheld, then re-served ==="
rm -f "$W/queue"/*; : > "$W/req.log"
printf '{"id": "%020d-%032x", "text": "unackable for now"}\n' 21 21 > "$W/queue/000021.json"
printf '%020d-%032x\n' 21 21 > "$W/ack-fail"
FM_HOME="$W/home" FM_RIVER_WAIT=2 FM_RIVER_UNREACHABLE_WINDOW=2 FM_RIVER_RETRY_BACKOFF=0 timeout 60 "$WT/bin/fm-procevent-river.sh" poll > "$W/refused.json"
echo "poll 1 (acks refused) emitted:"; cat "$W/refused.json"
echo "items still pending service-side: $(ls "$W/queue" | wc -l)"
: > "$W/ack-fail"
FM_HOME="$W/home" FM_RIVER_WAIT=5 timeout 60 "$WT/bin/fm-procevent-river.sh" poll > "$W/reserved.json"
echo "poll 2 (acks allowed) emitted:"; cat "$W/reserved.json"
echo "items still pending service-side: $(ls "$W/queue" | wc -l)"
