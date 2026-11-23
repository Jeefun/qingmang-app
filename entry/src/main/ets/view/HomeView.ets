/**
 * 首页：大标题 + 搜索框 + 继续观看 + 分类 Tab + 自适应信息流。
 *
 * 尺寸取自 Mate 60 Pro 实测（1260px / 388vp @3.25）：大标题 26、副标题 12、搜索框高 43。
 * 列数不写死：手机 3 列，超级桌面/平板按窗口宽度铺满（见 Breakpoints.gridColumns）。
 */
import { LengthMetrics } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sensor } from '@kit.SensorServiceKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { Drama, GENRES, Genre, HistoryItem } from '../model/Models';
import { TAG_ALL, VIDEO_TAGS, matchesDramaTag, tagEmptyHint } from '../model/Tags';
import { SourceInfo } from '../model/SourceModels';
import { AppState } from '../store/AppState';
import { ModuleApi } from '../net/ModuleApi';
import { SourceRegistry } from '../store/SourceRegistry';
import { HomeCache, HomeSnapshot } from '../store/HomeCache';
import { Breakpoints, Bp, Metrics } from '../theme/Theme';
import { Glass, GlassSpec, GlassTier } from '../theme/Glass';
import { PosterCard, StateHint } from './Widgets';

const HOME_TAG: string = 'QingMangHome';
/** 骨架屏占位卡数量：约两行 */
const SKELETON_IDS: number[] = [1, 2, 3, 4, 5, 6];

@Component
export struct HomeView {
  @State genreIndex: number = 0;
  @State items: Drama[] = [];
  @State loading: boolean = false;
  @State errorText: string = '';
  @State hasMore: boolean = true;
  @State loadingMore: boolean = false;
  @State viewWidth: number = 0;
  @State recent: HistoryItem[] = [];
  /** 搜索框按压态 */
  @State searchPressed: boolean = false;
  /** 继续观看卡片的按压态（存 seriesId） */
  @State pressId: string = '';
  /** 当前选中的题材，TAG_ALL 表示不筛选 */
  @State activeTag: string = TAG_ALL;
  /** 标签 chip 的按压态 */
  @State tagPress: string = '';
  /** 下拉刷新中（Refresh 组件的 $$ 双向绑定） */
  @State isRefreshing: boolean = false;
  /** 车机虚拟屏：信息流卡片列数与字号随之放大（EntryAbility 实时维护） */
  @StorageProp('carMode') carMode: boolean = false;
  /** 站源切换面板 */
  @State sourceSheetOpen: boolean = false;
  @State sourceList: SourceInfo[] = [];
  @State activeSourceId: string = SourceRegistry.BUILTIN_ID;
  /** 站源 chip 按压态 */
  @State sourcePressed: boolean = false;
  /**
   * 分类列表随站源变化：内置源是固定三项，模块源取模块 categories()。
   * 初始给内置源默认值，模块激活后由 applySourceGenres 异步替换。
   */
  @State genres: Genre[] = GENRES.slice();

  private nextOffset: number = 0;
  private sessionId: string = '';
  private seen: string[] = [];
  private seq: number = 0;
  /** 数据拉取时间，跟着快照一起恢复，仅用于诊断 */
  private fetchedAt: number = 0;
  /** 滚动控制器：既要记录位置，也要在组件重建后把位置放回去 */
  private scroller: Scroller = new Scroller();
  private currentScrollY: number = 0;
  /** 重建后待恢复的偏移；-1 表示无需恢复 */
  private pendingScrollY: number = -1;
  private scrollRestored: boolean = false;
  /** 摇一摇传感器是否已挂上 */
  private shakeOn: boolean = false;
  /** 上次触发摇一摇的时间（毫秒），1500ms 去抖防止一次甩动连抽多部 */
  private lastShakeAt: number = 0;

  /** 顶部标题栏占位：内容首项要避开它，但 Scroll 视口仍从 y=0 开始 */
  @Prop topInset: number = 0;
  /** 尾部留白：最后一行要能滚到悬浮胶囊上方 */
  @Prop bottomInset: number = 0;

  onOpen: (seriesId: string) => void = () => {
  };
  onSearch: () => void = () => {
  };
  onOpenSources: () => void = () => {
  };
  onScroll: () => void = () => {
  };

  aboutToAppear(): void {
    this.refreshRecent();
    this.refreshSources();
    this.prepareThenLoad();
    // 摇一摇：加速度权限是 system_grant，声明即授予，直接订阅；
    // 同时补一次接续播放（DISTRIBUTED_DATASYNC，user_grant）的运行时授权
    this.startShake();
    this.requestContinuePermission();
  }

  aboutToDisappear(): void {
    // 组件随时可能被 if/else 分支销毁，离开前把视图状态写回快照
    this.saveSnapshot();
    this.stopShake();
  }

  /**
   * 进首页先对齐站源分类，再走「快照回填或首拉」。
   * 模块源的分类要异步取，期间 loading=true 挡住空态，避免闪「没有内容」。
   */
  private async prepareThenLoad(): Promise<void> {
    this.loading = true;
    await this.applySourceGenres();
    this.restoreOrLoad();
  }

