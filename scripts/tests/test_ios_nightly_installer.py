from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "ios_nightly_installer.py"
SPEC = importlib.util.spec_from_file_location("ios_nightly_installer", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ScheduleTests(unittest.TestCase):
    def test_due_once_during_scheduled_minute_or_later_in_hour(self) -> None:
        now = dt.datetime(2026, 8, 15, 23, 8)
        self.assertTrue(MODULE.is_schedule_due(now, "23:00", None))
        self.assertFalse(MODULE.is_schedule_due(now, "23:00", "2026-08-15"))

    def test_does_not_catch_up_after_scheduled_hour(self) -> None:
        now = dt.datetime(2026, 8, 16, 0, 1)
        self.assertFalse(MODULE.is_schedule_due(now, "23:00", None))

    def test_next_schedule_rolls_to_tomorrow(self) -> None:
        now = dt.datetime(2026, 8, 15, 23, 0)
        self.assertEqual(
            MODULE.next_schedule_time(now, "23:00"),
            dt.datetime(2026, 8, 16, 23, 0),
        )


class DeviceProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.config = MODULE.InstallerConfig(
            project_root=root,
            log_path=root / "installer.log",
            state_dir=root / "state",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def _payload(*, tunnel: str = "connected", transport: str = "localNetwork") -> dict:
        return {
            "info": {"outcome": "success"},
            "result": {
                "hardwareProperties": {"udid": MODULE.DEFAULT_DEVICE_ID},
                "connectionProperties": {
                    "transportType": transport,
                    "tunnelState": tunnel,
                    "pairingState": "paired",
                },
                "deviceProperties": {
                    "name": MODULE.DEFAULT_DEVICE_NAME,
                    "developerModeStatus": "enabled",
                    "ddiServicesAvailable": True,
                },
            },
        }

    def _fake_run(self, payload: dict):
        def run(_config, command):
            output_path = Path(command[command.index("--json-output") + 1])
            output_path.write_text(json.dumps(payload), encoding="utf-8")
            return mock.Mock(returncode=0, stdout="")

        return run

    def test_accepts_connected_local_network_device(self) -> None:
        with mock.patch.object(MODULE, "_run_and_capture", self._fake_run(self._payload())):
            reachable, message = MODULE.device_is_reachable(self.config)
        self.assertTrue(reachable)
        self.assertIn(MODULE.DEFAULT_DEVICE_NAME, message)

    def test_rejects_cached_but_disconnected_device(self) -> None:
        with mock.patch.object(
            MODULE, "_run_and_capture", self._fake_run(self._payload(tunnel="disconnected"))
        ):
            reachable, message = MODULE.device_is_reachable(self.config)
        self.assertFalse(reachable)
        self.assertIn("未连接", message)

    def test_rejects_usb_connection(self) -> None:
        with mock.patch.object(
            MODULE, "_run_and_capture", self._fake_run(self._payload(transport="wired"))
        ):
            reachable, message = MODULE.device_is_reachable(self.config)
        self.assertFalse(reachable)
        self.assertIn("局域网", message)


class LaunchAgentTests(unittest.TestCase):
    def test_uses_current_interpreter_without_resolving_venv_symlink(self) -> None:
        config = MODULE.InstallerConfig(project_root=Path("/tmp/project"))
        with mock.patch.object(MODULE.sys, "executable", "/tmp/venv/bin/python"):
            payload = MODULE.launch_agent_payload(config)
        self.assertEqual(payload["ProgramArguments"][0], "/tmp/venv/bin/python")


if __name__ == "__main__":
    unittest.main()
