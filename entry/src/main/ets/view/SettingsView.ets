/**
 * 「我的」页：外观、播放、弹幕、存储。
 *
 * 布局取自手机实测：大标题 26 + 右上版本号，分组标题小号灰字，
 * 每张卡片白底圆角、内边距 16；分段胶囊选中态为墨黑实底。
 */
import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { bundleManager } from '@kit.AbilityKit';
import { Breakpoints, Metrics, ThemeController, ThemeMode } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';
import { Settings } from '../store/Settings';
import { AppState } from '../store/AppState';
import { CachedEpisode } from '../store/CacheIndex';
import { SourceRegistry } from '../store/SourceRegistry';
import { SegmentedChip } from './Widgets';

/** 倍速档位（真实倍数，不是 PlaybackSpeed 枚举下标） */
const SPEED_OPTIONS: number[] = [0.75, 1, 1.5, 1.75, 2, 2.5, 3, 4, 5];
const THEME_OPTIONS: ThemeMode[] = [ThemeMode.System, ThemeMode.Light, ThemeMode.Dark];
/** 弹幕字号档位（vp）与区域档位（占视频区高度比例） */
const DM_SIZE_OPTIONS: number[] = [13, 15, 18];
const DM_SIZE_LABELS: string[] = ['小', '中', '大'];
const DM_AREA_VALUES: number[] = [0.3, 0.55, 1];
const DM_AREA_LABELS: string[] = ['顶部', '中部', '全屏'];
/** 同屏弹幕上限档位：稀疏 / 标准 / 密集 */
const DM_DENSITY_VALUES: number[] = [6, 12, 20];
const DM_DENSITY_LABELS: string[] = ['稀疏', '标准', '密集'];
/** 弹幕颜色档位（与播放器面板一致） */
const DM_COLOR_VALUES: string[] = ['#FFFFFF', '#FFE24A', '#4AF0FF', '#FF7AC8', '#6CFF66'];
/** 弹幕滚动速度档位（与播放器面板一致） */
const DM_SPEED_VALUES: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
const DM_SPEED_LABELS: string[] = ['慢速', '稍慢', '标准', '稍快', '快速', '极速'];
/** 缓存保留档位：6 / 12 / 24 集 */
const CACHE_KEEP_OPTIONS: number[] = [6, 12, 24];

@Component
export struct SettingsView {
  @StorageProp('safeTop') safeTopPx: number = 0;
  @State viewWidth: number = 0;
  /** 尾部留白：最后一张卡片要能滚到悬浮胶囊上方 */
  @Prop bottomInset: number = 0;

  onScroll: () => void = () => {
  };
  onOpenSources: () => void = () => {
  };
  @State themeMode: ThemeMode = ThemeController.mode;
  @State speed: number = Settings.speed;
  @State danmaku: boolean = Settings.danmaku;
  @State danmakuOpacity: number = Settings.danmakuOpacity;
  @State danmakuSize: number = Settings.danmakuSize;
  @State danmakuArea: number = Settings.danmakuArea;
  @State danmakuDensity: number = Settings.danmakuDensity;
  @State danmakuColorIdx: number = Settings.danmakuColor;
  @State danmakuMerge: boolean = Settings.danmakuMerge;
  @State danmakuSpeed: number = Settings.danmakuSpeed;
  /** 弹幕屏蔽词（Settings 内部持久化，这里只做展示副本） */
  @State blockedWords: string[] = Settings.danmakuBlocked.slice();
  @State newWord: string = '';
  @State cacheKeep: number = Settings.cacheKeep;
  @State cachedEpisodes: CachedEpisode[] = [];
  /** 缓存列表排序：false=按时间（新→旧） true=按大小（大→小） */
  @State sortBySize: boolean = false;
  /** 清空确认态：第一次点「清理」变红字「确认清空？」，3 秒不点自动复位 */
  @State confirmClear: boolean = false;
  @State backgroundPlay: boolean = Settings.backgroundPlay;
  @State autoNext: boolean = Settings.autoNext;
  @State reduceTransparency: boolean = Settings.reduceTransparency;
  @State reduceMotion: boolean = Settings.reduceMotion;
  @State cacheText: string = '计算中…';
  @State clearing: boolean = false;
  @State version: string = '1.0.0';
  /** 内部版本号，反馈问题时用它唯一定位构建 */
  @State versionCode: number = 0;
  /** 观看时长：今日 / 本周（秒），进页时读一次 */
  @State todaySeconds: number = 0;
  @State weekSeconds: number = 0;
  /** 手风琴当前展开的分组下标；-1 = 全收起。进页默认全收起，不记忆 */
  @State expandedIndex: number = -1;
  private confirmTimer: number = -1;

