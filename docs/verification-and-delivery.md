# MuseumMuse 验证与交付

本文件承接 [AGENTS.md](../AGENTS.md) 第 6 章；功能变更交付前必须阅读，Widget 变更必须执行第 6.3 节的桌面截图与日志闭环。

## 6. 验证与交付

### 6.1 默认验证策略

- iOS 发布继续要求 [OTA + Yao App Source 双渠道](ios-adhoc-ota.md#双渠道发布流程)，使用同一正式签名 IPA；软件源具体发布与验收每次遵循 [SignOs PUBLISH_PROMPT.md](https://github.com/zh0ngtian/SignOs/blob/main/cloudflare/app-source/PUBLISH_PROMPT.md) 最新内容。只改发布工具时执行相应脚本检查，不要求重建 App；OTA `--plan` 只表示本地验签，不代表线上发布通过。

- 后续每次修复问题或新增功能后，都需要优先使用模拟器 `iPhone 17 Pro` 作为默认构建和运行目标再交付。
- 当前 Codex 沙箱内执行 `xcrun simctl` 或 `xcodebuild` 访问模拟器时，可能出现 `CoreSimulatorService connection became invalid`、`simdiskimaged crashed or is not responding`、`Operation not permitted`、`No available simulator runtimes` 或 `iOS 26.5 Platform Not Installed` 等假性失败；这不一定表示本机缺少 runtime 或项目构建失败。遇到这类错误时，应先用脱离沙箱的 Xcode CLI 路径复核，例如 `xcrun simctl list runtimes` 和对应 `xcodebuild ... build-for-testing`，再判断是否真的是代码或环境问题。
- 运行 iOS 单元测试时，当前默认关闭 parallel testing：
  - `DailyMuseumTests` scheme 不应使用克隆模拟器并行执行
  - 当前环境下 clone simulator 容易在 `Failed to install or launch the test runner` 阶段失败
- 涉及真机权限、真机网络或其他模拟器无法稳定覆盖的场景时，再补充使用真机 `Yao iPhone 17 Pro` 验证。
- 涉及详情页 `AI` 按钮时：
  - 可先用模拟器确认按钮显示、入口位置和 `DoubaoMuseum` URL 拼装
  - 快捷指令实际拉起、缺失后的快捷指令安装提示，以及豆包缺失后的 App 安装提示需优先用真机验收
- 使用模拟器做交互验证时，默认采用 `xcodebuild build` + `xcrun simctl install` + `xcrun simctl launch` 链路，不默认使用 `xcodebuild test`。
- 原因：
  - `xcodebuild test` 会接管并可能克隆 / 回收模拟器，测试结束后目标模拟器可能被自动关闭。
  - 如需保持当前模拟器桌面状态、继续截图或继续观察 widget 刷新结果，应优先避免在验证中途运行 `xcodebuild test`。
- 只有在明确需要跑单元测试或 UI 测试时，才使用 `xcodebuild test`；跑完后需要预期模拟器可能回到 `Shutdown` 状态，并按需重新 `boot/install/launch`。

### 6.2 默认设备与真机补充链路

- 当前默认验证设备：
  - 模拟器名称：`iPhone 17 Pro`
  - 默认使用当前本机可用的 `iPhone 17 Pro` 模拟器实例进行构建、安装、启动与截图验证
- 当前可用的真机补充验证设备：
  - 真机名称：`Yao iPhone 17 Pro`
  - 真机设备 ID：`00008150-000E4010362B401C`
- 当前命令行真机调试约束：
  - `xcrun devicectl list devices` 能正确发现真机，不代表当前沙箱内的 `xcodebuild` 一定能正确识别真机 destination
  - 在当前环境中，沙箱内执行 `xcodebuild` 时，可能只看到 `Any iOS Device`，看不到真实设备 `Yao iPhone 17 Pro`
  - 如需进行真机构建、安装、启动验证，应优先使用脱离沙箱的 Xcode CLI 路径执行
  - 已验证可工作的命令包括：
    - `xcodebuild -project DailyMuseum.xcodeproj -scheme DailyMuseum -showdestinations`
    - `xcodebuild -project DailyMuseum.xcodeproj -scheme DailyMuseum -destination 'id=00008150-000E4010362B401C' -derivedDataPath .deriveddata build`
    - `xcrun devicectl device install app --device 00008150-000E4010362B401C .deriveddata/Build/Products/Debug-iphoneos/DailyMuseum.app`
    - `xcrun devicectl device process launch --device 00008150-000E4010362B401C tech.zh0ngtian.DailyMuseum`
  - 上述命令是既有验证路径；设备在线状态、构建/安装/启动结果必须在本次交付时重新核验，不能沿用历史成功结论。
- 仓库提供 `scripts/ios_nightly_installer.py`，每日 `00:00` 检查真机局域网开发连接、签名有效期并构建安装；不主动启动 App。修改该链路前必须阅读 [每晚自动安装到真机](ios-nightly-installer.md)，继续保持描述文件不足 `24` 小时续签、失败恢复缓存、独立 `.deriveddata-nightly` 和 `scripts/tests/test_ios_nightly_installer.py` 回归。

### 6.3 小组件截图闭环测试

- 2026-10-10 移除桌面组号角标：常规版在默认 `iPhone 17 Pro` / iOS 26.5 构建、安装、启动通过；兼容版在 `MuseumMuse Widget Groups` / iOS 27 构建、安装、启动通过。第 1 组定向刷新成功并停止候选推进，小尺寸桌面成功态确认无组号；现有第 1 组小、中、大、超大和第 2 组中尺寸均生成成功 timeline。相关 Widget/SpringBoard/chronod 日志未命中 `imageTooLarge`、归档失败、`CHSErrorDomain`、`Fatal error` 或 `No AppIntent`。证据在 `build/verification/widget-hide-group-number/`；随后已发布 OTA `1.1.2 (8)`，设备 Release、逐目标验签及 HTTPS 回验通过，发布证据在 `build/verification/ios-ota-1.1.2/`。本次未安装真机，未逐尺寸截图及重测自动调度。

- 私有 OTA 兼容版另按 [OTA 文档](ios-adhoc-ota.md) 构建与签名；真实小组件、点击刷新打开 App、共享日志与详情链接必须实机验证。兼容版需验证 10 个 kind 的注册、四种尺寸（超大须 iOS 27）、同组跨尺寸同步和不同组独立选馆/刷新、组 1 升级迁移、选择持久化及无实例不刷新。日志以 `compat:<组号>|<scope>` 区分同馆不同组；不得要求兼容版通过桌面 AppIntent 编辑验收。用户指定模拟器时按其要求验证，实机/整点自动刷新等未覆盖项如实记录。

- 验证小组件问题时，默认要形成“构建 / 安装 / 启动 + 日志 + 桌面截图 + 系统日志”的闭环，不接受只看 provider 日志就下结论。
- 模拟器推荐链路：
  - `xcodebuild -project DailyMuseum.xcodeproj -scheme DailyMuseumTests -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -derivedDataPath .deriveddata-sim build-for-testing`
  - `xcrun simctl install <SIMULATOR_ID> .deriveddata-sim/Build/Products/Debug-iphonesimulator/DailyMuseum.app`
  - `xcrun simctl launch <SIMULATOR_ID> tech.zh0ngtian.DailyMuseum`
- 仓库内现有日志脚本：
  - `scripts/pull_simulator_request_logs.sh`
  - 常用参数：
    - `--udid <SIMULATOR_ID>`：指定模拟器
    - `--clear`：清空旧日志
    - `--trigger-refresh`：触发 `dailymuseum://debug/widget-refresh`
    - `--instance-token <TOKEN>`：按共享刷新键定向触发刷新，常规版键为 `scope`，兼容版为 `compat:<组号>|<scope>`
    - `--scope-raw-value <RAW>`：按 scope 触发刷新，例如 `single:nmc`、`single:shm`
    - `--wait <SECONDS>`：刷新后等待
    - `--tail <N>`：输出最后 N 条日志
    - `--instances`：输出 `instances.json`
    - `--screenshot-path <PATH>`：保存截图
    - `--home-screen`：截图前尝试回到桌面
- 推荐闭环步骤：
  - 1. `build-for-testing + install + launch`
  - 2. 用 `scripts/pull_simulator_request_logs.sh --instances` 确认当前共享刷新键，当前脚本输出里仍沿用 `instanceToken` 字段名
  - 3. 优先用 `--instance-token` 定向触发当前可见 `scope` 组刷新，避免影响其它 scope 的现场
  - 4. 用脚本或 `xcrun simctl io ... screenshot` 抓图
  - 5. 检查 request logs，确认：
    - 候选拉取顺序符合预期
    - 成功后没有继续多拉
    - provider 至少生成过对应 family 的 timeline
    - 当前关键 widget 日志能看到对应的共享刷新键
  - 6. 再查系统日志，确认没有 `imageTooLarge`、归档失败或 Chrono 渲染错误
  - 7. 最后以桌面截图作为最终验收证据
- 自动刷新调度回归需要覆盖同日多时间点积压、跨日积压、恰好结束时间和结束时间之后；验证只补刷一次、下一次计划严格晚于执行时刻，并在失败、共享组其它尺寸请求和 store 重建后保持已推进的时间点。模拟器可先备份设置与 `instances.json`，在关机状态下注入旧计划及匹配的 schedule signature，再启动并重新加载 timeline；检查只有一次 `开始自动刷新`、未来的下一次计划、成功态桌面截图，以及再次重载不重复请求。验证后恢复原设置并移除注入的计划，不能把测试状态写入真机。
- 多 source 博物馆切换验证还需要补充：
  - 主 App 页面设置默认显示服务端 `defaultSourceKey` 对应数据源
  - 切换 source 后，收藏夹中切换前已收藏的展品仍可见并能打开
  - Widget 单馆刷新时，日志中的候选来源、图片 URL 优先级和图片请求头应与当前 source metadata 一致
- 常用日志命令：
  - `zsh scripts/pull_simulator_request_logs.sh --udid <SIMULATOR_ID> --clear --trigger-refresh --instance-token <TOKEN> --wait 8 --tail 120`
  - `zsh scripts/pull_simulator_request_logs.sh --udid <SIMULATOR_ID> --instances`
  - `xcrun simctl spawn <SIMULATOR_ID> log show --style compact --last 10m --predicate 'eventMessage CONTAINS[c] "imageTooLarge" OR eventMessage CONTAINS[c] "Widget archival failed due to image being too large" OR process == "DailyMuseumWidgetExtension"'`
- 截图注意事项：
  - `--home-screen` 或 `notifyutil` 回桌面不一定每次都可靠，截图前必须确认 Simulator 当前真的在 SpringBoard。
  - 如果脚本截图截到的是前台 App，而不是桌面，可改用激活 `Simulator` 后发送 `Shift-Command-H` 再截图。
  - 验收 widget 是否修好时，必须保留一张最终桌面成功态截图，不能只保留 App 前台截图。
- 如果这轮验证中运行了 `xcodebuild test`：
  - 需要预期模拟器可能被接管、重建或关闭。
  - 跑完后通常要重新 `boot/install/launch`，再重新做一轮桌面截图验证。
