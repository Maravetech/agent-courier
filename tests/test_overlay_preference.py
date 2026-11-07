"""Delivery remains usable while the optional visual is disabled or unavailable."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from test_courier import SCRIPT, courier, overlay

SENDER, TARGET = 'Claude Code·0102', 'Codex·00177'


class OverlayPreferenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / 'overlay'
        self.config = self.state / 'config.json'
        self.env = dict(os.environ, COURIER_STATE_DIR=self.temp.name)
        self.env.pop('COURIER_OVERLAY', None)

    def cli(self, *args, override=None):
        env = self.env if override is None else dict(self.env, COURIER_OVERLAY=override)
        return subprocess.run([sys.executable, '-I', SCRIPT, 'overlay', *args], env=env,
                              text=True, capture_output=True, timeout=10)

    def test_default_off_keeps_state_directory_absent(self):
        result = self.cli('pair', '--from', SENDER, '--to', TARGET, '--state', 'sending')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())

    def test_persistent_switch_and_temporary_overrides(self):
        self.assertIn('effective=off', self.cli('status').stdout)
        self.assertEqual(self.cli('on').returncode, 0)
        self.assertIs(json.loads(self.config.read_text())['enabled'], True)
        self.assertIn('effective=off', self.cli('status', override='0').stdout)
        self.assertIn('effective=on', self.cli('status').stdout)
        self.assertEqual(self.cli('off').returncode, 0)
        self.assertIs(json.loads(self.config.read_text())['enabled'], False)
        self.assertIn('effective=on', self.cli('status', override='1').stdout)
        self.assertIn('effective=off', self.cli('status').stdout)

    def test_disabled_visual_hooks_never_scan_rollout(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(courier, 'LOGDIR', self.temp.name), \
             patch.object(courier, 'scan') as scan:
            courier.overlay_from_log('unused', 'delivered')
            courier.overlay_latest_turn('unused', 'working')
            courier.overlay_watch_completion('unused')
        scan.assert_not_called()

    def test_off_does_not_bypass_disconnected_gate(self):
        self.state.mkdir()
        (self.state / 'links.json').write_text(json.dumps({'disconnected': [SENDER + '→' + TARGET]}))
        with patch.object(courier, 'LOGDIR', self.temp.name), patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(courier.overlay_check(SENDER, TARGET), 5)
            self.assertEqual(courier.overlay_check('DSH·779', TARGET), 0)

    def test_visual_hook_failure_does_not_stop_computer_use_send(self):
        args = SimpleNamespace(from_session=SENDER, to=TARGET, state='sending', reason='')
        with patch.dict(os.environ, dict(self.env, COURIER_OVERLAY='1'), clear=True), \
             patch.object(courier.subprocess, 'run', side_effect=subprocess.TimeoutExpired('overlay', 2)):
            self.assertEqual(courier.cmd_overlay_pair(args), 0)

    def test_missing_or_crashed_app_is_best_effort(self):
        args = ['overlay_controller.py', '--from-session', SENDER, '--to-session', TARGET, '--state', 'sending']
        for failure in (None, OSError('renderer could not start')):
            with patch.dict(os.environ, dict(self.env, COURIER_OVERLAY='1'), clear=True), \
                 patch.object(sys, 'argv', args), patch.object(overlay, 'STATE_DIR', self.state), \
                 patch.object(overlay, 'STATE_FILE', self.state / 'pairs.json'), \
                 patch.object(overlay, 'LINKS_FILE', self.state / 'links.json'), \
                 patch.object(overlay, 'ensure_app', side_effect=failure):
                self.assertEqual(overlay.main(), 0)
