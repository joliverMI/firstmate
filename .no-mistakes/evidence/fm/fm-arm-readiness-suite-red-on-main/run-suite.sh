#!/usr/bin/env bash
# usage: run-suite.sh <label> <runs> <logfile>
label=$1; runs=$2; logfile=$3
cd /home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M0D29D6KBG8H6BZVRRHMZZZ5
pass=0; fail=0
: > "$logfile"
echo "== phase: $label ==" | tee -a "$logfile"
echo "load at start: $(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$logfile"
for i in $(seq 1 "$runs"); do
  outfile=$(mktemp)
  if tests/fm-pi-watch-extension.test.sh > "$outfile" 2>&1; then
    pass=$((pass+1)); verdict=PASS
  else
    fail=$((fail+1)); verdict=FAIL
  fi
  n_ok=$(grep -c '^ok - ' "$outfile" || true)
  n_notok=$(grep -c -i '^not ok\|^FAIL' "$outfile" || true)
  printf 'run %02d/%s: %s  assertions_ok=%s failures=%s\n' "$i" "$runs" "$verdict" "$n_ok" "$n_notok" | tee -a "$logfile"
  if [ "$verdict" = FAIL ]; then
    echo "---- failing output (run $i) ----" | tee -a "$logfile"
    cat "$outfile" | tee -a "$logfile"
    echo "---- end ----" | tee -a "$logfile"
  fi
  rm -f "$outfile"
done
echo "load at end: $(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$logfile"
echo "RESULT $label: $pass/$runs passed, $fail failed" | tee -a "$logfile"
