/**
 * 应用入口。
 *
 * 手机竖屏：顶部小标题栏 + 浮起胶囊底栏 + 全宽内容；宽度 ≥600vp（横屏 / 平板 / 车机投屏）切成左侧导航。
 * 底部导航做成浮起胶囊，内容可以滑到它下方，视觉上更轻，也是手机实测版本的形态。
 * 不做页面路由栈，用状态切换即可——返回路径只有一条，多余的路由层级只会增加误触。
 */
import { common } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from '../store/AppState';
import { Prefs } from '../store/Prefs';
import { Settings } from '../store/Settings';
import { UpdateNotify } from '../store/UpdateNotify';
import { SourceRegistry } from '../store/SourceRegistry';
import { ModuleRuntime } from '../net/ModuleRuntime';
import { CarDesktop } from '../car/CarDesktop';
import { Bp, Breakpoints, Metrics, ThemeController } from '../theme/Theme';
import { Immersive } from '../theme/Immersive';
import { Glass, GlassTier } from '../theme/Glass';
import { GlassSurface, GlassButton, GlassButtonKind } from '../view/GlassWidgets';
import { NavIcon } from '../view/Widgets';
import { HomeView } from '../view/HomeView';
import { DetailView } from '../view/DetailView';
import { PlayerView } from '../view/PlayerView';
import { SearchView } from '../view/SearchView';
import { HistoryView } from '../view/HistoryView';
import { FavoriteView } from '../view/FavoriteView';
import { SettingsView } from '../view/SettingsView';
import { SourcesView } from '../view/SourcesView';

class NavItem {
  label: string = '';
  icon: string = '';

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

const NAV_ITEMS: NavItem[] = [
  new NavItem('首页', 'home'),
  new NavItem('搜索', 'search'),
  new NavItem('历史', 'history'),
  new NavItem('收藏', 'fav'),
  new NavItem('我的', 'profile')
];

/** 胶囊自动隐藏延时（毫秒） */
const NAV_HIDE_DELAY: number = 2000;
/**
 * 胶囊单项宽度（vp）。
 * 注意：Row 在不设 width 时会撑满父约束，无法「由内容撑开」，
 * 所以胶囊总宽必须显式算出 = 项宽 × 项数 + 左右 padding。
 */
const NAV_ITEM_W: number = 52;
const NAV_PAD_X: number = 5;

/**
 * Navigation 在 Free 模式下会把自定义 title 的内容钉在窗口 56vp 处（实测），
 * 与本页需要的「状态栏下沿」差一段，用负偏移拉回去。
 * 数值 = safeTop - 56：本机 safeTop 38vp → 上移 18vp，标题回到改造前的位置。
 * 只在材质可用时生效，兜底路径保持原来的几何不动。
 */
const TITLE_PIN_VP: number = 56;

@Entry
@Component
struct Index {
  @State tab: number = 0;
  /** 0=列表页 1=详情 2=播放 3=站源管理 */
  @State mode: number = 0;
  @State detailId: string = '';
  @State playId: string = '';
  @State playIndex: number = 1;
  /** 播放页来路：详情页进入记 true，返回时回详情；列表进入记下来源 tab */
  private playFromDetail: boolean = false;
  private playFromTab: number = 0;
  /** 车机投屏角标：EntryAbility 按 displayIdChange 实时写入，流转/迁回都会即时刷新 */
  @StorageProp('carMode') carOnScreen: boolean = false;
  /**
   * 续播指令（JSON 字符串）：
   * 桌面卡片点击 / 跨设备接续时由 EntryAbility 写入，
   * 冷启动在 aboutToAppear 消费一次，热启动靠 @Watch。
   */
  @StorageProp('pendingPlay') @Watch('onPendingPlay') pendingPlay: string = '';
  @State viewWidth: number = 0;

  @StorageProp('safeTop') safeTopPx: number = 0;
  @StorageProp('safeBottom') safeBottomPx: number = 0;
  @StorageProp('safeLeft') safeLeftPx: number = 0;
  @StorageProp('safeRight') safeRightPx: number = 0;
  /** EntryAbility 在 windowSizeChange 里写入，作为布局宽度的兜底来源 */
  @StorageProp('screenWidth') windowWidthPx: number = 0;
  /** 悬浮胶囊是否可见：滚动时出现，停手 2 秒淡出 */
  @State navVisible: boolean = true;
  /** 导航项按压态下标，用于 0.94 缩放反馈（-1 表示没有按下） */
  @State navPress: number = -1;
  /** 标题栏圆形功能钮的按压反馈 */
  @State topPress: boolean = false;
  /** 已装站源模块数非零时挂载沙箱 Web 组件（SourceRegistry 安装/卸载后维护） */
  @StorageProp('modulesPresent') modulesPresent: boolean = false;

