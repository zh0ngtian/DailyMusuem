# MuseumMuse 数据接入与分类规范

本文件承接 [AGENTS.md](../AGENTS.md) 第 3 章；涉及后端、crawler、metadata 或分类时必须阅读相关小节。源站请求规则仅适用于离线 crawler，客户端通过后端读取展品。

## 3. 数据接入与分类规范

### 3.1 数据接入

- 当前正式展品数据路径为 `离线爬虫 + 腾讯云 SCF 代码包内只读 SQLite + iOS/Widget 后端客户端`。原 Cloudflare Worker + D1 已于 `2026-07-25` 删除，不再提供回滚链路。
- 主 App 二级页、详情页和 Widget 默认不再直接请求各馆官方展品接口；各馆官方 API / 官网解析统一由 `server/crawler/museums/` 实现并作为排查依据。
- SQLite 只保存展品文字字段、分类、官网链接、图片 URL 和抓取元信息，不保存图片二进制。
- 图片仍由客户端按服务端返回的 `primaryImageURL` / `primaryImageSmallURL` 异步拉取。
- 客户端博物馆元数据由服务端 `/v1/museums/metadata` 下发，主 App 首页、分类、能力开关、Widget scope 建议项、详情页翻译语言、文本标点风格和图片策略都以该 metadata 为正式来源；客户端不再维护 `MuseumID.allCases` 作为正式博物馆列表或无 metadata fallback。
- `/v1/museums/metadata` 需要返回 `museumID`、馆名、副标题、国家、城市、地址、`textPunctuationStyle`、`icon.url` / `icon.assetName` / `icon.backgroundColor`、`capabilities`、`defaultSourceKey`、`sources`、`categories` 和 `waterfallImageFetchPolicy`。当前六馆的 `icon.assetName` 使用现有首页 logo asset 名，例如 `NmcHomepageLogo`、`MetHomepageLogo`。
- 服务端 SQLite 的 `museums` 表需要包含 `address`、`icon_url`、`icon_asset_name`、`icon_background_color`、`text_punctuation_style` 和 `supports_favorites`；`data_sources` 需要包含 `translation_source_language`、`preferred_image_url_order_json`、`image_request_headers_json`、`artwork_source_key` 和 `list_filter_json`。客户端策略放在 `museum_client_policies`，其中 `waterfall_image_qps` 只控制二级页瀑布流缩略图请求启动速率。
- 瀑布流图片限流不是全局 QPS，也不限制详情页主图、全屏预览图、首页图标或 Widget 图片。默认 `waterfall_image_qps=NULL` 表示不限流；当前只有中国国家博物馆配置 `waterfall_image_qps=1`。
- 页面设置统一存入 App Group `feed.preferences.v2` JSON；不要恢复 `feed.source.*`、`feed.category.*`、`naraMuseumDataSource`、`metShowsOnlyOnViewArtworks` 或其它按馆专用设置。
- 二级页“页面设置”只在 `sources.count > 1` 时显示数据源选择器；当前大都会显示 `全部展品` / `在展展品`，奈良显示 `馆方数据源` / `ColBase`，其它单源博物馆不显示数据源选择。
- Widget 配置中的展示范围使用动态 AppIntents entity，从 App Group 中最近一次成功的 metadata 快照读取 `capabilities.supportsWidgetContent` 的博物馆；没有 metadata 快照时只能展示 `所有博物馆` 虚拟项。
- 旧 Swift 直连抓源 API 文件已从工程删除；不要重新引入 `Shared/MetMuseum`、`Shared/JapanSearch`、`Shared/NaraMuseum`、`Shared/NationalMuseumChina`、`Shared/ShanghaiMuseum`、`Shared/GuimetMuseum` 下的客户端官方源请求。源站规则参考和解析器回归应放在 `server/crawler/museums/` 及其测试中。
- 当前 `server.crawler.main crawl` 成功后会按 SQLite 当前状态写出 manifest；默认库 `museummuse.sqlite` 使用同目录 `manifest.json`，非默认库使用同目录 `{db_stem}.manifest.json`，避免多个 SQLite 在同一目录时互相覆盖 manifest。`--museum all` 只允许显式传入 `--allow-network` 后顺序执行全部正式源，避免误触发真实源站请求。
- 本地后端 / 客户端功能测试可先运行 `python -m server.crawler.seed_sample_data --db server/data/museummuse.sqlite` 生成最小样本 SQLite；该脚本复用各馆 crawler parser / store 函数，不触发任何源站网络请求，不能当作真实全量抓取完成证据。
- 真实数据交付仍以 `python -m server.crawler.main crawl --museum all --db server/data/museummuse.sqlite --allow-network --max-details {明确预算}` 或 `--full --skip-existing` 生成的 SQLite、`manifest.json` 和抓取日志为准；live crawl 必须显式传入大于 `0` 的 `--max-details` 或显式传入 `--full`，避免默认命令产生无详情数据的假成功。
- `--full` 表示遍历当前数据源发现到的完整候选池，不能和 `--max-details` 同时使用；`--skip-existing` 用于长任务续跑，遇到目标库中已存在的 `(museum_id, source_key, object_id)` 时跳过详情请求，并在 crawl run manifest 中记录 `skippedExistingCount`。
- `--museum all` 可用 `--exclude-museum {crawler_id}` 跳过高风险来源；例如国博全量详情策略未确认时，应使用 `--exclude-museum nmc` 先完成其它来源全量 crawl。
- `--page-size {N}` 可用于支持分页大小的候选搜索 crawler，例如 Japan Search 和上海博物馆；它只减少候选页请求次数，不改变详情页抓取上限。用户已允许后续批量尝试 `50`，但若源站失败率升高，应回退到默认 `10`。
- `--request-interval {seconds}` 可用于支持该参数的非国博 crawler 调整请求间隔；`--concurrency {N}` 可用于支持该参数的非国博长详情 crawler 并发抓取详情。用户已允许后续非国博来源尝试 `--request-interval 0.1 --concurrency 10`（约 `10 QPS` 上限）。这两个参数禁止用于国博，国博仍必须遵守单独 API 调用预算和反爬限制。
- 本地客户端连接后端验证全量数据时，后端必须显式设置 `MUSEUMMUSE_DB_PATH=server/data/museummuse-live-all.sqlite`；`server/data/museummuse-live-full.sqlite` 是早期每源 `10` 条的小样本库，继续指向它会导致客户端看起来只能加载 `10` 条。
- 模拟器或本地服务验证客户端时，客户端可通过进程环境变量 `MUSEUMMUSE_BACKEND_BASE_URL` 覆盖 Info.plist 中的 `MuseumBackendBaseURL`；没有该环境变量时才使用 Info.plist 默认值。后续本地和腾讯云验证必须同时注入 `MUSEUMMUSE_SIMPLE_AUTH_SECRET`，确保客户端、脚本和服务端使用同一个 simple auth secret。Xcode 编译注入通过已提交的 `Config/Secrets.xcconfig` 和未提交的 `Config/Secrets.local.xcconfig` 完成，真实 secret 不得写入 git。
- 后续涉及服务端 schema、metadata、数据源、crawler 入库规则或部署包的调试，必须先使用本地 SQLite 和本地 Python API 完成验证，客户端通过 `MUSEUMMUSE_BACKEND_BASE_URL=http://127.0.0.1:8000` 指向本地服务，后端通过 `MUSEUMMUSE_AUTH_MODE=simple MUSEUMMUSE_SIMPLE_AUTH_SECRET={secret}` 启动；本地服务端测试、iOS 单元测试 / 构建和必要的模拟器交互验证通过后，才能更新腾讯云 SCF。
- 当前腾讯云正式资源位于广州地域：SCF HTTP 函数 `museummuse-api`（FunctionId `lam-fo3kkl6o`）、私有 COS bucket `museummuse-scf-artifacts-1259375612`、执行角色 `MuseumMuseSCFRole`。函数使用 Python 3.10、512 MB 内存、15 秒超时、单 worker，不配置预置并发。
- 腾讯云 SCF 部署包使用 `server/tencent_scf/build_package.sh {sqlite} {manifest} {output.zip}` 构建；脚本把 Python API、依赖、SQLite 和 manifest 一起打包，并通过 `scf_bootstrap` 在 `9000` 端口启动 Web 函数。SQLite 位于代码目录，只读查询；数据更新必须重新构建并发布完整代码包，不能在函数运行时写库。
- SCF 的 `MUSEUMMUSE_NONCE_STORE` 必须设为 `cos`。运行时使用 `MuseumMuseSCFRole` 的临时凭证，以 `x-cos-forbid-overwrite` 原子写入 `auth-nonces/{hash}`；该角色只能向此 prefix 执行 `cos:PutObject`。COS lifecycle 必须让 `auth-nonces/` 在 `1` 天后过期，并清理 `1` 天以上的未完成分片上传。
- 正式部署包存放在 COS `deployments/`；迁移基线备份存放在 `backups/cloudflare-d1/2026-07-24/`，包括 gzip SQLite、gzip SQL 和 manifest。不要删除这组基线备份；未来每次发布应使用新的版本化对象 key。
- iOS 主 App 和 Widget 的默认 `MuseumBackendBaseURL` 指向自定义 HTTPS 域名 `https://museum-api.zh0ngtian.tech`；该域名通过 DNSPod CNAME `1259375612.ap-guangzhou.tencentscf.com` 和 SCF `/*` 路由指向 `museummuse-api`。腾讯云默认函数 URL `https://1259375612-6mtzjn85y7.ap-guangzhou.tencentscf.com` 只作为域名故障排查入口，不作为客户端默认值。
- 自定义域名证书 ID 为 `ZSoYf0pa`，有效期截至 `2026-10-22 22:59:59`。到期前必须申请新证书并更新 SCF 自定义域名绑定；客户端无需改 URL。线上签名回归使用 `scripts/probe_backend_simple_auth.py`；默认只检查无签名拒绝、metadata、博物馆列表和 Widget 候选。完整验收还需显式追加展品列表 / 详情路径，并单独检查 health 和 nonce 重放，操作见 `server/tencent_scf/README.md`；不得用裸 `curl` 判断 `/v1` 业务接口可用。
- Cloudflare Worker `museummuse-api` 和 D1 `musuem_muse`（原 UUID：`9ab953e7-0af0-4c08-863a-85717e4fc941`）已于 `2026-07-25` 永久删除；旧地址 `https://museummuse-api.305301890.workers.dev` 不再可用。仓库中的 `server/worker` 仅保留为历史实现，`wrangler.jsonc` 中的原 D1 UUID 已失效，禁止直接执行部署。
- 如未来明确决定重新启用 Cloudflare，必须使用 `[@cloudflare](plugin://cloudflare@openai-curated-remote)` 插件重新创建 D1、更新 binding、从腾讯 COS 迁移基线恢复数据、配置 secrets、部署 Worker 并完成签名 probe；不能把这一过程称为直接回滚。Cloudflare R2 从未启用，现阶段备份以腾讯 COS 为准。
- 如果本地通过但腾讯云验证失败，优先排查 SCF 代码包、SQLite / manifest、环境变量、COS nonce 权限和函数 URL。不允许在客户端加旧 source key、旧字段或按馆 fallback 来掩盖线上数据未同步。
- 如果未来重新创建 D1，导入 SQL 需要使用 `sqlite3 {db} ".dump --newlines"` 生成，并移除 `BEGIN TRANSACTION` / `COMMIT` 等 D1 不接受的事务包装，不能使用会输出 `unistr(...)` 的默认 `.dump`。
- 上海博物馆和 Met 这类长详情任务会在 live crawl 中逐条提交，并每 `100` 个候选输出一次进度；如果任务中断，后续应使用 `--skip-existing` 续跑，不能直接认为已完成。
- 全量交付前必须运行 `python -m server.crawler.main status --db {SQLite}`；只有所有正式 crawler target 都显示 `completion=complete`，才能视为“全量爬取完成”。样本数据、`--max-details` smoke run 或只有部分来源成功不能当作全量完成证据。
- 服务端 `/v1` 业务接口默认需要鉴权；`MUSEUMMUSE_AUTH_MODE=disabled` 原则上只允许 loopback 本地开发跳过鉴权。当前 App Attest 生产链路未完成前，腾讯云 SCF 和本地 Python API 支持临时轻量 `AUTH_MODE=simple`：客户端用同一 secret 对 canonical request hash 做 HMAC-SHA256，业务请求必须携带 `Authorization: Bearer <signature>`、`X-MuseumMuse-Timestamp`、`X-MuseumMuse-Nonce`、`X-MuseumMuse-Request-Hash` 和 `X-MuseumMuse-App-Version`，服务端只接受时间偏移 `10` 秒内的请求并做短期 nonce 去重。
- `simple` 模式只是防止裸接口和简单抓包复用的过渡方案，不等同于生产 App Attest；secret 不能写死在源码，SCF 侧必须通过环境变量配置，客户端通过 `MuseumBackendSimpleAuthSecret` Info.plist 构建配置或 `MUSEUMMUSE_SIMPLE_AUTH_SECRET` 环境变量注入。腾讯云 SCF 使用 COS 原子对象写入实现跨实例 nonce 去重，该运行态 nonce 不属于博物馆离线数据迁移表。
- Simulator 本地调试可使用 `MUSEUMMUSE_AUTH_MODE=debug` 和 `MUSEUMMUSE_DEBUG_AUTH_SECRET` 启用 debug auth；客户端仍需通过 challenge / register / session 获取短期 token，并在业务请求中携带 timestamp、nonce、request hash 和 debug assertion。
- 未配置正式 App Attest 校验时，非 `simple` / 本地 debug / disabled 模式不能当作生产可用鉴权；服务端应返回 `501 app_attest_not_configured`。

