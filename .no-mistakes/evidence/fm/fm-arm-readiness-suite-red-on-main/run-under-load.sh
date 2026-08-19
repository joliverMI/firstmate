#!/usr/bin/env bash
# usage: run-under-load.sh <treedir> <label> <runs> <logfile> [loadprocs]
tree=$1; label=$2; runs=$3; logfile=$4; loadprocs=${5:-160}
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
for _ in $(seq 1 "$loadprocs"); do
  ( while :; do :; done ) &
  pids+=($!)
done
sleep 20   # let the load average climb before the phase starts
pass=0; fail=0
: > "$logfile"
{
  echo "== phase: $label =="
  echo "tree: $tree"
  echo "synthetic load: $loadprocs busy-loop processes on $(nproc) cores"
  echo "load at start: $(cut -d' ' -f1-3 /proc/loadavg)"
} | tee -a "$logfile"
for i in $(seq 1 "$runs"); do
  outfile=$(mktemp)
  if ( cd "$tree" && tests/fm-pi-watch-extension.test.sh ) > "$outfile" 2>&1; then
    pass=$((pass+1)); verdict=PASS
  else
    fail=$((fail+1)); verdict=FAIL
  fi
  n_ok=$(grep -c '^ok - ' "$outfile" || true)
  printf 'run %02d/%s: %s  assertions_ok=%s\n' "$i" "$runs" "$verdict" "$n_ok" | tee -a "$logfile"
  if [ "$verdict" = FAIL ]; then
    echo "---- failing assertions (run $i) ----" | tee -a "$logfile"
    grep -n 'FAIL\|not ok\|expected' "$outfile" | head -20 | tee -a "$logfile"
    echo "---- end ----" | tee -a "$logfile"
  fi
  rm -f "$outfile"
done
{
  echo "load at end: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "RESULT $label: $pass/$runs passed, $fail failed"
} | tee -a "$logfile"
