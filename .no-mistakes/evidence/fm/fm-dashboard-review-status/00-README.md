# Testing/review split — end-to-end evidence

A real `bin/fm-dashboard.sh` server was started against a seeded **pre-split**
SQLite database (3 `testing` cards plus one card in each other status), then
driven exactly the way an agent, the fleet auditor, and the Admiral's phone
drive it: the CLI, the HTTP API, the fleet-auditor sweep, and the rendered
board in Chrome.

| File | What it shows |
|---|---|
| `01-migration-startup.txt` | `fm-dashboard.sh start` against a pre-split DB; the server's startup report names the 3 cards it rewrote. |
| `02-migrated-state-and-audit-trail.txt` | Persisted state after migration: 3 cards now `review`, each with a single `testing -> review` `status_history` entry carrying the reason, and `updated_at` untouched. |
| `03-cli-and-api-accept-both.txt` | CLI and HTTP API accept and store both `testing` and `review`; an invented status is refused by both (CLI exit 1, API HTTP 400). |
| `04-restart-idempotence.txt` | A live `restart` does **not** re-run the migration; a genuinely in-flight `testing` card stays `testing`. No card carries a status the web bundle cannot render. |
| `05-auditor-sweep.txt` | The auditor flags a `testing` card whose linked crew reads `blocked`, flags none of the 4 `review` cards, and produces no finding once a live crew is behind the same testing card. |
| `06-board-review-and-testing.png` | The rendered board at phone width: `Testing (1)` and `Review (4)` chips in order, distinct colours, `Mark Complete` only on `review` cards. |
| `07-filter-review.png` | The `Review` filter chip active — the 4 awaiting-him cards, each with `Mark Complete`, still showing their original ages (4d/5d/6d) because the migration left `updated_at` alone. |
| `08-filter-testing.png` | The `Testing` filter chip active — the one in-flight card, with the auditor's discrepancy for it visible in the Discrepancy Log below. |
| `09-card-overlay-status-dropdown.png` | A `testing` card's overlay: the status dropdown offers all eight statuses including `Review`, and a `testing` card gets no `Mark Complete`. |
| `10-mark-complete-from-review.png` | After clicking `Mark Complete` on the migrated "Re-rig the mainsail halyard" card in the browser: `Review (4) -> (3)`, `Complete (1) -> (2)`, and the API confirms `review -> complete` persisted. |
