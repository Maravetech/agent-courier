"""Offline tests: a fake CODEX_HOME with hand-written session logs. Never touches a real ~/.codex or the UI."""
import json
import os
import subprocess
import time
import sys
import tempfile
import unittest
import importlib.util
import glob
import io
from contextlib import redirect_stdout
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
        self.old_logdir = courier.LOGDIR
        courier.LOGDIR = os.path.join(home, 'state')
        self.old_native_ax = courier.USE_NATIVE_AX
        courier.USE_NATIVE_AX = False  # legacy fixture cases still exercise their parsing helpers
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
        courier.LOGDIR = self.old_logdir
        courier.USE_NATIVE_AX = self.old_native_ax
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

    def test_status_zero_messages_hides_message_bodies(self):
        code, out = self.run_cli('status', TID, '-n', '0')
        self.assertEqual(code, 0, out)
        self.assertNotIn('marker-42', out)
        self.assertNotIn('--- 2026-', out)

    def test_verify(self):
        self.assertEqual(self.run_cli("verify", TID, "--text", "marker-42")[0], 0)
        self.assertEqual(self.run_cli("verify", TID, "--text", "marker-42", "--since", "2026-01-03T00:00:00Z", "--timeout", "0")[0], 1)
        self.assertEqual(self.run_cli("verify", TID, "--text", "ignored", "--timeout", "0")[0], 1)  # environment context is not a user message

    def test_verify_polls_until_delayed_delivery_appears(self):
        proc = subprocess.Popen([sys.executable, '-I', SCRIPT, 'verify', TID, '--text', 'delayed-marker', '--timeout', '2', '--interval', '0.05'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env)
        time.sleep(0.2)
        path = glob.glob(os.path.join(self.tmp.name, 'sessions', '*', '*', '*', 'rollout-*.jsonl'))[0]
        with open(path, 'a', encoding='utf-8') as f:
            f.write(msg('2026-01-02T00:00:04.000Z', 'user', 'delayed-marker') + '\n')
        out, err = proc.communicate(timeout=3)
        self.assertEqual(proc.returncode, 0, out + err)

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

    def test_wait_rejects_interleaved_user_message(self):
        path = glob.glob(os.path.join(self.tmp.name, 'sessions', '*', '*', '*', 'rollout-*.jsonl'))[0]
        original = Path(path).read_text(encoding='utf-8')
        extra = msg('2026-01-02T00:00:01.750Z', 'user', 'another user request') + '\n'
        marker = msg('2026-01-02T00:00:02.000Z', 'assistant', '【回复】Codex·00159 → Claude Code·0007\n收到')
        Path(path).write_text(original.replace(marker, extra + marker), encoding='utf-8')
        code, out = self.run_cli('wait', TID, '--text', 'marker-42', '--timeout', '1')
        self.assertEqual(code, 1, out)
        self.assertIn('其他用户消息', out)

    def test_wait_accepts_initial_cli_new_delivery_after_auto_title(self):
        path = glob.glob(os.path.join(self.tmp.name, 'sessions', '*', '*', '*', 'rollout-*.jsonl'))[0]
        raw = Path(path).read_text(encoding='utf-8').replace('Codex·00159', 'Codex·新建')
        Path(path).write_text(raw, encoding='utf-8')
        index = os.path.join(self.tmp.name, 'session_index.jsonl')
        with open(index, 'a', encoding='utf-8') as f:
            f.write(json.dumps({'id': TID, 'thread_name': 'auto generated title'}) + '\n')
        code, out = self.run_cli('wait', TID, '--text', 'marker-42', '--timeout', '1')
        self.assertEqual(code, 0, out)

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

    def segmented_rollout(self):
        segment_id = '01aaaaaa-0000-7000-8000-000000000099'
        path = os.path.join(self.tmp.name, 'sessions', '2026', '01', '02',
                            f'rollout-2026-01-02T00-10-00-{TID}_{segment_id}.jsonl')
        header = '【投递】Claude Code·0007 → Codex·00159'
        rows = [
            line('2026-01-02T00:10:00.000Z', 'event_msg', {'type': 'task_started'}),
            msg('2026-01-02T00:10:01.000Z', 'user', header + '\n\nsegment-marker-93 marker-42'),
            msg('2026-01-02T00:10:02.000Z', 'assistant', '【回复】Codex·00159 → Claude Code·0007\nsegment-done'),
            line('2026-01-02T00:10:03.000Z', 'event_msg', {'type': 'task_complete'}),
        ]
        Path(path).write_text('\n'.join(rows) + '\n', encoding='utf-8')
        return path

    def test_segmented_find_and_status_use_latest_segment(self):
        new_path = self.segmented_rollout()
        code, found = self.run_cli('find', TID)
        self.assertEqual(code, 0, found)
        self.assertIn(new_path, found)
        code, status = self.run_cli('status', TID, '-n', '1')
        self.assertEqual(code, 0, status)
        self.assertIn('2026-01-02T00:10:03.000Z', status)
        self.assertIn('segment-done', status)

    def test_segmented_verify_and_wait_find_delivery_after_abort(self):
        self.segmented_rollout()
        code, verified = self.run_cli('verify', TID, '--text', 'segment-marker-93', '--timeout', '0')
        self.assertEqual(code, 0, verified)
        code, waited = self.run_cli('wait', TID, '--text', 'segment-marker-93', '--timeout', '0')
        self.assertEqual(code, 0, waited)
        self.assertIn('回复抬头：✅', waited)
        self.assertIn('segment-done', waited)

    def test_segmented_locate_returns_one_session(self):
        self.segmented_rollout()
        code, located = self.run_cli('locate', '--text', 'marker-42', '--hours', '1000000')
        self.assertEqual(code, 0, located)
        self.assertEqual(len(located.strip().splitlines()), 1)

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

    def test_send_rejects_wrong_recipient_and_malformed_target(self):
        self.assertIsNone(courier.parse_header('【投递】Claude Code·0007 → Codex·foobar\nhello'))
        self.assertIsNone(courier.parse_header('【投递】Claude Code·0007 → Hermes·00159\nhello'))
        with patch.object(courier, 'AGENTS', ('Claude Code', 'Codex')):
            self.assertIsNone(courier.parse_header('【投递】Unknown Sender·0007 → Codex·00159\nhello'))
        wrong = self.write('wrong.txt', '【投递】Claude Code·0007 → Codex·00160\n\nhello')
        self.assertEqual(self.run_cli('send', TID, '--file', wrong)[0], 2)
        not_new = self.write('not-new.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        self.assertEqual(self.run_cli('send', '--new', '--file', not_new)[0], 2)


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

    def test_ui_send_rechecks_target_immediately_before_write(self):
        body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID)
        calls = []
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 1)), patch.object(courier, 'cua_tab', side_effect=[args.expect_tab, '00160 archived one']), \
             patch.object(courier, 'cua_textarea', return_value=(3, 'Message', '')), patch.object(courier, 'cua_tree', return_value=''), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier, 'cua', side_effect=lambda tool, data: calls.append((tool, data)) or '{}'):
            self.assertEqual(courier.cmd_ui_send(args), 2)
        self.assertFalse(any(tool == 'set_value' for tool, _ in calls))

    def test_ui_send_missing_button_restores_empty_draft(self):
        body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        value = Path(body).read_text(encoding='utf-8')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID)
        calls, output = [], io.StringIO()
        textareas = [(3, 'Message', ''), (3, 'Message', value), (3, 'Message', value), (3, 'Message', '')]
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 1)), patch.object(courier, 'cua_tab', return_value=args.expect_tab), \
             patch.object(courier, 'cua_textarea', side_effect=textareas), patch.object(courier, 'cua_tree', side_effect=lambda _p, _w, q: '[8] AXRadioButton "00159 test target"' if q == '' else ''), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier, 'cua', side_effect=lambda tool, data: calls.append((tool, data)) or '{}'), \
             patch.object(courier.time, 'sleep'), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_send(args), 1)
        self.assertEqual([data['value'] for tool, data in calls if tool == 'set_value'], [value, ''])
        self.assertNotIn('click', [tool for tool, _ in calls])
        self.assertIn('已还原', output.getvalue())

    def test_ui_send_button_comes_from_same_window_and_tab_snapshot(self):
        body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        value = Path(body).read_text(encoding='utf-8')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID, window_id=1)
        calls = []
        def tree(_pid, wid, query):
            calls.append(('snapshot', {'window_id': wid, 'query': query}))
            return '[8] AXRadioButton "00159 test target"\n[9] AXButton "发送"' if query == '' else ''
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 1)), patch.object(courier, 'cua_tab', return_value=args.expect_tab), \
             patch.object(courier, 'cua_textarea', side_effect=[(3, 'Message', ''), (3, 'Message', value)]), \
             patch.object(courier, 'cua_tree', side_effect=tree), patch.object(courier, 'cua_front', return_value=[]), \
             patch.object(courier, 'cua', side_effect=lambda tool, data: calls.append((tool, data)) or '{}'), patch.object(courier.time, 'sleep'):
            self.assertEqual(courier.cmd_ui_send(args), 0)
        self.assertEqual(calls[-2], ('snapshot', {'window_id': 1, 'query': ''}))
        self.assertEqual(calls[-1], ('click', {'pid': 42, 'window_id': 1, 'element_index': 9}))

    def test_ui_send_ignores_button_text_inside_static_content(self):
        body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        value = Path(body).read_text(encoding='utf-8')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID)
        calls, output = [], io.StringIO()
        textareas = [(3, 'Message', ''), (3, 'Message', value), (3, 'Message', value), (3, 'Message', '')]
        tree = '[8] AXRadioButton "00159 test target"\nAXStaticText = [9] AXButton "发送"'
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 1)), patch.object(courier, 'cua_tab', return_value=args.expect_tab), \
             patch.object(courier, 'cua_textarea', side_effect=textareas), patch.object(courier, 'cua_tree', side_effect=lambda _p, _w, q: tree if q == '' else ''), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier, 'cua', side_effect=lambda tool, data: calls.append((tool, data)) or '{}'), \
             patch.object(courier.time, 'sleep'), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_send(args), 1)
        self.assertNotIn('click', [tool for tool, _ in calls])
        self.assertIn('已还原', output.getvalue())

    def test_ui_send_does_not_clear_another_tab_after_postwrite_switch(self):
        body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        value = Path(body).read_text(encoding='utf-8')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID)
        calls, output = [], io.StringIO()
        tabs = iter([args.expect_tab, args.expect_tab, '00160 archived one', '00160 archived one'])
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 1)), patch.object(courier, 'cua_tab', side_effect=lambda *_: next(tabs)), \
             patch.object(courier, 'cua_textarea', side_effect=[(3, 'Message', ''), (3, 'Message', value)]), patch.object(courier, 'cua_tree', return_value=''), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier, 'cua', side_effect=lambda tool, data: calls.append((tool, data)) or '{}'), \
             patch.object(courier.time, 'sleep'), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_send(args), 2)
        self.assertEqual(len([tool for tool, _ in calls if tool == 'set_value']), 1)
        self.assertIn('未还原', output.getvalue())

    def test_ui_send_rejects_duplicate_titles_before_accessing_ui(self):
        body = self.write("delivery.txt", "【投递】Claude Code·0007 → Codex·00159\n\nhello")
        index = os.path.join(self.tmp.name, "session_index.jsonl")
        with open(index, "a", encoding="utf-8") as f:
            f.write(json.dumps({"id": TID2, "thread_name": "00159 test target"}) + "\n")
        args = SimpleNamespace(file=body, expect_tab="00159 test target", session_id=TID)
        with patch.object(courier, "CODEX", self.tmp.name), patch.object(courier, "INDEX", index), \
             patch.object(courier, "cua_target", side_effect=RuntimeError("must not access UI")):
            self.assertEqual(courier.cmd_ui_send(args), 2)

    def test_ui_send_rejects_header_for_another_tab_before_ui(self):
        body = self.write('wrong-tab.txt', '【投递】Claude Code·0007 → Codex·00172\n\nhello')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID)
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', side_effect=AssertionError('UI must not be accessed')):
            self.assertEqual(courier.cmd_ui_send(args), 2)

    def test_cross_process_ui_lock_blocks_switch_and_send(self):
        import textwrap
        lock_file = os.path.join(self.tmp.name, 'codex-ui.lock')
        holder = textwrap.dedent('''
            import fcntl, json, os, sys, time
            fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            os.write(fd, json.dumps({'pid': os.getpid(), 'command': 'fixture-holder', 'started_at': '2026-01-02T00:00:00Z'}).encode())
            print('READY', flush=True)
            time.sleep(5)
        ''')
        proc = subprocess.Popen([sys.executable, '-c', holder, lock_file], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(proc.stdout.readline().strip(), 'READY')
            body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
            send_args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID, lock_timeout=0.1)
            switch_args = SimpleNamespace(title='00159 test target', lock_timeout=0.1)
            tab_args = SimpleNamespace(lock_timeout=0.1)
            out = io.StringIO()
            with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
                 patch.object(courier, 'LOGDIR', self.tmp.name), \
                 patch.object(courier, 'cua_target', side_effect=AssertionError('UI must not be accessed')), \
                 redirect_stdout(out):
                self.assertEqual(courier.cmd_ui_switch(switch_args), 2)
                self.assertEqual(courier.cmd_ui_send(send_args), 2)
                self.assertEqual(courier.cmd_ui_tab(tab_args), 2)
            self.assertIn('fixture-holder', out.getvalue())
        finally:
            proc.terminate()
            proc.wait(timeout=5)
            proc.stdout.close()

    def test_ui_lock_releases_after_exception(self):
        with patch.object(courier, 'LOGDIR', self.tmp.name):
            with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
                with courier.ui_writer_lock(0.1, 'fixture'):
                    raise RuntimeError('fixture failure')
            with courier.ui_writer_lock(0.1, 'fixture-again'):
                pass

    def test_ui_lock_refuses_symlink_without_touching_target(self):
        target = self.write('protected.txt', 'untouched')
        os.symlink(target, os.path.join(self.tmp.name, 'codex-ui.lock'))
        with patch.object(courier, 'LOGDIR', self.tmp.name):
            with self.assertRaises(OSError):
                with courier.ui_writer_lock(0.1, 'fixture'):
                    pass
        self.assertEqual(Path(target).read_text(encoding='utf-8'), 'untouched')

    def test_ui_send_refuses_draft_without_echoing_private_text(self):
        body = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        args = SimpleNamespace(file=body, expect_tab='00159 test target', session_id=TID)
        out = io.StringIO()
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 1)), patch.object(courier, 'cua_tab', return_value=args.expect_tab), \
             patch.object(courier, 'cua_textarea', return_value=(3, 'Message', 'PRIVATE_DRAFT_MARKER')), \
             patch.object(courier, 'cua_tree', return_value=''), patch.object(courier, 'cua_front', return_value=[]), \
             redirect_stdout(out):
            self.assertEqual(courier.cmd_ui_send(args), 2)
        self.assertNotIn('PRIVATE_DRAFT_MARKER', out.getvalue())

    def test_ui_switch_requires_exact_unique_index_title(self):
        args = SimpleNamespace(title='00159 test')
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', side_effect=RuntimeError('UI must not be accessed')):
            self.assertEqual(courier.cmd_ui_switch(args), 2)

    def test_cua_target_can_select_exact_window_when_two_are_open(self):
        apps = json.dumps({'apps': [{'pid': 42, 'bundle_id': courier.CODEX_BUNDLE, 'running': True}]})
        wins = json.dumps({'windows': [
            {'window_id': 111, 'is_on_screen': True, 'bounds': {'height': 500}},
            {'window_id': 222, 'is_on_screen': True, 'bounds': {'height': 500}},
        ]})
        with patch.object(courier, 'cua', side_effect=[apps, wins]):
            self.assertEqual(courier.cua_target(222), (42, 222))

    def test_ui_switch_scopes_double_axwindow_and_reports_actual_tab(self):
        args = SimpleNamespace(title='00159 test target', window_id=111)
        clicked = []
        def fake_cua(tool, data):
            if tool == 'list_windows':
                return json.dumps({'windows': [
                    {'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}},
                    {'window_id': 222, 'title': 'Other', 'is_on_screen': False, 'bounds': {'height': 500}},
                ]})
            if tool == 'get_window_state':
                tree = ('- [0] AXWindow "Main"\n'
                        '  - [9] AXButton "00159 test target"\n'
                        '  - [10] AXRadioButton "00166 wrong"\n'
                        '- [100] AXWindow "Other"\n'
                        '  - [109] AXButton "00159 test target"\n'
                        '  - [110] AXRadioButton "00159 test target"')
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'click':
                clicked.append(data['element_index'])
                return '{}'
            raise AssertionError(tool)
        output = io.StringIO()
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 111)), patch.object(courier, 'cua', side_effect=fake_cua), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier.time, 'sleep'), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_switch(args), 1)
        self.assertEqual(clicked, [9])
        self.assertIn('未切换', output.getvalue())
        self.assertIn('00159 test target', output.getvalue())
        self.assertIn('00166 wrong', output.getvalue())

    def test_double_axwindow_tab_and_textarea_come_from_selected_subtree(self):
        tree = ('- [0] AXWindow "Other"\n'
                '  - [1] AXRadioButton "00166 wrong"\n'
                '  - [2] AXTextArea "Message" = "PRIVATE_OTHER_DRAFT"\n'
                '- [100] AXWindow "Main"\n'
                '  - [101] AXRadioButton "00159 test target"\n'
                '  - [102] AXTextArea "Message" = "first\\nsecond"')
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [
                    {'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}},
                    {'window_id': 222, 'title': 'Other', 'is_on_screen': False, 'bounds': {'height': 500}},
                ]})
            raise AssertionError(tool)
        with patch.object(courier, 'cua', side_effect=fake_cua):
            self.assertEqual(courier.cua_tab(42, 111), '00159 test target')
            self.assertEqual(courier.cua_textarea(42, 111), (102, 'Message', 'first\nsecond'))

    def test_double_axwindow_ambiguous_title_refuses(self):
        tree = ('- [0] AXWindow "Main"\n  - [1] AXRadioButton "00159 test target"\n'
                '  - [3] AXTextArea "Message" = ""\n'
                '- [100] AXWindow "Main"\n  - [101] AXRadioButton "00159 test target"\n'
                '  - [103] AXTextArea "Message" = ""')
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [{'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}}]})
            raise AssertionError(tool)
        with patch.object(courier, 'cua', side_effect=fake_cua):
            with self.assertRaisesRegex(RuntimeError, 'AXWindow'):
                courier.cua_tab(42, 111)

    def test_double_axwindow_without_windowserver_owner_refuses(self):
        tree = ('- [0] AXWindow "Main"\n  - [1] AXRadioButton "00159 test target"\n'
                '- [100] AXWindow "Ghost"\n  - [101] AXRadioButton "00166 wrong"')
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [{'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}}]})
            raise AssertionError(tool)
        with patch.object(courier, 'cua', side_effect=fake_cua):
            with self.assertRaisesRegex(RuntimeError, 'AXWindow'):
                courier.cua_tab(42, 111)

    def test_ui_switch_ambiguous_axwindow_never_clicks(self):
        tree = ('- [0] AXWindow "Main"\n  - [9] AXButton "00159 test target"\n'
                '- [100] AXWindow "Main"\n  - [109] AXButton "00159 test target"')
        clicked = []
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [{'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}}]})
            if tool == 'click':
                clicked.append(data)
                return '{}'
            raise AssertionError(tool)
        output = io.StringIO()
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 111)), patch.object(courier, 'cua', side_effect=fake_cua), \
             patch.object(courier, 'cua_front', return_value=[]), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_switch(SimpleNamespace(title='00159 test target', window_id=111)), 2)
        self.assertEqual(clicked, [])
        self.assertIn('未切换', output.getvalue())
        self.assertIn('实际标签页无法判定', output.getvalue())

    def test_ui_send_ambiguous_axwindow_never_writes(self):
        body_file = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        tree = ('- [0] AXWindow "Main"\n  - [1] AXRadioButton "00159 test target"\n'
                '  - [3] AXTextArea "Message" = ""\n'
                '- [100] AXWindow "Main"\n  - [101] AXRadioButton "00159 test target"\n'
                '  - [103] AXTextArea "Message" = ""')
        writes = []
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [{'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}}]})
            if tool == 'set_value':
                writes.append(data)
                return '{}'
            raise AssertionError(tool)
        output = io.StringIO()
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 111)), patch.object(courier, 'cua', side_effect=fake_cua), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier.time, 'sleep'), redirect_stdout(output):
            code = courier.cmd_ui_send(SimpleNamespace(file=body_file, expect_tab='00159 test target', session_id=TID, window_id=111))
        self.assertEqual(code, 2)
        self.assertEqual(writes, [])
        self.assertIn('没有写入', output.getvalue())

    def test_double_axwindow_restore_targets_selected_textarea(self):
        body = '【投递】Claude Code·0007 → Codex·00159\n\nhello'
        tree = ('- [0] AXWindow "Other"\n  - [2] AXRadioButton "00166 wrong"\n'
                '  - [3] AXTextArea "Message" = "PRIVATE_OTHER_DRAFT"\n'
                '- [100] AXWindow "Main"\n  - [101] AXRadioButton "00159 test target"\n'
                '  - [102] AXTextArea "Message" = ' + json.dumps(body, ensure_ascii=False))
        restored = []
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                current = tree if not restored else tree.replace(json.dumps(body, ensure_ascii=False), '""')
                return json.dumps({'window_id': 111, 'tree_markdown': current})
            if tool == 'list_windows':
                return json.dumps({'windows': [
                    {'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}},
                    {'window_id': 222, 'title': 'Other', 'is_on_screen': False, 'bounds': {'height': 500}},
                ]})
            if tool == 'set_value':
                restored.append(data)
                return '{}'
            raise AssertionError(tool)
        args = SimpleNamespace(expect_tab='00159 test target', window_id=111)
        with patch.object(courier, 'cua', side_effect=fake_cua), patch.object(courier, 'cua_target', return_value=(42, 111)):
            self.assertTrue(courier.restore_own_draft(args, 42, 111, 102, body, ''))
        self.assertEqual(restored[0]['element_index'], 102)
        self.assertEqual(restored[0]['value'], '')

    def test_double_axwindow_send_uses_selected_button(self):
        body_file = self.write('delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        body = Path(body_file).read_text(encoding='utf-8')
        args = SimpleNamespace(file=body_file, expect_tab='00159 test target', session_id=TID, window_id=111)
        current_value, clicks = '', []
        def fake_cua(tool, data):
            nonlocal current_value
            if tool == 'get_window_state':
                tree = ('- [0] AXWindow "Other"\n'
                        '  - [1] AXRadioButton "00159 test target"\n'
                        '  - [9] AXButton "发送"\n'
                        '- [100] AXWindow "Main"\n'
                        '  - [101] AXRadioButton "00159 test target"\n'
                        '  - [103] AXTextArea "Message" = ' + json.dumps(current_value, ensure_ascii=False) + '\n'
                        '  - [109] AXButton "发送"')
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [
                    {'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}},
                    {'window_id': 222, 'title': 'Other', 'is_on_screen': False, 'bounds': {'height': 500}},
                ]})
            if tool == 'set_value':
                self.assertEqual(data['element_index'], 103)
                current_value = data['value']
                return '{}'
            if tool == 'click':
                clicks.append(data['element_index'])
                return '{}'
            raise AssertionError(tool)
        with patch.object(courier, 'CODEX', self.tmp.name), patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'cua_target', return_value=(42, 111)), patch.object(courier, 'cua', side_effect=fake_cua), \
             patch.object(courier, 'cua_front', return_value=[]), patch.object(courier.time, 'sleep'):
            self.assertEqual(courier.cmd_ui_send(args), 0)
        self.assertEqual(clicks, [109])

    def test_same_subtree_duplicate_controls_refuse(self):
        tree = ('- [0] AXWindow "Main"\n'
                '  - [1] AXRadioButton "00159 test target"\n'
                '  - [2] AXRadioButton "00166 wrong"\n'
                '  - [3] AXTextArea "Message" = ""\n'
                '  - [4] AXTextArea "Message" = ""')
        def fake_cua(tool, data):
            if tool == 'get_window_state':
                return json.dumps({'window_id': 111, 'tree_markdown': tree})
            if tool == 'list_windows':
                return json.dumps({'windows': [{'window_id': 111, 'title': 'Main', 'is_on_screen': True, 'bounds': {'height': 500}}]})
            raise AssertionError(tool)
        with patch.object(courier, 'cua', side_effect=fake_cua):
            with self.assertRaisesRegex(RuntimeError, '多个标签页'):
                courier.cua_tab(42, 111)
            with self.assertRaisesRegex(RuntimeError, '唯一输入框'):
                courier.cua_textarea(42, 111)

    def test_ax_textarea_decodes_escaped_newlines_for_draft_check(self):
        with patch.object(courier, "cua_tree", return_value='[3] AXTextArea "Message" = "第一行\\n第二行"'):
            self.assertEqual(courier.cua_textarea(42, 1), (3, "Message", "第一行\n第二行"))

    def test_ax_textarea_reads_full_multiline_value_without_query_filter(self):
        def tree(_pid, _wid, query):
            return '[3] AXTextArea "Message" = "第一行\n第二行"' if query == '' else '[3] AXTextArea "Message" = "第一行"'
        with patch.object(courier, 'cua_tree', side_effect=tree):
            self.assertEqual(courier.cua_textarea(42, 1), (3, 'Message', '第一行\n第二行'))

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

    def test_docs_explain_cli_new_cannot_assign_numbered_app_title(self):
        english = Path(os.path.join(os.path.dirname(__file__), '..', 'README.md')).read_text(encoding='utf-8')
        chinese = Path(os.path.join(os.path.dirname(__file__), '..', 'README.zh-CN.md')).read_text(encoding='utf-8')
        self.assertIn('does not set the Codex App title', english)
        self.assertIn('不会设置 Codex App 会话标题', chinese)

    def test_native_ax_binds_visible_window_without_reading_double_cua_tree(self):
        windows = {'windows': [
            {'pid': 42, 'window_id': 111, 'is_on_screen': True,
             'bounds': {'x': 10, 'y': 20, 'width': 1000, 'height': 700}},
            {'pid': 42, 'window_id': 222, 'is_on_screen': False,
             'bounds': {'x': 0, 'y': 0, 'width': 960, 'height': 720}}]}
        fake = SimpleNamespace(returncode=0, stdout=json.dumps({'ok': True, 'tab': '00159 test target'}))
        def fake_cua(tool, _args):
            self.assertEqual(tool, 'list_windows')  # get_window_state has two AXWindow roots
            return json.dumps(windows)
        with patch.object(courier, 'cua_target', return_value=(42, 111)), \
             patch.object(courier, 'cua', side_effect=fake_cua), \
             patch.object(courier.subprocess if hasattr(courier, 'subprocess') else subprocess, 'run', return_value=fake) as run:
            result = courier.native_ui_action('tab')
        self.assertEqual(result['tab'], '00159 test target')
        command = run.call_args.args[0]
        self.assertIn('codex_ax.swift', command[1])
        self.assertEqual(command[5:9], ['10', '20', '1000', '700'])

    def test_native_ax_cold_start_primes_once_then_retries(self):
        windows = {'windows': [{'pid': 42, 'window_id': 111, 'is_on_screen': True,
                                'bounds': {'x': 10, 'y': 20, 'width': 1000, 'height': 700}}]}
        calls = []
        def fake_cua(tool, args):
            calls.append((tool, args))
            return json.dumps(windows if tool == 'list_windows' else {'tree_markdown': ''})
        runs = [SimpleNamespace(returncode=2, stdout=json.dumps({'ok': False, 'warmup_required': True})),
                SimpleNamespace(returncode=0, stdout=json.dumps({'ok': True, 'tab': '00174 test'}))]
        with patch.object(courier, 'cua_target', return_value=(42, 111)), \
             patch.object(courier, 'cua', side_effect=fake_cua), \
             patch.object(subprocess, 'run', side_effect=runs) as run:
            self.assertEqual(courier.native_ui_action('tab')['tab'], '00174 test')
        self.assertEqual(run.call_count, 2)
        self.assertEqual([item[0] for item in calls], ['list_windows', 'get_window_state'])
        self.assertEqual(calls[1][1]['query'], '聊天工具栏')

    def test_native_tab_ignores_ambiguous_double_axwindow_tree(self):
        ambiguous = ('- [0] AXWindow "Main"\n  - [1] AXRadioButton "00159 test target"\n'
                     '- [100] AXWindow "Main"\n  - [101] AXRadioButton "00159 test target"')
        reply = {'ok': True, 'tab': '00159 test target',
                 'front_before': 'Claude', 'front_after': 'Claude'}
        output = io.StringIO()
        with patch.object(courier, 'USE_NATIVE_AX', True, create=True), \
             patch.object(courier, 'native_ui_action', return_value=reply, create=True), \
             patch.object(courier, 'cua_tree', return_value=ambiguous), \
             patch.object(courier, 'cua_target', side_effect=AssertionError('legacy tree path used')), \
             redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_tab(SimpleNamespace(window_id=111)), 0)
        self.assertIn('00159 test target', output.getvalue())

    def test_native_switch_reports_actual_tab_on_failure(self):
        args = SimpleNamespace(title='00159 test target', window_id=None)
        reply = {'ok': False, 'reason': '切页后核对失败', 'actual_tab': '00160 archived one'}
        output = io.StringIO()
        with patch.object(courier, 'USE_NATIVE_AX', True), \
             patch.object(courier, 'CODEX', self.tmp.name), \
             patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'native_ui_action', return_value=reply), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_switch(args), 2)
        self.assertIn('实际标签页「00160 archived one」', output.getvalue())

    def test_native_send_preserves_body_and_reports_rollback(self):
        body = self.write('native-delivery.txt', '【投递】Claude Code·0007 → Codex·00159\n\n第一行\n第二行')
        args = SimpleNamespace(file=body, session_id=TID, expect_tab='00159 test target', window_id=111)
        calls = []
        def native(action, title='', text='', window_id=None):
            calls.append((action, title, text, window_id))
            if action == 'tab': return {'ok': True, 'tab': args.expect_tab}
            return {'ok': False, 'reason': '发送按钮不唯一', 'restored': True}
        output = io.StringIO()
        with patch.object(courier, 'USE_NATIVE_AX', True), \
             patch.object(courier, 'CODEX', self.tmp.name), \
             patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'native_ui_action', side_effect=native), redirect_stdout(output):
            self.assertEqual(courier.cmd_ui_send(args), 2)
        self.assertEqual(calls[1], ('send', args.expect_tab, Path(body).read_text(), 111))
        self.assertIn('已还原', output.getvalue())
        self.assertNotIn('第一行', output.getvalue())

    def test_native_send_success_uses_same_bridge_for_tab_and_send(self):
        body = self.write('native-success.txt', '【投递】Claude Code·0007 → Codex·00159\n\nhello')
        args = SimpleNamespace(file=body, session_id=TID, expect_tab='00159 test target', window_id=None)
        answers = [{'ok': True, 'tab': args.expect_tab},
                   {'ok': True, 'tab': args.expect_tab, 'front_before': 'Claude', 'front_after': 'Claude'}]
        with patch.object(courier, 'USE_NATIVE_AX', True), \
             patch.object(courier, 'CODEX', self.tmp.name), \
             patch.object(courier, 'INDEX', os.path.join(self.tmp.name, 'session_index.jsonl')), \
             patch.object(courier, 'native_ui_action', side_effect=answers) as native:
            self.assertEqual(courier.cmd_ui_send(args), 0)
        self.assertEqual([call.args[0] for call in native.call_args_list], ['tab', 'send'])


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