#### 3.1.1 大都会艺术博物馆

- 大都会当前主数据源是 `The Met Collection API`：
  - 搜索展品 ID：
    - `https://collectionapi.metmuseum.org/public/collection/v1/search`
  - 拉取展品详情：
    - `https://collectionapi.metmuseum.org/public/collection/v1/objects/{objectID}`
- 大都会当前搜索请求约束：
  - 搜索继续使用 `q`、`hasImages` 和可选的 `departmentId`
  - 当前服务端 metadata 把大都会配置为两个客户端可选数据源：默认 `met_all`（全部展品）和 `met_on_view`（在展展品）
  - `met_on_view` 不单独入库；它在 `data_sources.artwork_source_key=met_all` 的基础上通过 `list_filter_json={"only_on_view":true}` 复用 `met_all` 展品并过滤 `artworks.is_on_view=1`
  - 大都会二级页页面设置和 Widget 与奈良馆共用同一套数据源选择逻辑；客户端只发送 `source=met_on_view`，不再发送 `only_on_view` query 参数
  - Met object JSON 中的 `isOnView` 必须入库到 `artworks.is_on_view`，否则 `met_on_view` 会没有候选
- 大都会详情页中的“展品介绍/官网概述”不完全依赖公开 API：
  - 当公开 API 未返回可用介绍字段时，需要继续访问官网页面：
    - 先尝试中文页面：`https://www.metmuseum.org/zh/art/collection/search/{objectID}`
    - 中文页面没有可用概述时，再回退英文页面：`https://www.metmuseum.org/art/collection/search/{objectID}`
  - 当前会从官网页面的 object overview 区块中提取描述内容，作为详情页补充信息来源。
  - object overview 的 CSS module hash 可能变化，解析规则需要匹配稳定的 overview / label 语义片段，不能依赖某一个完整 class 名。
  - 部分官网页面会把介绍放在标题区的顶部简介段落中，位置在标题、年代、展出状态之后，`Artwork Details` 之前；当 object overview 不存在时，需要把该顶部简介作为兜底来源。
  - Met 官网页面可能返回 Vercel Security Checkpoint；当前离线 crawler 没有浏览器渲染兜底，抓取失败时保留空介绍并记录后续补抓。主 App 只读取后端详情，不恢复 WebKit 抓源链路。
