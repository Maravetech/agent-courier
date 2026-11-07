import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class MenuClickTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = None
        tap = ROOT / "overlay/MenuClickTap.swift"
        if sys.platform != "darwin" or not tap.exists():
            return
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        cls.fixture = pathlib.Path(directory.name) / "menu-click"
        subprocess.run(["swiftc", str(tap), str(ROOT / "tests/menu_click_fixture.swift"),
                        "-o", str(cls.fixture)], check=True, timeout=60)

    def run_fixture(self, mode):
        if self.fixture is not None:
            result = subprocess.run([str(self.fixture), mode], check=True, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.stdout.strip(), f"PASS {mode}")

    def setUp(self):
        tap = ROOT / "overlay/MenuClickTap.swift"
        self.source = (tap if tap.exists() else ROOT / "overlay/CourierOverlay.swift").read_text()

    def test_disabled_tap_recovers(self):
        self.assertIn(".tapDisabledByTimeout", self.source)
        self.assertIn(".tapDisabledByUserInput", self.source)
        self.run_fixture("recovery")

    def test_tap_does_not_consume_clicks(self):
        self.assertIn("options: .listenOnly", self.source)
        self.assertNotIn("options: .defaultTap", self.source)
        self.run_fixture("passthrough")

    def test_tap_has_its_own_run_loop(self):
        self.assertIn("Thread.detachNewThread", self.source)
        self.assertIn("CFRunLoopGetCurrent()", self.source)
        self.assertNotIn("CFRunLoopGetMain()", self.source)
        self.run_fixture("worker")
