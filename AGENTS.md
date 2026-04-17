# DailyMuseum Product Requirements

## 产品定位

- `DailyMuseum` 是一个 iOS App，用于展示各大博物馆的展品。
- 第一版当前只支持 `大都会艺术博物馆`。
- 应用需要同时提供主 App 和 Widget 小组件体验。

## 当前支持的博物馆

- 已支持博物馆：
  - 名称：`大都会艺术博物馆`
  - 副标题：`美国 纽约`
  - 名称：`东京国立博物馆`
  - 副标题：`日本 东京`
  - 名称：`中国国家博物馆`
  - 副标题：`中国 北京`
- 当前数据源：
  - `The Met Collection API`
  - `Japan Search Web API`
  - `中国国家博物馆列表接口`
  - `中国国家博物馆 H5 分享页接口`

## 数据获取方式

### 大都会艺术博物馆

- 大都会当前主数据源是 `The Met Collection API`：
  - 搜索展品 ID：
    - `https://collectionapi.metmuseum.org/public/collection/v1/search`
  - 拉取展品详情：
    - `https://collectionapi.metmuseum.org/public/collection/v1/objects/{objectID}`
- 大都会详情页中的“展品介绍/官网概述”不完全依赖公开 API：
  - 当公开 API 未返回可用介绍字段时，需要继续访问官网页面：
    - `https://www.metmuseum.org/art/collection/search/{objectID}`
  - 当前会从官网页面的 object overview 区块中提取描述内容，作为详情页补充信息来源。
- 后续如果修改大都会详情逻辑：
  - 不能假设公开 API 已包含完整介绍文案。
  - 不能删除官网页面抓取这条兜底链路，除非确认官方 API 已能稳定返回同等信息。
  - 不允许把 `Overview / Provenance / References / Catalogue Entry` 等其他官网区块误当作展品介绍。

### 东京国立博物馆

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

### 中国国家博物馆

- 中国国家博物馆当前接入接口：
    - `https://appapi.chnmuseum.cn/api/exhibit_list?cate_id={类别ID}&limit={一次拉取的数量}&p=i&son_cate_id=0`
    - `https://appapi.chnmuseum.cn/api/exhibit/share_link?p=i&exhibit_id={id}`
- 当前 App 对列表接口的用途：
    - 批量拉取展品列表
    - 分页获取展品 ID 池
    - 按分类构建二级页候选数据池
- 当前 App 对该接口的用途：
    - 拉取展品详情页 HTML
    - 从 HTML 中解析标题、年代、分类、尺寸、图片、展品介绍
- 该接口的 QPS 限制要求：
    - 中国国家博物馆对 QPS 非常敏感，必须视为严格限流接口
    - 客户端请求频率必须控制在 `1 QPS`
    - 不允许对该接口并发突发请求，避免 IP 被封禁
    - 后续如修改中国国家博物馆相关加载逻辑，必须保留或强化现有限流机制，不能绕过

## 博物馆分类要求

### 通用规则

- 二级页面中的类别名称必须展示中文，不直接向用户展示原始分类 key。
- 数据拉取、缓存键、筛选请求需要继续保留并使用各馆原始分类值。
- `全部` 不是远端真实分类：
  - 仅作为 UI 展示态
  - 等价于当前博物馆下所有可选分类全部选中
- 如果后续新增或调整分类映射：
  - 必须同时更新展示中文名
  - 必须同时更新请求所使用的原始值
  - 不允许只改 UI 文案、不改实际筛选值

### 大都会艺术博物馆分类

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

### 东京国立博物馆分类

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

### 中国国家博物馆分类

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

## 主 App 信息架构

- App 主界面为两级结构：
  - 一级页面：博物馆列表
  - 二级页面：某个博物馆的展品列表
- 点击二级页面中的展品后，进入展品详情页。

## 一级页面要求

- 展示已支持的博物馆列表。
- 当前博物馆文案要求：
  - 主标题显示：`大都会艺术博物馆`
  - 副标题显示：`美国 纽约`
  - 主标题显示：`东京国立博物馆`
  - 副标题显示：`日本 东京`

## 二级页面要求