- 后续如果修改大都会详情逻辑：
  - 不能假设公开 API 已包含完整介绍文案。
  - 不能删除官网页面抓取这条兜底链路，除非确认官方 API 已能稳定返回同等信息。
  - 只提取 object overview、顶部简介或 meta description；不把 `Provenance / References / Catalogue Entry` 等其他官网区块误当作展品介绍。
- 离线全量 crawler 需要处理 Met 搜索候选池中少量详情 API 不可取的 objectID：
  - 若 object detail API 稳定返回 `404` 或在低速重试后长期无响应，不能伪造展品入库。
  - 这类候选应记录到 `crawl_errors`，并在 run manifest 中计入 `permanentFailureCount`，作为“已遍历但源站无详情”的终端状态。
  - `status` 判定 Met 全量完成时允许 `artworkCount + permanentFailureCount == candidateCount`。
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum met --sample-detail-json` 验证 The Met object JSON 解析和 SQLite 入库，并支持通过 `--sample-web-html` 验证官网 overview / 顶部简介 / meta description 兜底解析。真实网络抓取会在 object API 后按中文页、英文页顺序尝试官网描述；服务端 crawler 没有 WebKit 渲染兜底，若遇到 Vercel Security Checkpoint 只能保留空介绍并记录后续补抓。
- Met live crawl 支持通过 `--category-id {内部分类ID}` 把项目内部分类映射到官方 `departmentId` 后搜索，例如 `africa-oceania-americas -> 5`、`european-paintings -> 11`；后续新增或调整 Met 分类时必须同步维护这层映射。

#### 3.1.2 东京国立博物馆

- 东京国立博物馆当前主数据源是 `Japan Search Web API`：
  - 搜索 itemIDs：
    - `https://jpsearch.go.jp/api/item/search/jps-cross`
  - 拉取单件详情：
    - `https://jpsearch.go.jp/api/item/{itemID}`
