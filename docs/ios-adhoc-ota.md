# MuseumMuse Ad Hoc / OTA

## 当前版本 1.1.2（2026-10-10）

移除桌面小组件左上角组号，保留添加小组件和主 App 设置中的组名，以及各组独立选馆/刷新。用户已授权后续 App/Widget 改动完成并通过必要验证后直接发布 OTA，并要求对应提交的 GitHub 构建检查通过，规则维护在 [AGENTS.md](../AGENTS.md)。

当前发布：`1.1.2 (8)`，Ad Hoc 已签名，`2704741` bytes，SHA-256 `6035209e0d7003ad56f25f788e769991c70f912bd246ec64420702cbe3fb4b70`。设备 Release 构建、主 App/Widget 逐目标验签、版本目录与固定入口 HTTPS HEAD/完整 GET/SHA-256 回验通过，已原子切换 current，未覆盖历史版本。

- [固定安装页](https://192.168.123.79:8768/channels/museummuse/current/install.html)
- [固定 IPA 下载](https://192.168.123.79:8768/channels/museummuse/current/latest.ipa)
- manifest 指向不可变 `releases/1.1.2/latest.ipa`。

模拟器验证见 [验证记录](verification-and-delivery.md#63-小组件截图闭环测试)：常规与兼容构建/安装/启动通过，兼容版小尺寸桌面确认无组号，定向刷新和相关系统日志通过。本次未安装真机、未重测整点自动刷新及全部尺寸截图。构建/签名/发布证据在 `build/verification/ios-ota-1.1.2/`，桌面与请求/系统日志证据在 `build/verification/widget-hide-group-number/`。

## 历史版本 1.1.1（2026-10-10）

实现 10 组兼容小组件，每组支持小、中、大、iOS 27 竖向超大（`systemExtraLargePortrait`）。在主 App 设置 → 小组件 →“分组与展示博物馆”分别选馆；同组跨尺寸同步，组间独立，即使选同馆也不合并内容。第 1 组保留原 kind 和选馆偏好；详情合同见 [主 App 规范](app-behavior-contract.md#10-组小组件入口)。

当时发布：`1.1.1 (7)`，Ad Hoc 已签名，`2706484` bytes，SHA-256 `d25b49b876b1c70bd14f900cfa737a0124f5b4a84dcff6245ab3b6ff9f75a877`。固定入口沿用下文，版本化包为 `releases/1.1.1/latest.ipa`。签名与 HTTPS HEAD/完整 GET/SHA-256 回验通过；1.1.0 的注册错误在模拟器发现后已撤下当前渠道，由此版本修复，不覆盖旧版本目录。

本轮按用户要求使用独立 `MuseumMuse Widget Groups`（iPhone 17 Pro / iOS 27）模拟器验收，未安装本版到真机。证据保存在 `build/verification/ios-ota-1.1.1/`：

- 5 项设置、非法值、导入导出、组键/链接与同馆多组刷新隔离单元测试通过；默认模拟器测试为 iOS 26.5，四尺寸真实渲染另在 iOS 27 覆盖。设备 Release 与模拟器兼容构建成功，模拟器已安装启动。
- 系统日志确认 10 个 kind × 4 尺寸共 40 种 snapshot 成功（`registered-previews.json`）。最初插值名称触发 `Formatted text for configurationDisplayName is not supported`，已改用 `Text(verbatim:)`，修复后注册成功。
- 设置页完整显示第 1–10 组；无实例时选择第 1、2 组只记录“当前 WidgetKit 配置：空”，没有展品请求。关闭重启 App 后选馆仍保留。
- 第 1 组选国博，实际桌面小、中、大、超大均显示“济南刘家功夫针铺”广告青铜版；同组共享图片和状态。之后刷新一次更新为“仿石釉堆贴螭龙纹瓶”，小尺寸与超大桌面均已确认同步更新，四尺寸 provider 均产生成功态。
- 第 2 组选上博，独立显示“长沙窑青釉褐彩执壶”；在主 App 把第 2 组改成国博后显示《医林改错》木雕版，第 1 组保持原展品。随后第 1 组刷新也未改变第 2 组内容。两个组分别使用 `compat:1|single:nmc` 和 `compat:2|single:nmc`，证明同馆不同组仍隔离。
- 请求日志确认 network-only 单件候选、命中后停止，图片降采样仍满足原上限。10:12:20 起修复版相关系统日志未命中 `imageTooLarge`、`archival failed`、`CHSErrorDomain`、`No AppIntent` 或 `Fatal error`。
- 本轮未等待整点自动刷新，未逐一把全部 40 种配置放到桌面；组 3–10 验证范围为系统注册/预览和共用实现。未重测真机旧版覆盖迁移或全部深链接前后台组合，不能以模拟器结果替代这些结论。

## 历史版本 1.0.4（2026-10-10）

新增主 App 设置 → 小组件 → “展示博物馆”：默认所有博物馆，支持 metadata 中全部可用单馆。所有桌面兼容小组件共用这一选择；切换立即保存、触发 network-only 刷新，手动与自动入口读取同一 scope。移除馆/不支持 Widget/非法配置回退全部，配置导入导出包含此项。下文 1.0.3 是首次修复的历史证据。

当时发布：`1.0.4 (5)`，Ad Hoc 已签名，`2681894` bytes，SHA-256 `35ae3a53ef63b5fb1738580d39134626718cff42abafbdd1adfd9c885dde61ea`。固定安装入口不变，版本化包为 `releases/1.0.4/latest.ipa`。本轮验收证据保存在 `build/verification/ios-ota-1.0.4/`。

本轮实际验证：2 个持久化/非法或已移除馆回退/配置导入导出测试通过；真机与模拟器兼容构建成功，模拟器完成安装启动。真机从全部切到国博（金冠）、再切到上博（银币），桌面图片立即随选馆更新；终止 App 后点击桌面刷新冷启动，选择仍为上博，请求日志 `single:shm` 刷新为毛公旅鼎且命中首件后停止。设置的 1 小时自动刷新保留。最后恢复选择为全部。01:27:30 起采集的相关系统日志未命中 `No AppIntent`、`imageTooLarge`、`archival failed`、`CHSErrorDomain`。本轮未重新测试整点自动刷新、中/大尺寸及多个桌面实例，也未删除真机现有 Widget 测试无实例场景。

## 首次兼容修复 1.0.3（2026-10-10）

真机 `Yao iPhone 17 Pro` 已通过 Safari OTA 覆盖安装 `1.0.3 (4)`。兼容静态 Widget 已显示上海博物馆“犀角雕倒卷荷叶杯”，点击右上角刷新打开 App 并成功更新桌面，点击主体进入对应详情。原 App 未卸载，自动刷新设置仍为 1 小时，已有类别设置保留。

- 固定安装页：<https://192.168.123.79:8768/channels/museummuse/current/install.html>
- 不可变 IPA：<https://192.168.123.79:8768/channels/museummuse/releases/1.0.3/latest.ipa>
- 大小：`2674463` bytes
- SHA-256：`3e9b13200af00336ce0dab40ae672e8abcd119bb4f6991911e2b7875fcaeb97e`
- 仅目标设备、同一局域网可用；复用手机已信任的 Codex Mobile LAN CA，没有新增根证书。独立服务端口 `8768`，其它项目的 `8766` 服务不变。

实际提供的 profile 是包含登记设备的 **Ad Hoc** profile，并非 `ProvisionsAllDevices` 企业 profile。P12 可以同时签 App 和 Widget；当前障碍不能概括为“P12 不支持 Widget”。两次实机对照（1.0.1/1.0.2）表明，App 与扩展都能安装、共享组可用，但系统拒绝扩展连接 `com.apple.siri.VoiceShortcuts.xpc`，随后出现 `No AppIntent in timeline` 和 `CHSErrorDomain 1101`。具体授权判断尚未证实；不能仅凭这些日志归咎于全能签。

用户因此选择兼容版：固定所有博物馆，暂不支持桌面选择单馆，手动刷新打开 App。它使用 `StaticConfiguration` / `TimelineProvider`，不通过 AppIntent 配置或按钮。三尺寸、原有共享状态、network-only 候选、去重历史、降采样、失败态和自动 timeline 规则继续共用原实现。该段记录当时两种构建的历史状态；自 1.1.3 起统一为 10 组静态小组件。

## 签名与存储边界

- 源码 Bundle ID 保留 `tech.zh0ngtian.MuseumMuse` 与 `tech.zh0ngtian.MuseumMuse.widget`。
- 已安装基准 IPA 经逐目标独立验签，两目标实际签名 App ID 都为 `SC456JW7RP.app.jade6694.grapefruit3766`，Team 为 `SC456JW7RP`。升级严格保留该安装身份、keychain groups 和目标集合；不能从 profile 的 App ID 猜测或修改 CFBundleIdentifier。
- 严格的新身份预检仍由 `scripts/check_ios_adhoc_profiles.py` 执行；原默认 profile 不授权项目原始 App ID / App Group。这不等于已经安装且独立验签通过的兼容身份不能覆盖升级。
- 本项目签名适配器 `scripts/sign_ios_widget_ipa.py` 加载 `ios-adhoc-ota` skill 的加解密与验签函数，显式映射每个 target 的 profile。共享同一 profile 必须建立在固定基准身份、逐目标授权检查之上，绝不自动将主 App profile 套给未知扩展。
- 源码默认 App Group 保留 `group.tech.zh0ngtian.MuseumMuse`。该私有渠道明确选择 profile 已授权的 `group.363da22903f0409e.5`，签名时写入两个目标的 `MuseumAppGroupIdentifier`，且核对实际 entitlement 一致。
- 此 group 也被其它同证书应用使用。`MuseumMuse.` defaults 前缀及 `MuseumMuse/` 文件目录只避免命名冲突，不提供不同应用之间的安全隔离。只有主 App 在首次成功访问共享组时复制旧私有 suite 的已知项目偏好，不覆盖已有目标值；配置导入导出继续使用可移植键名。
- 当前 `devicectl` 只允许复制容器 `Library/Documents/tmp` 路径，因此不能直接导出根目录 `MuseumMuse/`。本次通过主 App 请求日志页读取并截图验证共享日志，不能把复制失败误判为共享组不可用。
- 不修改 Apple CMS profile、不制造 profile、不删除扩展、不直接复制旧包的无关能力。项目所需权限来自两个 entitlements 文件，既有安装身份字段保留。

## 私有状态与重复发布

仓库外状态目录为 `~/Library/Application Support/IOSAdHocOTA/museummuse/`：

- `release.local.json`：显式目标/profile/entitlements 映射、基准 SHA、发布模式及 TLS/渠道路径。
- `installed-baseline.ipa`：最初实际安装包及固定 SHA-256，签名前重新独立验签。
- `channel/releases/<version>/`：不可覆盖的版本目录；`channel/current` 原子指向当前版本。
- LaunchAgent：`~/Library/LaunchAgents/local.ios-adhoc-ota.museummuse.plist`，调用 `scripts/serve_ios_ota.py`；必须保留脚本位置。局域网 IP 改变时须同时更新证书 SAN 与发布 URL。

共享配置 `~/Library/Application Support/IOSAdHocOTA/signing.local.json` 只引用现有 P12/profile/password 文件，私钥、密码、配置和 IPA 不提交仓库。

所有构建统一为 10 组静态 Widget，无需编译条件切换。App 与 Widget 的 `MuseumWidgetCompatibilityBuild=YES` 是保留给既有签名校验器的固定产物标记，私有配置继续设置 `widgetCompatibilityMode: true`；这两个历史字段不再选择另一套实现。每次发布使用新的版本号和递增 Build，禁止覆盖历史版本。

```sh
xcodebuild -project DailyMuseum.xcodeproj -scheme DailyMuseum \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .deriveddata-ota CODE_SIGNING_ALLOWED=NO build

python3 scripts/sign_ios_widget_ipa.py \
  --config "$HOME/Library/Application Support/IOSAdHocOTA/museummuse/release.local.json" \
  --app .deriveddata-ota/Build/Products/Release-iphoneos/DailyMuseum.app \
  --output /tmp/MuseumMuse-new.ipa

python3 scripts/publish_ios_widget_ota.py \
  --config "$HOME/Library/Application Support/IOSAdHocOTA/museummuse/release.local.json" \
  --ipa /tmp/MuseumMuse-new.ipa --notes '本版具体变更' --plan

python3 scripts/publish_ios_widget_ota.py \
  --config "$HOME/Library/Application Support/IOSAdHocOTA/museummuse/release.local.json" \
  --ipa /tmp/MuseumMuse-new.ipa --notes '本版具体变更'

python3 -m unittest discover -s scripts/tests -p 'test_ios_adhoc_profiles.py'
python3 -m unittest discover -s scripts/tests -p 'test_ios_widget_signing.py'
```

签名流程：固定 SHA 的基准快照 → 安全解包和嵌套关系检查 → 临时钥匙串导入现有 P12 → 每目标校验证书/profile/设备/有效期/全部实际权限 → 扩展先签、主 App 后签 → 最终 IPA 独立验签。发布器再次按配置核对全部 target 的实际权限、安装身份、版本、运行 group 和兼容模式，然后暂存、HTTPS HEAD/完整 GET/SHA-256 回验、原子激活、固定入口回验。此 OTA 发布器不接受仅带 `signed=true` 的外部元数据。

## 发布与构建检查

1. 完成对应变更的本地验证和文档回填；App/Widget 功能改动递增版本与 Build。纯文档、流水线或发布工具修改不递增 App 版本、不重新发布 OTA。
2. 将拟发布提交推送到 GitHub，确认 `iOS Build` 的 `Build` 与 `Publish unsigned IPA` 全部通过；确认对应 GitHub Release 中唯一的 `MuseumMuse-unsigned.ipa` 和 SHA-256 校验文件齐全，并记录 commit SHA、Actions run URL 和 Release URL。工作流和本地复现入口见 [GitHub iOS 构建检查](verification-and-delivery.md#64-github-ios-构建检查)。
3. App/Widget 改动按上方命令从同一提交构建设备版本，使用现有私有配置逐目标签名和独立验签，然后发布 OTA。完成版本目录与固定入口 HTTPS HEAD、完整 GET、大小与 SHA-256 回验，并记录 `channel/releases/<version>/latest-ios.json` 发布凭证。
4. 对应提交的构建检查、Release 上传与 OTA 回验都成功才算 App/Widget 交付完成。流水线构建并发布未签名 IPA，实际签名、安装和 Widget 桌面验收继续走现有本地链路。

## 首次兼容修复的验证与限制

- 真机兼容 Release 与模拟器默认 Debug 均构建成功；模拟器默认 App 已安装启动，默认 AppIntent 小组件桌面仍显示成功态，01:13:15 provider 日志为 `scope=all phase=success`。
- 3 个设置/Widget 设置读取单测通过；7 个严格 profile 测试与 4 个复杂包签名边界测试通过。
- 真机请求日志：`scope=all`，候选 1 图片 `2500x1878 → 1024x769`，成功后停止继续拉取；`family=small ... phase=success`。
- 01:11:05 之后采集的相关系统日志未出现 `No AppIntent`、`imageTooLarge`、`Widget archival failed`、`CHSErrorDomain`。存在一条 SpringBoard content-confirmation timeout，桌面与点击实测成功；不宣称系统日志完全无警告。
- 桌面小尺寸成功态、刷新、详情跳转已实测；自动刷新保留原调度实现，本次未等待下一个整点，也未重新逐尺寸验收中/大组件或全部前后台冷启动组合。
- 本地证据：`build/verification/ios-ota-1.0.3/`（忽略目录），包含安装信息、发布 JSON、桌面/日志/详情截图及系统日志。不得把 provider success 单独当作通过。

依据：[Apple Widget 深链接文档](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)。技能来源：`~/.codex/skills/ios-adhoc-ota/SKILL.md` 与 `references/complex-targets.md`。
