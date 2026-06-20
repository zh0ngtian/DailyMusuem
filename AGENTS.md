# MuseumMuse Product Requirements

## 文档维护约定

- 进行任何功能性修改后，必须同步检查 `AGENTS.md` 是否需要修改或补充。
- 如果本次改动影响了功能范围、交互规则、数据接入、分类映射、Widget 行为、验证方式或已知约束，必须在交付前把对应内容回填到 `AGENTS.md`。
- 不允许代码已经修改完成，但 `AGENTS.md` 仍停留在旧行为描述。

## 目录

- `1. 范围与支持状态`：说明产品定位、当前支持状态和当前阶段正式范围。
- `2. 新增博物馆接入指南`：说明新增一个博物馆时的完成标准、接入顺序、漏改点和红线。
- `3. 数据接入与分类规范`：汇总各馆数据源、字段来源、分页 / 限流约束和分类映射。
- `4. 主 App 规范`：定义一级页、二级页、详情页和统一文案要求。
- `5. Widget 规范`：定义配置、刷新、交互、视觉、深链接和常见坑。
- `6. 验证与交付`：定义模拟器默认策略、真机补充方案和 widget 闭环验收方式。

## 1. 范围与支持状态

### 1.1 产品定位

- `MuseumMuse`（中文名：`博物女神`）是一个 iOS App，用于展示各大博物馆的展品。
- 当前版本的正式交付范围以本章 `1.3 当前阶段正式范围` 为准。
- 仓库中如果已经存在某个博物馆的数据接入或实验代码，不等于该博物馆已经正式支持。
- 应用需要同时提供主 App 和 Widget 小组件体验。

### 1.2 当前支持状态

- 已接入数据源 / 代码链路的博物馆：
  - 名称：`大都会艺术博物馆`
  - 副标题：`纽约`
  - 名称：`东京国立博物馆`
  - 副标题：`东京`
  - 名称：`奈良国立博物馆`
  - 副标题：`奈良`
  - 名称：`中国国家博物馆`
  - 副标题：`北京`
  - 名称：`上海博物馆`
  - 副标题：`上海`
  - 名称：`吉美国立亚洲艺术博物馆`
  - 副标题：`巴黎`
- 判断规则：
  - 仅接上 API、能拉到数据，不能视为“新增博物馆已完成”。
  - 只有同时完成 `一级页入口`、`二级页瀑布流`、`页面设置`、`详情页`、`Widget`、`深链接`、`验证闭环`、`AGENTS.md 回填`，才算正式支持。

### 1.3 当前阶段正式范围

- 当前阶段正式支持的博物馆为：
  - `中国国家博物馆`
  - `上海博物馆`
  - `大都会艺术博物馆`
  - `东京国立博物馆`
  - `奈良国立博物馆`
  - `吉美国立亚洲艺术博物馆`
- 上述六馆均应维持主 App 一级页入口、二级页、详情页、收藏夹、Widget 单馆 scope、深链接和验证闭环。
- 如果代码中出现新的 `MuseumID`、API 文件或实验数据源，但没有补齐本文 `2.1 完成标准`，不得加入当前正式支持范围。

## 2. 新增博物馆接入指南

### 2.1 完成标准

- 新增一个博物馆，不是只把 `MuseumID` 加进枚举或把数据拉通。
- 只有满足以下条件，才算这个博物馆真正接入完成：
  - 主 App 一级页可见，且名称、副标题符合中文文案要求。
  - 二级页可按现有规则完成首批加载、继续上滑加载、下拉刷新、页面设置记忆、类别多选、日志展示。
- 详情页能稳定展示标题、艺术家、年代、材质、尺寸、类别、文化、国家、官网链接、版权声明，并提供 `AI` 按钮；`AI` 按钮使用 `apple.intelligence` 图标，点击后调用固定名称的快捷指令 `DoubaoMuseum`，传入 `介绍一下这个展品：当前详情页官方网页链接`。若返回 `未找到快捷指令`，则提示安装快捷指令；若返回 `该App无法打开` 或 `the app could not be opened`，则提示安装豆包 App。同时支持点击主图进入全屏预览后缩放、跟随手机旋转和保存图片。
  - Widget 支持该馆单馆 scope，并继续遵守实例隔离、手动 / 自动刷新、`network-only`、单件候选推进规则。
  - Widget 主体点击后能通过深链接直达该馆展品详情，且前台 / 后台 / 冷启动都正常。
  - 已补齐文档中的数据源、分类映射、特殊限制、验证方式。
  - 已完成默认模拟器验证闭环；如涉及真机权限、真机网络或其他模拟器无法稳定覆盖的场景，再补充真机验证。

### 2.2 接入顺序

- 第 1 步：先确认数据源是否足够稳定。
  - 至少确认：搜索接口、详情接口、分类来源、官网原始链接、图片字段、展品介绍来源、QPS / 限流要求、是否需要网页抓取兜底。
  - 如果公开 API 没有稳定返回展品介绍，需要先明确官网兜底抓取的目标区块，不能抓错栏目。
  - 如果接口对分页大小、并发数、请求频率敏感，必须在立项时就写入实现约束，不能等到被限流后再补救。
- 第 2 步：先定义馆级数据契约，再开始写 UI。
  - 必须先确定：博物馆中文名、副标题、稳定 `museumID`、是否支持系统翻译、是否支持 Widget、类别原始值与中文展示映射。
  - 分类必须同时定义三套值：
    - 接口请求值
    - 项目内部稳定标识
    - UI 中文展示值
  - `全部` 只能是 UI 聚合态，不能伪装成远端真实分类。
- 第 3 步：先把主 App 二级页链路补完整。
  - 新馆必须接入二级页的首批 `10` 条加载、继续上滑后松手加载下一批、下拉刷新、页面设置记忆、按馆缓存。
  - 每批详情请求仍然只能拉 `10` 条，不允许为了“凑满页面”而在同一批里额外追拉更多详情。
  - 如果该馆搜索结果池很大，必须考虑本地持久化缓存和页面级缓存，避免每次重进都从头拉。
  - 如果该馆有明显的慢接口或长链路，必须补页面内加载日志。
- 第 4 步：补齐详情页与图片行为。
  - 详情页至少满足本文 `4.4 展品详情页` 的要求。
  - 图片失败后在网络恢复时必须可重新加载，不能出现“一次失败后永久失败”的状态。
  - 如果详情页依赖网页抓取兜底，必须保留精确解析规则，不能把其他栏目误当作展品介绍。
- 第 5 步：补齐 Widget，而不是只做主 App。
  - 新馆如果要算正式支持，必须同时接入 Widget scope、实例隔离刷新、单件候选推进、失败态、成功态图片裁剪与降采样。
  - Widget 刷新仍然必须走 `network-only`，不能复用主 App 的搜索 / 详情缓存来“假装刷新成功”。
  - 单馆 scope 时，只能从当前博物馆和该馆当前生效类别中选候选。
  - 找到首个可渲染展品后必须立即停止，不能成功后继续拉第二个候选。
