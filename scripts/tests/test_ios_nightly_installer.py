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
    def test_default_schedule_is_midnight(self) -> None:
        self.assertEqual(MODULE.DEFAULT_SCHEDULE, "00:00")

    def test_due_once_during_scheduled_minute_or_later_in_hour(self) -> None:
        now = dt.datetime(2026, 8, 16, 0, 8)
        self.assertTrue(MODULE.is_schedule_due(now, "00:00", None))
        self.assertFalse(MODULE.is_schedule_due(now, "00:00", "2026-08-16"))

    def test_does_not_catch_up_after_scheduled_hour(self) -> None:
        now = dt.datetime(2026, 8, 16, 1, 1)
        self.assertFalse(MODULE.is_schedule_due(now, "00:00", None))

    def test_next_schedule_rolls_to_tomorrow(self) -> None:
        now = dt.datetime(2026, 8, 15, 0, 0)
        self.assertEqual(
            MODULE.next_schedule_time(now, "00:00"),
            dt.datetime(2026, 8, 16, 0, 0),
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


class ProvisioningProfileRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.profile_directory = root / "profiles"
        self.profile_directory.mkdir()
        self.config = MODULE.InstallerConfig(
            project_root=root,
            log_path=root / "installer.log",
            state_dir=root / "state",
            provisioning_profile_directories=(self.profile_directory,),
        )
        self.now = dt.datetime(2026, 8, 19, 15, 0, tzinfo=dt.timezone.utc)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def _payload(bundle_identifier: str, expiration: dt.datetime) -> dict:
        return {
            "Entitlements": {
                "application-identifier": f"PGKB4LZW48.{bundle_identifier}"
            },
            "ExpirationDate": expiration,
        }

    def test_stages_app_and_widget_profiles_expiring_within_24_hours(self) -> None:
        app_profile = self.profile_directory / "app.mobileprovision"
        widget_profile = self.profile_directory / "widget.mobileprovision"
        app_profile.touch()
        widget_profile.touch()
        payloads = {
            app_profile: self._payload(
                "tech.zh0ngtian.MuseumMuse", self.now + dt.timedelta(hours=23)
            ),
            widget_profile: self._payload(
                "tech.zh0ngtian.MuseumMuse.widget",
                self.now + dt.timedelta(hours=23),
            ),
        }

        with mock.patch.object(
            MODULE,
            "_read_provisioning_profile",
            side_effect=lambda path: payloads[path],
        ):
            refresh = MODULE.stage_expiring_provisioning_profiles(
                self.config, now=self.now
            )

        self.assertEqual(refresh.labels, ("主 App", "Widget"))
        self.assertFalse(app_profile.exists())
        self.assertFalse(widget_profile.exists())
        refresh.restore()
        self.assertTrue(app_profile.exists())
        self.assertTrue(widget_profile.exists())

    def test_keeps_profiles_with_more_than_24_hours_remaining(self) -> None:
        app_profile = self.profile_directory / "app.mobileprovision"
        app_profile.touch()
        payload = self._payload(
            "tech.zh0ngtian.MuseumMuse", self.now + dt.timedelta(hours=25)
        )

        with mock.patch.object(
            MODULE, "_read_provisioning_profile", return_value=payload
        ):
            refresh = MODULE.stage_expiring_provisioning_profiles(
                self.config, now=self.now
            )

        self.assertEqual(refresh.labels, ())
        self.assertTrue(app_profile.exists())

    def test_fresh_duplicate_prevents_unnecessary_refresh(self) -> None:
        expiring_profile = self.profile_directory / "expiring.mobileprovision"
        fresh_profile = self.profile_directory / "fresh.mobileprovision"
        expiring_profile.touch()
        fresh_profile.touch()
        payloads = {
            expiring_profile: self._payload(
                "tech.zh0ngtian.MuseumMuse", self.now + dt.timedelta(hours=1)
            ),
            fresh_profile: self._payload(
                "tech.zh0ngtian.MuseumMuse", self.now + dt.timedelta(days=6)
            ),
        }

        with mock.patch.object(
            MODULE,
            "_read_provisioning_profile",
            side_effect=lambda path: payloads[path],
        ):
            refresh = MODULE.stage_expiring_provisioning_profiles(
                self.config, now=self.now
            )

        self.assertEqual(refresh.labels, ())
        self.assertTrue(expiring_profile.exists())
        self.assertTrue(fresh_profile.exists())

    def test_discards_staged_backup_after_success(self) -> None:
        app_profile = self.profile_directory / "app.mobileprovision"
        app_profile.touch()
        payload = self._payload(
            "tech.zh0ngtian.MuseumMuse", self.now + dt.timedelta(hours=1)
        )

        with mock.patch.object(
            MODULE, "_read_provisioning_profile", return_value=payload
        ):
            refresh = MODULE.stage_expiring_provisioning_profiles(
                self.config, now=self.now
            )

        backup_paths = [backup for _original, backup in refresh.moved_profiles]
        refresh.discard_backups()
        self.assertFalse(app_profile.exists())
        self.assertTrue(all(not path.exists() for path in backup_paths))


class NightlyInstallerProfileRefreshTests(unittest.TestCase):
    def test_restores_staged_profiles_when_build_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "DailyMuseum.xcodeproj").mkdir()
            config = MODULE.InstallerConfig(
                project_root=root,
                log_path=root / "installer.log",
                state_dir=root / "state",
            )
            refresh = mock.Mock(labels=("主 App",))
            installer = MODULE.NightlyInstaller(config)

            with (
                mock.patch.object(
                    MODULE,
                    "device_is_reachable",
                    return_value=(True, "设备可用"),
                ),
                mock.patch.object(
                    MODULE,
                    "stage_expiring_provisioning_profiles",
                    return_value=refresh,
                ),
                mock.patch.object(MODULE, "build_command", return_value=["build"]),
                mock.patch.object(MODULE, "_run_streaming", return_value=65),
            ):
                succeeded = installer.run("test")

            self.assertFalse(succeeded)
            refresh.restore.assert_called_once_with()
            refresh.discard_backups.assert_not_called()


class LaunchAgentTests(unittest.TestCase):
    def test_uses_current_interpreter_without_resolving_venv_symlink(self) -> None:
        config = MODULE.InstallerConfig(project_root=Path("/tmp/project"))
        with mock.patch.object(MODULE.sys, "executable", "/tmp/venv/bin/python"):
            payload = MODULE.launch_agent_payload(config)
        self.assertEqual(payload["ProgramArguments"][0], "/tmp/venv/bin/python")


if __name__ == "__main__":
    unittest.main()
