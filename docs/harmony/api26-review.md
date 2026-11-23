# API 26 技术规范对照 · 全盘代码梳理

> 对象：青芒短视频（HarmonyOS 7 / API 26 / ArkTS + ArkUI V1）
> 日期：2026-11-06
> 结论口径：**已修 / 评估后不改 / 待真机验证** 三类分开写，不把「改了」说成「验过了」。

---

## 一、方法与来源可信度

华为文档中心是 SPA，正文由 JS 动态渲染，`WebFetch` 只能取到页面骨架。本轮采用三方交叉：

| 来源 | 用途 | 可信度 |
|---|---|---|
| 官方文档原文片段（搜索结果缓存） | 规范条文本身 | 高 |
| 本机 SDK `D:\DevEco Studio\sdk\default\openharmony\ets\api\*.d.ts` 的 JSDoc | 接口签名、`@since`、枚举值 | 高（机器可复核） |
| `toolchains/modulecheck/module.json` 的 JSON Schema | 配置项合法枚举 | 高 |
| 开发者论坛 / 官方博客 | 实践说明与默认值佐证 | 中，仅用于旁证 |

**未取到完整原文的条目一律不写成定论**，下文会标注。

---

## 二、逐条对照

### 2.1 应用配置与网络

| 规范要求 | 工程现状 | 处理 |
|---|---|---|
| `cleartextTraffic` 缺省为 `false`；官方《Remote Communication Kit 开发准备》明确「HTTP 是明文传输协议，通常需禁用」，API 20 起 `component-config` 可管到 Network Kit | 扫描发现全工程**唯一**一个 `http://` 字面量是 `ContentApi.ets` 里的 `PLAYBACK_API` 常量，且**未被任何代码引用**（死常量） | ✅ **删除死常量**。因此**不需要**新增 `network_config.json` 放行明文——为一个不存在的请求开全局明文是白白降级安全性 |
| 权限按需声明 | 只声明 `INTERNET`、`GET_NETWORK_INFO`，无冗余权限 | ✅ 符合 |
| `deviceTypes` / 多窗方向 | 已按官方文档改为 `landscape_auto` + `enableLandscapeMultiWindow()` | 见 `docs/harmony/window-and-car.md` |

> 这一条值得单独记：如果只看「有个 http://」就顺势加 `cleartextTrafficPermitted: true`，反而会引入一个真实的安全配置缺口。全盘梳理的价值在这里。

### 2.2 生命周期与资源释放

| 规范要求 | 工程现状 | 处理 |
|---|---|---|
| 组件销毁后不应再有异步回调写状态 | `PlayerView.closeSettings()` 和 `toggleFullscreen()` 各有一个 `setTimeout`，**未登记 timer、未在 `aboutToDisappear` 清理**。前者回调写 `settingsOpen`（@State），后者回调重算弹幕轨道 | ✅ 新增 `sheetCloseTimer` / `fullscreenTimer`，`aboutToDisappear` 统一清理；全屏回调加 `released` 守卫 |
| AVPlayer 事件监听成对注销 | `on('stateChange'…)` 5 个，`releasePlayer()` 里 `off` 5 个，成对 | ✅ 符合 |
| 弹幕 ticker / 提示 timer | `danmakuTimer` / `dmHintTimer` / `hideTimer` 均有清理 | ✅ 符合 |
| 窗口事件监听 | `EntryAbility` 的 `windowSizeChange` 等挂在 window 生命周期上，Ability 销毁随窗口释放 | ⚠️ 低风险：`onWindowStageDestroy` 未显式 `off`，建议后续补；本轮未动 |

### 2.3 无障碍

| 规范要求 | 工程现状 | 处理 |
|---|---|---|
| 纯图标控件必须提供无障碍文本，否则读屏无语义 | 全工程扫描 `accessibilityText / accessibilityDescription / accessibilityLevel` **零命中** | ✅ 已补：播放页 7 个圆钮（返回 / 弹幕开关 / 设置 / 上一集 / 下一集 / 全屏）、中央播放键（随播放态播报「播放 / 暂停」）、底部导航项（含「当前选中」）、首页自绘搜索框。`roundButton` 的 `label` 改为**必填参数**，从签名上防止以后新增图标钮又漏掉 |

