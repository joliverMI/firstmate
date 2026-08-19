#!/usr/bin/env bash
# Repeated-run harness for tests/fm-pi-watch-extension.test.sh
# usage: run-suite-repeatedly.sh <phase-label> <runs> <logdir>
set -u
phase=$1; runs=$2; logdir=$3
mkdir -p "$logdir"
pass=0; fail=0
printf 'phase=%s runs=%s start_loadavg=%s\n' "$phase" "$runs" "$(cut -d' ' -f1-3 /proc/loadavg)"
for i in $(seq 1 "$runs"); do
  start=$(date +%s.%N)
  tests/fm-pi-watch-extension.test.sh > "$logdir/$phase-run$i.log" 2>&1
  rc=$?
  end=$(date +%s.%N)
  oks=$(grep -c '^ok - ' "$logdir/$phase-run$i.log")
  if [ "$rc" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  printf 'phase=%s run=%02d rc=%d assertions_ok=%s secs=%.1f loadavg1=%s\n' \
    "$phase" "$i" "$rc" "$oks" "$(echo "$end - $start" | bc)" "$(cut -d' ' -f1 /proc/loadavg)"
done
printf 'PHASE %s RESULT: passed=%d failed=%d of %d  end_loadavg=%s\n' \
  "$phase" "$pass" "$fail" "$runs" "$(cut -d' ' -f1-3 /proc/loadavg)"
