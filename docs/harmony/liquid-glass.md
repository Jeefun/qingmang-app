# 液态玻璃 / 高级光感（材料规范）

> 建立于 2026-11-06。对应代码：`entry/src/main/ets/theme/Glass.ets`、`entry/src/main/ets/view/GlassWidgets.ets`。
> 视觉预览：`docs/preview/glass-preview.html`

## 一、官方提供的两条路，为什么选了手工那条

HarmonyOS 7（API 26）新增**沉浸光感**（immersive system material），官方两处开关：

1. **应用级**：`module.json5` → `metadata` 里 `ohos.arkui.UIMaterial.state = enable`
   开启后 Dialog / Toast / AlphabetIndexer / ChipGroup / Chip / Select / Menu / Toggle /
   SegmentButton(V2) / Slider / bindSheet / SelectionMenu **默认**套用系统材质。
2. **组件级**：`.systemMaterial(new uiMaterial.ImmersiveMaterial({ style, materialColor, colorInvert, applyShadow, interactive, lightEffect }))`
   —— `systemMaterial` 是 CommonMethod 通用属性（`@since 26.0.0`），组件级优先级高于应用级。

可选参数（本机 SDK `@ohos.arkui.uiMaterial.d.ts` 实证）：

| 参数 | 取值 | 说明 |
|---|---|---|
| `style` | `ULTRA_THIN(0)` / `THIN(1)` / `REGULAR(2)` / `THICK(3)` / `ULTRA_THICK(4)` | 厚度档，默认 REGULAR |
| `materialColor` | `ResourceColor` | 染色，**必须带透明度**，全不透明会把滤镜完全挡住 |
| `colorInvert` | boolean，默认 false | 按背景互补色自动反色（只在薄材质上易触发） |
| `applyShadow` | boolean，默认 true | 材质自带阴影，优先于普通 `shadow()` |
| `interactive` | boolean，默认 false | 按压形变 |
| `lightEffect` | `LightEffectOptions \| null` | 光感交互反馈，`color` 默认白 |

**但本工程实测这条路不产出画面。** ALN-AL00 / 7.0.0.111 / API 26 / materialLevel=GENTLE 上：
`systemMaterial` 挂在 `Navigation.title` 且无 `out of scope` 日志，材质层却没有任何可见渲染——
把 `materialColor` 改成半透明红、`style` 从 `ULTRA_THIN` 换到 `ULTRA_THICK`、甚至换成
`Material.empty`，三种情况截图完全一致。所以：

> **系统材质保留配置（等系统侧放开自动生效），视觉主体用 `backgroundEffect` 手工实现。**

## 二、手工玻璃的配方

底层 API 是通用属性 `backgroundEffect(options: BackgroundEffectOptions)`，四个可调项
（`radius` / `saturation` / `brightness` / `color`）正好够做折射感：

| 参数 | 作用 | 关键点 |
|---|---|---|
| `radius` | 模糊半径 | 决定「厚度」。16 薄 / 24 常规 / 34 厚 |
| `saturation` | 饱和度增益 | **最容易做错的一项**：默认 1，等于 1 时背景颜色透不上来，看起来是灰蒙蒙的磨砂；1.6~2.0 才有玻璃透色的感觉 |
| `brightness` | 亮度增益 | >1 模拟光穿过玻璃；厚面板反而要 <1（压暗）才保证文字可读 |
| `color` | 薄纱染色 | **必须带 alpha**。同时不要再叠不透明 `backgroundColor`，否则模糊被实色盖死 |

三档参数（`Glass.spec()` 实现）：

| 档位 | radius | saturation | brightness | 染色（深/浅） | 用于 |
|---|---|---|---|---|---|
| Thin | 16 | 1.6 | 1.04 | `#80100C0E` / `#A6FFFFFF` | 圆钮、chip、搜索框、封面上标签 |
| Regular | 24 | 1.8 | 1.05 | `#80100C0E` / `#A6FFFFFF` | 导航条、主按钮、卡片 |
| Thick | 34 | 2.0 | 0.88 | `#B30A0809` / `#D9FFFFFF` | 播放器设置面板 |