- 二级页面展示该博物馆的展品流。
- 布局形式为瀑布流。
- 页面必须适配最新 iPhone 全面屏，不允许出现上下大黑边。
- 页面必须支持正常滚动，不允许出现上滑后无法继续触发加载的问题。
- 二级页面需要提供单独的“页面设置”入口。
- 当前二级页面中的以下能力需要放入“页面设置”中统一管理：
  - 视图切换
  - 类别筛选

### 二级页面设置交互规则

- 页面设置中的“显示”需要支持记忆功能。
- 页面设置中的“类别筛选”需要支持多选。
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
- 如果用户没有点击 `完成`，而是直接通过下滑手势关闭页面设置：
  - 本次设置修改不生效
  - 不允许写入记忆状态
  - 二级页面继续保持进入设置前的显示和筛选状态

### 数据加载规则

- 进入二级页面时，不要一次性抓取所有详情数据。
- 首次只加载少量展品：
  - 当前约定为 `10` 个。
- 后续继续浏览时，滚动到底部再加载下一批。
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
- 东京国立博物馆的数据池也不允许预拉取：
  - Japan Search 搜索分页大小按 `10` 条处理。
  - 首次进入只准备首批所需的 `10` 条候选数据。
  - 后续每次继续浏览时，也只按下一批所需数量增量补齐，不要额外预备 `30` 条或更多数据。

### 排序与展示规则

- 需要提供一个设置开关：
  - `随机展示展品`
- 当开关开启时：
  - 展品按随机顺序展示。
- 当开关关闭时：
  - 展品按 `objectID` 顺序展示。
  - 当前约定为 `objectID` 升序。

### 二级页缓存与性能要求

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

### 二级页日志要求

- 在等待拉取全量 `objectIDs` 时，页面中需要显示相关日志。
- 日志至少应覆盖：
  - 检查内存缓存
  - 检查本地缓存
  - 开始从大都会艺术博物馆拉取全量 `objectIDs`
  - 拉取完成并写入缓存
  - 开始整理随机或顺序数据
  - 开始拉取首批展品详情
  - 首批或下一批详情加载完成
  - 加载失败原因

### 二级页图片要求

- 某些展品图片因网络问题加载失败后，网络恢复时需要支持重新加载。
- 不能出现“某张图失败后永远不再重试”的情况。

## 展品详情页要求

- 点击展品后进入详情页。
- 详情信息通过 API 抓取。
- 详情页至少展示：
  - 标题
  - 艺术家
  - 年代
  - 材质
  - 尺寸
  - 部门
  - 文化
  - 国家
  - 馆藏
- 详情页支持跳转到官网原始链接。

## 小组件总体要求

- 需要提供 WidgetKit 小组件。
- 支持三种尺寸：
  - `systemSmall`
  - `systemMedium`
  - `systemLarge`
- 小组件用于随机展示一件展品。
- 小组件的刷新间隔和展示范围可在 App 内设置。

## 小组件配置要求

- App 内需要提供小组件设置页。
- 可配置项至少包括：
  - 刷新间隔
  - 展示范围
  - 是否优先展示有图片的展品
- 展示范围支持：
  - 所有博物馆
  - 单个博物馆

## 小组件内容与交互要求

- 三种尺寸的小组件在同一个刷新周期内必须显示同一件展品。
- 小组件需要支持手动刷新按钮。
- 点击刷新按钮后，应刷新到新的展品。
- 小组件点击主体区域后，应直接进入 App 内对应展品的详情页。
- 小组件不应只停留在 App 首页。

## 小组件视觉要求

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

## 深链接要求

- 小组件点击主体区域时，需通过 App 内深链接跳转到对应展品详情。
- 深链接目标必须能在以下场景下正常工作：
  - App 已在前台
  - App 在后台
  - App 冷启动

## 小组件刷新常见坑

- 不能把 provider 返回 `success` 误判为“桌面一定已正常显示”：
  - `Widget Provider` 日志只能说明 timeline 已生成。
  - 真正的验收仍然要看 SpringBoard 桌面截图。
