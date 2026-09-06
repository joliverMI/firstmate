#!/usr/bin/env bash
# tests/fm-dashboard-boot.test.sh - coverage for the boot-survival half of the
# Admiral's Fleet Dashboard: `install-boot`/`uninstall-boot`, the unit they
# write, and the lifecycle coherence rules that hold once that unit manages a
# home.
#
# systemd itself is faked on PATH - a stub `systemctl --user` that reads the
# generated unit exactly as systemd would (its ExecStart and Environment lines),
# runs it, and tracks whether it is active, plus a stub `loginctl`. No test here
# touches a real user unit, and none asserts on implementation-source bytes: the
# unit file under test is this command's own output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { pass "skipped - python3 not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { pass "skipped - curl not available"; exit 0; }

DASH="$ROOT/bin/fm-dashboard.sh"
STARTED_PIDS=()

reap_started() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -9 "$pid" 2>/dev/null
  done
  # Anything the fake systemd still has running is the unit's own server.
  if [ -n "${FAKE_SYSTEMD_STATE:-}" ] && [ -f "$FAKE_SYSTEMD_STATE/main.pid" ]; then
    kill -9 "$(cat "$FAKE_SYSTEMD_STATE/main.pid")" 2>/dev/null
  fi
}

fm_dashboard_boot_cleanup() {
  reap_started
  fm_test_cleanup
}
trap fm_dashboard_boot_cleanup EXIT
trap 'fm_dashboard_boot_cleanup; exit 130' INT
trap 'fm_dashboard_boot_cleanup; exit 143' TERM

TMP_ROOT=$(fm_test_tmproot fm-dashboard-boot) || fail "could not create temp root"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_SYSTEMD_STATE="$TMP_ROOT/fake-systemd"
mkdir -p "$FAKE_SYSTEMD_STATE"
export FAKE_SYSTEMD_STATE
export FAKE_SYSTEMD_LOG="$FAKE_SYSTEMD_STATE/calls.log"
: >"$FAKE_SYSTEMD_LOG"

# A stand-in systemd user manager: `start` really runs the unit's ExecStart with
# its Environment, so the address the unit binds is proved end to end rather
# than assumed, and `is-active` answers from that process.
cat >"$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
state=$FAKE_SYSTEMD_STATE
quiet=false
args=()
for a in "$@"; do
  case "$a" in
    --user) ;;
    --quiet) quiet=true ;;
    *) args+=("$a") ;;
  esac
done
# Log the verb and its unit, without the flags, so a test can assert on the
# whole line rather than a substring of one.
printf '%s\n' "${args[*]}" >>"$FAKE_SYSTEMD_LOG"
verb=${args[0]:-}
unit_file=${FM_DASHBOARD_UNIT_DIR:-$HOME/.config/systemd/user}/fm-dashboard.service
running() { [ -f "$state/main.pid" ] && kill -0 "$(cat "$state/main.pid")" 2>/dev/null; }
# A unit-file word the way systemd reads it: surrounding double quotes dropped,
# and %% the only spelling of a literal percent sign.
unquote() { local v=$1; v=${v#\"}; v=${v%\"}; printf '%s' "${v//%%/%}"; }
case "$verb" in
  daemon-reload) ;;
  enable) [ -f "$unit_file" ] || exit 1; : >"$state/enabled" ;;
  disable) rm -f "$state/enabled" ;;
  is-enabled)
    if [ -f "$state/enabled" ]; then $quiet || echo enabled; exit 0; fi
    $quiet || echo disabled; exit 1 ;;
  is-active)
    if running; then $quiet || echo active; exit 0; fi
    $quiet || echo inactive; exit 3 ;;
  start)
    [ -f "$unit_file" ] || exit 1
    running && exit 0
    exec_line=$(sed -n 's/^ExecStart=//p' "$unit_file" | head -n1)
    case "$exec_line" in
      \"*) rest=${exec_line#\"}; exec_path=$(unquote "\"${rest%%\"*}\""); exec_args=${rest#*\"} ;;
      *) exec_path=${exec_line%% *}; exec_args=${exec_line#* } ;;
    esac
    env_args=()
    while IFS= read -r line; do env_args+=("$(unquote "$line")"); done < <(sed -n 's/^Environment=//p' "$unit_file")
    # shellcheck disable=SC2086
    nohup env "${env_args[@]}" "$exec_path" $exec_args >"$state/unit.log" 2>&1 &
    echo $! >"$state/main.pid" ;;
  stop)
    if running; then
      pid=$(cat "$state/main.pid")
      kill "$pid" 2>/dev/null
      while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
    fi
    rm -f "$state/main.pid" ;;
  *) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/systemctl"

