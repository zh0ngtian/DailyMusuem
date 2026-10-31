# MuseumMuse 验证与交付

本文件承接 [AGENTS.md](../AGENTS.md) 第 6 章；功能变更交付前必须阅读，Widget 变更必须执行第 6.3 节的桌面截图与日志闭环。

## 6. 验证与交付

### 6.1 默认验证策略

- 默认完成标准是改动通过验证、合入主分支 `main`，并提交和推送最终代码。每次任务按以下顺序交付：
  1. 开始修改前获取最新主分支，记录其完整 SHA 为 `mainStartSha`；同时记录开发起点 `baseSha`，两者分别用于判断主分支是否推进和界定本次改动范围。
  2. 完成改动、对应范围的本地验证和文档回填；验证通过后，再获取最新主分支，记录合入前的 `mainBeforeMergeSha`，将本次改动合入该主分支。
  3. 若 `mainBeforeMergeSha == mainStartSha`，说明修改期间主分支没有新提交，可复用本次验证结果，不重复回归；若不相等，则对合入后的代码按改动范围再做回归，通过后才能完成最终提交和推送。冲突解决或合入时额外修改了代码，也必须验证这些修改。
  4. 推送前再次确认远端主分支；若其又有新提交，继续整合并回归，不覆盖他人提交。记录起点、合入前主分支 SHA、最终提交与验证结果，并说明执行或跳过合入后回归的依据。直接在 `main` 上工作的任务同样遵守此比较规则。
- 默认不发布：日常交付不递增 App 版本 / Build，不创建发布标签或 GitHub Release，不发布 OTA、不部署 SCF，也不登记发布任务或提交协调器 `ready`。2026-10-20 起，此规则取代此前后续改动自动发布 OTA 的授权；只有用户明确要求发布时才启用第 6.5 节及对应发布流程。
- 自 2026-10-25 起，后续客户端仅发布 unsigned IPA 至 GitHub Release，并保留 SHA-256 / 元数据附件；停止本机发布构建、私有签名和 OTA 上传、激活、固定入口更新。用户要求“发布”也不包含这些步骤，不要求签名验签、OTA HTTPS 回验或 OTA receipt。已有签名与 OTA 版本、产物和凭证保留为历史记录；必要的本地功能验证和开发安装继续执行。
- 涉及客户端时，仍须确认最终提交的日常 GitHub Actions `iOS Build` 的 `Build` 通过；普通主分支提交不要求发布冻结清单。只有明确要求 App/Widget 发布时，才执行第 6.4 节的标签发布要求：统一版本 / Build、同一提交的 `vX.Y.Z` 标签 `iOS Release` 的 `Build` / `Publish unsigned IPA`、Release 附件与冻结来源核对。

- 后续改动不涉及客户端时，不触发本地 iOS 构建、测试目标编译或 GitHub Actions `iOS Build`，只执行与改动相称的服务端、数据、脚本或文档验证，也不要求该提交提供未签名 IPA Release 或发布 OTA。
- 客户端范围包括主 App、Widget、Shared、客户端测试、资源和工程 / 编译配置。纯后端、schema、metadata、crawler、部署包、文档、运维或发布工具改动，不因现有 iOS 交付条款而要求客户端构建；同时包含客户端改动时，继续执行对应 iOS 验证，发布仍以用户明确要求为前提。
- 涉及客户端的修复或新增功能，需要优先使用模拟器 `iPhone 17 Pro` 作为默认构建和运行目标再交付。
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
    - `xcrun devicectl device process launch --device 00008150-000E4010362B401C tech.zh0ngtian.MuseumMuse`
  - 上述命令是既有验证路径；设备在线状态、构建/安装/启动结果必须在本次交付时重新核验，不能沿用历史成功结论。
- 仓库提供 `scripts/ios_nightly_installer.py`，每日 `00:00` 检查真机局域网开发连接、签名有效期并构建安装；不主动启动 App。修改该链路前必须阅读 [每晚自动安装到真机](ios-nightly-installer.md)，继续保持描述文件不足 `24` 小时续签、失败恢复缓存、独立 `.deriveddata-nightly` 和 `scripts/tests/test_ios_nightly_installer.py` 回归。

### 6.3 小组件截图闭环测试

