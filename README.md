# MuseumMuse（博物女神）

MuseumMuse 是一个最低支持 iOS 18 的 SwiftUI App，提供博物馆展品流、详情、收藏和三种尺寸的 Widget。

正式范围为中国国家博物馆、上海博物馆、大都会艺术博物馆、东京国立博物馆、奈良国立博物馆和吉美国立亚洲艺术博物馆。客户端入口、类别和数据源由后端 metadata 下发。

展品数据路径为离线 Python crawler → SQLite → Python API / 腾讯云 SCF → App 与 Widget；图片由客户端按源站 URL 异步下载。

## 开发入口

默认交付为验证通过后合入 `main`；若修改期间主分支有新提交，合入后再按改动范围回归，否则复用已通过的验证，再提交并推送代码。默认不递增版本 / Build、不发布 OTA 或 GitHub Release、不部署 SCF；仅在用户明确要求发布时启用发布协调器。起点记录与比较规则见 [默认验证策略](docs/verification-and-delivery.md#61-默认验证策略)。

自 2026-10-25 起，后续客户端仅发布 GitHub Release 的 unsigned IPA 及 SHA-256 / 元数据附件，停止本机发布构建、私有签名和 OTA 发布。客户端协调器阶段为 `promote → build → github → verify`，旧配置中的 `device` / `sign` / `ota` 请求直接跳过，详见 [协调器接入](docs/release-coordinator-integration.md)。已有签名与 OTA 版本、产物和凭证保留作历史记录；必要的本地功能验证和开发安装继续按改动范围执行。

- 用 Xcode 打开 `DailyMuseum.xcodeproj`，主 App scheme 为 `DailyMuseum`，测试 scheme 为 `DailyMuseumTests`；默认验证模拟器为 `iPhone 17 Pro`，单元测试关闭 parallel testing。
- `Project.yml` 是 XcodeGen 工程配置；鉴权值通过未提交的 `Config/Secrets.local.xcconfig` 注入，变量名为 `MUSEUMMUSE_SIMPLE_AUTH_SECRET`。
- 本地 Python 环境安装 `server/requirements.txt` 后，按 [后端本地启动示例](docs/frontend-backend-separation-design.md#4-总体架构) 生成离线样本并启动 API。样本只用于功能验证，全量库需另行准备。
- 日常 GitHub Actions `iOS Build` 仅在 push / PR 命中客户端路径时执行一次 App 与嵌入 Widget 的真机 Release 构建，使用 `generic/platform=iOS`、关闭签名；检查 Xcode / iOS SDK，检出子模块，失败时上传构建日志。**CI 成功只表示编译、链接通过**；功能按改动范围在本地验证。日常流程不跑 Swift / Python 回归、不启动模拟器、不打包 IPA，成功时不上传诊断或产物；无需私有签名材料或正式后端 Secret。本地入口：`bash scripts/check_ios_build.sh`。
- 推送 `vX.Y.Z` 标签时，独立的 `iOS Release` 工作流构建设备 Release，检查标签与 App / Widget 版本、打包和校验 IPA、生成 SHA-256 与元数据，并上传到该标签的 [GitHub Release](https://github.com/zh0ngtian/DailyMusuem/releases)。主分支日常 push 不再自动发布 `build-<SHA>` Release；既有 Release 保留。发布包仍未签名，后端 Secret 可选，缺失时使用占位值。
- 完整自动化回归改为手动运行 `iOS Regression`（Actions → Run workflow，可指定模拟器 destination），按需执行 Python 回归和 Swift 模拟器测试。Widget 桌面截图、权限和真机功能继续按改动范围本地验收。用户报告本轮模拟器回归耗时 **8 分 16 秒**，精简主要省去这一段；依赖下载和 Release 编译仍需时间，尚未实测新 CI 总耗时。详细合同见 [GitHub iOS 构建检查](docs/verification-and-delivery.md#64-github-ios-构建检查)。
- 现有 Python 回归：`python3 -m unittest discover -s server -p 'test_*.py'` 和 `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`。

## 规范与运维

用户明确要求发布时，多任务发布采用 canonical 全局 `AGENTS.md` 的合批规则；本项目发布目标、验证与共享凭证见 [多任务发布协调](docs/verification-and-delivery.md#65-多任务发布协调)。已复用本机现有 ReleaseCoordinator 0.1.3，客户端与 SCF 分别配置作用域；配置、CLI、登录启动和真实验收限制见 [协调器接入](docs/release-coordinator-integration.md)。

| 文档 | 用途 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 开发规则、接入完成标准、Widget 与交付验证要求 |
| [数据接入与分类规范](docs/data-ingestion-contract.md) | 各馆 crawler、分类、限流预算与数据交付合同 |
| [主 App 规范](docs/app-behavior-contract.md) | 页面、设置、详情、收藏和图片行为 |
| [前后端架构](docs/frontend-backend-separation-design.md) | API、SQLite、鉴权、数据准备和发布流程 |
| [动态 metadata 契约](docs/client-dynamic-museum-metadata-refactor.md) | metadata 字段、客户端模型与通用配置 |
| [腾讯云 SCF 运维](server/tencent_scf/README.md) | 打包、配置、签名 probe 和发布验收 |
| [验证与交付](docs/verification-and-delivery.md) | 模拟器、真机、Widget 截图与日志闭环 |
| [历史 Ad Hoc / OTA](docs/ios-adhoc-ota.md) | 已有 OTA 版本、签名与真机验收记录；后续不再发布 OTA |
| [每晚安装到真机](docs/ios-nightly-installer.md) | macOS 状态栏安装程序、签名续期和诊断 |

当前展品流缓存只在 App 进程内恢复；重启恢复页面缓存仍待实现。生产 App Attest 校验尚未完成，现有过渡鉴权为 simple HMAC。代码已实现、线上已发布、桌面已验收须分别核实。