cat >"$FAKEBIN/loginctl" <<'SH'
#!/usr/bin/env bash
set -u
state=$FAKE_SYSTEMD_STATE
printf 'loginctl %s\n' "$*" >>"$FAKE_SYSTEMD_LOG"
case "${1:-}" in
  enable-linger)
    [ -f "$state/linger-refused" ] && exit 1
    : >"$state/linger"; exit 0 ;;
  show-user)
    if [ -f "$state/linger" ]; then echo "Linger=yes"; else echo "Linger=no"; fi
    exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/loginctl"

PATH="$FAKEBIN:$PATH"
export PATH

UNIT_DIR="$TMP_ROOT/units"
mkdir -p "$UNIT_DIR"
export FM_DASHBOARD_UNIT_DIR="$UNIT_DIR"
UNIT="$UNIT_DIR/fm-dashboard.service"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# A home laid out the way a real one is: $FM_HOME/bin is the tracked root's bin,
# which is what `install-boot` must pin ExecStart to - not the checkout this
# test happens to run the script from.
make_home() {  # <name> -> echoes the home's physical path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  ln -s "$ROOT/bin" "$home/bin"
  (cd "$home" && pwd -P)
}

# The unit is not running yet at this point in any case that calls this.
reset_fake_systemd() {
  rm -f "$FAKE_SYSTEMD_STATE/enabled" "$FAKE_SYSTEMD_STATE/linger" \
    "$FAKE_SYSTEMD_STATE/linger-refused" "$FAKE_SYSTEMD_STATE/main.pid"
  : >"$FAKE_SYSTEMD_LOG"
}

test_install_boot_writes_and_enables_the_unit() {
  local home port out
  home=$(make_home install-case)
  port=$(free_port) || fail "could not allocate a port"
  printf 'http://127.0.0.1:%s\n' "$port" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" install-boot 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "install-boot failed"; }

  assert_present "$UNIT" "install-boot did not write the unit file"
  assert_grep_line "ExecStart=\"$home/bin/fm-dashboard.sh\" serve-foreground" "$UNIT" \
    "the unit does not run the home's own script in the foreground"
  assert_grep_line "Environment=\"FM_HOME=$home\"" "$UNIT" "the unit does not record the home it manages"
  assert_grep_line "Environment=\"FM_DASHBOARD_HOST=127.0.0.1\"" "$UNIT" \
    "the unit does not bind the host start would have defaulted to from config/dashboard-url"
  assert_grep_line "Environment=\"FM_DASHBOARD_PORT=$port\"" "$UNIT" "the unit does not record the resolved port"
  assert_grep_line "Environment=\"FM_DASHBOARD_DB=$home/data/dashboard.db\"" "$UNIT" \
    "the unit does not record the resolved database"
  assert_grep_line "WantedBy=default.target" "$UNIT" "the unit is not wanted by default.target, so it never starts at boot"
  assert_grep_line "Restart=on-failure" "$UNIT" "the unit does not restart on failure"
  assert_grep_line "enable fm-dashboard.service" "$FAKE_SYSTEMD_LOG" "install-boot did not enable the unit"
  assert_grep_line "daemon-reload" "$FAKE_SYSTEMD_LOG" "install-boot did not reload the user manager"
  assert_present "$FAKE_SYSTEMD_STATE/linger" "install-boot did not enable lingering, so the board waits for a login"
  assert_contains "$out" "lingering enabled" "install-boot did not report that lingering was enabled"

  pass "install-boot writes a foreground unit pinned to the home's own script, enables it, and turns lingering on"
}

test_install_boot_prints_the_command_when_lingering_needs_privileges() {
  local home port out
  home=$(make_home linger-case)
  port=$(free_port) || fail "could not allocate a port"
  printf 'http://127.0.0.1:%s\n' "$port" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"
  : >"$FAKE_SYSTEMD_STATE/linger-refused"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" install-boot 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "install-boot refused to install when lingering could not be enabled"; }

  assert_present "$UNIT" "install-boot did not install the unit when lingering failed"
  assert_grep_line "enable fm-dashboard.service" "$FAKE_SYSTEMD_LOG" \
    "install-boot did not still enable the unit when lingering failed"
  assert_contains "$out" "loginctl enable-linger" \
    "install-boot did not print the exact command the operator must run"
  rm -f "$FAKE_SYSTEMD_STATE/linger-refused"

  pass "a refused enable-linger still installs and enables the unit, and names the command to run by hand"
}