- 小组件成功态如果直接使用远端原始大图，容易触发 WidgetKit/Chrono 归档失败：
  - 常见系统日志关键字包括：
    - `Widget archival failed due to image being too large`
    - `imageTooLarge`
  - 成功态背景图必须先按小组件目标比例裁剪，并降采样到受控像素尺寸后再渲染。
- 当 widget 配置里的隐藏 `instanceToken` 缺失、变化或未正确回传时：
  - provider 可能只能按 `scope` 收养最近一次可展示状态。
  - 这类回退逻辑必须优先采用最近一次 `success`，不能优先采用较新的 `refreshing`，否则桌面容易长期停在“刷新中”。
- 用 `scope` 级别调试刷新时，同 scope 的多个实例可能被一起触发：
  - 容易污染日志。
  - 也容易让当前可见桌面实例被后续刷新覆盖。
  - 需要稳定复现时，优先按 `instanceToken` 定向触发。
- SpringBoard 和 WidgetKit 都存在快照缓存：
  - 代码修好后，桌面仍可能短时间继续显示旧占位态或旧快照。
  - 这时需要结合重新安装 App、重新拉起 App、重新请求 timeline、必要时重启模拟器或强制回桌面后再次截图来判断。
- 小组件“刷新中”能显示，不代表“成功态”也一定能显示：
  - 这两条渲染路径不同。
  - 成功态往往才会暴露图片归档、图片尺寸、图片解码和状态回退等问题。

## 文案要求

- 博物馆名称使用中文：
  - `大都会艺术博物馆`
- 博物馆副标题只显示国家和城市：
  - `美国 纽约`
- 不再显示 `The Met`
- 不再在副标题中重复展示博物馆名称。

## 验证要求

- 后续每次修复问题或新增功能后，都需要优先使用真机 `Yao iPhone 17 Pro` 作为默认构建和运行目标再交付。
- 如果真机暂时不可用，再退回使用 `iPhone 17 Pro` 模拟器验证。
- 使用模拟器做交互验证时，默认采用 `xcodebuild build` + `xcrun simctl install` + `xcrun simctl launch` 链路，不默认使用 `xcodebuild test`。
- 原因：
  - `xcodebuild test` 会接管并可能克隆/回收模拟器，测试结束后目标模拟器可能被自动关闭。
  - 如需保持当前模拟器桌面状态、继续截图或继续观察 widget 刷新结果，应优先避免在验证中途运行 `xcodebuild test`。
- 只有在明确需要跑单元测试或 UI 测试时，才使用 `xcodebuild test`；跑完后需要预期模拟器可能回到 `Shutdown` 状态，并按需重新 `boot/install/launch`。
- 当前默认验证设备：
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

### 小组件截图闭环测试

- 验证小组件问题时，默认要形成“构建/安装/启动 + 日志 + 桌面截图 + 系统日志”的闭环，不接受只看 provider 日志就下结论。
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
    - `--instance-token <TOKEN>`：按实例定向触发刷新
    - `--scope-raw-value <RAW>`：按 scope 触发刷新，例如 `single:shm`
    - `--wait <SECONDS>`：刷新后等待
    - `--tail <N>`：输出最后 N 条日志
    - `--instances`：输出 `instances.json`
    - `--screenshot-path <PATH>`：保存截图
    - `--home-screen`：截图前尝试回到桌面
- 推荐闭环步骤：
  - 1. `build-for-testing + install + launch`
  - 2. 用 `scripts/pull_simulator_request_logs.sh --instances` 确认当前 widget 实例和 `instanceToken`
  - 3. 优先用 `--instance-token` 定向触发当前可见实例刷新，避免同 scope 多实例互相污染
  - 4. 用脚本或 `xcrun simctl io ... screenshot` 抓图
  - 5. 检查 request logs，确认：
    - 候选拉取顺序符合预期
    - 成功后没有继续多拉
    - provider 至少生成过对应 family 的 timeline
  - 6. 再查系统日志，确认没有 `imageTooLarge`、归档失败或 Chrono 渲染错误
  - 7. 最后以桌面截图作为最终验收证据
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

## 当前阶段范围说明

- 当前版本需要保证以下博物馆体验完整可用：
  - `大都会艺术博物馆`
  - `东京国立博物馆`
