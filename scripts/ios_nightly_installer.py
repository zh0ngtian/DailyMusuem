#!/usr/bin/env python3
"""MuseumMuse macOS menu-bar app for nightly iPhone installation.

The default action is to run as a menu-bar app. At the configured local time it
checks that the paired iPhone is currently reachable over the local network,
builds the iOS app, and installs it without launching it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


APP_NAME = "MuseumMuse Nightly Installer"
LAUNCH_AGENT_LABEL = "tech.zh0ngtian.museummuse-nightly-installer"
DEFAULT_DEVICE_ID = "00008150-000E4010362B401C"
DEFAULT_DEVICE_NAME = "Yao iPhone 17 Pro"
DEFAULT_SCHEDULE = "00:00"
DEFAULT_PROVISIONING_REFRESH_HOURS = 24
DEFAULT_SIGNED_BUNDLES = (
    ("tech.zh0ngtian.MuseumMuse", "主 App"),
    ("tech.zh0ngtian.MuseumMuse.widget", "Widget"),
)


def _user_library_path(*parts: str) -> Path:
    return Path.home().joinpath("Library", *parts)


DEFAULT_LOG_PATH = _user_library_path("Logs", "MuseumMuseNightlyInstaller.log")
DEFAULT_STATE_DIR = _user_library_path("Application Support", "MuseumMuseNightlyInstaller")
DEFAULT_LAUNCH_AGENT_PATH = _user_library_path(
    "LaunchAgents", f"{LAUNCH_AGENT_LABEL}.plist"
)


def _default_provisioning_profile_directories() -> tuple[Path, ...]:
    return (
        _user_library_path(
            "Developer", "Xcode", "UserData", "Provisioning Profiles"
        ),
        _user_library_path("MobileDevice", "Provisioning Profiles"),
    )


class InstallerError(RuntimeError):
    """An expected device, build, or installation failure."""


@dataclass(frozen=True)
class InstallerConfig:
    project_root: Path
    device_id: str = DEFAULT_DEVICE_ID
    device_name: str = DEFAULT_DEVICE_NAME
    schedule: str = DEFAULT_SCHEDULE
    scheme: str = "DailyMuseum"
    configuration: str = "Debug"
    project_name: str = "DailyMuseum.xcodeproj"
    product_name: str = "DailyMuseum.app"
    log_path: Path = DEFAULT_LOG_PATH
    state_dir: Path = DEFAULT_STATE_DIR
    provisioning_profile_directories: tuple[Path, ...] = (
        _default_provisioning_profile_directories()
    )
    signed_bundles: tuple[tuple[str, str], ...] = DEFAULT_SIGNED_BUNDLES
    provisioning_refresh_hours: int = DEFAULT_PROVISIONING_REFRESH_HOURS

    @property
    def project_path(self) -> Path:
        return self.project_root / self.project_name

    @property
    def derived_data_path(self) -> Path:
        return self.project_root / ".deriveddata-nightly"

    @property
    def app_path(self) -> Path:
        return (
            self.derived_data_path
            / "Build"
            / "Products"
            / f"{self.configuration}-iphoneos"
            / self.product_name
        )

    @property
    def state_path(self) -> Path:
        return self.state_dir / "state.json"

    @property
    def job_lock_path(self) -> Path:
        return self.state_dir / "install.lock"

    @property
    def app_lock_path(self) -> Path:
        return self.state_dir / "menubar.lock"

    @property
    def provisioning_profile_backup_dir(self) -> Path:
        return self.state_dir / "provisioning-profile-refresh-backups"


def command_environment() -> dict[str, str]:
    env = os.environ.copy()
    preferred_paths = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]
    existing = env.get("PATH", "").split(os.pathsep)
    env["PATH"] = os.pathsep.join(dict.fromkeys(preferred_paths + existing))
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    return env


def parse_schedule(value: str) -> tuple[int, int]:
    try:
        parsed = dt.datetime.strptime(value, "%H:%M")
    except ValueError as exc:
        raise argparse.ArgumentTypeError("时间必须使用 HH:MM 格式，例如 00:00") from exc
    return parsed.hour, parsed.minute


def is_schedule_due(
    now: dt.datetime, schedule: str, last_scheduled_date: str | None
) -> bool:
    hour, minute = parse_schedule(schedule)
    return (
        now.hour == hour
        and now.minute >= minute
        and last_scheduled_date != now.date().isoformat()
    )


def next_schedule_time(now: dt.datetime, schedule: str) -> dt.datetime:
    hour, minute = parse_schedule(schedule)
    candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now:
        candidate += dt.timedelta(days=1)
    return candidate


def load_state(config: InstallerConfig) -> dict[str, object]:
    try:
        return json.loads(config.state_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_state(config: InstallerConfig, state: dict[str, object]) -> None:
    config.state_dir.mkdir(parents=True, exist_ok=True)
    temporary_path = config.state_path.with_suffix(".tmp")
    temporary_path.write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    temporary_path.replace(config.state_path)


def append_log(config: InstallerConfig, message: str) -> None:
    config.log_path.parent.mkdir(parents=True, exist_ok=True)
    timestamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    with config.log_path.open("a", encoding="utf-8") as log_file:
        log_file.write(f"[{timestamp}] {message}\n")


def _tool(name: str) -> str:
    path = shutil.which(name, path=command_environment()["PATH"])
    if not path:
        raise InstallerError(f"找不到命令：{name}")
    return path


def build_command(config: InstallerConfig) -> list[str]:
    return [
        _tool("xcodebuild"),
        "-project",
        str(config.project_path),
        "-scheme",
        config.scheme,
        "-configuration",
        config.configuration,
        "-destination",
        f"id={config.device_id}",
        "-derivedDataPath",
        str(config.derived_data_path),
        "-allowProvisioningUpdates",
        "build",
    ]


def install_command(config: InstallerConfig) -> list[str]:
    return [
        _tool("xcrun"),
        "devicectl",
        "device",
        "install",
        "app",
        "--device",
        config.device_id,
        "--timeout",
        "180",
        str(config.app_path),
    ]


def _run_and_capture(config: InstallerConfig, command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    append_log(config, f"执行：{' '.join(command)}")
    completed = subprocess.run(
        command,
        cwd=config.project_root,
        env=command_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if completed.stdout:
        with config.log_path.open("a", encoding="utf-8") as log_file:
            log_file.write(completed.stdout)
            if not completed.stdout.endswith("\n"):
                log_file.write("\n")
    return completed


def _run_streaming(config: InstallerConfig, command: Sequence[str]) -> int:
    append_log(config, f"执行：{' '.join(command)}")
    with config.log_path.open("a", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            command,
            cwd=config.project_root,
            env=command_environment(),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        return process.wait()


def _read_provisioning_profile(path: Path) -> dict[str, object] | None:
    completed = subprocess.run(
        ["/usr/bin/security", "cms", "-D", "-i", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        return None
    try:
        payload = plistlib.loads(completed.stdout)
    except (plistlib.InvalidFileException, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _utc_datetime(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value.astimezone(dt.timezone.utc)


@dataclass
class ProvisioningProfileRefresh:
    moved_profiles: list[tuple[Path, Path]]
    labels: tuple[str, ...]

    def restore(self) -> None:
        for original_path, backup_path in reversed(self.moved_profiles):
            if not backup_path.exists() or original_path.exists():
                continue
            original_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(backup_path), str(original_path))
        self._remove_empty_backup_directories()

    def discard_backups(self) -> None:
        for _original_path, backup_path in self.moved_profiles:
            backup_path.unlink(missing_ok=True)
        self._remove_empty_backup_directories()

    def _remove_empty_backup_directories(self) -> None:
        for _original_path, backup_path in self.moved_profiles:
            try:
                backup_path.parent.rmdir()
            except OSError:
                pass


def stage_expiring_provisioning_profiles(
    config: InstallerConfig, now: dt.datetime | None = None
) -> ProvisioningProfileRefresh:
    """Temporarily remove near-expiry app profiles so Xcode must renew them."""
    now_utc = _utc_datetime(now or dt.datetime.now(dt.timezone.utc))
    refresh_deadline = now_utc + dt.timedelta(
        hours=config.provisioning_refresh_hours
    )
    bundle_labels = dict(config.signed_bundles)
    profiles_by_bundle: dict[str, list[tuple[Path, dt.datetime]]] = {
        bundle_identifier: [] for bundle_identifier in bundle_labels
    }

    for directory in config.provisioning_profile_directories:
        if not directory.is_dir():
            continue
        for path in directory.glob("*.mobileprovision"):
            payload = _read_provisioning_profile(path)
            if payload is None:
                continue
            application_identifier = payload.get("Entitlements")
            if not isinstance(application_identifier, dict):
                continue
            raw_application_identifier = application_identifier.get(
                "application-identifier"
            )
            expiration = payload.get("ExpirationDate")
            if not isinstance(raw_application_identifier, str) or not isinstance(
                expiration, dt.datetime
            ):
                continue
            for bundle_identifier in bundle_labels:
                if raw_application_identifier.endswith(f".{bundle_identifier}"):
                    profiles_by_bundle[bundle_identifier].append(
                        (path, _utc_datetime(expiration))
                    )
                    break

    paths_to_move: list[Path] = []
    labels: list[str] = []
    for bundle_identifier, profiles in profiles_by_bundle.items():
        if not profiles:
            continue
        latest_expiration = max(expiration for _path, expiration in profiles)
        if latest_expiration > refresh_deadline:
            continue
        labels.append(bundle_labels[bundle_identifier])
        paths_to_move.extend(path for path, _expiration in profiles)

    if not paths_to_move:
        return ProvisioningProfileRefresh([], ())

    backup_directory = config.provisioning_profile_backup_dir / now_utc.strftime(
        "%Y%m%d-%H%M%S-%f"
    )
    backup_directory.mkdir(parents=True, exist_ok=False)
    moved_profiles: list[tuple[Path, Path]] = []
    try:
        for index, original_path in enumerate(paths_to_move):
            backup_path = backup_directory / f"{index}-{original_path.name}"
            shutil.move(str(original_path), str(backup_path))
            moved_profiles.append((original_path, backup_path))
    except OSError as exc:
        refresh = ProvisioningProfileRefresh(moved_profiles, tuple(labels))
        refresh.restore()
        raise InstallerError(f"无法暂存即将过期的描述文件：{exc}") from exc

    return ProvisioningProfileRefresh(moved_profiles, tuple(labels))


def device_is_reachable(config: InstallerConfig) -> tuple[bool, str]:
    """Connect to the device and require a usable local-network developer tunnel."""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as json_file:
        json_path = Path(json_file.name)

    try:
        command = [
            _tool("xcrun"),
            "devicectl",
            "device",
            "info",
            "details",
            "--device",
            config.device_id,
            "--timeout",
            "10",
            "--json-output",
            str(json_path),
        ]
        completed = _run_and_capture(config, command)
        try:
            payload = json.loads(json_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            return False, f"无法读取设备探测结果：{exc}"

        if completed.returncode != 0 or payload.get("info", {}).get("outcome") != "success":
            return False, "设备探测命令失败"

        result = payload.get("result", {})
        hardware = result.get("hardwareProperties", {})
        connection = result.get("connectionProperties", {})
        properties = result.get("deviceProperties", {})

        if hardware.get("udid") != config.device_id:
            return False, "探测结果不是目标设备"
        if connection.get("transportType") != "localNetwork":
            return False, "目标设备没有通过局域网连接"
        if connection.get("tunnelState") != "connected":
            return False, "目标设备的局域网开发通道未连接"
        if connection.get("pairingState") != "paired":
            return False, "目标设备尚未与本机配对"
        if properties.get("developerModeStatus") != "enabled":
            return False, "目标设备未启用开发者模式"
        if not properties.get("ddiServicesAvailable"):
            return False, "目标设备的开发者服务暂不可用"
        return True, f"已通过局域网发现 {properties.get('name', config.device_name)}"
    finally:
        json_path.unlink(missing_ok=True)


StatusCallback = Callable[[str, str], None]


class NightlyInstaller:
    def __init__(self, config: InstallerConfig, status_callback: StatusCallback | None = None):
        self.config = config
        self.status_callback = status_callback or (lambda _status, _message: None)

    def _status(self, status: str, message: str) -> None:
        append_log(self.config, message)
        self.status_callback(status, message)

    def run(self, trigger: str) -> bool:
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        with self.config.job_lock_path.open("a+") as lock_file:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self._status("busy", "已有编译或安装任务正在执行")
                return False

            state = load_state(self.config)
            state["lastAttemptAt"] = dt.datetime.now().astimezone().isoformat()
            state["lastTrigger"] = trigger
            save_state(self.config, state)

            self._status("checking", "正在检查目标 iPhone 的局域网连接")
            reachable, detail = device_is_reachable(self.config)
            if not reachable:
                self._finish(False, detail)
                return False

            self._status("building", f"{detail}；正在编译 {self.config.scheme}")
            if not self.config.project_path.exists():
                self._finish(False, f"找不到 Xcode 项目：{self.config.project_path}")
                return False

            try:
                profile_refresh = stage_expiring_provisioning_profiles(self.config)
            except InstallerError as exc:
                self._finish(False, str(exc))
                return False
            if profile_refresh.labels:
                labels = "、".join(profile_refresh.labels)
                self._status(
                    "building",
                    f"{labels} 描述文件将在 {self.config.provisioning_refresh_hours} "
                    "小时内到期；正在强制续签",
                )

            try:
                build_exit_code = _run_streaming(
                    self.config, build_command(self.config)
                )
            except OSError as exc:
                profile_refresh.restore()
                self._finish(False, f"无法启动编译命令：{exc}")
                return False
            if build_exit_code != 0:
                profile_refresh.restore()
                self._finish(False, f"编译失败（退出码 {build_exit_code}），请查看日志")
                return False
            profile_refresh.discard_backups()
            if not self.config.app_path.is_dir():
                self._finish(False, f"编译完成但找不到 App：{self.config.app_path}")
                return False

            self._status("installing", f"编译成功；正在安装到 {self.config.device_name}")
            install_result = _run_and_capture(self.config, install_command(self.config))
            if install_result.returncode != 0:
                self._finish(False, f"安装失败（退出码 {install_result.returncode}），请查看日志")
                return False

            self._finish(True, "编译并安装成功；App 未启动")
            return True

    def _finish(self, success: bool, message: str) -> None:
        state = load_state(self.config)
        state["lastResult"] = "success" if success else "failure"
        state["lastMessage"] = message
        state["lastFinishedAt"] = dt.datetime.now().astimezone().isoformat()
        save_state(self.config, state)
        self._status("success" if success else "failure", message)


def launch_agent_payload(config: InstallerConfig) -> dict[str, object]:
    return {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [
            sys.executable,
            str(Path(__file__).resolve()),
            "--menubar",
            "--project-root",
            str(config.project_root),
            "--device-id",
            config.device_id,
            "--device-name",
            config.device_name,
            "--schedule",
            config.schedule,
            "--scheme",
            config.scheme,
            "--configuration",
            config.configuration,
        ],
        "WorkingDirectory": str(config.project_root),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "EnvironmentVariables": {
            "PATH": command_environment()["PATH"],
            "DEVELOPER_DIR": command_environment()["DEVELOPER_DIR"],
        },
        "StandardOutPath": str(config.log_path),
        "StandardErrorPath": str(config.log_path),
    }


def install_launch_agent(config: InstallerConfig) -> None:
    DEFAULT_LAUNCH_AGENT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with DEFAULT_LAUNCH_AGENT_PATH.open("wb") as plist_file:
        plistlib.dump(launch_agent_payload(config), plist_file, sort_keys=False)
    domain = f"gui/{os.getuid()}"
    subprocess.run(
        ["/bin/launchctl", "bootout", domain, str(DEFAULT_LAUNCH_AGENT_PATH)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    completed = subprocess.run(
        ["/bin/launchctl", "bootstrap", domain, str(DEFAULT_LAUNCH_AGENT_PATH)],
        check=False,
    )
    if completed.returncode != 0:
        raise InstallerError("LaunchAgent 已写入，但 launchctl 启动失败")
    print(f"已安装并启动：{DEFAULT_LAUNCH_AGENT_PATH}")


def uninstall_launch_agent() -> None:
    domain = f"gui/{os.getuid()}"
    subprocess.run(
        ["/bin/launchctl", "bootout", domain, str(DEFAULT_LAUNCH_AGENT_PATH)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    DEFAULT_LAUNCH_AGENT_PATH.unlink(missing_ok=True)
    print(f"已移除：{DEFAULT_LAUNCH_AGENT_PATH}")


def run_menubar(config: InstallerConfig) -> int:
    try:
        import objc
        from AppKit import (
            NSApplication,
            NSApplicationActivationPolicyAccessory,
            NSImage,
            NSMenu,
            NSMenuItem,
            NSStatusBar,
            NSVariableStatusItemLength,
            NSWorkspace,
        )
        from Foundation import NSObject, NSURL, NSTimer
        from PyObjCTools import AppHelper
    except ImportError as exc:
        print(
            "缺少 PyObjC。请先运行 scripts/setup_ios_nightly_installer.sh，"
            "或安装 scripts/ios_nightly_installer_requirements.txt。",
            file=sys.stderr,
        )
        return 1

    config.state_dir.mkdir(parents=True, exist_ok=True)
    app_lock_file = config.app_lock_path.open("a+")
    try:
        fcntl.flock(app_lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("状态栏程序已经在运行。")
        return 0

    class MenuBarController(NSObject):
        def init(self):  # type: ignore[no-untyped-def]
            self = objc.super(MenuBarController, self).init()
            if self is None:
                return None
            self.runner = NightlyInstaller(config, self._thread_status)
            self.running = False
            self.status_item = None
            self.status_line = None
            self.next_run_line = None
            self.timer = None
            return self

        def applicationDidFinishLaunching_(self, _notification):  # type: ignore[no-untyped-def]
            self.status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(
                NSVariableStatusItemLength
            )
            self._set_icon("iphone")
            menu = NSMenu.alloc().init()

            self.status_line = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "就绪", None, ""
            )
            self.status_line.setEnabled_(False)
            menu.addItem_(self.status_line)

            self.next_run_line = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "", None, ""
            )
            self.next_run_line.setEnabled_(False)
            menu.addItem_(self.next_run_line)
            menu.addItem_(NSMenuItem.separatorItem())

            run_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "立即检测、编译并安装", "runNow:", ""
            )
            run_item.setTarget_(self)
            menu.addItem_(run_item)

            check_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "仅检测手机", "checkDevice:", ""
            )
            check_item.setTarget_(self)
            menu.addItem_(check_item)

            log_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "显示日志", "showLog:", ""
            )
            log_item.setTarget_(self)
            menu.addItem_(log_item)

            project_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "显示项目", "showProject:", ""
            )
            project_item.setTarget_(self)
            menu.addItem_(project_item)
            menu.addItem_(NSMenuItem.separatorItem())

            quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "退出", "quit:", "q"
            )
            quit_item.setTarget_(self)
            menu.addItem_(quit_item)

            self.status_item.setMenu_(menu)
            self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                15.0, self, "timerFired:", None, True
            )
            self._refresh_menu()
            append_log(config, f"状态栏程序已启动；每日计划时间 {config.schedule}")

        def _set_icon(self, symbol_name: str) -> None:
            image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
                symbol_name, APP_NAME
            )
            if image is not None:
                image.setTemplate_(True)
                self.status_item.button().setImage_(image)

        def _refresh_menu(self) -> None:
            next_run = next_schedule_time(dt.datetime.now(), config.schedule)
            self.next_run_line.setTitle_(
                f"下次检查：{next_run.strftime('%m-%d %H:%M')}"
            )

        def timerFired_(self, _timer):  # type: ignore[no-untyped-def]
            self._refresh_menu()
            state = load_state(config)
            now = dt.datetime.now()
            last_date = state.get("lastScheduledDate")
            if not self.running and is_schedule_due(
                now, config.schedule, last_date if isinstance(last_date, str) else None
            ):
                state["lastScheduledDate"] = now.date().isoformat()
                save_state(config, state)
                self._start_job("scheduled")

        def runNow_(self, _sender):  # type: ignore[no-untyped-def]
            self._start_job("manual")

        def checkDevice_(self, _sender):  # type: ignore[no-untyped-def]
            if self.running:
                return
            self.running = True
            self._apply_status("checking", "正在检查目标 iPhone 的局域网连接")

            def check() -> None:
                try:
                    reachable, message = device_is_reachable(config)
                    AppHelper.callAfter(
                        self._apply_status,
                        "success" if reachable else "failure",
                        message,
                    )
                except Exception as exc:  # keep the menu-bar process alive
                    append_log(config, f"设备检测异常：{exc}")
                    AppHelper.callAfter(self._apply_status, "failure", f"检测异常：{exc}")
                finally:
                    AppHelper.callAfter(self._set_running, False)

            threading.Thread(target=check, name="device-check", daemon=True).start()

        def _start_job(self, trigger: str) -> None:
            if self.running:
                self._apply_status("busy", "已有任务正在执行")
                return
            self.running = True

            def work() -> None:
                try:
                    self.runner.run(trigger)
                except Exception as exc:  # keep the menu-bar process alive
                    append_log(config, f"未处理异常：{exc}")
                    AppHelper.callAfter(self._apply_status, "failure", f"任务异常：{exc}")
                finally:
                    AppHelper.callAfter(self._set_running, False)

            threading.Thread(target=work, name="nightly-install", daemon=True).start()

        def _thread_status(self, status: str, message: str) -> None:
            AppHelper.callAfter(self._apply_status, status, message)

        def _apply_status(self, status: str, message: str) -> None:
            icons = {
                "checking": "iphone.radiowaves.left.and.right",
                "building": "hammer",
                "installing": "arrow.down.app",
                "success": "checkmark.circle",
                "failure": "exclamationmark.triangle",
                "busy": "clock",
            }
            self._set_icon(icons.get(status, "iphone"))
            self.status_line.setTitle_(message)

        def _set_running(self, running: bool) -> None:
            self.running = running
            self._refresh_menu()

        def showLog_(self, _sender):  # type: ignore[no-untyped-def]
            config.log_path.parent.mkdir(parents=True, exist_ok=True)
            config.log_path.touch(exist_ok=True)
            url = NSURL.fileURLWithPath_(str(config.log_path))
            NSWorkspace.sharedWorkspace().activateFileViewerSelectingURLs_([url])

        def showProject_(self, _sender):  # type: ignore[no-untyped-def]
            url = NSURL.fileURLWithPath_(str(config.project_path))
            NSWorkspace.sharedWorkspace().activateFileViewerSelectingURLs_([url])

        def quit_(self, _sender):  # type: ignore[no-untyped-def]
            NSApplication.sharedApplication().terminate_(self)

    application = NSApplication.sharedApplication()
    application.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    controller = MenuBarController.alloc().init()
    application.setDelegate_(controller)
    AppHelper.runEventLoop()
    return 0


def build_parser() -> argparse.ArgumentParser:
    default_project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--menubar", action="store_true", help="运行状态栏程序（默认）")
    mode.add_argument("--check-device", action="store_true", help="只检查手机是否可连接")
    mode.add_argument("--run-now", action="store_true", help="立即检查、编译并安装")
    mode.add_argument("--print-commands", action="store_true", help="只打印编译和安装命令")
    mode.add_argument("--install-launch-agent", action="store_true", help="安装登录启动项")
    mode.add_argument("--uninstall-launch-agent", action="store_true", help="移除登录启动项")
    parser.add_argument("--project-root", type=Path, default=default_project_root)
    parser.add_argument(
        "--device-id",
        default=os.environ.get("MUSEUMMUSE_NIGHTLY_DEVICE_ID", DEFAULT_DEVICE_ID),
    )
    parser.add_argument(
        "--device-name",
        default=os.environ.get("MUSEUMMUSE_NIGHTLY_DEVICE_NAME", DEFAULT_DEVICE_NAME),
    )
    parser.add_argument("--schedule", default=DEFAULT_SCHEDULE, type=str)
    parser.add_argument("--scheme", default="DailyMuseum")
    parser.add_argument("--configuration", default="Debug")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        parse_schedule(args.schedule)
    except argparse.ArgumentTypeError as exc:
        parser.error(str(exc))

    config = InstallerConfig(
        project_root=args.project_root.expanduser().resolve(),
        device_id=args.device_id,
        device_name=args.device_name,
        schedule=args.schedule,
        scheme=args.scheme,
        configuration=args.configuration,
    )

    try:
        if args.check_device:
            reachable, message = device_is_reachable(config)
            print(message)
            return 0 if reachable else 2
        if args.run_now:
            installer = NightlyInstaller(config, lambda _status, message: print(message))
            return 0 if installer.run("command-line") else 1
        if args.print_commands:
            print(" ".join(build_command(config)))
            print(" ".join(install_command(config)))
            return 0
        if args.install_launch_agent:
            install_launch_agent(config)
            return 0
        if args.uninstall_launch_agent:
            uninstall_launch_agent()
            return 0
        return run_menubar(config)
    except InstallerError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
