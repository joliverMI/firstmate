#!/usr/bin/env python3
"""Entrypoint for the Admiral's Fleet Dashboard server.

Zero-dependency by design: only the Python 3 standard library. Run it with
    python3 bin/fleet-dashboard/server/main.py --host <tailnet-ip> --port 8420
and the board is live at http://<tailnet-ip>:8420/ - see bin/fm-dashboard.sh
and docs/dashboard.md for the operator-facing start/stop wrapper and the
default host/port/db-path resolution it uses.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from api import serve  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("FM_DASHBOARD_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("FM_DASHBOARD_PORT", "8420")))
    default_db = os.environ.get(
        "FM_DASHBOARD_DB",
        os.path.join(os.path.expanduser("~"), "firstmate", "data", "dashboard.db"),
    )
    parser.add_argument("--db", default=default_db)
    args = parser.parse_args()

    httpd = serve(args.host, args.port, args.db)
    print(f"fleet dashboard listening on http://{args.host}:{args.port}  (db: {args.db})", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