### 玻璃的三层结构（缺一层就塌）

1. **本体**：`backgroundEffect` 模糊 + 染色
2. **折射亮边**：
   - 1px 描边 `border({ width: 1, color: 高光色 })`
   - 顶部高光条：**两端淡出、中间亮**的水平渐变（等比白线看起来像描边，只有中段亮才有折射感）
   - 底部一道极淡暗线，给玻璃厚度
3. **弥散投影**：大半径（14/22/30）+ 低透明度，让组件浮起来而不是贴上去

### 按压反馈

`scale 0.96` + `brightness +0.05`（按下时按钮自己变亮 = 「指尖打光」）+ 阴影收紧，
150ms `Curve.EaseOut`。三样一起给，才有「按进去了并且有光」的物理感。

## 三、必须遵守的约束

- **不要**再手写 `backgroundColor + backgroundBlurStyle` 当玻璃用。`backgroundBlurStyle` 只给 BlurStyle
  枚举（`COMPONENT_THIN` 等），调不了饱和度和亮度，做出来是磨砂塑料。
- **不要**在设了 `backgroundEffect` 之后再设不透明 `backgroundColor`。
- **深色模式染色用低 alpha 黑、浅色用低 alpha 白**。反过来做，深色模式下玻璃会发白发脏。
- **「降低透明度」开关**（`Settings.reduceTransparency`）打开时：`radius = 0`、饱和/亮度回 1、
  染色换成实色。只把 alpha 提到不透明而保留模糊，会出脏边。
- 导航未选中项在**浅色玻璃上必须用深色字**（`app.color.textDim`），不能用白色半透明。
  预览阶段就踩到过：白字压在白玻璃上等于隐形。

## 四、覆盖清单（37 处）

| 文件 | 处数 | 改了什么 |
|---|---|---|
| `pages/Index.ets` | 3 | 底部胶囊导航条、宽屏侧栏、标题栏搜索胶囊 |
| `view/PlayerView.ets` | 6 | 圆钮 / pill / 画质胶囊 / 中央播放键 / 设置面板 / 面板内格子 |
| `view/SettingsView.ets` | 7 | 6 张设置卡片 + 1 个圆块 |
| `view/Widgets.ets` | 6 | SegmentedChip、TagChip、SettingCard、PosterCard 集数标签、空态主按钮 |
| `view/SearchView.ets` | 3 | 搜索框、内嵌搜索按钮、历史词 chip |
| `view/DetailView.ets` | 3 | 主按钮 ×2、宽屏返回圆钮 |
| `view/HistoryView.ets` | 2 | 封面标签、筛选 chip |
| `view/HomeView.ets` | 1 | 搜索框 |

## 五、未验证项

- **真机观感**：`backgroundEffect` 的实际模糊质量、低算力设备（materialLevel=SMOOTH）上的降级表现，
  都需要真机看。hdc 当前无设备（`[Empty]`）。
- 预览页用 CSS `backdrop-filter` 复刻同一套配方，能验证「参数是否合理、对比度是否够」，
  但**不能替代** ArkUI 在真实像素密度下的渲染结果（尤其 1px 高光条在高 DPI 下是否可见）。

## 六、来源

| 结论 | 来源 | 可信度 |
|---|---|---|
| `uiMaterial` 全部类型与默认值 | 本机 `sdk/default/openharmony/ets/api/@ohos.arkui.uiMaterial.d.ts` | 高（官方注释） |
| `systemMaterial` 是 CommonMethod 通用属性、`@since 26.0.0` | 本机 `ets/component/common.d.ts:22642` | 高 |
| 应用级开关的 metadata 名与取值 | `module.json5` 配置文档 + 本工程已配置 | 高 |
| `backgroundEffect` 四个参数与取值范围 | 本机 `ets/component/common.d.ts:7126`（`BackgroundEffectOptions`） | 高 |
| `systemMaterial` 在真机无可见渲染 | 本工程 2026-11 实测记录（ALN-AL00） | 中（单机单版本，不代表所有设备） |