- 东京馆搜索当前使用的核心筛选条件包括：
  - `f-db=cobas`
  - `q-contributor=東京国立博物館`
  - `f-contents=image`
- 东京馆搜索存在已知接口行为约束：
  - 离线 crawler 默认 `size=10`，可按 3.1 的受控参数策略尝试 `--page-size 50`；客户端不再直接请求 Japan Search。
  - 当 contributor 查询返回空结果时，需要允许退回 `cobas` 全库搜索并在本地过滤东京国立博物馆数据。
- 东京馆当前不依赖官网页面抓取详情：
  - 展品列表和详情信息都以 `Japan Search Web API` 返回为准。
  - 后续如增加新的网页抓取方案，必须先确认不会破坏现有分页、缓存和字段映射逻辑。
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum tnm --sample-detail-json` 验证 Japan Search item JSON 解析和 SQLite 入库；真实网络抓取必须显式传入 `--allow-network`，并保留默认 `size=10`、受控 `--page-size` 调整、contributor 空结果 fallback 和本地过滤规则。

#### 3.1.3 奈良国立博物馆

- 奈良国立博物馆当前支持两套数据源：
  - 默认数据源：馆方中文藏品数据库 `https://www.narahaku.go.jp/chinese/collection/`
  - 可选数据源：`Japan Search Web API` / `ColBase`
- 奈良馆数据源选择通过通用二级页“页面设置”source selector 展示：
  - 默认值为 `馆方数据源`
  - 可切换为 `ColBase`
  - 数据源选择通过 App Group `UserDefaults` 持久化，主 App 列表、详情页和 Widget 刷新读取同一设置
  - 数据源切换不影响已经收藏的文物；收藏夹中的 `narahaku-*` 馆方源展品和 ColBase 展品都必须继续可见、可打开、可取消收藏
- 奈良馆方源搜索页：
  - `https://www.narahaku.go.jp/chinese/collection/?bumon={门类}&img=1&action=image_search`
  - 用于解析候选池中的 `data-href`、缩略图、标题和摘要
  - 候选需要合并去重
- 奈良馆方源详情页：
  - `https://www.narahaku.go.jp/chinese/collection/{id}.html`
  - 用于解析标题、材质、尺寸、国家 / 年代、门类、说明区、主图 / 缩略图和官网链接
  - 若详情页没有艺术家或介绍文本，字段保持空值，不允许伪造内容
  - 解析说明区时需要按 `<p>` 和 `<br>` 拆分文本段，删除包含 `翻译` 的文本段，并删除每段最后一个 `。` 后面的内容，避免把翻译署名或 `语音导览` 等尾部说明展示为展品介绍
  - 部分详情页会缺失材质行，例如 `1317-331.html` 的说明区只有空行、尺寸、国家 / 年代；解析时必须先识别尺寸行，不能按固定行号把年代解析到尺寸里
  - `http://www.narahaku.go.jp/...` 和协议相对图片 URL 需要规范化为 `https://...`
