# 鸿蒙开发要点（本工程适用）

> 建立于 2026-11-05。来源与验证方式见文末，**凡标「未核验」的都不能当成结论**。

## 一、窗口方向：本工程踩过的坑，逐条规则

官方文档《窗口旋转 · 旋转接口的行为限制》里有四条容易被忽略的硬规则，每一条都直接命中本工程（视频类 + 车机超级桌面）：

| # | 规则（官方原文要点） | 对本工程的含义 |
|---|---|---|
| 1 | 只有**主窗口**支持设置旋转策略。对子窗口设置「无效果且不报错」，也不影响显示方向 | 必须走 `windowStage.getMainWindow()`，不能用子窗口/浮窗 |
| 2 | 智慧多窗悬浮窗、分屏、多任务、应用后台、自由多窗等场景下，**系统忽略旋转策略；接口可正常调用，但显示方向不会改变** | 车机超级桌面本质是投屏/多窗 → `setPreferredOrientation()` **静默失效** |
| 3 | 主窗口**全屏显示时**旋转策略立即生效；**非全屏时变更不会立即生效**，要等进入全屏后才生效 | 投屏窗口不是全屏 → 又一条失效路径 |
| 4 | 显示方向强依赖 sensor，**无 sensor 的设备（如 TV）调用该接口不会生效** | **车机没有 sensor** → 第三条失效路径 |

**结论：在车机超级桌面上，`setPreferredOrientation(LANDSCAPE)` 三重失效，而且不报错。** 这就是「改了没变化、日志里也没错误」的机制解释——不是代码写错，是这条路本身就通不了。

### 真正有效的做法：多窗方向声明 + 动态开关

`preferMultiWindowOrientation`（`module.json5` → `abilities`，schema 实证合法值只有四个）：

| 取值 | 官方语义 | 适用 |
|---|---|---|
| `default` | 缺省，不配置 | 其他应用 |
| `portrait` | 多窗布局竖向 | 竖向游戏 |
| `landscape` | 多窗布局横向，支持横向悬浮窗 + 上下分屏 | 横向游戏 |
| `landscape_auto` | **多窗布局动态可变为横向**，须配合 `enableLandscapeMultiWindow()` / `disableLandscapeMultiWindow()` | **视频类（本工程）** |

SDK 注释对 `enableLandscapeMultiWindow()` 的硬性前提写得很明确：

> This API takes effect only for the main window of the application. In addition,
> **preferMultiWindowOrientation** must be set to **landscape_auto** in the abilities tag
> in the **module.json5** file.

即：配成 `landscape` 时该 API **不生效**。本工程原先正是 `landscape`，已改正。

### 布局适配不要看屏幕方向

> 应用窗口的宽高比与屏幕属性的 Orientation 没有直接关系，**不建议根据屏幕属性的 Orientation 来做窗口布局适配**。屏幕属性的 Orientation 仅用于辅助 sensor 和相机的方向修正。

布局一律基于**窗口尺寸 / 断点**（`windowSizeChange`、媒体查询、`GridRow` 断点），不看 `display.orientation`。

## 二、车机「只有中间一条」的完整因果链

```
手机应用经超级桌面流转到中控屏
        ↓
座舱按「应用声明的方向」下发窗口形状（竖屏应用 → 竖长窗口）
        ↓
运行时想用 setPreferredOrientation(LANDSCAPE) 掰横
        ↓
命中规则 2（多窗）+ 规则 3（非全屏）+ 规则 4（无 sensor）
        ↓
接口 Promise 正常 resolve，方向纹丝不动，日志干净
        ↓
窗口仍是竖的 → 中控屏上就是「中间一条」
```

正确的发力点有两个，且必须成对：

1. **声明层**：`preferMultiWindowOrientation: "landscape_auto"` —— 窗口下发前就告诉系统「这个应用多窗下要横着排」
2. **运行时**：`enableLandscapeMultiWindow()` —— 让多窗布局动态转横；离开座舱时 `disableLandscapeMultiWindow()` 还原