class SwiftAXFixtureTest(unittest.TestCase):
    """Pure Swift decision fixtures; no live App or ~/.codex access."""

    SCRIPT = os.path.join(os.path.dirname(__file__), '..', 'skills', 'courier', 'scripts', 'codex_ax.swift')

    def fixture(self, mode, snapshots, target=''):
        payload = json.dumps({'mode': mode, 'snapshots': snapshots, 'target': target}, ensure_ascii=False)
        run = subprocess.run(['swift', self.SCRIPT, 'fixture'], input=payload,
                             text=True, capture_output=True, timeout=30)
        return run.returncode, json.loads(run.stdout)

    def test_toolbar_title_cross_checks_window_and_old_radio_still_works(self):
        new = {'window': '00174 courier AX 投递测试', 'toolbars': 1,
               'staticTexts': ['00174 courier AX 投递测试'], 'radios': [], 'areas': 1}
        self.assertEqual(self.fixture('title', [new])[1]['tab'], new['window'])
        self.assertEqual(self.fixture('title', [dict(new, staticTexts=['00172 wrong'])])[0], 2)
        self.assertEqual(self.fixture('title', [dict(new, staticTexts=[])])[0], 2)
        old = {'window': new['window'], 'toolbars': 0, 'staticTexts': [],
               'radios': [new['window']], 'areas': 1}
        self.assertEqual(self.fixture('title', [old])[0], 0)

    def test_cold_start_waits_for_toolbar_and_composer_then_times_out_closed(self):
        cold = {'window': 'ChatGPT', 'toolbars': 0, 'staticTexts': [], 'radios': [], 'areas': 0}
        warm = {'window': '00174 courier AX 投递测试', 'toolbars': 1,
                'staticTexts': ['00174 courier AX 投递测试'], 'radios': [], 'areas': 1}
        self.assertEqual(self.fixture('ready', [cold, cold, warm])[1]['poll'], 2)
        self.assertEqual(self.fixture('ready', [cold, cold])[0], 2)

    def test_switch_accepts_delayed_title_only_after_matching_readback(self):
        old = {'window': '00159 投递courier', 'toolbars': 1,
               'staticTexts': ['00159 投递courier'], 'radios': [], 'areas': 1}
        target = dict(old, window='00174 courier AX 投递测试',
                      staticTexts=['00174 courier AX 投递测试'])
        self.assertEqual(self.fixture('switch', [old, old, target], target['window'])[1]['poll'], 2)
        self.assertEqual(self.fixture('switch', [old, old], target['window'])[0], 2)

    def test_duplicate_exact_sidebar_buttons_choose_first(self):
        row = {'window': '00159 投递courier', 'toolbars': 1,
               'staticTexts': ['00159 投递courier'], 'radios': [], 'areas': 1, 'targets': 2}
        self.assertEqual(self.fixture('button', [row])[1]['button_index'], 0)
        self.assertEqual(self.fixture('button', [dict(row, targets=0)])[0], 2)


if __name__ == "__main__":
    unittest.main()