- 第 6 步：最后才决定是否对用户展示。
  - 不要因为代码里已经有 `MuseumID`、API 文件、实验数据源，就直接把它暴露到一级页或 Widget 配置里。
  - 是否属于“当前支持的博物馆”，以本文完成标准和 `1.3 当前阶段正式范围` 为准，不以代码存在与否为准。

### 2.3 常见漏改点

- 新增博物馆时，不能只改一个入口；至少要全局搜索下面这些关键词，确认所有分发点都覆盖：
  - `switch museumID`
  - `switch scope`
  - `MuseumID.allCases`
  - `WidgetConfiguredMuseumScope`
  - `supportsWidgetContent`
- 当前高频落点包括：
  - `Shared/Museum.swift`
    - 博物馆枚举、名称、副标题、翻译能力、Widget 支持、类别定义
  - `Shared/ArtworkFeed/ArtworkFeedViewModel.swift`
    - 二级页批量加载、缓存恢复、分类切换后的刷新策略
  - `DailyMuseum/Views/ArtworkDetailLoaderView.swift`
    - 详情页按馆分发逻辑
  - `DailyMuseumWidget/DailyMuseumWidget.swift`
    - Widget 配置项中的单馆 scope 枚举与展示文案
  - `DailyMuseumWidget/WidgetSettingsReader.swift`
    - Widget 侧分类读取、候选池准备、按馆详情拉取
  - `DailyMuseumWidget/WidgetRefreshDeliveryTracker.swift`
    - Widget 刷新时的候选推进、图片优先级、按馆特殊策略
- 如果只是把新馆加进 `MuseumID.allCases`，往往会导致：
  - 一级页提前暴露未完成馆
  - Widget scope 提前出现未完成馆
  - 深链接、详情页或刷新分发逻辑遗漏 case 后在运行时暴露问题

### 2.4 接入红线

- 不允许把分类 raw key 直接展示给用户，必须先补中文映射。
- 不允许只改 UI 文案、不改真实请求值或缓存键。
- 不允许绕过已有的分页、限流、缓存、兜底抓取约束。
- 不允许主 App 和 Widget 共用一套“看起来能跑”的偷懒逻辑：
  - 主 App 需要缓存与分批加载。
  - Widget 需要实例隔离与 `network-only` 刷新。
- 不允许把 provider 返回成功误判为 widget 已真正显示成功：
  - 新馆接入完成与否，仍然必须看桌面截图和系统日志。

## 3. 数据接入与分类规范

### 3.1 数据接入

- 当前改造后的展品数据路径为 `离线爬虫 + 服务端 SQLite + iOS/Widget 后端客户端`。
- 主 App 二级页、详情页和 Widget 默认不再直接请求各馆官方展品接口；各馆官方 API / 官网解析代码保留为爬虫规则参考和短期排查依据。
- SQLite 只保存展品文字字段、分类、官网链接、图片 URL 和抓取元信息，不保存图片二进制。
- 图片仍由客户端按服务端返回的 `primaryImageURL` / `primaryImageSmallURL` 异步拉取。
- 当前 `server.crawler.main crawl` 成功后会按 SQLite 当前状态写出 manifest；默认库 `museummuse.sqlite` 使用同目录 `manifest.json`，非默认库使用同目录 `{db_stem}.manifest.json`，避免多个 SQLite 在同一目录时互相覆盖 manifest。`--museum all` 只允许显式传入 `--allow-network` 后顺序执行全部正式源，避免误触发真实源站请求。
- 本地后端 / 客户端功能测试可先运行 `python -m server.crawler.seed_sample_data --db server/data/museummuse.sqlite` 生成最小样本 SQLite；该脚本复用各馆 crawler parser / store 函数，不触发任何源站网络请求，不能当作真实全量抓取完成证据。
- 真实数据交付仍以 `python -m server.crawler.main crawl --museum all --db server/data/museummuse.sqlite --allow-network --max-details {明确预算}` 或 `--full --skip-existing` 生成的 SQLite、`manifest.json` 和抓取日志为准；live crawl 必须显式传入大于 `0` 的 `--max-details` 或显式传入 `--full`，避免默认命令产生无详情数据的假成功。
- `--full` 表示遍历当前数据源发现到的完整候选池，不能和 `--max-details` 同时使用；`--skip-existing` 用于长任务续跑，遇到目标库中已存在的 `(museum_id, source_key, object_id)` 时跳过详情请求，并在 crawl run manifest 中记录 `skippedExistingCount`。
- `--museum all` 可用 `--exclude-museum {crawler_id}` 跳过高风险来源；例如国博全量详情策略未确认时，应使用 `--exclude-museum nmc` 先完成其它来源全量 crawl。
- `--page-size {N}` 可用于支持分页大小的候选搜索 crawler，例如 Japan Search 和上海博物馆；它只减少候选页请求次数，不改变详情页抓取上限。用户已允许后续批量尝试 `50`，但若源站失败率升高，应回退到默认 `10`。
- `--request-interval {seconds}` 可用于支持该参数的非国博 crawler 调整请求间隔；`--concurrency {N}` 可用于支持该参数的非国博长详情 crawler 并发抓取详情。用户已允许后续非国博来源尝试 `--request-interval 0.1 --concurrency 10`（约 `10 QPS` 上限）。这两个参数禁止用于国博，国博仍必须遵守单独 API 调用预算和反爬限制。
- 本地客户端连接后端验证全量数据时，后端必须显式设置 `MUSEUMMUSE_DB_PATH=server/data/museummuse-live-all.sqlite`；`server/data/museummuse-live-full.sqlite` 是早期每源 `10` 条的小样本库，继续指向它会导致客户端看起来只能加载 `10` 条。
- Cloudflare serverless 部署使用 `server/worker` 中的 Worker 实现，Worker 名称为 `museummuse-api`，D1 绑定名为 `DB`，当前 D1 数据库为 `musuem_muse`（UUID：`9ab953e7-0af0-4c08-863a-85717e4fc941`）。iOS 主 App 和 Widget 的默认 `MuseumBackendBaseURL` 指向 `https://museummuse-api.305301890.workers.dev`。
- 将 `server/data` 中的 SQLite 迁移到 D1 时，以 `server/data/museummuse-live-all.sqlite` 和同名 manifest 为准；导入 SQL 需要使用 `sqlite3 {db} ".dump --newlines"` 生成，并移除 `BEGIN TRANSACTION` / `COMMIT` 等 D1 不接受的事务包装，不能使用会输出 `unistr(...)` 的默认 `.dump`。
- 上海博物馆和 Met 这类长详情任务会在 live crawl 中逐条提交，并每 `100` 个候选输出一次进度；如果任务中断，后续应使用 `--skip-existing` 续跑，不能直接认为已完成。
- 全量交付前必须运行 `python -m server.crawler.main status --db {SQLite}`；只有所有正式 crawler target 都显示 `completion=complete`，才能视为“全量爬取完成”。样本数据、`--max-details` smoke run 或只有部分来源成功不能当作全量完成证据。
- 服务端 `/v1` 业务接口默认需要鉴权；`MUSEUMMUSE_AUTH_MODE=disabled` 原则上只允许 loopback 本地开发跳过鉴权。当前 Cloudflare Worker 为了让现有客户端无需 App Attest 即可访问，临时以 `AUTH_MODE=disabled` 部署；该模式只适合作为当前 serverless 联调路径，不能视为生产鉴权完成。
- Simulator 本地调试可使用 `MUSEUMMUSE_AUTH_MODE=debug` 和 `MUSEUMMUSE_DEBUG_AUTH_SECRET` 启用 debug auth；客户端仍需通过 challenge / register / session 获取短期 token，并在业务请求中携带 timestamp、nonce、request hash 和 debug assertion。
- 未配置正式 App Attest 校验时，非本地 debug / disabled 模式不能当作生产可用鉴权；服务端应返回 `501 app_attest_not_configured`。