现有的 `ensureFillScreen()`（`maximize()` → `setWindowLimits()` + `resize()`）保留为尺寸兜底，它解决的是「窗口形状对了但没占满」，与方向是两件事。

## 三、Car Kit：判断「是否在超级桌面」的官方姿势

本地 HMS SDK 有 `@kit.CarKit`（`@hms.carService.smartMobilityCommon.d.ts`）：

```ts
smartMobilityCommon.getSmartMobilityStatus(SmartMobilityType.SUPER_LAUNCHER)
// → SmartMobilityInfo { status: IDLE=0 | RUNNING=1, type, data }
// on('smartMobilityStatus', [SUPER_LAUNCHER], cb) 可监听连接/断开
```

比现在用的 `display.getAllDisplays().length > 1` 权威。**但没有引入**，原因：

- 需要权限 `ohos.permission.ACCESS_CAR_DISTRIBUTED_ENGINE`
- 该权限在本机 `modulecheck` 权限表里查不到 → 属受限权限，大概率需要 ACL 签名/申请，贸然加上可能装不上
- 当前 `getAllDisplays().length > 1` 已能判定「多了一块屏」，够用且零权限

**结论：暂不引入 Car Kit。** 若后续要精确区分「超级桌面 / HiCar / 车机原生」，再评估 ACL。

## 四、其他在本工程已验证的约束

- **`maximize()` 只对主窗口和「可最大化子窗口」有效**，否则抛 `1300004 Unauthorized operation`；`801` 表示设备能力不支持。两者都要 try/catch，不能当成必然成功。
- **`setWindowLimits()` 要先于 `resize()`**：部分设备会把窗口上限压成手机尺寸，不抬上限 resize 会被静默夹住。
- **API 26 新增** `maximize(maximizeOptions?: MaximizeOptions)`，`MaximizeOptions` 含 `maximizePresentation` / `acrossDisplayPresentation` / `snapshotAnimationConfig`；其中 `acrossDisplayPresentation` **只在支持折叠的 2in1 上有效**，车机上无作用，别拿它当车机方案。
- 车机侧 `avoidAreaChange` 的四个方向与手机不同，布局必须四边都读，不能只读上下。

## 五、来源与可信度

| 结论 | 来源 | 可信度 |
|---|---|---|
| 旋转策略在多窗/无 sensor/非全屏下失效 | 华为开发者联盟《窗口旋转》正文（经搜索缓存取得原文），与英文版 `device.harmonyos.com` 表述一致 | 高（原文引用） |
| `preferMultiWindowOrientation` 四个取值 | 本机 `sdk/default/openharmony/toolchains/modulecheck/module.json` 的 JSON Schema `enum` | 高（机器可验证） |
| `enableLandscapeMultiWindow` 需 `landscape_auto` + 仅主窗口 | 本机 `sdk/default/openharmony/ets/api/@ohos.window.d.ts` 官方 JSDoc | 高（官方注释） |
| Car Kit 接口与权限 | 本机 `sdk/default/hms/ets/api/@hms.carService.smartMobilityCommon.d.ts` | 高（官方注释） |
| `landscape` vs `landscape_auto` 的效果差异（悬浮窗/分屏形态） | 官方 module.json5 配置文档 | 中（只影响手机多窗观感，未实测） |
| 车机实际是否会因本改动铺开 | — | **未核验**，hdc 无设备 |

> 说明：华为文档中心是 SPA，`WebFetch` 只能取到页面骨架（正文由 JS 渲染），因此没有直接抓正文。
> 上述「官方原文」来自搜索结果中保留的文档正文片段，并与 SDK 内的官方 JSDoc / JSON Schema 交叉印证。
> 需要 100% 原文时，用 DevEco Studio 内置的文档查看器打开同名文档页。
