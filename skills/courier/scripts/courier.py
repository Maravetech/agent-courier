#!/usr/bin/env python3
"""courier（投递）助手：定位 Codex 会话、看状态、命令行投递、核对送达、等回复。

find / status / verify / wait 只读 ~/.codex 下的会话索引和 rollout 记录。
send 走命令行通道（codex exec），日志写到 $COURIER_STATE_DIR（默认 ~/.local/state/courier）。
App 里开着的会话要走界面通道（后台电脑操作工具），见上一级的 SKILL.md。

用法：
  codex_thread.py find <标题片段>              列出匹配的会话（ID、标题、rollout 路径）
  codex_thread.py status <ID或标题片段>        当前回合是否在跑 + 最近几条消息
  codex_thread.py verify <ID或标题片段> --text <正文片段> [--since <ISO时间>] [--timeout 30]
                                               轮询核对用户消息是否已写进记录（送达证据）
  codex_thread.py wait <ID或标题片段> --text <唯一投递片段> [--timeout 600]
                                               等对应投递后的首个回合结束，核对最终回复
  codex_thread.py watch <ID或标题片段>            持续输出开工 / 完成 / 中止 / 等待确认的变化

  codex_thread.py compose --from-agent <App或Agent> --from-session <编号> (--to <ID或标题> | --new) --file <正文> [--out <文件>]
                                               加投递抬头「【投递】Claude Code·0007 → Codex·00159」；send 和前端发送都必须用带抬头的正文
  codex_thread.py ui-tab | ui-switch <完整标题> | ui-send --file <带抬头正文> --session-id <ID> --expect-tab <完整标题>
                                               前端备用通道（cua-driver，纯无障碍接口，不截图、不抢焦点）
  codex_thread.py send [<ID或标题>] --file <正文文件> [--new]
                                               命令行通道：--new 新建会话；给 ID 则续接没在 App 里打开的会话

退出码：0 成功；1 没找到 / 未送达 / 回合或身份核验失败；2 参数错误或会话不唯一；3 等待超时；4 会话被 App 占用（active writer）。
"""
import argparse
import glob
import json
import os
import sys
import time

CODEX = os.path.expanduser(os.environ.get("CODEX_HOME", "~/.codex"))
INDEX = os.path.join(CODEX, "session_index.jsonl")