test_unit_managed_lifecycle_is_coherent() {
  local home port url out
  home=$(make_home lifecycle-case)
  port=$(free_port) || fail "could not allocate a port"
  url="http://127.0.0.1:$port"
  printf '%s\n' "$url" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" install-boot >"$home/install.out" 2>&1 \
    || { cat "$home/install.out" >&2; fail "install-boot failed"; }

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" start 2>&1) \
    || { printf '%s\n' "$out" >&2; cat "$FAKE_SYSTEMD_STATE/unit.log" 2>/dev/null >&2; fail "start did not bring up the unit-managed board"; }
  STARTED_PIDS+=("$(cat "$FAKE_SYSTEMD_STATE/main.pid" 2>/dev/null)")
  assert_contains "$out" "fm-dashboard.service" "start did not report that the unit brought the board up"
  assert_contains "$out" "api reachable at $url/api/health" \
    "start reported success without proving the API answers on the unit's address"
  assert_absent "$home/state/dashboard.pid" \
    "a unit-managed start wrote a pidfile, so two records now claim to own the board"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" server-status 2>&1)
  assert_contains "$out" "process: unit-managed by fm-dashboard.service (active, enabled)" \
    "server-status did not report the board as unit-managed with the unit's own state"
  assert_not_contains "$out" "no active pid recorded" \
    "server-status still reports a running unit-managed board as no pid recorded"
  assert_contains "$out" "api:     reachable at $url" "server-status did not report API reachability"
  assert_contains "$out" "lingering on" "server-status did not report whether the board comes up with the host"

  # A second start must refuse rather than race the unit for the port.
  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" start 2>&1) && fail "a second start against a live unit-managed board did not refuse"
  assert_contains "$out" "already running under the systemd user unit" \
    "the refusal did not say the unit already has the board running"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" restart 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "restart of a unit-managed board failed"; }
  STARTED_PIDS+=("$(cat "$FAKE_SYSTEMD_STATE/main.pid" 2>/dev/null)")
  assert_grep_line "stop fm-dashboard.service" "$FAKE_SYSTEMD_LOG" "restart did not stop the unit through the user manager"
  assert_contains "$out" "api reachable" "restart did not prove the board answers again"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" stop 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "stop of a unit-managed board failed"; }
  assert_contains "$out" "systemd user unit fm-dashboard.service" "stop did not report that it stopped the unit"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" server-status 2>&1)
  assert_contains "$out" "process: unit-managed by fm-dashboard.service (inactive, enabled)" \
    "server-status did not report the stopped unit-managed board with the unit's own state"

  pass "once the unit manages the home, start, stop, restart and server-status all speak for the unit"
}

test_restart_hands_a_hand_started_board_over_to_the_unit() {
  local home port url hand_pid out
  home=$(make_home handover-case)
  port=$(free_port) || fail "could not allocate a port"
  url="http://127.0.0.1:$port"
  printf '%s\n' "$url" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"

  # The board as it is today: started by hand, tracked only by its pidfile.
  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" start >"$home/hand-start.out" 2>&1 \
    || { cat "$home/hand-start.out" >&2; fail "the hand-started board did not come up"; }
  hand_pid=$(cat "$home/state/dashboard.pid")
  STARTED_PIDS+=("$hand_pid")

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" install-boot >"$home/install.out" 2>&1 \
    || { cat "$home/install.out" >&2; fail "install-boot failed while a board was already running"; }
  assert_contains "$(cat "$home/install.out")" "hand it over with: fm-dashboard.sh restart" \
    "install-boot did not say how to hand the running board over"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" server-status 2>&1)
  assert_contains "$out" "unit-managed by fm-dashboard.service" "server-status did not report the new unit"
  assert_contains "$out" "ALSO running from a pidfile (pid $hand_pid)" \
    "server-status hid the hand-started board the unit cannot bind behind"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" restart 2>&1) \
    || { printf '%s\n' "$out" >&2; cat "$FAKE_SYSTEMD_STATE/unit.log" 2>/dev/null >&2; fail "restart did not hand the board over to the unit"; }
  STARTED_PIDS+=("$(cat "$FAKE_SYSTEMD_STATE/main.pid" 2>/dev/null)")

  kill -0 "$hand_pid" 2>/dev/null && fail "restart left the hand-started board running behind the unit"
  assert_absent "$home/state/dashboard.pid" "restart left the hand-started board's pidfile behind"
  assert_contains "$out" "api reachable at $url/api/health" \
    "restart did not prove the unit-managed board answers on the same address"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" server-status 2>&1)
  assert_not_contains "$out" "ALSO running from a pidfile" "server-status still reports a hand-started board after the handover"
  assert_contains "$out" "api:     reachable at $url" "the board is not reachable after the handover"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" stop >/dev/null 2>&1 || fail "could not stop the handed-over board"

  pass "restart retires the hand-started board and hands its address to the unit, losing nothing"
}