#### 3.1.1 大都会艺术博物馆

- 大都会当前主数据源是 `The Met Collection API`：
  - 搜索展品 ID：
    - `https://collectionapi.metmuseum.org/public/collection/v1/search`
  - 拉取展品详情：
    - `https://collectionapi.metmuseum.org/public/collection/v1/objects/{objectID}`
- 大都会当前搜索请求约束：
  - 搜索继续使用 `q`、`hasImages` 和可选的 `departmentId`
  - 默认不附带 `isOnView` 过滤条件，不把搜索结果限制为“正在展出”
  - 大都会二级页页面设置提供 `仅显示展出展品` 开关，默认关闭；开启后主 App 和 Widget 的大都会候选池搜索请求需要附带 `isOnView=true`
  - 大都会 objectIDs 缓存 key 必须区分 `仅显示展出展品` 开关状态，避免开启和关闭状态复用同一候选池
- 大都会详情页中的“展品介绍/官网概述”不完全依赖公开 API：
  - 当公开 API 未返回可用介绍字段时，需要继续访问官网页面：
    - 先尝试中文页面：`https://www.metmuseum.org/zh/art/collection/search/{objectID}`
    - 中文页面没有可用概述时，再回退英文页面：`https://www.metmuseum.org/art/collection/search/{objectID}`
  - 当前会从官网页面的 object overview 区块中提取描述内容，作为详情页补充信息来源。
  - object overview 的 CSS module hash 可能变化，解析规则需要匹配稳定的 overview / label 语义片段，不能依赖某一个完整 class 名。
  - 部分官网页面会把介绍放在标题区的顶部简介段落中，位置在标题、年代、展出状态之后，`Artwork Details` 之前；当 object overview 不存在时，需要把该顶部简介作为兜底来源。
  - Met 官网页面可能返回 Vercel Security Checkpoint，主 App 中 `URLSession` 抓取不到概述时，需要使用 App 侧浏览器渲染兜底再复用同一套解析规则；该 WebKit 兜底不能放入 Shared，避免污染 Widget extension。
- 后续如果修改大都会详情逻辑：
  - 不能假设公开 API 已包含完整介绍文案。
  - 不能删除官网页面抓取这条兜底链路，除非确认官方 API 已能稳定返回同等信息。
  - 不允许把 `Overview / Provenance / References / Catalogue Entry` 等其他官网区块误当作展品介绍。
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
  - 大 `size` 值在 iPhone 端不稳定，分页大小必须按当前约定的小页策略处理，不能恢复成一次抓取超大页。
  - 当 contributor 查询返回空结果时，需要允许退回 `cobas` 全库搜索并在本地过滤东京国立博物馆数据。
- 东京馆当前不依赖官网页面抓取详情：
  - 展品列表和详情信息都以 `Japan Search Web API` 返回为准。
  - 后续如增加新的网页抓取方案，必须先确认不会破坏现有分页、缓存和字段映射逻辑。
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum tnm --sample-detail-json` 验证 Japan Search item JSON 解析和 SQLite 入库；真实网络抓取必须显式传入 `--allow-network`，并继续保留 `size=10` 小页、contributor 空结果 fallback 和本地过滤规则。

#### 3.1.3 奈良国立博物馆

- 奈良国立博物馆当前支持两套数据源：
  - 默认数据源：馆方中文藏品数据库 `https://www.narahaku.go.jp/chinese/collection/`
  - 可选数据源：`Japan Search Web API` / `ColBase`
- 奈良馆数据源选择只在奈良二级页“页面设置”中展示：
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
  - 详情 loader 对 `.nnm` 需要按 `objectID` 前缀分发：`narahaku-` 走馆方详情，否则走 Japan Search / ColBase
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum nnm-official --sample-detail-html --sample-object-id {原始ID}` 验证奈良馆方详情 HTML 解析和 SQLite 入库；搜索页解析、`narahaku-` objectID、图片 URL 规范化、说明文本清洗、缺失材质行处理和官方门类 membership 都必须继续与 Swift 侧规则保持一致。
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
  - 大 `size` 值在 iPhone 端不稳定，分页大小必须按当前约定的小页策略处理，不能恢复成一次抓取超大页。
  - 主 App 二级页和 Widget 均继续按 `10` 条小页增量推进。
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
- 当前 App 对搜索接口的用途：
  - 分页拉取展品编码 `code`
  - 获取首屏所需的摘要信息和缩略图
  - 按 `subtype` 构建二级页和 widget 的候选池
- 当前 App 对详情页和图片页的用途：
  - 从详情页解析标题、纪年、分类、尺寸、材质、作者、产地、展品介绍
  - 从图片页解析主图和小图地址
  - 详情页和图片页共同组成最终详情数据，不能只依赖搜索摘要
- 上海博物馆当前请求约束：
  - 搜索分页大小按 `10` 条处理
  - 当前离线 crawler 默认对搜索、详情、图片请求使用保守节流；用户批准后，真实全量抓取可通过 `--request-interval 0.1 --concurrency 10` 在共享 limiter 下尝试约 `10 QPS` 上限
  - 请求需要继续保留浏览器风格请求头与 `Referer`
  - 离线 crawler 对搜索、详情和图片请求的瞬时网络失败最多重试 `3` 次，每次重试仍需经过同一个共享 limiter
  - 后续如果修改上海博物馆链路，不能移除分页、小页策略、节流或请求头兜底
- 上海博物馆详情链路注意事项：
  - 搜索返回的 `catalog` 和摘要字段只可作为预览或补充，详情页仍应以文章页解析结果为准
  - 部分文章页标题前会带 `img.jwz` 等题名字形图片，标题解析必须先清理标题区内的图片、收藏链接等标签，不能要求 `title` div 的第一个节点就是纯文本
  - 图片页解析失败时，当前允许继续返回文字详情；后续修改时不能因为图片页失败而直接丢弃整条详情
  - 主 App 二级页首批加载允许先用文章页解析出的文字字段渲染卡片，再等待图片页补齐图片链接与后续图片显示
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum shm --sample-detail-html --sample-object-id {code}` 验证上海博物馆文章页 HTML 解析和 SQLite 入库；可选 `--sample-image-html` 补充图片页解析。真实网络抓取必须显式传入 `--allow-network`，并继续保留搜索 / 文章 / 图片请求共享 limiter、图片页失败不丢弃文字详情、搜索摘要不替代文章页详情的规则。

