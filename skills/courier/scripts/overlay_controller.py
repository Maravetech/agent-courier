#!/usr/bin/env python3
"""Optional overlay state and short-lived monitor; never controls another app's UI."""
import argparse
from datetime import datetime
import fcntl
import glob
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import time

STATE_DIR = Path(os.environ.get("COURIER_STATE_DIR", "~/.local/state/courier")).expanduser() / "overlay"
STATE_FILE = STATE_DIR / "pairs.json"
REPO = Path(__file__).resolve().parents[3]
BUILT_APP = REPO / "overlay/build/courier-overlay.app/Contents/MacOS/courier-overlay"
INSTALLED_APP = Path("~/Applications/courier-overlay.app/Contents/MacOS/courier-overlay").expanduser()
VALID_STATES = {"idle", "pending", "sending", "delivered", "working", "replied", "wrong_header", "error", "stuck", "archived_source", "archived_target"}
TOKEN = re.compile(r"^(Claude Code|Codex)·(\d+)$")


def parse_token(value):
    match = TOKEN.fullmatch(value)
    if not match or len(match[2]) != (4 if match[1] == "Claude Code" else 5):
        raise ValueError("expected Claude Code·NNNN or Codex·NNNNN")
    return match[1], match[2]


def atomic_write(data):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pairs-", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, ensure_ascii=False, separators=(",", ":"))
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, STATE_FILE)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_pairs():
    try:
        pairs = json.loads(STATE_FILE.read_text()).get("pairs", [])
        return [{**pair, "from_app": pair.get("from_app", "Claude Code"),
                 "to_app": pair.get("to_app", "Codex")} for pair in pairs
                if isinstance(pair, dict) and pair.get("from") and pair.get("to")]
    except (OSError, ValueError, AttributeError):
        return []


def update_pair(sender, recipient, state, reason=""):
    from_app, from_id = parse_token(sender)
    to_app, to_id = parse_token(recipient)
    if state not in VALID_STATES:
        raise ValueError("invalid overlay state")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "state.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = read_pairs()
        pairs = [p for p in current if (p.get("from_app"), p.get("from"), p.get("to_app"), p.get("to")) != (from_app, from_id, to_app, to_id)]
        if state != "archived_source":
            old = next((p for p in current if (p.get("from_app"), p.get("from"), p.get("to_app"), p.get("to")) == (from_app, from_id, to_app, to_id)), {})
            pairs.append({**old, "from_app": from_app, "from": from_id, "to_app": to_app, "to": to_id,
                          "state": state, "reason": reason[:60], "updated_at": time.time()})
        atomic_write({"pairs": pairs})
    return pairs


def archived_codex(number):
    home = Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser()
    try:
        rows = [json.loads(line) for line in (home / "session_index.jsonl").read_text().splitlines() if line]
    except (OSError, ValueError):
        return False
    ids = {row.get("id") for row in rows if re.match(r"^" + re.escape(number) + r"\s", row.get("thread_name", ""))}
    if not ids:
        return False
    try:
        with sqlite3.connect(f"file:{home / 'state_5.sqlite'}?mode=ro", uri=True, timeout=1) as db:
            rows = db.execute("SELECT id, archived FROM threads WHERE id IN (" + ",".join("?" for _ in ids) + ")", tuple(ids)).fetchall()
        return bool(rows) and all(bool(row[1]) for row in rows)
    except sqlite3.Error:
        return False


def archived_claude(number):
    root = Path.home() / "Library/Application Support/Claude/claude-code-sessions"
    found = []
    for path in root.glob("**/*.json"):
        try:
            row = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if str(row.get("title", "")).startswith(number + " "):
            found.append(row.get("isArchived"))
    return bool(found) and all(value is True for value in found)


def archived(app, number):
    return archived_codex(number) if app == "Codex" else archived_claude(number)