> 说明：本轮只覆盖主要交互入口。Slider、TagChip、设置面板关闭钮等仍有缺口，已在下方「待办」列出。

### 2.4 性能

| 规范要求 | 工程现状 | 处理 |
|---|---|---|
| 官方《布局优化指导》：**ForEach 适合两屏以内**；超过两屏用 `LazyForEach` + `@Reusable` + `cachedCount` | 首页是分页信息流（每页 54 条，可持续追加），用 `Flex(wrap)` + `ForEach`，全工程 19 处 `ForEach`、**0 处 `LazyForEach`** | ⚠️ **结构性技术债，本轮不改**。原因：`LazyForEach` 只能用于 List/Grid/WaterFlow 等容器，`Flex` 用不了；改造需换成 Grid + 实现 `IDataSource`，会同时改动自适应列数、分页合并、断点布局。没有真机 Profiler 基线就盲改，可能比现状更差。改造条件写在「待办」 |
| 官方《性能提升建议》：源图远大于显示尺寸时开 `autoResize(true)` 降采样 | 5 处封面 `Image` 均未开 | ✅ 已补 5 处（详情页 ×2、历史、继续观看、PosterCard） |
| 动画阶段只改 `translate / scale / opacity`，不改宽高/position | 按压动效全部是 `scale` + `.animation()`；控件显隐是 `opacity` + `offset`；设置面板是 `translate` | ✅ 符合 |
| 图片解码不放在 `build` / 滚动回调 | 无同步解码、无同步 IO | ✅ 符合 |

### 2.5 语言与状态管理

| 规范要求 | 工程现状 | 处理 |
|---|---|---|
| ArkTS 严格类型，不用 `any` / `unknown` / 非空断言绕过 | 全量扫描 **零命中** `@ts-ignore`、`as any`、`: any` | ✅ 符合 |
| `ForEach` 必须给稳定 key | 19 处均提供 key（`seriesId` / `genre.key` / `item.label` 等） | ✅ 符合 |
| `@State` 不放不参与渲染的大对象 | `PlayerView` 把 `danmakuAll` / `danmakuCursor` / timer / 请求号都声明为 `private`，只有 `danmakuLive` 是 `@State` | ✅ 符合，弹幕这块做得对 |

---

## 三、代码结构评估（命名与注释规范）

**做得好的**：命名语义清楚（`resetDanmaku` / `indexOfTime` / `ensureTagResults`），关键算法有「为什么这么做」的注释而非复述代码；文件按 `net / model / store / theme / view / pages` 分层；`Glass.ets` / `Tags.ets` 把可变规则抽成独立模块。

**仍存在的问题**：

1. **`PlayerView.ets` 约 2431 行**，一个组件里塞了播放控制、弹幕引擎、设置面板、选集、全屏、画质、XComponent surface 管理。官方虽无硬性行数规定，但这已经超出可维护范围。建议按 `DanmakuEngine` / `PlayerControls` / `SettingsSheet` 拆。本轮不动（无真机验证，拆分风险高于收益）。
2. **硬编码基准宽度**：`SettingsView.innerWidth()` 里写死 `360`，应改取 `Breakpoints` 或 `onAreaChange` 的实际宽度。窄窗车机上会算错 chip 宽度 → **建议优先修**。
3. **空 catch 吞异常**：多处 `catch (error) { // 忽略 }`。多数有合理降级（版本读取、缓存统计），但排查线上问题时缺日志。建议至少 `hilog.warn` 打 code。
4. 注释里仍有少量口语化表述（「白建定时器」「糊一屏」），团队内部可读，若要对外开源需统一为书面语。

---

## 四、本轮已修（均可编译验证）

