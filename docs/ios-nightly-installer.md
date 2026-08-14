# 每晚自动安装到真机

`scripts/ios_nightly_installer.py` 是一个 macOS 状态栏程序。它每天本地时间 `23:00` 检查目标 iPhone；只有设备通过局域网连接、已经配对、开启开发者模式且开发者服务可用时，才会编译并安装 `DailyMuseum.app`。安装完成后不会启动 App。

## 前置条件

- Mac 已安装 Xcode，并已接受许可协议。
- iPhone 已开启开发者模式。
- iPhone 曾通过数据线在 Xcode 的 Devices and Simulators 中完成配对，并开启 `Connect via network`。
- Mac 和 iPhone 在同一局域网，且 Mac 在 `23:00` 已登录并处于唤醒状态。
- 项目的自动签名和 `Config/Secrets.local.xcconfig` 已配置好，命令行真机构建可以成功。

## 一次性安装

在仓库根目录执行：

```bash
zsh scripts/setup_ios_nightly_installer.sh
```

脚本会在 `~/Library/Application Support/MuseumMuseNightlyInstaller/venv` 创建独立 Python 环境、安装 PyObjC、写入用户级 LaunchAgent，并立即启动状态栏程序。以后登录 macOS 时会自动启动。

## 状态栏操作

- `立即检测、编译并安装`：手动执行完整流程。
- `仅检测手机`：只验证局域网开发连接，不构建。
- `显示日志`：在 Finder 中定位日志文件。
- `显示项目`：在 Finder 中定位 Xcode 项目。
- `退出`：停止当前状态栏程序；下次登录时会再次启动。

日志路径：`~/Library/Logs/MuseumMuseNightlyInstaller.log`。

## 命令行诊断

```bash
# 只检查手机，不改变手机内容
python3 scripts/ios_nightly_installer.py --check-device

# 只打印将要执行的构建和安装命令
python3 scripts/ios_nightly_installer.py --print-commands

# 使用虚拟环境立即执行完整流程
"$HOME/Library/Application Support/MuseumMuseNightlyInstaller/venv/bin/python" \
  scripts/ios_nightly_installer.py --run-now

# 移除登录启动项
"$HOME/Library/Application Support/MuseumMuseNightlyInstaller/venv/bin/python" \
  scripts/ios_nightly_installer.py --uninstall-launch-agent
```

需要更换手机或时间时，可传入 `--device-id`、`--device-name`、`--schedule HH:MM` 后重新执行 `--install-launch-agent`。

## 已知限制

- Mac 睡眠时不能执行编译；如果在 `23:00` 后、`23:59` 前唤醒，会在状态栏程序下一次轮询时补做。当日直到午夜仍未唤醒则跳过该次任务。
- iPhone 可能要求解锁后才能建立开发者通道或安装。
- 脚本只检查和安装，不调用 `devicectl device process launch`，因此不会主动打开 App。
