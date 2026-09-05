"""Durable SQLite persistence for the Admiral's Fleet Dashboard.

One task = one card. Every mutation goes through this module so the schema
stays the single owner of the board's shape. No table here mirrors any
fleet backlog; the board owns its own records deliberately (see docs/dashboard.md
"Why the board owns its own records" for the drift-risk tradeoff this implies).
"""

from __future__ import annotations

import calendar
import json
import os
import random
import re
import sqlite3
import string
import threading
import time
from contextlib import contextmanager

# Sort order IS this order: the page, the API's `--sort status`, and the
# board's own sections all read it left to right. `needs_action` leads
# because it is the only status nothing can clear but him doing a thing -
# `needs_review` costs him one tap from wherever he is standing, so a board
# that put it first would rank the cheaper ask above the one that is
# genuinely holding work up. See docs/dashboard.md "Why `needs-action` and
# `needs-review` are two statuses".
STATUSES = (
    "needs_action",
    "needs_review",
    "not_started",
    "working",
    "paused",
    "waiting",
    "testing",
    "review",
    "complete",
)

# `needs_attention` was split into the two statuses above. It is still
# accepted as an INPUT spelling everywhere a status is read - an older
# script, an agent working from an older copy of the doctrine - and always
# means `needs_action`, which is where every existing card of that status
# was migrated. It is never emitted: no card carries it, no response
# contains it, and it is not in STATUSES, so it cannot be filtered for or
# sorted by under its old name. Old `status_history` rows keep it, because
# those record what the board actually said at the time.
DEPRECATED_STATUS_ALIASES = {"needs_attention": "needs_action"}


def canonical_status(status: str | None) -> str | None:
    """The stored spelling for a status a caller supplied, alias included."""
    if status is None:
        return None
    return DEPRECATED_STATUS_ALIASES.get(status, status)


def normalized_plan(plan: str | None) -> str | None:
    """The one normalization a plan gets, applied on every write path.

    The approval binding compares the plan he approved against the plan the
    card carries, character for character. That comparison is only honest if
    both sides were normalized the same way and only once: a plan stored with
    surrounding whitespace but approved as the surface displayed it would be
    permanently approved-and-stale, with two identical-looking texts on the
    card and no way back. So every writer routes the plan through here, and
    every comparison downstream stays exact.
    """
    plan = (plan or "").strip()
    return plan or None


# The two statuses that mean the Admiral himself is the next step. Both sort
# above everything else and both are what the auditor's age check is for.
BLOCKING_STATUSES = ("needs_action", "needs_review")

# The captain set is NOT written here. web/captains.json is its only copy; the
# shell wrapper and the browser read that same file, so a captain added there
# is live in all three at once. Read once at import: the manifest ships with
# the code and changing it means restarting the server anyway.
CAPTAINS_MANIFEST = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web", "captains.json"
)


