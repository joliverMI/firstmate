#!/usr/bin/env bash
# End-to-end demo: how a firstmate operator experiences the tmux-liveness bug.
#
# A crew "design" was spawned into tmux window fm:fm-design and later died.
# Its status log still says "working: drafting the layout" (append-only event
# log - a dead crew never writes a closing line). A SIBLING crew "designer" is
# still live in fm:fm-designer - its name is a strict PREFIX collision.
#
# bin/fm-crew-state.sh is what firstmate reads every heartbeat to render a
# crew's current state. Run it against the DEAD crew.
set -u
TREE=$1            # repo tree to exercise (base = pre-fix, worktree = fixed)
LABEL=$2
SOCK="fm-liveness-demo-$$-$(basename "$TREE")"
REAL_TMUX=$(command -v tmux)
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness-demo.XXXXXX")
SHIM="$D/shim"; mkdir -p "$SHIM" "$D/state" "$D/wt"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$SHIM/tmux"
# fake `no-mistakes` so no validation run is attributed to this crew: the pane
# probe is then the only thing standing between a dead crew and its stale log.
cat > "$SHIM/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$SHIM/no-mistakes"
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$D"; }
trap cleanup EXIT

"$SHIM/tmux" new-session -d -s fm -n shell
"$SHIM/tmux" new-window -t fm -n fm-designer     # the LIVE sibling crew
# note: fm-design was never created / already died.

printf 'window=fm:fm-design\nworktree=%s/wt\nkind=secondmate\n' "$D" > "$D/state/design.meta"
printf 'working: drafting the layout\n' > "$D/state/design.status"

echo "### $LABEL"
echo "\$ tmux -L $SOCK list-windows -t fm -F '#{window_name}'   # what is actually alive"
"$SHIM/tmux" list-windows -t fm -F '  #{window_name}'
echo "\$ cat state/design.meta"
sed 's/^/  /' "$D/state/design.meta"
echo "\$ fm-crew-state.sh design      # firstmate's per-heartbeat read of crew 'design'"
PATH="$SHIM:$PATH" FM_STATE_OVERRIDE="$D/state" "$TREE/bin/fm-crew-state.sh" design 2>&1 | sed 's/^/  /'
echo
