#!/usr/bin/env bash
# Simulated CPU load generator: N busy-loop processes, PIDs recorded for teardown.
# usage: cpu-load.sh start <n> <pidfile> | cpu-load.sh stop <pidfile>
set -u
case $1 in
  start)
    n=$2; pidfile=$3; : > "$pidfile"
    for _ in $(seq 1 "$n"); do
      bash -c 'while :; do :; done' & echo $! >> "$pidfile"
    done
    ;;
  stop)
    pidfile=$2
    while read -r p; do kill "$p" 2>/dev/null; done < "$pidfile"
    rm -f "$pidfile"
    ;;
esac
