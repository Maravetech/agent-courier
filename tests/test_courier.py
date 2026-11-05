"""Offline tests: a fake CODEX_HOME with hand-written session logs. Never touches a real ~/.codex or the UI."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
import importlib.util
import glob
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "skills", "courier", "scripts", "courier.py")
spec = importlib.util.spec_from_file_location("courier_under_test", SCRIPT)
courier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(courier)

TID = "01aaaaaa-0000-7000-8000-000000000001"
TID2 = "01aaaaaa-0000-7000-8000-000000000002"


def line(ts, typ, payload):
    return json.dumps({"timestamp": ts, "type": typ, "payload": payload}, ensure_ascii=False)


def msg(ts, role, text):
    return line(ts, "response_item", {"type": "message", "role": role,
                                      "content": [{"type": "input_text" if role == "user" else "output_text", "text": text}]})


class CourierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        home = self.tmp.name
        day = os.path.join(home, "sessions", "2026", "01", "02")
        os.makedirs(day)
        os.makedirs(os.path.join(home, "archived_sessions"))
        with open(os.path.join(home, "session_index.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({"id": TID, "thread_name": "00159 test target"}) + "\n")
            f.write(json.dumps({"id": TID2, "thread_name": "00160 archived one"}) + "\n")
        header = "【投递】Claude Code·0007 → Codex·00159"
        rows = [
            msg("2026-01-02T00:00:00.000Z", "user", "<environment_context>ignored</environment_context>"),
            line("2026-01-02T00:00:01.000Z", "event_msg", {"type": "task_started"}),
            msg("2026-01-02T00:00:01.500Z", "user", header + "\n\nhello marker-42\n"),
            msg("2026-01-02T00:00:02.000Z", "assistant", "【回复】Codex·00159 → Claude Code·0007\n收到"),
            line("2026-01-02T00:00:03.000Z", "event_msg", {"type": "task_complete"}),
        ]
        with open(os.path.join(day, f"rollout-2026-01-02T00-00-00-{TID}.jsonl"), "w", encoding="utf-8") as f:
            f.write("\n".join(rows) + "\n")
        with open(os.path.join(home, "archived_sessions", f"rollout-2026-01-01T00-00-00-{TID2}.jsonl"), "w", encoding="utf-8") as f:
            f.write(msg("2026-01-01T00:00:00.000Z", "user", "archived marker-77") + "\n")
        self.env = dict(os.environ, CODEX_HOME=home, COURIER_STATE_DIR=os.path.join(home, "state"))
        self.env.pop("COURIER_AGENTS", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args, env=None):
        r = subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, env=env or self.env)
        return r.returncode, r.stdout + r.stderr

    def write(self, name, text):
        p = os.path.join(self.tmp.name, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p

    def test_find_by_number_and_id(self):
        self.assertEqual(self.run_cli("find", "00159")[0], 0)
        self.assertEqual(self.run_cli("find", TID)[0], 0)
        self.assertEqual(self.run_cli("find", "nope")[0], 1)

    def test_ambiguous(self):
        code, out = self.run_cli("status", "00")
        self.assertEqual(code, 2, out)

    def test_status_idle(self):
        code, out = self.run_cli("status", "00159")
        self.assertEqual(code, 0)
        self.assertIn("空闲", out)

    def test_verify(self):
        self.assertEqual(self.run_cli("verify", TID, "--text", "marker-42")[0], 0)
        self.assertEqual(self.run_cli("verify", TID, "--text", "marker-42", "--since", "2026-01-03T00:00:00Z")[0], 1)
        self.assertEqual(self.run_cli("verify", TID, "--text", "ignored")[0], 1)  # environment context is not a user message

    def test_wait_and_reply_header(self):
        code, out = self.run_cli("wait", TID, "--text", "marker-42", "--timeout", "2")
        self.assertEqual(code, 0, out)
        self.assertIn("回复抬头：✅", out)
        self.assertIn("收到", out)

    def test_wait_timeout(self):
        code, _ = self.run_cli("wait", TID, "--text", "missing-marker", "--timeout", "1", "--interval", "0.2")
        self.assertEqual(code, 3)

    def test_wait_uses_delivery_anchor_even_if_started_late(self):
        code, out = self.run_cli("wait", TID, "--text", "marker-42", "--since", "2026-01-03T00:00:00Z", "--timeout", "1")
        self.assertEqual(code, 0, out)
        self.assertIn("收到", out)

    def test_wait_fails_on_abort_or_wrong_reply_header(self):
        path = glob.glob(os.path.join(self.tmp.name, "sessions", "*", "*", "*", "rollout-*.jsonl"))[0]
        original = Path(path).read_text(encoding="utf-8")
        with open(path, "w", encoding="utf-8") as f:
            f.write(original.replace('"type": "task_complete"', '"type": "turn_aborted"'))
        code, out = self.run_cli("wait", TID, "--text", "marker-42", "--timeout", "1")
        self.assertNotEqual(code, 0, out)
        with open(path, "w", encoding="utf-8") as f:
            f.write(original.replace("【回复】Codex·00159 → Claude Code·0007", "【回复】Codex·00160 → Claude Code·0007"))
        code, out = self.run_cli("wait", TID, "--text", "marker-42", "--timeout", "1")
        self.assertNotEqual(code, 0, out)
        self.assertIsNone(courier.parse_header("【投递】伪造 → Codex·00159\n正文"))

    def test_wait_rejects_delivery_header_for_another_session(self):
        path = glob.glob(os.path.join(self.tmp.name, "sessions", "*", "*", "*", "rollout-*.jsonl"))[0]
        with open(path, encoding="utf-8") as f:
            original = f.read()
        with open(path, "w", encoding="utf-8") as f:
            f.write(original.replace("Codex·00159", "Codex·00160"))
        code, out = self.run_cli("wait", TID, "--text", "marker-42", "--timeout", "1")
        self.assertNotEqual(code, 0, out)

    def test_watch_emits_only_status_transitions(self):
        path = glob.glob(os.path.join(self.tmp.name, "sessions", "*", "*", "*", "rollout-*.jsonl"))[0]
        with open(path, "a", encoding="utf-8") as f:
            f.write(line("2026-01-02T00:00:04.000Z", "event_msg", {"type": "task_started"}) + "\n")
            f.write(line("2026-01-02T00:00:05.000Z", "response_item", {"type": "function_call", "name": "request_user_input"}) + "\n")
            f.write(line("2026-01-02T00:00:06.000Z", "event_msg", {"type": "turn_aborted"}) + "\n")
        code, out = self.run_cli("watch", TID, "--timeout", "0")
        self.assertEqual(code, 0, out)
        self.assertEqual([line.split(" ", 1)[1] for line in out.strip().splitlines()], ["开工", "完成", "开工", "等待确认", "中止"])

    def test_locate_includes_archived(self):
        code, out = self.run_cli("locate", "--text", "marker-77", "--hours", "1000000")
        self.assertEqual(code, 0, out)
        self.assertIn(TID2, out)
        self.assertEqual(self.run_cli("status", TID2)[0], 0)

    def test_compose(self):
        body = self.write("b.txt", "do the thing")
        out_file = os.path.join(self.tmp.name, "o.txt")
        code, out = self.run_cli("compose", "--from-agent", "Claude Code", "--from-session", "0007",
                                 "--to", TID, "--file", body, "--out", out_file)
        self.assertEqual(code, 0, out)
        text = Path(out_file).read_text(encoding="utf-8")
        self.assertTrue(text.startswith("【投递】Claude Code·0007 → Codex·00159"))
        self.assertIn("【回复】Codex·00159 → Claude Code·0007", text)
        code, out = self.run_cli("compose", "--from-agent", "Hermes", "--from-session", "12", "--new", "--file", body)
        self.assertEqual(code, 2)  # session number must be 3+ digits
        code, out = self.run_cli("compose", "--from-agent", "bad|name", "--from-session", "0007", "--new", "--file", body)
        self.assertEqual(code, 2)
        code, out = self.run_cli("compose", "--from-agent", "Codex", "--from-session", "0007", "--new", "--file", out_file)
        self.assertEqual(code, 2)  # already has a header

    def test_agent_allowlist(self):
        body = self.write("b.txt", "x")
        env = dict(self.env, COURIER_AGENTS="Claude Code,Codex")
        self.assertEqual(self.run_cli("compose", "--from-agent", "Hermes", "--from-session", "0007", "--new", "--file", body, env=env)[0], 2)
        self.assertEqual(self.run_cli("compose", "--from-agent", "Codex", "--from-session", "0007", "--new", "--file", body, env=env)[0], 0)

    def test_send_refuses_without_header(self):
        body = self.write("b.txt", "no header here")
        self.assertEqual(self.run_cli("send", "--new", "--file", body)[0], 2)
        self.assertEqual(self.run_cli("ui-send", "--file", body, "--expect-tab", "00159")[0], 2)


    def test_ui_send_requires_exact_target_and_rechecks_before_click(self):
        body = self.write("delivery.txt", "【投递】Claude Code·0007 → Codex·00159\n\nhello")
        args = SimpleNamespace(file=body, expect_tab=None, session_id=None)
        with patch.object(courier, "cua_target", side_effect=RuntimeError("must not call UI")):
            self.assertEqual(courier.cmd_ui_send(args), 2)
        args.expect_tab = "00159 test target"
        args.session_id = TID
        calls = []
        tabs = iter([args.expect_tab, "00160 archived one"])
        with patch.object(courier, "CODEX", self.tmp.name), patch.object(courier, "INDEX", os.path.join(self.tmp.name, "session_index.jsonl")), \
             patch.object(courier, "cua_target", return_value=(42, 1)), patch.object(courier, "cua_tab", side_effect=lambda *_: next(tabs)), \
             patch.object(courier, "cua_textarea", side_effect=[(3, "Message", ""), (3, "Message", Path(body).read_text(encoding="utf-8").rstrip())]), \
             patch.object(courier, "cua_tree", return_value='[9] AXButton "发送"'), patch.object(courier, "cua_front", return_value=[]), \
             patch.object(courier, "cua", side_effect=lambda tool, data: calls.append(tool) or "{}"), patch.object(courier.time, "sleep"):
            self.assertEqual(courier.cmd_ui_send(args), 2)
        self.assertNotIn("click", calls)

    def test_ui_send_rejects_duplicate_titles_before_accessing_ui(self):
        body = self.write("delivery.txt", "【投递】Claude Code·0007 → Codex·00159\n\nhello")
        index = os.path.join(self.tmp.name, "session_index.jsonl")
        with open(index, "a", encoding="utf-8") as f:
            f.write(json.dumps({"id": TID2, "thread_name": "00159 test target"}) + "\n")
        args = SimpleNamespace(file=body, expect_tab="00159 test target", session_id=TID)
        with patch.object(courier, "CODEX", self.tmp.name), patch.object(courier, "INDEX", index), \
             patch.object(courier, "cua_target", side_effect=RuntimeError("must not access UI")):
            self.assertEqual(courier.cmd_ui_send(args), 2)

    def test_ax_textarea_decodes_escaped_newlines_for_draft_check(self):
        with patch.object(courier, "cua_tree", return_value='[3] AXTextArea "Message" = "第一行\\n第二行"'):
            self.assertEqual(courier.cua_textarea(42, 1), (3, "Message", "第一行\n第二行"))

    def test_ci_permissions_and_action_pins(self):
        workflow = Path(os.path.join(os.path.dirname(__file__), '..', '.github', 'workflows', 'ci.yml')).read_text(encoding='utf-8')
        self.assertRegex(workflow, r'permissions:\s*\n\s+contents: read')
        self.assertNotIn('actions/checkout@v4', workflow)
        self.assertNotIn('actions/setup-python@v5', workflow)

    def test_docs_describe_exact_target_and_anchored_wait(self):
        for name in ('README.md', 'README.zh-CN.md'):
            doc = Path(os.path.join(os.path.dirname(__file__), '..', name)).read_text(encoding='utf-8')
            self.assertIn('--session-id <ID>', doc)
            self.assertIn('wait <ID> --text', doc)
            self.assertIn('watch <ID>', doc)


CID = "aaaaaaaa-1111-4222-8333-444444444444"


class ClaudeBackendTest(unittest.TestCase):
    """Claude side is read-only: find / status / verify / wait / watch against a fake ~/.claude."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        h = self.tmp.name
        meta = os.path.join(h, "sessions", "acct", "org")
        os.makedirs(meta)
        for i, (title, t) in enumerate([("0009 old title", 1), ("0009 review", 5)]):
            with open(os.path.join(meta, f"local_{i}.json"), "w") as f:
                json.dump({"cliSessionId": CID, "title": title, "lastActivityAt": t}, f)
        proj = os.path.join(h, "claude", "projects", "-tmp-proj")
        os.makedirs(proj)
        rows = [
            {"type": "user", "timestamp": "2026-01-02T00:00:01.000Z",
             "message": {"role": "user", "content": "【投递】Codex·00159 → Claude Code·0009\n\nreview marker-9"}},
            {"type": "assistant", "timestamp": "2026-01-02T00:00:02.000Z",
             "message": {"role": "assistant", "stop_reason": "tool_use", "content": [{"type": "tool_use"}]}},
            {"type": "user", "timestamp": "2026-01-02T00:00:03.000Z",
             "message": {"role": "user", "content": [{"type": "tool_result", "content": "x"}]}},
            {"type": "assistant", "timestamp": "2026-01-02T00:00:04.000Z",
             "message": {"role": "assistant", "stop_reason": "end_turn",
                         "content": [{"type": "text", "text": "【回复】Claude Code·0009 → Codex·00159\nok"}]}},
        ]
        with open(os.path.join(proj, f"{CID}.jsonl"), "w", encoding="utf-8") as f:
            f.write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
        self.env = dict(os.environ, CLAUDE_CONFIG_DIR=os.path.join(h, "claude"),
                        COURIER_CLAUDE_SESSIONS=os.path.join(h, "sessions"), CODEX_HOME=os.path.join(h, "none"))

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args):
        r = subprocess.run([sys.executable, "-I", SCRIPT, "--app", "claude", *args],
                           capture_output=True, text=True, env=self.env)
        return r.returncode, r.stdout + r.stderr

    def test_find_uses_latest_title(self):
        code, out = self.cli("find", "0009")
        self.assertEqual(code, 0, out)
        self.assertIn("0009 review", out)

    def test_status_verify_wait(self):
        code, out = self.cli("status", CID)
        self.assertIn("空闲", out)
        self.assertEqual(self.cli("verify", CID, "--text", "marker-9")[0], 0)
        code, out = self.cli("wait", CID, "--since", "2026-01-02T00:00:00Z", "--timeout", "2")
        self.assertEqual(code, 0, out)
        self.assertIn("回复抬头：✅", out)

    def test_anchor_wait_and_stream_watch_on_claude_backend(self):
        code, out = self.cli("wait", CID, "--text", "marker-9", "--since", "2026-01-03T00:00:00Z", "--timeout", "1")
        self.assertEqual(code, 0, out)
        self.assertIn("回复抬头：✅", out)
        code, out = self.cli("watch", CID, "--stream", "--timeout", "0")
        self.assertEqual(code, 0, out)
        self.assertEqual([line.split(" ", 1)[1] for line in out.strip().splitlines()], ["开工", "完成"])

    def test_watch_returns_on_turn_end(self):
        code, out = self.cli("watch", CID, "--since", "2026-01-02T00:00:00Z", "--timeout", "2")
        self.assertEqual(code, 0, out)
        self.assertIn("状态恢复", out)
        code, _ = self.cli("watch", CID, "--since", "2026-01-03T00:00:00Z", "--timeout", "1", "--interval", "0.2")
        self.assertEqual(code, 3)

    def test_front_end_refused_for_claude(self):
        self.assertEqual(self.cli("ui-tab")[0], 2)



if __name__ == "__main__":
    unittest.main()