  /** 当前激活源是模块时返回模块 id，否则空串 */
  private activeModuleId(): string {
    const id: string = SourceRegistry.activeId();
    if (id === SourceRegistry.BUILTIN_ID || !SourceRegistry.isInstalled(id)) {
      return '';
    }
    return id;
  }

  private isModuleSource(): boolean {
    return this.activeModuleId().length > 0;
  }

  /** 分类列表对齐激活源：内置源固定三项；模块源先放占位再异步取 categories() */
  private async applySourceGenres(): Promise<void> {
    const moduleId = this.activeModuleId();
    if (moduleId.length === 0) {
      this.genres = GENRES.slice();
      return;
    }
    this.genres = [new Genre('', '全部', '')];
    try {
      const list: Genre[] = await ModuleApi.categories(moduleId);
      if (list.length > 0) {
        this.genres = list;
      }
    } catch (error) {
      hilog.info(0x0001, HOME_TAG, `[HOME] module categories failed: ${(error as Error).message}`);
      // 分类拉不到时保留占位，feed 失败会给出错误提示
    }
  }

  /**
   * 进入首页：有快照先回填，一次接口都不打；只有冷启动/首次进入才请求。
   * 顺序很重要——先把 items 填上再决定是否发请求，否则用户会先看到一屏骨架。
   * 快照属于其它站源时作废：分类键对不上，回填只会出一屏错误数据。
   */
  private restoreOrLoad(): void {
    const snap: HomeSnapshot | null = HomeCache.get();
    if (snap === null || snap.items.length === 0 || snap.sourceId !== SourceRegistry.activeId()) {
      hilog.info(0x0001, HOME_TAG, '[HOME] miss, fetch first page');
      this.reload();
      return;
    }
    this.items = snap.items.slice();
    this.nextOffset = snap.nextOffset;
    this.sessionId = snap.sessionId;
    this.seen = snap.seen.slice();
    this.hasMore = snap.hasMore;
    this.genreIndex = snap.genreIndex;
    this.activeTag = snap.activeTag;
    this.fetchedAt = snap.fetchedAt;
    this.currentScrollY = snap.scrollY;
    this.pendingScrollY = snap.scrollY;
    this.loading = false;
    const ageSec: number = Math.round((Date.now() - this.fetchedAt) / 1000);
    hilog.info(0x0001, HOME_TAG,
      `[HOME] restore items=${this.items.length} genre=${this.genreIndex} tag=${this.activeTag} y=${Math.round(snap.scrollY)} age=${ageSec}s requests=0`);
  }

  /** 把当前视图状态写回进程内快照。列表为空时不写，避免用空列表盖掉好数据。 */
  private saveSnapshot(): void {
    if (this.items.length === 0) {
      return;
    }
    const snap = new HomeSnapshot();
    snap.items = this.items.slice();
    snap.nextOffset = this.nextOffset;
    snap.sessionId = this.sessionId;
    snap.seen = this.seen.slice();
    snap.hasMore = this.hasMore;
    snap.genreIndex = this.genreIndex;
    snap.activeTag = this.activeTag;
    snap.scrollY = this.currentScrollY;
    snap.fetchedAt = this.fetchedAt;
    snap.sourceId = SourceRegistry.activeId();
    HomeCache.save(snap);
  }

  /** 继续观看取最近 5 条历史 */
  private refreshRecent(): void {
    try {
      const list = AppState.history.list();
      this.recent = list.slice(0, 5);
    } catch (error) {
      this.recent = [];
    }
  }

  /** 站源列表与激活态 */
  private refreshSources(): void {
    this.sourceList = SourceRegistry.sources();
    this.activeSourceId = SourceRegistry.activeId();
  }

  private activeSourceName(): string {
    for (const info of this.sourceList) {
      if (info.id === this.activeSourceId) {
        return info.name;
      }
    }
    return SourceRegistry.BUILTIN_NAME;
  }

  private pickSource(info: SourceInfo): void {
    if (info.id === this.activeSourceId) {
      this.sourceSheetOpen = false;
      return;
    }
    if (SourceRegistry.activate(info.id)) {
      this.refreshSources();
      this.getUIContext().getPromptAction()
        .showToast({ message: `已切换到「${info.name}」`, duration: 1500 });
      this.sourceSheetOpen = false;
      // 模块源激活后触发一次设备注册（模块 devices 能力），失败静默
      if (info.kind === 'module') {
        AppState.api.registerDevice().catch((): void => {
        });
      }
      this.switchSourceReload();
      return;
    }
    this.getUIContext().getPromptAction()
      .showToast({ message: '该站源未安装，请先到站源管理安装', duration: 2200 });
  }

  /** 切源后整页重载：清列表与筛选态，按新源重取分类与首页 */
  private switchSourceReload(): void {
    this.seq++;
    this.items = [];
    this.errorText = '';
    this.hasMore = true;
    this.seen = [];
    this.sessionId = '';
    this.nextOffset = 0;
    this.genreIndex = 0;
    this.activeTag = TAG_ALL;
    this.currentScrollY = 0;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.prepareThenLoad();
  }

