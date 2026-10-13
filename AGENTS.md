# MuseumMuse Product Requirements

## 文档维护约定

- 进行任何功能性修改后，必须同步检查 `AGENTS.md` 是否需要修改或补充。
- 如果本次改动影响了功能范围、交互规则、数据接入、分类映射、Widget 行为、验证方式或已知约束，必须在交付前把对应内容回填到 `AGENTS.md`。
- 不允许代码已经修改完成，但 `AGENTS.md` 仍停留在旧行为描述。
- 用户已授权后续 App/Widget 改动通过必要验证后，由统一协调入口发布到现有私有 Ad Hoc OTA，无需再次询问；按发布批次统一递增版本和 Build，完成逐目标验签与 HTTPS 回验。交付还必须确认该批最终提交的日常 GitHub Actions `iOS Build` 的 `Build` 通过，并通过指向同一提交的 `vX.Y.Z` 标签独立 `iOS Release` 确认 `Build` 与 `Publish unsigned IPA` 全部通过，标签 Release 提供一份 10 组小组件未签名 IPA、SHA-256 校验文件和元数据；详细流程见 [发布与构建检查](docs/ios-adhoc-ota.md#发布与构建检查)。纯文档、流水线或发布工具修改不递增 App 版本、不重新发布 OTA。
- 第 3、4、6 章的详细合同分别维护在 `docs/data-ingestion-contract.md`、`docs/app-behavior-contract.md` 和 `docs/verification-and-delivery.md`；功能修改时同时检查本文件的摘要/入口与对应合同。保留单一详细解释，不复制成平行规范。
- 后续改动不涉及客户端时，不触发客户端构建（包括本地 iOS 构建 / 测试目标编译及 GitHub Actions `iOS Build`），只执行与改动相称的验证。客户端范围包括主 App、Widget、Shared、客户端测试、资源和工程 / 编译配置；纯后端、数据、文档、运维或发布工具改动不要求客户端构建、未签名 IPA Release 或 OTA 发布。详细验证与 CI 触发范围见 [验证与交付](docs/verification-and-delivery.md#61-默认验证策略)。
- 通用多任务协调、合批窗口、冻结、互斥和恢复原则以当前生效的 canonical 全局 `AGENTS.md` 为准，本项目不复制正文。本项目的客户端 OTA / GitHub Release 与腾讯云 SCF 分属不同发布目标，项目补充、适配器和共享凭证要求统一见 [多任务发布协调](docs/verification-and-delivery.md#65-多任务发布协调)。已复用本机 ReleaseCoordinator 0.1.3 的共享服务，客户端与 SCF 分别登记 `museummuse-ios-production` / `museummuse-scf-production`；适配器入口、配置、登记/ready/共同 receipt 核对及真实验收限制见 [协调器接入](docs/release-coordinator-integration.md)。现有服务为登录启动；SCF 新包部署仍需有效原凭证和全量输入，不能把替身测试当作真实部署完成。

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

- 已接入代码链路的六馆见 1.3；馆名和城市以服务端 metadata 为准。
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

- 新增一个博物馆，需要补齐服务端 metadata、爬虫入库和客户端完整体验；`MuseumID` 是字符串包装类型。
- 只有满足以下条件，才算这个博物馆真正接入完成：
  - 主 App 一级页可见，且名称、副标题符合中文文案要求。
  - 二级页可按现有规则完成首批加载、继续上滑加载、下拉刷新、页面设置记忆、类别多选、日志展示。
  - 详情页能稳定展示标题、艺术家、年代、材质、尺寸、类别、文化、国家、官网链接、版权声明，并提供 `AI` 按钮；`AI` 按钮使用 `apple.intelligence` 图标，点击后调用固定名称的快捷指令 `DoubaoMuseum`，传入 `介绍一下这个展品：当前详情页官方网页链接`。若返回 `未找到快捷指令`，则提示安装快捷指令；若返回 `该App无法打开` 或 `the app could not be opened`，则提示安装豆包 App。同时支持点击主图进入全屏预览后缩放、跟随手机旋转和保存图片。
  - Widget 支持该馆单馆 scope，并继续遵守同组共享、不同组隔离、手动 / 自动刷新、`network-only`、单件候选推进规则。
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
  - 每批后端列表请求仍然只能拉 `10` 条完整展品，不允许为了“凑满页面”而在同一批里额外追拉更多详情。
  - 如果该馆搜索结果池很大，必须考虑本地持久化缓存和页面级缓存，避免每次重进都从头拉。
  - 如果该馆有明显的慢接口或长链路，必须补页面内加载日志。
- 第 4 步：补齐详情页与图片行为。
  - 详情页至少满足 [主 App 规范第 4.4 节](docs/app-behavior-contract.md#44-展品详情页) 的要求。
  - 图片失败后在网络恢复时必须可重新加载，不能出现“一次失败后永久失败”的状态。
  - 如果详情页依赖网页抓取兜底，必须保留精确解析规则，不能把其他栏目误当作展品介绍。
- 第 5 步：补齐 Widget，而不是只做主 App。
  - 新馆如果要算正式支持，必须同时接入 Widget scope、同组共享、不同组隔离刷新、单件候选推进、失败态、成功态图片裁剪与降采样。
  - Widget 刷新仍然必须走 `network-only`，不能复用主 App 的搜索 / 详情缓存来“假装刷新成功”。
  - 单馆 scope 时，只能从当前博物馆和该馆当前生效类别中选候选。
  - 找到首个可渲染展品后必须立即停止，不能成功后继续拉第二个候选。
- 第 6 步：最后才决定是否对用户展示。
  - 不要因为代码里已经有 `MuseumID`、API 文件、实验数据源，就直接把它暴露到一级页或 Widget 配置里。
  - 是否属于“当前支持的博物馆”，以本文完成标准和 `1.3 当前阶段正式范围` 为准，不以代码存在与否为准。

### 2.3 常见漏改点

- 新增博物馆时，不能只改一个入口；至少要全局搜索下面这些关键词，确认所有分发点都覆盖：
  - `/v1/museums/metadata`
  - `museum_client_policies`
  - `data_sources`
  - `switch scope`
  - `WidgetGroupScope`
  - `supportsWidgetContent`
- 当前高频落点包括：
  - `server/crawler/stores.py`
    - metadata seed、`museums` 扩展字段、`data_sources`、`museum_client_policies`
  - `server/api/db.py` / `server/worker/src/index.js`
    - Python API（含腾讯云 SCF 部署包）是正式实现；`server/worker` 是已退役的 Cloudflare 实现，如重新启用必须保持 metadata 字段一致
  - `Shared/Museum.swift`
    - 只能保留字符串标识和通用格式化；馆名、副标题、Widget 支持、类别等正式数据必须来自 metadata，不能恢复本地六馆全集 fallback
  - `Shared/MuseumMetadataStore.swift`
    - App Group metadata 快照读写、Widget extension 读取路径
  - `Shared/ArtworkFeed/ArtworkFeedViewModel.swift`
    - 二级页批量加载、缓存恢复、分类切换后的刷新策略
  - `DailyMuseum/Views/ArtworkDetailLoaderView.swift`
    - 详情页必须优先走后端详情接口，避免重新引入按馆官方 API 分发
  - `Shared/Settings/WidgetMuseumScope.swift`
    - Widget 分组选馆从 metadata 快照读取可配置单馆，并保存到共享偏好
  - `DailyMuseumWidget/WidgetSettingsReader.swift`
    - Widget 侧分类读取、候选池准备
  - `DailyMuseumWidget/WidgetRefreshDeliveryTracker.swift`
    - Widget 刷新时的候选推进、metadata 图片优先级和 source 图片请求头
- 如果只把新馆写进客户端静态 fallback，而没有补服务端 metadata，往往会导致：
  - 一级页提前暴露未完成馆
  - Widget scope 拿不到动态配置项
  - 分类、瀑布流图片 QPS、图标、能力开关缺失
  - 深链接、详情页或刷新分发逻辑在运行时暴露问题

### 2.4 接入红线

- 不允许把分类 raw key 直接展示给用户，必须先补中文映射。
- 不允许只改 UI 文案、不改真实请求值或缓存键。
- 不允许绕过已有的分页、限流、缓存、兜底抓取约束。
- 不允许主 App 和 Widget 共用一套“看起来能跑”的偷懒逻辑：
  - 主 App 需要缓存与分批加载。
  - Widget 需要同组共享、不同组隔离与 `network-only` 刷新。
- 不允许把 provider 返回成功误判为 widget 已真正显示成功：
  - 新馆接入完成与否，仍然必须看桌面截图和系统日志。

## 3. 数据接入与分类规范

完整要求见 [数据接入与分类规范](docs/data-ingestion-contract.md)。修改后端、crawler、metadata、分类或部署前，必须读取该文档相关小节。

- 数据路径：离线 Python crawler → SQLite → Python API / 腾讯云 SCF → iOS 和 Widget；图片由客户端按 URL 拉取，SQLite 不存图片二进制。
- metadata 是馆名、分类、source、能力、图标、翻译语言和图片策略的唯一正式来源；禁止恢复客户端六馆静态 fallback 或官网抓源。
- 页面设置统一存入 App Group `feed.preferences.v2`；source 过滤在后端处理。Met 使用 `met_all` / `met_on_view`，奈良使用 `official` / `colbase`。
- 国博源站请求必须串行并遵守 API 总量预算，不能只靠 QPS；默认列表 `limit=100`、最多 `20` 次，详情 `share_link` 和全量抓取有额外显式开关，必须先读第 3.1.4 节。
- 真实 crawl 必须显式 `--allow-network` 并选择正数 `--max-details` 或 `--full`；全量完成以所有正式 target 的 `status completion=complete` 为准，样本不算。
- 服务端/schema/metadata/部署变更先通过本地 SQLite、simple auth Python API 和对应服务端验证，再更新腾讯云 SCF；只有同时涉及客户端改动时，才追加 iOS 测试/构建和必要模拟器验证。
- 正式 URL 的客户端配置为 `https://museum-api.zh0ngtian.tech`；本地覆盖用 `MUSEUMMUSE_BACKEND_BASE_URL`，双方使用同一个 `MUSEUMMUSE_SIMPLE_AUTH_SECRET`。真实 secret 只放未提交的 `Config/Secrets.local.xcconfig` 或环境变量。
- SCF 只读 SQLite 随代码包发布，COS nonce 原子写入保持最小权限；不得覆盖版本化发布对象或删除迁移基线。部署与签名回归入口见 [SCF 运维文档](server/tencent_scf/README.md)。
- Cloudflare Worker / D1 已退役，`server/worker` 仅作历史参考，禁止直接部署；App Attest 生产校验尚未完成，不能把 simple HMAC 描述成正式 App Attest。

## 4. 主 App 规范

完整要求见 [主 App 规范](docs/app-behavior-contract.md)。修改首页、二级页、设置、详情、收藏、图片或分享前，必须读取该文档相关小节。

- 首页、类别和 source 选择由 metadata 驱动；多 source 才显示数据源选择器，设置草稿只在点击 `完成` 后保存。
- 二级页每批只请求一次 `limit=10` 的后端列表，滚到底后继续上滑并松手才加载下一批；不自动追拉凑满。
- 页面缓存当前仅在进程内；重启恢复展品流缓存仍是待实现需求。文字先渲染，图片异步加载并支持失败后重试。
- 国博瀑布流缩略图按 metadata `qps=1` 排队；该策略不限制详情、全屏、首页图标或 Widget 图片。
- 详情走后端，保持 AI `DoubaoMuseum`、官网、系统翻译、收藏、分享、全局字号、全屏缩放和相册保存行为；精确文案及测试要求见第 4.4 节。
- source 切换不能隐藏旧收藏或改变已有深链接；当前引用不携带 source，详情由后端唯一 `(museum_id, object_id)` 解析。

## 5. Widget 规范

### 5.1 总体要求

- 全部构建统一提供 10 组静态小组件，由主 App 设置 → 小组件 →“分组与展示博物馆”分别选馆（默认所有博物馆，可选 metadata 支持 Widget 的单馆）。同组各尺寸同步，组间内容和刷新独立，即使选同馆也不合并；刷新通过链接打开主 App 完成，主体继续跳转展品详情。使用 `StaticConfiguration` / `TimelineProvider`，选馆与按钮刷新统一由主 App 完成。发布与真实验证限制见 [OTA 文档](docs/ios-adhoc-ota.md)。

- 需要提供 WidgetKit 小组件。
- 支持三种尺寸：
  - `systemSmall`
  - `systemMedium`
  - `systemLarge`
- 每组额外支持 iOS 27 `systemExtraLargePortrait` 竖向超大尺寸；较旧系统仍提供小、中、大三尺寸。
- 小组件用于随机展示一件展品。
- 当前小组件支持手动刷新，并可在首页全局设置中开启自动刷新。
- 自动刷新间隔支持：`关闭`、`1小时`、`3小时`、`6小时`、`12小时`、`24小时`，默认值为 `24小时`；用户明确保存为 `关闭` 时仍保持关闭。
- 自动刷新需要额外配置每日 `开始时间` 与 `结束时间`；默认值分别为 `00:00` 和 `23:00`。
- `开始时间` 与 `结束时间` 只支持选择整点。
- 小组件渲染状态和刷新任务以“组号 + scope”为共享键：
  - 同组多个桌面实例、各尺寸必须显示同一件展品。
  - 任一同组实例手动或自动刷新后，其他同组实例显示同一刷新结果。
  - 不同组的内容、任务、失败态和自动计划独立，即使选择同馆也不合并。
- 小组件首次安装或尚未成功拉到展品时，应显示中性占位态，例如：
  - `点击刷新获取展品`
  - 副标题提示：`点击刷新，在 App 中获取展品`

### 5.2 配置要求

- 主 App 为 10 组分别选馆。第 1 组保留旧 Widget kind 与选馆设置；第 2–10 组初始为全部。具体持久化、链接和迁移合同见 [主 App 规范](docs/app-behavior-contract.md#10-组小组件入口)。
- 桌面添加时选择组，展示范围在主 App 分组设置中配置。
- 如果新添加的小组件与桌面上已有实例属于同组：
  - 新实例需要直接复用这组当前共享内容
  - 不应因为是新实例而回退到独立占位态
- 展示范围支持：
  - 所有博物馆
  - 单个博物馆
- 每组选馆的默认项必须是 `所有博物馆`，不能显示参数标题占位文案。
- 主 App 分组选馆里的展示范围顺序需要跟随首页当前固定顺序，但保持平铺展示，不按国家分组。
- 小组件自动刷新间隔、开始时间、结束时间只在首页全局设置中配置，不放入分组选馆页。
- 单馆 scope 来自 metadata 中支持 Widget 的博物馆，名称与首页一致。
- 主 App 内各博物馆当前保存的类别选择仍然需要保留：
  - 小组件刷新时继续复用这些类别作为过滤条件
  - 奈良国立博物馆需要同时读取当前数据源，并读取该数据源对应的分类存储；馆方源和 ColBase 源分类互不污染
- 不再提供以下旧配置项：
  - 全局展示范围
  - 是否优先展示有图片的展品

### 5.3 刷新逻辑

- 刷新只针对链接指定组，实际桌面配置须同时匹配 kind 对应组号、scope 与尺寸；未添加的组不得发起网络刷新。每组独立保存内容、任务、失败态和自动计划；自动时间设置仍为全局，已展示展品历史仍按博物馆共享。
- 点击刷新按钮时，需要刷新当前共享组。
- 开启自动刷新后，由 WidgetKit timeline 调度触发，实际执行时间以系统调度为准。
- 开启自动刷新后，到 `开始时间` 时需要自动刷新一次，并在未超过 `结束时间` 前按当前刷新间隔继续刷新；若某次时间点恰好等于 `结束时间`，该次仍可执行。
- 开启自动刷新后，到期时需要刷新当前组，并继续复用同一套候选推进、图片校验和状态持久化规则。
- 当自动刷新设置为 `关闭` 时，小组件不应安排下一次自动 timeline 刷新，但手动刷新按钮仍然可用。
- 自动刷新节奏按固定时间表计算，不按“上次刷新成功时间 + 间隔”滚动顺延。
- 系统延迟执行导致多个时间点（含跨日）积压时，只补刷一次；在发起网络请求前，将下一次计划持久化为当前执行时刻之后的第一个合法时间点，不逐个补跑旧计划。刷新失败或 extension 重启也不得重新消费已合并的旧时间点。
- 自动刷新开始日志的计划时间必须包含日期和时间，便于区分跨日积压与同一天重复触发。
- 用户修改自动刷新间隔、开始时间或结束时间后，只从当前时刻之后的下一个合法时间点按新规则继续，不补触发当前时刻之前已错过的本日时间点。
- 用户手动刷新时，不得改变当前组的自动刷新节奏或下一次自动刷新时间点。
- 同一共享组连续点击刷新时，后一次必须立即抢占前一次：
  - 立即取消前一次仍在执行的搜索、详情、图片拉取和等待行为
  - 直接开始第二次刷新
- 小组件不再展示单独的“刷新中”可见状态：
  - 已有成功展品时，刷新过程中继续保留上一件展品，直到新结果成功或失败后再切换
  - 尚无成功展品时，刷新过程中继续保留占位态，不显示“刷新中”文案或转圈态
- 同组的多个实例需要共享状态与日志：
  - 不允许同组实例各自保留不同展品或不同刷新任务
- 不同组之间互不影响：
  - 不允许一个组的刷新取消、覆盖或污染另一个组的状态和日志
- 任意刷新入口触发刷新时，包括小组件按钮、自动刷新或调试入口的批量 / 按 scope 刷新，都必须先通过 WidgetKit 获取当前桌面实际存在的小组件配置，再只刷新这些配置对应的组与 `scope`：
  - `WidgetInstances/instances.json` 只表示曾经渲染或登记过的共享状态，不等于当前桌面仍存在该组小组件
  - 如果系统当前配置中没有某个组与 `scope`，即使持久化状态里仍残留该组与 `scope`，也不能触发该组与 `scope` 的网络刷新
  - 刷新入口需要记录本次 WidgetKit 返回的 组号 / `scope` / 尺寸摘要，方便真机日志判断系统实际认为哪些小组件存在
- WidgetKit 的 snapshot、preview 或非当前配置 timeline 渲染请求不能直接登记为真实桌面实例：
  - 写入 `WidgetInstances/instances.json` 或记录 `Widget 完成渲染` 前，也需要确认该组 / `scope` / 尺寸仍存在于当前桌面配置中
  - 非当前配置的渲染请求只允许读取已有共享状态用于展示，不能新建或更新共享状态
  - 获取当前配置后，应清理不在当前配置中的历史共享状态，避免已删除的组残留后续误触发刷新
- 小组件刷新必须走 `network-only`：
  - 刷新时直连服务端，不复用主 App 搜索 / 详情缓存来选取展品
  - 仅允许持久化当前共享组上一次渲染结果和刷新状态，供 WidgetKit 重绘
- 中国国家博物馆小组件刷新不再直连 `exhibit_list` 或详情源站，必须通过服务端候选 / 列表接口获取服务端已入库展品。
- 国博源站 API 调用量控制属于离线爬虫职责；不能在 Widget provider 中重新实现国博源站随机页候选逻辑。
- 小组件刷新必须跟随当前 metadata source：
  - network-only 候选请求需要携带当前 `sourceKey` 和当前 source 下的生效类别
  - 单馆 scope 时，只能使用当前 source 下当前生效类别
  - Widget 图片 URL 优先级使用 `sources.preferredImageURLOrder`
  - Widget 图片请求头使用 `sources.imageRequestHeaders`
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
- 三种尺寸的小组件只要属于同一个组，就必须显示同一件展品；不同组独立刷新。
- 小组件点击主体区域后，应直接进入 App 内对应展品的详情页。
- 小组件不应只停留在 App 首页。

### 5.5 视觉

- 桌面小组件内容不显示组号；组名仅在添加小组件与主 App 分组设置中用于选组。
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
- 深链接需要保留原始 `museumID` 和 `objectID`；当前引用不携带 `sourceKey`，详情 loader 不传 source，后端按唯一 `(museum_id, object_id)` 推断。当前 source 设置不得改变旧链接/收藏的目标；新增真实 source 必须避免同馆 objectID 冲突，无法避免时需先扩展引用与收藏标识。
- 深链接目标必须能在以下场景下正常工作：
  - App 已在前台
  - App 在后台
  - App 冷启动

### 5.7 常见坑

- 多个 Widget 的名称用 `Text(verbatim:)` 传给 `configurationDisplayName`；直接使用字符串插值会在 iOS 27 注册描述时触发 formatted text fatal error，导致整个扩展不出现在小组件库。

- 不能把 provider 返回 `success` 误判为“桌面一定已正常显示”：
  - `Widget 完成渲染` 日志只能说明 timeline 已生成。
  - 真正的验收仍然要看 SpringBoard 桌面截图。
- 小组件成功态如果直接使用远端原始大图，容易触发 WidgetKit/Chrono 归档失败：
  - 常见系统日志关键字包括：
    - `Widget archival failed due to image being too large`
    - `imageTooLarge`
  - 成功态背景图必须在图片下载成功后、写入 App Group 前先降采样到受控像素尺寸，渲染时直接读取已降采样文件并交给 SwiftUI `scaledToFill` 裁剪，避免在 Widget View 内再次 `UIImage(data:)` + 重绘导致真机 Widget 内存峰值过高、`idle`、归档失败或进程被系统终止。
  - 当前归档安全上限同时约束最大边和总像素面积：最大边不得超过 `1024`，总像素不得超过 `1,000,000`；只限制最大边不足以覆盖接近正方形的图片。
  - Widget provider 读取成功态实例时必须同步检查并迁移旧版本遗留的超限 App Group 图片；不能要求用户等待下一次网络刷新才能消除旧图片造成的归档失败。
  - 图片降采样测试必须至少覆盖横图、竖图和接近正方形图片，并同时断言最大边和总像素面积；模拟器闭环仍需确认系统日志没有 `imageTooLarge`，不能只看单元测试或 `Widget 完成渲染`。
- Widget 当前不再按隐藏 `instanceToken` 隔离内容：
  - provider 必须按组号与 `scope` 命中共享状态；旧 scope 状态迁移到第 1 组
  - 共享键不包含尺寸，同组实例显示同一份内容
- 用 `scope` 级别调试刷新时，同 scope 的多个桌面实例会被一起触发：
  - 同组刷新和日志共享是预期行为；`--instance-token` 使用包含组号的共享键，不能隔离同组的单个桌面实例。
  - 需要稳定复现时，定向选择当前共享组，并避免并发触发同组刷新。
- Widget 相关 request logs 当前需要显式打印共享刷新键：
  - 底层日志字段仍沿用 `instanceToken`
  - 值为 `compat:<组号>|<scope>`，例如 `compat:2|single:met`。日志需同时包含共享键、scope 和尺寸，不能把同馆不同组折叠。
- Widget 的 request logs、实例状态和主 App 日志页依赖主 App 与 Widget Extension 共享同一个 App Group：
  - 构建必须同时保留 `DailyMuseum/DailyMuseum.entitlements` 和 `DailyMuseumWidget/DailyMuseumWidgetAppGroup.entitlements` 中的 `group.tech.zh0ngtian.MuseumMuse`；私有 OTA 允许签名器同时写入已获 profile 授权的共享组，运行时读取两个目标一致的 `MuseumAppGroupIdentifier`，具体命名空间、迁移与隔离限制见 OTA 文档。
  - 任一 target 丢失该 App Group 后，主 App 将无法读取 widget 写入的 request logs 与实例状态
- SpringBoard 和 WidgetKit 都存在快照缓存：
  - 代码修好后，桌面仍可能短时间继续显示旧占位态或旧快照。
  - 这时需要结合重新安装 App、重新拉起 App、重新请求 timeline、必要时重启模拟器或强制回桌面后再次截图来判断。
- 小组件去掉可见“刷新中”态后，桌面仍可能只看到旧展品或占位态：
  - 这不代表刷新已经成功完成。
  - 成功态往往才会暴露图片归档、图片尺寸、图片解码和状态回退等问题。

## 6. 验证与交付

完整流程见 [验证与交付](docs/verification-and-delivery.md)。修复问题或新增功能交付前必须阅读，Widget 变更必须执行其中第 6.3 节。

- 涉及客户端改动时，默认使用本机 `iPhone 17 Pro` 模拟器构建、安装、启动、截图；单元测试关闭 parallel testing，避免 clone simulator 问题。不涉及客户端时不触发客户端构建。
- 保留交互现场时用 `xcodebuild build` / `build-for-testing` + `simctl install` + `simctl launch`；确需单测才用 `xcodebuild test`，之后可能需要重新启动模拟器。
- 沙箱内 CoreSimulator / runtime / destination 异常先按权限流程用沙箱外 Xcode CLI 复核，不直接认定代码失败。
- AI 快捷指令实际拉起、联网/相册权限等模拟器不能稳定覆盖的场景，再用 `Yao iPhone 17 Pro` 真机补验。
- Widget 验收必须同时有构建/安装/启动、request logs、SpringBoard 桌面截图和系统日志；provider success 不等于已显示，需确认没有 `imageTooLarge`、归档或 Chrono 错误。
- `scripts/pull_simulator_request_logs.sh` 的 `--instance-token` 为共享键，统一为 `compat:<组号>|<scope>`，不能隔离同组的单个实例；具体参数见验证文档。
- 夜间真机安装修改还需阅读 [夜间安装文档](docs/ios-nightly-installer.md)，保持只构建安装、不主动启动，以及描述文件续签失败时恢复缓存。
- 纯文档修改检查链接、代码依据和 `git diff --check`；不将未执行的模拟器、真机或线上验证写成已通过。
- 日常 push / PR CI 只执行一次 `generic/platform=iOS` 无签名 Release 构建；CI 成功只表示编译、链接通过，功能按改动范围在本地验证。Swift / Python 和模拟器回归仅手动按需运行 `iOS Regression`；IPA 打包、版本检查、校验和、元数据及附件上传只在 `vX.Y.Z` 标签的 `iOS Release` 执行，日常构建只在失败时上传日志。
- Ad Hoc / OTA 接入状态与签名前置检查见 [Ad Hoc 发布文档](docs/ios-adhoc-ota.md)。`scripts/publish_ios_widget_ota.py` 负责 OTA 验签与发布；交付同时要求对应提交的 [GitHub iOS 构建检查](docs/verification-and-delivery.md#64-github-ios-构建检查) 通过。各版本的真机覆盖范围以 OTA 文档的实际记录为准。默认 profile 不授权项目原始身份，不能将私有兼容渠道描述为原始身份的正式 Ad Hoc 导出。不得删除 Widget、移除必要 App Group 或将主 App profile 自动套给扩展以绕过签名缺项。