test_a_unit_for_another_home_changes_nothing_here() {
  local other home port url pid out
  other=$(make_home other-home)
  home=$(make_home untouched-home)
  port=$(free_port) || fail "could not allocate a port"
  url="http://127.0.0.1:$port"
  printf '%s\n' "$url" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$other" "$DASH" install-boot >"$other/install.out" 2>&1 \
    || { cat "$other/install.out" >&2; fail "install-boot failed for the other home"; }

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" start >"$home/start.out" 2>&1 \
    || { cat "$home/start.out" >&2; fail "a home with no unit of its own could not start its board"; }
  pid=$(cat "$home/state/dashboard.pid")
  STARTED_PIDS+=("$pid")

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" server-status 2>&1)
  assert_contains "$out" "process: running (pid $pid)" \
    "a unit installed for another home hijacked this home's pidfile lifecycle"
  assert_not_contains "$out" "unit-managed" "this home reported itself unit-managed by another home's unit"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" install-boot 2>&1) \
    && fail "install-boot silently overwrote a unit that manages another home"
  assert_contains "$out" "$other" "the refusal did not name the home the installed unit manages"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" stop >/dev/null 2>&1 || fail "could not stop the pidfile-managed board"

  pass "a unit that names another home leaves this home's pidfile lifecycle exactly as it was"
}

test_uninstall_boot_returns_the_home_to_the_pidfile_lifecycle() {
  local home port url out pid
  home=$(make_home uninstall-case)
  port=$(free_port) || fail "could not allocate a port"
  url="http://127.0.0.1:$port"
  printf '%s\n' "$url" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" install-boot >"$home/install.out" 2>&1 \
    || { cat "$home/install.out" >&2; fail "install-boot failed"; }
  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" start >"$home/start.out" 2>&1 \
    || { cat "$home/start.out" >&2; fail "the unit-managed board did not start"; }
  STARTED_PIDS+=("$(cat "$FAKE_SYSTEMD_STATE/main.pid" 2>/dev/null)")

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" uninstall-boot 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "uninstall-boot failed"; }
  assert_absent "$UNIT" "uninstall-boot left the unit file behind"
  assert_grep_line "stop fm-dashboard.service" "$FAKE_SYSTEMD_LOG" \
    "uninstall-boot removed a unit that was still supervising a running board"
  assert_grep_line "disable fm-dashboard.service" "$FAKE_SYSTEMD_LOG" "uninstall-boot did not disable the unit"
  assert_present "$FAKE_SYSTEMD_STATE/linger" "uninstall-boot turned off lingering other user units depend on"

  # Back to the pidfile lifecycle, on the same address.
  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" start >"$home/restart.out" 2>&1 \
    || { cat "$home/restart.out" >&2; fail "the home could not start its board again after uninstall-boot"; }
  pid=$(cat "$home/state/dashboard.pid")
  STARTED_PIDS+=("$pid")
  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" server-status 2>&1)
  assert_contains "$out" "process: running (pid $pid)" "server-status did not return to the pidfile lifecycle"
  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home" "$DASH" stop >/dev/null 2>&1 || fail "could not stop the board after uninstall-boot"

  pass "uninstall-boot stops, disables and removes the unit, and the home goes back to the pidfile lifecycle"
}

