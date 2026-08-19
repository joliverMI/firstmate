# Evidence: tmux endpoint liveness no longer reports dead targets as alive

All artifacts below were produced against a **real tmux 3.4 server** on an
isolated private socket (`tmux -L`), comparing the base commit `3c8f796`
("BEFORE") with the target commit `e382d0c` ("AFTER") on the same live server.

| file | what it shows |
| --- | --- |
| `tmux-probe-before-after.txt` | The probe's verdict for 13 real targets, run from inside a live tmux pane. BEFORE answered **alive for all 13**, including six that do not exist. AFTER answers all 13 correctly. |
| `tmux-steer-misdelivery.txt` | An ordinary steer addressed to a crew whose window is gone. BEFORE it was typed into a live sibling crew's pane and executed there. AFTER the send is refused, and the sibling pane is untouched. |
| `fm-session-start-endpoints.txt` | The session-start fleet digest's `endpoint:` lines. BEFORE every record read `alive`. AFTER: `dead` for the gone window, `alive` for the live one, `unknown (remote ...; not checked from here)` for the remote secondmate. |
| `fm-crew-state-before-after.txt` | `fm-crew-state.sh`, the line firstmate reads every heartbeat. BEFORE a dead crew was read off the wrong pane; AFTER it reports `backend target gone`. The remote secondmate still reports `state: working - source: status-log` either way, and the file shows why the local probe must be skipped for it. |
| `tmux-smoke-before-fix.log` / `tmux-smoke-after-fix.log` | The repository's real-tmux regression suite `tests/fm-backend-tmux-smoke.test.sh`, run against pre-fix code (fails at the first liveness assertion, `LIVENESS-RESULT:EXISTS`) and against the fix (48 assertions pass). |

## Re-verification at the final commit `27b3073`

The table above compares `3c8f796` with `e382d0c`. `27b3073` adds a `list-panes`
arm to the shared secondmate fake tmux (`tests/secondmate-helpers.sh`); the
artifacts below re-run the same real-tmux comparison against that final tip.

| file | what it shows |
| --- | --- |
| `reverify-27b3073-operator-surfaces.txt` | One transcript covering all three layers against a live tmux 3.4 server: (1) raw `display-message` exiting 0 for every target including nonexistent ones, and resolving `fm:fm-design` to the live sibling `fm-designer`'s pane `%1`; (2) the session-start briefing's `endpoint:` verdicts — BEFORE all three records read `alive`, AFTER they read `alive` / `dead` / `unknown (remote build-box; not checked from here)`; (3) `fm-crew-state.sh` for a dead secondmate whose status log still says `working` — BEFORE `state: working · source: status-log`, AFTER `state: unknown · source: none · backend target gone`. |
| `reverify-27b3073-tmux-smoke.log` | `bin/fm-test-run.sh tests/fm-backend-tmux-smoke.test.sh` at `27b3073`: 48 real-tmux assertions, exit 0. |
| `session-start-endpoint-digest-demo.sh`, `crew-state-liveness-demo.sh` | Self-contained reproducers for the two operator surfaces. Each takes `<repo-tree> <label>`, spins up its own private tmux socket, and prints the transcript; run once against a base checkout and once against this branch. |
