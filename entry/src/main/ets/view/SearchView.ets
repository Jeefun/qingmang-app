/**
 * 搜索页。内容源搜索走 tab_type=29（剧集），结果按 10 条分页。
 * 搜索框整体白底圆角，右侧嵌一颗红底「搜索」按钮。
 * 没搜过 / 清空关键词时展示最近搜索过的关键词，点一下直接重搜。
 */
import { LengthMetrics } from '@kit.ArkUI';
import { Drama, FeedPage } from '../model/Models';
import { VIDEO_TAGS } from '../model/Tags';
import { AppState } from '../store/AppState';
import { Breakpoints, Metrics } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';
import { PosterCard, StateHint } from './Widgets';

@Component
export struct SearchView {
  @State keyword: string = '';
  @State items: Drama[] = [];
  @State loading: boolean = false;
  @State searched: boolean = false;
  @State errorText: string = '';
  @State hasMore: boolean = false;
  @State viewWidth: number = 0;
  @State historyWords: string[] = [];
  /** 按下中的控件标识，用于统一的按压反馈 */
  @State pressKey: string = '';
  /** 车机虚拟屏：结果卡片走大卡档并放大字号（与首页同一套规则） */
  @StorageProp('carMode') carMode: boolean = false;

  private searchId: string = '';
  private pageOffset: number = 0;
  private seq: number = 0;

  aboutToAppear(): void {
    this.historyWords = AppState.searchHistory.list();
  }

  private cardWidth(): number {
    return Breakpoints.cardWidth(this.winWidth(), this.columns());
  }

  private winWidth(): number {
    return this.viewWidth > 0 ? this.viewWidth : 360;
  }

  private pad(): number {
    return Breakpoints.pagePadding(this.winWidth());
  }

  /** 车机触控热区下限：可点元素 ≥48vp（验收标准），手机原值直通 */
  private carTouch(size: number): number {
    if (!this.carMode) {
      return size;
    }
    const scaled: number = Math.round(size * 1.4);
    return scaled < 48 ? 48 : scaled;
  }

  /** 车机文字加两档：远距离观看小字读不出 */
  private carFont(size: number): number {
    return this.carMode ? size + 2 : size;
  }

  private columns(): number {
    return Breakpoints.gridColumns(this.winWidth(), this.carMode);
  }