  private car: CarDesktop = new CarDesktop();
  private navTimer: number = -1;
  /**
   * 标题栏系统材质。只在这里取一次：build 每帧都会执行，
   * 每次 new 一个 ImmersiveMaterial 既浪费又可能让系统材质层反复重建。
   * 为 undefined 表示当前设备不支持沉浸光感，标题栏回落到渐变蒙层。
   */
  private titleMaterial: uiMaterial.ImmersiveMaterial | undefined = Immersive.titleMaterial();
  /** 上一次记录的断点，仅在变化时打日志，避免滚动时刷屏 */
  private lastBreakpoint: Bp = Bp.Sm;
  /** 启动后第一次算出断点也要记一条，便于对比改造前后 */
  private bpLogged: boolean = false;

  aboutToAppear(): void {
    // 顺序不能反：Prefs 先拿到 context，设备号才能读出来，否则每次启动都会重新注册
    try {
      const context = this.hostContext();
      if (context !== undefined) {
        Prefs.init(context);
        Settings.load();
        // 站源模块沙箱：context 供读取 filesDir/modules 与 rawfile 宿主脚本
        ModuleRuntime.setContext(context);
      }
    } catch (error) {
      // 拿不到 context 时退化为内存态
    }
    // 已装模块决定是否挂载沙箱 Web（AppStorage 'modulesPresent'）
    SourceRegistry.syncModulesPresent();
    this.initContext();
    AppState.api.init();
    // 冷启动路径：EntryAbility 在 loadContent 前写入的续播指令随初始值带进来
    this.consumePendingPlay(this.pendingPlay);
    // 收藏更新提醒：延迟 9 秒，避开启动高峰（首屏加载、设备注册）
    this.scheduleUpdateCheck();
    // 进页面先亮 2 秒，让用户知道导航在哪
    this.showNav();
    // 材质状态一次性打进日志：验证时 grep VERIFY 就能看到应用级开关有没有真的进包
    Immersive.logState();
  }

  aboutToDisappear(): void {
    this.car.stop();
    this.clearNavTimer();
  }

  /** 显示胶囊并重置倒计时；每次滚动/点击都要先清旧定时器，避免多计时器叠加 */
  private showNav(): void {
    this.navVisible = true;
    this.clearNavTimer();
    this.navTimer = setTimeout(() => {
      this.navVisible = false;
      this.navTimer = -1;
    }, NAV_HIDE_DELAY);
  }

  private clearNavTimer(): void {
    if (this.navTimer !== -1) {
      clearTimeout(this.navTimer);
      this.navTimer = -1;
    }
  }

  /**
   * 内容顶部内缩量：窄屏且有顶部标题栏时，列表首项要让开状态栏 + 标题栏。
   * 注意这里只影响「列表内容」，不影响 Scroll 视口——视口仍从 y=0 开始，
   * 滚动起来内容才会从标题栏背后穿过去。
   */
  private topInset(): number {
    if (this.mode !== 0 || this.tab === 4) {
      return 0;
    }
    // 宽屏走左侧导航分支：父容器已统一 padding(safeTop + 14)。
    // 这里再返回 safeTop + topBarHeight 会让列表页叠加双份 safeTop 再加 60vp
    // —— 正是实车「标题上方留白 29%–48%」的根因。
    if (!this.isNarrow()) {
      return 0;
    }
    const base: number = this.safeTopPx + Metrics.topBarHeight;
    // 只有窄屏才有这条材质标题栏
    return base + this.titleExtra();
  }

  /** 标题栏被 Navigation 下推的量（vp，负值），材质不可用时为 0 */
  private titleOffset(): number {
    if (!this.useMaterial()) {
      return 0;
    }
    return Math.min(0, this.safeTopPx - TITLE_PIN_VP);
  }

  /**
   * 材质标题栏比原来的小标题栏多占的高度（vp）。
   * 标题栏下推过的量要补回到内容顶部留白里，否则首屏大标题会被压进模糊带。
   */
  private titleExtra(): number {
    return -this.titleOffset();
  }

  /**
   * 顶部渐变蒙层取色：两端同色不同 alpha。
   * 必须内联成字面量元组交给 linearGradient —— 传一个方法返回的元组数组，
   * 运行时会被当成普通二维数组，渐变整层静默不渲染（踩过）。
   */
  /** 标题栏正下方必须完全不透明，否则滚过去的大字会和标题糊在一起 */
  private scrimSolid(): string {
    return ThemeController.isDark ? '#FF100C0E' : '#FFF7F5F2';
  }

  private scrimMid(): string {
    return ThemeController.isDark ? '#D9100C0E' : '#D9F7F5F2';
  }

