#!/usr/bin/env bash
# Manual end-to-end demo: the guard must NOT block a copy a finished task's own
# teardown genuinely retired. Drives the real bin/fm-spawn.sh CLI twice.
set -u
ROOT=$1
SCRATCH=$(mktemp -d /tmp/fm-reuse-demo.XXXXXX)
PROJ="$SCRATCH/project"; POOL_WT="$SCRATCH/pool-copy-1"; HOME_DIR="$SCRATCH/home"

mkdir -p "$PROJ"
git -C "$PROJ" init --quiet -b main
git -C "$PROJ" config user.email demo@example.com
git -C "$PROJ" config user.name demo
printf 'shipped\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" commit --quiet -m initial
git init --quiet --bare "$PROJ.origin.git"
git -C "$PROJ" remote add origin "$PROJ.origin.git"
git -C "$PROJ" push --quiet -u origin main
git -C "$PROJ" worktree add --quiet -b fm/pool-1 "$POOL_WT"

mkdir -p "$HOME_DIR"/{state,data,projects,config}
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"

FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
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

spawn() {
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  echo "\$ fm-spawn.sh $id <project> --mode no-mistakes --yolo off"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" --mode no-mistakes --yolo off 2>&1 \
    | grep -v 'records no delivery contract line' | sed 's/^/  /'
  echo "  exit status: ${PIPESTATUS[0]}"
}

echo "=================================================================="
echo "  NO FALSE-POSITIVE: a copy teardown genuinely retired stays reusable"
echo "=================================================================="
echo
echo "1) First task takes pool copy 1."
spawn pool-first-task
echo
echo "2) That task finishes; fm-teardown.sh returns the copy and retires its record."
echo "\$ rm -f state/pool-first-task.meta state/pool-first-task.turn-ended"
rm -f "$HOME_DIR/state/pool-first-task.meta" "$HOME_DIR/state/pool-first-task.turn-ended"
echo
echo "3) The pool hands the same copy to the next task - this must NOT be refused."
spawn pool-next-task
echo
echo "--- who firstmate records on pool copy 1 now --------------------------"
grep -H "worktree=$POOL_WT\$" "$HOME_DIR"/state/*.meta 2>/dev/null | sed "s#$HOME_DIR/state/#  #"
echo
rm -rf "$SCRATCH"