#### 3.1.6 吉美国立亚洲艺术博物馆

- 吉美国立亚洲艺术博物馆当前主数据源是官网中文藏品页：
  - 分类入口页：
    - `https://www.guimet.fr/zh-hans/cangpin`
  - 分类页：
    - `https://www.guimet.fr/zh-hans/collections/{collection-slug}`
  - 展品详情页：
    - `https://www.guimet.fr/zh-hans/nos-collections/{collection-slug}/{artwork-slug}`
- 当前 App 对官网分类页的用途：
  - 从 `node--type-art-work` 卡片解析展品详情页 URL、标题、卡片类别和图片
  - 分类页只作为候选池，不代替详情页字段解析
  - 分类页摘要不允许写入详情缓存；二级页和 Widget 批量加载仍必须进入展品详情页抓取图片和展品字段
  - `objectID` 使用详情页路径中 `/zh-hans/nos-collections/` 后的相对路径，并用 `~` 替代路径分隔符，例如 `afghanistan-pakistan~bodhisattva-maitreya`
- 当前 App 对官网详情页的用途：
  - 从 `artwork-title`、`main-artwork`、`field--name-field-teaser`、`field--name-field-ref-widgets` 和 `info-table` 解析标题、年代、材质、尺寸、类别、地区 / 地点、展品介绍、图片和官网链接
  - 详情介绍只解析当前展品正文区，不允许把 `了解更多藏品` 相关卡片误抓进介绍
  - 当前官网详情页未稳定提供艺术家或国家字段时，允许保持空值，不允许伪造内容
- 吉美国立亚洲艺术博物馆当前请求约束：
  - 请求需要继续保留浏览器风格 `User-Agent`、`text/html` Accept 和中文 `Accept-Language`
  - 主 App 二级页和 Widget 均从官网分类页准备候选，详情页仍按现有每批 `10` 条推进
  - Widget 刷新仍然必须走 `network-only`，不能复用主 App 搜索 / 详情缓存
- 后续如果修改吉美国立亚洲艺术博物馆链路：
  - 不能恢复到 POP / Joconde 作为主数据源，除非产品范围再次明确调整
  - 不能把官网分类页以外的站内推荐卡片混入当前分类候选池
  - 不能把详情页中的导航、分享、相关藏品或页脚内容误当作展品字段
- 当前 Python 离线爬虫已支持 `server.crawler.main crawl --museum guimet --sample-detail-html --sample-detail-url {详情页URL}` 验证吉美官网详情 HTML 解析和 SQLite 入库；真实网络抓取必须显式传入 `--allow-network`，并继续保留官网分类页候选、详情页字段解析、`~` objectID 分隔和“不混入了解更多藏品”规则。

### 3.2 分类规范

#### 3.2.1 通用规则

- 二级页面中的类别名称必须展示中文，不直接向用户展示原始分类 key。
- 数据拉取、缓存键、筛选请求需要继续保留并使用各馆原始分类值。
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

- 中国国家博物馆展品已取消类别静态映射，只允许通过接口拉取。
- 中国国家博物馆分类来源以列表接口 `exhibit_list` 的 `cate_id` 为准。
- 请求侧需要继续使用 `cate_id` 作为筛选值。
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
- 中国国家博物馆详情页中的分类字段只作为展示校验或兜底参考，不作为主筛选来源。

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

## 4. 主 App 规范

### 4.1 信息架构

- App 主界面以一级页面为入口，并提供可从一级页面进入的收藏夹页：
  - 一级页面：博物馆列表
  - 收藏夹页面：按博物馆分组查看已收藏展品
  - 二级页面：某个博物馆的展品列表
- 点击二级页面中的展品后，进入展品详情页。
- 点击收藏夹页面中的展品后，同样进入对应展品详情页。

### 4.2 一级页面

- 展示已支持的博物馆列表。
- 首页按国家分组展示博物馆：
  - `中国` 分组固定显示在最上方
  - 同一国家内的博物馆继续保持当前支持顺序
- 首页每个博物馆卡片左侧都需要展示对应 logo：
  - logo 放在统一的浅色圆角容器中
  - 名称和副标题继续保持当前中文文案，不因 logo 接入而改变
  - 首页已按国家分组时，卡片副标题只显示城市，不重复显示国家
- 首页不提供延迟测试开关、延迟结果行或下拉测速入口，也不在进入首页时发起测速请求。
- App 冷启动时需要立即发起一次独立的轻量联网请求，用于触发系统联网权限提示；该请求不写入展品搜索、详情或 Widget 缓存。
- 右上角需要同时提供：
  - 收藏夹图标入口
  - 设置图标入口
- 首页不再提供博物馆拖拽排序或排序模式；右上角固定显示收藏夹和设置入口。
- 首页设置页用于全局设置：
  - 小组件自动刷新间隔可选：`关闭`、`1小时`、`3小时`、`6小时`、`12小时`、`24小时`
  - 小组件自动刷新间隔默认值为 `关闭`
  - 小组件自动刷新还需要提供 `开始时间` 和 `结束时间`，默认分别为 `00:00` 和 `23:00`
  - `开始时间` 与 `结束时间` 以单独的设置行展示，点击后进入时间选择，不直接在设置页内联展开选择器
  - 时间选择页面使用不透明背景，不展示右下角的当前时间预览
  - `开始时间` 与 `结束时间` 只支持选择整点
  - `开始时间` 与 `结束时间` 按每日同日时间窗生效，不支持跨午夜；若结束时间早于开始时间，则结束时间需要自动归齐到开始时间
  - 设置页需要根据当前配置显示“今日自动刷新时间”明细；自动刷新关闭时显示已关闭状态
  - “今日自动刷新时间”文案需要居中；各时间点按多行多列等距排布，不使用顿号拼接，并使用等宽字体
  - 设置页需要支持将 App 配置导出为 JSON 文件，并支持从 JSON 文件导入恢复
  - 配置导入 / 导出范围包括全局设置、详情页全局字号、各馆二级页显示和分类设置、奈良数据源、收藏、旧博物馆排序 key，以及按博物馆记录的 Widget 已刷新展品历史
  - 配置导入后需要刷新主 App 内存状态，并触发 Widget timeline 重新加载
- 首页设置页不展示翻译相关项目。
- 详情页翻译能力继续保留：
  - 不再提供腾讯云、MiniMax 或其他第三方翻译引擎的选择、凭证填写、测试或清空入口
  - 详情页右上角翻译按钮使用 `TranslationSession` 触发应用内批量翻译
  - 翻译结果直接在当前详情页原位替换原文，不弹出独立翻译页
  - 首次翻译成功后支持在原文与译文之间切换
  - 若系统翻译语言包未准备好，只提示，不主动弹出系统下载页
  - App 当前最低支持系统版本为 `iOS 18`