  private scrimClear(): string {
    return ThemeController.isDark ? '#00100C0E' : '#00F7F5F2';
  }

  private hostContext(): common.UIAbilityContext | undefined {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return undefined;
    }
    return ctx as common.UIAbilityContext;
  }

  /** 布局宽度：优先用实测内容宽，其次用窗口监听写入的宽，最后兜底手机竖屏 */
  private winWidth(): number {
    if (this.viewWidth > 0) {
      return this.viewWidth;
    }
    return this.windowWidthPx > 0 ? this.windowWidthPx : 360;
  }

  private isNarrow(): boolean {
    return !Breakpoints.isWide(this.winWidth());
  }

  /** 左右导航宽度随断点放大，车机宽屏下再抬一档：图标与文字才不显小 */
  private navWidth(): number {
    const width = this.winWidth();
    if (width >= 1280) {
      return this.carOnScreen ? 152 : 128;
    }
    if (width >= 840) {
      return this.carOnScreen ? 136 : 108;
    }
    return Metrics.navWidth;
  }

  /** 车机侧栏导航项尺寸：图标 34 / 项高 76（实车反馈侧栏图标小、不易点） */
  private navIconSize(): number {
    return this.carOnScreen ? 34 : Metrics.floatNavIcon;
  }

  private navItemHeight(): number {
    return this.carOnScreen ? 76 : 64;
  }

  private initContext(): void {
    try {
      const context = this.hostContext();
      if (context === undefined) {
        AppState.carMode = false;
        return;
      }
      // 启动瞬间的判定：车机直接拉起时 config.displayId 已 > 0，
      // 会话中途流转则由 EntryAbility 的 displayIdChange 写入 AppStorage 实时刷新。
      const displayId = this.car.detectDisplay(context);
      AppState.displayId = displayId;
      AppState.carMode = displayId > 0;

      // Car Kit 事件为增强项（需受限权限，普通签名拿不到）：能收到就覆盖 AppStorage 的判定
      this.car.start((running: boolean) => {
        AppStorage.setOrCreate('carMode', running);
        AppState.carMode = running;
      });
    } catch (error) {
      AppState.carMode = false;
    }
  }

  private openDetail(seriesId: string): void {
    this.detailId = seriesId;
    this.mode = 1;
  }

  /** 热启动：卡片/接续再次拉起应用时 EntryAbility 更新 AppStorage，这里被 @Watch 唤醒 */
  private onPendingPlay(_prop: string): void {
    this.consumePendingPlay(this.pendingPlay);
  }

