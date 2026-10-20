# MuseumMuse 发布协调器接入

操作合同已读取 [release-coordinator README](https://github.com/zh0ngtian/release-coordinator/blob/main/README.md) 和 [USAGE](https://github.com/zh0ngtian/release-coordinator/blob/main/USAGE.md)。通用合批与恢复原则维护在使用者的 canonical 全局 `AGENTS.md`；本文只描述本项目配置、适配器和验收。

本接入仅用于用户明确要求的发布。默认代码交付按 [默认验证策略](verification-and-delivery.md#61-默认验证策略) 验证、合入 `main`，按主分支是否推进决定合入后回归，再提交和推送；不登记发布任务、不提交 `ready`，不要求发布 receipt。以下 CLI 与适配器合同均以已有明确发布请求为前提。

## 本机部署与启动

2026-10-13 已复用本机现有 `releasectl` 0.1.3：`~/.local/bin/releasectl`，状态目录 `~/Library/Application Support/ReleaseCoordinator/`，同一个 `service.sock` 与 SQLite 注册表。未安装第二份服务或数据库。`installation.json` 的 `startup=login`，`launchctl print gui/501/local.release-coordinator` 确认现有 LaunchAgent 正在运行，带 `RunAtLoad` / `KeepAlive`；health 返回同一运行进程。

这是用户登录启动，**不是登录前的系统开机启动**。本轮没有迁移为 LaunchDaemon。若需要真正开机启动，按上游 README 的 `install.py --system --user zhongtian --python <现有绝对Python路径>` 在系统终端完成管理员认证，然后重新检查 `installation.json` 和 `launchctl print system/local.release-coordinator`；只采用一个启动模式，保留现有状态与历史 runtime。启动成功不代表登录前 GitHub、签名钥匙串或腾讯云凭证可用，项目 `preflight` 会先检查现有 GitHub认证。

常用只读命令：

```sh
"$HOME/.local/bin/releasectl" health
launchctl print "gui/$(id -u)/local.release-coordinator"
"$HOME/.local/bin/releasectl" status --project museummuse-ios-production
"$HOME/.local/bin/releasectl" status --project museummuse-scf-production
```

发布主机为 `Yao-Mac-mini.local`。多机只通过 `ssh zhongtian@Yao-Mac-mini.local` 在该主机执行以上 CLI，并将验证文件传到该主机，开发 SHA 先 push 同一远端。不要在开发机器各建队列、复制数据库到共享盘或另外部署协调器。现有 SSH 监听可达，主机公钥已与本机 sshd 公开公钥核对；本轮非交互 SSH 登录返回 `Permission denied`，账户授权与跨机器实际使用尚未验收，需用户在系统终端设置现有 SSH 登录权限。不创建新的签名身份或自动关闭 SSH 主机校验。

## 项目配置和作用域

仓库保持 `https://github.com/zh0ngtian/DailyMusuem.git`，正式分支 `main`。

| 配置 | 目标与环境 | 私有配置位置 | 适配阶段 |
| --- | --- | --- | --- |
| `museummuse-ios-production` | `tech.zh0ngtian.MuseumMuse` / `production`；主 App + Widget、GitHub 未签名 IPA、既有私有 Ad Hoc OTA | `~/Library/Application Support/ReleaseCoordinator/projects/museummuse-ios-production.json` | `scripts/museum_release_adapter.py`：prepare、promote、build、github、device、sign、ota、verify |
| `museummuse-scf-production` | `museummuse-api` / `production`；腾讯云广州 SCF / COS | `~/Library/Application Support/ReleaseCoordinator/projects/museummuse-scf-production.json` | `scripts/museum_scf_release_adapter.py`：prepare、promote、package、deploy、verify |

两配置已登记同一服务，scope 分别为 `a1252c8bffd4c2d0c5198fc924fda6198c32c160a3397cd877531bd06f252a51` 和 `67d175829b8ba6280c636deaabf082d35d15f31ea10c26cc4592f4b1507ec39a`。不设共同 `lock_scope`，不因复用主机或只读证书而把不同发布目标串行。两作用域只在实际写同一远端 main 的 promote 阶段，使用共享 `museum-main-locks/<remote哈希>` 短文件锁，并仅允许 fast-forward；不能改变已冻结提交。若远端 main 分叉，保留失败批次，通过明确关联修复解决。

客户端继续使用项目原有 Xcode/scheme、10 组静态 Widget、现有 P12/profile、固定升级身份、共享组和 `IOSAdHocOTA/museummuse/release.local.json` 渠道。私有设备构建读取原 `Config/Secrets.local.xcconfig`，签名配置只在批次私有目录派生版本及冻结目标 entitlements 路径，不改原材料或身份。后端继续用现有 Python、只读 SQLite、`build_package.sh`、版本化 COS `deployments/` key 和 `UpdateFunctionCode`；不启用旧 Cloudflare。Python验证环境位于项目忽略目录 `build/release-coordinator-venv`，安装的只是仓库现有 `server/requirements.txt`。

## 登记、验证和交付

仅在用户明确要求发布后，在发布主机执行；任务 ID 必须明确区分客户端/后端子任务：

```sh
release_cli="$HOME/.local/bin/releasectl"
"$release_cli" register --project museummuse-ios-production --task TASK_ID
"$release_cli" heartbeat --task TASK_ID --state active
# 每分钟更新；收尾验证时用 closing，受阻时用 blocked。
"$release_cli" heartbeat --task TASK_ID --state closing
# 在独立分支/worktree 完成本地验证，再 push 固定SHA。
git push origin HEAD
"$release_cli" ready --task TASK_ID --sha "$(git rev-parse HEAD)" --validation /absolute/path/to/validation.json
"$release_cli" wait --task TASK_ID --timeout 45
"$release_cli" status --task TASK_ID
"$release_cli" batch --id BATCH_ID
```

后端任务换用 `museummuse-scf-production`。`validation.json` 必须保存开发起点的完整 `baseSha`（该 SHA 是任务 SHA 的祖先），用 `baseSha..task.sha` 确定改动范围，不能用可能已经推进的 main 判断。`checks` 中客户端配置要求 `release-adapter`、`release-batch`、`coordinator-acceptance`、`diff-check`；后端还要求 `backend-local`。每项有真实 `name`、`status=passed` 与 `evidence`，只在命令或验收实际成功后登记。客户端功能批次还须提供 `client-local`，涉及 Widget 的改动提供 `widget-desktop`，证据必须满足 [验证与交付 6.1–6.3](verification-and-delivery.md#61-默认验证策略)，不能用 provider success 代替桌面和系统日志。

本项目新增机制测试入口：

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_*release*.py'
python3 -B -m unittest discover -s scripts/tests -p 'test_scf_archive_verification.py'
# 后端与包输入验证使用配置中现有Python验证环境。
build/release-coordinator-venv/bin/python -B -m unittest discover -s server -p 'test_*.py'
git diff --check
```

上面测试只证明机制和服务端代码。客户端功能改动仍做原有模拟器/必要真机验收；后端正式输入可从现役SCF下载包按云端checksum恢复原SQLite/manifest，保留恢复证明和原代码包；仍须所有 crawler target 的 `completion=complete`、SQLite完整性、本地 simple-auth API 和对应服务端检查，不用样本或预算 smoke run代替全量。`ready` 是自动发布授权；队列、冻结、恢复请求都不算交付。最终读取 `status --task` 对应成功 batch 的 `data.receipt`（`recovered` 时核对 `recovered_by`），确认自己的任务 SHA/实际改动在 frozen SHA 中、所有必要阶段已验证。共同凭证也保存在状态目录 `receipts/<batchId>.json`；参与任务不分别签名或发包。

失败恢复的具体 CLI 是 `register --project <项目ID> --task <修复ID> --repairs-batch <最新失败叶节点ID>`，再 push 修复SHA并 ready。不要对 failed 调用 resume、编辑冻结工作树或移动标签；正确恢复状态按 canonical 全局规则判断。诊断、旧批次工作树、历史产物和 receipt 保留。

## 适配器验收合同

`prepare` 在批次私有目录以原子保留文件登记一次版本/数据输入，进程中断重试沿用同一保留。客户端功能批次统一递增 patch 和 Build，同步工程、Project.yml 与 App/Widget Info.plist；工具批次保留版本，不编译或发布客户端。整合后重跑对应机制检查，客户端还构建默认模拟器并要求任务功能/Widget验收证据。后端原子复制与校验全量 SQLite/manifest，继续使用 manifest dataVersion，不递增 App版本。

冻结 manifest `.release-batch.json` 不包含其自身SHA，发布校验与适配器从精确引入该文件的 Git提交获得最终SHA。日常 `iOS Build` 允许普通分支（含 `main`）提交不带新的冻结清单；正式发布仍须全历史 checkout 核对冻结来源、任务祖先、版本和已通过检查。主分支客户端检查与标签发布分别使用稳定 `museummuse-production-build` / `museummuse-production-release` concurrency，`cancel-in-progress: false`、`queue: max`；开发/PR 用另一组。保留客户端paths，纯工具/纯后端不会因manifest改动触发 iOS Build。

每阶段先读取真实状态再执行缺失动作；progress保存 CI run ID/attempt 或部署RequestId。GitHub SHA/run/三附件元数据与校验和绑定冻结批次，已有附件一致就复用，缺失才补，不同则保留并失败。私有设备构建隔离批次目录，用编译输入、完成日志及真实两目标核对来源；已完工但响应丢失时补凭证，已验签IPA不再签。最终签名包两目标保存 `MuseumReleaseSourceCommit` / `MuseumReleaseBatchID`，发布器独立验签并把包内已核对字段写入 OTA receipt，保留原末端锁和 staged/current HTTPS完整回验。已暂存版本只验收并激活，不重新发包。

后端包内 `data/release-marker.json` 保存冻结SHA、批次、SQLite/manifest校验和与dataVersion，`/health` 可选返回同一 `releaseMarker`，旧部署无文件时原字段不变。check从腾讯云下载实际代码包，用GetFunctionAddress的CodeSha256核对下载ZIP自身，再与已验证上传包比较每个文件的路径、内容SHA、大小和权限；不要求两个ZIP容器的压缩字节完全相同。共同凭证分别记录uploadedZipSha256、deployedZipSha256、codeContentsSha256与文件数；marker、数据校验和及Active/health/runtime权限仍须一致，任一文件新增、缺失、改内容或改权限均拒绝。COS既有对象不可覆盖且需完整读取核对。未知更新响应只等来源收敛，不重复UpdateFunctionCode。最终 `probe_backend_release.py` 验证原六馆metadata/列表/详情、Widget候选、无签名拒绝和同一headers二次nonce401。

## 2026-10-13 实际验收与限制

- 机制验收：90项相关适配器、冻结CI、发布幂等和隔离协调测试通过；包括双scope并发、90/180秒截止、冻结后新任务、实际SIGKILL后的租约接管、响应丢失、单渠道失败、最新失败叶节点修复及同一 recovered receipt。另58项server、7项profile和4项原Widget签名边界测试通过。外部渠道副作用采用可控替身，不能据此宣称真实新版本已发布。
- 现役客户端真实只读验收：`1.1.3 (9)`，主App/Widget独立验签、版本目录与固定入口HTTPS完整下载/校验和通过。GitHub历史 `build-b2ccbcddc4947bb62f7859e783b4f6a05a84928c` 的IPA/checksum真实核对通过；该历史Release缺metadata，显式记作历史基线，不能当作此次冻结提交的产物。新客户端功能批次仍必须满足三附件/双CI的完整合同。
- SCF新包真实部署已通过：成功子批次 `3324cfcc-1e18-4f93-82de-bc370fa98529`，冻结来源 `d00bf2004fae60c5c9a0e83934a05f43ebef62f6`，更新RequestId `13b15e29-b795-434a-85d7-5028ac2e5e23`。函数Active，云端ZIP自身checksum、全部673文件内容/权限及原runtime/角色合同核对通过；六馆metadata/列表/详情、health/dataVersion/marker、无签名拒绝与同headers nonce401通过，原默认Widget候选probe也实测HTTP200。输入hash与 `dataVersion=2026-06-20T12:07:22Z` 均未改变。
- 认证及输入阻挡已解除：用户在系统终端更新原腾讯云凭证；从现役SCF代码包恢复原SQLite/manifest，云端ZIP、132247552字节SQLite的SHA及全部七个正式crawler target completion均通过，本地真实prepare通过。数据版本不变，不重新抓源。SSH监听可达，但非交互账户授权仍未通过；真多机SSH使用未验收。
- 原SCF批次 `6869ca52-bc4e-402d-8694-667ce36ba6c7` 已冻结并实际更新函数，health已返回来源标记。因严格比较上传/下载ZIP容器hash失败，历史批次保持failed；实际核对两份包的673个文件内容、集合和权限一致。登记 `museummuse-scf-code-zip-repair-20261013 --repairs-batch` 关联修复，只修复该最新失败叶节点，用新版本化COS对象与新的冻结提交完成子批次；子批次实际complete，原任务 `museummuse-scf-marker-20261013` 已recovered并引用成功子批次的同一receipt，已逐项核对，不原地恢复或补造成功。
- 本轮不涉及客户端功能，不递增App版本、不触发客户端构建、标签Release或OTA发包，也不重复安装协调器。服务状态、当前基线验收和测试日志保存在项目 `build/verification/release-coordinator-20261013/`；本次工具批次的最终提交与共同receipt以服务实际结果为准。

2026-10-13 容器来源修复回归：原90项机制回归及新增5项SCF ZIP来源测试通过；正例允许压缩/顺序变化，反例拒绝代码或输入变化、文件增删、执行权限变化、重复/不安全路径和符号链接。原failed批次记录不变，新的关联子批次沿用原数据版本并使用新的不可变COS对象。

SCF部署共同凭证位于现有状态目录 `receipts/3324cfcc-1e18-4f93-82de-bc370fa98529.json`。上传ZIP SHA-256 `8591001341baf3d7f2cebe4d561684dab8b8a30cf7331aa8c9fc34ee0e540580`，云端下载ZIP SHA-256 `34de5d57ebf253d4782142a1a49c2d7bb10f72571bd933b25df0658e26a94a53`，文件内容/权限指纹 `d961d99d3a37b8f59abc0156c93857206c8892ab7df090efc587cbcb39ef6b38`；原failed父批次及对象保持不变。后续验证/文档收尾按tooling处理，核对线上来源仍为该成功部署，不重新发包。