- 当前博物馆文案要求：
  - 主标题显示：`大都会艺术博物馆`
  - 副标题显示：`纽约`
  - 主标题显示：`东京国立博物馆`
  - 副标题显示：`东京`
  - 主标题显示：`奈良国立博物馆`
  - 副标题显示：`奈良`
  - 主标题显示：`中国国家博物馆`
  - 副标题显示：`北京`
  - 主标题显示：`上海博物馆`
  - 副标题显示：`上海`
  - 主标题显示：`吉美国立亚洲艺术博物馆`
  - 副标题显示：`巴黎`

### 4.3 二级页面

- 二级页面展示该博物馆的展品流。
- 布局形式为瀑布流。
- 页面必须适配最新 iPhone 全面屏，不允许出现上下大黑边。
- 页面必须支持正常滚动，不允许出现上滑后无法继续触发加载的问题。
- 二级页面需要提供单独的“页面设置”入口。
- 当前二级页面中的以下能力需要放入“页面设置”中统一管理：
  - 视图切换
  - 类别筛选

#### 4.3.1 页面设置交互

- 页面设置中的“显示”需要支持记忆功能。
- 页面设置中的“类别筛选”需要支持多选。
- 用户点进页面设置后，当前已生效的“显示”选项和类别勾选状态必须在首屏立即渲染出来：
  - 不允许先显示默认值、空态或未勾选状态，再延迟补刷成真实配置
  - 打开设置页时看到的内容，应等于该博物馆当前实际生效的配置
- 类别筛选默认状态为：
  - `全部`
  - 等价于该博物馆下所有类别都被选中
- 类别筛选需要按博物馆分别记忆用户上次的选择结果。
- “显示”也需要按博物馆分别记忆用户上次的选择结果。
- 用户在页面设置中做出的修改，不允许边改边立即生效。
- 只有当用户点击页面设置右上角的 `完成` 按钮后：
  - 显示设置才真正生效
  - 类别筛选才真正生效
  - 如类别发生变化，才重新按新类别进行数据拉取和显示
- 大都会艺术博物馆的页面设置额外提供 `仅显示展出展品`：
  - 默认关闭
  - 只对大都会馆显示，其他博物馆页面设置不变
  - 和分类一样，只能在点击 `完成` 后生效；未点击 `完成` 直接关闭时，本次开关草稿不写入
  - 开启后主 App 与 Widget 的大都会搜索候选池都只请求 `isOnView=true` 的展品
- 奈良国立博物馆的页面设置额外提供 `数据源`：
  - 只对奈良馆显示，其他博物馆页面设置不变
  - 默认选中 `馆方数据源`
  - 可切换 `ColBase`
  - 数据源和分类一样，只能在点击 `完成` 后生效；未点击 `完成` 直接关闭时，本次数据源和分类草稿都不写入
- 如果用户没有点击 `完成`，而是直接通过下滑手势关闭页面设置：
  - 本次设置修改不生效
  - 不允许写入记忆状态
  - 二级页面继续保持进入设置前的显示和筛选状态

#### 4.3.2 数据加载

- 进入二级页面时，不要一次性抓取所有详情数据。
- 首次只加载少量展品：
  - 当前约定为 `10` 个。
- 后续继续浏览时，滚动到底部后继续上滑加载下一批。
- 到达底部后，不允许自动继续加载下一批。
- 底部加载更多的交互需要对齐顶部 `refreshable` 的手感：
  - 先继续上滑，超过阈值后进入“松开即可加载下一批”状态。
  - 只有用户松手后，才真正触发下一批加载。
- 每次增量加载数量：
  - 当前约定为 `10` 个。
- 每一批的网络详情请求数量也必须严格限制为 `10` 个，不允许为了补齐可展示数量继续在同一批里额外追拉更多详情。
- 下拉刷新时：
  - 重新刷新二级页内容。
  - 重新走首批加载逻辑。
  - 刷新过程中直接进入二级页内联的 `正在加载展品...` 状态，不再回退到独立的 `正在加载展品...` 全屏界面。
  - 刷新中的首批加载提示出现时，屏幕上已经渲染出的展品卡片仍需保留，待新首批结果完成后再整体切换。
- 东京国立博物馆和奈良国立博物馆 ColBase 源的数据池也不允许预拉取：
  - Japan Search 搜索分页大小按 `10` 条处理。
  - 首次进入只准备首批所需的 `10` 条候选数据。
  - 后续每次继续浏览时，也只按下一批所需数量增量补齐，不要额外预备 `30` 条或更多数据。
- 奈良国立博物馆馆方源同样不允许预拉详情：
  - 首次进入只从馆方分类结果页准备候选，再拉首批 `10` 条详情
  - 后续继续浏览仍按每批 `10` 条推进
  - 不允许为了补齐首屏在同一批里额外追拉更多详情
- 吉美国立亚洲艺术博物馆官网数据源同样不允许预拉详情：
  - 首次进入只从官网分类页准备候选，再拉首批 `10` 条详情
  - 后续继续浏览仍按每批 `10` 条推进
  - 不允许为了补齐首屏在同一批里额外追拉更多详情

#### 4.3.3 排序与展示

- 主 App 二级页固定按随机顺序展示展品。
- 二级页面切换到列表视图时，展品卡片中不显示博物馆名称。

#### 4.3.4 缓存与性能

- 不要每次进入二级页面都重新刷新。
- 同一次 App 运行期间，返回再进入二级页面时应复用缓存数据。
- 需要尽量减少首次进入的等待时间。
- 已确认首屏慢的核心原因是：
  - Met 搜索接口会返回大批量 `objectIDs`
  - 详情接口需要逐条继续拉取
- 当前策略要求：
  - `objectIDs` 需要做本地持久化缓存
  - 已加载的页面内容需要做页面级缓存
  - 重启 App 后首次进入二级页时，优先复用本地缓存
  - 二级页首批展品不需要等待整批图片都准备完成；任一展品的文本详情一旦可用，即可先进入列表开始渲染
  - 列表卡片图片继续按卡片异步加载；图片字段需要额外链路补齐时，允许文字先显示、图片后补齐

#### 4.3.5 日志

- 在等待拉取全量 `objectIDs` 时，页面中需要显示相关日志。
- 页面内加载日志和请求日志的时间戳需要精确到毫秒级。
- 日志至少应覆盖：
  - 检查内存缓存
  - 检查本地缓存
  - 开始从大都会艺术博物馆拉取全量 `objectIDs`
  - 拉取完成并写入缓存
  - 开始整理随机或顺序数据
  - 开始拉取首批展品详情
  - 首批或下一批详情加载完成
  - 加载失败原因

#### 4.3.6 图片

- 某些展品图片因网络问题加载失败后，网络恢复时需要支持重新加载。
- 不能出现“某张图失败后永远不再重试”的情况。

### 4.4 展品详情页

