# 青芒短视频 · HarmonyOS 7 手机版（支持鸿蒙智行车机超级桌面）

基于 [Xanerix/guoapp](https://github.com/Xanerix/guoapp)（上游开源实现）重写的鸿蒙原生**手机客户端**，
面向 **HarmonyOS 7（API 26）**，装在手机上使用；手机连上鸿蒙智行座舱后，可通过**超级桌面**把画面投到车机大屏。

> 定位：**手机 App**，通过超级桌面的**应用流转**在车机大屏上显示（不是车机原生安装）。
> `deviceTypes` 现为 `phone / tablet / 2in1 / car`：早期只声明前三项时，座舱把应用当
> 「未适配的手机应用」塞进 9:18 兼容窗口，看上去就是屏幕中间一条竖条。
> 车机适配的完整依据与验证脚本见 `docs/harmony/window-and-car.md`。

原项目以 GPL-3.0 发布，本项目同样遵循 GPL-3.0。

---

## 一、为什么是重写而不是移植

原仓库不是单一 App，而是三层结构：

| 层 | 技术 | 规模 | 鸿蒙可用性 |
|---|---|---|---|
| UI | Flutter / Dart | 108 文件 / 30557 行 | ❌ 依赖 `media_kit`（libmpv）、`ffmpeg_kit`，OHOS 无原生库 |
| 业务核心 | Go，FFI 导出 `DuanjuRequest` | 130 文件 / 24657 行 | ❌ 编译产物是 arm64 glibc 动态库，OHOS 用户态不兼容 |
| 数据源 | 字节系接口 + X-Gorgon/X-Argus/X-Ladon 风控 | — | ✅ 可用 ArkTS 重写 |

`flutter-ohos` 能把 UI 编出来，但一进入播放页就会因为没有 mpv / ffmpeg 原生库而崩，
所以走 **ArkTS 原生重写** 这条路，只保留车机场景真正需要的链路。

## 二、已实现

- **设备注册**：向 `log.snssdk.com` 注册伪设备，拿 `device_id` / `install_id` 并持久化
- **风控签名**：X-Gorgon（20 字节载荷异或 + 4 位循环 + 位反转）、X-Argus（protobuf + 自研 Feistel + AES-128-CBC）、X-Ladon（34 轮 Feistel），SM3 / MD5 / AES 全部纯 TS 实现
- **信息流**：真人剧 / 漫剧 / AI 剧三个频道，分类分页；首页列表、筛选态与滚动位置按进程缓存，
  切 Tab / 从详情返回不再重新请求（重复点当前分类可强制刷新，见 `store/HomeCache.ets`）
- **题材筛选**：玄幻 / 言情 / 科幻 / 悬疑 / 恐怖 / 修仙 / 都市 / 古装 / 穿越 / 重生 / 逆袭 / 甜宠，首页横向标签栏；冷门题材自动多翻几页再判空（见 `model/Tags.ets`）
- **液态玻璃**：全站按钮、导航、卡片、设置面板统一玻璃材质，按压提亮 + 缩放回弹（见 `theme/Glass.ets`、`docs/harmony/liquid-glass.md`）
- **关于与版本**：「我的」页展示应用标识、版本号、版本码与内容来源说明
- **详情与选集**：`video_detail` 接口取全部分集
- **搜索**：`search/tab` 接口，`tab_type=29` 剧集分页
- **播放器**：AVPlayer + XComponent，通过 `createMediaSourceWithUrl` 带 Referer（内容源 CDN 有防盗链，Video 组件做不到）
- **CENC 解密**：自研 MP4 解析 + AES-128-CTR 逐样本解密，解密后改写 `encv`/`enca`/`sinf`/`senc` 标记盒，落盘当本地文件播放；结果按集缓存（保留最近 6 集）
- **播控中心**：AVSession 媒体会话接入系统播控中心，锁屏 / 通知面板可控制播放、进度与切集
- **投屏**：`AVCastPickerHelper` 系统设备选择器，投屏到 Cast+ / DLNA 大屏；投屏中本地播放器降级为备源，播放 / 暂停 / 拖动 / 切集全部转发远端；投播期间申请长时任务（`audioPlayback` 后台模式 + `KEEP_BACKGROUND_RUNNING`），锁屏不断流
- **小窗播放**：`@ohos.PiPWindow`（XComponent 模式），播放控制台点「小窗」即全局悬浮续播，小窗面板支持播放/暂停与上下集；按 `isPiPEnabled()` 探测能力，不支持时提示
- **下一集预缓存**：播放中后台预取并解密下一集（复用同一份缓存），自动连播 / 手动切集秒开
- **播放页系统栏**：进入播放页系统栏保持可见、图标切浅色（`playerActive` 标记），退出播放页恢复深浅色主题
- **观看历史**：集号 + 进度，点开续播
- **响应式布局**：手机竖屏走「底部胶囊 Tab + 三列海报」，宽度 ≥600vp（横屏 / 平板 / 车机投屏）自动切成「左侧导航 + 多列」
- **手机交互**：进播放页自动横屏、退出自动转回竖屏；列表页保留状态栏，播放页全屏；48vp 最小热区 + 深色底 + 焦点态（投屏后可用车机方向键/触摸）
- **超级桌面感知**：`displayId !== 0` 判定当前被投到车机虚拟屏，右上角显示「车机投屏」角标；Car Kit 事件监听为增强项，失败静默降级

## 三、播放链路（已打通）

内容源的 mp4 是 **CENC-AES-CTR** 加密：`encv` 样本描述 + `tenc` 声明 8 字节 IV + `senc` 按样本给 IV，整样本加密、无子样本模式。
AVPlayer 不支持 CENC，所以走这条链路：

```
video_model 接口 → main_url + encrypt_info.spade_a
      ↓  下载整集（约 4~8 MB）
spade_a 还原 AES-128 密钥（异或滚动解码）
      ↓
按 stsz/stco/stsc 还原样本偏移 → 逐样本 AES-128-CTR（IV||0 计数块）
      ↓
encv→hvc1 / enca→mp4a，sinf/senc→free（长度不变，偏移表无需重算）
      ↓
AVPlayer fdSrc 播放本地文件
```

真机验证：第 1 集与未缓存过的第 2 集均能出声出画，拖动进度、切集、缓存命中秒开均正常。

投屏与预缓存都复用这套缓存：预缓存在播放中提前跑一遍「下载 → 解密 → 落盘」；
投屏时明文流直接把 URL 交给远端，加密集则把解密后的 `ep_*.mp4` 以 `fdSrc` 方式交给系统投播框架，
传输由系统负责，解码与解密留在手机侧。

## 四、未实现（必须知道）

| 项 | 状态 | 说明 |
|---|---|---|
| 下载 / 合并 / 转码 | ❌ 未做 | 原项目用 ffmpeg 做 HLS 合并与转码，鸿蒙侧无对应能力 |
| 弹幕 | ✅ 只读已接入 | 走内容源 `comment/list` 的 comment 通道（comment_type=20）拉官方弹幕，按 `offset_time` 时间轴滚动；不提供发送。密度依赖源站，冷门剧集常常为 0 |
| 多源（黄豆/剧果/韩小圈等） | ❌ 未做 | 只保留单一主源 |
| 分辨率切换 | ⚠️ 部分 | 会选最高码率，未做手动切换 UI |
| 缓存上限 | ⚠️ 固定 | 只保留最近 6 集，没有离线下载管理 |

`PlaySource.keyHex` 非空即代表该集带内容加密，走上面的下载解密链路；明文流则直接 `createMediaSourceWithUrl` 播放。

## 五、编译运行

1. 安装 **DevEco Studio 26.0.0**（配套 HarmonyOS 7 / API 26 的 SDK）
2. 打开本目录，等待自动 Sync
3. 若提示 `oh-package.json5` 的 `modelVersion` 不匹配，按 IDE 提示升级到对应版本
4. 配置签名：`File → Project Structure → Signing Configs → Automatically generate signature`
5. 连接到 API 26 真机或模拟器，Run

> 本工程已在 DevEco 内用 hvigor 编译通过，并在 Mate 60 Pro（HarmonyOS 7.0 / API 26）上真机验证：
> 首页两列、详情页竖屏、播放页自动横屏、退出转回竖屏、分集切换与拖动均正常。
> 一键构建脚本：`bash scripts/build.sh release`（编译 → 签名 → hdc 安装）。

## 六、上车机（超级桌面投屏）要求

本质是**手机 App 投屏**，不是给车机装应用，因此：

1. **手机先装好本应用**（就是现在这个包，`deviceTypes` 含 phone / tablet / 2in1 / car）
2. **手机与车机登录同一个华为账号**，开启蓝牙 + WLAN，靠近车辆
3. 车机端打开「超级桌面」→ 应用列表里找到「青芒短视频」→ 点开即在车机大屏运行
4. 车里看到的界面会自动切到宽屏布局（左侧导航 + 多列海报），左上角出现「车机投屏」角标

补充说明：

- **不需要上架**，个人使用用调试证书签名即可（`scripts/build.sh` 已内置）
- **用 release 包**：debug 包在超级桌面/车机环境下部分能力受限，本项目统一用 release 编译
- **`deviceTypes` 需要 `car`**，但**不需要** `ACCESS_CAR_DISTRIBUTED_ENGINE` 权限：前者是让座舱按横向窗口下发，后者只在调用 Car Kit 出行互联接口时才要，属受限权限，工程未引入
- 车机满屏的关键路径是 `preferMultiWindowOrientation: landscape_auto` + `enableLandscapeMultiWindow()`；`setPreferredOrientation()` 在多窗/无 sensor 场景下会被系统静默忽略，不能只靠它
- **上下黑边根因与修复**：`ensureFillScreen()` 旧版只检查「窗口宽度 ≥ 车机屏九成」就提前返回，宽度铺满但高度不足（座舱按手机比例下发横窗）时不再补尺寸，车机按宽度适配后上下各留一条黑边。现改为**宽或高任一缺口 > 48px 即触发补铺**（2026-11-07 收紧，原为「任一不足九成」），并显式 `maximize(MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)`（最大化进沉浸 + 禁标题栏/Dock 悬停），maximize 失败再抬 `setWindowLimits` + `resize` 到整屏。细节与验证状态见 §七
- 导航开启后是「分屏」还是「地图悬浮」由座舱策略决定，应用侧无公开 API 可控；本应用通过「声明 `car` + 横窗 + 沉浸式全屏最大化」将自己呈现为标准横屏视频应用，这是获得「全屏 + 地图悬浮」待遇的系统认可路径，最终表现需上车验证
- 若车机应用列表里找不到本应用：先确认手机端能独立打开（说明包没问题），再检查座舱版本、账号是否一致、超级桌面开关
- 车机只负责显示与触控，解码仍在手机侧完成，因此**手机不能与车机断连**

## 七、车机适配交接（2026-11-07 实车反馈轮）

> 背景：实车上车试用后反馈四类问题 —— 首页上下大黑边、播放页四周黑边更重、车机全屏按钮过小难点、弹幕成堆无优化。
> 本轮**只动布局 / 尺寸 / 限流参数，业务逻辑与数据结构零改动**；全部改走 `carMode` 分支，
> `carMode = false`（手机）时的渲染结果与改动前等价。

### 7.1 车机判定口径（新增代码必须沿用）

`pages/Index.ets` 依据 `displayId > 0` 判定「跑在车机虚拟屏」，
写 `AppStorage.setOrCreate('carMode', running)`，同时同步 `AppState.carMode`。
各页面用 `@StorageProp('carMode') carMode: boolean` 订阅。

**新写页面/组件要跟随车机适配，就订阅这个 key，不要自己再按屏幕宽度猜一次。**

### 7.2 已完成（代码落地 + 编译通过）

编译证据：`hvigor BUILD SUCCESSFUL in 24 s 14 ms` / 33 tasks / 22 executed，
产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`（1.6 MB，2026-11-07 12:12）。
追加轮（2026-11-07 12:19）：修注释口径 + 车机返回直达（见 §7.3-2/§7.3-5）后
`BUILD SUCCESSFUL in 13 s 784 ms`，已签名 `entry-default-signed.hap` 待装机。

| # | 实车问题 | 文件 · 入口 | 改法 |
|---|---|---|---|
| 1 | 首页上下大黑边（图1） | `entryability/EntryAbility.ets` · `ensureFillScreen()` | 旧逻辑「宽高都 ≥90% 才返回」正好放过 10% 黑边；改为**宽或高任一缺口 > 48px 就继续补铺**。补齐顺序：`maximize(ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)` → 仍不足则抬 `setWindowLimits` 到整屏再 `resize`。末态日志打 `FILLED` / `STILL_SHORT` |
| 2 | 播放页四周黑边更重（图2） | `view/PlayerView.ets` · `aboutToAppear()` | 车机下进页即 `isFullscreen = true`，绕开宽屏「左视频 + 右选集」分栏（分栏 + 上下留白 + 容器边距三层挤压）。手机分支不动 |
| 3 | 按钮/文字过小难点（图3） | `PlayerView.carBtn()` / `carFont()` | 触控目标统一 `×1.4`，文字 `+2`：圆钮 34→48、返回 36→50、胶囊 28→39、chip 32→45、中央播放 46→64、设置关闭钮 30→42、选集格 44→62；进度条 40→56、滑块 13→18、轨道 3→5；`PlyIcon` 新增 `glyphSize` 随按钮同步放大 |
| 4 | 弹幕成堆无优化（图3） | `PlayerView.spawnDue()` | 三重限流：①**同文本去重** —— 屏上已有同句就不再放第二条（弹幕全程 8.2 s，等于天然 ~8 s 去重窗，直接掐掉「同一句刷十几条」）；②**同屏上限** `DM_MAX_ONSCREEN = 12`，满了 `break` 停发而不是硬塞；③落后 >3 s 的迟到弹幕直接丢弃、每帧最多补 6 条。车机弹幕字号 `dmShowSize() = dmSize + 3`，行高同步 +3（轨道占用、行高、渲染三处必须同一值，否则碰撞按小字算、渲染按大字画，会重新叠字） |
| 5 | 首页/历史/搜索内容小、右侧大片留白 | `theme/Theme.ets` · `gridColumns(width, carMode)`；`HistoryView` / `HomeView` / `SearchView` / `Index.ets` | 车机目标卡宽 148/132 → **200/168**（列数随之下调、卡片变大）；`HistoryView` 字号 `+2`、标题行高 18→24、标题高 36→48、清空按钮 52vp、页标题 `heroTitle +4`；`HomeView`/`SearchView` chip 内边距加大并给 `PosterCard` 传 `fontBoost: 1.15`；侧栏宽 128/108 → **152/136**，导航图标 34、项高 76、标签字号 +3 |
| 6 | 设置生效但界面不刷新（倍速 1.75 播放、显示仍 1.0x） | `PlayerView.roundButton/pill/chip` | **全局根因**：三个 @Builder 按值传参，官方 FAQ（faqs-arkui-1078）明确按值参数不随状态刷新。改为**单对象字面量参数**（`RoundBtnOpt/PillOpt/ChipOpt`，按引用传递）后修复，连带修好：投屏/小窗胶囊标签与激活态、弹幕开关图标、上下集置灰、画质/字号/区域 chip 激活态、fs 图标——这些此前全是按值快照（2026-11-07 下午轮） |
| 7 | 弹幕「比较集中、丑、滚动不优雅」 | `PlayerView` 弹幕管线 | 四项美化：① `pickLane` 改**轮询扫描**（`dmNextLane` 逐条前移），弹幕均匀铺开不再扎堆顶部；② **分轨变速**（`laneSpeed`=0.9/1.0/1.1 交替，同轨恒速防追尾），滚动错落有致；③ **入/出场渐变**（`dmItemAlpha`，画宽 8% 渐变带 × 用户不透明度），不再砰进砰出；④ 文字**双层阴影仿 B 站描边**（四向贴字轮廓 + 柔和环境影，亮色画面白字可读）（2026-11-07 下午轮） |

分辨率核实（对应你查到的 2560×1440）：问界系 HarmonyOS 座舱中控为 15.6 英寸 2K 屏，**2560×1440**，与网上资料一致。
工程内不含任何写死像素，全部走 vp + 断点，density 变化由系统换算，因此无需按 2560 做特殊分支。

### 7.3 未完成（按优先级，换平台后从这里接）

1. **真机视觉回归 0 项完成** —— 本轮只做到「编译通过 + HAP 打包成功」，设备在改造中途掉线（`hdc list targets` 为空），
   所有观感结论都还没有实测支撑，不能算验收通过。
2. **六项待上车核验**（逐条打勾，不通过就回来改参数）：
   - [ ] 首页上下黑边是否真的消失；`hdc shell hilog | grep VERIFY` 的 `fill:` 行末态是否为 `FILLED`
   - [ ] 播放页四周黑边是否消失，画面是否真正铺满
   - [ ] 48vp 圆钮 / 44vp chip 在 15.6 寸屏上是否够大好点
   - [ ] 播放页全屏后**还能不能退出来**（`isFullscreen` 初始 true）—— 已静态排除死锁：车机下返回钮**直达返回**（不再先退全屏落回分栏中间态，见 `PlayerView.topBar()` 返回回调的 `carMode` 分支，2026-11-07 补）；返回手势/返回键仍需实测
   - [ ] 触控 `×1.4` 后是否有元素溢出：设置面板 5 个 chip 一行、选集 6 列、进度条两端时间文字不换行
   - [ ] 首页/历史 卡片变大后是否被挤出屏幕（列数下降但仍要保证不出现横向滚动）
   - [ ] **手机端先验**：设置 1.75 倍速 → 收起设置 → 底部「1.75x」胶囊应立即显示（§7.2-6 修复项）；
     弹幕应均匀分布在画面各轨道、有快有慢、入出场柔和渐变、文字带描边（§7.2-7 修复项）
3. **弹幕限流可能「矫枉过正」** —— 去重是整屏同文本比对，`DM_MAX_ONSCREEN = 12` 偏保守。
   若实测觉得「弹幕太少/太稀」，调参顺序：先把上限提到 16，再考虑把去重窗收窄成「最近 5 秒内出现过同句」。
   参数都在 `PlayerView.ets` 顶部 `DM_*` 常量区，改完不用动别处。
4. **竖屏源在横屏车机里的构图** —— 短剧源是竖屏，铺满 2560×1440 横屏后黑边可能从「上下」变成「左右」。
   本轮未改 `objectFit` 策略；若实车是左右大黑边，需要在 `videoBoxWidth()/videoBoxHeight()` 一带做「cover 裁切」或「左右分栏放弹幕/选集」，属下一轮的结构性改动。
5. ~~**小瑕疵（不影响功能）**~~ 已修（2026-11-07）：`EntryAbility.ets` 里 48px 的注释口径改为
   「2560x1440 屏、density 3.25 下约 15vp」，`ensureFillScreen()` 的文档注释同步改为 48px 缺口判定（原文还写着「九成」）。

### 7.4 换平台继续（三步）

**第一步：环境**

需要 DevEco Studio（含 SDK **API 26**）+ 自带 node；签名需 `keys/` 目录（`guoapp.p12` / `guoapp-debug.cer` / `guoapp-debug.p7b`），
放在工程同级或设 `GUOAPP_KEYS` 指向。

> ⚠️ 本轮踩过的坑（新机器可能复现）：hvigor wrapper 的 pnpm 装包失败后只留下两个**悬空软链**，
> 报错 `ENOENT: no such file ...\project_caches\<hash>\workspace\node_modules\@ohos\hvigor\bin\hvigor.js`，
> 且删目录重来会再次复现。两种修法：
> 1. 联网机：删掉 `C:\Users\<用户>\.hvigor\project_caches\<hash>\workspace`，回 DevEco Studio 点一次 Sync，让它重新 install；
> 2. 离线兜底（本轮采用）：把 DevEco 自带 `tools/hvigor/hvigor` 与 `tools/hvigor/hvigor-ohos-plugin`
>    （版本同为 **6.26.9**）复制或建 junction 到 `<workspace>/node_modules/@ohos/` 下同名位置，再编译即通过。

**第二步：编译**

```bash
# 只验证能否编译（不签名，最快）
cd <工程根>
export DEVECO_SDK_HOME="/d/DevEco Studio/sdk"
export NODE_HOME="/d/DevEco Studio/tools/node"; export PATH="$NODE_HOME:$PATH"
./hvigorw assembleHap --mode module -p module=entry@default -p product=default --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap

# 要装到车上就必须签名（build-profile.json5 的 signingConfigs 目前为空，直接编译只出 unsigned）
bash scripts/build.sh release
```

**第三步：上车验证**

```bash
bash scripts/verify-car.sh --install   # 装签名包 → 抓窗口几何 → 抓 [VERIFY] 日志 → 给结论
bash scripts/verify-car.sh             # 只体检不重装
```
判定口径：窗口宽 ≥ 车机屏宽 90% 视为已铺开；仍有黑边就把 `fill:` / `env:` / `metrics:` 三行日志带回来定位维度。

### 7.5 参数速查（改之前先看这张表）

| 项 | 手机 | 车机 | 位置 |
|---|---|---|---|
| 播放页触控倍数 | 1.0 | **1.4** | `PlayerView.carBtn()` |
| 播放页文字增量 | 0 | **+2** | `PlayerView.carFont()` |
| 弹幕字号 | `dmSize` | **`dmSize + 3`** | `PlayerView.dmShowSize()` |
| 同屏弹幕上限 | 12 | 12 | `DM_MAX_ONSCREEN` |
| 信息流目标卡宽 | 148 / 132 | **200 / 168** | `Theme.gridColumns()` |
| 侧栏宽度 | 128 / 108 | **152 / 136** | `Index.navWidth()` |
| 铺满缺口阈值 | — | **48 px** | `EntryAbility.ensureFillScreen()` |
| 触控目标下限 | 44 vp | 48–64 vp | 由 `carBtn()` 保证 |

### 7.6 硬约束（下一轮同样适用）

- **不改业务逻辑与数据结构**：网络、解密、缓存、播放状态机一行都别碰，只调布局/尺寸/参数。
- **双向不退化**：每处改动都要保证 `carMode = false` 时与改动前一致；手机端观感是本轮回归的红线。
- **尺寸走 token 或 helper**：不再出现散落的魔法数字，新增尺寸先进 `theme/Theme.ets` 或对应 `carBtn()`/`carFont()`。
- **改完必须编译**：`BUILD SUCCESSFUL` 才能算改完，ArkTS 的类型报错一律以编译器为准（不被旧文档写法带偏）。

## 八、目录

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   入口，保留系统栏 + 屏幕常亮
├── pages/Index.ets                 底部 Tab（竖屏）/ 左侧导航（宽屏）+ 播放页接管
├── model/Models.ets                Drama / Episode / FeedPage / PlaySource
├── model/Tags.ets                  题材标签体系与匹配规则
├── net/
│   ├── Sm3.ets                     SM3（X-Argus 依赖）
│   ├── Md5.ets                     MD5 + hex + query 编码
│   ├── Aes.ets                     AES-128-CBC 加密
│   ├── Sign.ets                    X-Gorgon / X-Argus / X-Ladon
│   ├── Cenc.ets                    CENC-AES-CTR 逐样本解密（MP4 盒解析 → encv 落盘）
│   ├── Http.ets                    NetworkKit 封装
│   └── ContentApi.ets              设备注册、信息流、详情、搜索、弹幕、取流
├── store/                          Prefs / HistoryStore / AppState / HomeCache（首页会话缓存）
├── car/CarDesktop.ets              displayId 投屏判定（无需车机权限）
├── theme/Theme.ets                 配色与尺寸 token
├── theme/Glass.ets                 液态玻璃材质参数（Thin / Regular / Thick）
├── theme/Immersive.ets             系统材质接入（当前设备不渲染，保留配置）
├── view/GlassWidgets.ets           GlassSurface / GlassButton 复用组件
└── view/                           首页 / 详情 / 播放 / 搜索 / 历史 / 通用组件
```

## 九、合规与规范

- 品牌与侵权风险分层评估：`docs/harmony/compliance-review.md`
- API 26 技术规范对照与代码梳理：`docs/harmony/api26-review.md`
- 应用定位为**个人学习研究**，视频内容版权归原作者及内容提供方所有，
  不上传、不存储、不二次分发；公开分发或上架前需另行做正式合规审查。

## 十、验收顺序建议

1. 手机桌面打开，看首页是否出内容、是否三列 —— 出内容说明设备注册 + 签名全链路通了；
   切到「我的」再切回首页应直接恢复原列表与滚动位置，不出现「正在加载剧集…」
2. 点进任意剧集：海报在上、简介与选集在下 —— 验证竖屏排版
3. 点「续播」：画面自动转横屏并出画面出声；首次约等 3~10 秒（下载 + 解密），同一集再进为秒开
4. 拖动进度条、点「下一集」—— 确认解密文件可随机定位、切集不报错
5. 点返回：自动转回竖屏并落在观看历史 —— 验证方向还原
6. 播放中点「小窗」→ 视频变全局悬浮小窗，回到桌面/其他应用仍出画出声；小窗面板可暂停/上下集，回应用内点「小窗」恢复
7. 点「投屏」→ 系统设备选择器列出同网 Cast+ / DLNA 设备 → 选择后大屏出画，本机变遥控（播放/暂停、拖进度、切集即时生效），锁屏不断流
8. 让一集快播完 → 自动切下一集应基本秒开（预缓存命中）；播放中锁屏 → 播控中心可暂停/续播
9. 上车连座舱 → 超级桌面打开本应用 → 布局变宽屏、左上角出现「车机投屏」角标；车机大屏应**无上下黑边**（铺满整屏）。若仍有黑边，手机连 USB 后执行 `hdc shell hilog | grep VERIFY`，把 `fill:` / `env:` / `metrics:` 三行发给开发者——里面是窗口/目标屏尺寸与补尺寸结果，能直接定位差在哪个维度
10. 车机播放中打开导航 → 观察是分屏还是「全屏 + 地图悬浮」，结合上一条的日志反馈
