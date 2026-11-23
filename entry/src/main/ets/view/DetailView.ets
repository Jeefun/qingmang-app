/**
 * 详情页：大封面 + 上浮面板（剧名 / 集数 / 主按钮 / 简介 / 选集）。
 *
 * 手机实测：封面高约 322vp，面板用 20 圆角从封面底部上浮 26vp 盖住接缝，
 * 选集为 5 列胶囊按钮，当前集墨黑实底。
 */
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { DramaDetail, Episode, FavoriteItem, HistoryItem } from '../model/Models';
import { AppState } from '../store/AppState';
import { Breakpoints, Metrics } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';
import { StateHint } from './Widgets';

@Component
export struct DetailView {
  seriesId: string = '';
  @StorageProp('safeTop') safeTopPx: number = 0;
  @State title: string = '';
  @State cover: string = '';
  @State description: string = '';
  @State tags: string = '';
  @State episodes: Episode[] = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  @State resumeIndex: number = 1;
  @State viewWidth: number = 0;
  /** 按下中的控件标识，用于统一的按压反馈 */
  @State pressKey: string = '';
  /** 是否已收藏（进入页面时从收藏夹读一次） */
  @State favored: boolean = false;
  /** 车机虚拟屏（EntryAbility 实时维护）：字号/触控目标/封面尺寸随之调整 */
  @StorageProp('carMode') carMode: boolean = false;
  /** 窗口高（vp，EntryAbility 写入）：车机是「宽而矮」的窗口，封面高度必须按它封顶 */
  @StorageProp('screenHeight') screenHeightVp: number = 0;
  /** 底部安全区（vp）：选集网格的底部留白要避开手势条 */
  @StorageProp('safeBottom') safeBottomPx: number = 0;

  onBack: () => void = () => {
  };
  onPlay: (seriesId: string, episodeIndex: number) => void = () => {
  };

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      await AppState.ensureReady();
      const detail: DramaDetail = await AppState.api.detail(this.seriesId);
      this.title = detail.drama.displayTitle;
      this.cover = detail.drama.cover;
      this.description = detail.drama.description;
      this.tags = detail.drama.tags;
      this.episodes = detail.episodes;

