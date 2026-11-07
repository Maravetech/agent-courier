#!/usr/bin/env python3
"""One-shot overlay state reports; never controls another app's UI."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

STATE_DIR = Path(os.environ.get("COURIER_STATE_DIR", "~/.local/state/courier")).expanduser() / "overlay"
STATE_FILE = STATE_DIR / "pairs.json"
LINKS_FILE = STATE_DIR / "links.json"
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


def atomic_write(data, destination=None):
    destination = destination or STATE_FILE
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pairs-", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(data, out, ensure_ascii=False, separators=(",", ":"))
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, destination)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def preference(folder=None):
    try:
        return json.loads(((folder or STATE_DIR) / "config.json").read_text()).get("enabled") is True
    except (OSError, ValueError, AttributeError):
        return False


def enabled(folder=None):
    override = os.environ.get("COURIER_OVERLAY")
    return override == "1" if override in ("0", "1") else preference(folder)


def set_enabled(value):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "state.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        atomic_write({"enabled": value, "revision": uuid.uuid4().hex}, STATE_DIR / "config.json")


def wait_stopped():
    try:
        lock = (STATE_DIR / "instance.lock").open("r")
    except FileNotFoundError:
        return True
    with lock:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                time.sleep(0.05)
    return False


def read_pairs():
    try:
        pairs = json.loads(STATE_FILE.read_text()).get("pairs", [])
        return [{**pair, "from_app": pair.get("from_app", "Claude Code"),
                 "to_app": pair.get("to_app", "Codex")} for pair in pairs
                if isinstance(pair, dict) and pair.get("from") and pair.get("to")]
    except (OSError, ValueError, AttributeError):
        return []


def pair_key(sender, recipient):
    parse_token(sender)
    parse_token(recipient)
    return sender + "→" + recipient


def read_links(path=None):
    try:
        data = json.loads((path or LINKS_FILE).read_text())
        links = data.get("disconnected") if isinstance(data, dict) else None
        return {key for key in links if isinstance(key, str)} if isinstance(links, list) else set()
    except (OSError, ValueError, AttributeError):
        return set()


def is_disconnected(sender, recipient):
    return pair_key(sender, recipient) in read_links()


def set_link(sender, recipient, connected):
    key = pair_key(sender, recipient)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "state.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pairs = read_pairs()
        if not any(pair.get("from_app") + "·" + pair.get("from") == sender and
                   pair.get("to_app") + "·" + pair.get("to") == recipient for pair in pairs):
            raise ValueError("只能关联或断开已有投递配对")
        links = read_links()
        if connected:
            links.discard(key)
        else:
            links.add(key)
        fd, name = tempfile.mkstemp(prefix=".links-", dir=STATE_DIR)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                json.dump({"disconnected": sorted(links)}, out, ensure_ascii=False)
                out.flush()
                os.fsync(out.fileno())
            os.replace(name, LINKS_FILE)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    return connected


def update_pair(sender, recipient, state, reason="", respect_preference=False):
    from_app, from_id = parse_token(sender)
    to_app, to_id = parse_token(recipient)
    if state not in VALID_STATES:
        raise ValueError("invalid overlay state")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "state.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if respect_preference and not enabled():
            return []
        if state == "sending" and is_disconnected(sender, recipient):
            raise PermissionError("这对会话已在菜单栏断开，请先点关联")
        current = read_pairs()
        pairs = [p for p in current if (p.get("from_app"), p.get("from"), p.get("to_app"), p.get("to")) != (from_app, from_id, to_app, to_id)]
        old = next((p for p in current if (p.get("from_app"), p.get("from"), p.get("to_app"), p.get("to")) == (from_app, from_id, to_app, to_id)), {})
        now = time.time()
        motion_at = (old.get("motion_at", old.get("updated_at", now)) if state in ("delivered", "working")
                     else now)
        pairs.append({**old, "from_app": from_app, "from": from_id, "to_app": to_app, "to": to_id,
                      "state": state, "reason": reason[:60], "updated_at": now, "motion_at": motion_at})
        atomic_write({"pairs": pairs})
    return pairs


def app_path():
    return INSTALLED_APP if INSTALLED_APP.is_file() else BUILT_APP


def ensure_app():
    if not enabled():
        return
    app = app_path()
    if not app.is_file():
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with (STATE_DIR / "app.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not enabled():
            return
        rows = subprocess.run(["/bin/ps", "-awwxo", "command="], capture_output=True, text=True, timeout=5).stdout.splitlines()
        if any(row == str(app) or row.startswith(str(app) + " ") for row in rows):
            return
        env = dict(os.environ)
        env.pop("COURIER_OVERLAY_FIXTURE", None)
        subprocess.Popen([str(app), str(STATE_FILE)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, env=env)


def status():
    override = os.environ.get("COURIER_OVERLAY")
    print(f"configured={'on' if preference() else 'off'} effective={'on' if enabled() else 'off'}"
          f" override={override if override in ('0', '1') else 'none'}")
    return 0


def start_best_effort():
    try:
        ensure_app()
    except (OSError, subprocess.SubprocessError):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--set-enabled", choices=("on", "off"))
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--link", choices=["connect", "disconnect"])
    parser.add_argument("--from-session")
    parser.add_argument("--to-session")
    parser.add_argument("--state", choices=sorted(VALID_STATES))
    parser.add_argument("--reason", default="")
    args = parser.parse_args()
    if args.set_enabled:
        value = args.set_enabled == "on"
        set_enabled(value)
        if value and enabled() and read_pairs():
            start_best_effort()
        elif not value and not wait_stopped():
            print("已保存关闭状态，但浮层尚未退出", file=sys.stderr)
            return 1
        return status()
    if args.status:
        return status()
    if args.check or args.link:
        if not (args.from_session and args.to_session):
            parser.error("check/link needs --from-session and --to-session")
        try:
            if args.link:
                set_link(args.from_session, args.to_session, args.link == "connect")
            elif is_disconnected(args.from_session, args.to_session):
                print("这对会话已在菜单栏断开，请先点关联", file=sys.stderr)
                return 5
        except ValueError as error:
            parser.error(str(error))
        return 0
    if not (args.from_session and args.to_session and args.state):
        parser.error("pair needs --from-session, --to-session and --state")
    if not enabled():
        return 0
    try:
        pairs = update_pair(args.from_session, args.to_session, args.state, args.reason, respect_preference=True)
    except PermissionError as error:
        print(str(error), file=sys.stderr)
        return 5
    except ValueError as error:
        parser.error(str(error))
    if pairs:
        start_best_effort()
    return 0


if __name__ == "__main__":
    sys.exit(main())