- 2026-10-31 刷新图标两秒反馈：`Toggle(isOn: false, intent:)` 与自定义样式利用 WidgetKit 临时状态旋转，最长两秒，结果返回时重置；不额外延迟 intent。默认 iOS 27 模拟器构建、安装、启动通过，桌面点击生成成功刷新日志；模拟器点击实例的动画和快照更新不稳定，动画与最终换图以真机验收为准。独立开发测试 App `tech.zh0ngtian.MuseumRefreshTest` 在 `Yao iPhone 17 Pro` / iOS 27.0 安装、启动，通过录屏确认两秒旋转后停止、刷新停留桌面并换展品；44 pt 区域左下边缘点击成功，连续两次点击后最终换为大都会水罐，主体点击进入相同展品详情。App 内共享日志确认 `compat:1|all` 刷新成功、候选 1 命中后停止、图片降采样至 669 × 1024；系统日志确认 intent 成功完成，最终点击区间未出现图片超限、归档失败或动作 metadata 缺失。首次安装时系统 `linkd` 动作索引因 `GRDB.DatabaseError Code=8` 阻止动作，用户重启设备后恢复。原 MuseumMuse 安装未覆盖。本轮仅验 iOS 27；未重测十组逐项 UI、四尺寸完整闭环、整点自动调度或减弱动态效果的系统开关，相关业务逻辑沿用上一轮回归。本轮证据在 `build/verification/widget-refresh-feedback/`；不递增版本/Build、不发布。

- 2026-10-31 桌面原地刷新：刷新按钮由 Link 改为 `Button(intent:)`，使用 `openAppWhenRun=false` 的 `WidgetRefreshIntent`，仅传当前组号并等待共享刷新服务完成；保留 44 × 44 pt 点击区与旧刷新 URL 兼容。默认 `iPhone 17 Pro` / iOS 27 模拟器构建、安装、启动通过；实际点击按钮后停留桌面并成功换展品，边缘及连续点击日志确认 nonce=7 抢占 nonce=6。小、中、大、超大竖排四尺寸桌面截图确认同组内容，主体点击进入对应详情。52 项 Widget 状态/设置回归全部通过，覆盖同组跨尺寸共享、同馆不同组隔离、无实例不刷新与抢占；系统日志未命中 `imageTooLarge`、归档失败、`CHSErrorDomain`、`Fatal error` 或 `No AppIntent`。证据在 `build/verification/widget-inline-refresh/`。未安装真机、未重测整点自动调度或十组逐项 UI；既有重签安装身份约束不变。此轮不递增版本/Build、不发布。

- 2026-10-31 修复刷新按钮边缘误入详情：在 `Yao iPhone 17 Pro` / iOS 27 的既有 `1.1.4 (10)` 重签安装版复现，图标中心可刷新，偏左下边缘打开详情；将刷新 Link label 内的矩形点击区统一扩大为 `44 × 44 pt`，保持图标大小与中心位置。在默认 `iPhone 17 Pro` / iOS 27 模拟器完成构建、安装、启动，小尺寸成功态相同偏移的边缘点击触发第 1 组刷新并更新桌面展品，主体点击仍进入对应详情；小、中、大、超大竖排四尺寸桌面截图显示同组相同展品与正常按钮布局。请求日志确认首个成功候选后停止推进，相关系统日志未命中 `imageTooLarge`、归档失败、`CHSErrorDomain` 或 `Fatal error`。证据在 `build/verification/widget-refresh-hit-target/`。设备 Debug 与本地 unsigned Release 构建通过；修复版未装入真机，因既有重签 App 的 application-identifier 与本地开发身份不匹配而被 iOS 拒绝覆盖。用户选择保留原 App，自行重签安装本地修复包；未发布、未递增版本/Build，也未重测十组全部状态、组间并发或整点自动调度。

- 2026-10-11 统一为唯一的 10 组静态 Widget：72 项分组/状态/设置/自动刷新测试、7 项 profile 测试和 4 项签名边界测试通过；设备 Release 与模拟器构建通过。在默认 `iPhone 17 Pro` / iOS 26.5 以及 `MuseumMuse Widget Groups` / iOS 27 安装、启动并定向刷新成功，成功候选后停止继续拉取。两台模拟器的小尺寸 SpringBoard 截图显示新展品；iOS 27 第 1 组四尺寸生成成功 timeline，第 2 组保留独立内容；实际点击桌面刷新打开 App 并完成指定组刷新，十组设置页保留既有选馆。相关系统日志未命中 `imageTooLarge`、归档失败、`CHSErrorDomain`、`Fatal error` 或 `No AppIntent`。证据在 `build/verification/widget-groups-only/`。本轮未安装真机、未逐尺寸截图或重测整点自动调度；分组键/同馆不同组隔离及旧状态迁移由回归测试覆盖。