      const history = AppState.history.find(this.seriesId);
      this.resumeIndex = history === null ? 1 : history.episodeIndex;
      this.favored = AppState.favorites.has(this.seriesId);
    } catch (error) {
      this.errorText = (error as Error).message;
      this.episodes = [];
    } finally {
      this.loading = false;
    }
  }

  private resumeLabel(): string {
    if (this.resumeIndex > 1) {
      return `续播第 ${this.resumeIndex} 集`;
    }
    return '从第 1 集开始';
  }

  /** 收藏 / 取消收藏，toast 给明确反馈 */
  private toggleFavorite(): void {
    const item = new FavoriteItem();
    item.seriesId = this.seriesId;
    item.title = this.title;
    item.cover = this.cover;
    this.favored = AppState.favorites.toggle(item);
    this.getUIContext().getPromptAction().showToast({
      message: this.favored ? '已收藏，在「收藏」页可以找到' : '已取消收藏',
      duration: 1600
    });
  }

  /** 拉起系统分享面板。内容源没有公开网页链接，分享纯文本。 */
  private shareDrama(): void {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const ctx = host as common.UIAbilityContext;
    const text = `《${this.title}》· 全 ${this.episodes.length} 集 · 来自青芒短视频`;
    const data = new systemShare.SharedData({
      utd: utd.UniformDataType.PLAIN_TEXT,
      content: text
    });
    const controller = new systemShare.ShareController(data);
    controller.show(ctx, {});
  }

  /** 题材数量：tags 形如「恋爱 · 都市 · 职场」，按分隔点拆开计数 */
  private tagCount(): number {
    if (this.tags.length === 0) {
      return 0;
    }
    let n: number = 0;
    const parts: string[] = this.tags.split('·');
    for (const p of parts) {
      if (p.trim().length > 0) {
        n++;
      }
    }
    return n;
  }

  /**
   * 统计数据行的单元格：大数字 + 小标签（对齐系统应用详情页的「评分 / 安装量」规格）。
   * 数字一律取真实数据：总集数、题材数、已看进度，不编造评分或热度。
   */
  @Builder
  statCell(value: string, label: string) {
    Column({ space: 3 }) {
      Text(value)
        .fontSize(Metrics.statValueSize)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label)
        .fontSize(Metrics.tinySize)
        .fontColor($r('app.color.textFaint'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  statDivider() {
    Column()
      .width(1)
      .height(Metrics.statDividerHeight)
      .backgroundColor($r('app.color.divider'))
  }

  /**
   * 收藏 / 分享双钮：与主按钮同一套玻璃语言，但用中性档，
   * 层级上必须让位于「续播」这个主操作。
   */
  @Builder
  actionRow(width: Length) {
    Row({ space: 12 }) {
      Text(this.favored ? '已收藏' : '收藏')
        .fontSize(Metrics.bodySize)
        .fontColor(this.favored ? $r('app.color.accentOn') : $r('app.color.text'))
        .layoutWeight(1)
        .height(Metrics.chipHeight)
        .textAlign(TextAlign.Center)
        .backgroundEffect({
          radius: Glass.spec(GlassTier.Thin).blurRadius,
          saturation: Glass.spec(GlassTier.Thin).saturation,
          brightness: Glass.spec(GlassTier.Thin).brightness,
          color: this.favored ? Glass.accentTint() : Glass.spec(GlassTier.Thin).tint
        })
        .border({
          width: 1,
          color: this.favored ? '#4DFFFFFF' : Glass.spec(GlassTier.Thin).borderColor
        })
        .borderRadius(Metrics.chipHeight / 2)
        .scale({ x: this.pressKey === 'fav' ? 0.97 : 1, y: this.pressKey === 'fav' ? 0.97 : 1 })
        .animation({ duration: 130, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.pressKey = 'fav';
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressKey = '';
          }
        })
        .onClick(() => {
          this.toggleFavorite();
        })

      Text('分享')
        .fontSize(Metrics.bodySize)
        .fontColor($r('app.color.text'))
        .layoutWeight(1)
        .height(Metrics.chipHeight)
        .textAlign(TextAlign.Center)
        .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
        .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
        .borderRadius(Metrics.chipHeight / 2)
        .scale({ x: this.pressKey === 'share' ? 0.97 : 1, y: this.pressKey === 'share' ? 0.97 : 1 })
        .animation({ duration: 130, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.pressKey = 'share';
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressKey = '';
          }
        })
        .onClick(() => {
          this.shareDrama();
        })
    }
    .width(width)
    .margin({ top: 12 })
  }

  private isNarrow(): boolean {
    return !Breakpoints.isWide(this.winWidth());
  }

  private winWidth(): number {
    return this.viewWidth > 0 ? this.viewWidth : 360;
  }

  private pad(): number {
    return Breakpoints.pagePadding(this.winWidth());
  }

  /** 车机文字加两档：与 HistoryView / PlayerView 同一套放大规则 */
  private carFont(size: number): number {
    return this.carMode ? size + 2 : size;
  }

  /** 车机触控热区放大：44vp 芯片在 15.6 寸屏上坐远一点就点不稳 */
  private carTouch(size: number): number {
    if (!this.carMode) {
      return size;
    }
    const scaled: number = Math.round(size * 1.4);
    return scaled < 48 ? 48 : scaled;
  }

  /** 窗口可用高度（vp）：封面与简介的封顶基准 */
  private availHeight(): number {
    return this.screenHeightVp > 0 ? this.screenHeightVp : 780;
  }

  /**
   * 宽屏封面宽度：随断点放大，但必须按窗口高度封顶。
   *
   * 车机是「宽而矮」的窗口（如 960x360vp）：按断点取 252x353 的封面后，
   * 固定高度行（返回栏 + 封面行 + 选集标题）合计已超过整个视口，
   * 选集区被挤到 0 高度 —— 实车「选集完全不可见、只能点续播」的直接根因。
   * 这里以窗口高的 42% 反推封面尺寸上限，再与断点档位取小。
   */
  private coverWidth(): number {
    const width: number = this.winWidth();
    let base: number = 200;
    if (width >= 1280) {
      base = 252;
    } else if (width >= 840) {
      base = 220;
    }
    const capH: number = Math.round(this.availHeight() * 0.42);
    const safeCap: number = capH > 160 ? capH : 160;
    const byHeight: number = Math.round(safeCap / 1.4);
    return base > byHeight ? byHeight : base;
  }

  private coverHeight(): number {
    return Math.round(this.coverWidth() * 1.4);
  }

  /** 宽屏简介行数：矮窗口收紧，别让简介把首屏吃光（整页可滚，展开靠滚动） */
  private descMaxLines(): number {
    return this.availHeight() < 480 ? 3 : 5;
  }

  /** 选集列数随窗口增长：手机 5 列，车机宽屏 8~10 列，避免胶囊被拉成一条 */
  private episodeColumns(): number {
    const width: number = this.winWidth();
    if (width >= 1280) {
      return 10;
    }
    if (width >= 840) {
      return 8;
    }
    if (width >= 600) {
      return 7;
    }
    return 5;
  }

  /** 选集网格宽度：按当前列数等分铺满 */
  private episodeCellWidth(): number {
    const avail: number = this.winWidth() - this.pad() * 2;
    const cells: number = this.episodeColumns();
    const each: number = Math.floor((avail - Metrics.chipGap * (cells - 1)) / cells);
    return each > 40 ? each : 40;
  }

  @Builder
  episodeGrid() {
    Column() {
      ForEach(this.episodeRows(), (row: number[]) => {
        Row({ space: Metrics.chipGap }) {
          ForEach(row, (index: number) => {
            Text(`${index}`)
              .fontSize(this.carFont(Metrics.smallSize))
              .fontColor(index === this.resumeIndex ? $r('app.color.inkOn') : $r('app.color.textDim'))
              .backgroundColor(index === this.resumeIndex ? $r('app.color.chipOn') : $r('app.color.chipBg'))
              .borderRadius(this.carTouch(Metrics.chipHeight) / 2)
              .width(this.episodeCellWidth())
              .height(this.carTouch(Metrics.chipHeight))
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.onPlay(this.seriesId, index);
              })
          }, (index: number) => `${index}`)
        }
        .width('100%')
        .margin({ bottom: Metrics.chipGap })
      }, (row: number[]) => `${row.length > 0 ? row[0] : 0}`)
    }
    .width('100%')
  }

  /** 把分集按当前列数切开，避免 Flex 自动折行时宽度算不准 */
  private episodeRows(): number[][] {
    const perRow: number = this.episodeColumns();
    const rows: number[][] = [];
    let current: number[] = [];
    for (const episode of this.episodes) {
      current.push(episode.index);
      if (current.length === perRow) {
        rows.push(current);
        current = [];
      }
    }
    if (current.length > 0) {
      rows.push(current);
    }
    return rows;
  }

  /** 手机上：封面 + 上浮面板 */
  @Builder
  mobileLayout() {
    Scroll() {
      Column() {
        // 封面区
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.cover)
            .width('100%')
            .height(322)
            .objectFit(ImageFit.Cover)
            // 官方《性能提升建议》：源图远大于显示尺寸时开启自动降采样，
            // 避免按原分辨率解码吃掉内存（信息流封面最典型）
            .autoResize(true)
            .backgroundColor($r('app.color.surfaceHigh'))
            .alt($r('app.media.startIcon'))
            .margin({ top: this.safeTopPx })

          // 顶部压暗，保证返回键在浅色封面上也看得见
          Text('')
            .width('100%')
            .height(96)
            .linearGradient({
              angle: 180,
              colors: [['#66000000', 0], ['#00000000', 1]]
            })
            .margin({ top: this.safeTopPx })

          // 返回键：圆形功能钮（对齐系统应用的 44vp 规格）。
          // 封面顶部已有压暗渐变，这里保持深色半透明圆，在浅色封面上才看得见。
          // 注意：Stack 的对齐只能写在构造器，没有 .justifyContent()/.alignItems()。
          Stack({ alignContent: Alignment.Center }) {
            Text('‹')
              .fontSize(Metrics.roundBtnGlyph)
              .fontColor(Color.White)
          }
          .width(Metrics.roundBtnSize)
          .height(Metrics.roundBtnSize)
          .borderRadius(Metrics.roundBtnSize / 2)
          .backgroundColor($r('app.color.roundBtnScrim'))
          .margin({ left: Metrics.safeMargin, top: this.safeTopPx + 8 })
          .scale({ x: this.pressKey === 'back' ? 0.9 : 1, y: this.pressKey === 'back' ? 0.9 : 1 })
          .animation({ duration: 130, curve: Curve.EaseOut })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.pressKey = 'back';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressKey = '';
            }
          })
          .onClick(() => {
            this.onBack();
          })
        }
        .width('100%')
        .height(this.safeTopPx + 322)

        // 上浮面板
        Column() {
          Text(this.title)
            .fontSize(Metrics.heroTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text'))
            .width('100%')
            .margin({ top: 18 })

          // 统计数据行（对齐系统应用详情页的「评分 / 安装量」规格）。
          // 数字全部取真实数据：总集数、题材数、已看进度，不编造评分或热度。
          Row() {
            this.statCell(`${this.episodes.length}`, '总集数')
            this.statDivider()
            this.statCell(`${this.tagCount()}`, '题材')
            this.statDivider()
            this.statCell(`${this.resumeIndex > 1 ? this.resumeIndex - 1 : 0}`, '已看')
          }
          .width('100%')
          .margin({ top: 16 })

          if (this.tags.length > 0) {
            Row({ space: 8 }) {
              Text(this.tags)
                .fontSize(Metrics.tinySize)
                .fontColor($r('app.color.textDim'))
                .backgroundColor($r('app.color.chipBg'))
                .borderRadius(Metrics.chipRadius)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 12 })
          }

          Text(this.resumeLabel())
            .fontSize(Metrics.bodySize)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.inkOn'))
            // 主按钮：强调色玻璃。整宽按钮用常规档，
            // 模糊 + 折射高光边让它在封面背景上也立得住，不再是一块死黑
            .backgroundEffect({
              radius: Glass.spec(GlassTier.Regular).blurRadius,
              saturation: Glass.spec(GlassTier.Regular).saturation,
              brightness: Glass.spec(GlassTier.Regular).brightness,
              color: Glass.accentTint()
            })
            .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
            .borderRadius(Metrics.primaryButtonHeight / 2)
            .height(Metrics.primaryButtonHeight)
            .width('100%')
            .textAlign(TextAlign.Center)
            .shadow({
              radius: Glass.spec(GlassTier.Regular).shadowRadius,
              color: Glass.spec(GlassTier.Regular).shadowColor,
              offsetX: 0,
              offsetY: 8
            })
            .margin({ top: 18 })
            .scale({ x: this.pressKey === 'play' ? 0.97 : 1, y: this.pressKey === 'play' ? 0.97 : 1 })
            .animation({ duration: 130, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.pressKey = 'play';
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.pressKey = '';
              }
            })
            .onClick(() => {
              this.onPlay(this.seriesId, this.resumeIndex);
            })

          this.actionRow('100%')

          Text('简介')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textFaint'))
            .width('100%')
            .margin({ top: 24, bottom: 10 })

          Text(this.description.length > 0 ? this.description : '暂无简介')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textDim'))
            .lineHeight(23)
            .width('100%')

          Row() {
            Text('选集')
              .fontSize(Metrics.bodySize)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text'))
            Blank()
            Text(`${this.episodes.length} 集`)
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textFaint'))
          }
          .width('100%')
          .margin({ top: 24, bottom: 12 })

          this.episodeGrid()
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad(), bottom: 28 })
        .backgroundColor($r('app.color.bg'))
        .borderRadius({ topLeft: Metrics.sheetRadius, topRight: Metrics.sheetRadius })
        .clip(true)
        .margin({ top: -26 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /**
   * 宽屏 / 投屏：海报与简介左右排布。
   *
   * 整页放在同一个 Scroll 里：车机窗口「宽而矮」，若选集区单独用
   * layoutWeight 挂在固定高度行之后，视口高度不足时权重会被压成 0，
   * 选集整块不可见也滚不到。改为整页滚动后，选集在任何窗口高度下都可达。
   */
  @Builder
  wideLayout() {
    Scroll() {
      Column() {
        Row() {
          // 宽屏返回键与窄屏同源：44vp 圆钮 + 统一字号 token
          Stack({ alignContent: Alignment.Center }) {
            Text('‹')
              .fontSize(Metrics.roundBtnGlyph)
              .fontColor($r('app.color.text'))
          }
          .width(Metrics.roundBtnSize)
          .height(Metrics.roundBtnSize)
          .borderRadius(Metrics.roundBtnSize / 2)
          // 圆钮走薄玻璃，比一块实色圆片更像「浮在内容上的按钮」
          .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
          .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
          .shadow({
            radius: Glass.spec(GlassTier.Thin).shadowRadius,
            color: Glass.spec(GlassTier.Thin).shadowColor,
            offsetX: 0,
            offsetY: 4
          })
          .onClick(() => {
            this.onBack();
          })
          Blank()
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad(), top: this.safeTopPx + 10, bottom: 10 })

        Row({ space: 24 }) {
          Image(this.cover)
            .width(this.coverWidth())
            .height(this.coverHeight())
            .objectFit(ImageFit.Cover)
            // 官方《性能提升建议》：源图远大于显示尺寸时开启自动降采样，
            // 避免按原分辨率解码吃掉内存（信息流封面最典型）
            .autoResize(true)
            .borderRadius(Metrics.cardRadius)
            .backgroundColor($r('app.color.surfaceHigh'))

          Column() {
            Text(this.title)
              .fontSize(this.carFont(Metrics.titleSize))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text'))
              .width('100%')

            // 统计数据行（与窄屏分支同源，真实数据）
            Row() {
              this.statCell(`${this.episodes.length}`, '总集数')
              this.statDivider()
              this.statCell(`${this.tagCount()}`, '题材')
              this.statDivider()
              this.statCell(`${this.resumeIndex > 1 ? this.resumeIndex - 1 : 0}`, '已看')
            }
            .width('100%')
            .margin({ top: 12 })

            Text(this.resumeLabel())
              .fontSize(this.carFont(Metrics.bodySize))
              .fontColor($r('app.color.inkOn'))
              .backgroundEffect({
                radius: Glass.spec(GlassTier.Regular).blurRadius,
                saturation: Glass.spec(GlassTier.Regular).saturation,
                brightness: Glass.spec(GlassTier.Regular).brightness,
                color: Glass.accentTint()
              })
              .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
              .borderRadius(Metrics.primaryButtonHeight / 2)
              .height(this.carTouch(Metrics.primaryButtonHeight))
              .width(this.coverWidth())
              .textAlign(TextAlign.Center)
              .margin({ top: 14 })
              .onClick(() => {
                this.onPlay(this.seriesId, this.resumeIndex);
              })

            this.actionRow(this.coverWidth())

            Text(this.description.length > 0 ? this.description : '暂无简介')
              .fontSize(this.carFont(Metrics.smallSize))
              .fontColor($r('app.color.textDim'))
              .lineHeight(22)
              .maxLines(this.descMaxLines())
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 14 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad() })

        Row() {
          Text('选集')
            .fontSize(this.carFont(Metrics.bodySize))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text'))
          Blank()
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad() })
        .margin({ top: 18, bottom: 10 })

        Column() {
          this.episodeGrid()
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad() })
      }
      .width('100%')
      .padding({ left: 0, right: 0, bottom: this.safeBottomPx + 28 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Column() {
      if (this.loading) {
        StateHint({ message: '正在读取剧集…', busy: true })
          .layoutWeight(1)
      } else if (this.errorText.length > 0) {
        StateHint({
          message: '剧集详情加载失败',
          detail: this.errorText,
          actionText: '重试',
          onAction: () => {
            this.load();
          }
        })
          .layoutWeight(1)
      } else if (this.isNarrow()) {
        this.mobileLayout()
      } else {
        this.wideLayout()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.viewWidth = Number(newValue.width);
    })
  }
}
