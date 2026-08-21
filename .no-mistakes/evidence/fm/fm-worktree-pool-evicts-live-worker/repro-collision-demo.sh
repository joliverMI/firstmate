#!/usr/bin/env bash
# Manual end-to-end demo: a pool that hands back a copy another live task is
# already working in. Drives the real bin/fm-spawn.sh CLI.
set -u
ROOT=$1        # firstmate checkout to drive
LABEL=$2       # "BEFORE FIX" / "AFTER FIX"
SCRATCH=$(mktemp -d /tmp/fm-collision-demo.XXXXXX)

PROJ="$SCRATCH/project"
POOL_WT="$SCRATCH/pool-copy-1"
HOME_DIR="$SCRATCH/home"

# --- a real project with a real origin ---------------------------------------
mkdir -p "$PROJ"
git -C "$PROJ" init --quiet -b main
git -C "$PROJ" config user.email demo@example.com
git -C "$PROJ" config user.name demo
printf 'shipped\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit --quiet -m "initial"
git init --quiet --bare "$PROJ.origin.git"
git -C "$PROJ" remote add origin "$PROJ.origin.git"
git -C "$PROJ" push --quiet -u origin main

# --- pool copy 1, handed to task shipwright-a, which is mid-flight ------------
git -C "$PROJ" worktree add --quiet -b fm/shipwright-a "$POOL_WT"
printf 'half-finished feature\n' > "$POOL_WT/feature.txt"
git -C "$POOL_WT" add feature.txt
git -C "$POOL_WT" commit --quiet -m "wip: shipwright-a's unlanded work"
HOLDER_COMMIT=$(git -C "$POOL_WT" rev-parse --short HEAD)

mkdir -p "$HOME_DIR"/{state,data,projects,config}
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"
cat > "$HOME_DIR/state/shipwright-a.meta" <<META
window=firstmate:fm-shipwright-a
worktree=$POOL_WT
project=$PROJ
harness=codex
kind=ship
mode=no-mistakes
yolo=off
META

# --- the new task the operator is about to spawn ------------------------------
NEW_ID=shipwright-b
mkdir -p "$HOME_DIR/data/$NEW_ID"
printf 'brief for shipwright-b\n' > "$HOME_DIR/data/$NEW_ID/brief.md"

# --- fake terminal backend: the pool settles the new window into pool-copy-1 --
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$POOL_WT"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/treehouse"

echo "=================================================================="
echo "  $LABEL   (firstmate at $ROOT)"
echo "=================================================================="
echo
echo "Setup: task 'shipwright-a' is live in pool copy $POOL_WT"
echo "       with in-flight, unlanded work committed at $HOLDER_COMMIT:"
git -C "$POOL_WT" log --oneline -1
echo "       \$ ls pool-copy-1"
ls "$POOL_WT" | sed 's/^/         /'
echo
echo "The pool now hands that same copy back for a second task, 'shipwright-b'."
echo
echo "\$ fm-spawn.sh shipwright-b <project> --mode no-mistakes --yolo off"
set +e
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$NEW_ID" "$PROJ" --mode no-mistakes --yolo off 2>&1 | sed 's/^/  /'
STATUS=${PIPESTATUS[0]}
set -e
echo
echo "exit status: $STATUS"
echo
echo "--- what happened to shipwright-a's in-flight work --------------------"
echo "\$ git -C pool-copy-1 log --oneline -1"
git -C "$POOL_WT" log --oneline -1 | sed 's/^/  /'
echo "\$ ls pool-copy-1"
ls "$POOL_WT" | sed 's/^/  /'
if git -C "$POOL_WT" rev-parse --verify --quiet "$HOLDER_COMMIT" >/dev/null && \
   [ "$(git -C "$POOL_WT" rev-parse --short HEAD)" = "$HOLDER_COMMIT" ] && \
   [ -f "$POOL_WT/feature.txt" ]; then
  echo "  => shipwright-a's unlanded commit $HOLDER_COMMIT is INTACT"
else
  echo "  => shipwright-a's unlanded commit $HOLDER_COMMIT is GONE (worktree reset out from under it)"
fi
echo
echo "--- firstmate's own record of who owns that copy ----------------------"
echo "\$ grep -H worktree= state/*.meta"
grep -H "worktree=" "$HOME_DIR"/state/*.meta 2>/dev/null | sed "s#$HOME_DIR/state/#  #"
claims=$(grep -l "worktree=$POOL_WT\$" "$HOME_DIR"/state/*.meta 2>/dev/null | wc -l)
echo "  => $claims task record(s) claim pool copy $POOL_WT"
echo
rm -rf "$SCRATCH" "$PROJ.origin.git" 2>/dev/null
