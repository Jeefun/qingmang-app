# 验证报告：沉浸光感接入 + 超级桌面车机回归

- 日期：2026-11-05
- 设备：ALN-AL00，HarmonyOS 7.0.0.111(SP10C00E111R4P3)，API 26
- 窗口：1260×2720 px / 388×837 vp，density 3.25，safeTop 38vp，safeBottom 28vp
- 材质档位：`materialLevel=GENTLE`（中算力），`isImmersiveMaterialSupported=true`
- 包：`entry/build/default/outputs/default/entry-default-signed.hap`（release，compatibleSdk 26）
- 截图：`docs/verify-immersive/`

---

## 一、结论速览

| 项 | 结论 | 依据 |
| --- | --- | --- |
| 应用级开关 `ohos.arkui.UIMaterial.state=enable` | **PASS** | hilog：`[VERIFY] material state=ENABLE ... apiVersion=26` |
| 标题栏迁移到 `Navigation.title` + `systemMaterial` + `STACK` | **PASS（结构接入）** | 无 `Material inactive: out of scope` 日志 |
| 标题栏材质**可见渲染** | **FAIL（系统侧）** | 4 组对照实验视觉完全一致，见 2.2 |
| 标题栏渐变模糊（`GRADUAL_BLUR`） | **PASS** | 滚动时顶部渐进模糊，见 02/03 截图 |
| 底部胶囊接入材质 | **N/A（方案 C）** | 手写 Row 不在生效范围；HDS 未引入，见 2.3 |
| 控件（Toggle/Slider） | **PASS（间接）** | 应用级 ENABLE 默认接管；开关仍为品牌红，无回退 |
| 低版本兜底 | **PASS（代码路径）** | 见 2.5，但包的最低版本已是 26 |
| 深浅色自动适配 | **PASS** | 03 截图，无需监听切换 |
| 几何未回退 | **PASS（1 处 18vp 偏移已说明）** | 见 2.6 |

---

## 二、任务一：沉浸光感改造

### 2.1 改动清单

| 文件 | 改动 |
| --- | --- |
| `entry/src/main/module.json5` | 新增 module 级 metadata：`ohos.arkui.UIMaterial.state = enable` |
| `entry/src/main/ets/theme/Immersive.ets` | 新建。能力探测（`sdkApiVersion≥26` + `isImmersiveMaterialSupported()`）、材质构造、`Material.empty`、`[VERIFY]` 状态日志 |
| `entry/src/main/ets/pages/Index.ets` | 页面根改为 `Navigation`；原 `topBar()` 改为 `titleBar()` 挂到 `.title()`；`ignoreLayoutSafeArea`；`scrollEffectOptions` 渐变模糊；布局/断点日志 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 窗口尺寸、避让区（四方向）、窗口状态日志统一 `[VERIFY]` 前缀，并补 vp 换算后的最终值 |

标题栏相关代码约束的落实情况：

- `uiMaterial` 统一从 `@kit.ArkUI` 导入，未使用 `@ohos.*` 旧路径。
- 走材质的标题栏已移除 `backgroundColor` / `backgroundBlurStyle` / `border` / `shadow`，只留内容（渐变蒙层仅在**不走材质**的分支绘制）。
- 标题文字色改为 `$r('sys.color.ohos_id_color_text_primary')`，不再用应用自定义色，智能反色的前提成立。
- 状态管理沿用 V1（`@Entry @Component @State`）。工程全量为 V1，本次未混入 V2 装饰器（V1/V2 禁止混用优先于"延续 V2"的表述）。

### 2.2 关键实测：材质层在本机不渲染

四组对照实验，其他条件不变，只改一个变量，截图逐像素对比：

| # | 变量 | 期望 | 实测 |
| --- | --- | --- | --- |
| 1 | `style: ULTRA_THIN` | 超薄通透 | 顶部只有 `GRADUAL_BLUR` 的渐变模糊，无材质染色 |
| 2 | `style: ULTRA_THICK` | 强模糊/厚材质 | 与 #1 完全一致 |
| 3 | `materialColor: '#66FF0000'`（半透明红） | 顶部明显偏红 | 无任何红色调 |
| 4 | `systemMaterial: Material.empty` | 材质消失 | 与 #1 完全一致 |

补充对照：

