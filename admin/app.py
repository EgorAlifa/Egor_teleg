#!/usr/bin/env python3
"""MTProto Proxy Admin Panel — polls mtg /stats, stores history, serves dashboard."""

import os
import sqlite3
import time
import threading
import functools
from datetime import datetime, timezone

import requests
from flask import Flask, render_template, jsonify, request, Response

# ---------------------------------------------------------------------------
# Config (override via env vars)
# ---------------------------------------------------------------------------
STATS_URL   = os.getenv("STATS_URL",   "http://127.0.0.1:445/stats")
POLL_SECS   = int(os.getenv("POLL_SECS",   "60"))
DB_PATH     = os.getenv("DB_PATH",     "/data/stats.db")
PANEL_PORT  = int(os.getenv("PANEL_PORT",  "8080"))
ADMIN_USER  = os.getenv("ADMIN_USER",  "admin")
ADMIN_PASS  = os.getenv("ADMIN_PASS",  "changeme")
PROXY_NAME  = os.getenv("PROXY_NAME",  "MTProto Proxy")

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with get_db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS snapshots (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                ts              INTEGER NOT NULL,
                active_conns    INTEGER DEFAULT 0,
                total_conns     INTEGER DEFAULT 0,
                traffic_in      INTEGER DEFAULT 0,
                traffic_out     INTEGER DEFAULT 0,
                crashes         INTEGER DEFAULT 0,
                raw_json        TEXT
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON snapshots(ts)")
        conn.commit()

# ---------------------------------------------------------------------------
# Stats polling
# ---------------------------------------------------------------------------

def _extract(data: dict) -> dict:
    """Normalise mtg v2 JSON into flat numbers."""
    conns   = data.get("connections", {})
    traffic = data.get("traffic", {})
    alltime = conns.get("all_time", {})
    total   = sum(alltime.values()) if isinstance(alltime, dict) else 0

    return {
        "active_conns":  int(conns.get("active", 0)),
        "total_conns":   int(total),
        "traffic_in":    int(traffic.get("ingress", 0)),
        "traffic_out":   int(traffic.get("egress",  0)),
        "crashes":       int(data.get("crashes", 0)),
    }


def poll_once():
    try:
        resp = requests.get(STATS_URL, timeout=5)
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:
        app.logger.warning("stats fetch failed: %s", exc)
        return

    flat = _extract(data)
    now  = int(time.time())

    import json
    with get_db() as conn:
        conn.execute(
            """INSERT INTO snapshots
               (ts, active_conns, total_conns, traffic_in, traffic_out, crashes, raw_json)
               VALUES (?,?,?,?,?,?,?)""",
            (now, flat["active_conns"], flat["total_conns"],
             flat["traffic_in"], flat["traffic_out"], flat["crashes"],
             json.dumps(data)),
        )
        conn.commit()
    app.logger.info("snapshot saved: active=%d total=%d", flat["active_conns"], flat["total_conns"])


def poll_loop():
    """Background thread: poll on startup then every POLL_SECS."""
    poll_once()
    while True:
        time.sleep(POLL_SECS)
        poll_once()

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def require_auth(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or auth.username != ADMIN_USER or auth.password != ADMIN_PASS:
            return Response(
                "Unauthorized", 401,
                {"WWW-Authenticate": 'Basic realm="Admin Panel"'},
            )
        return f(*args, **kwargs)
    return decorated

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
@require_auth
def index():
    return render_template("index.html", proxy_name=PROXY_NAME)


@app.route("/api/current")
@require_auth
def api_current():
    """Latest single snapshot."""
    with get_db() as conn:
        row = conn.execute(
            "SELECT * FROM snapshots ORDER BY ts DESC LIMIT 1"
        ).fetchone()
    if not row:
        return jsonify({"error": "no data yet"}), 404
    return jsonify(dict(row))


@app.route("/api/history")
@require_auth
def api_history():
    """Time-series for the last N hours (default 24)."""
    hours  = min(int(request.args.get("hours", 24)), 720)
    since  = int(time.time()) - hours * 3600
    with get_db() as conn:
        rows = conn.execute(
            """SELECT ts, active_conns, total_conns, traffic_in, traffic_out
               FROM snapshots WHERE ts >= ? ORDER BY ts ASC""",
            (since,),
        ).fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/summary")
@require_auth
def api_summary():
    """Aggregate totals and peak."""
    with get_db() as conn:
        row = conn.execute("""
            SELECT
                COUNT(*)          AS snapshots,
                MAX(active_conns) AS peak_active,
                MAX(total_conns)  AS total_conns,
                MAX(traffic_in)   AS traffic_in,
                MAX(traffic_out)  AS traffic_out,
                MIN(ts)           AS first_seen,
                MAX(ts)           AS last_seen
            FROM snapshots
        """).fetchone()
    return jsonify(dict(row))


@app.route("/health")
def health():
    return "ok"

# ---------------------------------------------------------------------------
# Entry-point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    init_db()
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()
    app.run(host="0.0.0.0", port=PANEL_PORT, debug=False)