def _load_captains(path: str = CAPTAINS_MANIFEST) -> tuple[str, ...]:
    """Captain ids in display order, straight from the manifest.

    Refuses to start on a missing or malformed manifest rather than falling
    back to a built-in list: a silent fallback is exactly the second copy this
    file exists to avoid, and it would mislabel cards instead of stopping.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    ids = tuple(str(c["id"]) for c in data["captains"])
    if not ids:
        raise ValueError(f"{path}: no captains defined")
    return ids


CAPTAINS = _load_captains()
NOTE_TABS = ("interpretation", "communication", "needs")
NOTE_AUTHORS = ("agent", "firstmate", "admiral")

SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  agent TEXT NOT NULL DEFAULT '',
  captain TEXT NOT NULL,
  status TEXT NOT NULL,
  waiting_on_id TEXT,
  waiting_reason TEXT,
  needs_action_reason TEXT,
  review_plan TEXT,
  plan_approved_at TEXT,
  plan_approved_text TEXT,
  review_plan_updated_at TEXT,
  starred INTEGER NOT NULL DEFAULT 0,
  backlog_ref TEXT,
  initial_prompt TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL REFERENCES tasks(id),
  tab TEXT NOT NULL,
  author TEXT NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  link_url TEXT,
  link_label TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_task ON notes(task_id);

CREATE TABLE IF NOT EXISTS status_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL REFERENCES tasks(id),
  from_status TEXT,
  to_status TEXT NOT NULL,
  changed_at TEXT NOT NULL,
  note TEXT
);
CREATE INDEX IF NOT EXISTS idx_history_task ON status_history(task_id);

CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  key TEXT,
  occurrences INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  last_seen_at TEXT
);

CREATE TABLE IF NOT EXISTS audit_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT,
  completed_at TEXT NOT NULL,
  duration_seconds REAL NOT NULL,
  tasks_checked INTEGER NOT NULL,
  discrepancies_found INTEGER NOT NULL DEFAULT 0,
  forced INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""

DEFAULT_AUDIT_INTERVAL_MINUTES = 15

# Columns added after the initial schema. CREATE TABLE IF NOT EXISTS leaves an
# already-created table untouched, so a database created before a column
# existed needs it added explicitly - this keeps existing cards and their
# history intact instead of requiring a fresh database.
# `needs_action_reason` is the same column `needs_attention_reason` was, under
# the name the status now has; _rename_needs_attention_reason below renames it
# in place on an older database, so it is already present by the time this list
# is consulted and nothing here re-adds an empty second copy of it.
#
# review_plan holds the recommended action a `needs_review` card is asking him
# to approve. plan_approved_at/plan_approved_text hold his approval and the
# EXACT plan text that was on the card when he gave it - two columns, not one
# flag, because an approval is only worth anything against the wording he
# actually read (see approve_plan).
# review_plan_updated_at dates the wording itself: when the plan he is being
# asked about last CHANGED, which is when the question changed. It is what
# lets a reader tell a new ask from a card that has merely been touched, and
# `updated_at` cannot do that job - a note, a title edit, or an approval moves
# `updated_at` without changing anything he is being asked (see set_review_plan
# and the auditor's newest-ask timestamp in bin/fm-fleet-audit-sweep.sh).
_TASK_COLUMN_MIGRATIONS = (
    ("needs_action_reason", "TEXT"),
    ("review_plan", "TEXT"),
    ("plan_approved_at", "TEXT"),
    ("plan_approved_text", "TEXT"),
    ("review_plan_updated_at", "TEXT"),
)

_AUDIT_RUN_COLUMN_MIGRATIONS = (
    ("forced", "INTEGER NOT NULL DEFAULT 0"),
)

# key/occurrences/last_seen_at back a database created before the general
# collapse mechanism existed (see record_audit_finding). last_seen_at has no
# SQL default because it must mirror each existing row's own created_at, not
# a single fixed value, so it needs the one-time backfill below rather than a
# column DEFAULT.
_AUDIT_LOG_COLUMN_MIGRATIONS = (
    ("key", "TEXT"),
    ("occurrences", "INTEGER NOT NULL DEFAULT 1"),
    ("last_seen_at", "TEXT"),
)

# Settings keys used for the auditor's own liveness, distinct from the
# audit_runs history. A tick is recorded on every timer invocation, whether or
# not it decided a sweep was due, so a dead timer becomes a stale heartbeat
# rather than a silently-aging "last run" that could still look recent. The
# sweep lock is single-row state (not a table) for the same reason: one
# auditor sweep at a time, no queue, claimed and released through ordinary
# settings reads/writes under the existing write lock.
SETTING_LAST_TICK_AT = "audit_last_tick_at"
SETTING_SWEEP_RUNNING = "audit_sweep_running"
SETTING_SWEEP_STARTED_AT = "audit_sweep_started_at"
SETTING_SWEEP_FORCED = "audit_sweep_forced"

# Marks the one-time split of the old `testing` status - which had meant
# "done, and ready for him to look at" - into `testing` (the fleet is
# actively exercising it right now) and `review` (done, with nothing left
# for him to do but look if he feels like it).
# Every card in `testing` the first time this code runs against a database
# means the old thing: no earlier code could have set the new meaning, since
# it did not exist yet. This must therefore fire at most once, before the
# server accepts its first request, or a genuinely in-flight `testing` card
# created after the split would be wrongly rewritten to `review` on the next
# restart.
SETTING_TESTING_REVIEW_SPLIT_MIGRATED = "migrated_testing_review_split_v1"

# Marks the one-time split of `needs_attention` into `needs_action` (he has to
# do a thing himself) and `needs_review` (the fleet is proposing an action and
# asking him to approve it). Every existing `needs_attention` card migrates to
# `needs_action`, never to `needs_review`: a `needs_review` card must carry a
# recommended-plan summary, and no pre-split card has one, so routing any of
# them the other way would mean inventing a recommendation the fleet never
# actually made. Gated by this marker for the same reason the testing/review
# split is, though the guard is weaker here by construction: nothing can write
# `needs_attention` after the split, so a second run would find nothing to do
# anyway.
SETTING_NEEDS_ATTENTION_SPLIT_MIGRATED = "migrated_needs_attention_split_v1"

# A claimed sweep that has not released itself within this long is treated as
# abandoned (crashed subprocess, killed server) rather than left stuck forever
# refusing every future tick and button press. Overridable so a test can prove
# the reclaim path without a real 10-minute wait.
MAX_SWEEP_SECONDS = int(os.environ.get("FM_AUDIT_MAX_SWEEP_SECONDS", "600"))

_write_lock = threading.Lock()


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _iso_to_epoch(iso: str) -> float:
    return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))


class PlanChangedError(ValueError):
    """The plan moved between what he was shown and what he approved.

    A distinct type so the HTTP layer can answer 409 on the fact rather than
    on the wording of the message - the page's re-approve flow keys off that
    status code, and a reworded sentence must never be able to change it.
    """


class Store:
    def __init__(self, db_path: str):
        self.db_path = db_path
        directory = os.path.dirname(os.path.abspath(db_path))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(SCHEMA)
            self._rename_needs_attention_reason(conn)
            existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(tasks)")}
            for name, coltype in _TASK_COLUMN_MIGRATIONS:
                if name not in existing_columns:
                    conn.execute(f"ALTER TABLE tasks ADD COLUMN {name} {coltype}")
            existing_run_columns = {row[1] for row in conn.execute("PRAGMA table_info(audit_runs)")}
            for name, coltype in _AUDIT_RUN_COLUMN_MIGRATIONS:
                if name not in existing_run_columns:
                    conn.execute(f"ALTER TABLE audit_runs ADD COLUMN {name} {coltype}")
            existing_log_columns = {row[1] for row in conn.execute("PRAGMA table_info(audit_log)")}
            for name, coltype in _AUDIT_LOG_COLUMN_MIGRATIONS:
                if name not in existing_log_columns:
                    conn.execute(f"ALTER TABLE audit_log ADD COLUMN {name} {coltype}")
            conn.execute("UPDATE audit_log SET last_seen_at = created_at WHERE last_seen_at IS NULL")
            conn.execute(
                "INSERT OR IGNORE INTO settings(key, value) VALUES ('audit_interval_minutes', ?)",
                (str(DEFAULT_AUDIT_INTERVAL_MINUTES),),
            )
            migrated = self._migrate_testing_to_review(conn)
            split = self._migrate_needs_attention_to_needs_action(conn)
        if migrated:
            print(
                f"dashboard: migrated {len(migrated)} card(s) from testing to review "
                f"(testing/review split): {', '.join(migrated)}"
            )
        if split:
            print(
                f"dashboard: migrated {len(split)} card(s) from needs_attention to "
                f"needs_action (needs-action/needs-review split): {', '.join(split)}"
            )

    # Accepted tradeoff, not an oversight: a phone tab already open across a
    # server restart keeps the pre-migration app.js in memory, so a migrated
    # card can transiently render without its Mark Complete action and with the
    # status dropdown falling back to that old bundle's first option until the
    # page is reloaded. Non-destructive and self-clearing on reload, so it is
    # handled operationally (tell the Admiral to refresh after a deploy) rather
    # than by adding a cache-busting/versioning surface to the board.
    # Deliberately leaves updated_at alone: it means when the Admiral's work
    # last actually changed, not when a script touched the row, so a mechanical
    # relabel must not float a dozen finished cards to the top of his default
    # updated-desc sort. The status_history row and the startup report below are
    # the migration's record that it ran.
    def _migrate_testing_to_review(self, conn: sqlite3.Connection) -> list[str]:
        """One-time split of the old `testing` meaning into `testing` (live
        fleet activity) and `review` (done, with nothing left for him to do
        but look if he feels like it).
        Gated by SETTING_TESTING_REVIEW_SPLIT_MIGRATED so it can only ever
        rewrite the cards that meant the old thing, never a later, genuinely
        in-flight `testing` card. Returns the migrated task ids so the caller
        can report exactly what changed.
        """
        already = conn.execute(
            "SELECT 1 FROM settings WHERE key = ?", (SETTING_TESTING_REVIEW_SPLIT_MIGRATED,)
        ).fetchone()
        if already is not None:
            return []
        ids = [row[0] for row in conn.execute("SELECT id FROM tasks WHERE status = 'testing'")]
        if ids:
            ts = now_iso()
            conn.executemany(
                "UPDATE tasks SET status = 'review' WHERE id = ?",
                [(task_id,) for task_id in ids],
            )
            conn.executemany(
                """INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)
                   VALUES (?, 'testing', 'review', ?, ?)""",
                [
                    (task_id, ts, "migrated: testing/review split - this card meant ready for his review")
                    for task_id in ids
                ],
            )
        conn.execute(
            "INSERT OR IGNORE INTO settings(key, value) VALUES (?, '1')",
            (SETTING_TESTING_REVIEW_SPLIT_MIGRATED,),
        )
        return ids

    # A database created before the needs-action/needs-review split holds the
    # ask in a column named for the status that no longer exists. Renamed in
    # place rather than added-and-copied: the two would be one column's data
    # under two names, and the loser would silently start collecting the
    # writes while every reader still read the winner. Guarded on the columns
    # actually present so it is a no-op on a fresh database (where SCHEMA
    # already created the new name) and on an already-renamed one.
    def _rename_needs_attention_reason(self, conn: sqlite3.Connection) -> None:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(tasks)")}
        if "needs_attention_reason" in columns and "needs_action_reason" not in columns:
            conn.execute(
                "ALTER TABLE tasks RENAME COLUMN needs_attention_reason TO needs_action_reason"
            )

    # Deliberately leaves updated_at alone, for the same reason the
    # testing/review migration above does: it means when his work last
    # actually changed, not when a script relabelled it, and floating a dozen
    # blocked cards to the top of his default sort would be a mechanical
    # relabel pretending to be news.
    #
    # Deliberately leaves status_history alone too, which is the more
    # load-bearing of the two. Writing a needs_attention -> needs_action row
    # per card would reset every one of their ages to this restart, and the
    # auditor's age check reads exactly that timestamp - a card he has been
    # sitting on since Tuesday would read as flagged one minute ago, and the
    # one finding that catches an ask that never reached him would go quiet
    # across the whole board. Rewriting the old rows in place instead would
    # falsify them: the board really did say `needs_attention` then. So the
    # rows stay as they are, `needs_attention` keeps its meaning as a readable
    # historical spelling, and every reader of that timestamp accepts both
    # spellings (bin/fm-fleet-audit-sweep.sh's check 5 does). The record that
    # this migration ran is the settings marker and the startup line naming
    # every card it moved.
    def _migrate_needs_attention_to_needs_action(self, conn: sqlite3.Connection) -> list[str]:
        """One-time move of every `needs_attention` card to `needs_action`.

        Never to `needs_review`: that status requires a recommended-plan
        summary, and no pre-split card has one. Returns the migrated ids so
        the caller can report exactly what changed.
        """
        already = conn.execute(
            "SELECT 1 FROM settings WHERE key = ?", (SETTING_NEEDS_ATTENTION_SPLIT_MIGRATED,)
        ).fetchone()
        if already is not None:
            return []
        ids = [row[0] for row in conn.execute("SELECT id FROM tasks WHERE status = 'needs_attention'")]
        if ids:
            conn.executemany(
                "UPDATE tasks SET status = 'needs_action' WHERE id = ?",
                [(task_id,) for task_id in ids],
            )
        conn.execute(
            "INSERT OR IGNORE INTO settings(key, value) VALUES (?, '1')",
            (SETTING_NEEDS_ATTENTION_SPLIT_MIGRATED,),
        )
        return ids

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    @contextmanager
    def _cursor(self, write: bool = False):
        if write:
            _write_lock.acquire()
        conn = self._connect()
        try:
            cur = conn.cursor()
            yield cur
            if write:
                conn.commit()
        finally:
            conn.close()
            if write:
                _write_lock.release()

    # ---- id generation ----

    def _slug(self, title: str) -> str:
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        return slug[:40] or "task"

    def _new_id(self, cur: sqlite3.Cursor, title: str) -> str:
        base = self._slug(title)
        for _ in range(20):
            suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=4))
            candidate = f"{base}-{suffix}"
            cur.execute("SELECT 1 FROM tasks WHERE id = ?", (candidate,))
            if cur.fetchone() is None:
                return candidate
        raise RuntimeError("could not allocate a unique task id")

    # ---- tasks ----

    def add_task(
        self,
        title: str,
        captain: str,
        initial_prompt: str,
        agent: str = "",
        status: str = "not_started",
        backlog_ref: str | None = None,
        needs_action_reason: str | None = None,
        review_plan: str | None = None,
    ) -> dict:
        if captain not in CAPTAINS:
            raise ValueError(f"unknown captain: {captain!r}")
        status = canonical_status(status)
        if status not in STATUSES:
            raise ValueError(f"unknown status: {status!r}")
        # Mirrors set_status: the reason column is only ever populated for
        # the status it belongs to, so a later transition away from
        # needs_action can't leave a stale reason rendering on the card.
        needs_action_reason = needs_action_reason if status == "needs_action" else None
        # The plan is NOT scoped that way - see set_status for why a card that
        # leaves needs_review keeps its plan and its approval.
        review_plan = normalized_plan(review_plan)
        if status == "needs_review" and review_plan is None:
            raise ValueError(
                "needs_review requires a recommended-plan summary - an approval box "
                "with nothing in it is exactly what this status exists to prevent"
            )
        if status != "needs_review" and review_plan is not None:
            raise ValueError(
                "a recommended plan can only be created by starting the card at "
                f"needs_review - a plan on a {status} card renders no approval box, so it "
                "would be a recommendation he is never actually shown or able to accept"
            )
        ts = now_iso()
        with self._cursor(write=True) as cur:
            task_id = self._new_id(cur, title)
            cur.execute(
                """INSERT INTO tasks
                   (id, title, agent, captain, status, waiting_on_id, waiting_reason,
                    needs_action_reason, review_plan, plan_approved_at, plan_approved_text,
                    review_plan_updated_at, starred, backlog_ref, initial_prompt,
                    created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, NULL, NULL, ?, 0, ?, ?, ?, ?)""",
                (task_id, title, agent, captain, status, needs_action_reason, review_plan,
                 ts if review_plan else None, backlog_ref, initial_prompt, ts, ts),
            )
            cur.execute(
                """INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)
                   VALUES (?, NULL, ?, ?, 'created')""",
                (task_id, status, ts),
            )
        return self.get_task(task_id)

    # Derived on the way out rather than stored, so it can never disagree with
    # the two columns it is derived from. `plan_approved` says he approved
    # something; `plan_approval_stale` says the plan has been edited since,
    # so what he approved is NOT what the card now displays. A reader that
    # only checks `plan_approved` and acts is acting on authority it does not
    # have, which is why the stale flag travels beside it everywhere, in
    # `show`, in --json, and on the page.
    @staticmethod
    def _with_approval_state(task: dict) -> dict:
        approved_at = task.get("plan_approved_at")
        approved_text = task.get("plan_approved_text")
        task["plan_approved"] = bool(approved_at)
        task["plan_approval_stale"] = bool(approved_at) and approved_text != task.get("review_plan")
        return task

    # A plan may only be CREATED through the path that also puts the approval
    # box in front of him, because a plan he is never shown is a
    # recommendation nobody can accept - `show` would print "recommended
    # plan:" on a card that renders no button. That is a rule about creation
    # and not about where a plan may live: a plan and its approval
    # deliberately outlive the card's status (see set_status), so a card that
    # has left needs_review still accepts a correction to the wording the
    # fleet is acting under. So the refusal is exactly this narrow - a card
    # that has NEVER been needs_review and carries no plan - and it is decided
    # from the card's own status history rather than its current status, which
    # says nothing about the doors the card has already been through.
    @staticmethod
    def _guard_plan_creation(task: dict) -> None:
        if task.get("review_plan"):
            return
        if any(row.get("to_status") == "needs_review"
               for row in task.get("status_history") or ()):
            return
        raise ValueError(
            "a recommended plan can only be created by moving the card to needs_review - "
            "this card has never been needs_review and carries no plan, so nothing would "
            "show him an approval box for the plan being written"
        )

    def get_task(self, task_id: str) -> dict | None:
        with self._cursor() as cur:
            cur.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
            row = cur.fetchone()
            if row is None:
                return None
            task = self._with_approval_state(dict(row))
            cur.execute(
                "SELECT * FROM notes WHERE task_id = ? ORDER BY created_at ASC, id ASC",
                (task_id,),
            )
            task["notes"] = [dict(r) for r in cur.fetchall()]
            cur.execute(
                "SELECT * FROM status_history WHERE task_id = ? ORDER BY changed_at ASC, id ASC",
                (task_id,),
            )
            task["status_history"] = [dict(r) for r in cur.fetchall()]
        return task

    def list_tasks(self, status: str | None = None, captain: str | None = None,
                    starred: bool | None = None) -> list[dict]:
        query = "SELECT * FROM tasks WHERE 1=1"
        params: list = []
        if status:
            query += " AND status = ?"
            params.append(canonical_status(status))
        if captain:
            query += " AND captain = ?"
            params.append(captain)
        if starred is not None:
            query += " AND starred = ?"
            params.append(1 if starred else 0)
        query += " ORDER BY updated_at DESC"
        with self._cursor() as cur:
            cur.execute(query, params)
            return [self._with_approval_state(dict(r)) for r in cur.fetchall()]

    def task_exists(self, task_id: str) -> bool:
        with self._cursor() as cur:
            cur.execute("SELECT 1 FROM tasks WHERE id = ?", (task_id,))
            return cur.fetchone() is not None

    def update_task(self, task_id: str, **fields) -> dict:
        if not self.task_exists(task_id):
            raise KeyError(task_id)
        allowed = {"title", "agent", "captain", "backlog_ref", "starred"}
        sets, params = [], []
        for key, value in fields.items():
            if key not in allowed:
                raise ValueError(f"cannot update field: {key!r}")
            if key == "captain" and value not in CAPTAINS:
                raise ValueError(f"unknown captain: {value!r}")
            sets.append(f"{key} = ?")
            params.append(int(value) if key == "starred" else value)
        if not sets:
            return self.get_task(task_id)
        sets.append("updated_at = ?")
        params.append(now_iso())
        params.append(task_id)
        with self._cursor(write=True) as cur:
            cur.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE id = ?", params)
        return self.get_task(task_id)

    def set_status(self, task_id: str, status: str, waiting_on_id: str | None = None,
                    reason: str | None = None, review_plan: str | None = None) -> dict:
        status = canonical_status(status)
        if status not in STATUSES:
            raise ValueError(f"unknown status: {status!r}")
        current = self.get_task(task_id)
        if current is None:
            raise KeyError(task_id)
        if waiting_on_id and not self.task_exists(waiting_on_id):
            raise ValueError(f"waiting_on_id does not exist: {waiting_on_id!r}")
        # `reason` is repurposed per status: what a card is waiting on for
        # `waiting`, what is being asked of him for `needs_action`. The two
        # are mutually exclusive, so only the active status's column is kept.
        waiting_reason = reason if status == "waiting" else None
        needs_action_reason = reason if status == "needs_action" else None
        if status != "waiting":
            waiting_on_id = None
        # A move into needs_review needs a plan, either supplied by this call
        # or already on the card; refuse rather than park him in front of an
        # approval box with nothing to approve.
        next_plan = normalized_plan(review_plan) or normalized_plan(current.get("review_plan"))
        if status == "needs_review" and next_plan is None:
            raise ValueError(
                "needs_review requires a recommended-plan summary - an approval box "
                "with nothing in it is exactly what this status exists to prevent"
            )
        # The plan and his approval deliberately do NOT clear when the card
        # leaves needs_review, unlike the two reason columns above. Those are
        # scoped to their status because a stale one renders as a live ask;
        # an approval is the opposite kind of record - it is the Admiral's own
        # word about what the fleet may do, and work happens AFTER he gives
        # it, so destroying it the moment the card advances would erase the
        # authority the fleet is acting under exactly when it starts acting.
        # It is kept, and kept bound to its own wording: if the plan is later
        # edited, _with_approval_state marks the approval stale rather than
        # letting it drift onto text he never read.
        if next_plan is not None and status != "needs_review":
            self._guard_plan_creation(current)
        ts = now_iso()
        # A status write that changes the plan changes the question, so it
        # dates the wording too; one that leaves the plan alone must not, or
        # every unrelated status change would read as a fresh ask.
        plan_changed_at = (
            ts if next_plan != current.get("review_plan")
            else current.get("review_plan_updated_at")
        )
        with self._cursor(write=True) as cur:
            cur.execute(
                """UPDATE tasks SET status = ?, waiting_on_id = ?, waiting_reason = ?,
                   needs_action_reason = ?, review_plan = ?, review_plan_updated_at = ?,
                   updated_at = ? WHERE id = ?""",
                (status, waiting_on_id, waiting_reason, needs_action_reason, next_plan,
                 plan_changed_at, ts, task_id),
            )
            cur.execute(
                """INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)
                   VALUES (?, ?, ?, ?, ?)""",
                (task_id, current["status"], status, ts, reason),
            )
        return self.get_task(task_id)

    def set_review_plan(self, task_id: str, plan: str) -> dict:
        """Write the recommended-plan summary a needs_review card asks him to approve.

        Editing the plan does not delete an approval he already gave - that
        record is his word and is never silently thrown away - but it does
        break the binding, because the approval was for the old wording.
        _with_approval_state then reports the card as approved AND stale, the
        card shows both texts, and the approve button comes back. Nothing
        here decides that: it falls out of the two columns disagreeing.

        Replacing the wording also dates it in `review_plan_updated_at`, which
        is the durable mark that says the ask itself changed here. Without it
        the only trace of a plan edit is `updated_at`, and the auditor reading
        that could not tell a new question from a note being added - so a
        reply he gave to the OLD plan would go on silencing a card that now
        asks him something he has never seen. Re-writing the same text is not
        a new question and deliberately leaves the date where it was.
        """
        plan = normalized_plan(plan)
        if plan is None:
            raise ValueError("a recommended-plan summary cannot be empty")
        current = self.get_task(task_id)
        if current is None:
            raise KeyError(task_id)
        self._guard_plan_creation(current)
        ts = now_iso()
        plan_changed_at = (
            ts if plan != current.get("review_plan")
            else current.get("review_plan_updated_at")
        )
        with self._cursor(write=True) as cur:
            cur.execute(
                "UPDATE tasks SET review_plan = ?, review_plan_updated_at = ?, updated_at = ? "
                "WHERE id = ?",
                (plan, plan_changed_at, ts, task_id),
            )
        return self.get_task(task_id)

    def approve_plan(self, task_id: str, plan_as_displayed: str) -> dict:
        """Record that the Admiral approved the plan he was actually looking at.

        `plan_as_displayed` is the verbatim text the surface he clicked on had
        rendered. It must equal the plan currently stored, or this refuses:
        that is the whole safety property. Without it, a plan edited between
        the page's last poll and his tap would collect an approval for wording
        he never saw, and an agent would then act on authority he did not give.

        This records consent and NOTHING else. It does not merge, deploy,
        delete, advance the card, or start any work - deliberately, and stated
        here so a later change has to argue with this comment first. Agents act
        afterwards, under exactly the boundaries they already had.
        """
        current = self.get_task(task_id)
        if current is None:
            raise KeyError(task_id)
        stored = current.get("review_plan")
        if not stored:
            raise ValueError("there is no recommended plan on this card to approve")
        if normalized_plan(plan_as_displayed) != stored:
            raise PlanChangedError(
                "the plan changed since it was shown - nothing was approved. "
                "Re-read the card and approve the plan it now displays."
            )
        ts = now_iso()
        with self._cursor(write=True) as cur:
            cur.execute(
                "UPDATE tasks SET plan_approved_at = ?, plan_approved_text = ?, updated_at = ? "
                "WHERE id = ?",
                (ts, stored, ts, task_id),
            )
            # Deliberately writes NO status_history row. plan_approved_at and
            # plan_approved_text are already the durable, readable record of
            # his word, so a history row would add nothing - and it would cost
            # something real: it is a same-status row, indistinguishable in
            # shape from the re-ask rows set_status writes, and the auditor
            # has to tell those apart to know how long he has been blocked.
            # An earlier version of this wrote one, and it silently reset the
            # blocked-age of every card he approved - making the cards he had
            # answered look freshly flagged to the very sweep that exists to
            # catch cards he has been left waiting on.
        return self.get_task(task_id)

    def delete_task(self, task_id: str) -> None:
        with self._cursor(write=True) as cur:
            cur.execute("DELETE FROM notes WHERE task_id = ?", (task_id,))
            cur.execute("DELETE FROM status_history WHERE task_id = ?", (task_id,))
            cur.execute("DELETE FROM audit_log WHERE task_id = ?", (task_id,))
            cur.execute("UPDATE tasks SET waiting_on_id = NULL WHERE waiting_on_id = ?", (task_id,))
            cur.execute("DELETE FROM tasks WHERE id = ?", (task_id,))

    # ---- notes (interpretation / communication / needs tabs) ----

    def add_note(self, task_id: str, tab: str, author: str, text: str = "",
                 link_url: str | None = None, link_label: str | None = None) -> dict:
        if tab not in NOTE_TABS:
            raise ValueError(f"unknown tab: {tab!r}")
        if author not in NOTE_AUTHORS:
            raise ValueError(f"unknown author: {author!r}")
        if not text and not link_url:
            raise ValueError("a note needs text, a link, or both")
        if not self.task_exists(task_id):
            raise KeyError(task_id)
        ts = now_iso()
        with self._cursor(write=True) as cur:
            cur.execute(
                """INSERT INTO notes (task_id, tab, author, text, link_url, link_label, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (task_id, tab, author, text, link_url, link_label, ts),
            )
            cur.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (ts, task_id))
        return self.get_task(task_id)

    # ---- settings (key/value) ----

    def _get_setting(self, cur: sqlite3.Cursor, key: str) -> str | None:
        cur.execute("SELECT value FROM settings WHERE key = ?", (key,))
        row = cur.fetchone()
        return row["value"] if row else None

    def _set_setting(self, cur: sqlite3.Cursor, key: str, value: str) -> None:
        cur.execute(
            "INSERT INTO settings(key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

    # ---- audit ----

    def get_audit_interval_minutes(self) -> int:
        with self._cursor() as cur:
            cur.execute("SELECT value FROM settings WHERE key = 'audit_interval_minutes'")
            row = cur.fetchone()
            return int(row["value"]) if row else DEFAULT_AUDIT_INTERVAL_MINUTES

    def set_audit_interval_minutes(self, minutes: int) -> int:
        if minutes < 1:
            raise ValueError("audit interval must be at least 1 minute")
        with self._cursor(write=True) as cur:
            cur.execute(
                "INSERT INTO settings(key, value) VALUES ('audit_interval_minutes', ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (str(minutes),),
            )
        return minutes

    def record_audit_finding(self, kind: str, text: str, task_id: str | None = None,
                              key: str | None = None) -> dict:
        """Record a discrepancy or error, collapsing a recurring one into its
        existing row instead of appending a new one every time it recurs.

        `key` is the caller's own fingerprint for the *condition*, not the
        wording - a check that keeps re-detecting the same standing problem
        passes the same `key` every time even if `text` itself changes (an
        elapsed age, a different observed state). Collapsing is scoped to the
        exact (task_id, kind, key) triple: a card with no `key` never
        collapses at all (every call inserts, the pre-existing behavior), and
        two different checks must use different keys so a finding from one
        check can never be mistaken for - and so silence - a finding from
        another check on the same task. See docs/dashboard.md "Auditor
        integration" for the caller-side contract (why the count must still
        be tracked by the sweep script itself, independent of collapsing).
        """
        if kind not in ("discrepancy", "error"):
            raise ValueError(f"unknown audit finding kind: {kind!r}")
        ts = now_iso()
        with self._cursor(write=True) as cur:
            if key:
                cur.execute(
                    """SELECT id, occurrences FROM audit_log
                       WHERE task_id IS ? AND kind = ? AND key = ?
                       ORDER BY id DESC LIMIT 1""",
                    (task_id, kind, key),
                )
                existing = cur.fetchone()
                if existing is not None:
                    occurrences = existing["occurrences"] + 1
                    cur.execute(
                        "UPDATE audit_log SET text = ?, last_seen_at = ?, occurrences = ? WHERE id = ?",
                        (text, ts, occurrences, existing["id"]),
                    )
                    return {"collapsed": True, "occurrences": occurrences}
            cur.execute(
                """INSERT INTO audit_log (task_id, kind, text, key, occurrences, created_at, last_seen_at)
                   VALUES (?, ?, ?, ?, 1, ?, ?)""",
                (task_id, kind, text, key, ts, ts),
            )
            return {"collapsed": False, "occurrences": 1}

    def record_audit_run(self, duration_seconds: float, tasks_checked: int,
                          discrepancies_found: int = 0, started_at: str | None = None,
                          forced: bool = False) -> None:
        # A completed run is the normal, successful way a claimed sweep ends,
        # so recording one also releases the lock - see release_audit_sweep
        # for the separate path a sweep that errors out uses instead.
        with self._cursor(write=True) as cur:
            cur.execute(
                """INSERT INTO audit_runs
                   (started_at, completed_at, duration_seconds, tasks_checked, discrepancies_found, forced)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (started_at, now_iso(), duration_seconds, tasks_checked, discrepancies_found, int(forced)),
            )
            self._set_setting(cur, SETTING_SWEEP_RUNNING, "0")

    def record_audit_tick(self) -> str:
        ts = now_iso()
        with self._cursor(write=True) as cur:
            self._set_setting(cur, SETTING_LAST_TICK_AT, ts)
        return ts

    def claim_audit_sweep(self, forced: bool = False) -> dict:
        """Atomically claim the single sweep slot, or report who already holds it.

        A claim held past MAX_SWEEP_SECONDS is treated as abandoned (the
        subprocess that held it crashed or was killed without releasing) and
        is silently reclaimed rather than left stuck refusing every future
        tick and button press.
        """
        ts = now_iso()
        with self._cursor(write=True) as cur:
            running = self._get_setting(cur, SETTING_SWEEP_RUNNING) == "1"
            started_at = self._get_setting(cur, SETTING_SWEEP_STARTED_AT)
            if running and started_at:
                age = _iso_to_epoch(ts) - _iso_to_epoch(started_at)
                if age > MAX_SWEEP_SECONDS:
                    running = False
            if running:
                return {
                    "claimed": False,
                    "running_since": started_at,
                    "forced": self._get_setting(cur, SETTING_SWEEP_FORCED) == "1",
                }
            self._set_setting(cur, SETTING_SWEEP_RUNNING, "1")
            self._set_setting(cur, SETTING_SWEEP_STARTED_AT, ts)
            self._set_setting(cur, SETTING_SWEEP_FORCED, "1" if forced else "0")
        return {"claimed": True, "started_at": ts, "forced": forced}

    def release_audit_sweep(self) -> None:
        """Release a claimed sweep slot without recording a completed run.

        Used when a sweep fails before it can call record_audit_run, so a
        failed check never leaves the board looking like it is still sweeping
        (or, worse, permanently locked out of ever sweeping again).
        """
        with self._cursor(write=True) as cur:
            self._set_setting(cur, SETTING_SWEEP_RUNNING, "0")

    def get_audit_status(self, log_limit: int = 100) -> dict:
        with self._cursor() as cur:
            cur.execute(
                "SELECT * FROM audit_runs ORDER BY completed_at DESC, id DESC LIMIT 1"
            )
            last_run = cur.fetchone()
            # last_seen_at, not created_at: a collapsed row that keeps getting
            # reconfirmed must keep reading as current, not sink toward
            # eviction under its own original first-seen timestamp while a
            # long-resolved one-off entry outranks it.
            cur.execute(
                "SELECT * FROM audit_log ORDER BY last_seen_at DESC, id DESC LIMIT ?",
                (log_limit,),
            )
            log = [dict(r) for r in cur.fetchall()]
            last_tick_at = self._get_setting(cur, SETTING_LAST_TICK_AT)
            running = self._get_setting(cur, SETTING_SWEEP_RUNNING) == "1"
            started_at = self._get_setting(cur, SETTING_SWEEP_STARTED_AT)
            forced = self._get_setting(cur, SETTING_SWEEP_FORCED) == "1"
        return {
            "last_run": dict(last_run) if last_run else None,
            "log": log,
            "interval_minutes": self.get_audit_interval_minutes(),
            "last_tick_at": last_tick_at,
            "sweep_lock": {"running": running, "started_at": started_at if running else None,
                            "forced": forced if running else False},
        }