  /** 顶部标题栏占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;

  onOpen: (seriesId: string) => void = () => {
  };
  onScroll: () => void = () => {
  };

  async doSearch(reset: boolean): Promise<void> {
    const word = this.keyword.trim();
    if (word.length === 0) {
      this.errorText = '输入剧名再搜索';
      return;
    }
    // 发起即记账：网络失败也算「搜过」，重试时点一下历史词就行
    AppState.searchHistory.add(word);
    this.historyWords = AppState.searchHistory.list();

    const token = ++this.seq;
    this.loading = true;
    this.errorText = '';
    if (reset) {
      this.pageOffset = 0;
      this.searchId = '';
      this.items = [];
    }

    try {
      await AppState.ensureReady();
      const page: FeedPage = await AppState.api.search(word, this.pageOffset, this.searchId);
      if (token !== this.seq) {
        return;
      }
      this.searchId = page.sessionId;
      this.hasMore = page.hasMore;
      if (reset) {
        this.items = page.items;
      } else {
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
          }
        }
        this.items = merged;
      }
      this.pageOffset += 10;
      this.searched = true;
    } catch (error) {
      if (token !== this.seq) {
        return;
      }
      this.errorText = (error as Error).message;
      this.searched = true;
    } finally {
      if (token === this.seq) {
        this.loading = false;
      }
    }
  }

  /**
   * 未搜索状态：热门搜索（题材词，点一下直接搜）+ 最近搜索（有历史词才展示）。
   * 这里不用 StateHint 占满整屏——那样词条永远没地方站。
   */
  @Builder
  searchHistoryBlock() {
    Scroll() {
      Column() {
        // ── 热门搜索：题材词来自内容源标签表，与首页筛选同一套语料 ──
        Row() {
          Text('热门搜索')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textDim'))
          Blank()
          Text('换剧种 点这里')
            .fontSize(Metrics.smallSize - 1)
            .fontColor($r('app.color.textFaint'))
        }
        .width('100%')
        .padding({ top: 22, bottom: 12 })

        Flex({
          wrap: FlexWrap.Wrap,
          justifyContent: FlexAlign.Start,
          space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(10) }
        }) {
          ForEach(VIDEO_TAGS.slice(1), (tag: string) => {
            Text(tag)
              .fontSize(this.carFont(Metrics.smallSize))
              .fontColor($r('app.color.accentOn'))
              // 静态强调色底：热门标签数量多且随输入法弹出重排，不挂实时模糊
              .backgroundColor(Glass.accentTint())
              .border({ width: 1, color: Glass.listBorder() })
              .borderRadius(this.carTouch(34) / 2)
              .height(this.carTouch(34))
              .padding({ left: 15, right: 15 })
              .textAlign(TextAlign.Center)
              .maxLines(1)
              .scale({ x: this.pressKey === `h${tag}` ? 0.95 : 1, y: this.pressKey === `h${tag}` ? 0.95 : 1 })
              .animation({ duration: 130, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.pressKey = `h${tag}`;
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.pressKey = '';
                }
              })
              .onClick(() => {
                this.keyword = tag;
                this.doSearch(true);
              })
          }, (tag: string) => tag)
        }
        .width('100%')

        // ── 最近搜索：搜过的关键词，点一下重搜 ──
        if (this.historyWords.length > 0) {
          Row() {
            Text('最近搜索')
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textDim'))
            Blank()
            Text('清空')
              .fontSize(this.carFont(Metrics.smallSize - 1))
              .fontColor($r('app.color.textFaint'))
              .padding({ left: 12, right: 4, top: 6, bottom: 6 })
              // 车机：可点元素 ≥48vp，给「清空」补足热区高度
              .constraintSize({ minHeight: this.carTouch(32) })
              .onClick(() => {
                AppState.searchHistory.clear();
                this.historyWords = [];
              })
          }
          .width('100%')
          .padding({ top: 26, bottom: 12 })

          Flex({
            wrap: FlexWrap.Wrap,
            justifyContent: FlexAlign.Start,
            space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(10) }
          }) {
            ForEach(this.historyWords, (word: string) => {
              Text(word)
                .fontSize(this.carFont(Metrics.smallSize))
                .fontColor($r('app.color.textDim'))
                // 历史词条静态底：数量多、重排频繁，不挂实时模糊
                .backgroundColor(Glass.listTint())
                .border({ width: 1, color: Glass.listBorder() })
                .borderRadius(this.carTouch(34) / 2)
                .height(this.carTouch(34))
                .padding({ left: 15, right: 15 })
                .textAlign(TextAlign.Center)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 240 })
                .scale({ x: this.pressKey === `w${word}` ? 0.95 : 1, y: this.pressKey === `w${word}` ? 0.95 : 1 })
                .animation({ duration: 130, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressKey = `w${word}`;
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressKey = '';
                  }
                })
                .onClick(() => {
                  this.keyword = word;
                  this.doSearch(true);
                })
            }, (word: string) => word)
          }
          .width('100%')
        } else {
          Text('搜过的关键词会留在这里，下次点一下就行')
            .fontSize(Metrics.smallSize - 1)
            .fontColor($r('app.color.textFaint'))
            .width('100%')
            .padding({ top: 26 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: this.pad(), right: this.pad(), bottom: this.bottomInset })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .onDidScroll(() => {
      this.onScroll();
    })
  }

  build() {
    Column() {
      // 这里刻意不再放一版大标题「搜索」：
      // (1) 顶部标题栏已经写着「搜索」，两个同名字叠在屏幕顶部是重复信息；
      // (2) 这一版大标题没吃 safeTop，实测会被系统状态栏的时间压住（截图里能看到残影）。
      // 搜索页的主入口是输入框，直接让它顶到标题栏下方，层级更干净。

      // 搜索框 + 内嵌按钮：外层控制左右边距，内层撑满剩余宽度
      Row() {
        Row() {
          TextInput({ placeholder: '搜剧名、演员或关键词', text: this.keyword })
            .layoutWeight(1)
            .height(this.carTouch(Metrics.searchHeight))
            .fontSize(this.carFont(Metrics.smallSize))
            .fontColor($r('app.color.text'))
            .placeholderColor($r('app.color.textFaint'))
            .backgroundColor(Color.Transparent)
            .padding({ left: 18, right: 8 })
            .onChange((value: string) => {
              this.keyword = value;
              // 关键词清空后回到「最近搜索」，否则搜完一次就再也回不到历史列表
              if (value.trim().length === 0 && this.searched) {
                this.searched = false;
                this.errorText = '';
              }
            })
            .cancelButton({ style: CancelButtonStyle.INPUT })
            .onSubmit(() => {
              this.doSearch(true);
            })

          Text('搜索')
            .fontSize(this.carFont(Metrics.smallSize))
            .fontColor($r('app.color.accentOn'))
            .backgroundEffect({
              radius: Glass.spec(GlassTier.Thin).blurRadius,
              saturation: Glass.spec(GlassTier.Thin).saturation,
              brightness: Glass.spec(GlassTier.Thin).brightness,
              color: Glass.accentTint()
            })
            .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
            .height(this.carTouch(Metrics.searchHeight))
            .width(this.carTouch(61))
            .borderRadius(this.carTouch(Metrics.searchHeight) / 2)
            .textAlign(TextAlign.Center)
            .scale({ x: this.pressKey === 'go' ? 0.94 : 1, y: this.pressKey === 'go' ? 0.94 : 1 })
            .animation({ duration: 120, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.pressKey = 'go';
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.pressKey = '';
              }
            })
            .onClick(() => {
              this.doSearch(true);
            })
        }
        .width('100%')
        .constraintSize({ maxWidth: 560 })
        .height(this.carTouch(Metrics.searchHeight))
        .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
        .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
        .borderRadius(this.carTouch(Metrics.searchHeight) / 2)
        .shadow({
          radius: Glass.spec(GlassTier.Thin).shadowRadius,
          color: Glass.spec(GlassTier.Thin).shadowColor,
          offsetX: 0,
          offsetY: 4
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: this.pad(), right: this.pad(), top: this.topInset + 15 })

      if (this.loading) {
        StateHint({ message: '正在搜索…', busy: true })
          .layoutWeight(1)
      } else if (this.errorText.length > 0) {
        StateHint({ message: '搜索没成功', detail: this.errorText })
          .layoutWeight(1)
      } else if (!this.searched) {
        this.searchHistoryBlock()
      } else if (this.items.length === 0) {
        StateHint({ message: '没有找到相关剧集', detail: '换个关键词试试' })
          .layoutWeight(1)
      } else {
        Scroll() {
          Column() {
            Flex({
              wrap: FlexWrap.Wrap,
              justifyContent: FlexAlign.Start,
              space: { main: LengthMetrics.vp(Metrics.cardGap), cross: LengthMetrics.vp(18) }
            }) {
              ForEach(this.items, (item: Drama) => {
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
              }, (item: Drama) => item.seriesId)
            }
            .width('100%')

            if (this.hasMore) {
              Text('加载更多')
                .fontSize(this.carFont(Metrics.smallSize))
                .fontColor($r('app.color.text'))
                .height(this.carTouch(Metrics.chipHeight))
                .padding({ left: 20, right: 20 })
                .backgroundColor($r('app.color.surfaceHigh'))
                .borderRadius(this.carTouch(Metrics.chipHeight) / 2)
                .margin({ bottom: 24 })
                .scale({ x: this.pressKey === 'more' ? 0.95 : 1, y: this.pressKey === 'more' ? 0.95 : 1 })
                .animation({ duration: 130, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressKey = 'more';
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressKey = '';
                  }
                })
                .onClick(() => {
                  this.doSearch(false);
                })
            }
          }
          .width('100%')
          .padding({ left: this.pad(), right: this.pad(), top: 16, bottom: this.bottomInset })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .onDidScroll(() => {
          this.onScroll();
        })
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