- 奈良馆方源展品 `objectID` 必须使用 `narahaku-{原始ID}`：
  - 示例：`narahaku-1032-0`
  - 用于区分收藏 key、feed cache key、Widget candidate key 和深链接
  - 详情页、列表和 Widget 均通过后端 `source` + `objectID` 查询，不允许客户端按 `narahaku-` 前缀重新分发到馆方 / ColBase 抓源逻辑
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum nnm-official --sample-detail-html --sample-object-id {原始ID}` 验证奈良馆方详情 HTML 解析和 SQLite 入库；搜索页解析、`narahaku-` objectID、图片 URL 规范化、说明文本清洗、缺失材质行处理和官方门类 membership 都必须继续由服务端 crawler 维护。
- 奈良 ColBase 源继续复用 `Japan Search Web API`：
  - 搜索 itemIDs：
    - `https://jpsearch.go.jp/api/item/search/jps-cross`
  - 拉取单件详情：
    - `https://jpsearch.go.jp/api/item/{itemID}`
- 奈良 ColBase 源搜索当前使用的核心筛选条件包括：
  - `f-db=cobas`
  - `q-contributor=Nara National Museum`
  - `f-contents=image`
- 奈良 ColBase 源搜索 fallback 规则：
  - 当 contributor 查询返回空结果时，需要允许退回 `cobas` 全库搜索并在本地过滤奈良国立博物馆数据。
  - 本地过滤需要接受 contributor `奈良国立博物館`、`Nara National Museum`，以及 provider `narahaku`。
- 奈良 ColBase 源搜索存在与东京馆相同的分页约束：
  - 离线 crawler 默认 `size=10`，可按 3.1 的受控参数策略尝试 `--page-size 50`；客户端不再直接请求 Japan Search。
  - 主 App 从后端每批加载 `10` 条，Widget 从后端每轮推进 `1` 个候选。
- ColBase `linkUrl` 作为 ColBase 源官网原始链接，用于详情页官网入口、AI 按钮和 Widget 深链接来源。
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum nnm-colbase --sample-detail-json` 验证奈良 ColBase item JSON 解析和 SQLite 入库；真实网络抓取必须显式传入 `--allow-network`，并继续保留与东京馆一致的小页、fallback 和 provider / contributor 本地过滤规则。

#### 3.1.4 中国国家博物馆

- 中国国家博物馆当前接入接口：
  - `https://appapi.chnmuseum.cn/api/exhibit_list?cate_id={类别ID}&limit={一次拉取的数量}&p=i&son_cate_id=0`
  - `https://appapi.chnmuseum.cn/api/exhibit/share_link?p=i&exhibit_id={id}`
- 当前离线爬虫对列表接口的用途：
  - 尽量少调用 API 获取尽量多的候选展品 ID
  - 优先使用 `cate_id=0` 全部分类和最大已验证 `limit` 做大页分页
  - 不应为了每个分类重复调用列表 API；分类关系优先从详情 HTML 或已抓字段回填
  - 列表 item 中已经返回的标题、年代、分类、尺寸、图片等摘要字段需要随候选一起保留；详情 HTML 缺少 `brief` 段落时，应优先用这些已获取摘要字段回填，不能为了补字段再额外打分类列表 API
- 当前离线爬虫对详情页 HTML 的用途：
  - 拉取展品详情页 HTML
  - 从 HTML 中解析标题、年代、分类、尺寸、图片、展品介绍
- 当前中国国家博物馆详情页字段提取规则：
  - 标题来自详情页 `brief` 区块中的 `h1`
  - 年代、分类、尺寸来自 `brief` 区块中的段落顺序
  - 展品介绍来自 `detail` 区块
  - 图片使用详情页中的首张可用 `img`
  - 当前数据源未稳定提供艺术家、材质、文化等字段时，允许保持空值，不允许伪造内容
