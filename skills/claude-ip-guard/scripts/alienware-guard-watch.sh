#!/bin/bash
# alienware-guard-watch.sh — Mac 侧巡检外星人（Windows）上的 Claude IP 守护
#
# Windows 守护跑在 SYSTEM 账号下，告警只写进它自己的 events.jsonl，没人看得见
# （2026-09-30 起断网 16 天无人知）。这里由 Mac launchd 每 10 分钟 SSH 读它的 state.json，
# 异常连续两轮就经通报 bot 告警：守护报错 / 状态超过 30 分钟没更新（计划任务停了）/ SSH 连不上外星人。
# 恢复时报一次；一直没恢复则每 12 小时提醒一次。只读，不往外星人写任何东西，不碰任何内核。
#
# 巡检自身状态：$WATCH_STATE_DIR/watch.json（最后一轮的结论、连到哪台、告警到了哪一步）
set -uo pipefail

WATCH_HOSTS="${WATCH_HOSTS:-alienware alienware2}"
WATCH_SSH="${WATCH_SSH:-/usr/bin/ssh}"
NOTIFY_CMD="${NOTIFY_CMD:-$HOME/claudecode_xinran/scripts/notify-master.sh}"
WATCH_STATE_DIR="${WATCH_STATE_DIR:-$HOME/.local/state/alienware-guard-watch}"
REMOTE_STATE='C:\Tools\claude-ip-guard\state\state.json'

mkdir -p "$WATCH_STATE_DIR"
fetched="$WATCH_STATE_DIR/remote-state.json"
reached=""
for host in $WATCH_HOSTS; do
  if "$WATCH_SSH" -o BatchMode=yes -o ConnectTimeout=8 "$host" "type $REMOTE_STATE" >"$fetched" 2>/dev/null && [ -s "$fetched" ]; then
    reached="$host"
    break
  fi
done
[ -n "$reached" ] || : >"$fetched"

message="$(/usr/bin/python3 - "$fetched" "$WATCH_STATE_DIR/watch.json" "${WATCH_NOW:-$(date +%s)}" "$reached" <<'PY'
import datetime
import json
import os
import re
import sys

fetched, watch_path, now, host = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
STALE_SECONDS = 30 * 60
BAD_RUNS_BEFORE_ALERT = 2
REMIND_SECONDS = 12 * 3600

try:
    with open(watch_path, encoding="utf-8") as f:
        watch = json.load(f)
except (OSError, ValueError):
    watch = {}


def duration(seconds):
    minutes = max(int(seconds) // 60, 1)
    if minutes < 60:
        return f"{minutes} 分钟"
    hours = minutes // 60
    return f"{hours} 小时" if hours < 48 else f"{hours // 24} 天"


raw, detail = "ok", ""
if not host:
    raw = "unreachable"
else:
    try:
        with open(fetched, encoding="utf-8-sig") as f:
            state = json.load(f)
        stamp = re.sub(r"(\.\d{6})\d+", r"\1", state["ts"])
        age = now - datetime.datetime.fromisoformat(stamp).timestamp()
        detail = str(state.get("detail", ""))[:200]
        if age > STALE_SECONDS:
            raw, detail = "stale", f"{duration(age)}没更新，最后一次是 {state['ts'][:16].replace('T', ' ')}"
        elif state.get("status") != "OK":
            raw = "fail"
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raw, detail = "fail", f"state.json 读不懂：{exc}"

prev_raw = watch.get("raw", "ok")
streak = 0 if raw == "ok" else (watch.get("streak", 0) + 1 if raw == prev_raw else 1)
bad_since = None if raw == "ok" else (watch.get("bad_since") or now)
alerted = watch.get("alerted", "")
alerted_at = watch.get("alerted_at", 0)

ALERTS = {
    "unreachable": "连不上外星人：Tailscale 和局域网两条线 SSH 都不通，已持续约 {dur}。可能关机、断网，或者局域网 IP 又漂了。去劳模说。",
    "fail": "外星人 Claude 守护连续报错，已持续约 {dur}，Claude 和外网可能都断了。守护原话：{detail}。去劳模说。",
    "stale": "外星人守护的状态{detail}，计划任务 claude-ip-guard 可能停了。去劳模说。",
}

message = ""
if raw == "ok":
    if alerted:
        message = f"外星人守护恢复正常：{detail}"
        alerted, alerted_at = "", 0
elif streak >= BAD_RUNS_BEFORE_ALERT:
    text = ALERTS[raw].format(dur=duration(now - bad_since), detail=detail)
    if alerted != raw:
        message, alerted, alerted_at = text, raw, now
    elif now - alerted_at >= REMIND_SECONDS:
        message, alerted_at = "仍未恢复：" + text, now

watch = {
    "last_run": now,
    "host": host,
    "raw": raw,
    "streak": streak,
    "bad_since": bad_since,
    "alerted": alerted,
    "alerted_at": alerted_at,
    "detail": detail,
}
tmp = watch_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(watch, f, ensure_ascii=False, indent=2)
os.replace(tmp, watch_path)
print(message)
PY
)"

if [ -n "$message" ]; then
  "$NOTIFY_CMD" -m "$message"
fi
exit 0
