#!/usr/bin/env bash
set -u
EV=/tmp/no-mistakes-evidence/01M0DK5YFW9RYBPHARK8YE2V4J
trap '$EV/cpu-load.sh stop /tmp/fm-load.pids 2>/dev/null' EXIT INT TERM
$EV/cpu-load.sh start 160 /tmp/fm-load.pids
sleep 20
$EV/run-suite-repeatedly.sh loaded 20 $EV/logs