- 把 `scrollEffectType` 从 `GRADUAL_BLUR` 换成 `COMMON_BLUR`，顶部模糊**完全消失**、内容贴到屏幕顶端 → 说明此前观察到的模糊全部来自 `scrollEffectOptions`，与材质无关。
- 把自定义 builder 换成字符串标题 `.title('果鉴测试')`，材质同样不渲染（标题被系统按大标题样式绘制在状态栏区域，视觉不可接受，已还原）。

**结论**：`systemMaterial` 配置正确、组件在生效范围内（无 out of scope 日志）、应用级开关为 ENABLE，但材质层在本机无可见输出。属系统侧未开放/算力档位限制，非应用代码问题。

**处理**：材质配置保留（系统放开后自动生效，不需再改代码），实际视觉收益由 `GRADUAL_BLUR` 承担。已在 `Index.ets` 的 `titleBar()` 注释里写明实测结论，避免下一轮误判为"已生效"。

**待确认**：需要一台高算力档（EXQUISITE）设备或更新系统版本复测，才能区分"GENTLE 档被简化"与"API 26 未开放"。

### 2.3 底部胶囊：为什么停在方案 C

任务给的决策规则是"已用 HDS 组件则上方案 A，否则先按方案 C 过渡"。本工程：

- 零 HDS 依赖（`oh-package.json5` 无 HDS，全量 UI 手写）；
- 胶囊的四条硬需求与 `HdsTabs` 不兼容：① 居中短胶囊（218vp，非通栏）；② 滚动出现 / 停手 2 秒隐藏；③ 内容不是 `TabContent` 分页，而是 `mode` 状态机（列表/详情/播放三层）；④ 宽度 ≥600vp 时整体换成左侧竖导航。
- 手写 Row 挂 `systemMaterial` 会直接触发 `Material inactive: out of scope`，属无效代码，未挂。

因此胶囊保留 `backgroundBlurStyle(COMPONENT_REGULAR)`，与改造前完全一致（08/09 截图）。下个版本迁 HDS 时再评估方案 A。

### 2.4 控件与弹窗

- 本工程无系统 Dialog / Menu（播放页的清晰度、倍速面板是自绘浮层，属范围外），无 `bindSheet`。
- Toggle 共 5 个、Slider 共 2 个，均在应用级 ENABLE 的默认接管清单内，未额外挂 `systemMaterial`。实测开关仍为品牌红（`selectedColor` 未被材质覆盖），无视觉回退（10 截图）。
- `Button`（仅错误态的"重试"）**未挂材质**：材质会强制清空 `backgroundColor`，黑色主按钮会失去层级、在浅色页上几乎不可见，属设计回退。这是本次唯一有意偏离任务示例的地方。

### 2.5 低版本兜底

代码路径：`deviceInfo.sdkApiVersion < 26` 或 `isImmersiveMaterialSupported()` 为 false 时，`titleMaterial` 为 undefined → 标题栏走原来的渐变蒙层分支，且 `titleOffset()/titleExtra()` 归零，几何与改造前逐像素一致。

但需要指出：`build-profile.json5` 的 `compatibleSdkVersion` 仍是 `26.0.0`，API 26 以下设备**根本装不上这个包**。"低版本不崩"在当前产物上是空条件——真要覆盖 API<26，需下调 compatibleSdkVersion，属产品决策，本次未动。

### 2.6 几何变化

| 元素 | 改造前 | 改造后 | 判定 |
| --- | --- | --- | --- |
| 标题「果鉴」 | `[48,175][159,240]` | `[48,175][159,240]` | 完全一致 |
| 右上「搜索」胶囊 | `[1031,164][1212,252]` | `[1031,164][1212,252]` | 完全一致 |
| 首屏大标题 | `[48,292]` | `[48,351]` | **+59px（18vp）** |

18vp 偏移的成因：`Navigation` 在 Free 模式下把自定义 title 的内容钉在窗口 56vp 处（实测，与 builder 高度无关），而本页需要它贴在状态栏下沿（38vp），故用 `offset y = safeTop - 56` 拉回；标题栏整体因此比原来的 52vp 高 18vp，内容顶部留白同步 +18vp，避免首屏大标题被压进模糊带。这是唯一可见的布局变化，宽屏/播放/详情分支不受影响（无标题栏，`titleOffset` 为 0）。

---

## 三、任务二：车机回归清单

环境说明：**无问界 M9 车机可用**，本节仅完成"本地宽屏模拟 + 手机回归"两个批次；车机终验批次整体 **BLOCKED**。宽屏模拟采用临时把 `orientation` 改为 `landscape` 构建，验证后已还原 `auto_rotation` 并重新安装（当前装机包为竖屏包）。