- 该接口的反爬与调用量限制要求：
  - 中国国家博物馆 API 对同一 IP 请求次数非常敏感，请求 API 太多可能导致 IP 被封禁；不能只依赖 `1 QPS` 作为保护。
  - 离线爬虫必须记录并控制 API 总调用量，列表 API 优先大页抓取，避免按分类或按小页重复拉取。
  - 爬虫侧默认使用 `MUSEUMMUSE_NMC_LIST_LIMIT=100` 和 `MUSEUMMUSE_NMC_MAX_LIST_API_CALLS=20` 作为国博列表 API 预算上限；提高这些值前必须先确认源站风险。
  - 国博 live crawl 带 `--max-details` 时，候选池发现只需要拿到足够支撑目标成功条数的候选后就停止，不能为了少量详情先消耗完整列表预算。
  - 国博 `--full` 不允许默认通过 `share_link` API 全量打详情；除非已经确认风险并显式设置 `MUSEUMMUSE_NMC_DETAIL_FETCH_MODE=share_link_api` 和 `MUSEUMMUSE_NMC_ALLOW_FULL_SHARE_LINK_API=1`，否则应先补网页详情抓取路径或继续使用受控预算模式。
  - `server.crawler.main crawl --museum nmc` 支持通过 `--sample-detail-html` 离线验证详情解析和 SQLite 入库；真实网络抓取必须显式传入 `--allow-network`。
  - 国博详情 live 抓取默认不启用 `share_link` API path；只有显式设置 `MUSEUMMUSE_NMC_DETAIL_FETCH_MODE=share_link_api` 才允许走该路径，且会继续消耗 API 预算。
  - 网页 HTML 抓取相对 API 更安全，详情字段应优先按网页抓取路径解析；如必须访问 `share_link` 这类 API path 返回的 HTML，也要和列表 API 共用预算、串行限流并记录调用量。
  - 不允许对国博 API 并发突发请求，避免 IP 被封禁。
  - 后续如修改中国国家博物馆相关加载逻辑，必须保留或强化爬虫侧限流、API 调用预算和大页策略，不能绕过。

#### 3.1.5 上海博物馆

- 上海博物馆当前接入接口：
  - 展品搜索：
    - `https://www.shanghaimuseum.net/mu/frontend/pg/collection/search-antique`
  - 展品详情页：
    - `https://www.shanghaimuseum.net/mu/frontend/pg/article/id/{code}`
  - 展品图片页：
    - `https://www.shanghaimuseum.net/mu/frontend/pg/article/aid/{code}`
- 当前离线 crawler 对搜索接口的用途：
  - 分页拉取展品编码 `code`
  - 获取首屏所需的摘要信息和缩略图
  - 按 `subtype` 构建二级页和 widget 的候选池
- 当前离线 crawler 对详情页和图片页的用途：
  - 从详情页解析标题、纪年、分类、尺寸、材质、作者、产地、展品介绍
  - 从图片页解析主图和小图地址
  - 详情页和图片页共同组成最终详情数据，不能只依赖搜索摘要
- 上海博物馆当前请求约束：
  - 离线搜索分页默认 `10` 条，可按 3.1 的受控策略尝试 `--page-size 50`
  - 当前离线 crawler 默认对搜索、详情、图片请求使用保守节流；用户批准后，真实全量抓取可通过 `--request-interval 0.1 --concurrency 10` 在共享 limiter 下尝试约 `10 QPS` 上限
  - 请求需要继续保留浏览器风格请求头与 `Referer`
  - 离线 crawler 对搜索、详情和图片请求的瞬时网络失败最多重试 `3` 次，每次重试仍需经过同一个共享 limiter
  - 后续如果修改上海博物馆链路，不能移除分页、小页策略、节流或请求头兜底
- 上海博物馆详情链路注意事项：
  - 搜索返回的 `catalog` 和摘要字段只可作为预览或补充，详情页仍应以文章页解析结果为准
  - 部分文章页标题前会带 `img.jwz` 等题名字形图片，标题解析必须先清理标题区内的图片、收藏链接等标签，不能要求 `title` div 的第一个节点就是纯文本
  - 图片页解析失败时，当前允许继续返回文字详情；后续修改时不能因为图片页失败而直接丢弃整条详情
  - 主 App 使用后端已入库文字和图片 URL 渲染卡片，图片异步下载；客户端不请求文章页或图片页来补字段
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum shm --sample-detail-html --sample-object-id {code}` 验证上海博物馆文章页 HTML 解析和 SQLite 入库；可选 `--sample-image-html` 补充图片页解析。真实网络抓取必须显式传入 `--allow-network`，并继续保留搜索 / 文章 / 图片请求共享 limiter、图片页失败不丢弃文字详情、搜索摘要不替代文章页详情的规则。

#### 3.1.6 吉美国立亚洲艺术博物馆

- 吉美国立亚洲艺术博物馆当前主数据源是官网中文藏品页：
  - 分类入口页：
    - `https://www.guimet.fr/zh-hans/cangpin`
  - 分类页：
    - `https://www.guimet.fr/zh-hans/collections/{collection-slug}`
  - 展品详情页：
    - `https://www.guimet.fr/zh-hans/nos-collections/{collection-slug}/{artwork-slug}`
- 当前离线 crawler 对官网分类页的用途：
  - 从 `node--type-art-work` 卡片解析展品详情页 URL、标题、卡片类别和图片
  - 分类页只作为候选池，不代替详情页字段解析
  - 分类页摘要不能代替入库详情；离线 crawler 必须进入展品详情页解析图片 URL 和展品字段
  - `objectID` 使用详情页路径中 `/zh-hans/nos-collections/` 后的相对路径，并用 `~` 替代路径分隔符，例如 `afghanistan-pakistan~bodhisattva-maitreya`
- 当前离线 crawler 对官网详情页的用途：
  - 从 `artwork-title`、`main-artwork`、`field--name-field-teaser`、`field--name-field-ref-widgets` 和 `info-table` 解析标题、年代、材质、尺寸、类别、地区 / 地点、展品介绍、图片和官网链接
  - 详情介绍只解析当前展品正文区，不允许把 `了解更多藏品` 相关卡片误抓进介绍
  - 当前官网详情页未稳定提供艺术家或国家字段时，允许保持空值，不允许伪造内容
