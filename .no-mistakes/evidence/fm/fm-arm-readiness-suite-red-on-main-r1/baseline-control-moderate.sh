#!/usr/bin/env bash
# Negative control for cause B: run the PRE-CHANGE (base 45bd292) suite file
# against the same tree, under the same 160-process CPU load, 10 times.
set -u
EV=/tmp/no-mistakes-evidence/01M0DK5YFW9RYBPHARK8YE2V4J
cleanup() {
  $EV/cpu-load.sh stop /tmp/fm-load-base2.pids 2>/dev/null
  git checkout -- tests/fm-pi-watch-extension.test.sh
}
trap cleanup EXIT INT TERM
git show 45bd292:tests/fm-pi-watch-extension.test.sh > tests/fm-pi-watch-extension.test.sh
chmod +x tests/fm-pi-watch-extension.test.sh
$EV/cpu-load.sh start 48 /tmp/fm-load-base2.pids
sleep 20
$EV/run-suite-repeatedly.sh base-moderate 12 $EV/logs
