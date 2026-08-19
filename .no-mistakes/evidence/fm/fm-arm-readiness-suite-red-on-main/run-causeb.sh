#!/usr/bin/env bash
# usage: run-causeb.sh <logfile> <runs> <loadprocs>
logfile=$1; runs=${2:-10}; loadprocs=${3:-160}
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
for _ in $(seq 1 "$loadprocs"); do ( while :; do :; done ) & pids+=($!); done
sleep 20
: > "$logfile"
TESTS=(test_pi_hung_successor_falls_back_to_typed_wake test_pi_unretired_successor_falls_back_without_retry)
{
  echo "== cause-B isolation: the two named Pi readiness-window assertions =="
  echo "synthetic load: $loadprocs busy-loop processes on $(nproc) cores"
  echo "load at start: $(cut -d' ' -f1-3 /proc/loadavg)"
} | tee -a "$logfile"
for tree in /tmp/arm-repro-loginshell /tmp/arm-repro-fixed; do
  case $tree in
    *loginshell) label="arm child under bash -lc (pre-fix behaviour)";;
    *) label="arm child under bash -c (FM_WATCH_ARM_NO_LOGIN_SHELL=1, shipped)";;
  esac
  pass=0; fail=0
  echo "-- $label --" | tee -a "$logfile"
  for i in $(seq 1 "$runs"); do
    o=$( cd "$tree" && tests/single.sh "${TESTS[@]}" 2>&1 )
    if [ $? -eq 0 ]; then pass=$((pass+1)); else
      fail=$((fail+1))
      printf 'run %02d FAIL: %s\n' "$i" "$(printf '%s' "$o" | grep '^not ok' | head -1)" | tee -a "$logfile"
    fi
  done
  echo "RESULT [$label]: $pass/$runs passed, $fail failed" | tee -a "$logfile"
done
echo "load at end: $(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$logfile"