  /**
   * 消费续播指令：解析 {seriesId, episodeIndex} 后直接进播放页。
   * 消费完立即清空（本地与 AppStorage 双清），避免返回列表时被再次触发。
   */
  private consumePendingPlay(raw: string): void {
    if (raw.length === 0) {
      return;
    }
    this.pendingPlay = '';
    AppStorage.setOrCreate('pendingPlay', '');
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const seriesId = parsed['seriesId'];
      const rawEpisode = parsed['episodeIndex'];
      if (typeof seriesId === 'string' && seriesId.length > 0) {
        const episode: number = typeof rawEpisode === 'number' && rawEpisode > 0 ? rawEpisode : 1;
        this.openPlayer(seriesId, episode);
        hilog.info(0x0001, 'QingMangIndex',
          `[VERIFY] 续播入口生效: ${seriesId} 第${episode}集`);
      }
    } catch (error) {
      hilog.warn(0x0001, 'QingMangIndex', '[VERIFY] 续播指令解析失败');
    }
  }

  /** 收藏剧集更新检查：延迟触发，内部 15 分钟节流，重复调用安全 */
  private scheduleUpdateCheck(): void {
    setTimeout(() => {
      try {
        const context = this.hostContext();
        if (context !== undefined) {
          UpdateNotify.check(context);
        }
      } catch (error) {
        // 更新提醒是增强项，失败不影响主流程
      }
    }, 9000);
  }

  private openPlayer(seriesId: string, episodeIndex: number): void {
    this.playFromDetail = this.mode === 1;
    this.playFromTab = this.tab;
    this.playId = seriesId;
    this.playIndex = episodeIndex;
    this.mode = 2;
  }

  /** 打开站源管理页：来路 tab 不变，返回时回到原列表页 */
  private openSources(): void {
    this.mode = 3;
  }

  private exitSources(): void {
    this.mode = 0;
    this.showNav();
  }

  /**
   * 退出播放页：详情进的回详情，列表进的回原 tab。
   * 原来硬编码回历史 tab，从「详情 → 播放」返回时会跳错页。
   */
  private exitPlayer(): void {
    if (this.playFromDetail) {
      this.mode = 1;
    } else {
      this.mode = 0;
      this.tab = this.playFromTab;
    }
    this.showNav();
  }

  /**
   * 系统返回手势。不拦截时默认把整个应用退到桌面——
   * 播放/详情页必须在这里转成「向上返回一层」。
   */
  onBackPress(): boolean {
    if (this.mode === 2) {
      // 播放页交给 PlayerView 自己分层处理（收设置面板 → 退全屏 → 退页），
      // 面板与全屏状态都在子组件里，父层拿不到，用信号转发。
      AppStorage.setOrCreate('playerBackSignal', Date.now());
      return true;
    }
    if (this.mode === 3) {
      this.exitSources();
      return true;
    }
    if (this.mode === 1) {
      this.mode = 0;
      this.showNav();
      return true;
    }
    // 列表页保持默认行为（退出应用）
    return false;
  }

  private selectTab(index: number): void {
    this.tab = index;
    this.mode = 0;
    // 切页后先亮 2 秒，让用户能继续点下一个 Tab
    this.showNav();
  }

  /** 顶部小标题栏文案；我的页自己带大标题，不显示 */
  private topBarTitle(): string {
    if (this.tab === 0) {
      return '青芒短视频';
    }
    if (this.tab === 1) {
      return '搜索';
    }
    if (this.tab === 3) {
      return '收藏';
    }
    return '历史';
  }

  /** 标题栏是否交给系统（仅在窄屏列表页出现：宽屏走左侧导航，播放/详情页不要标题栏） */
  private showTitle(): boolean {
    return this.mode === 0 && this.tab !== 4 && this.isNarrow();
  }

  /**
   * 标题栏是否走系统材质。
   * 「降低透明度」打开时退回实色方案——这条开关的语义就是「玻璃材质改为实色背景」，
   * 材质由系统绘制，不能用 backgroundBlurStyle 关掉，只能显式传 Material.empty。
   */
  private useMaterial(): boolean {
    return this.titleMaterial !== undefined && !Settings.reduceTransparency;
  }

  /**
   * 传给 Navigation.title 的材质对象。
   *   - 设备支持且未开「降低透明度」→ 沉浸材质；
   *   - 设备支持但开了「降低透明度」→ Material.empty，显式关掉（传 undefined 关不掉）；
   *   - 设备不支持 → undefined，此时连应用级开关都不该生效。
   */
  private titleSystemMaterial(): uiMaterial.Material | undefined {
    if (this.titleMaterial === undefined) {
      return undefined;
    }
    return Settings.reduceTransparency ? Immersive.noneMaterial() : this.titleMaterial;
  }

  /**
   * 标题栏前景色。
   *
   * 开了系统材质后必须换成系统色资源：智能反色只认 $r 资源值，
   * 写死 Color.White / 自定义色值不会触发反色，深色背景上就会糊成一片。
   * 材质不可用时仍用应用自己的暖墨色，保持原有观感。
   */
  private titleFg(): Resource {
    if (this.useMaterial()) {
      return $r('sys.color.ohos_id_color_text_primary');
    }
    return $r('app.color.text');
  }

  /**
   * 顶部标题栏，挂在 Navigation 的 title 上。
   *
   * 为什么是 Navigation：systemMaterial 只对系统组件的标题栏生效，
   * 手写 Row 挂材质会被判为 "out of scope"（日志可见），什么效果都没有。
   *
   * 实测结论（ALN-AL00 / 7.0.0.111 / API 26 / materialLevel=GENTLE）：
   * systemMaterial 已按规范接入且无 out of scope 日志，但材质层没有可见渲染——
   * 把 materialColor 临时改成半透明红、style 从 ULTRA_THIN 换到 ULTRA_THICK、
   * 甚至换成 Material.empty，三种情况截图完全一致；换成字符串标题也一样。
   * 真正带来视觉提升的是下面 scrollEffectOptions 的 GRADUAL_BLUR 渐变模糊。
   * 材质保留配置，等系统侧放开后即可自动生效，不需要再改代码。
   *
   * 两种形态：
   *   - 走材质：不画蒙层——材质层被不透明背景盖住就永远看不见；
   *   - 不走材质（设备不支持 / 打开「降低透明度」）：保留原来的渐变蒙层，
   *     老设备观感与改造前一致。
   */
  @Builder
  titleBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.useMaterial()) {
        // 兜底：渐变蒙层必须是有确定高度的独立绘制层，
        // 直接给 wrap 高度的 Column 加 linearGradient 不会渲染（实测整层消失）
        Text('')
          .width('100%')
          .height(this.safeTopPx + Metrics.topBarHeight + 20)
          .linearGradient({
            angle: 180,
            colors: [
              [this.scrimSolid(), 0.0],
              [this.scrimMid(), 0.56],
              [this.scrimClear(), 1.0]
            ]
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
          .hitTestBehavior(HitTestMode.None)
      }

      Row() {
        Text(this.topBarTitle())
          .fontSize(Metrics.topTitleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.titleFg())

        Blank()

        if (this.tab === 0) {
          // 圆形功能钮（对齐系统应用的搜索钮规格）：
          // 44vp 圆形 + 玻璃底 + 线性放大镜，比文字胶囊更接近官方应用的视觉重量。
          // 图标走 media 资源的 base/dark 双份，主题切换时颜色自动跟随。
          // 注意：Stack 的对齐只能写在构造器，没有 .justifyContent()/.alignItems()。
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_nav_search'))
              .width(20)
              .height(20)
              .objectFit(ImageFit.Contain)
          }
          .width(Metrics.roundBtnSize)
          .height(Metrics.roundBtnSize)
          .borderRadius(Metrics.roundBtnSize / 2)
          // 与底栏、侧栏同一套材质，避免「一处玻璃一处塑料」
          .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
          .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
          .shadow({
            radius: Glass.spec(GlassTier.Thin).shadowRadius,
            color: Glass.spec(GlassTier.Thin).shadowColor,
            offsetX: 0,
            offsetY: 3
          })
          .scale({ x: this.topPress ? 0.92 : 1, y: this.topPress ? 0.92 : 1 })
          .animation({ duration: 150, curve: Curve.EaseOut })
          .accessibilityText('搜索')
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.topPress = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.topPress = false;
            }
          })
          .onClick(() => {
            this.selectTab(1);
          })
        }

        if (this.carOnScreen) {
          // 带上窗口宽度：车机上这张截图本身就能说明系统下发的窗口有多大
          // （若是 600 上下就是被塞进了 9:18 兼容窗口，宽屏应接近 1200+）
          Text(`车机 ${Math.round(this.winWidth())}vp`)
            .fontSize(10)
            .fontColor($r('app.color.accentOn'))
            .backgroundColor($r('app.color.accent'))
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .height(Metrics.topBarHeight)
      // 28vp 大标题与 44vp 圆钮必须垂直居中，否则标题会顶在栏顶。
      // 注意：本机 SDK 的 Row.alignItems 参数类型是 VerticalAlign（控制交叉轴=垂直），
      // 与 hmos-arkui-develop-skill/r/quick-rules/07-attribute-params.md 写的
      // 「Row 用 HorizontalAlign.*」相反。已以编译器约束为准。
      .alignItems(VerticalAlign.Center)
      .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin })
    }
    .width('100%')
    .height(Metrics.topBarHeight)
    // 材质带由 Navigation 绘制，位置固定；内容自己上移回到状态栏下沿
    .offset({ y: this.titleOffset() })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 宽屏：左侧竖排导航 */
  @Builder
  navBar() {
    Column({ space: 4 }) {
      // 侧栏宽度只有 96~128vp，六字全称一行放不下。
      // 拆成「青芒」主标 + 「短视频」副标，既完整呈现应用名又不挤压导航项。
      Column({ space: 2 }) {
        Text('青芒')
          .fontSize(this.winWidth() >= 1280 ? 22 : 19)
          .fontColor($r('app.color.text'))
          .fontWeight(FontWeight.Bold)
        Text('短视频')
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ top: this.safeTopPx + 22, bottom: 26 })

      ForEach(NAV_ITEMS, (item: NavItem, index: number) => {
        Column({ space: this.carOnScreen ? 7 : 5 }) {
          NavIcon({ type: item.icon, active: this.tab === index && this.mode === 0,
            iconSize: this.navIconSize() })
          Text(item.label)
            .fontSize(Metrics.navLabelSize + (this.carOnScreen ? 3 : 1))
            .fontColor(this.tab === index && this.mode === 0
              ? $r('app.color.navActiveFg') : $r('app.color.textFaint'))
        }
        .width(this.navWidth() - 24)
        .height(this.navItemHeight())
        .justifyContent(FlexAlign.Center)
        .borderRadius(Metrics.cardRadius)
        // 与底部胶囊同源的选中高亮块：淡染青绿，深浅色各一份 token
        .backgroundColor(this.tab === index && this.mode === 0
          ? $r('app.color.navActiveBg') : Color.Transparent)
        .shadow(this.tab === index && this.mode === 0
          ? { radius: 10, color: $r('app.color.navActiveGlow'), offsetX: 0, offsetY: 3 }
          : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
        .scale({ x: this.navPress === index ? 0.94 : 1, y: this.navPress === index ? 0.94 : 1 })
        .animation({ duration: 180, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.navPress = index;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.navPress = -1;
          }
        })
        .onClick(() => {
          this.selectTab(index);
        })
      }, (item: NavItem) => item.label)

      Blank()
    }
    .width(this.navWidth())
    .height('100%')
    .padding({ left: this.safeLeftPx })
    // 侧栏也是一块玻璃：薄档 + 右侧一道垂直折射亮边作为分界，
    // 比 1px 实色分割线柔和，且能和底部导航条保持同一套材质语言
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
    .border({ width: { right: 1 }, color: Glass.spec(GlassTier.Thin).borderColor })
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 导航条顶部的折射高光：两端淡出、中间亮。
   * 一条等比白线看起来像描边，只有中段亮两头淡才有「玻璃边缘折射」的观感。
   *
   * 高度用 1.5 而不是 1：3.5 倍屏下 1vp 只有 3.5 物理像素，
   * 再被 0.35 左右的透明度一稀释就基本看不见了，这是「看不出玻璃」的第二个原因。
   */
  @Builder
  navHighlight() {
    Row()
      .width('88%')
      .height(1.5)
      .borderRadius(1)
      .linearGradient({
        angle: 90,
        colors: [
          ['#00FFFFFF', 0.0],
          [Glass.spec(GlassTier.Regular).highlightColor, 0.42],
          ['#00FFFFFF', 1.0]
        ]
      })
  }

  /** 底部内侧压边：玻璃下沿要比上沿暗，才有「一块有厚度的板」的观感 */
  @Builder
  navShade() {
    Row()
      .width('78%')
      .height(1)
      .borderRadius(0.5)
      .linearGradient({
        angle: 90,
        colors: [
          ['#00000000', 0.0],
          [ThemeController.isDark ? '#40000000' : '#1A000000', 0.5],
          ['#00000000', 1.0]
        ]
      })
  }

  /**
   * 底部浮起胶囊导航。
   * 选中项是纯白椭圆 + 极淡投影，未选中透明，整体半透明白叠在内容上。
   */
  @Builder
  bottomBar() {
    Row() {
      ForEach(NAV_ITEMS, (item: NavItem, index: number) => {
        // 图标从 23 放大到 27 后，2vp 间距会让图形下沿几乎贴住文字；
        // 加到 3vp，27 + 3 + 文字行高仍容得下 48vp 项高。
        Column({ space: 3 }) {
          NavIcon({ type: item.icon, active: this.tab === index })
          Text(item.label)
            .fontSize(Metrics.navLabelSize)
            // 选中态对齐系统应用：强调色文字 + 淡染高亮块，比白色椭圆的反馈更明确
            .fontColor(this.tab === index ? $r('app.color.navActiveFg') : $r('app.color.textDim'))
        }
        // 固定项宽：胶囊总宽由 NAV_ITEM_W 显式算出，不能被 layoutWeight 拉满
        .width(NAV_ITEM_W)
        .height(Metrics.floatNavItemHeight)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Metrics.floatNavItemHeight / 2)
        // 图标本身无语义，用文字标签作为无障碍描述；读屏会连同选中态一起播报
        .accessibilityText(`${item.label}${this.tab === index ? '，当前选中' : ''}`)
        // 选中项：淡染高亮块（品牌青绿），对齐应用市场的选中反馈强度
        .backgroundColor(this.tab === index ? $r('app.color.navActiveBg') : Color.Transparent)
        // 高亮块本身已是实色，不再叠白色描边（会和淡染块打架）；
        // 保留一层很轻的弥散投影，让块像浮在玻璃条上而不是印上去
        .shadow(this.tab === index
          ? { radius: 10, color: $r('app.color.navActiveGlow'), offsetX: 0, offsetY: 3 }
          : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
        .scale({ x: this.navPress === index ? 0.9 : 1, y: this.navPress === index ? 0.9 : 1 })
        .animation({ duration: 150, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.navPress = index;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.navPress = -1;
          }
        })
        .onClick(() => {
          this.selectTab(index);
          this.showNav();
        })
      }, (item: NavItem) => item.label)
    }
    // 显式总宽：Row 主轴默认撑满父约束，不写 width 就会变成「铺满整屏」
    .width(NAV_ITEM_W * NAV_ITEMS.length + NAV_PAD_X * 2)
    // 单项高 48（Metrics.floatNavItemHeight）+ 上下各 2 = 52，正好等于 Metrics.floatNavHeight。
    // 图标从 23 放大到 27 后若仍留 3vp padding，胶囊会被撑到 54vp，与底部留白计算脱节。
    .padding({ left: NAV_PAD_X, right: NAV_PAD_X, top: 2, bottom: 2 })
    .borderRadius(26)
    // 液态玻璃三层结构的第一层：模糊 + 饱和度增益 + 薄纱染色。
    // 饱和度过 1 才能让背后的海报透色（纯模糊只会发灰），
    // tint 也不能太实，否则模糊被染色盖死、玻璃退化成实色底板。
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    // 第二层是折射亮边。用非对称边而不是等比描边：
    // 玻璃是上方进光、下方出光，上边亮下边暗才有厚度感，等比白边只是一圈描边。
    .border({
      width: { left: 1, right: 1, top: 1, bottom: 1 },
      color: {
        left: Glass.spec(GlassTier.Regular).borderColor,
        right: Glass.spec(GlassTier.Regular).borderColor,
        top: Glass.spec(GlassTier.Regular).highlightColor,
        bottom: ThemeController.isDark ? '#14FFFFFF' : '#24000000'
      }
    })
    .overlay(this.navHighlight(), { align: Alignment.Top, offset: { x: 0, y: 0 } })
    .overlay(this.navShade(), { align: Alignment.Bottom, offset: { x: 0, y: 0 } })
    // 第三层：弥散投影。半径要够大、透明度要够低，玻璃才是「浮起来」而不是「贴上去」
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ bottom: this.safeBottomPx + 16 })
    .transition(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: 24 }))
        .animation({ duration: 250, curve: Curve.EaseOut })
    )
  }

  @Builder
  contentPane() {
    if (this.mode === 3) {
      SourcesView({
        onBack: () => {
          this.exitSources();
        },
        onScroll: () => {
          this.showNav();
        }
      })
        .width('100%')
        .height('100%')
    } else if (this.mode === 1) {
      DetailView({
        seriesId: this.detailId,
        onBack: () => {
          this.mode = 0;
          this.showNav();
        },
        onPlay: (seriesId: string, episodeIndex: number) => {
          this.openPlayer(seriesId, episodeIndex);
        }
      })
        .width('100%')
        .height('100%')
    } else if (this.tab === 0) {
      HomeView({
        topInset: this.topInset(),
        bottomInset: this.bottomInset(),
        onOpen: (seriesId: string) => {
          this.openDetail(seriesId);
        },
        onSearch: () => {
          this.selectTab(1);
        },
        onOpenSources: () => {
          this.openSources();
        },
        onScroll: () => {
          this.showNav();
        }
      })
        .width('100%')
        .height('100%')
    } else if (this.tab === 1) {
      SearchView({
        topInset: this.topInset(),
        bottomInset: this.bottomInset(),
        onOpen: (seriesId: string) => {
          this.openDetail(seriesId);
        },
        onScroll: () => {
          this.showNav();
        }
      })
        .width('100%')
        .height('100%')
    } else if (this.tab === 2) {
      HistoryView({
        topInset: this.topInset(),
        bottomInset: this.bottomInset(),
        onOpen: (seriesId: string, episodeIndex: number) => {
          this.openPlayer(seriesId, episodeIndex);
        },
        onScroll: () => {
          this.showNav();
        }
      })
        .width('100%')
        .height('100%')
    } else if (this.tab === 3) {
      FavoriteView({
        topInset: this.topInset(),
        bottomInset: this.bottomInset(),
        onOpen: (seriesId: string) => {
          this.openDetail(seriesId);
        },
        onScroll: () => {
          this.showNav();
        }
      })
        .width('100%')
        .height('100%')
    } else {
      SettingsView({
        bottomInset: this.bottomInset(),
        onOpenSources: () => {
          this.openSources();
        },
        onScroll: () => {
          this.showNav();
        }
      })
        .width('100%')
        .height('100%')
    }
  }

  /**
   * 内容尾部留白：浮起的胶囊会盖住内容，最后一项要能滚到它上方。
   * 注意这个值必须加在「列表内容」里，不能加在内容层容器上——
   * 加在容器上等于缩短 Scroll 视口，内容就永远滚不到胶囊背后了。
   */
  private bottomInset(): number {
    if (this.mode !== 0) {
      return 0;
    }
    // 宽屏没有浮起胶囊（导航在左侧），尾部留白只保留安全区 + 呼吸空间
    if (!this.isNarrow()) {
      return this.safeBottomPx + 24;
    }
    return Metrics.floatNavHeight + this.safeBottomPx + 24;
  }

  build() {
    // Navigation 只作容器：标题栏挂它的 title 才能拿到系统材质，
    // 内容区仍是原来的 Stack（宽屏 / 窄屏 / 播放三条分支不变），不引入路由栈。
    Navigation() {
      // 外层 Stack 始终存在，用来测量真实宽度：切分支时测量不会断
      Stack() {
        if (this.mode === 2) {
          PlayerView({
            seriesId: this.playId,
            startIndex: this.playIndex,
            onBack: () => {
              this.exitPlayer();
            }
          })
            .width('100%')
            .height('100%')
        } else if (this.isNarrow()) {
          // 手机竖屏：内容铺满全屏，胶囊是浮层，内容从它背后穿过
          Stack({ alignContent: Alignment.Bottom }) {
            Stack({ alignContent: Alignment.TopStart }) {
              Column() {
                this.contentPane()
              }
              .width('100%')
              .height('100%')
              // 只靠 onDidScroll 唤醒是漏的：搜索/历史/我的页内容常常不足一屏，
              // Scroll 根本不产生滚动回调，胶囊 2 秒隐掉后就再也唤不出来。
              // 触摸内容区任意位置同样算一次「操作」，与滚动等价。
              .onTouch((event: TouchEvent) => {
                // 只在列表页（mode 0）重置倒计时：播放页拖进度条每帧都来一次 Down，
                // 那里根本不显示胶囊，白建定时器没有意义。
                if (event.type === TouchType.Down && this.mode === 0) {
                  this.showNav();
                }
              })
              // 顶部标题栏已交给 Navigation.title（系统材质需要），这里不再叠一层
            }
            .width('100%')
            .height('100%')

            // 外层负责底部：胶囊不设宽度，天然水平居中
            if (this.mode === 0 && this.navVisible) {
              this.bottomBar()
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.bg'))
        } else {
          // 横屏 / 平板 / 超级桌面投屏：左侧导航 + 自适应内容区
          Row() {
            this.navBar()

            Column() {
              this.contentPane()
            }
            .layoutWeight(1)
            .height('100%')
            // 宽屏没有顶部小标题栏，内容要自己让开状态栏/车机异形区；
            // 横屏时 safeTop 常为 0，再补 14vp 免得大标题贴边被裁
            .padding({ top: this.safeTopPx + 14, right: this.safeRightPx })
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.bg'))
        }

        // 站源模块沙箱：隐藏 Web 组件执行已安装模块的 main.js（详见 net/ModuleRuntime.ets）。
        // 1x1 + 全透明 + 不参与命中，只做 JS 执行与回调桥接，不承载任何可见 UI。
        if (this.modulesPresent) {
          Web({ controller: ModuleRuntime.controller, src: 'about:blank' })
            .width(1)
            .height(1)
            .opacity(0)
            .hitTestBehavior(HitTestMode.None)
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .onControllerAttached(() => {
              ModuleRuntime.onControllerAttached();
            })
            .javaScriptProxy({
              object: ModuleRuntime.bridge,
              name: '__qmNative',
              methodList: ['onResult', 'persist', 'log'],
              controller: ModuleRuntime.controller
            })
            .onPageEnd(() => {
              ModuleRuntime.onPageEnd();
            })
        }
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.TopStart)
      // 内容区不设背景：材质要能透出后面的页面底色，同时避免与 bg 叠出第二层实色
      .backgroundColor(Color.Transparent)
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.viewWidth = Number(newValue.width);
        this.logBreakpoint();
      })
    }
    // 标题栏：systemMaterial 与 barStyle 无关联，但同时给 STACK 才是「压着内容」的沉浸形态
    .title(this.titleBar, {
      systemMaterial: this.titleSystemMaterial(),
      barStyle: BarStyle.STACK,
      // 内容上滑时标题栏渐变模糊。实测 COMMON_BLUR 在这套自定义标题上完全不渲染，
      // GRADUAL_BLUR 才有渐变模糊效果，同时它也是官方对沉浸光感标题栏的推荐搭配。
      scrollEffectOptions: {
        scrollEffectType: ScrollEffectType.GRADUAL_BLUR
      }
    })
    .titleMode(NavigationTitleMode.Free)
    .hideTitleBar(!this.showTitle())
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    // Navigation 默认自己避让状态栏，会把整页压到状态栏下面一条（实测 top=124px），
    // 沉浸式就断了。用 ignoreLayoutSafeArea 让布局从 y=0 起，标题栏与内容各自补 safeTop，
    // 与改造前的几何完全一致。前置条件是标题栏处于 STACK 模式，上面已经给了。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  /** 断点变化打一次日志：车机流转时用它确认布局确实按新窗口重排了 */
  private logBreakpoint(): void {
    const bp: Bp = Breakpoints.of(this.winWidth());
    if (this.bpLogged && bp === this.lastBreakpoint) {
      return;
    }
    this.bpLogged = true;
    this.lastBreakpoint = bp;
    hilog.info(0x0001, 'QingMangLayout',
      `[VERIFY] breakpoint changed to: ${Bp[bp]} windowWidth=${this.winWidth()}vp`);
  }
}