- 点击展品后进入详情页。
- 详情信息通过服务端详情接口抓取；官网页面解析、大都会概述兜底、国博 / 上博 HTML 清洗等逻辑前移到离线爬虫。
- 详情页不显示副标题；艺术家需要作为独立字段展示。
- 详情页右上角需要提供收藏按钮：
  - 未收藏时显示 `star`
  - 已收藏时显示 `star.fill`
  - 点击后在收藏 / 取消收藏之间切换
- 详情页右上角需要提供分享按钮：
  - 图标使用 `square.and.arrow.up`
  - 点击后对当前展品详情页生成一张长截图
  - 截图不包含顶部导航和操作按钮，但需要包含当前详情页中尚未滚动到的正文内容
  - 生成截图后先弹出一个简单预览，再进入系统分享页面
  - 预览页默认固定半屏高度，不提供拉高或改尺寸交互
  - 预览页中的截图需要完整按比例展示，不使用滚动查看
  - 系统分享页面继续以该图片作为分享对象
  - `DailyMuseum/Info.plist` 需要继续声明 `LSApplicationQueriesSchemes=weixin`，用于分享链路中的微信可用性诊断
- 详情页右上角操作较多时，分享和字号调整需要收纳进显式的 `更多` 菜单；`AI`、官网、翻译、收藏和 `更多` 需要保持一级可见，不能被系统自动溢出挤掉。
- 详情页右上角一级操作图标需要使用自适应尺寸：
  - 紧凑屏幕使用较小基准尺寸
  - 常规宽度使用稍大基准尺寸
  - 尺寸继续跟随系统 Dynamic Type 缩放
- 支持翻译的详情页右上角需要继续提供翻译按钮：
  - 点击后使用 `TranslationSession` 批量翻译当前详情页已展示的标题、介绍和字段
  - 翻译结果直接替换当前详情页正文，不弹出独立翻译页
  - 首次翻译成功后，按钮需要支持在原文与译文之间切换
  - 若系统翻译语言包未准备好，只展示提示，不弹出系统下载页
  - 不再在 App 内维护腾讯云、MiniMax 或其他第三方翻译引擎配置
  - App 当前最低支持系统版本为 `iOS 18`
- 详情页 `更多` 菜单中需要提供字号调整操作：
  - `更大字号` 使用 `plus.magnifyingglass`
  - `更小字号` 使用 `minus.magnifyingglass`
  - 不提供恢复默认字号操作
  - 点击 `更大字号` 或 `更小字号` 后，`更多` 菜单不能自动收起，需要允许用户连续调整字号
  - 字号调整是全局持久化配置，影响所有博物馆的所有展品详情页，App 重启后仍保留，并随配置导入 / 导出迁移
  - 字号调整不影响首页、二级页、收藏夹或 Widget
- 详情页右上角需要提供 `AI` 按钮：
  - 图标使用 `apple.intelligence`
  - 当前仅在该展品存在官网原始链接时显示
  - 点击后直接调用快捷指令 `DoubaoMuseum`
  - 传入文本固定为：`介绍一下这个展品：当前详情页官方网页链接`
  - 若快捷指令返回 `未找到快捷指令`，则提示用户安装快捷指令，安装入口固定打开：`https://www.icloud.com/shortcuts/50a57de8c0884898a895556c3e8b01b5`
  - 若快捷指令返回 `该App无法打开` 或 `the app could not be opened`，则提示用户安装 `豆包` App，安装入口固定打开：`https://apps.apple.com/cn/app/id6459478672`
- 收藏状态需要在本地持久化保存，App 重启后仍保留。
- 详情页至少展示：
  - 标题
  - 作者
  - 年代
  - 材质
  - 尺寸
  - 类别
  - 文化
  - 国家
- 详情页中的标题、介绍、字段文字和版权文字需要支持自由选中文字，不是只支持整段复制。
- 详情内容底部需要显示版权声明，格式固定为：
  - `©XX博物馆 版权所有`
  - 版权声明在底部独立展示，并水平居中
- 中国国家博物馆、上海博物馆等中文数据源中的详情文字在做 HTML 实体与标点清洗时，需要优先输出中文标点：
  - 引号使用中文引号
  - 破折号使用中文破折号
  - 省略号使用中文省略号
- 详情页支持跳转到官网原始链接。
- 点击详情页主图后，需要进入全屏预览页。
- 全屏预览页需要支持：
  - 双指缩放
  - 单指上下滑动连续缩放；连续缩放时需要保持触点锚定，不能出现画面抖动或回跳到原始尺寸
  - 缩放后的拖动查看
  - 跟随手机横竖屏旋转
  - 保存到系统相册

### 4.4.1 收藏夹页

- 收藏夹页从首页右上角的收藏夹图标进入。
- 收藏夹页按博物馆分组展示已收藏展品。
- 收藏夹中的展品卡片样式、宽度、间距需要对齐对应博物馆二级页的列表模式，不允许继续使用额外的系统列表 inset 把卡片压窄。
- 分组顺序需要跟随首页当前固定的国家分组顺序：
  - 当前顺序为 `中国国家博物馆`、`上海博物馆`、`大都会艺术博物馆`、`东京国立博物馆`、`奈良国立博物馆`、`吉美国立亚洲艺术博物馆`
- 每个分组内的展品按收藏时间倒序排序。
- 收藏夹页点击展品后，需要进入对应展品详情页。
- 奈良国立博物馆的数据源切换不影响已经收藏的文物：
  - 收藏夹不按当前奈良数据源过滤
  - 已收藏的 `narahaku-*` 馆方源展品和 ColBase 展品都必须继续显示
  - 点击收藏夹中的奈良展品时，详情页按 `objectID` 前缀分发到正确数据源
- 收藏夹页中的展品需要支持左滑删除，左滑删除等价于取消收藏。
- 收藏夹列表左滑删除后，同一展品详情页右上角星标状态也必须同步为未收藏；反过来，在详情页取消收藏后返回收藏夹时，对应卡片也必须立即消失。
- 取消收藏可通过收藏夹列表左滑删除，或通过详情页右上角星标完成。

### 4.5 统一文案

- 博物馆名称使用中文：
  - `大都会艺术博物馆`
  - `东京国立博物馆`
  - `奈良国立博物馆`
  - `中国国家博物馆`
  - `上海博物馆`
  - `吉美国立亚洲艺术博物馆`
- 博物馆副标题只显示城市：
  - `纽约`
  - `东京`
  - `奈良`
  - `北京`
  - `上海`
  - `巴黎`
- 不再在副标题中重复展示博物馆名称。

## 5. Widget 规范

### 5.1 总体要求

- 需要提供 WidgetKit 小组件。
- 支持三种尺寸：
  - `systemSmall`
  - `systemMedium`
  - `systemLarge`
