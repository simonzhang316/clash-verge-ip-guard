#!/usr/bin/env python3
"""Cockpit server (S1 guard bridge + S2 mihomo read-only bridge).

Per ADR-0002 (single repairer rule):
- The Cockpit never probes the residential egress itself; it reads the
  guard's state.json written by claude-ip-enforce.
- The mihomo bridge is GET-only against an exact-match whitelist. No
  /delay endpoints (active probing), no mutation endpoints. mihomo's
  external-controller TCP stays closed; only the unix socket is used.
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.client
import json
import os
import socket
import socketserver
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
INDEX_FILE = BASE_DIR / "index.html"

GUARD_STATE_JSON = Path(
    os.environ.get(
        "GUARD_STATE_JSON",
        str(Path.home() / ".local/state/claude-ip-guard/state.json"),
    )
)
GUARD_EVENTS_JSONL = Path(
    os.environ.get(
        "GUARD_EVENTS_JSONL",
        str(Path.home() / ".local/state/claude-ip-guard/events.jsonl"),
    )
)
# enforcer runs every 30s; three missed cycles means the guard itself is down
GUARD_STALE_AFTER_S = 90

MIHOMO_SOCK = os.environ.get("CLASH_SOCK", "/tmp/verge/verge-mihomo.sock")
# Read-only bridge whitelist. Exact match only: no /delay (active probe
# traffic), no group/provider probes, no mutation paths. /connections is
# GET-only here; closing connections (DELETE) stays rejected.
CLASH_GET_WHITELIST = {"/configs", "/proxies", "/rules", "/version", "/connections"}

VERGE_APPDIR = Path(
    os.environ.get(
        "CLASH_VERGE_BASE",
        str(
            Path.home()
            / "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
        ),
    )
)
PROFILES_INDEX = VERGE_APPDIR / "profiles.yaml"

_node_count_cache: dict[str, tuple[float, int | None]] = {}


def log_access(method: str, path: str, status: int) -> None:
    print(
        f"[{dt.datetime.now().isoformat(timespec='seconds')}] {method} {path} -> {status}",
        flush=True,
    )


def guard_status() -> dict:
    if not GUARD_STATE_JSON.exists():
        return {
            "available": False,
            "reason": "state_file_missing",
            "hint": "enforcer 尚未写入状态文件，确认 claude-ip-enforcer LaunchAgent 在跑",
        }
    try:
        raw = json.loads(GUARD_STATE_JSON.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {
            "available": False,
            "reason": f"state_file_unreadable_{type(exc).__name__}",
        }

    age_seconds = None
    stale = True
    try:
        ts = dt.datetime.fromisoformat(raw.get("ts", ""))
        age_seconds = int((dt.datetime.now(ts.tzinfo) - ts).total_seconds())
        stale = age_seconds > GUARD_STALE_AFTER_S
    except ValueError:
        pass

    return {
        "available": True,
        "stale": stale,
        "age_seconds": age_seconds,
        "stale_after_seconds": GUARD_STALE_AFTER_S,
        "guard": raw,
    }


def guard_events(limit: int) -> dict:
    if not GUARD_EVENTS_JSONL.exists():
        return {"available": True, "events": []}
    try:
        lines = GUARD_EVENTS_JSONL.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return {"available": False, "reason": f"events_unreadable_{type(exc).__name__}"}
    events = []
    for line in lines[-limit:]:
        try:
            events.append(json.loads(line))
        except ValueError:
            continue
    events.reverse()  # newest first
    return {"available": True, "events": events}


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, sock_path: str, timeout: float = 5.0):
        super().__init__("localhost", timeout=timeout)
        self.sock_path = sock_path

    def connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.sock_path)
        self.sock = s


def mihomo_get(path: str) -> tuple[int, dict]:
    conn = UnixHTTPConnection(MIHOMO_SOCK)
    try:
        conn.request("GET", path, headers={"Host": "localhost"})
        resp = conn.getresponse()
        body = resp.read()
        try:
            return resp.status, json.loads(body)
        except ValueError:
            return 502, {"error": "mihomo_bad_json"}
    except OSError as exc:
        return 502, {"error": f"mihomo_unreachable_{type(exc).__name__}"}
    finally:
        conn.close()


def profile_node_count(profile_file: Path) -> int | None:
    """Count proxy definitions in a subscription profile, cached by mtime.

    Subscription files here are mihomo-lenient YAML (plus historical heal
    injections) that strict PyYAML cannot parse. Every proxy definition has
    exactly one `server:` field and groups have none, so counting server
    fields (block + flow style) is the reliable signal.
    """
    import re

    try:
        mtime = profile_file.stat().st_mtime
    except OSError:
        return None
    key = str(profile_file)
    cached = _node_count_cache.get(key)
    if cached and cached[0] == mtime:
        return cached[1]
    try:
        text = profile_file.read_text(encoding="utf-8")
        count = len(re.findall(r"(?m)^\s*server:\s", text)) + len(
            re.findall(r"[{,]\s*server:\s", text)
        )
    except OSError:
        count = None
    _node_count_cache[key] = (mtime, count)
    return count


def subscriptions() -> dict:
    try:
        import yaml
    except ImportError:
        return {"available": False, "reason": "pyyaml_missing"}
    try:
        index = yaml.safe_load(PROFILES_INDEX.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"available": False, "reason": f"profiles_unreadable_{type(exc).__name__}"}

    current_uid = index.get("current")
    profiles = []
    for item in index.get("items", []):
        # remote/local entries are the actual subscriptions; merge/script/
        # rules/proxies/groups entries are Verge chain artifacts.
        if item.get("type") not in ("remote", "local"):
            continue
        option = item.get("option") or {}
        updated = item.get("updated")
        profiles.append(
            {
                "uid": item.get("uid"),
                "name": item.get("name"),
                "type": item.get("type"),
                "is_current": item.get("uid") == current_uid,
                "updated_ts": updated,
                "updated_iso": (
                    dt.datetime.fromtimestamp(updated).isoformat(timespec="seconds")
                    if isinstance(updated, (int, float))
                    else None
                ),
                "allow_auto_update": option.get("allow_auto_update"),
                "update_interval_min": option.get("update_interval"),
                "node_count": profile_node_count(
                    VERGE_APPDIR / "profiles" / str(item.get("file"))
                ),
            }
        )
    return {"available": True, "current": current_uid, "profiles": profiles}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def _send_json(self, status: int, payload: dict, method: str = "GET") -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        if self.path.startswith("/api/"):
            log_access(method, self.path, status)

    def _send_file(self, path: Path, content_type: str) -> None:
        if not path.exists():
            self.send_error(404, "Not Found")
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _reject_write(self, method: str) -> None:
        self._send_json(
            405,
            {"error": "method_not_allowed", "hint": "Cockpit 桥只读（ADR-0002）"},
            method,
        )

    def do_PUT(self) -> None:  # noqa: N802
        self._reject_write("PUT")

    def do_POST(self) -> None:  # noqa: N802
        self._reject_write("POST")

    def do_PATCH(self) -> None:  # noqa: N802
        self._reject_write("PATCH")

    def do_DELETE(self) -> None:  # noqa: N802
        self._reject_write("DELETE")

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path in ("/", "/index.html"):
            self._send_file(INDEX_FILE, "text/html; charset=utf-8")
            return

        if path == "/api/guard":
            self._send_json(200, guard_status())
            return

        if path == "/api/subscriptions":
            self._send_json(200, subscriptions())
            return

        if path == "/api/events":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                limit = min(int(query.get("limit", ["100"])[0]), 500)
            except ValueError:
                limit = 100
            self._send_json(200, guard_events(limit))
            return

        if path.startswith("/api/clash/"):
            target = "/" + path[len("/api/clash/"):]
            if target not in CLASH_GET_WHITELIST:
                self._send_json(
                    403,
                    {
                        "error": "not_whitelisted",
                        "hint": "只读桥白名单外路径（ADR-0002）",
                    },
                )
                return
            status, payload = mihomo_get(target)
            self._send_json(status, payload)
            return

        self._send_json(404, {"error": "not_found"})


class ThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    parser = argparse.ArgumentParser(description="Cockpit local web server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    with ThreadingHTTPServer((args.host, args.port), Handler) as httpd:
        print(f"Cockpit running at http://{args.host}:{args.port}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