- 2026-10-10 移除桌面组号角标：常规版在默认 `iPhone 17 Pro` / iOS 26.5 构建、安装、启动通过；兼容版在 `MuseumMuse Widget Groups` / iOS 27 构建、安装、启动通过。第 1 组定向刷新成功并停止候选推进，小尺寸桌面成功态确认无组号；现有第 1 组小、中、大、超大和第 2 组中尺寸均生成成功 timeline。相关 Widget/SpringBoard/chronod 日志未命中 `imageTooLarge`、归档失败、`CHSErrorDomain`、`Fatal error` 或 `No AppIntent`。证据在 `build/verification/widget-hide-group-number/`；随后已发布 OTA `1.1.2 (8)`，设备 Release、逐目标验签及 HTTPS 回验通过，发布证据在 `build/verification/ios-ota-1.1.2/`。本次未安装真机，未逐尺寸截图及重测自动调度。

- 真机补验使用现有本地开发构建与安装链路，已有私有签名与历史真机覆盖范围见 [历史 OTA 文档](ios-adhoc-ota.md)，不触发 OTA 发布；真实小组件、点击刷新停留桌面、共享日志与详情链接需按真机补验范围验证。所有构建需验证 10 个 kind 的注册、四种尺寸（超大须 iOS 27）、同组跨尺寸同步和不同组独立选馆/刷新、组 1 升级迁移、选择持久化及无实例不刷新。日志以 `compat:<组号>|<scope>` 区分同馆不同组；选馆在 App 中验收。用户指定模拟器时按其要求验证，实机/整点自动刷新等未覆盖项如实记录。

- 验证小组件问题时，默认要形成“构建 / 安装 / 启动 + 日志 + 桌面截图 + 系统日志”的闭环，不接受只看 provider 日志就下结论。
- 模拟器推荐链路：
  - `xcodebuild -project DailyMuseum.xcodeproj -scheme DailyMuseumTests -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -derivedDataPath .deriveddata-sim build-for-testing`
  - `xcrun simctl install <SIMULATOR_ID> .deriveddata-sim/Build/Products/Debug-iphonesimulator/DailyMuseum.app`
  - `xcrun simctl launch <SIMULATOR_ID> tech.zh0ngtian.MuseumMuse`
- 仓库内现有日志脚本：
  - `scripts/pull_simulator_request_logs.sh`
  - 常用参数：
    - `--udid <SIMULATOR_ID>`：指定模拟器
    - `--clear`：清空旧日志
    - `--trigger-refresh`：触发 `dailymuseum://debug/widget-refresh`
    - `--instance-token <TOKEN>`：按共享刷新键定向触发刷新，键为 `compat:<组号>|<scope>`
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

### 6.4 GitHub iOS 构建检查

#### 日常 push / PR：只检查构建

