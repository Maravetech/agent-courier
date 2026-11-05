"""Offline tests: a fake CODEX_HOME with hand-written session logs. Never touches a real ~/.codex or the UI."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "skills", "courier", "scripts", "courier.py")

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
        code, out = self.run_cli("wait", TID, "--since", "2026-01-02T00:00:00Z", "--timeout", "2")
        self.assertEqual(code, 0, out)
        self.assertIn("回复抬头：✅", out)
        self.assertIn("收到", out)

    def test_wait_timeout(self):
        code, _ = self.run_cli("wait", TID, "--since", "2026-01-05T00:00:00Z", "--timeout", "1", "--interval", "0.2")
        self.assertEqual(code, 3)

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
        text = open(out_file, encoding="utf-8").read()
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
        self.assertEqual(self.run_cli("ui-send", "--file", body)[0], 2)


if __name__ == "__main__":
    unittest.main()