def codex_progress(pair):
    """Read the recipient rollout directly; watch is not needed for visual state."""
    if pair["to_app"] != "Codex":
        return None
    script_dir = str(Path(__file__).resolve().parent)
    if script_dir not in sys.path:
        sys.path.insert(0, script_dir)
    import courier
    rows = [row for row in courier.codex_index().values()
            if re.match(r"^" + re.escape(pair["to"]) + r"\s", row.get("thread_name", ""))]
    if len(rows) != 1:
        return None
    path = courier.codex_log(rows[0]["id"])
    if not path:
        return None
    messages, running, last_done = courier.codex_scan(path)
    users = [(index, stamp, body) for index, (stamp, role, body) in enumerate(messages) if role == "user"]
    if not users:
        return None
    index, stamp, body = users[-1]
    if pair["state"] == "sending":
        try:
            sent_at = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
        if sent_at < pair["updated_at"] - 2:
            return None
    if courier.parse_header(body) != (pair["from_app"] + "·" + pair["from"], pair["to_app"] + "·" + pair["to"]):
        return None
    if running:
        if time.time() - os.path.getmtime(path) >= int(os.environ.get("COURIER_STUCK_SECONDS", "600")):
            return "stuck", "卡住"
        return ("delivered" if pair["state"] == "sending" else "working"), ""
    replies = [text for _, role, text in messages[index + 1:] if role == "assistant"]
    if replies and replies[-1].splitlines()[0] == courier.reply_line(*courier.parse_header(body)):
        return "replied", ""
    if last_done and last_done[1] == "turn_aborted":
        return "error", "回合中止"
    if replies:
        return "wrong_header", "回复抬头不对"
    return "delivered", ""


def app_path():
    return INSTALLED_APP if INSTALLED_APP.is_file() else BUILT_APP


def ensure_app():
    app = app_path()
    if not app.is_file():
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "app.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = subprocess.run(["/bin/ps", "-awwxo", "command="], capture_output=True, text=True, timeout=5).stdout.splitlines()
        if any(row == str(app) or row.startswith(str(app) + " ") for row in rows):
            return
        env = dict(os.environ)
        env.pop("COURIER_OVERLAY_FIXTURE", None)
        subprocess.Popen([str(app), str(STATE_FILE)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, env=env)


def monitor():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "monitor.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        empty_since = None
        next_check = 0
        while True:
            now = time.time()
            if now >= next_check:
                with (STATE_DIR / "state.lock").open("a+") as state_lock:
                    fcntl.flock(state_lock, fcntl.LOCK_EX)
                    old = read_pairs()
                    pairs = []
                    for pair in old:
                        if pair["state"] == "archived_target":
                            pairs.append(pair)
                            continue
                        if archived(pair["from_app"], pair["from"]):
                            continue
                        if archived(pair["to_app"], pair["to"]):
                            if pair["state"] != "archived_target":
                                pair = {**pair, "state": "archived_target", "updated_at": now}
                            pairs.append(pair)
                            continue
                        progress = codex_progress(pair)
                        if progress and progress != (pair["state"], pair.get("reason", "")):
                            pair = {**pair, "state": progress[0], "reason": progress[1], "updated_at": now}
                        pairs.append(pair)
                    if pairs != old:
                        atomic_write({"pairs": pairs})
                next_check = now + 10
            with (STATE_DIR / "state.lock").open("a+") as state_lock:
                fcntl.flock(state_lock, fcntl.LOCK_EX)
                old = read_pairs()
                pairs = [pair for pair in old if pair["state"] != "archived_target" or now - pair["updated_at"] < 2.8]
                if pairs != old:
                    atomic_write({"pairs": pairs})
            if not read_pairs():
                empty_since = empty_since or now
                if now - empty_since > 3:
                    break
            else:
                empty_since = None
            time.sleep(0.5)
        return 0


def status():
    app = app_path()
    if not app.is_file():
        print("浮层 App 尚未构建")
        return 1
    result = subprocess.run([str(app), "--status"], capture_output=True, text=True, timeout=5)
    print(result.stdout.strip() or "辅助功能状态无法读取")
    return result.returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--monitor", action="store_true")
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--from-session")
    parser.add_argument("--to-session")
    parser.add_argument("--state", choices=sorted(VALID_STATES))
    parser.add_argument("--reason", default="")
    args = parser.parse_args()
    if args.status:
        return status()
    if args.monitor:
        return monitor()
    if not (args.from_session and args.to_session and args.state):
        parser.error("pair needs --from-session, --to-session and --state")
    if os.environ.get("COURIER_OVERLAY", "1") == "0":
        return 0
    try:
        pairs = update_pair(args.from_session, args.to_session, args.state, args.reason)
    except ValueError as error:
        parser.error(str(error))
    if pairs and app_path().is_file():
        ensure_app()
        subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()), "--monitor"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