- 工作流入口：[`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml)，名称为 `iOS Build`。分支 push / pull request 仅在变更命中 `DailyMuseum/**`、`DailyMuseumWidget/**`、`Shared/**`、`DailyMuseumTests/**`、`DailyMuseum.xcodeproj/**`、`Config/**` 或 `Project.yml` 时自动执行；纯后端、数据、文档、运维、流水线或发布工具改动不自动触发。分支 push 显式使用 `branches: ['**']`，避免标签 push 同时触发日常构建与发布构建。保留 `workflow_dispatch` 供明确要求手动构建时使用，不为非客户端改动主动补触发。
- 使用已提交的 Xcode 工程和共享 scheme，不在 CI 中重新生成工程；检出代码和递归子模块。继续使用 `xcode-27` arm64 runner，固定 `DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer`。runner / 工具链原有依据见 [GitHub runner 说明](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/) 与 [软件清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)；镜像变动时显式更新配置。
- 唯一的 `Build` 任务运行 [`scripts/check_ios_build.sh`](../scripts/check_ios_build.sh)：检查 Xcode 和 iOS SDK，随后仅调用一次 `xcodebuild ... -scheme DailyMuseum -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`，编译 App 和嵌入的 10 组静态 Widget。使用占位鉴权值，无需正式后端 Secret、证书或 provisioning profile。
- **CI 成功只表示编译、链接通过。** 不运行 Swift / Python 回归、模拟器测试目标编译、模拟器启动 / 安装 / 运行，不进行 IPA 打包、版本检查、校验和、元数据或产物上传；成功时不上传诊断。失败时仅上传 `build/ci/*.log`，保留 7 天。日志在输出前隐去鉴权值，`pipefail` 保证构建失败不会被日志管道吞掉。
- 功能按改动范围在本地验证，继续遵守第 6.1–6.3 节；构建检查不能替代安装、Widget 桌面截图或系统日志。本次用户报告的模拟器回归耗时为 8 分 16 秒，精简主要省去这一段，依赖下载和 Release 编译仍需时间；新流程总耗时尚未实测。
- 本地复现：`bash scripts/check_ios_build.sh`，设备构建和日志位于忽略目录 `build/ci/`；不产生 IPA。任务仅有 `contents: read`。主分支使用稳定 `museummuse-production-build` group，开发/PR使用独立的ref group；均 `cancel-in-progress: false`、`queue: max`。普通分支提交（含 `main`）可在没有新发布冻结清单时构建，并记录实际提交与源码树；正式冻结批次仍检查精确引入提交和任务祖先，工具/后端批次跳过客户端编译，且不会仅因 manifest 变化自动触发此流程。日常构建上下文不构成发布凭证，标签发布仍强制校验客户端冻结批次。

#### 标签发布：保留 IPA 和 Release 附件

- 独立入口：[`.github/workflows/ios-release.yml`](../.github/workflows/ios-release.yml)，名称为 `iOS Release`，只由 `v*` 标签 push 触发，不受客户端 paths 过滤影响。正式标签格式为 `vX.Y.Z`，须与 App / Widget 的 `CFBundleShortVersionString` 一致；两目标 Build 必须一致且为正整数。
- `Build` 先复用设备 Release 构建，再运行 [`scripts/package_ios_release.sh`](../scripts/package_ios_release.sh)，检查标签、App / Widget 版本和可执行文件，保留嵌入 Widget，封装 `Payload/DailyMuseum.app`，校验 ZIP 完整性及包内版本，生成唯一的 `MuseumMuse-unsigned.ipa`、`.ipa.sha256` 和 `MuseumMuse-unsigned.json`。元数据记录版本、Build、commit、bundle IDs、10 组标记、大小、SHA-256 和鉴权配置状态。
- 标签构建可从同名 GitHub Actions Secret 注入 `MUSEUMMUSE_SIMPLE_AUTH_SECRET`，未配置时仍用占位值，并在 Release 说明中标明不能连接正式后端。无需私有签名材料；上传真实 Secret 仍需用户明确授权。构建脚本在输出及持久化日志前隐去鉴权值。
- 成功后上传发布包 Actions artifact，保留 7 天；`Publish unsigned IPA` 下载并重新核对 SHA-256，使用已存在的版本标签创建或更新 GitHub Release，上传 IPA、校验文件和元数据。日常主分支 push / 手动构建不再创建 `build-<SHA>` prerelease，历史 Release 不删除。发布器将三附件绑定批次/任务/冻结SHA/版本/runId；相同附件真实下载核对后一致则幂等复用，缺失才补上传，不一致即保留原资产并失败，不用 `--clobber` 覆盖。
- 构建任务权限为 `contents: read`，发布任务单独授权 `contents: write`；concurrency为稳定 `museummuse-production-release` group，`cancel-in-progress: false`、`queue: max`；不同标签在同一客户端发布环境排队，不替换已有pending。发布流程不跑回归；仅失败时上传日志。未签名 IPA 安装前需自行签名，流水线不修改版本 / Build，后续不再追加 OTA 发布。
- 本地复现打包：先运行构建脚本，再执行 `RELEASE_TAG=vX.Y.Z bash scripts/package_ios_release.sh`；仅打包现有产物，不再次编译。
- App/Widget 发布交付前确认批次最终提交已推送，日常 `Build` 与指向该提交的版本标签 `Build` / `Publish unsigned IPA` 都成功，标签 Release 的 IPA、校验文件和元数据齐全；记录最终 commit SHA、两个 Actions run URL 与 Release URL，每个任务再核对自身改动已包含并读取该批共享凭证。待执行、失败、取消、本地成功或未推送配置不能宣称 GitHub 已通过。

#### 软件源更新日志

- 每个客户端发布版本在 `Config/ReleaseNotes/<版本>.md` 保存中文更新说明，供 GitHub Release 使用；缺失或没有中文内容时停止发布，不能只写批次号替代实际更新内容。
- 更新说明须用具体中文描述该版本实际交付的新增功能、体验调整和问题修复；合批时汇总实际改动，不包含未交付或计划中的功能，不只写“常规更新”“优化体验”“修复若干问题”。产品名、API 名称等必要专有名词可以保留原文。
- 发布前核对版本号与最终发布内容，确认对应中文日志已随 GitHub Release 更新写入。

#### 手动按需回归

- 独立入口：[`.github/workflows/ios-regression.yml`](../.github/workflows/ios-regression.yml)，名称为 `iOS Regression`，仅 `workflow_dispatch`，没有 push / PR / 标签触发。
- 在 Actions → Run workflow 选择 ref 和模拟器 destination（默认 `platform=iOS Simulator,name=iPhone 17 Pro,OS=latest`，按 runner 可用设备调整）。安装 `server/requirements.txt` 后执行服务端和脚本 Python `unittest`，再以 `DailyMuseumTests` scheme 执行 Swift 模拟器 `xcodebuild test`，关闭 parallel testing。运行时由 Xcode 管理模拟器和测试安装 / 启动，无需私有签名材料。
- 保留回归日志和 `.xcresult`，无论成功失败上传并保留 7 天；不打包 IPA、不发布 Release。依赖本机私有材料或已安装 skill 的 Python 测试可能跳过，必须查看测试摘要；手动自动化回归不能替代 Widget 桌面截图、真机权限和线上验证。

### 6.5 多任务发布协调

通用合批、互斥、冻结与恢复原则仅维护在 canonical 全局 `AGENTS.md`。本项目已复用现有 ReleaseCoordinator 0.1.3，共享服务配置、适配器、任务登记/验证/ready、共同receipt核对和实际验收集中维护在 [协调器接入](release-coordinator-integration.md)，不在本节复制操作合同。

本节仅在用户明确要求发布时启用。默认代码交付按第 6.1 节完成，不进入发布队列、不提交 `ready`，也不以发布 receipt 作为日常交付的完成条件。

`scripts/museum_release_adapter.py` 的客户端阶段为 `promote → build → github → verify`；旧协调器配置若仍请求 `device`、`sign`、`ota`，返回 `required=false` / `reason=unsigned-ipa-only`，不构建本机发布包、不读取私有签名或 OTA 配置、不访问旧 OTA 渠道。版本准备只依据工程版本和 GitHub 版本标签，Build 在工程值基础上递增；工具批次保持原值，最终只核对主分支提交，不再验签或回验历史 OTA。

客户端目标为 `tech.zh0ngtian.MuseumMuse` / production，保持主App+Widget、main、日常 `iOS Build` 和标签 `iOS Release`，仅交付 unsigned IPA、SHA-256 和元数据。后端目标为 `museummuse-api` / production，保持全量SQLite、Python/腾讯SCF、COS版本化对象和原线上验收；两者分开协调，只有promote阶段写同一main时共用短锁。涉及两侧的任务分别登记子任务和依赖，等待各自必要验收，不借用另一目标的成功结果。

客户端各任务验证记录保存 `baseSha` 与真实证据，冻结提交包含所有任务SHA；功能批次仍执行第6.1–6.3节完整要求，client-local和Widget桌面证据不能用CI代替。正式CI的稳定作用域group关闭抢占并使用 `queue: max`，全历史校验批次引入提交/版本/任务祖先，Release 三附件绑定同一冻结来源。纯文档、纯工具和纯后端批次不编译客户端、不递增App版本、不触发IPA Release。

SCF新包的marker和真实代码包checksum必须与冻结来源、SQLite/manifest及线上health相符；只读probe通过不能代替新包部署。2026-10-13已通过适配器与恢复替身、现役GitHub/OTA与六馆API只读核验；原云凭证与全量输入已恢复；SCF成功关联修复批次已实际核对云端包、673文件、输入及线上完整接口，原failed历史保持不变；真实状态与同一recovered receipt见接入文档。用户登录启动和系统开机启动、多机SSH授权、已实现机制和真实新版本验收需分别报告。详细证据与待办见接入文档。

阶段结果和共同发布凭证保存在现有协调器状态目录，逐任务核对receipt后才交付；failed历史保留，修复流程按canonical全局与接入CLI办理。发布排队语义依据 [GitHub concurrency 文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)，CI排队不替代提交合批。
