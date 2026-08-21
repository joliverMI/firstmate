#!/usr/bin/env bash
# End-to-end demo: does a fleet self-update follow the fork the checkout tracks?
set -u
WT=/home/joliv/.no-mistakes/worktrees/4cc5c0885385/01M0GZ5GAYE1MMH0ZHM3GTDHTH
LAB=/tmp/fm-fork-lab
rm -rf "$LAB"; mkdir -p "$LAB"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export FM_GATE_REFUSE_BYPASS=1

B=$(git -C "$WT" rev-parse 3a972e3^)   # real ancestor: before bin/fm-dashboard.sh and --card existed
F=$(git -C "$WT" rev-parse HEAD)       # fork tip under test

echo "### Fixture (real firstmate history)"
echo "public template  kunchenguid/firstmate  main = $(git -C "$WT" log -1 --format='%h %s' "$B")"
echo "development fork joliverMI/firstmate    main = $(git -C "$WT" log -1 --format='%h %s' "$F")"
echo "fork-only commits ahead of the template: $(git -C "$WT" rev-list --count "$B".."$F")"
echo

git init -q --bare "$LAB/template.git"; git -C "$LAB/template.git" symbolic-ref HEAD refs/heads/main
git init -q --bare "$LAB/fork.git";     git -C "$LAB/fork.git" symbolic-ref HEAD refs/heads/main
git -C "$WT" push -q "$LAB/template.git" "$B:refs/heads/main"
git -C "$WT" push -q "$LAB/fork.git" "$F:refs/heads/main"

# pre-fix bin/ (base commit b98e098), run from its own directory
mkdir -p "$LAB/prefix"
git -C "$WT" archive b98e098 bin | tar -x -C "$LAB/prefix"

build_fixture() {   # remote host: code root whose origin is the template but whose main tracks the fork
  rm -rf "$LAB/remote-root" "$LAB/remote-home"
  git clone -q --origin origin "$LAB/template.git" "$LAB/remote-root"
  git -C "$LAB/remote-root" remote add fork "$LAB/fork.git"
  git -C "$LAB/remote-root" fetch -q fork
  git -C "$LAB/remote-root" branch -q --set-upstream-to=fork/main main
  git clone -q "$LAB/template.git" "$LAB/remote-home"
  printf 'ios\n' > "$LAB/remote-home/.fm-secondmate-home"
}

report_home() {
  local h="$LAB/remote-home"
  echo "  home HEAD                 : $(git -C "$h" log -1 --format='%h %s' HEAD)"
  if [ -f "$h/bin/fm-dashboard.sh" ]; then
    echo "  bin/fm-dashboard.sh       : PRESENT -> $(bash "$h/bin/fm-dashboard.sh" --help 2>&1 | sed -n '1p')"
  else
    echo "  bin/fm-dashboard.sh       : ABSENT"
  fi
  if bash "$h/bin/fm-spawn.sh" --help 2>&1 | grep -q -- '--card <card-id>'; then
    echo "  fm-spawn.sh --card        : PRESENT -> $(bash "$h/bin/fm-spawn.sh" x /tmp --mode direct-PR --yolo off --card= 2>&1 | sed -n '1p')"
  else
    echo "  fm-spawn.sh --card        : ABSENT -> $(bash "$h/bin/fm-spawn.sh" x /tmp --mode direct-PR --yolo off --card= 2>&1 | sed -n '1p')"
  fi
}

run_update() {   # $1 = bin dir to run the fleet update from
  FM_ROOT_OVERRIDE="$LAB/remote-root" FM_HOME="$LAB/remote-home" \
    bash "$1/fm-remote-secondmate-control.sh" update ios 2>&1 | sed 's/^/  /'
}

for variant in prefix fixed; do
  case $variant in
    prefix) BIN="$LAB/prefix/bin"; label="BEFORE the fix (bin/ at b98e098)" ;;
    fixed)  BIN="$WT/bin";         label="AFTER the fix  (bin/ at $(git -C "$WT" rev-parse --short HEAD))" ;;
  esac
  build_fixture
  echo "### $label"
  echo "  fm-remote-secondmate-control.sh update ios   (as /updatefirstmate dispatches it to the host)"
  run_update "$BIN"
  report_home
  echo
done

echo "### The update line the captain actually sees (bin/fm-update.sh against the same code root)"
for variant in prefix fixed; do
  case $variant in
    prefix) BIN="$LAB/prefix/bin"; label="before" ;;
    fixed)  BIN="$WT/bin";         label="after " ;;
  esac
  build_fixture
  out=$(FM_ROOT_OVERRIDE="$LAB/remote-root" FM_HOME="$LAB/remote-root" bash "$BIN/fm-update.sh" 2>&1 | grep '^firstmate:')
  echo "  $label fix: $out"
done
echo

echo "### No upstream configured: keeps origin/main and says so"
build_fixture
git -C "$LAB/remote-root" branch -q --unset-upstream main
FM_ROOT_OVERRIDE="$LAB/remote-root" FM_HOME="$LAB/remote-root" bash "$WT/bin/fm-update.sh" 2>&1 | grep '^firstmate:' | sed 's/^/  /'
echo

echo "### Fast-forward-only safety is unchanged"
build_fixture
git -C "$LAB/remote-root" commit -q --allow-empty -m 'unlanded local work'
DIV=$(git -C "$LAB/remote-root" rev-parse HEAD)
FM_ROOT_OVERRIDE="$LAB/remote-root" FM_HOME="$LAB/remote-root" bash "$WT/bin/fm-update.sh" 2>&1 | grep '^firstmate:' | sed 's/^/  diverged code root -> /'
[ "$(git -C "$LAB/remote-root" rev-parse HEAD)" = "$DIV" ] \
  && echo "  diverged code root -> unlanded commit still at HEAD, nothing forced or discarded"

build_fixture
printf 'uncommitted\n' > "$LAB/remote-root/AGENTS.md"
FM_ROOT_OVERRIDE="$LAB/remote-root" FM_HOME="$LAB/remote-root" bash "$WT/bin/fm-update.sh" 2>&1 | grep '^firstmate:' | sed 's/^/  dirty code root    -> /'
grep -q uncommitted "$LAB/remote-root/AGENTS.md" \
  && echo "  dirty code root    -> uncommitted edit still in the worktree, nothing stashed"