test_install_boot_refuses_a_linked_worktree_home() {
  local worktree primary checkout out
  worktree=$(make_home task-worktree)
  primary="$TMP_ROOT/primary-checkout"
  printf 'gitdir: %s/.git/worktrees/task-worktree\n' "$primary" >"$worktree/.git"
  reset_fake_systemd
  rm -f "$UNIT"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT=8420 \
    FM_HOME="$worktree" "$DASH" install-boot 2>&1) \
    && fail "install-boot pinned the unit to a linked worktree that will be deleted out from under it"
  assert_contains "$out" "$worktree" "the refusal did not name the worktree home it resolved"
  assert_contains "$out" "FM_HOME=$primary fm-dashboard.sh install-boot" \
    "the refusal did not name the primary checkout to pass as FM_HOME"
  assert_absent "$UNIT" "install-boot wrote a unit file before refusing"
  assert_no_grep "enable fm-dashboard.service" "$FAKE_SYSTEMD_LOG" "install-boot enabled a unit it refused to install"

  # A primary checkout's .git is a directory, and a home that is no git checkout
  # at all has none: both install.
  checkout=$(make_home primary-style)
  mkdir -p "$checkout/.git"
  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT=8420 \
    FM_HOME="$checkout" "$DASH" install-boot 2>&1) \
    || { printf '%s\n' "$out" >&2; fail "install-boot refused a primary checkout whose .git is a directory"; }
  assert_grep_line "Environment=\"FM_HOME=$checkout\"" "$UNIT" "the unit does not record the primary checkout"

  pass "install-boot refuses a linked worktree home and names the primary checkout to pass, leaving real checkouts and plain homes alone"
}

test_one_home_under_two_spellings_is_still_the_units_home() {
  local home alias port url out
  home=$(make_home "odd home %d")
  alias="$TMP_ROOT/alias-home"
  ln -s "$home" "$alias"
  port=$(free_port) || fail "could not allocate a port"
  url="http://127.0.0.1:$port"
  printf '%s\n' "$url" >"$home/config/dashboard-url"
  reset_fake_systemd
  rm -f "$UNIT"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$home/" "$DASH" install-boot >"$home/install.out" 2>&1 \
    || { cat "$home/install.out" >&2; fail "install-boot failed for a home spelled with a trailing slash"; }
  assert_grep_line "Environment=\"FM_HOME=${home//%/%%}\"" "$UNIT" \
    "the unit did not record the home's one physical path as a systemd-quoted word"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$alias" "$DASH" start 2>&1) \
    || { printf '%s\n' "$out" >&2; cat "$FAKE_SYSTEMD_STATE/unit.log" 2>/dev/null >&2; fail "start through a symlinked spelling of the unit's home failed"; }
  STARTED_PIDS+=("$(cat "$FAKE_SYSTEMD_STATE/main.pid" 2>/dev/null)")
  assert_contains "$out" "started by fm-dashboard.service" \
    "start through another spelling of the home launched a pidfile server beside the unit"
  assert_absent "$home/state/dashboard.pid" "a second spelling of the unit's home got its own pidfile"
  assert_contains "$out" "api reachable at $url/api/health" \
    "the unit-managed board did not answer on the address recorded for a home with a space and a percent sign"

  out=$(env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$alias/" "$DASH" server-status 2>&1)
  assert_contains "$out" "process: unit-managed by fm-dashboard.service (active, enabled)" \
    "server-status under another spelling of the home did not see the unit"
  assert_present "$home/data/dashboard.db" "the unit-managed server did not open the database recorded for the home"

  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$alias" "$DASH" stop >/dev/null 2>&1 || fail "could not stop the unit-managed board through the alias spelling"
  env -u FM_DASHBOARD_HOST -u FM_DASHBOARD_DB FM_DASHBOARD_PORT="$port" \
    FM_HOME="$alias" "$DASH" uninstall-boot >/dev/null 2>&1 \
    || fail "uninstall-boot through another spelling of the unit's home refused"
  assert_absent "$UNIT" "uninstall-boot left the unit behind"

  pass "a trailing slash, a symlink, a space or a percent sign in the home never splits it from its own unit"
}

test_install_boot_writes_and_enables_the_unit
test_install_boot_refuses_a_linked_worktree_home
test_one_home_under_two_spellings_is_still_the_units_home
test_install_boot_prints_the_command_when_lingering_needs_privileges
test_unit_managed_lifecycle_is_coherent
test_restart_hands_a_hand_started_board_over_to_the_unit
test_a_unit_for_another_home_changes_nothing_here
test_uninstall_boot_returns_the_home_to_the_pidfile_lifecycle
