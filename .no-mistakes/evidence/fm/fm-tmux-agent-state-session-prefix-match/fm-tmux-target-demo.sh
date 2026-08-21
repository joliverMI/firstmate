#!/usr/bin/env bash
# Manual end-to-end demonstration of the two remaining tmux target-resolution
# gaps this change closes, driven through the real backend functions against a
# real tmux server on a private socket.
set -u
ROOT=$1
LABEL=$2
REAL_TMUX=$(command -v tmux)
SOCKET="fm-demo-$$"
SHIM=$(mktemp -d /tmp/fm-demo.XXXXXX)
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"; export PATH
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$SHIM"; }
trap cleanup EXIT
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || exit 1

echo "=================================================================="
echo " $LABEL   (tmux $(tmux -V | awk '{print $2}'))"
echo "=================================================================="

tmux new-session -d -s demo -x 200 -y 50

echo
echo "--- 1. kill a task window whose NAME contains a dot -----------------"
fm_backend_tmux_create_task demo fm-rel-1 "$HOME" >/dev/null
tmux split-window -t demo:fm-rel-1
fm_backend_tmux_create_task demo fm-rel-1.2 "$HOME" >/dev/null
echo "windows before kill:"; tmux list-windows -t '=demo' -F '  #{window_name}'
echo "\$ fm_backend_tmux_kill demo:fm-rel-1.2      # remove ONLY the dotted-name window"
fm_backend_tmux_kill demo:fm-rel-1.2
echo "windows after kill:"; tmux list-windows -t '=demo' -F '  #{window_name}'
if tmux list-windows -t '=demo' -F '#{window_name}' | grep -Fqx fm-rel-1; then
  if tmux list-windows -t '=demo' -F '#{window_name}' | grep -Fqx fm-rel-1.2; then
    echo "RESULT: dotted-name window SURVIVED (kill did nothing)"
  else
    echo "RESULT: OK - only the addressed window 'fm-rel-1.2' was removed"
  fi
else
  echo "RESULT: DEFECT - the unrelated live sibling window 'fm-rel-1' was DESTROYED"
fi
tmux kill-window -t '=demo:=fm-rel-1' 2>/dev/null
tmux list-windows -t '=demo' -F '#{window_id} #{window_name}' | while read -r i n; do
  [ "$n" = "fm-rel-1.2" ] && tmux kill-window -t "$i"; done

echo
echo "--- 2. spawn-time typing at a destroyed prefix-colliding window ------"
fm_backend_tmux_create_task demo fm-alpha-2 "$HOME" >/dev/null
sleep 0.6
echo "live windows:"; tmux list-windows -t '=demo' -F '  #{window_name}'
echo "'demo:fm-alpha' does NOT exist; it is only a PREFIX of live 'demo:fm-alpha-2'."
echo "\$ fm_backend_tmux_send_text_line demo:fm-alpha \"echo SETUP-COMMAND-FOR-ALPHA\""
if err=$(fm_backend_tmux_send_text_line demo:fm-alpha "echo SETUP-COMMAND-FOR-ALPHA" 2>&1); then rc=0; else rc=$?; fi
[ -n "$err" ] && printf '  stderr: %s\n' "$err"
echo "  (send exit status: $rc)"
echo "\$ fm_backend_tmux_send_literal demo:fm-alpha \"echo LAUNCH-COMMAND-FOR-ALPHA\""
if err=$(fm_backend_tmux_send_literal demo:fm-alpha "echo LAUNCH-COMMAND-FOR-ALPHA" 2>&1); then rc=0; else rc=$?; fi
[ -n "$err" ] && printf '  stderr: %s\n' "$err"
echo "  (send exit status: $rc)"
sleep 1.2
echo "pane contents of the innocent live neighbour demo:fm-alpha-2:"
fm_backend_tmux_capture demo:fm-alpha-2 30 | grep -v '^$' | sed 's/^/  | /'
if fm_backend_tmux_capture demo:fm-alpha-2 30 | grep -q 'COMMAND-FOR-ALPHA'; then
  echo "RESULT: DEFECT - input addressed to a dead window landed in a LIVE neighbour's pane"
else
  echo "RESULT: OK - nothing addressed to the dead window reached the live neighbour"
fi

echo
echo "--- 3. recovery-grade liveness read of a nonexistent session ---------"
tmux new-session -d -s crew-9-2 -x 200 -y 50
fm_backend_tmux_create_task crew-9-2 fm-7 "$HOME" >/dev/null
fm_backend_tmux_send_text_line crew-9-2:fm-7 "exec -a claude sleep 300" >/dev/null 2>&1
for _ in $(seq 1 40); do
  case "$(fm_backend_tmux_foreground_argv0s crew-9-2:fm-7 2>/dev/null)" in *claude*) break ;; esac
  sleep 0.1
done
echo "live sessions:"; tmux list-sessions -F '  #{session_name}'
echo "session 'crew-9' does NOT exist; it is only a PREFIX of live 'crew-9-2'."
echo "\$ fm_backend_agent_state tmux crew-9:fm-7"
state=$(fm_backend_agent_state tmux crew-9:fm-7)
echo "  -> $state"
case "$state" in
  alive) echo "RESULT: DEFECT - a nonexistent endpoint reported ALIVE (read from the live sibling session)" ;;
  missing) echo "RESULT: OK - nonexistent endpoint reported missing; recovery is licensed correctly" ;;
  *) echo "RESULT: $state" ;;
esac
echo