  /** 继续观看还剩多少分钟（不足 1 分钟记 1） */
  private remainLabel(item: HistoryItem): string {
    const remainMs: number = item.durationMs - item.positionMs;
    if (item.durationMs <= 0 || remainMs <= 0) {
      return '';
    }
    return `还剩 ${Math.max(1, Math.round(remainMs / 60000))} 分钟`;
  }

  /**
   * 订阅加速度传感器实现摇一摇。
   * ACCELEROMETER 是 normal 级 system_grant 权限，无需运行时弹窗；
   * 无传感器的设备（部分车机/2in1）订阅会抛错，静默降级即可。
   */
  private startShake(): void {
    if (this.shakeOn) {
      return;
    }
    try {
      sensor.on(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        // 静止时合加速度约 9.8 m/s²；用力甩动峰值远超 25
        const magnitude: number =
          Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
        if (magnitude < 25) {
          return;
        }
        const now: number = Date.now();
        if (now - this.lastShakeAt < 1500) {
          return;
        }
        this.lastShakeAt = now;
        this.pickLucky();
      }, { interval: 200000000 }); // 200ms 采样：够灵敏也省电
      this.shakeOn = true;
      hilog.info(0x0001, HOME_TAG, '[HOME] shake sensor on (200ms)');
    } catch (error) {
      hilog.warn(0x0001, HOME_TAG, '[HOME] shake sensor unavailable');
    }
  }

  private stopShake(): void {
    if (!this.shakeOn) {
      return;
    }
    try {
      sensor.off(sensor.SensorId.ACCELEROMETER);
    } catch (error) {
      // 传感器可能已随组件销毁释放
    }
    this.shakeOn = false;
  }

  /** 摇一摇剧荒盲盒：从当前信息流随机抽一部，toast 提示后进详情 */
  private pickLucky(): void {
    if (this.loading || this.items.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '内容加载中，稍后再摇', duration: 1500 });
      return;
    }
    const index: number = Math.floor(Math.random() * this.items.length);
    const pick: Drama = this.items[index];
    this.getUIContext().getPromptAction()
      .showToast({ message: `摇到了《${pick.title}》，看看合不合口味`, duration: 2000 });
    hilog.info(0x0001, HOME_TAG, `[HOME] shake lucky pick: ${pick.seriesId}`);
    this.onOpen(pick.seriesId);
  }

  /** 接续播放授权（DISTRIBUTED_DATASYNC，user_grant）：进首页时一次弹窗，拒绝则跨设备接续静默不可用 */
  private requestContinuePermission(): void {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        return;
      }
      const manager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = ['ohos.permission.DISTRIBUTED_DATASYNC'];
      manager.requestPermissionsFromUser(context as common.UIAbilityContext, perms)
        .catch(() => {
          // 用户拒绝不影响其他功能
        });
    } catch (error) {
      hilog.warn(0x0001, HOME_TAG, '[HOME] continue permission request failed');
    }
  }

  /** 当前分类。模块源分类数与内置源不同，快照下标可能越界，兜底回第一项 */
  private currentGenre(): Genre {
    if (this.genreIndex >= 0 && this.genreIndex < this.genres.length) {
      return this.genres[this.genreIndex];
    }
    if (this.genres.length > 0) {
      return this.genres[0];
    }
    return new Genre('', '全部', '');
  }

  async reload(): Promise<void> {
    const token = ++this.seq;
    this.loading = true;
    this.errorText = '';
    this.nextOffset = 0;
    this.sessionId = '';
    this.seen = [];

    try {
      await AppState.ensureReady();
      const genre = this.currentGenre();
      const page = await AppState.api.feed(genre.key, genre.scene, 0, '', []);
      if (token !== this.seq) {
        return;
      }
      this.items = page.items;
      this.nextOffset = page.nextOffset;
      this.sessionId = page.sessionId;
      this.hasMore = page.hasMore;
      for (const item of page.items) {
        this.seen.push(item.seriesId);
      }
      this.fetchedAt = Date.now();
      this.saveSnapshot();
      hilog.info(0x0001, HOME_TAG, `[HOME] fetch ok items=${page.items.length} genre=${genre.key}`);
    } catch (error) {
      if (token !== this.seq) {
        return;
      }
      hilog.info(0x0001, HOME_TAG, `[HOME] fetch failed: ${(error as Error).message}`);
      // 列表为空才进错误页；已有内容时不把好数据换成错误提示
      if (this.items.length === 0) {
        this.errorText = (error as Error).message;
      }
    } finally {
      if (token === this.seq) {
        this.loading = false;
        // 首屏加载完再补拉冷门题材。放在 finally 而不是 try 末尾，
        // 是因为 loadMore 会因 this.loading 为 true 而直接短路。
        this.ensureTagResults();
      }
    }
  }

  async loadMore(): Promise<void> {
    if (!this.hasMore || this.loading || this.loadingMore || this.nextOffset <= 0) {
      return;
    }
    const token = this.seq;
    this.loadingMore = true;
    try {
      const genre = this.currentGenre();
      const page = await AppState.api.feed(genre.key, genre.scene, this.nextOffset, this.sessionId, this.seen);
      if (token !== this.seq) {
        return;
      }
      const merged = this.items.slice();
      for (const item of page.items) {
        let exists = false;
        for (const known of merged) {
          if (known.seriesId === item.seriesId) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          merged.push(item);
          this.seen.push(item.seriesId);
        }
      }
      this.items = merged;
      this.nextOffset = page.nextOffset;
      this.sessionId = page.sessionId.length > 0 ? page.sessionId : this.sessionId;
      this.hasMore = page.hasMore;
      // 翻页后的合并列表也要进快照，否则切走再回来会退回第一页
      this.saveSnapshot();
      hilog.info(0x0001, HOME_TAG, `[HOME] more ok total=${this.items.length}`);
    } catch (error) {
      this.hasMore = false;
    } finally {
      this.loadingMore = false;
    }
  }

  private isNarrow(): boolean {
    return !Breakpoints.isWide(this.winWidth());
  }

  private winWidth(): number {
    return this.viewWidth > 0 ? this.viewWidth : 360;
  }

  /** 车机文字加两档：与 HistoryView / PlayerView 同一套放大规则 */
  private carFont(size: number): number {
    return this.carMode ? size + 2 : size;
  }

  /** 随断点变化的页面左右边距 */
  private pad(): number {
    return Breakpoints.pagePadding(this.winWidth());
  }

  /** 信息流列数：手机 3 列，宽屏按窗口宽度铺满；车机用大卡档（200/168vp） */
  private columns(): number {
    return Breakpoints.gridColumns(this.winWidth(), this.carMode);
  }

  private cardWidth(): number {
    return Breakpoints.cardWidth(this.winWidth(), this.columns());
  }

  /** 继续观看卡片：宽屏放大，手机保持实测 215x122 */
  private recentCardWidth(): number {
    const bp = Breakpoints.of(this.winWidth());
    if (bp === Bp.Xl) {
      return 300;
    }
    if (bp === Bp.Lg) {
      return 260;
    }
    if (bp === Bp.Md) {
      return 236;
    }
    return 215;
  }

  private recentCardHeight(): number {
    return Math.round(this.recentCardWidth() * 0.567);
  }

  /** 继续观看 hero 大卡高度：比小卡高约四成，宽屏再放大 */
  private recentHeroHeight(): number {
    const bp = Breakpoints.of(this.winWidth());
    if (bp === Bp.Xl || bp === Bp.Lg) {
      return 200;
    }
    if (bp === Bp.Md) {
      return 180;
    }
    return 168;
  }

  /** 首条已升为 hero 大卡，横滑区只放剩余条目 */
  private restRecent(): HistoryItem[] {
    return this.recent.slice(1);
  }

  /** 按题材过滤后的列表。不做缓存：items 变化由 @State 驱动重算，缓存反而容易脏 */
  private visibleItems(): Drama[] {
    if (this.activeTag === TAG_ALL) {
      return this.items;
    }
    const out: Drama[] = [];
    for (const item of this.items) {
      if (matchesDramaTag(item.tagList, this.activeTag)) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 冷门题材（恐怖、科幻等）在首页第一页可能一部都没有。
   * 这时自动多翻几页再筛，而不是直接甩一个空态给用户——
   * 「空」既可能是筛选没命中，也可能是还没加载够，必须先排除后者。
   */
  private async ensureTagResults(): Promise<void> {
    if (this.activeTag === TAG_ALL || !this.hasMore) {
      return;
    }
    let tries: number = 0;
    while (tries < 3 && this.hasMore && !this.loadingMore && this.visibleItems().length < 6) {
      tries++;
      await this.loadMore();
    }
  }

  /** 下拉刷新：重新拉第一页 + 补「继续观看」，完成后收起指示器 */
  private async pullToRefresh(): Promise<void> {
    this.refreshRecent();
    await this.reload();
    this.isRefreshing = false;
  }

  /**
   * 换一批：跳到下一页取新内容整屏替换；已翻到底就从第一页重来。
   * 请求期间旧内容保持可见，不闪骨架屏。
   */
  private async refreshBatch(): Promise<void> {
    if (this.loading || this.loadingMore) {
      return;
    }
    const token = ++this.seq;
    this.loading = true;
    try {
      await AppState.ensureReady();
      const genre = this.currentGenre();
      let offset = this.nextOffset;
      let session = this.sessionId;
      let seen = this.seen.slice();
      if (!this.hasMore || offset <= 0) {
        offset = 0;
        session = '';
        seen = [];
      }
      const page = await AppState.api.feed(genre.key, genre.scene, offset, session, seen);
      if (token !== this.seq) {
        return;
      }
      this.items = page.items;
      this.nextOffset = page.nextOffset;
      this.sessionId = page.sessionId.length > 0 ? page.sessionId : session;
      this.hasMore = page.hasMore;
      this.seen = [];
      for (const item of page.items) {
        this.seen.push(item.seriesId);
      }
      this.fetchedAt = Date.now();
      this.currentScrollY = 0;
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
      this.saveSnapshot();
      hilog.info(0x0001, HOME_TAG, `[HOME] batch ok items=${page.items.length} genre=${genre.key}`);
    } catch (error) {
      if (token === this.seq && this.items.length === 0) {
        this.errorText = (error as Error).message;
      }
    } finally {
      if (token === this.seq) {
        this.loading = false;
        this.ensureTagResults();
      }
    }
  }

  private selectTag(tag: string): void {
    if (this.activeTag === tag) {
      return;
    }
    this.activeTag = tag;
    // 筛选态也要进快照：切走再回来不该把用户选的题材重置成「全部」
    this.saveSnapshot();
    this.ensureTagResults();
  }

  private subtitle(): string {
    const count: number = this.visibleItems().length;
    if (count > 0) {
      return `${count} 部 · 每日更新`;
    }
    return '每日更新 · 点开即看';
  }

  /** 标题区：大标题 + 副标题 + 搜索框 */
  @Builder
  headerBlock() {
    Column() {
      Text('今晚，看点短的')
        .fontSize(Metrics.heroTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
        .width('100%')

      Text(this.subtitle())
        .fontSize(Metrics.smallSize - 1)
        .fontColor($r('app.color.textFaint'))
        .margin({ top: 9 })
        .width('100%')

      Row({ space: 6 }) {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.accent'))
        Text(this.activeSourceName())
          .fontSize(Metrics.smallSize - 1)
          .fontColor($r('app.color.textDim'))
        Text('切换')
          .fontSize(Metrics.smallSize - 2)
          .fontColor($r('app.color.textFaint'))
      }
      .height(26)
      .padding({ left: 11, right: 11 })
      .backgroundColor(Glass.listTint())
      .border({ width: 1, color: Glass.listBorder() })
      .borderRadius(13)
      .alignSelf(ItemAlign.Start)
      .margin({ top: 10 })
      .scale({ x: this.sourcePressed ? 0.96 : 1, y: this.sourcePressed ? 0.96 : 1 })
      .animation({ duration: 130, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.sourcePressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.sourcePressed = false;
        }
      })
      .onClick(() => {
        this.refreshSources();
        this.sourceSheetOpen = true;
      })
      .bindSheet($$this.sourceSheetOpen, this.sourceSheetPane(), {
        height: 380,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.bg')
      })

      Row() {
        Text('搜剧名、演员或关键词')
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textFaint'))
        Blank()
        Text('搜索')
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.text'))
      }
      .width('100%')
      .constraintSize({ maxWidth: 440 })
      .height(Metrics.searchHeight)
      .padding({ left: 18, right: 18 })
      // 这是个自绘的「伪输入框」，读屏不会把它识别成可点击控件，
      // 必须显式给出无障碍文本，否则读屏用户找不到搜索入口
      .accessibilityText('搜索剧名、演员或关键词，点击进入搜索页')
      // 搜索框做成玻璃条：下方海报滚动时颜色会从框里透出来，
      // 比一块实色底更「浮」在内容上
      .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
      .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
      .borderRadius(Metrics.searchHeight / 2)
      .shadow({
        radius: Glass.spec(GlassTier.Thin).shadowRadius,
        color: Glass.spec(GlassTier.Thin).shadowColor,
        offsetX: 0,
        offsetY: 4
      })
      .margin({ top: 15 })
      .scale({ x: this.searchPressed ? 0.985 : 1, y: this.searchPressed ? 0.985 : 1 })
      .animation({ duration: 130, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.searchPressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.searchPressed = false;
        }
      })
      .onClick(() => {
        this.onSearch();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 继续观看：首条全宽 hero 大卡，其余横滑小卡 */
  @Builder
  recentHeroCard(item: HistoryItem) {
    Stack({ alignContent: Alignment.Bottom }) {
      Image(item.cover)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .autoResize(true)
        .backgroundColor($r('app.color.surfaceHigh'))
        .alt($r('app.media.startIcon'))

      // 底部整幅渐变，托住标题与进度信息
      Text('')
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.35], ['#99000000', 1]]
        })

      Column({ space: 9 }) {
        Row() {
          Text(item.title)
            .fontSize(Metrics.bodySize + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text('继续播')
            .fontSize(Metrics.smallSize)
            .fontColor(Color.White)
            .height(30)
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.accent'))
            .borderRadius(15)
            .margin({ left: 12 })
        }
        .width('100%')

        Row({ space: 9 }) {
          Text(`看到第 ${item.episodeIndex} 集`)
            .fontSize(Metrics.tinySize)
            .fontColor('#E6FFFFFF')
          if (this.remainLabel(item).length > 0) {
            Text(this.remainLabel(item))
              .fontSize(Metrics.tinySize)
              .fontColor('#B3FFFFFF')
          }
        }
        .width('100%')

        Row() {
          Row()
            .width(`${Math.round(item.progress * 100)}%`)
            .height(3)
            .backgroundColor($r('app.color.accent'))
          Row()
            .layoutWeight(1)
            .height(3)
            .backgroundColor('#59FFFFFF')
        }
        .width('100%')
        .height(3)
      }
      .width('100%')
      .padding({ left: 14, right: 14, bottom: 13 })
    }
    .width('100%')
    .height(this.recentHeroHeight())
    .borderRadius(Metrics.cardRadius)
    .clip(true)
    .scale({ x: this.pressId === item.seriesId ? 0.98 : 1, y: this.pressId === item.seriesId ? 0.98 : 1 })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressId = item.seriesId;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressId = '';
      }
    })
    .onClick(() => {
      this.onOpen(item.seriesId);
    })
  }

  /** 继续观看：横版小卡，封面底部叠进度 */
  @Builder
  recentBlock() {
    Column() {
      Text('继续观看')
        .fontSize(Metrics.smallSize)
        .fontColor($r('app.color.textDim'))
        .width('100%')
        .margin({ bottom: 11 })

      if (this.recent.length > 0) {
        this.recentHeroCard(this.recent[0])
      }

      if (this.recent.length > 1) {
        Scroll() {
          Row({ space: 11 }) {
            ForEach(this.restRecent(), (item: HistoryItem) => {
              Column({ space: 8 }) {
                Stack({ alignContent: Alignment.Bottom }) {
                  Image(item.cover)
                    .width('100%')
                    .height(this.recentCardHeight())
                    .objectFit(ImageFit.Cover)
                    // 官方《性能提升建议》：源图远大于显示尺寸时开启自动降采样，
                    // 避免按原分辨率解码吃掉内存（信息流封面最典型）
                    .autoResize(true)
                    .backgroundColor($r('app.color.surfaceHigh'))
                    .alt($r('app.media.startIcon'))

                  // 底部渐变，保证「看到第 N 集」读得清
                  Text('')
                    .width('100%')
                    .height(56)
                    .linearGradient({
                      angle: 180,
                      colors: [['#00000000', 0], ['#99000000', 1]]
                    })

                  Text(`看到第 ${item.episodeIndex} 集`)
                    .fontSize(Metrics.tinySize)
                    .fontColor(Color.White)
                    .width('100%')
                    .padding({ left: 12, bottom: 14 })

                  // 进度条：已看红色，剩余半透明白
                  Row() {
                    Row()
                      .width(`${Math.round(item.progress * 100)}%`)
                      .height(3)
                      .backgroundColor($r('app.color.accent'))
                    Row()
                      .layoutWeight(1)
                      .height(3)
                      .backgroundColor($r('app.color.trackOff'))
                  }
                  .width('100%')
                  .height(3)
                }
                .width(this.recentCardWidth())
                .height(this.recentCardHeight())
                .borderRadius(Metrics.cardRadius)
                .clip(true)

              Text(item.title)
                .fontSize(Metrics.smallSize)
                .fontColor($r('app.color.text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(this.recentCardWidth())
              }
              .scale({ x: this.pressId === item.seriesId ? 0.96 : 1, y: this.pressId === item.seriesId ? 0.96 : 1 })
              .animation({ duration: 140, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.pressId = item.seriesId;
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.pressId = '';
                }
              })
              .onClick(() => {
                this.onOpen(item.seriesId);
              })
            }, (item: HistoryItem) => `${item.seriesId}`)
          }
          .padding({ left: this.pad(), right: this.pad() })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: 11 })
      }
    }
    .width('100%')
    .margin({ top: 24 })
  }

  /** 站源切换半模态面板 */
  @Builder
  sourceSheetPane() {
    Column({ space: 0 }) {
      Row() {
        Text('切换站源')
          .fontSize(Metrics.bodySize + 1)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
        Blank()
        Text('收起')
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textDim'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.sourceSheetOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 10 })

      Scroll() {
        Column() {
          ForEach(this.sourceList, (info: SourceInfo) => {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                Row({ space: 7 }) {
                  Text(info.name)
                    .fontSize(Metrics.bodySize)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (info.adult) {
                    Text('18+')
                      .fontSize(Metrics.tinySize - 1)
                      .fontColor('#FF6B5E')
                      .height(17)
                      .padding({ left: 6, right: 6 })
                      .border({ width: 1, color: '#66FF6B5E' })
                      .borderRadius(4)
                  }
                }
                .alignItems(VerticalAlign.Center)

                if (info.description.length > 0) {
                  Text(info.description)
                    .fontSize(Metrics.smallSize - 1)
                    .fontColor($r('app.color.textFaint'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (info.id === this.activeSourceId) {
                Text('使用中')
                  .fontSize(Metrics.smallSize - 1)
                  .fontColor($r('app.color.text'))
                  .height(26)
                  .padding({ left: 11, right: 11 })
                  .backgroundColor(Glass.accentTint())
                  .borderRadius(13)
              } else if (!info.runnable) {
                Text('待运行时')
                  .fontSize(Metrics.smallSize - 1)
                  .fontColor($r('app.color.textFaint'))
                  .height(26)
                  .padding({ left: 11, right: 11 })
                  .border({ width: 1, color: Glass.listBorder() })
                  .borderRadius(13)
              } else {
                Text('切换')
                  .fontSize(Metrics.smallSize - 1)
                  .fontColor($r('app.color.textDim'))
                  .height(26)
                  .padding({ left: 11, right: 11 })
                  .border({ width: 1, color: Glass.listBorder() })
                  .borderRadius(13)
              }
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 11, bottom: 11 })
            .onClick(() => {
              this.pickSource(info);
            })
          }, (info: SourceInfo) => `${info.id}_${this.activeSourceId}`)

          Divider()
            .color(Glass.listBorder())
            .margin({ left: 20, right: 20, top: 8, bottom: 4 })

          Row({ space: 9 }) {
            Text('管理站源')
              .fontSize(Metrics.bodySize)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text'))
            Text('安装与卸载内容源模块')
              .fontSize(Metrics.smallSize - 1)
              .fontColor($r('app.color.textFaint'))
              .layoutWeight(1)
              .maxLines(1)
            Text('›')
              .fontSize(Metrics.bodySize + 2)
              .fontColor($r('app.color.textFaint'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 20, right: 20, top: 11, bottom: 16 })
          .onClick(() => {
            this.sourceSheetOpen = false;
            this.onOpenSources();
          })
        }
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  /** 分类：文字 + 选中下划线，右侧带「换一批」 */
  @Builder
  genreTabs() {
    Row() {
      Row({ space: 22 }) {
        ForEach(this.genres, (genre: Genre, index: number) => {
          Column({ space: 7 }) {
            Text(genre.name)
              .fontSize(Metrics.bodySize)
              .fontWeight(index === this.genreIndex ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(index === this.genreIndex ? $r('app.color.text') : $r('app.color.textFaint'))

            Row()
              .width(index === this.genreIndex ? 18 : 6)
              .height(3)
              .borderRadius(2)
              .backgroundColor(index === this.genreIndex ? $r('app.color.ink') : Color.Transparent)
              .animation({ duration: 200, curve: Curve.EaseOut })
          }
          .onClick(() => {
            if (this.genreIndex === index) {
              // 会话内列表常驻内存，重复点当前分类就是用户主动刷新的入口
              hilog.info(0x0001, HOME_TAG, '[HOME] manual refresh');
            } else {
              this.genreIndex = index;
            }
            this.currentScrollY = 0;
            this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
            this.reload();
          })
        }, (genre: Genre) => genre.key)
      }
      .layoutWeight(1)

      Text(this.loading || this.loadingMore ? '更换中' : '换一批')
        .fontSize(this.carFont(Metrics.smallSize))
        .fontColor($r('app.color.textDim'))
        .height(30)
        .padding({ left: 13, right: 13 })
        .backgroundColor($r('app.color.surfaceHigh'))
        .borderRadius(15)
        .alignSelf(ItemAlign.Center)
        .onClick(() => {
          this.refreshBatch();
        })
    }
    .width('100%')
    .margin({ top: 22, bottom: 14 })
  }

  /** 骨架卡片：封面灰块 + 两行文字占位，弱化首屏白屏感 */
  @Builder
  skeletonCard() {
    Column({ space: 8 }) {
      Column()
        .width('100%')
        .height(Math.round(this.cardWidth() * Metrics.posterRatio))
        .borderRadius(Metrics.posterRadius)
        .backgroundColor($r('app.color.surfaceHigh'))

      Column()
        .width('70%')
        .height(11)
        .borderRadius(6)
        .backgroundColor($r('app.color.surfaceHigh'))

      Column()
        .width('45%')
        .height(10)
        .borderRadius(5)
        .backgroundColor($r('app.color.surfaceHigh'))
    }
    .width(this.cardWidth())
  }

  /** 标签 chip 的玻璃底色：选中走强调色，未选中走中性薄玻璃 */
  private tagEffect(active: boolean): BackgroundEffectOptions {
    const spec: GlassSpec = Glass.spec(GlassTier.Thin);
    const opt: BackgroundEffectOptions = {
      radius: spec.blurRadius,
      saturation: spec.saturation,
      brightness: spec.brightness,
      color: active ? Glass.accentTint() : spec.tint
    };
    return opt;
  }

  /**
   * 题材筛选栏：横向滚动的玻璃 chip。
   * 放在分类 Tab 下方——分类决定「看哪一类短剧」，题材决定「看什么故事」，
   * 这是两级筛选，顺序不能反。
   */
  @Builder
  tagBar() {
    Column() {
      Row() {
        Text('按题材筛选')
          .fontSize(Metrics.smallSize - 1)
          .fontColor($r('app.color.textDim'))
        Blank()
        Text(this.activeTag === TAG_ALL
          ? `${this.items.length} 部`
          : `${this.visibleItems().length} 部`)
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
      }
      .width('100%')
      .margin({ bottom: 10 })

      Scroll() {
        Row({ space: 8 }) {
          ForEach(VIDEO_TAGS, (tag: string) => {
            // 选中态对齐系统应用的「精选」胶囊：实心强调色 + 深色文字。
            // 莱姆绿是亮色，配白字对比度不足，所以前景用 chipOn（近黑）而不是 inkOn。
            Text(tag)
              .fontSize(this.carFont(Metrics.tinySize + 1))
              .fontWeight(this.activeTag === tag ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.activeTag === tag ? $r('app.color.chipOn') : $r('app.color.text'))
              .padding({
                left: this.carMode ? 20 : 16, right: this.carMode ? 20 : 16,
                top: this.carMode ? 11 : 8, bottom: this.carMode ? 11 : 8
              })
              // 选中走实心强调色，未选中走静态半透明底。
              // 题材栏横向滚动，若每个 chip 都挂实时模糊，滚动必掉帧。
              .backgroundColor(this.activeTag === tag ? $r('app.color.lime') : Glass.listTint())
              .border({
                width: this.activeTag === tag ? 0 : 1,
                color: Glass.listBorder()
              })
              .borderRadius(Metrics.chipRadius)
              .scale({ x: this.tagPress === tag ? 0.93 : 1, y: this.tagPress === tag ? 0.93 : 1 })
              .animation({ duration: 140, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.tagPress = tag;
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.tagPress = '';
                }
              })
              .onClick(() => {
                this.selectTag(tag);
              })
          }, (tag: string) => tag)
        }
        .padding({ right: this.pad() })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .margin({ bottom: 16 })
  }

  build() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      Scroll(this.scroller) {
        Column() {
          Column() {
            this.headerBlock()

            if (this.recent.length > 0) {
              this.recentBlock()
            }

            this.genreTabs()

            // 题材标签是内置源的筛选维度，模块源没有对应数据，隐藏
            if (!this.isModuleSource()) {
              this.tagBar()
            }

            if (this.loading && this.items.length === 0) {
              Flex({
                wrap: FlexWrap.Wrap,
                justifyContent: FlexAlign.Start,
                space: { main: LengthMetrics.vp(Metrics.cardGap), cross: LengthMetrics.vp(18) }
              }) {
                ForEach(SKELETON_IDS, (id: number) => {
                  this.skeletonCard()
                }, (id: number) => `sk${id}`)
              }
              .width('100%')
            } else if (this.errorText.length > 0 && this.items.length === 0) {
              Row() {
                StateHint({
                  message: '内容加载失败',
                  detail: this.errorText,
                  actionText: '重新加载',
                  onAction: () => {
                    this.reload();
                  }
                })
              }
              .width('100%')
              .height(240)
            } else if (this.visibleItems().length === 0) {
              Row() {
                // 区分两种情况：整类没内容 vs 筛选没命中。
                // 后者要给出「清除筛选」这个出口，否则用户会以为加载坏了。
                if (this.activeTag !== TAG_ALL && this.items.length > 0 && !this.loadingMore) {
                  StateHint({
                    message: tagEmptyHint(this.activeTag),
                    detail: '换个题材，或查看当前分类的全部内容',
                    actionText: '清除筛选',
                    onAction: () => {
                      this.selectTag(TAG_ALL);
                    }
                  })
                } else if (this.loadingMore) {
                  StateHint({ message: '正在查找题材…', busy: true })
                } else {
                  StateHint({ message: '这个分类暂时没有内容', detail: '换一个分类试试' })
                }
              }
              .width('100%')
              .height(240)
            } else {
              Flex({
                wrap: FlexWrap.Wrap,
                justifyContent: FlexAlign.Start,
                space: { main: LengthMetrics.vp(Metrics.cardGap), cross: LengthMetrics.vp(18) }
              }) {
                ForEach(this.visibleItems(), (item: Drama) => {
                  PosterCard({
                    title: item.displayTitle,
                    cover: item.cover,
                    meta: item.displayMeta,
                    cardWidth: this.cardWidth(),
                    fontBoost: this.carMode ? 1.15 : 1,
                    seriesId: item.seriesId,
                    onSelect: (id: string) => {
                      this.onOpen(id);
                    }
                  })
                }, (item: Drama) => `${item.seriesId}`)
              }
              .width('100%')

              if (this.loadingMore) {
                Row() {
                  LoadingProgress()
                    .width(26)
                    .height(26)
                    .color($r('app.color.accent'))
                  Text('加载更多…')
                    .fontSize(Metrics.smallSize)
                    .fontColor($r('app.color.textDim'))
                    .margin({ left: 8 })
                }
                .height(56)
                .justifyContent(FlexAlign.Center)
                .width('100%')
              } else if (!this.hasMore) {
                Text('没有更多了')
                  .fontSize(Metrics.smallSize)
                  .fontColor($r('app.color.textFaint'))
                  .height(56)
                  .width('100%')
                  .textAlign(TextAlign.Center)
              }
            }
          }
          .width('100%')
          .padding({ left: this.pad(), right: this.pad(), top: this.topInset, bottom: this.bottomInset })
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .onDidScroll(() => {
        this.onScroll();
        this.currentScrollY = this.scroller.currentOffset().yOffset;
      })
      .onReachEnd(() => {
        this.loadMore();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .onRefreshing(() => {
      this.pullToRefresh();
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.viewWidth = Number(newValue.width);
      // 首帧布局完成后才把上次的滚动位置放回去；在 aboutToAppear 里直接 scrollTo
      // 会因为内容尚未测量而被截断到 0
      if (!this.scrollRestored && this.pendingScrollY > 0 && Number(newValue.height) > 0) {
        this.scrollRestored = true;
        this.scroller.scrollTo({ xOffset: 0, yOffset: this.pendingScrollY });
      }
    })
  }
}