- 吉美国立亚洲艺术博物馆当前请求约束：
  - 请求需要继续保留浏览器风格 `User-Agent`、`text/html` Accept 和中文 `Accept-Language`
  - 官网分类页候选由离线 crawler 准备；主 App 每批请求 `10` 条后端展品，Widget 每轮请求 `1` 条后端候选
  - Widget 刷新仍然必须走 `network-only`，不能复用主 App 搜索 / 详情缓存
- 后续如果修改吉美国立亚洲艺术博物馆链路：
  - 不能恢复到 POP / Joconde 作为主数据源，除非产品范围再次明确调整
  - 不能把官网分类页以外的站内推荐卡片混入当前分类候选池
  - 不能把详情页中的导航、分享、相关藏品或页脚内容误当作展品字段
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum guimet --sample-detail-html --sample-detail-url {详情页URL}` 验证吉美官网详情 HTML 解析和 SQLite 入库；真实网络抓取必须显式传入 `--allow-network`，并继续保留官网分类页候选、详情页字段解析、`~` objectID 分隔和“不混入了解更多藏品”规则。

### 3.2 分类规范

#### 3.2.1 通用规则

- 二级页面中的类别名称必须展示中文，不直接向用户展示原始分类 key。
- 客户端请求和缓存使用 metadata 的稳定 `categoryID`；源站原始请求值与中文展示映射由服务端维护。本节各馆请求参数均指离线 crawler 对源站的请求。
- `全部` 不是远端真实分类：
  - 仅作为 UI 展示态
  - 等价于当前博物馆下所有可选分类全部选中
- 如果后续新增或调整分类映射：
  - 必须同时更新展示中文名
  - 必须同时更新请求所使用的原始值
  - 不允许只改 UI 文案、不改实际筛选值

#### 3.2.2 大都会艺术博物馆分类

- 大都会艺术博物馆分类来源以官方 `/departments` 为准。
- 请求侧需要继续使用 `departmentId` 作为筛选值。
- 当前中文映射必须保持如下对应关系：
  - `1` -> `美国装饰艺术`
  - `3` -> `古代西亚艺术`
  - `4` -> `武器与盔甲`
  - `5` -> `非洲、大洋洲与美洲艺术`
  - `6` -> `亚洲艺术`
  - `7` -> `修道院分馆`
  - `8` -> `服装学院`
  - `9` -> `素描与版画`
  - `10` -> `古埃及艺术`
  - `11` -> `欧洲绘画`
  - `12` -> `欧洲雕塑与装饰艺术`
  - `13` -> `古希腊与古罗马艺术`
  - `14` -> `伊斯兰艺术`
  - `15` -> `罗伯特·雷曼收藏`
  - `16` -> `图书馆藏`
  - `17` -> `中世纪艺术`
  - `18` -> `乐器`
  - `19` -> `摄影`
  - `21` -> `现代艺术`

#### 3.2.3 东京国立博物馆分类

- 东京国立博物馆分类来源以 `Japan Search Web API` 的 `facets.type.counts` 为准。
- 请求侧需要继续使用 `f-type` 作为筛选值。
- Tokyo 馆内部需要保留 raw code，展示层必须使用下面这组中文映射：
  - `archeology` -> `考古与历史资料`
  - `paint` -> `绘画`
  - `ancdoc` -> `书迹与古文书`
  - `metal` -> `金属工艺`
  - `ceramic` -> `陶瓷`
  - `lacquer` -> `漆器`
  - `daw` -> `染织`
  - `weaponry` -> `刀剑与兵器`
  - `sculpture` -> `雕刻`
  - `arts` -> `艺术与美术`
  - `architecture` -> `建筑`
- 后续如果东京馆接口返回额外类型：
  - 不能直接把 raw code 暴露给用户
  - 必须先补中文映射后再开放到 UI

#### 3.2.4 奈良国立博物馆分类

- 奈良国立博物馆分类随当前数据源切换。
- 馆方源分类来源为奈良馆方中文藏品数据库门类：
  - 请求侧使用 `bumon`
  - UI 展示值和请求值当前均为中文门类，但实现仍需区分职责，不能把 UI 文案判断写死为数据契约
  - `雕刻`
  - `绘画`
  - `书迹`
  - `工艺`
  - `考古`
  - `中国古代青铜器`
  - `其他`
- ColBase 源分类来源以 `Japan Search Web API` 的 `facets.type.counts` 为准。
- ColBase 源请求侧需要继续使用 `f-type` 作为筛选值。
- ColBase 源内部需要保留 raw code，展示层必须使用下面这组中文映射：
  - `archeology` -> `考古与历史资料`
  - `ancdoc` -> `书迹与古文书`
  - `paint` -> `绘画`
  - `craft` -> `工艺`
  - `sculpture` -> `雕刻`
  - `ceramic` -> `陶瓷`
  - `metal` -> `金属工艺`
  - `lacquer` -> `漆器`
  - `weaponry` -> `刀剑与兵器`
  - `daw` -> `染织`
- 两套分类需要分别记忆，互不污染。
- 切换数据源时，页面设置内的草稿分类重置为该数据源的 `全部`；只有点击 `完成` 后才保存数据源、保存分类并刷新列表。
- 后续如果奈良馆任一数据源返回额外类型：
  - 不能直接把 raw code 暴露给用户
  - 必须先补中文映射后再开放到 UI

#### 3.2.5 中国国家博物馆分类

- 中国国家博物馆客户端分类只从 metadata 获取；服务端 `server/crawler/stores.py` 维护稳定分类 seed，crawler 把源站分类归入对应 membership。
- 中国国家博物馆分类来源以列表接口 `exhibit_list` 的 `cate_id` 为准。
- 源站列表请求使用 `cate_id`，默认 `0` 聚合发现候选；客户端用 metadata 的内部分类 ID 发送 `category_ids`，不得按分类重复调用国博 API。
- 中国国家博物馆当前分类 ID 与展示映射规则如下：
  - `0` -> `全部`
  - `1` -> `考古发掘品`
  - `2` -> `革命文物`
  - `3` -> `国史文物`
  - `4` -> `传世文物`
  - `22` -> `货币`
  - `24` -> `文献拓本`
  - `26` -> `艺术品`
- 中国国家博物馆还需要明确区分三套值：
  - 接口请求值：
    - 使用 `cate_id`
  - 项目内部分类标识：
    - 可使用稳定的内部 key，例如 `archaeology`、`revolutionary`、`national-history`、`heirloom`、`currency`、`rubbings`、`arts`
  - UI 展示值：
    - 必须使用中文名称
- 如果中国国家博物馆列表接口失败：
  - 当前行为应直接按接口失败处理
  - 允许展示错误日志或失败态
- 国博详情 HTML 和已获取的摘要字段可用于回填入库分类关系；后端筛选使用 `artwork_categories`，不得为了补分类额外请求源站列表。

#### 3.2.6 上海博物馆分类

- 上海博物馆当前分类来源以项目内维护的 `subtype` 列表为准。
- 请求侧需要继续使用搜索接口请求体中的 `subtype` 作为筛选值。
- 上海博物馆当前分类的特点：
  - 当前 raw value 与 UI 展示值都使用中文 subtype 名称
  - 即便 raw value 与展示值一致，也必须继续区分“请求值”和“展示值”的职责，不能把分类规则写死在 UI 文案判断里
  - `全部` 仍然只是 UI 聚合态，不单独作为 subtype 传给远端
- 上海博物馆当前 subtype 列表如下：
  - `礼器`
  - `明器`
  - `法器`
  - `道具`
  - `模具/模版`
  - `丧葬用具`
  - `陈设/观赏品`
  - `日用品`
  - `文具`
  - `农具`
  - `工具`
  - `兵器`
  - `饪食器`
  - `酒器`
  - `水器`
  - `车马器`
  - `度量衡`
  - `古钱`
  - `铸币`
  - `打制币`
  - `机制币`
  - `纸币`
  - `金银锭`
  - `非法定钱币`
  - `雕塑`
  - `造像`
  - `碑刻/墓志`
  - `俑像`
  - `画像石`
  - `画像砖`
  - `封泥`
  - `符节（牌）`
  - `印玺`
  - `建筑配件`
  - `器物配件`
  - `织物`
  - `绣品`
  - `服装`
  - `饰品`
  - `文献`
  - `书籍图谱`
  - `拓本`
  - `玩具`
  - `乐器`
- 后续如果上海博物馆新增或调整 subtype：
  - 必须同时更新项目内静态列表
  - 必须确认新的 subtype 文案可直接用于 UI 展示
  - 必须确认请求体继续传递正确的 `subtype` 值

#### 3.2.7 吉美国立亚洲艺术博物馆分类

- 吉美国立亚洲艺术博物馆分类来源以官网 `https://www.guimet.fr/zh-hans/cangpin` 上展示的藏品分类为准。
- 请求侧需要继续使用官网分类页 path 作为筛选值。
- 当前官网分类 path 与 UI 展示映射如下：
  - `/zh-hans/collections/afghanistan-et-gandhara` -> `阿富汗 - 巴基斯坦`
  - `/zh-hans/collections/asie-du-sud-est` -> `东南亚`
  - `/zh-hans/collections/monde-indien` -> `印度世界`
  - `/zh-hans/collections/monde-himalayen` -> `喜马拉雅世界`
  - `/zh-hans/collections/chine` -> `中国`
  - `/zh-hans/collections/chine-bouddhique-asie-centrale` -> `中国佛教 - 中亚`
  - `/zh-hans/collections/coree` -> `韩国收藏`
  - `/zh-hans/collections/japon` -> `日本`
  - `/zh-hans/collections/textiles` -> `织物`
  - `/zh-hans/collections/tresors-de-la-bibliotheque` -> `历史图书馆珍藏`
  - `/zh-hans/collections/photographies` -> `摄影作品`
- 后续如果官网藏品页新增或调整分类：
  - 不能直接把未确认的 path 暴露给用户
  - 必须同时更新请求 path、内部稳定 id 和 UI 中文展示值