- 小组件用于随机展示一件展品。
- 当前小组件支持手动刷新，并可在首页全局设置中开启自动刷新。
- 自动刷新间隔支持：`关闭`、`1小时`、`3小时`、`6小时`、`12小时`、`24小时`，默认值为 `关闭`。
- 自动刷新需要额外配置每日 `开始时间` 与 `结束时间`；默认值分别为 `00:00` 和 `23:00`。
- `开始时间` 与 `结束时间` 只支持选择整点。
- 小组件仍按实例单独配置展示范围，但渲染状态和刷新任务改为按 `scope` 共享：
  - 同展示范围的多个桌面实例必须显示同一件展品
  - 任一同范围实例手动或自动刷新后，该范围其他实例也应显示同一刷新结果
  - 不同展示范围之间仍保持独立
- 小组件首次安装或尚未成功拉到展品时，应显示中性占位态，例如：
  - `点击刷新获取展品`
  - 副标题提示：`长按小组件，选择「编辑小组件」以改变展品展示范围`

### 5.2 配置要求

- 小组件改为按实例配置，不再使用旧的全局小组件设置页语义。
- 每个小组件实例都需要单独配置展示范围。
- 如果新添加的小组件与桌面上已有实例属于同 `scope`：
  - 新实例需要直接复用这组当前共享内容
  - 不应因为是新实例而回退到独立占位态
- 展示范围支持：
  - 所有博物馆
  - 单个博物馆
- 小组件编辑面板中 `展示范围` 的默认项必须是 `所有博物馆`，不能显示参数标题占位文案。
- 小组件编辑面板里的展示范围顺序需要跟随首页当前固定顺序，但保持平铺展示，不按国家分组。
- 小组件自动刷新间隔、开始时间、结束时间只在首页全局设置中配置，不放入单个小组件的编辑面板。
- 当前单馆 scope 文案至少包括：
  - `大都会艺术博物馆`
  - `东京国立博物馆`
  - `奈良国立博物馆`
  - `中国国家博物馆`
  - `上海博物馆`
  - `吉美国立亚洲艺术博物馆`
- 主 App 内各博物馆当前保存的类别选择仍然需要保留：
  - 小组件刷新时继续复用这些类别作为过滤条件
  - 奈良国立博物馆需要同时读取当前数据源，并读取该数据源对应的分类存储；馆方源和 ColBase 源分类互不污染
- 不再提供以下旧配置项：
  - 全局展示范围
  - 是否优先展示有图片的展品

### 5.3 刷新逻辑

- 点击刷新按钮时，需要刷新当前 `scope` 对应的共享组。
- 开启自动刷新后，由 WidgetKit timeline 调度触发，实际执行时间以系统调度为准。
- 开启自动刷新后，到 `开始时间` 时需要自动刷新一次，并在未超过 `结束时间` 前按当前刷新间隔继续刷新；若某次时间点恰好等于 `结束时间`，该次仍可执行。
- 开启自动刷新后，到期时需要刷新当前 `scope` 对应的共享组，并继续复用同一套候选推进、图片校验和状态持久化规则。
- 当自动刷新设置为 `关闭` 时，小组件不应安排下一次自动 timeline 刷新，但手动刷新按钮仍然可用。
- 自动刷新节奏按固定时间表计算，不按“上次刷新成功时间 + 间隔”滚动顺延。
- 用户修改自动刷新间隔、开始时间或结束时间后，只从当前时刻之后的下一个合法时间点按新规则继续，不补触发当前时刻之前已错过的本日时间点。
- 用户手动刷新时，不得改变当前 `scope` 的自动刷新节奏或下一次自动刷新时间点。
- 同一共享组连续点击刷新时，后一次必须立即抢占前一次：
  - 立即取消前一次仍在执行的搜索、详情、图片拉取和等待行为
  - 直接开始第二次刷新
- 小组件不再展示单独的“刷新中”可见状态：
  - 已有成功展品时，刷新过程中继续保留上一件展品，直到新结果成功或失败后再切换
  - 尚无成功展品时，刷新过程中继续保留占位态，不显示“刷新中”文案或转圈态
- 同 `scope` 的多个实例需要共享状态与日志：
  - 不允许同组实例各自保留不同展品或不同刷新任务
- 不同展示范围之间互不影响：
  - 不允许一个组的刷新取消、覆盖或污染另一个组的状态和日志
- 任意刷新入口触发刷新时，包括小组件按钮、自动刷新或调试入口的批量 / 按 scope 刷新，都必须先通过 WidgetKit 获取当前桌面实际存在的小组件配置，再只刷新这些配置对应的 `scope`：
  - `WidgetInstances/instances.json` 只表示曾经渲染或登记过的共享状态，不等于当前桌面仍存在该小组件
  - 如果系统当前配置中没有某个 `scope`，即使持久化状态里仍残留该 `scope`，也不能触发该 `scope` 的网络刷新
  - 刷新入口需要记录本次 WidgetKit 返回的 `scope` / 尺寸摘要，方便真机日志判断系统实际认为哪些小组件存在
- WidgetKit 的 snapshot、preview 或非当前配置 timeline 渲染请求不能直接登记为真实桌面实例：
  - 写入 `WidgetInstances/instances.json` 或记录 `Widget 完成渲染` 前，也需要确认该 `scope` / 尺寸仍存在于当前桌面配置中
  - 非当前配置的渲染请求只允许读取已有共享状态用于展示，不能新建或更新共享状态
  - 获取当前配置后，应清理不在当前配置中的历史共享状态，避免已删除的 `scope` 残留后续误触发刷新
- 小组件刷新必须走 `network-only`：
  - 刷新时直连服务端，不复用主 App 搜索 / 详情缓存来选取展品
  - 仅允许持久化当前共享组上一次渲染结果和刷新状态，供 WidgetKit 重绘
- 中国国家博物馆小组件刷新不再直连 `exhibit_list` 或详情源站，必须通过服务端候选 / 列表接口获取服务端已入库展品。
- 国博源站 API 调用量控制属于离线爬虫职责；不能在 Widget provider 中重新实现国博源站随机页候选逻辑。
- 奈良国立博物馆小组件刷新必须跟随当前奈良数据源：
  - 馆方源使用 network-only 馆方候选和馆方详情，不复用主 App 缓存
  - ColBase 源继续使用 network-only Japan Search / ColBase 候选和详情
  - 单馆 scope 时，只能使用当前数据源下当前生效类别
  - 对 `narahaku.go.jp` 图片需要使用浏览器风格请求头和馆方 Referer：`https://www.narahaku.go.jp/chinese/collection/`
  - 对 ColBase 图片继续优先使用缩略图和 ColBase Referer
- 单馆 scope 时：
  - 只从当前博物馆和该馆当前生效类别中选择候选
- `所有博物馆` scope 时：
  - 每一轮候选都要从仍未耗尽的博物馆中随机选择一个馆继续推进
- 小组件刷新链路改为单件候选推进：
  - 每轮只推进 `1` 个候选展品，不再先取一批详情再逐个筛选
  - 候选没有可用图片时，立即丢弃并继续下一个候选
  - 候选有图时，图片拉取最多重试 `3` 次
  - 同一候选图片连续失败 `3` 次后，必须放弃该候选并更换下一个
  - 一旦找到首个可渲染展品，必须立即停止后续拉取
  - 成功后不允许继续请求第二个候选
  - 如果全部候选耗尽，必须展示失败态，不能继续保留旧展品伪装成功
