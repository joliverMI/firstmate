#!/usr/bin/env bash
# End-to-end demo of the operator-facing surface: the per-task endpoint verdicts
# in firstmate's session-start briefing (bin/fm-session-start.sh).
#
# Fleet as recorded in state/*.meta, against a REAL tmux server:
#   designer  -> fm:fm-designer   LIVE
#   design    -> fm:fm-design     DEAD (its name is a strict PREFIX of fm-designer)
#   mate-1    -> remote:mate-1    on another host (remote_host=build-box)
set -u
TREE=$1; LABEL=$2
SOCK="fm-digest-demo-$$"
REAL_TMUX=$(command -v tmux)
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-digest-demo.XXXXXX")
HOME_DIR="$W/home"; ROOT="$W/root"; BIN="$W/bin"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$BIN"
git init -q -b main "$ROOT" && git -C "$ROOT" commit -q --allow-empty -m init
cat > "$BIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$BIN/tmux"
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

"$BIN/tmux" new-session -d -s fm -n shell
"$BIN/tmux" new-window -t fm -n fm-designer

printf 'window=fm:fm-designer\nkind=ship\n'                       > "$HOME_DIR/state/designer.meta"
printf 'window=fm:fm-design\nkind=ship\n'                         > "$HOME_DIR/state/design.meta"
printf 'window=remote:mate-1\nkind=secondmate\nremote_host=build-box\n' > "$HOME_DIR/state/mate-1.meta"

echo "### $LABEL"
echo "\$ tmux list-windows -t fm -F '#{window_name}'   # ground truth"
"$BIN/tmux" list-windows -t fm -F '  #{window_name}'
echo "\$ fm-session-start.sh    (endpoint verdicts from the session briefing)"
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PATH="$BIN:$PATH" \
  "$TREE/bin/fm-session-start.sh" 2>/dev/null \
  | grep -B1 '^endpoint:' | sed 's/^/  /'
echo
