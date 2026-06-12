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
import hmac
import http.client
import json
import os
import secrets
import socket
import socketserver
import subprocess
import sys
import time
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

# --- S3 operations layer ---------------------------------------------------
# Ops are the ONLY mutating surface and they are runtime-only (ADR-0002):
# selector switching (Claude locked), manual delay tests (never for groups
# containing Claude-Residential), guard recheck via launchctl kickstart.
COCKPIT_TOKEN_FILE = Path(
    os.environ.get(
        "COCKPIT_TOKEN_FILE",
        str(Path.home() / ".local/state/claude-ip-guard/cockpit-token"),
    )
)
ENFORCER_LAUNCHD_LABEL = "com.zhangxinran.claude-ip-enforcer"
DELAY_TEST_URL = "http://cp.cloudflare.com/generate_204"
DELAY_TEST_TIMEOUT_MS = 5000
DELAY_THROTTLE_S = 30
GROUP_TYPES = {"Selector", "URLTest", "Fallback", "LoadBalance"}

_delay_last_test: dict[str, float] = {}


def load_or_create_token() -> str:
    try:
        token = COCKPIT_TOKEN_FILE.read_text(encoding="utf-8").strip()
        if token:
            return token
    except OSError:
        pass
    token = secrets.token_hex(16)
    COCKPIT_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    COCKPIT_TOKEN_FILE.write_text(token + "\n", encoding="utf-8")
    COCKPIT_TOKEN_FILE.chmod(0o600)
    return token


COCKPIT_TOKEN = load_or_create_token()


def token_ok(header_value: str | None) -> bool:
    return bool(header_value) and hmac.compare_digest(header_value, COCKPIT_TOKEN)


def op_select_group(payload: dict) -> tuple[int, dict]:
    group = str(payload.get("group", ""))
    name = str(payload.get("name", ""))
    if not group or not name:
        return 400, {"error": "missing_group_or_name"}
    if group == "Claude":
        return 403, {"error": "claude_locked", "hint": "Claude 组由守护层锁定（ADR-0002）"}
    status, info = mihomo_get("/proxies/" + urllib.parse.quote(group))
    if status != 200:
        return 404, {"error": "group_not_found"}
    if info.get("type") != "Selector":
        return 403, {"error": "not_a_selector", "hint": f"{group} 是 {info.get('type')}，自动选组不可手动切"}
    if name not in (info.get("all") or []):
        return 400, {"error": "name_not_in_group"}
    status, _ = mihomo_request(
        "PUT", "/proxies/" + urllib.parse.quote(group), {"name": name}
    )
    if status not in (200, 204):
        return 502, {"error": f"mihomo_put_failed_{status}"}
    _, after = mihomo_get("/proxies/" + urllib.parse.quote(group))
    return 200, {"ok": True, "group": group, "now": after.get("now")}


def op_delay_test(payload: dict) -> tuple[int, dict]:
    group = str(payload.get("group", ""))
    if not group:
        return 400, {"error": "missing_group"}
    if group == "Claude":
        return 403, {"error": "claude_locked"}
    status, info = mihomo_get("/proxies/" + urllib.parse.quote(group))
    if status != 200:
        return 404, {"error": "group_not_found"}
    if info.get("type") not in GROUP_TYPES:
        return 400, {"error": "not_a_group"}
    if "Claude-Residential" in (info.get("all") or []):
        return 403, {
            "error": "claude_residential_protected",
            "hint": "该组包含家宽节点，禁止主动测速（ADR-0002）",
        }
    now = time.monotonic()
    last = _delay_last_test.get(group)
    if last is not None and now - last < DELAY_THROTTLE_S:
        return 429, {"error": "throttled", "retry_after_s": int(DELAY_THROTTLE_S - (now - last))}
    _delay_last_test[group] = now
    q = urllib.parse.urlencode({"url": DELAY_TEST_URL, "timeout": DELAY_TEST_TIMEOUT_MS})
    status, result = mihomo_request(
        "GET", "/group/" + urllib.parse.quote(group) + "/delay?" + q, timeout=20.0
    )
    if status != 200:
        return 502, {"error": f"delay_test_failed_{status}", "detail": result}
    return 200, {"ok": True, "group": group, "delays": result}


def op_recheck() -> tuple[int, dict]:
    # Kick the enforcer for an immediate cycle: the guard stays the single
    # repairer; the cockpit only asks it to run now instead of in <=30s.
    try:
        proc = subprocess.run(
            ["/bin/launchctl", "kickstart", f"gui/{os.getuid()}/{ENFORCER_LAUNCHD_LABEL}"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 502, {"error": f"kickstart_failed_{type(exc).__name__}"}
    if proc.returncode != 0:
        return 502, {"error": "kickstart_failed", "detail": proc.stderr.strip()[:200]}
    return 200, {"ok": True, "hint": "enforcer 已触发，约 10 秒后刷新守护状态"}


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


def mihomo_request(
    method: str, path: str, body: dict | None = None, timeout: float = 5.0
) -> tuple[int, dict]:
    conn = UnixHTTPConnection(MIHOMO_SOCK, timeout=timeout)
    try:
        headers = {"Host": "localhost"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        if not raw:
            return resp.status, {}
        try:
            return resp.status, json.loads(raw)
        except ValueError:
            return 502, {"error": "mihomo_bad_json"}
    except OSError as exc:
        return 502, {"error": f"mihomo_unreachable_{type(exc).__name__}"}
    finally:
        conn.close()


def mihomo_get(path: str) -> tuple[int, dict]:
    return mihomo_request("GET", path)


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

    def do_PATCH(self) -> None:  # noqa: N802
        self._reject_write("PATCH")

    def do_DELETE(self) -> None:  # noqa: N802
        self._reject_write("DELETE")

    def _read_json_body(self) -> dict:
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 65536)
            if length <= 0:
                return {}
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, OSError):
            return {}

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if not parsed.path.startswith("/api/ops/"):
            self._reject_write("POST")
            return
        if not token_ok(self.headers.get("X-Cockpit-Token")):
            self._send_json(401, {"error": "bad_token", "hint": "操作端点需要 token"}, "POST")
            return
        payload = self._read_json_body()
        if parsed.path == "/api/ops/select-group":
            status, result = op_select_group(payload)
        elif parsed.path == "/api/ops/delay-test":
            status, result = op_delay_test(payload)
        elif parsed.path == "/api/ops/recheck":
            status, result = op_recheck()
        else:
            status, result = 404, {"error": "unknown_op"}
        self._send_json(status, result, "POST")

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
