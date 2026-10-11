# MuseumMuse（博物女神）

MuseumMuse 是一个最低支持 iOS 18 的 SwiftUI App，提供博物馆展品流、详情、收藏和三种尺寸的 Widget。

正式范围为中国国家博物馆、上海博物馆、大都会艺术博物馆、东京国立博物馆、奈良国立博物馆和吉美国立亚洲艺术博物馆。客户端入口、类别和数据源由后端 metadata 下发。

展品数据路径为离线 Python crawler → SQLite → Python API / 腾讯云 SCF → App 与 Widget；图片由客户端按源站 URL 异步下载。

## 开发入口

- 用 Xcode 打开 `DailyMuseum.xcodeproj`，主 App scheme 为 `DailyMuseum`，测试 scheme 为 `DailyMuseumTests`；默认验证模拟器为 `iPhone 17 Pro`，单元测试关闭 parallel testing。
- `Project.yml` 是 XcodeGen 工程配置；鉴权值通过未提交的 `Config/Secrets.local.xcconfig` 注入，变量名为 `MUSEUMMUSE_SIMPLE_AUTH_SECRET`。
- 本地 Python 环境安装 `server/requirements.txt` 后，按 [后端本地启动示例](docs/frontend-backend-separation-design.md#4-总体架构) 生成离线样本并启动 API。样本只用于功能验证，全量库需另行准备。
- GitHub Actions `iOS Build` 在 push、PR 和手动触发时检查唯一的 10 组小组件版本的 App、Widget 和模拟器测试目标编译并打包一份未签名 IPA；主分支通过后自动发布到 [GitHub Releases](https://github.com/zh0ngtian/DailyMusuem/releases)。本地入口为 `bash scripts/check_ios_build.sh`，无需签名；本地默认使用占位鉴权值。细节见 [GitHub iOS 构建检查](docs/verification-and-delivery.md#64-github-ios-构建检查)。
- 现有 Python 回归：`python3 -m unittest discover -s server -p 'test_*.py'` 和 `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`。

## 规范与运维

| 文档 | 用途 |
| --- | --- |
| [AGENTS.md](AGENTS.md) | 开发规则、接入完成标准、Widget 与交付验证要求 |
| [数据接入与分类规范](docs/data-ingestion-contract.md) | 各馆 crawler、分类、限流预算与数据交付合同 |
| [主 App 规范](docs/app-behavior-contract.md) | 页面、设置、详情、收藏和图片行为 |
| [前后端架构](docs/frontend-backend-separation-design.md) | API、SQLite、鉴权、数据准备和发布流程 |
| [动态 metadata 契约](docs/client-dynamic-museum-metadata-refactor.md) | metadata 字段、客户端模型与通用配置 |
| [腾讯云 SCF 运维](server/tencent_scf/README.md) | 打包、配置、签名 probe 和发布验收 |
| [验证与交付](docs/verification-and-delivery.md) | 模拟器、真机、Widget 截图与日志闭环 |
| [Ad Hoc / OTA 发布](docs/ios-adhoc-ota.md) | 私有 OTA 签名、发布和 GitHub 构建检查 |
| [每晚安装到真机](docs/ios-nightly-installer.md) | macOS 状态栏安装程序、签名续期和诊断 |

当前展品流缓存只在 App 进程内恢复；重启恢复页面缓存仍待实现。生产 App Attest 校验尚未完成，现有过渡鉴权为 simple HMAC。代码已实现、线上已发布、桌面已验收须分别核实。