| # | 改动 | 文件 |
|---|---|---|
| 1 | 删除未被使用的明文 HTTP 常量，明确全站 HTTPS | `net/ContentApi.ets` |
| 2 | 两个延时回调登记 timer + 销毁清理 + released 守卫 | `view/PlayerView.ets` |
| 3 | 8 类控件补无障碍文本，`roundButton.label` 改必填 | `PlayerView / HomeView / pages/Index` |
| 4 | 5 处封面 `Image` 开 `autoResize(true)` | `DetailView / HistoryView / HomeView / Widgets` |
| 5 | 签名口令改环境变量优先 `GUOAPP_KEY_PWD` | `scripts/build.sh` |
| 6 | 玻璃染色 / 模糊 / 描边参数重构，导航条上亮下暗 | `theme/Glass.ets / pages/Index.ets` |
| 7 | 题材筛选从「零命中」修到真实可用：解析 `category_schema`、纳入标题、按实测词频重写别名 | `net/ContentApi.ets / model/Tags.ets / view/HomeView.ets` |
| 8 | 应用改名「青芒短视频」、新图标、「我的」页版本信息 | 资源 / `Index.ets` / `SettingsView.ets` |
| 9 | `SettingsView.innerWidth()` 去掉硬编码 360，按实际窗口宽算 | `view/SettingsView.ets` |

`BUILD SUCCESSFUL`（每步均已单独编译）。

---

## 五、评估后明确不改的项

| 项 | 不改的原因 |
|---|---|
| 首页 `ForEach` → `LazyForEach` | 需要换容器 + 实现 `IDataSource` + 重做自适应列数与分页合并；无真机 Profiler 基线，盲改风险高于收益 |
| `PlayerView` 拆分 | 2431 行确实该拆，但属于纯结构性重构，无设备回归验证时不宜动核心播放链路 |
| `bundleName` | 改名会影响升级链与已存数据，详见 `compliance-review.md` |
| 协议相关字符串（主机名 / UA / `display_name`） | 属于通信协议一部分，逐字依赖上游，改了接口立即失效 |

---

## 六、题材筛选实测（本轮最重要的一次纠错）

标签栏刚写完时，本地单元测试 8/8 通过、编译也过——但拿真实接口数据一跑，**12 个题材命中数全是 0**。原因是把数据来源猜错了：

| 字段 | 实测结果 |
|---|---|
| `tags` / `category_list` | 全部为空 |
| `category_name` | 一律是「短剧」 |
| **`category_schema`** | 一段 JSON 字符串，含官方题材数组；161 部样本里共 138 种不同题材 |

也就是说，按前三个字段做的筛选是个**点什么都没结果的假功能**。改为解析 `category_schema[].name`，并把标题纳入筛选来源（源站题材表里没有「修仙」「科幻」，但标题里大量出现），再按真实词频重写别名映射后：

```
三频道共 161 部样本：
玄幻 23 | 言情 30 | 科幻  7 | 悬疑 23 | 恐怖  8 | 修仙  4
都市 83 | 古装 29 | 穿越 24 | 重生 14 | 逆袭 59 | 甜宠  9
```

期间还修了一次「串味」：科幻别名里放了「系统 / 异界 / 异能」，命中数虚高到 42，点开全是修仙和穿越剧；收紧到「未来 / 星际 / 机甲 / 末世 / 灾难」后降到 7 条，少但准。

> 这条经验值得记：**离线单元测试通过 ≠ 功能可用**。凡是依赖外部数据形状的筛选 / 映射，都必须拿一次真实响应跑通。

## 七、必须真机 / 模拟器确认

1. `backgroundEffect` 在真实像素密度下的模糊质量与饱和度表现
2. 车机超级桌面满屏、窄窗下设置面板可用性
3. `accessibilityText` 在系统读屏下的实际播报
4. `autoResize(true)` 对封面清晰度的影响
5. 题材筛选翻到 3 页以后的结果数（Node 侧只取了每个频道第一页）

## 八、建议的下一步（按优先级）

1. 补齐剩余控件的无障碍文本（Slider、TagChip、面板关闭钮）
2. 拿到真机后先用 Profiler 录首页快滑 Trace，再决定要不要做 `LazyForEach` 改造
3. `EntryAbility.onWindowStageDestroy` 补窗口事件 `off`
4. 首页 `Flex(wrap)` 换 Grid 后接 `LazyForEach`，解决超长信息流的组件数量问题