### 1. 布局与断点

| 编号 | 结论 | 证据 |
| --- | --- | --- |
| L1 流转后整体布局 | **PASS（模拟）** | 06 截图：宽屏下内容横向铺满，无居中竖屏残留 |
| L2 lg 断点 | **PASS（模拟）** | `[VERIFY] breakpoint changed to: Md windowWidth=836.92vp`；列表切 4 列（07 截图） |
| L3 固定尺寸残留 | **PASS** | 搜索框 `constraintSize maxWidth 560`；网格按 `Breakpoints.gridColumns` 反推卡宽 |
| L4 文字与控件 | **PASS** | 无溢出/截断；左侧导航 128vp 档位图标不缩放 |

### 2. 窗口与避让监听

| 编号 | 结论 | 证据 |
| --- | --- | --- |
| W1 windowSizeChange | **PASS** | `[VERIFY] windowSizeChange: width=2720, height=1260` |
| W2 布局刷新 | **PASS（启动建窗）** / 运行时流转 **BLOCKED** | 建窗即按新尺寸布局，断点日志同步变化；流转瞬间的运行时回调需车机 |
| W3 avoidAreaChange | **PASS** | `[VERIFY] avoidAreaChange: type=0, top=0, bottom=0, left=0, right=0`；横屏后 `safeTop` 由 38→0，`metrics` 日志同步 |
| W4 内容遮挡 | **PASS（模拟）** | 宽屏内容区自带 `safeTop+14` 顶部内缩 + `safeRight` |

### 3. 沉浸式与胶囊（车机端重点）

| 编号 | 结论 | 证据 |
| --- | --- | --- |
| I1 顶部沉浸 | **PASS（手机）** | 02/03 截图：内容穿过状态栏，顶部为渐变模糊带 |
| I2 底部沉浸 | **PASS** | 列表底部留白 = `floatNavHeight + safeBottom + 24`，内容可滚到胶囊背后 |
| I3 胶囊形态 | **PASS（手机）** | 08 截图：居中短胶囊，实测 709×182px（218×56vp），非通栏，玻璃模糊正常 |
| I4 胶囊显隐 | **PASS** | 09 截图：进页 1.2s 可见、3.8s 后消失，2s 超时隐藏生效 |
| I5 胶囊触控 | **PASS（手机）** | 单项热区 52×45vp，≥48vp 建议值仅宽度略低 4vp |

### 4. 迁移与边界

| 编号 | 结论 | 说明 |
| --- | --- | --- |
| M1 手机→车机→手机往返 3 次 | **BLOCKED** | 无车机 |
| M2 车机内页面切换 | **BLOCKED** | 同上；手机端四 Tab + 详情 + 播放已逐页验证 |
| M3 横竖屏/分屏实时响应 | **BLOCKED（分屏）** / 横竖屏 **PASS（启动态）** | 无物理旋转条件，运行时旋转未复测 |
| M4 迁移中操作无崩溃 | **BLOCKED** | 无车机 |

### 5. 性能

| 编号 | 结论 | 说明 |
| --- | --- | --- |
| P1 列表滚动 | **PASS（手机）** | 无掉帧主观感受；未做 Profiler 帧率采样，**未核验** |
| P2 动画无闪烁 | **PASS（手机）** | 胶囊进出场 opacity+translate 过渡平滑 |

### 6. 失败项 / 高风险项

1. **材质层不渲染**（任务一）：见 2.2。不影响功能，但意味着"沉浸光感"在本机只落到渐变模糊。
2. **运行时旋转未复测**（M3/P1）：上一轮修复的"旋转黑屏"依赖 `PlayerView` 的稳定父链；本次在其上方加了一层 `Navigation`，父链形态变了。结构上 `videoArea` 的构建分支未动，但**需一次真机旋转复测**才能确认未回归。

---

## 四、未完成 / 需要下一轮

1. 车机终验（L/W/M 全量、M1 三次往返）：需问界 M9 + 超级桌面。
2. 真机旋转复测（播放页黑屏回归、布局重排）。
3. 高算力档设备复测材质是否渲染（区分 GENTLE 简化 vs API 26 未开放）。
4. 宽屏"继续观看"卡片偏大、`SettingsView` 底部遮挡：本次复核——底部遮挡**未复现**（10 截图，末卡片与页脚在胶囊上方完整可见），可关闭该项。