- 小组件已刷新过的展品 ID 历史需要按博物馆持久化记录：
  - 历史不写入单个小组件实例状态或 `WidgetInstances/instances.json`
  - 历史需要随 App Group 持久化，并关联真实 `museumID`
  - 删除某个单馆小组件后再新建同一博物馆的小组件，旧小组件刷新过的展品仍不能再次命中
  - 当某个刷新范围内已经没有新的未展示候选时，允许清空该范围涉及博物馆的历史并重试一次，避免永久没有可展示展品
- 主 App 的二级页分批加载规则不受此约束：
  - 主 App 仍保持每批 `10` 个的加载语义

### 5.4 内容与交互

- 小组件需要支持手动刷新按钮。
- 点击刷新按钮后，应刷新到新的展品；如果全部候选耗尽，则展示失败态。
- 不提供通过长按 App 图标强制刷新展品 / 小组件的 Quick Action。
- 小组件断网刷新失败时，失败提示末尾不显示句号，且无图背景使用与 idle 占位态相同的背景。
- 三种尺寸的小组件不再要求在同一个刷新周期内显示同一件展品：
  - 是否显示相同展品，以各自实例当前状态为准
- 小组件点击主体区域后，应直接进入 App 内对应展品的详情页。
- 小组件不应只停留在 App 首页。

### 5.5 视觉

- 展品照片需要裁剪填满小组件。
- 不要求展示完整照片内容。
- 可以只展示照片的一部分。
- 但绝对不能出现黑边或空白边。
- 小组件左下角显示：
  - 展品名称
  - 展品年代
- 左下角文字规则：
  - 左对齐
  - 字体加粗
  - 字号适当缩小
- 小组件右上角显示手动刷新按钮。

### 5.6 深链接

- 小组件点击主体区域时，需通过 App 内深链接跳转到对应展品详情。
- 奈良国立博物馆深链接需要保留原始 `objectID`：
  - `narahaku-*` 进入馆方源详情
  - 其他 `.nnm` objectID 进入 Japan Search / ColBase 详情
  - 当前奈良数据源设置不得改变已生成深链接或已收藏展品的详情分发
- 深链接目标必须能在以下场景下正常工作：
  - App 已在前台
  - App 在后台
  - App 冷启动

### 5.7 常见坑

- 不能把 provider 返回 `success` 误判为“桌面一定已正常显示”：
  - `Widget 完成渲染` 日志只能说明 timeline 已生成。
  - 真正的验收仍然要看 SpringBoard 桌面截图。
- 小组件成功态如果直接使用远端原始大图，容易触发 WidgetKit/Chrono 归档失败：
  - 常见系统日志关键字包括：
    - `Widget archival failed due to image being too large`
    - `imageTooLarge`
  - 成功态背景图必须在图片下载成功后、写入 App Group 前先降采样到受控像素尺寸，渲染时直接读取已降采样文件并交给 SwiftUI `scaledToFill` 裁剪，避免在 Widget View 内再次 `UIImage(data:)` + 重绘导致真机 Widget 内存峰值过高、`idle`、归档失败或进程被系统终止。
- Widget 当前不再按隐藏 `instanceToken` 隔离内容：
  - provider 必须优先按 `scope` 命中共享状态
  - 即便配置里的旧 `instanceToken` 发生变化，同组实例也应继续显示同一份内容
- 用 `scope` 级别调试刷新时，同 scope 的多个桌面实例会被一起触发：
  - 容易污染日志。
  - 也容易让当前可见实例被后续刷新覆盖。
  - 需要稳定复现时，优先按共享刷新键定向触发。
- Widget 相关 request logs 当前需要显式打印共享刷新键：
  - 底层日志字段仍沿用 `instanceToken`
  - 但当前值语义是 `scope`，例如 `single:met`
- Widget 的 request logs、实例状态和主 App 日志页依赖主 App 与 Widget Extension 共享同一个 App Group：
  - 当前必须同时保留 `DailyMuseum/DailyMuseum.entitlements` 和 `DailyMuseumWidget/DailyMuseumWidgetAppGroup.entitlements` 中的 `group.tech.zh0ngtian.MuseumMuse`
  - 任一 target 丢失该 App Group 后，主 App 将无法读取 widget 写入的 request logs 与实例状态
- SpringBoard 和 WidgetKit 都存在快照缓存：
  - 代码修好后，桌面仍可能短时间继续显示旧占位态或旧快照。
  - 这时需要结合重新安装 App、重新拉起 App、重新请求 timeline、必要时重启模拟器或强制回桌面后再次截图来判断。
- 小组件去掉可见“刷新中”态后，桌面仍可能只看到旧展品或占位态：
  - 这不代表刷新已经成功完成。
  - 成功态往往才会暴露图片归档、图片尺寸、图片解码和状态回退等问题。

## 6. 验证与交付

### 6.1 默认验证策略

- 后续每次修复问题或新增功能后，都需要优先使用模拟器 `iPhone 17 Pro` 作为默认构建和运行目标再交付。
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
  - 上述链路已经验证通过：
    - 真机构建成功
    - 真机安装成功
    - 真机启动成功

### 6.3 小组件截图闭环测试

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
    - `--instance-token <TOKEN>`：按共享刷新键定向触发刷新，当前键格式为 `scope`
    - `--scope-raw-value <RAW>`：按 scope 触发刷新，例如 `single:nmc`、`single:shm`
    - `--wait <SECONDS>`：刷新后等待
    - `--tail <N>`：输出最后 N 条日志
    - `--instances`：输出 `instances.json`
    - `--screenshot-path <PATH>`：保存截图
    - `--home-screen`：截图前尝试回到桌面
- 推荐闭环步骤：
  - 1. `build-for-testing + install + launch`
  - 2. 用 `scripts/pull_simulator_request_logs.sh --instances` 确认当前共享刷新键，当前脚本输出里仍沿用 `instanceToken` 字段名
  - 3. 优先用 `--instance-token` 定向触发当前可见 `scope` 组刷新，避免同 scope 多实例互相污染
  - 4. 用脚本或 `xcrun simctl io ... screenshot` 抓图
  - 5. 检查 request logs，确认：
    - 候选拉取顺序符合预期
    - 成功后没有继续多拉
    - provider 至少生成过对应 family 的 timeline
    - 当前关键 widget 日志能看到对应的共享刷新键
  - 6. 再查系统日志，确认没有 `imageTooLarge`、归档失败或 Chrono 渲染错误
  - 7. 最后以桌面截图作为最终验收证据
- 奈良国立博物馆数据源切换验证还需要补充：
  - 主 App 页面设置默认显示 `馆方数据源`
  - 切换 `ColBase` 后，收藏夹中切换前已收藏的 `narahaku-*` 展品仍可见并能打开
  - Widget 单馆 `奈良国立博物馆` 刷新时，日志中的候选来源和图片 Referer 应与当前奈良数据源一致
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
