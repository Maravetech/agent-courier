"""Exercise the same Swift reducer that the native rollout watcher uses."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform == "darwin", "macOS Swift overlay")
class OverlayRolloutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.temp.name)
        (cls.folder / 'main.swift').write_text('''import Foundation
let input = CommandLine.arguments[1], live = input + ".live"
let lines = try String(contentsOfFile: input, encoding: .utf8).split(separator: "\\n")
try Data().write(to: URL(fileURLWithPath: live))
let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: live))
let tracker = RolloutTracker()
var state: String?
for line in lines {
    try handle.write(contentsOf: Data((String(line)+"\\n").utf8))
    state = tracker.read(live, senderApp: "Claude Code", sender: "0102", targetApp: "Codex", target: "00172")
}
try handle.close()
print(state ?? "unchanged")
''')
        subprocess.run(['swiftc', str(ROOT/'overlay/RolloutState.swift'), str(cls.folder/'main.swift'), '-o', str(cls.folder/'reduce')], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check_states(self, rows, expected):
        path = self.folder/'fixture.jsonl'
        path.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
        actual = subprocess.check_output([str(self.folder/'reduce'), str(path)], text=True).strip()
        self.assertEqual(actual, expected)

    @staticmethod
    def event(kind, **fields):
        return dict(type='event_msg', payload=dict(type=kind, **fields))

    @staticmethod
    def message(role, text):
        return dict(type='response_item', payload=dict(type='message', role=role, content=[dict(text=text)]))

    def anchor(self):
        return [self.event('task_started'), self.message('user', '【投递】Claude Code·0102 → Codex·00172\n任务')]

    def test_delivery_interjection_reply(self):
        rows = self.anchor()+[self.message('user', '？'), self.message('assistant', '【回复】Codex·00172 → Claude Code·0102\n完成'), self.event('task_complete')]
        self.check_states(rows, 'replied')

    def test_delivery_503_retry_reply(self):
        rows = self.anchor()+[self.event('task_complete', error={'message':'503'}, last_agent_message='')]
        self.check_states(rows, 'error')
        rows += [self.event('task_started'), self.message('user', '继续')]
        self.check_states(rows, 'working')
        rows += [self.event('task_complete', last_agent_message='【回复】Codex·00172 → Claude Code·0102\n完成')]
        self.check_states(rows, 'replied')

    def test_abort_and_wrong_header(self):
        rows = self.anchor()+[self.message('assistant','中间说明'), self.event('turn_aborted')]
        self.check_states(rows, 'error')
        rows += [self.event('task_started'), self.event('task_complete', last_agent_message='错误抬头')]
        self.check_states(rows, 'wrong_header')

    def test_large_tool_output_does_not_lose_delivery(self):
        rows = self.anchor()+[dict(type='response_item', payload=dict(type='custom_tool_call_output', output='x'*2_000_000)), self.message('user','继续'), self.event('task_complete', last_agent_message='【回复】Codex·00172 → Claude Code·0102\n完成')]
        self.check_states(rows, 'replied')