  /** 折叠分组表：标题 + 一句副标题（收起时的内容预览） */
  private static sectionTitles(): string[] {
    return ['外观', '播放', '弹幕', '存储', '关于'];
  }

  private static sectionSubtitles(): string[] {
    return ['主题模式与显示效果', '倍速、内容源、息屏听剧与连播', '显示、样式与屏蔽词', '缓存管理与清理', '版本信息'];
  }

  aboutToAppear(): void {
    this.refreshCache();
    this.readVersion();
    this.refreshWatchStats();
  }

  aboutToDisappear(): void {
    if (this.confirmTimer !== -1) {
      clearTimeout(this.confirmTimer);
      this.confirmTimer = -1;
    }
  }

  private refreshWatchStats(): void {
    AppState.watchStats.flush();
    this.todaySeconds = AppState.watchStats.todaySeconds();
    this.weekSeconds = AppState.watchStats.weekSeconds();
  }

  /** 秒数 → 「X 分钟 / X 小时 Y 分」 */
  private static formatWatch(sec: number): string {
    if (sec < 60) {
      return sec > 0 ? '1 分钟内' : '0 分钟';
    }
    const minutes = Math.floor(sec / 60);
    if (minutes < 60) {
      return `${minutes} 分钟`;
    }
    const hours = Math.floor(minutes / 60);
    const rest = minutes % 60;
    return rest > 0 ? `${hours} 小时 ${rest} 分` : `${hours} 小时`;
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
      this.versionCode = info.versionCode;
    } catch (error) {
      // 取不到就显示默认值；版本信息只是展示项，不能因此阻断页面
    }
  }

  /** 卡片内可用宽度：按实际窗口宽算，且不超过 build 里的内容限宽 */
  private innerWidth(): number {
    // 原来写死 360，车机窄窗 / 分屏下会把 chip 宽度算错（要么溢出要么挤成一团）
    const width: number = this.viewWidth > 0 ? Math.min(this.viewWidth, this.contentMaxWidth()) : 360;
    return width - this.pad() * 2 - Metrics.cardPadding * 2;
  }

  /** 宽屏宿主：Index 的左侧导航分支已统一 padding(safeTop + 14)，本页不能再叠 safeTop */
  private wideHost(): boolean {
    return Breakpoints.isWide(this.viewWidth > 0 ? this.viewWidth : 360);
  }

  /** 内容列限宽：宽屏放宽到 1020。原来固定 820，车机窗口 ~1100vp 时右侧空出一大条 */
  private contentMaxWidth(): number {
    return this.wideHost() ? 1020 : 820;
  }

  private chipWidthFor(count: number): number {
    const total = this.innerWidth() - Metrics.chipGap * (count - 1);
    // 极窄窗口下给个下限，避免算出负数或 0 宽
    return Math.max(28, Math.floor(total / count));
  }

  private switchTheme(mode: ThemeMode): void {
    this.themeMode = mode;
    ThemeController.setMode(this.ctx(), mode);
  }

  /** 只统计播放器落盘的解密分片，不含其他缓存 */
  private cacheFiles(): string[] {
    try {
      const dir = this.ctx().cacheDir;
      return fs.listFileSync(dir).filter((n: string) => n.startsWith('ep_'));
    } catch (error) {
      return [];
    }
  }

  private refreshCache(): void {
    try {
      const dir = this.ctx().cacheDir;
      let total = 0;
      for (const name of this.cacheFiles()) {
        total += fs.statSync(`${dir}/${name}`).size;
      }
      this.cacheText = total === 0 ? '无缓存' : SettingsView.formatSize(total);
      // 缓存列表只展示「文件还在」的条目：索引可能记着已被淘汰的旧集
      const out: CachedEpisode[] = [];
      for (const entry of AppState.cacheIndex.list()) {
        try {
          fs.statSync(`${dir}/${entry.fileName}`);
          out.push(entry);
        } catch (error) {
          // 文件已不存在，跳过
        }
      }
      this.cachedEpisodes = out;
    } catch (error) {
      this.cacheText = '未知';
    }
  }

  /** 单条缓存条目的大小文案 */
  private cacheEntrySize(entry: CachedEpisode): string {
    try {
      return SettingsView.formatSize(fs.statSync(`${this.ctx().cacheDir}/${entry.fileName}`).size);
    } catch (error) {
      return '';
    }
  }

  /** 删除单条缓存（文件 + 台账） */
  private deleteCachedEpisode(entry: CachedEpisode): void {
    try {
      fs.unlinkSync(`${this.ctx().cacheDir}/${entry.fileName}`);
    } catch (error) {
      // 文件可能已被播放器淘汰，忽略
    }
    AppState.cacheIndex.remove(entry.vid, entry.quality);
    this.refreshCache();
  }

  private static formatSize(bytes: number): string {
    if (bytes < 1024 * 1024) {
      return `${Math.max(1, Math.round(bytes / 1024))} KB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private clearCache(): void {
    this.clearing = true;
    try {
      const dir = this.ctx().cacheDir;
      for (const name of this.cacheFiles()) {
        fs.unlinkSync(`${dir}/${name}`);
      }
    } catch (error) {
      // 忽略单个文件失败
    }
    AppState.cacheIndex.clear();
    this.clearing = false;
    this.refreshCache();
  }

  /** 新增弹幕屏蔽词：去重/空串时 toast 提示，成功后立即持久化 */
  private addBlockedWord(): void {
    const word: string = this.newWord.trim();
    if (word.length === 0) {
      return;
    }
    if (Settings.addBlockedWord(word)) {
      this.blockedWords = Settings.danmakuBlocked.slice();
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '该词已在屏蔽列表中', duration: 1500 });
    }
    this.newWord = '';
  }

  private removeBlockedWord(word: string): void {
    Settings.removeBlockedWord(word);
    this.blockedWords = Settings.danmakuBlocked.slice();
  }

  /** 单条缓存大小（字节）：排序与展示用，读取失败按 0 */
  private entrySize(entry: CachedEpisode): number {
    try {
      return fs.statSync(`${this.ctx().cacheDir}/${entry.fileName}`).size;
    } catch (error) {
      return 0;
    }
  }

  /**
   * 缓存列表排序视图：
   * 按时间（createdAt 降序，最新缓存在前）或按大小（降序，最占空间的在前）。
   * 大小排序预读一次 statSync 再做 O(n²) 选择排序——条目上限 24，开销可忽略。
   */
  private sortedEpisodes(): CachedEpisode[] {
    const list: CachedEpisode[] = this.cachedEpisodes.slice();
    if (this.sortBySize) {
      const sizes: number[] = [];
      for (const entry of list) {
        sizes.push(this.entrySize(entry));
      }
      for (let i = 0; i < list.length; i++) {
        for (let j = i + 1; j < list.length; j++) {
          if (sizes[j] > sizes[i]) {
            const tmpEntry: CachedEpisode = list[i];
            list[i] = list[j];
            list[j] = tmpEntry;
            const tmpSize: number = sizes[i];
            sizes[i] = sizes[j];
            sizes[j] = tmpSize;
          }
        }
      }
    } else {
      for (let i = 0; i < list.length; i++) {
        for (let j = i + 1; j < list.length; j++) {
          if (list[j].createdAt > list[i].createdAt) {
            const tmpEntry: CachedEpisode = list[i];
            list[i] = list[j];
            list[j] = tmpEntry;
          }
        }
      }
    }
    return list;
  }

  /** 清理按钮：第一次点进入确认态（红字 3 秒），再点一次才真正清空 */
  private onClearPressed(): void {
    if (this.confirmTimer !== -1) {
      clearTimeout(this.confirmTimer);
      this.confirmTimer = -1;
    }
    if (this.confirmClear) {
      this.confirmClear = false;
      this.clearCache();
      return;
    }
    this.confirmClear = true;
    this.confirmTimer = setTimeout(() => {
      this.confirmClear = false;
      this.confirmTimer = -1;
    }, 3000);
  }

  private pickCacheKeep(value: number): void {
    this.cacheKeep = value;
    Settings.cacheKeep = value;
    Settings.save();
  }

  /** 折叠组头：玻璃卡一行（组名 + 副标题 + 旋转箭头），点击切换展开 */
  @Builder
  sectionHeader(index: number, title: string, subtitle: string) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(Metrics.bodySize + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(Metrics.tinySize)
            .fontColor($r('app.color.textFaint'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('▼')
        .fontSize(9)
        .fontColor($r('app.color.textFaint'))
        .rotate({ angle: this.expandedIndex === index ? 180 : 0 })
        .animation({ duration: 200, curve: Curve.EaseOut })
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding, top: 13, bottom: 13 })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .margin({ top: 12 })
    .onClick(() => {
      this.toggleSection(index);
    })
  }

  /** 展开动画：减弱动效时直接切换，否则 220ms 过渡 */
  private toggleSection(index: number): void {
    const target: number = this.expandedIndex === index ? -1 : index;
    if (Settings.reduceMotion) {
      this.expandedIndex = target;
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.expandedIndex = target;
    });
  }

  @Builder
  switchRow(label: string, desc: string, on: boolean, onToggle: (v: boolean) => void) {
    Row() {
      Column({ space: 4 }) {
        Text(label)
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
        if (desc.length > 0) {
          Text(desc)
            .fontSize(Metrics.tinySize)
            .fontColor($r('app.color.textFaint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor($r('app.color.accent'))
        .width(44)
        .height(25)
        .onChange((value: boolean) => {
          onToggle(value);
        })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  /** 外观 · 主题三选 */
  @Builder
  themeCard() {
    Column({ space: 13 }) {
      Text('主题')
        .fontSize(Metrics.bodySize)
        .fontColor($r('app.color.text'))
        .width('100%')

      Row({ space: Metrics.chipGap }) {
        ForEach(THEME_OPTIONS, (mode: ThemeMode) => {
          SegmentedChip({
            label: ThemeController.label(mode),
            active: this.themeMode === mode,
            chipWidth: this.chipWidthFor(3),
            onTap: () => {
              this.switchTheme(mode);
            }
          })
        }, (mode: ThemeMode) => `${mode}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(Metrics.cardPadding)
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 外观 · 两个观感开关 */
  @Builder
  appearanceCard() {
    Column() {
      this.switchRow('降低透明度', '玻璃材质改为实色背景，边框更明确', this.reduceTransparency,
        (v: boolean) => {
          this.reduceTransparency = v;
          Settings.reduceTransparency = v;
          Settings.save();
        })

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)

      this.switchRow('减弱动效', '收纳与切换改为淡入淡出，不再滑动', this.reduceMotion,
        (v: boolean) => {
          this.reduceMotion = v;
          Settings.reduceMotion = v;
          Settings.save();
        })
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 播放 · 默认倍速五选 */
  @Builder
  speedCard() {
    Column({ space: 13 }) {
      Text('默认倍速')
        .fontSize(Metrics.bodySize)
        .fontColor($r('app.color.text'))
        .width('100%')

      // 9 档倍速：单行横向滚动，避免 5+4 换行参差
      Scroll() {
        Row({ space: Metrics.chipGap }) {
          ForEach(SPEED_OPTIONS, (value: number) => {
            SegmentedChip({
              label: Settings.speedLabel(value),
              active: this.speed === value,
              chipWidth: this.chipWidthFor(5),
              onTap: () => {
                this.speed = value;
                Settings.speed = value;
                Settings.save();
              }
            })
          }, (value: number) => `${value}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .padding(Metrics.cardPadding)
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 观看统计 · 今日 / 本周时长 */
  @Builder
  statsCard() {
    Row() {
      Column({ space: 6 }) {
        Text(SettingsView.formatWatch(this.todaySeconds))
          .fontSize(Metrics.bodySize + 2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
        Text('今日观看')
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column()
        .width(1)
        .height(38)
        .backgroundColor($r('app.color.divider'))

      Column({ space: 6 }) {
        Text(SettingsView.formatWatch(this.weekSeconds))
          .fontSize(Metrics.bodySize + 2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
        Text('本周观看')
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20 })
    }
    .width('100%')
    .padding(Metrics.cardPadding)
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 12 })
  }

  /** 播放 · 内容源：当前使用源 + 站源管理入口 */
  @Builder
  sourceCard() {
    Row() {
      Column({ space: 4 }) {
        Text('内容源')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
        Text(`当前使用「${SourceRegistry.activeName()}」，可在站源管理中安装更多`)
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('管理')
        .fontSize(Metrics.smallSize)
        .fontColor($r('app.color.text'))
        .height(32)
        .padding({ left: 14, right: 14 })
        .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
        .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
        .borderRadius(16)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onOpenSources();
        })
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding, top: 12, bottom: 12 })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 播放 · 后台播放 / 自动下一集 */
  @Builder
  playCard() {
    Column() {
      this.switchRow('息屏听剧', '锁屏或切到其他应用后继续出声', this.backgroundPlay,
        (v: boolean) => {
          this.backgroundPlay = v;
          Settings.backgroundPlay = v;
          Settings.save();
        })

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)

      this.switchRow('自动下一集', '播完自动续播', this.autoNext,
        (v: boolean) => {
          this.autoNext = v;
          Settings.autoNext = v;
          Settings.save();
        })
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 弹幕 · 开关与样式参数（屏蔽词独立成卡） */
  @Builder
  danmakuCard() {
    Column() {
      this.switchRow('显示弹幕', '关闭后画面不再出现滚动弹幕', this.danmaku,
        (v: boolean) => {
          this.danmaku = v;
          Settings.danmaku = v;
          Settings.save();
        })

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)
        .margin({ top: 4 })

      Row() {
        Text('弹幕透明度')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
        Blank()
        Text(`${Math.round(this.danmakuOpacity * 100)}%`)
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textDim'))
      }
      .width('100%')
      .margin({ top: 14 })

      Slider({
        value: this.danmakuOpacity * 100,
        min: 30,
        max: 100,
        step: 5
      })
        .selectedColor($r('app.color.accent'))
        .trackColor($r('app.color.surfaceHigh'))
        .width('100%')
        .onChange((value: number) => {
          this.danmakuOpacity = value / 100;
          Settings.danmakuOpacity = this.danmakuOpacity;
          Settings.save();
        })

      Row({ space: 10 }) {
        Text('字号')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
          .width(58)
        Row({ space: Metrics.chipGap }) {
          ForEach(DM_SIZE_OPTIONS, (size: number, idx: number) => {
            SegmentedChip({
              label: DM_SIZE_LABELS[idx],
              active: this.danmakuSize === size,
              chipWidth: this.chipWidthFor(3) - 24,
              onTap: () => {
                this.danmakuSize = size;
                Settings.danmakuSize = size;
                Settings.save();
              }
            })
          }, (size: number) => `dms${size}`)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .margin({ top: 14 })

      Row({ space: 10 }) {
        Text('区域')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
          .width(58)
        Row({ space: Metrics.chipGap }) {
          ForEach(DM_AREA_LABELS, (label: string, idx: number) => {
            SegmentedChip({
              label: label,
              active: this.danmakuArea === DM_AREA_VALUES[idx],
              chipWidth: this.chipWidthFor(3) - 24,
              onTap: () => {
                this.danmakuArea = DM_AREA_VALUES[idx];
                Settings.danmakuArea = DM_AREA_VALUES[idx];
                Settings.save();
              }
            })
          }, (label: string, idx: number) => `dma${idx}_${label}`)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .margin({ top: 14 })

      Row({ space: 10 }) {
        Text('密度')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
          .width(58)
        Row({ space: Metrics.chipGap }) {
          ForEach(DM_DENSITY_LABELS, (label: string, idx: number) => {
            SegmentedChip({
              label: label,
              active: this.danmakuDensity === DM_DENSITY_VALUES[idx],
              chipWidth: this.chipWidthFor(3) - 24,
              onTap: () => {
                this.danmakuDensity = DM_DENSITY_VALUES[idx];
                Settings.danmakuDensity = DM_DENSITY_VALUES[idx];
                Settings.save();
              }
            })
          }, (label: string, idx: number) => `dmd${idx}_${label}`)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .margin({ top: 14 })

      Row({ space: 10 }) {
        Text('颜色')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
          .width(58)
        Row({ space: 9 }) {
          ForEach(DM_COLOR_VALUES, (color: string, idx: number) => {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 20, height: 20 })
                .fill(color)
                .stroke(idx === 0 ? $r('app.color.divider') : Color.Transparent)
                .strokeWidth(1)
              if (idx === this.danmakuColorIdx) {
                Circle({ width: 26, height: 26 })
                  .fill(Color.Transparent)
                  .stroke($r('app.color.ink'))
                  .strokeWidth(1.6)
              }
            }
            .width(28)
            .height(28)
            .onClick(() => {
              this.danmakuColorIdx = idx;
              Settings.danmakuColor = idx;
              Settings.save();
            })
          }, (color: string, idx: number) => `dmclr${idx}_${color}`)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .height(34)
      .margin({ top: 12 })

      this.switchRow('合并重复弹幕', '相同弹幕合并为一条并标注条数', this.danmakuMerge,
        (v: boolean) => {
          this.danmakuMerge = v;
          Settings.danmakuMerge = v;
          Settings.save();
        })

      Row() {
        Text('弹幕速度')
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
          .width('100%')
      }
      .margin({ top: 12 })

      Scroll() {
        Row({ space: Metrics.chipGap }) {
          ForEach(DM_SPEED_LABELS, (label: string, idx: number) => {
            SegmentedChip({
              label: label,
              active: this.danmakuSpeed === DM_SPEED_VALUES[idx],
              chipWidth: this.chipWidthFor(4),
              onTap: () => {
                this.danmakuSpeed = DM_SPEED_VALUES[idx];
                Settings.danmakuSpeed = DM_SPEED_VALUES[idx];
                Settings.save();
              }
            })
          }, (label: string, idx: number) => `dmspd${idx}_${label}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding, top: 9, bottom: 12 })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 弹幕 · 屏蔽词管理（独立卡片：输入 + 词条流） */
  @Builder
  blockedCard() {
    Column() {
      Row({ space: 10 }) {
        TextInput({ placeholder: '添加屏蔽词', text: this.newWord })
          .layoutWeight(1)
          .height(36)
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.text'))
          .placeholderColor($r('app.color.textFaint'))
          .backgroundColor($r('app.color.surfaceHigh'))
          .borderRadius(18)
          .padding({ left: 14, right: 8 })
          .onChange((value: string) => {
            this.newWord = value;
          })
          .onSubmit(() => {
            this.addBlockedWord();
          })

        Text('添加')
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.accentOn'))
          .height(36)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.accent'))
          .borderRadius(18)
          .onClick(() => {
            this.addBlockedWord();
          })
      }
      .width('100%')

      if (this.blockedWords.length > 0) {
        Flex({
          wrap: FlexWrap.Wrap,
          justifyContent: FlexAlign.Start,
          space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) }
        }) {
          ForEach(this.blockedWords, (word: string) => {
            Text(`${word} ×`)
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textDim'))
              .backgroundColor($r('app.color.surfaceHigh'))
              .borderRadius(15)
              .height(30)
              .padding({ left: 13, right: 13 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 200 })
              .onClick(() => {
                this.removeBlockedWord(word);
              })
          }, (word: string) => `bw${word}`)
        }
        .width('100%')
        .margin({ top: 12 })
        Text('点词条移除；含屏蔽词的弹幕不再显示（仅本机生效）')
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
          .width('100%')
          .margin({ top: 6 })
      } else {
        Text('添加屏蔽词后，含该词的弹幕不再显示（仅本机生效）')
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding, top: 12, bottom: 12 })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /** 存储 · 缓存占用、保留上限、单条管理 */
  @Builder
  storageCard() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text('播放缓存')
            .fontSize(Metrics.bodySize)
            .fontColor($r('app.color.text'))
          Text(this.cachedEpisodes.length > 0
            ? `已缓存 ${this.cachedEpisodes.length} 集，解密分片，清理不影响观看`
            : '解密后的分片，清理不影响观看')
            .fontSize(Metrics.tinySize)
            .fontColor($r('app.color.textFaint'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.clearing ? '清理中'
          : this.confirmClear ? '确认清空？'
          : `${this.cacheText} · 清理`)
          .fontSize(Metrics.smallSize)
          .fontColor(this.confirmClear ? '#FF7A6B' : $r('app.color.textDim'))
          .height(34)
          .padding({ left: 14, right: 14 })
          .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
          .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
          .borderRadius(17)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onClearPressed();
          })
      }
      .width('100%')
      .padding({ top: 9, bottom: 9 })

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)
        .margin({ top: 10, bottom: 4 })

      Row() {
        Column({ space: 4 }) {
          Text('保留上限')
            .fontSize(Metrics.bodySize)
            .fontColor($r('app.color.text'))
          Text('超过后自动删掉最旧的缓存集')
            .fontSize(Metrics.tinySize)
            .fontColor($r('app.color.textFaint'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .margin({ top: 10 })

      Row({ space: Metrics.chipGap }) {
        ForEach(CACHE_KEEP_OPTIONS, (value: number) => {
          SegmentedChip({
            label: `${value} 集`,
            active: this.cacheKeep === value,
            chipWidth: this.chipWidthFor(3),
            onTap: () => {
              this.pickCacheKeep(value);
            }
          })
        }, (value: number) => `ck${value}`)
      }
      .width('100%')
      .margin({ top: 12 })

      // 已缓存的剧集：标题行 + 排序切换，台账列表可单条删除
      if (this.cachedEpisodes.length > 0) {
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(0.5)
          .margin({ top: 14, bottom: 4 })

        Row() {
          Text(`已缓存 ${this.cachedEpisodes.length} 集`)
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textDim'))
          Blank()
          SegmentedChip({
            label: '按时间',
            active: !this.sortBySize,
            chipWidth: 64,
            onTap: () => {
              this.sortBySize = false;
            }
          })
          SegmentedChip({
            label: '按大小',
            active: this.sortBySize,
            chipWidth: 64,
            onTap: () => {
              this.sortBySize = true;
            }
          })
        }
        .width('100%')
        .margin({ top: 10 })

        ForEach(this.sortedEpisodes(), (entry: CachedEpisode) => {
          Row() {
            Column({ space: 3 }) {
              Text(entry.title.length > 0 ? entry.title : '未知剧集')
                .fontSize(Metrics.smallSize)
                .fontColor($r('app.color.text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`第 ${entry.episodeIndex} 集 · ${this.cacheEntrySize(entry)}`)
                .fontSize(Metrics.tinySize)
                .fontColor($r('app.color.textFaint'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('删除')
              .fontSize(Metrics.smallSize - 1)
              .fontColor($r('app.color.textFaint'))
              .padding({ left: 12, right: 4, top: 6, bottom: 6 })
              .onClick(() => {
                this.deleteCachedEpisode(entry);
              })
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
        }, (entry: CachedEpisode) => `${entry.vid}_${entry.quality}_${entry.createdAt}`)
      }
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  /**
   * 关于 · 应用标识与版本信息。
   * 版本号从 bundleManager 实时读，不写死在 UI 里——
   * 否则以后发版改了 app.json5，这里还停留在旧数字，反馈问题时会误导定位。
   */
  @Builder
  aboutRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Metrics.smallSize)
        .fontColor($r('app.color.textDim'))
      Blank()
      Text(value)
        .fontSize(Metrics.smallSize)
        .fontColor($r('app.color.text'))
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  aboutCard() {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.startIcon'))
          .width(52)
          .height(52)
          .borderRadius(13)
          .clip(true)

        Column({ space: 5 }) {
          Text('青芒短视频')
            .fontSize(Metrics.bodySize + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
          Text('短视频聚合播放客户端')
            .fontSize(Metrics.tinySize)
            .fontColor($r('app.color.textFaint'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 4, bottom: 12 })

      this.aboutRow('当前版本', `v${this.version}`)
      this.aboutRow('版本码', `${this.versionCode}`)
      this.aboutRow('内容来源', '第三方公开接口')
    }
    .width('100%')
    .padding({ left: Metrics.cardPadding, right: Metrics.cardPadding, top: 12, bottom: 8 })
    .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Regular)))
    .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
    .borderRadius(Metrics.cardRadius)
    .shadow({
      radius: Glass.spec(GlassTier.Regular).shadowRadius,
      color: Glass.spec(GlassTier.Regular).shadowColor,
      offsetX: 0,
      offsetY: Glass.spec(GlassTier.Regular).shadowOffsetY
    })
    .margin({ top: 10 })
  }

  private pad(): number {
    return Breakpoints.pagePadding(this.viewWidth > 0 ? this.viewWidth : 360);
  }

  build() {
    Scroll() {
      // 外层只负责水平居中；内层限宽 + 承载内容。
      // 原来限宽列直接贴左，车机上右侧留出 14%+ 空白（实车「我的」页右侧空白根因）。
      Column() {
        Column() {
          Row() {
            Text('我的')
              .fontSize(Metrics.heroTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text'))
          }
          .width('100%')
          // 宽屏宿主已由 Index 统一让开 safeTop，这里只留标题呼吸空间；
          // 窄屏没有父级 top padding，仍需自己让开状态栏
          .padding({ top: this.wideHost() ? 10 : this.safeTopPx + 10 })

        // 观看数据展示：紧跟标题，常驻不折叠
        this.statsCard()

        // 五个分组折叠收纳：默认全收起，点组头展开，再点收起
        this.sectionHeader(0, SettingsView.sectionTitles()[0], SettingsView.sectionSubtitles()[0])
        if (this.expandedIndex === 0) {
          this.themeCard()
          this.appearanceCard()
        }

        this.sectionHeader(1, SettingsView.sectionTitles()[1], SettingsView.sectionSubtitles()[1])
        if (this.expandedIndex === 1) {
          this.speedCard()
          this.sourceCard()
          this.playCard()
        }

        this.sectionHeader(2, SettingsView.sectionTitles()[2], SettingsView.sectionSubtitles()[2])
        if (this.expandedIndex === 2) {
          this.danmakuCard()
          this.blockedCard()
        }

        this.sectionHeader(3, SettingsView.sectionTitles()[3], SettingsView.sectionSubtitles()[3])
        if (this.expandedIndex === 3) {
          this.storageCard()
        }

        this.sectionHeader(4, SettingsView.sectionTitles()[4], SettingsView.sectionSubtitles()[4])
        if (this.expandedIndex === 4) {
          this.aboutCard()
        }

        Text('视频内容版权归原作者及内容提供方所有。本应用仅提供聚合浏览与播放能力，'
          + '不上传、不存储、不二次分发内容，仅供个人学习研究使用。')
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textFaint'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 26, bottom: 24 })
        }
        .width('100%')
        // 宽屏放宽限宽并水平居中：设置项一行拉太宽难扫读，但 820 在车机窗口下偏窄
        .constraintSize({ maxWidth: this.contentMaxWidth() })
        .padding({ left: this.pad(), right: this.pad(), bottom: this.bottomInset })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .backgroundColor($r('app.color.bg'))
    .onDidScroll(() => {
      this.onScroll();
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.viewWidth = Number(newValue.width);
    })
  }
}
