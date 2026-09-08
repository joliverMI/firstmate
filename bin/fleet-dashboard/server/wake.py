"""The board's one outbound path into firstmate's durable wake queue.

The board is otherwise a closed loop: agents write cards, the Admiral reads
them, and nothing the board records reaches firstmate unless a session
happens to look. That is fine for everything except the two board writes
that hand work BACK to the fleet: his approval, and a note he writes on a
card - see docs/dashboard.md "What an approval does mechanically" for why a
status nobody is woken about rots by construction, and a note nobody is
woken about goes unanswered the same way.

Nothing here interprets a card or decides anything. It appends one wake
record through firstmate's own writer, `fm_wake_append` in
bin/fm-wake-lib.sh, and never writes the queue file itself: the queue's
sequence numbering, its lock, and its watcher-downtime coupling all live in
that function, and a second writer reimplementing the format is exactly how
a half-written record would appear.
"""

from __future__ import annotations

import os
import subprocess

# bin/fleet-dashboard/server/wake.py -> bin/, where fm-wake-lib.sh lives.
BIN_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WAKE_LIB = os.path.join(BIN_DIR, "fm-wake-lib.sh")

# The queue append takes a short-lived lock (one line, written under it) and
# normally finishes in well under a tenth of a second. The bound exists for the
# case where it cannot finish at all - an unwritable state directory makes the
# lock wait forever - and it is short because the Admiral's tap is waiting on
# this call: a phone spinning for a quarter of a minute is a worse answer than
# "approved, firstmate not woken, and here is where that is written down".
# Comfortably above FM_LOCK_STALE_AFTER, so a genuinely stale lock is still
# broken and waited through rather than timing out here.
PUBLISH_TIMEOUT_SECONDS = 5


class WakePublishError(RuntimeError):
    """The wake record was NOT appended. Nothing partial was written."""


def resolve_fm_home(db_path: str) -> str:
    """The firstmate home whose state/ this board belongs to.

    FM_HOME is normally inherited from the environment `fm-dashboard.sh
    start` (or the systemd user unit) launched the server in. When it is not
    - a bare `python3 main.py` - fall back to db_path's grandparent, since
    every caller passes --db as <FM_HOME>/data/dashboard.db. Stated once
    here because both the Force Audit button's sweep subprocess and the
    approval wake below have to resolve the SAME home; two copies of this
    rule would let a board wake one home while sweeping another.
    """
    return os.environ.get(
        "FM_HOME", os.path.dirname(os.path.dirname(os.path.abspath(db_path)))
    )


def publish_check_wake(fm_home: str, key: str, payload: str) -> None:
    """Append one `check:` wake record to <fm_home>/state/.wake-queue.

    Raises WakePublishError if the record was not written, having written
    nothing. The caller decides what a failure costs it; for the approval
    path the answer is deliberately "the approval still stands, loudly
    unaccompanied", because refusing to record his consent because a queue
    file was unwritable would be the worse failure.

    A record is never left half-written, including when the bound below cuts
    the writer off: the append is one line written under the queue's own lock
    by the writer that owns the format, so what a kill can cost is the whole
    record, never part of one. A lock held by the killed writer is reclaimed
    by the queue's existing staleness handling, not by anything here.
    """
    if not os.path.isfile(WAKE_LIB):
        raise WakePublishError(f"firstmate's wake-queue writer is not at {WAKE_LIB}")
    env = dict(os.environ)
    env["FM_HOME"] = fm_home
    # A fixed argv with the variable parts passed as positional arguments to
    # bash, never interpolated into the script text: a card id and a payload
    # are data, and this is the one place they cross into a shell.
    argv = [
        "bash",
        "-c",
        '. "$1" || exit 1; fm_wake_append check "$2" "$3"',
        "fm-dashboard-wake",
        WAKE_LIB,
        key,
        payload,
    ]
    try:
        result = subprocess.run(
            argv, env=env, cwd=BIN_DIR, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=PUBLISH_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise WakePublishError(
            f"firstmate's wake-queue writer did not finish within "
            f"{PUBLISH_TIMEOUT_SECONDS}s"
        ) from exc
    except OSError as exc:
        raise WakePublishError(f"could not run firstmate's wake-queue writer: {exc}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip().splitlines()
        raise WakePublishError(
            "firstmate's wake-queue writer refused the record "
            f"(exit {result.returncode}): {detail[-1] if detail else 'no output'}"
        )