def codex_index():
    """会话索引：同一 ID 取最后一条（最新标题）。"""
    latest = {}
    if not os.path.exists(INDEX):
        return latest
    with open(INDEX, encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("id"):
                latest[d["id"]] = d
    return latest


def codex_log(thread_id):
    hits = glob.glob(os.path.join(CODEX, "sessions", "*", "*", "*", f"rollout-*-{thread_id}.jsonl"))
    hits += glob.glob(os.path.join(CODEX, "archived_sessions", "**", f"rollout-*-{thread_id}.jsonl"), recursive=True)
    return max(hits, key=os.path.getmtime) if hits else None


def resolve(key):
    """ID 精确匹配优先；否则按标题片段匹配，必须唯一。"""
    idx = load_index()
    if key in idx:
        return [idx[key]]
    if rollout_path(key):
        return [{"id": key, "thread_name": "(索引里没有)"}]
    return [d for d in idx.values() if key in (d.get("thread_name") or "")]


def one(key):
    hits = resolve(key)
    if not hits:
        print(f"没找到会话：{key}", file=sys.stderr)
        sys.exit(1)
    if len(hits) > 1:
        print(f"会话不唯一（{len(hits)} 个），请给完整 ID：", file=sys.stderr)
        for d in hits:
            print(f"  {d['id']}  {d.get('thread_name')}", file=sys.stderr)
        sys.exit(2)
    d = hits[0]
    path = rollout_path(d["id"])
    if not path:
        print(f"会话 {d['id']} 没有 rollout 记录", file=sys.stderr)
        sys.exit(1)
    return d, path


def events(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def text_of(payload):
    return "".join(x.get("text", "") for x in payload.get("content", []) if isinstance(x, dict))


def is_real_user(t):
    s = t.lstrip()
    return bool(s) and not s.startswith("<environment_context>") and not s.startswith("<external_")


def codex_scan(path, since=None):
    """返回 (消息列表, 回合是否在跑, 最后一次回合结束时间)。"""
    msgs, running, last_done = [], False, None
    for d in events(path):
        ts = d.get("timestamp", "")
        p = d.get("payload") or {}
        if d.get("type") == "event_msg":
            t = p.get("type")
            if t == "task_started":
                running = True
            elif t in ("task_complete", "turn_aborted"):
                running = False
                last_done = (ts, t)
        elif d.get("type") == "response_item" and p.get("type") == "message":
            role = p.get("role")
            t = text_of(p)
            if role == "assistant" or (role == "user" and is_real_user(t)):
                if since is None or ts >= since:
                    msgs.append((ts, role, t))
    return msgs, running, last_done


# ---------------------------------------------------------------- Claude 后端（只读）
#
# Claude 桌面 App 的会话元数据：<App 数据>/claude-code-sessions/*/*/local_*.json（title、cliSessionId）；
# 会话记录：~/.claude/projects/<项目>/<cliSessionId>.jsonl。回合结束 = assistant 的 stop_reason 为 end_turn。

CLAUDE_HOME = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
CLAUDE_SESSIONS = os.path.expanduser(os.environ.get(
    "COURIER_CLAUDE_SESSIONS", "~/Library/Application Support/Claude/claude-code-sessions"))


def claude_index():
    """cliSessionId → {id, thread_name}；同一会话多份元数据（多账号镜像）取最近活动的那份。"""
    best = {}
    for f in glob.glob(os.path.join(CLAUDE_SESSIONS, "*", "*", "local_*.json")):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except (ValueError, OSError):
            continue
        cid = d.get("cliSessionId")
        if not cid:
            continue
        cur = best.get(cid)
        if cur is None or d.get("lastActivityAt", 0) > cur["_t"]:
            best[cid] = {"id": cid, "thread_name": d.get("title") or "", "_t": d.get("lastActivityAt", 0)}
    return best


def claude_log(cid):
    hits = glob.glob(os.path.join(CLAUDE_HOME, "projects", "*", f"{cid}.jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None


def claude_text(content, role):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
    return "".join(out)


def claude_scan(path, since=None):
    msgs, running, last_done = [], False, None
    for d in events(path):
        if d.get("isSidechain") or d.get("isMeta"):
            continue
        ts = d.get("timestamp", "")
        m = d.get("message") or {}
        typ = d.get("type")
        if typ == "user":
            c = m.get("content")
            if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                continue
            text = claude_text(c, "user")
            if not text.strip() or text.lstrip().startswith("<"):
                continue
            running = True
            if since is None or ts >= since:
                msgs.append((ts, "user", text))
        elif typ == "assistant":
            text = claude_text(m.get("content"), "assistant")
            if m.get("stop_reason") == "end_turn":
                running = False
                last_done = (ts, "end_turn")
            if text.strip() and (since is None or ts >= since):
                msgs.append((ts, "assistant", text))
    return msgs, running, last_done


APP = "codex"   # 由 --app 设置：codex | claude
APP_TOKEN = {"codex": "Codex", "claude": "Claude Code"}


def load_index():
    return claude_index() if APP == "claude" else codex_index()


def rollout_path(tid):
    return claude_log(tid) if APP == "claude" else codex_log(tid)


def scan(path, since=None):
    return claude_scan(path, since) if APP == "claude" else codex_scan(path, since)


def all_logs():
    if APP == "claude":
        return glob.glob(os.path.join(CLAUDE_HOME, "projects", "*", "*.jsonl"))
    files = glob.glob(os.path.join(CODEX, "sessions", "*", "*", "*", "rollout-*.jsonl"))
    return files + glob.glob(os.path.join(CODEX, "archived_sessions", "**", "rollout-*.jsonl"), recursive=True)


def log_id(path):
    base = os.path.basename(path)[:-6]
    return base if APP == "claude" else base.split("-", 6)[-1]


def cmd_watch_once(a):
    """后台盯多个会话：任一会话在 since 之后结束一个回合就退出（状态恢复 = 回合结束）。

    设计给发送方放到后台跑：退出即唤醒发送方，再用 wait/status 读回复。
    """
    targets = [one(k) for k in a.keys]
    deadline = time.time() + (a.timeout if a.timeout is not None else 3600)
    while True:
        for d, path in targets:
            msgs, running, last_done = scan(path, a.since)
            if last_done and last_done[0] >= a.since and not running:
                replies = [m for m in msgs if m[1] == "assistant"]
                tail = replies[-1][2].strip().splitlines()[0][:80] if replies else "（无回复文本）"
                print(f"状态恢复：{d.get('thread_name')}（{d['id']}）回合结束 @ {last_done[0]}")
                print(f"首行：{tail}")
                print(f"下一步：python3 -I {os.path.realpath(__file__)} --app {APP} wait {d['id']} --since {a.since}")
                return 0
        if time.time() > deadline:
            print(f"等待超时（{a.timeout}s）：{len(targets)} 个会话都还没结束回合")
            return 3
        time.sleep(a.interval)


def cmd_find(a):
    hits = resolve(a.key)
    if not hits:
        print("没找到")
        return 1
    for d in hits:
        print(f"{d['id']}\t{d.get('thread_name')}\t{rollout_path(d['id'])}")
    return 0


def cmd_locate(a):
    """按正文片段反查会话：前端新建会话后还不知道 ID 时用。只读，所有会话（含归档）都能查。"""
    files = all_logs()
    cutoff = time.time() - a.hours * 3600
    idx = load_index()
    found = 0
    for path in sorted(files, key=os.path.getmtime, reverse=True):
        if os.path.getmtime(path) < cutoff:
            continue
        msgs, _, _ = scan(path, a.since)
        if any(r == "user" and a.text in t for _, r, t in msgs):
            tid = log_id(path)
            print(f"{tid}\t{(idx.get(tid) or {}).get('thread_name', '(索引暂无标题)')}\t{path}")
            found += 1
    if not found:
        print(f"没找到含「{a.text}」的用户消息（最近 {a.hours} 小时）")
    return 0 if found else 1


def cmd_status(a):
    d, path = one(a.key)
    msgs, running, last_done = scan(path)
    print(f"会话：{d.get('thread_name')}  {d['id']}")
    print(f"记录：{path}")
    print(f"回合：{'正在运行' if running else '空闲'}；最后结束：{last_done}")
    for ts, role, t in (msgs[-a.n:] if a.n > 0 else []):
        print(f"--- {ts} {role}\n{t[:a.chars]}")
    return 0


def cmd_verify(a):
    deadline = time.monotonic() + max(0, a.timeout)
    while True:
        hits = resolve(a.key)
        if len(hits) > 1:
            print("会话不唯一；verify 请给完整 ID", file=sys.stderr)
            return 2
        d = hits[0] if hits else None
        path = rollout_path(d["id"]) if d else None
        if path:
            try:
                msgs, _, _ = scan(path, a.since)
            except FileNotFoundError:
                msgs = []  # record can be created or rotated between polls
            for ts, role, t in msgs:
                if role == "user" and a.text in t:
                    print(f"送达：{ts} user 消息含「{a.text}」  会话 {d['id']}")
                    return 0
        if time.monotonic() >= deadline:
            print(f"未送达：{d['id'] if d else a.key} 在 {a.since or '全部记录'} 之后没有含「{a.text}」的用户消息")
            return 1
        time.sleep(max(0.05, a.interval))


def cmd_wait(a):
    d, path = one(a.key)
    deadline = time.time() + a.timeout
    while True:
        anchors, replies, last_done, running = (delivery_turn(path, a.text) if a.text
                                               else legacy_turn(path, a.since))
        if anchors > 1:
            print("投递锚点不唯一；请提供更独特的 --text", file=sys.stderr)
            return 2
        if anchors == 1 and last_done:
            print(f"回合结束：{last_done[1]} @ {last_done[0]}")
            if last_done[1] == "interleaved":
                print("投递后插入了其他用户消息，不能把回复归给这次投递", file=sys.stderr)
                return 1
            if last_done[1] not in ("task_complete", "end_turn"):
                print("回合中止，未取得完成回执", file=sys.stderr)
                return 1
            assistants = [m for m in replies if m[1] == "assistant" and m[2].strip()]
            if not assistants:
                print("（这一回合没有助手回复）")
                return 1
            ts, _, t = assistants[-1]
            # 回复抬头核对：按本轮最后一条投递的抬头推出应有的回复抬头
            sent = [m for m in replies if m[1] == "user" and parse_header(m[2])]
            if not sent:
                print("投递抬头无效，不能核对回复身份", file=sys.stderr)
                return 1
            f_tok, t_tok = parse_header(sent[0][2])
            expected_target = token(APP_TOKEN[APP], session_number(d.get("thread_name"), d["id"]))
            if t_tok != expected_target and not (t_tok == token(APP_TOKEN[APP], "新建") and d.get("thread_name") == "(索引里没有)"):
                print(f"投递收件令牌与目标会话不符：{t_tok} != {expected_target}", file=sys.stderr)
                return 1
            want = reply_line(f_tok, t_tok)
            got = t.splitlines()[0] if t else ""
            if got != want:
                print(f"回复抬头：❌ 缺或不符（应为「{want}」，实际「{got[:60]}」）")
                return 1
            print(f"回复抬头：✅ {want}")
            print(f"--- 最终回复 {ts}\n{t}")
            return 0
        if time.time() > deadline:
            print(f"等待超时（{a.timeout}s）：回合{'仍在运行' if running else '未开始'}")
            return 3
        time.sleep(a.interval)


def delivery_turn(path, text):
    """Find the first turn end after the unique matching delivery, regardless of wall time."""
    anchors, replies, done, running = 0, [], None, False
    for d in events(path):
        if APP == "claude":
            if d.get("isSidechain") or d.get("isMeta"):
                continue
            m = d.get("message") or {}
            ts = d.get("timestamp", "")
            if d.get("type") == "user":
                c = m.get("content")
                if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                    continue
                value = claude_text(c, "user")
                if value.strip() and not value.lstrip().startswith("<"):
                    if text in value:
                        anchors += 1
                        if anchors == 1:
                            replies, done, running = [(ts, "user", value)], None, True
                    if anchors == 1 and done is None and replies and value != replies[0][2]:
                        done, running = (ts, "interleaved"), False
            elif anchors == 1 and done is None and d.get("type") == "assistant":
                value = claude_text(m.get("content"), "assistant")
                if value.strip():
                    replies.append((ts, "assistant", value))
                if m.get("stop_reason") == "end_turn":
                    done, running = (ts, "end_turn"), False
            continue
        p = d.get("payload") or {}
        ts = d.get("timestamp", "")
        if d.get("type") == "response_item" and p.get("type") == "message":
            role, value = p.get("role"), text_of(p)
            if role == "user" and is_real_user(value):
                if text in value:
                    anchors += 1
                    if anchors == 1:
                        replies = [(ts, "user", value)]
                        done = None
                        running = True
                if anchors == 1 and done is None and replies and value != replies[0][2]:
                    done, running = (ts, "interleaved"), False
            elif anchors == 1 and done is None and role == "assistant":
                replies.append((ts, role, value))
        elif anchors == 1 and done is None and d.get("type") == "event_msg":
            if p.get("type") in ("task_complete", "turn_aborted"):
                done = (ts, p["type"])
                running = False
    return anchors, replies, done, running


def legacy_turn(path, since):
    """Compatibility for callers that used a wall-clock start before delivery anchors existed."""
    msgs, running, done = scan(path, since)
    if not since or not done or done[0] < since:
        return 0, [], None, running
    users = [i for i, m in enumerate(msgs) if m[1] == "user" and parse_header(m[2])]
    if not users:
        return 0, [], None, running
    replies = msgs[users[-1]:]
    intervening = next((m for m in replies[1:] if m[1] == "user"), None)
    if intervening:
        return 1, replies, (intervening[0], "interleaved"), False
    return 1, replies, done, running


def status_event(row):
    """Map rollout control events to a small, private-text-free status stream."""
    payload = row.get("payload") or {}
    kind = payload.get("type")
    if row.get("type") == "event_msg":
        return {"task_started": "开工", "task_complete": "完成", "turn_aborted": "中止",
                "user_input_requested": "等待确认", "approval_request": "等待确认"}.get(kind)
    if row.get("type") == "response_item" and kind == "function_call":
        if payload.get("name") in ("request_user_input", "request_user_input_async", "request_approval"):
            return "等待确认"
    return None


def cmd_watch_stream(a):
    _, path = one(a.keys[0])
    deadline = time.monotonic() + a.timeout if a.timeout is not None else None
    seen, current = 0, None
    while True:
        rows = list(events(path))
        if len(rows) < seen:
            seen, current = 0, None
        for row in rows[seen:]:
            status = claude_status_event(row) if APP == "claude" else status_event(row)
            if status and status != current:
                print(f"{row.get('timestamp', '')} {status}", flush=True)
                current = status
        seen = len(rows)
        if deadline is not None and time.monotonic() >= deadline:
            return 0
        time.sleep(max(0.1, a.interval))


def claude_status_event(row):
    if row.get("isSidechain") or row.get("isMeta"):
        return None
    message = row.get("message") or {}
    if row.get("type") == "user":
        content = message.get("content")
        if isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return None
        return "开工" if claude_text(content, "user").strip() else None
    if row.get("type") == "assistant":
        return "完成" if message.get("stop_reason") == "end_turn" else None
    return None


def cmd_watch(a):
    if a.stream or a.since is None:
        if len(a.keys) != 1:
            print("状态流只接受一个会话", file=sys.stderr)
            return 2
        return cmd_watch_stream(a)
    return cmd_watch_once(a)


# 发送方名称：默认任何不含特殊符号的名字都可以；设置 COURIER_AGENTS（逗号分隔）就只认名单里的
AGENTS = tuple(x.strip() for x in os.environ.get("COURIER_AGENTS", "").split(",") if x.strip())


def agent_ok(name):
    import re
    if AGENTS:
        return name in AGENTS
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}", name or ""))
HEADER_PREFIX = "【投递】"


def token(app, number):
    """身份令牌：App 或 Agent 名 + session 编号，例如「Claude Code·0007」「Codex·00159」。"""
    return f"{app}·{number}"


REPLY_PREFIX = "【回复】"


def header_line(from_token, to_token):
    return f"{HEADER_PREFIX}{from_token} → {to_token}"


def reply_line(from_token, to_token):
    """回复抬头：收件方 → 发件方，方向和投递抬头相反。"""
    return f"{REPLY_PREFIX}{to_token} → {from_token}"


def parse_header(text):
    """从投递正文取 (发件令牌, 收件令牌)；取不到返回 None。"""
    import re
    first = text.splitlines()[0] if text else ""
    match = re.fullmatch(r"【投递】([A-Za-z0-9][A-Za-z0-9 ._-]{0,39}·\d{3,}) → ((?:Codex|Claude Code)·(?:\d{3,}|[0-9a-f]{8}|新建))", first)
    if not match or not agent_ok(match.group(1).rsplit("·", 1)[0]):
        return None
    return match.group(1), match.group(2)


def has_header(text):
    return parse_header(text) is not None


def session_number(thread_name, thread_id):
    import re
    m = re.match(r"\s*(\d{3,})", thread_name or "")
    return m.group(1) if m else thread_id[:8]


def cmd_compose(a):
    """给正文加上投递抬头（谁发给谁），输出到 --out，或者打到标准输出。"""
    if not agent_ok(a.from_agent):
        allowed = "、".join(AGENTS) if AGENTS else "字母数字开头、最多 40 个字符（字母、数字、空格、. _ -）"
        print(f"发送方名称不合规：{allowed}", file=sys.stderr)
        return 2
    import re
    if not re.fullmatch(r"\d{3,}", a.from_session.strip()):
        print("--from-session 只写发送方的 session 编号（数字，例如 0007）", file=sys.stderr)
        return 2
    if a.new:
        to_token = token(APP_TOKEN[APP], "新建")
    else:
        d, _ = one(a.to)
        to_token = token(APP_TOKEN[APP], session_number(d.get("thread_name"), d["id"]))
    body = open(a.file, encoding="utf-8").read().strip()
    if has_header(body):
        print("正文已经带了投递抬头，不要重复加", file=sys.stderr)
        return 2
    from_token = token(a.from_agent, a.from_session.strip())
    out = (header_line(from_token, to_token) + "\n\n" + body + "\n\n"
           + f"（回复要求：回复的第一行原样写「{reply_line(from_token, to_token)}」，第二行起写正文。）\n")
    if a.out:
        open(a.out, "w", encoding="utf-8").write(out)
        print(f"已生成：{a.out}")
        print(out.splitlines()[0])
    else:
        sys.stdout.write(out)
    return 0


LOGDIR = os.path.expanduser(os.environ.get("COURIER_STATE_DIR", "~/.local/state/courier"))


def cmd_send(a):
    """命令行通道：新建会话（--new）或续接一个没在 App 里打开的会话。

    后台起 `codex exec`，等它打出 session id 就返回；送达与回复用 verify / wait 核对。
    会话在 App 里开着时 Codex 会报 active writer，返回 4，改走界面通道。
    """
    import subprocess
    if not os.path.isfile(a.file):
        print(f"正文文件不存在：{a.file}", file=sys.stderr)
        return 2
    parsed = parse_header(open(a.file, encoding="utf-8").read())
    if not parsed:
        print("拒发：正文第一行没有投递抬头（谁发给谁）。先用 compose 生成。", file=sys.stderr)
        return 2
    if a.new:
        if a.key or parsed[1] != token("Codex", "新建"):
            print("拒发：新建会话不得给旧会话键，收件令牌必须是 Codex·新建", file=sys.stderr)
            return 2
    else:
        if not a.key:
            print("续接已有会话要给 ID 或标题；新建会话用 --new", file=sys.stderr)
            return 2
        d, _ = one(a.key)
        if parsed[1] != token("Codex", session_number(d.get("thread_name"), d["id"])):
            print("拒发：投递抬头的收件令牌与目标会话不符", file=sys.stderr)
            return 2
    os.makedirs(LOGDIR, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    log = os.path.join(LOGDIR, f"send-{stamp}.log")
    if a.new:
        argv = ["codex", "exec", "--skip-git-repo-check", "-s", a.sandbox, "-"]
        tid = None
    else:
        tid = d["id"]
        argv = ["codex", "exec", "resume", tid, "-"]
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(a.file, "rb") as body, open(log, "wb") as out:
        subprocess.Popen(argv, stdin=body, stdout=out, stderr=subprocess.STDOUT,
                         cwd=a.cwd or os.getcwd(), start_new_session=True)
    deadline = time.time() + 30
    while time.time() < deadline:
        time.sleep(1)
        txt = open(log, encoding="utf-8", errors="replace").read()
        if "active writer" in txt:
            print("被拒：目标会话在 Codex App 里开着（active writer）。改走界面通道，见 SKILL.md。")
            print(f"日志：{log}")
            return 4
        for line in txt.splitlines():
            if line.startswith("session id:"):
                sid = line.split(":", 1)[1].strip()
                print(f"已提交：会话 {sid}  SINCE={since}")
                print(f"日志：{log}")
                print(f"下一步：先 verify {sid} --text <唯一投递片段>，再 wait {sid} --text <唯一投递片段>")
                return 0
    print(f"30 秒内没拿到 session id，看日志：{log}")
    return 1


# ---------------------------------------------------------------- 前端备用通道：cua-driver（纯无障碍接口，不截图）
#
# 2026-11-05 实测：get_window_state(capture_mode=ax) 读、set_value 写输入框、AXPress 点左侧会话和「发送」按钮，
# 全程前台不变。唯一抢过焦点的是 AXPress 输入框本身 —— 本实现从不点输入框。

CODEX_BUNDLE = "com.openai.codex"
STOP_LABELS = tuple(x for x in os.environ.get("COURIER_STOP_LABELS", "停止,Stop,停止する,Stopp,Arrêter,Detener").split(",") if x)
SEND_LABELS = tuple(x for x in os.environ.get("COURIER_SEND_LABELS", "发送,Send,送信,Senden,Envoyer,Enviar").split(",") if x)


def cua(tool, args):
    import subprocess
    r = subprocess.run(["cua-driver", "call", tool, json.dumps(args, ensure_ascii=False)],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"cua-driver {tool} 失败：{(r.stderr or r.stdout).strip()[:200]}")
    return r.stdout


def cua_target(window_id=None):
    """返回 (pid, window_id)：多窗口时必须明确指定目标窗口。"""
    apps = json.loads(cua("list_apps", {}))["apps"]
    pid = next((a["pid"] for a in apps if a.get("bundle_id") == CODEX_BUNDLE and a.get("running")), None)
    if not pid:
        raise RuntimeError("Codex App 没在运行")
    wins = json.loads(cua("list_windows", {"pid": pid}))["windows"]
    wins = [w for w in wins if w.get("is_on_screen") and w["bounds"]["height"] > 200]
    if not wins:
        raise RuntimeError("Codex 没有在屏上的主窗口（最小化或在别的桌面空间）")
    if window_id is not None:
        chosen = [w for w in wins if w["window_id"] == window_id]
        if len(chosen) != 1:
            raise RuntimeError("指定的 Codex 窗口不在屏上")
        return pid, chosen[0]["window_id"]
    if len(wins) != 1:
        raise RuntimeError("Codex 同时有多个屏上窗口；请用 --window-id 指定目标")
    return pid, wins[0]["window_id"]


def cua_tree(pid, wid, query):
    return json.loads(cua("get_window_state", {"pid": pid, "window_id": wid, "capture_mode": "ax", "query": query}))["tree_markdown"]


def cua_front():
    apps = json.loads(cua("list_apps", {}))["apps"]
    return [a.get("name") for a in apps if a.get("active")]


def cua_tab(pid, wid):
    import re
    m = re.findall(r'AXRadioButton "([^"]+)"', cua_tree(pid, wid, "AXRadioButton"))
    return m[0] if m else None


def cua_textarea(pid, wid):
    """返回 (index, 占位文字, 当前值)。读取未过滤树，保留多行 AXValue。"""
    import re
    m = re.search(r'\[(\d+)\] AXTextArea "([^"]*)"(?: = "((?:[^"\\]|\\.)*))?', cua_tree(pid, wid, ""))
    if not m:
        raise RuntimeError("找不到输入框")
    value = m.group(3) or ""
    try:
        value = json.loads('"' + value + '"')
    except ValueError:
        pass
    return int(m.group(1)), m.group(2), value


def cmd_ui_tab(a):
    pid, wid = cua_target(getattr(a, "window_id", None))
    print(f"当前标签页：{cua_tab(pid, wid)}  前台：{cua_front()}")
    return 0


def cmd_ui_switch(a):
    """后台点左侧会话按钮（按标题），切完核对标签页。"""
    import re
    matches = [d for d in load_index().values() if d.get("thread_name") == a.title]
    if len(matches) != 1:
        print("拒绝切页：必须给索引中唯一的完整标题")
        return 2
    pid, wid = cua_target(getattr(a, "window_id", None))
    before = cua_front()
    hits = re.findall(r'\[(\d+)\] AXButton "([^"]+)"', cua_tree(pid, wid, a.title))
    hits = [(i, t) for i, t in hits if a.title == t]
    if not hits:
        print(f"左侧列表里没找到「{a.title}」")
        return 1
    if len(hits) != 1:
        print(f"左侧列表有 {len(hits)} 个标题匹配；请给唯一完整标题")
        return 2
    cua("click", {"pid": pid, "window_id": wid, "element_index": int(hits[0][0])})
    time.sleep(1.5)
    tab = cua_tab(pid, wid)
    print(f"已切换：标签页「{tab}」  前台 {before} → {cua_front()}")
    return 0 if tab == a.title and before == cua_front() else 1


def cmd_ui_send(a):
    """写输入框（set_value 整框）+ 点「发送」。输入框非空（有草稿）一律拒绝，不覆盖。"""
    import re
    with open(a.file, encoding="utf-8") as source:
        body = source.read().rstrip()
    if not has_header(body):
        print("拒发：正文第一行没有投递抬头。先用 compose 生成。", file=sys.stderr)
        return 2
    if not getattr(a, "session_id", None) or not a.expect_tab:
        print("拒发：必须给完整 --session-id 与 --expect-tab", file=sys.stderr)
        return 2
    d, _ = one(a.session_id)
    if d["id"] != a.session_id or d.get("thread_name") != a.expect_tab:
        print("拒发：会话 ID 与完整标题不一致", file=sys.stderr)
        return 2
    if sum(x.get("thread_name") == a.expect_tab for x in load_index().values()) != 1:
        print("拒发：完整标题在会话索引中不唯一", file=sys.stderr)
        return 2
    parsed = parse_header(body)
    if not parsed or parsed[1] != token("Codex", session_number(d.get("thread_name"), d["id"])):
        print("拒发：正文收件令牌与目标会话不符", file=sys.stderr)
        return 2
    pid, wid = cua_target(getattr(a, "window_id", None))
    tab = cua_tab(pid, wid)
    if tab != a.expect_tab:
        print(f"拒发：当前标签页是「{tab}」，不是「{a.expect_tab}」。先 ui-switch。")
        return 2
    before = cua_front()
    for lab in STOP_LABELS:  # 界面有「停止」按钮 = 目标会话正在跑回合：不写入、不插话
        if re.search(r'\] AXButton "' + re.escape(lab) + '"', cua_tree(pid, wid, lab)):
            print(f"拒发：目标会话正在运行回合（界面有「{lab}」按钮）。先 watch 等它状态恢复。")
            return 2
    idx, placeholder, value = cua_textarea(pid, wid)
    if value.strip() and value.strip() != placeholder.strip():
        print("拒发：输入框里有草稿，不覆盖，也不打印草稿内容。")
        return 2
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cua("set_value", {"pid": pid, "window_id": wid, "element_index": idx, "value": body})
    time.sleep(0.4)
    if cua_target(getattr(a, "window_id", None)) != (pid, wid) or cua_tab(pid, wid) != a.expect_tab:
        print("拒发：写入后目标窗口或标签页已变化；草稿保留")
        return 2
    new_idx, _, new_value = cua_textarea(pid, wid)
    if new_idx != idx or new_value != body:
        print("拒发：写入后的正文与原文不一致；草稿保留")
        return 2
    btn = None
    for lab in SEND_LABELS:  # 按按钮文字单独查：查全部按钮会被截断
        m = re.search(r'\[(\d+)\] AXButton "' + re.escape(lab) + '"', cua_tree(pid, wid, lab))
        if m:
            btn = int(m.group(1))
            break
    if btn is None:
        print("写入了但找不到「发送」按钮，没有发送。请人工检查输入框。")
        return 1
    if cua_target(getattr(a, "window_id", None)) != (pid, wid) or cua_tab(pid, wid) != a.expect_tab:
        print("拒发：点击前目标窗口或标签页已变化；草稿保留")
        return 2
    cua("click", {"pid": pid, "window_id": wid, "element_index": btn})
    print(f"已点发送：标签页「{tab}」  SINCE={since}  前台 {before} → {cua_front()}")
    print("下一步：verify / wait 核对送达与回复")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", choices=["codex", "claude"], default="codex",
                    help="读哪个 App 的会话：codex（默认）或 claude（只读后端）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    wa = sub.add_parser("watch"); wa.add_argument("keys", nargs="+"); wa.add_argument("--since")
    wa.add_argument("--stream", action="store_true")
    wa.add_argument("--timeout", type=float); wa.add_argument("--interval", type=float, default=2)
    wa.set_defaults(fn=cmd_watch)
    f = sub.add_parser("find"); f.add_argument("key"); f.set_defaults(fn=cmd_find)
    s = sub.add_parser("status"); s.add_argument("key")
    s.add_argument("-n", type=int, default=4); s.add_argument("--chars", type=int, default=600)
    s.set_defaults(fn=cmd_status)
    v = sub.add_parser("verify"); v.add_argument("key"); v.add_argument("--text", required=True)
    v.add_argument("--since"); v.add_argument("--timeout", type=float, default=30)
    v.add_argument("--interval", type=float, default=1); v.set_defaults(fn=cmd_verify)
    w = sub.add_parser("wait"); w.add_argument("key"); w.add_argument("--text"); w.add_argument("--since")
    w.add_argument("--timeout", type=int, default=600); w.add_argument("--interval", type=float, default=3)
    w.set_defaults(fn=cmd_wait)
    c = sub.add_parser("compose"); c.add_argument("--from-agent", required=True)
    c.add_argument("--from-session", required=True); c.add_argument("--to"); c.add_argument("--new", action="store_true")
    c.add_argument("--file", required=True); c.add_argument("--out"); c.set_defaults(fn=cmd_compose)
    lo = sub.add_parser("locate"); lo.add_argument("--text", required=True); lo.add_argument("--since")
    lo.add_argument("--hours", type=float, default=24); lo.set_defaults(fn=cmd_locate)
    ut = sub.add_parser("ui-tab"); ut.add_argument("--window-id", type=int); ut.set_defaults(fn=cmd_ui_tab)
    us = sub.add_parser("ui-switch"); us.add_argument("title"); us.add_argument("--window-id", type=int); us.set_defaults(fn=cmd_ui_switch)
    ud = sub.add_parser("ui-send"); ud.add_argument("--file", required=True); ud.add_argument("--session-id", required=True); ud.add_argument("--expect-tab", required=True); ud.add_argument("--window-id", type=int)
    ud.set_defaults(fn=cmd_ui_send)
    n = sub.add_parser("send"); n.add_argument("key", nargs="?"); n.add_argument("--file", required=True)
    n.add_argument("--new", action="store_true"); n.add_argument("--cwd")
    n.add_argument("--sandbox", default="workspace-write", choices=["read-only", "workspace-write"])
    n.set_defaults(fn=cmd_send)
    a = ap.parse_args()
    if a.cmd == "wait" and not (a.text or a.since):
        ap.error("wait 需要 --text <唯一投递片段>，旧调用可用 --since <时间>")
    global APP
    APP = a.app
    if APP == "claude" and a.cmd in ("send", "ui-send", "ui-switch", "ui-tab"):
        print("Claude 会话只支持只读后端（find/locate/status/verify/wait/watch/compose）；前端写入只面向 Codex。", file=sys.stderr)
        sys.exit(2)
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
