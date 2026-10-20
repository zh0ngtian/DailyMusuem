# MuseumMuse Ad Hoc / OTA

默认交付规则见 [默认验证策略](verification-and-delivery.md#61-默认验证策略)：验证通过后合入 `main`，仅在修改期间主分支有新提交时追加合入后回归，再提交和推送代码。默认不发布、不递增版本 / Build；本文发布流程仅在用户明确要求发布时执行。

## 当前版本 1.1.4（2026-10-20）

按用户要求基于当前代码重新打包为 `1.1.4 (10)`；保留现有六馆主 App 和 10 组静态小组件，本次没有新增客户端功能。中文更新说明保存在 `Config/ReleaseNotes/1.1.4.md`，OTA 与 GitHub Release 共用。

冻结来源为 `c4ad5b388bed05d0fc4dedae76b3e159ca35751f`，发布批次为 `1aa7d660-64a6-43e3-8189-be1e49a13641`。[日常 iOS Build](https://github.com/zh0ngtian/DailyMusuem/actions/runs/39280976507) 的 `Build`、[标签 iOS Release](https://github.com/zh0ngtian/DailyMusuem/actions/runs/39284302632) 的 `Build` 和 `Publish unsigned IPA` 全部通过。[v1.1.4 Release](https://github.com/zh0ngtian/DailyMusuem/releases/tag/v1.1.4) 提供未签名 IPA、SHA-256 校验文件和元数据。三个附件已真实下载核对，包内 App / Widget 均为 `1.1.4 (10)`，来源、批次及校验和一致，鉴权已配置。未签名 IPA 为 `2603064` bytes，SHA-256 `3c49d9de3e1c76e65968f18e0014ccb244aa5e9301a0103a02ee3df8c81810f3`。

当前 OTA 已原子切换为 `1.1.4 (10)`。Ad Hoc 已签名 IPA 为 `2645304` bytes，SHA-256 `7d004791939699f14f4c9a53092af848f7100d5ebec885c2a7ae5e43dcc7af42`。主 App / Widget 逐目标独立验签、升级身份、包内冻结来源与批次，以及版本目录和固定入口 HTTPS HEAD / 完整 GET / SHA-256 回验全部通过，旧版本保留。已核对安装页与 GitHub Release 均使用本版本中文更新说明。

- [固定安装页](https://192.168.123.79:8768/channels/museummuse/current/install.html)
- [固定 IPA 下载](https://192.168.123.79:8768/channels/museummuse/current/latest.ipa)
- manifest 指向不可变 `releases/1.1.4/latest.ipa`。

本地 93 项发布机制测试、7 项 profile 测试和 4 项 Widget 签名边界测试通过。默认 `iPhone 17 Pro` / iOS 27 完成构建、安装、启动与首页截图；冻结版本的 App / Widget 版本号也已核对，冻结发布清单验证通过。本次未做真机覆盖安装、小组件桌面或整点自动刷新回归；客户端功能代码与上一版一致。证据保存在 `build/verification/release-1.1.4/`，其中 `receipt.json` 是已核对的共同发布凭证副本；原凭证为现有协调器状态目录的 `receipts/1aa7d660-64a6-43e3-8189-be1e49a13641.json`。本轮文档记录单独收尾，不重建或重发客户端。

## 历史版本 1.1.3（2026-10-11）

统一为唯一的 10 组静态小组件，删除常规 AppIntent 配置、按钮刷新与编译切换逻辑。所有构建在 App 中为各组选馆、通过链接手动刷新；同组跨尺寸共享，各组独立。该版本的 GitHub Actions 构建并发布一份 `MuseumMuse-unsigned.ipa` 和校验文件。

当前发布：`1.1.3 (9)`，Ad Hoc 已签名，`2644885` bytes，SHA-256 `d27f78b326f7957b672ef9dd23240298da2b9dfdc8b16cb4b8d8f4ad83d27191`。主 App 与 Widget 逐目标独立验签、升级身份检查、版本目录及固定入口 HTTPS HEAD/完整 GET/大小/SHA-256 回验通过，已原子切换 current，保留历史版本。

- [固定安装页](https://192.168.123.79:8768/channels/museummuse/current/install.html)
- [固定 IPA 下载](https://192.168.123.79:8768/channels/museummuse/current/latest.ipa)
- manifest 指向不可变 `releases/1.1.3/latest.ipa`。

[构建记录](https://github.com/zh0ngtian/DailyMusuem/actions/runs/38136958110) 的 `Build` 和 `Publish unsigned IPA` 通过，[对应 Release](https://github.com/zh0ngtian/DailyMusuem/releases/tag/build-b2ccbcddc4947bb62f7859e783b4f6a05a84928c) 提供单份未签名 IPA。该发布对应功能提交 `b2ccbcddc4947bb62f7859e783b4f6a05a84928c`；后续纯记录提交不重发 OTA。

72 项 Widget 回归与 11 项签名相关测试通过；默认 iOS 26.5 与补充 iOS 27 模拟器安装、启动、桌面小尺寸成功态通过。iOS 27 实际点击刷新打开 App 并完成对应组刷新，十组设置页保留原选馆，其他组保持独立；四尺寸 timeline 与系统日志检查通过。本轮未安装真机、未逐尺寸截图或重测整点自动刷新。构建/请求/桌面证据在 `build/verification/widget-groups-only/`，签名及发布证据在 `build/verification/ios-ota-1.1.3/`。

## 历史版本 1.1.2（2026-10-10）

移除桌面小组件左上角组号，保留添加小组件和主 App 设置中的组名，以及各组独立选馆/刷新。当时后续改动自动发布 OTA 的授权已于 2026-10-20 被默认仅提交代码、不发布的规则取代；现行规则维护在 [AGENTS.md](../AGENTS.md)。

该次发布：`1.1.2 (8)`，Ad Hoc 已签名，`2704741` bytes，SHA-256 `6035209e0d7003ad56f25f788e769991c70f912bd246ec64420702cbe3fb4b70`。设备 Release 构建、主 App/Widget 逐目标验签、版本目录与固定入口 HTTPS HEAD/完整 GET/SHA-256 回验通过，已原子切换 current，未覆盖历史版本。

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

本节目录、锁与命令是现有执行环节。已复用ReleaseCoordinator共享服务；目标、凭证和适配器统一见 [多任务发布协调](verification-and-delivery.md#65-多任务发布协调)。OTA 发布器已有的 `.museum-release.lock` 是本机末端发布锁，仍作为末端锁，完整阶段由现有服务的作用域租约协调，多机器只用同一发布主机SSH入口。

仓库外状态目录为 `~/Library/Application Support/IOSAdHocOTA/museummuse/`：

- `release.local.json`：显式目标/profile/entitlements 映射、基准 SHA、发布模式及 TLS/渠道路径。
- `installed-baseline.ipa`：最初实际安装包及固定 SHA-256，签名前重新独立验签。
- `channel/releases/<version>/`：不可覆盖的版本目录；`channel/current` 原子指向当前版本。
- LaunchAgent：`~/Library/LaunchAgents/local.ios-adhoc-ota.museummuse.plist`，调用 `scripts/serve_ios_ota.py`；必须保留脚本位置。局域网 IP 改变时须同时更新证书 SAN 与发布 URL。

共享配置 `~/Library/Application Support/IOSAdHocOTA/signing.local.json` 只引用现有 P12/profile/password 文件，私钥、密码、配置和 IPA 不提交仓库。

所有构建统一为 10 组静态 Widget，无需编译条件切换。App 与 Widget 的 `MuseumWidgetCompatibilityBuild=YES` 是保留给既有签名校验器的固定产物标记，私有配置继续设置 `widgetCompatibilityMode: true`；这两个历史字段不再选择另一套实现。每个发布批次统一使用新的版本号和递增 Build，参与任务共用该版本，禁止覆盖历史版本。

用户明确要求发布后，各发布任务按 [协调器接入](release-coordinator-integration.md#登记验证和交付) 登记、本地验证、push固定SHA后ready。正式构建/签名/发布由 `scripts/museum_release_adapter.py` 的对应阶段执行；开发任务不分别运行这些发布步骤。设备构建继续使用原Xcode Release，批次私有目录记录冻结来源；已有完整产物经核对后复用。

`sign_ios_widget_ipa.py` 仍按原身份逐目标签名和独立验签；适配器在签名前为两目标Info写入已冻结 `MuseumReleaseSourceCommit` / `MuseumReleaseBatchID`。`publish_ios_widget_ota.py` 正式发布必须同时传 `--source-commit` 和 `--batch-id`，读取最终签名包的两目标字段核对，验证后写入OTA receipt。参数和额外字段不改变签名身份、profile、共享组或渠道。仅本地预检 `--plan` 可不传来源参数，不代表发布成功。

签名与权限边界的本地回归：

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_ios_adhoc_profiles.py'
python3 -B -m unittest discover -s scripts/tests -p 'test_ios_widget_signing.py'
python3 -B -m unittest discover -s scripts/tests -p 'test_widget_ota_release_source.py'
```

签名流程：固定 SHA 的基准快照 → 安全解包和嵌套关系检查 → 临时钥匙串导入现有 P12 → 每目标校验证书/profile/设备/有效期/全部实际权限 → 扩展先签、主 App 后签 → 最终 IPA 独立验签。发布器再次按配置核对全部 target 的实际权限、安装身份、版本、运行 group 和兼容模式，然后暂存、HTTPS HEAD/完整 GET/SHA-256 回验、原子激活、固定入口回验。此 OTA 发布器不接受仅带 `signed=true` 的外部元数据。

## 软件源更新日志

- 每个客户端发布版本在 `Config/ReleaseNotes/<版本>.md` 保存中文更新说明；协调器准备阶段检查该文件，OTA 安装页与 GitHub Release 读取同一份说明。缺失或没有中文内容时停止发布，不能只写批次号替代实际更新内容。
- 后续每次向软件源发布更新，面向用户的更新日志必须使用中文，清楚说明该版本实际交付的新增功能、体验调整和问题修复（按本次改动涉及的内容填写）。
- 更新日志必须与对应版本的最终发布内容一致；合批发布时汇总该批次的实际改动，不把未交付或计划中的功能写成已完成。
- 使用用户能理解的具体描述，说明改动涉及的功能及更新后的行为，避免只写“常规更新”“优化体验”“修复若干问题”等笼统内容。产品名、API 名称等必要专有名词可以保留原文。
- 发布前核对软件源中的版本号与更新日志，确认中文日志已随该版本更新写入。

## 发布与构建检查

本节仅用于用户明确要求的 App/Widget 发布；日常验证、合入与提交按 [默认验证策略](verification-and-delivery.md#61-默认验证策略) 完成，不触发以下发布步骤。

1. 各任务完成对应变更的本地验证和文档回填，登记确定的提交 SHA 与结果；由统一协调入口按 canonical 全局合批规则整合，按影响完成必要检查，统一递增版本与 Build 并冻结批次。项目协调要求与未落地部分见 [多任务发布协调](verification-and-delivery.md#65-多任务发布协调)。不涉及客户端的改动不触发客户端构建、不要求未签名 IPA Release、不递增 App 版本、不重新发布 OTA，只执行对应验证；客户端范围见 [默认验证策略](verification-and-delivery.md#61-默认验证策略)。
2. 协调入口将批次最终提交推进 main 并推送 GitHub，确认该提交日常 `iOS Build` 的 `Build` 通过；推送指向同一 SHA 且匹配 App / Widget 版本的 `vX.Y.Z` 标签，统一触发一轮独立 `iOS Release` 的 `Build` 与 `Publish unsigned IPA`。确认两任务通过，标签 GitHub Release 中唯一的 `MuseumMuse-unsigned.ipa`、SHA-256 校验文件和元数据齐全，核对标签、run 的提交与产物 metadata commit 一致，在共享凭证记录最终 SHA、两个 Actions run URL 和 Release URL。日常 CI 成功只表示编译、链接通过，功能按改动范围在本地验证；主分支 push 不再自动生成 Release。工作流和本地复现入口见 [GitHub iOS 构建检查](verification-and-delivery.md#64-github-ios-构建检查)。
3. 协调入口按现有构建入口从该冻结提交统一构建设备版本，使用现有私有配置逐目标签名和独立验签，然后发布 OTA；登记本地构建来源与产物校验和，不复用其他 SHA 的成功构建。完成版本目录与固定入口 HTTPS HEAD、完整 GET、大小与 SHA-256 回验，把 `channel/releases/<version>/latest-ios.json`、验签和回验记录关联到同一批次共享凭证。新OTA JSON记录已从最终两目标验证的sourceCommit/batchId，并在共同receipt关联CI；历史JSON缺这些字段时明确作为历史基线，不补造来源。
4. 批次最终提交的构建检查、Release 上传与 OTA 回验，以及改动范围所需本地 / Widget 验收都成功后，每个任务核对自己的改动包含于最终提交，并读取同一发布凭证，才算 App/Widget 交付完成。标签发布流水线构建并发布未签名 IPA，实际签名、安装和 Widget 桌面验收继续走现有本地链路；进入队列或加入批次不算交付。

冻结后到达的任务和失败恢复遵守 canonical 全局规则；不得追加到在建批次、抢占发布或重复签名发包。现有 OTA 版本目录仍不可覆盖；GitHub Release附件先真实下载核对，一致幂等、缺失补传，不一致保留并失败。历史版本、产物、凭证与实际验收范围继续保留。

## 首次兼容修复的验证与限制

- 真机兼容 Release 与模拟器默认 Debug 均构建成功；模拟器默认 App 已安装启动，默认 AppIntent 小组件桌面仍显示成功态，01:13:15 provider 日志为 `scope=all phase=success`。
- 3 个设置/Widget 设置读取单测通过；7 个严格 profile 测试与 4 个复杂包签名边界测试通过。
- 真机请求日志：`scope=all`，候选 1 图片 `2500x1878 → 1024x769`，成功后停止继续拉取；`family=small ... phase=success`。
- 01:11:05 之后采集的相关系统日志未出现 `No AppIntent`、`imageTooLarge`、`Widget archival failed`、`CHSErrorDomain`。存在一条 SpringBoard content-confirmation timeout，桌面与点击实测成功；不宣称系统日志完全无警告。
- 桌面小尺寸成功态、刷新、详情跳转已实测；自动刷新保留原调度实现，本次未等待下一个整点，也未重新逐尺寸验收中/大组件或全部前后台冷启动组合。
- 本地证据：`build/verification/ios-ota-1.0.3/`（忽略目录），包含安装信息、发布 JSON、桌面/日志/详情截图及系统日志。不得把 provider success 单独当作通过。

依据：[Apple Widget 深链接文档](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)。技能来源：`~/.codex/skills/ios-adhoc-ota/SKILL.md` 与 `references/complex-targets.md`。
