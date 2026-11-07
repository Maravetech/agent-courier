#!/usr/bin/env python3
"""One-process Claude SendMessage gate; invoked only through temporary CLI hooks.

The state file is private and short-lived. A successful ListAgents result must
name exactly one Claude Desktop session before the one SendMessage call can run.
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import sys


def listagents_result(value):
    """Find the structured ListAgents result, never assistant prose."""
    if isinstance(value, str):
        try:
            return listagents_result(json.loads(value))
        except ValueError:
            return None
    if isinstance(value, list):
        for item in value:
            found = listagents_result(item)
            if found is not None:
                return found
    if isinstance(value, dict):
        if isinstance(value.get("listing"), str) and isinstance(value.get("sections"), list):
            return value
        for key in ("tool_response", "tool_use_result", "content", "result", "text"):
            if key in value:
                found = listagents_result(value[key])
                if found is not None:
                    return found
    return None


def unique_desktop_target(value, title):
    result = listagents_result(value)
    if not result:
        return False
    rows = []
    for section in result["sections"]:
        if not isinstance(section, dict) or not isinstance(section.get("rows"), list):
            return False
        rows.extend(section["rows"])
    matches = [row for row in rows if isinstance(row, dict) and row.get("name") == title]
    if (len(matches) != 1 or not isinstance(matches[0].get("ref"), str)
            or matches[0].get("status") not in ("busy", "idle")):
        return False
    ref = matches[0]["ref"]
    if not re.fullmatch(r"[0-9a-f]{6,12}", ref):
        return False
    lines = []
    for line in result["listing"].splitlines():
        fields = re.split(r"\s+·\s+", line.strip())
        if len(fields) < 4:
            continue
        match = re.fullmatch(r"(.+?) \[([0-9a-f]{6,12})\]", fields[0])
        if match and match.group(1) == title:
            lines.append((match.group(2), fields[2], fields[3]))
    return lines == [(ref, matches[0]["status"], "Claude Desktop session")]


def decide(state, event):
    """Return (updated state, allowed); reject unknown or repeated calls."""
    name = event.get("tool_name")
    kind = event.get("hook_event_name")
    session = event.get("session_id")
    if not isinstance(session, str) or not session:
        return state, False
    if kind == "PreToolUse" and name == "ListAgents":
        state["list_attempts"] += 1
        allowed = state["list_attempts"] == 1 and state["send_attempts"] == 0
        if allowed:
            state["session_id"] = session
        return state, allowed
    if kind == "PostToolUse" and name == "ListAgents":
        allowed = (state["list_attempts"] == 1 and state["session_id"] == session
                   and not state["list_verified"] and
                   unique_desktop_target(event.get("tool_response"), state["title"]))
        state["list_verified"] = bool(allowed)
        return state, allowed
    if kind == "PreToolUse" and name == "SendMessage":
        state["send_attempts"] += 1
        args = event.get("tool_input")
        allowed = (state["send_attempts"] == 1 and state["list_attempts"] == 1
                   and state["list_verified"] and state["session_id"] == session
                   and isinstance(args, dict) and args.get("to") == state["title"]
                   and isinstance(args.get("message"), str)
                   and hashlib.sha256(args["message"].encode("utf-8")).hexdigest() == state["body_sha256"]
                   and ("recipient" not in args or args["recipient"] == state["title"]))
        state["send_allowed"] = bool(allowed)
        return state, allowed
    return state, False


def run_hook(path, event):
    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        directory = os.stat(os.path.dirname(path))
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                info.st_nlink != 1 or info.st_mode & 0o777 != 0o600 or
                info.st_size > 4096 or not stat.S_ISDIR(directory.st_mode) or
                directory.st_uid != os.getuid() or directory.st_mode & 0o777 != 0o700):
            raise ValueError("unsafe gate state")
        fcntl.flock(fd, fcntl.LOCK_EX)
        state = json.loads(os.read(fd, 4097).decode("utf-8"))
        state, allowed = decide(state, event)
        os.lseek(fd, 0, os.SEEK_SET)
        os.ftruncate(fd, 0)
        os.write(fd, json.dumps(state, ensure_ascii=False).encode("utf-8"))
        return allowed
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    args = parser.parse_args()
    event = {}
    try:
        event = json.load(sys.stdin)
        allowed = run_hook(args.state, event)
    except (OSError, ValueError, KeyError, TypeError, UnicodeError):
        allowed = False
    if event.get("hook_event_name") == "PreToolUse":
        outcome = "allow" if allowed else "deny"
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
             "permissionDecision": outcome,
             "permissionDecisionReason": "courier verified target" if allowed else "courier target gate refused"}}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
