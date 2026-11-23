/**
 * 历史页。卡片式：竖版封面 + 进度叠加 + 剧名，点一下直接续播。
 * 卡片尺寸复用首页信息流的断点（手机 3 列、宽屏按窗口宽度铺满），
 * 不再用固定宽度的横条行——宽屏下横条会被拉得很长、右侧一大片空白。
 */
import { LengthMetrics } from '@kit.ArkUI';
import { HistoryItem } from '../model/Models';
import { AppState } from '../store/AppState';
import { Breakpoints, Metrics } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';
import { StateHint } from './Widgets';

/** 历史分组：今天 / 昨天 / 更早 */
class HistorySection {
  label: string = '';
  items: HistoryItem[] = [];
}

@Component
export struct HistoryView {
  @State items: HistoryItem[] = [];
  @State viewWidth: number = 0;
  /** 搜索关键词：按剧名过滤历史记录 */
  @State filterText: string = '';
  /** 卡片按压态（存 seriesId） */
  @State pressId: string = '';
  /** 车机虚拟屏：卡片列数、字号、角标随之放大（EntryAbility 实时维护） */
  @StorageProp('carMode') carMode: boolean = false;

  /** 顶部标题栏占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;

  onOpen: (seriesId: string, episodeIndex: number) => void = () => {
  };
  onScroll: () => void = () => {
  };

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = AppState.history.list();
  }

  /** 按剧名关键词过滤（大小写不敏感），空关键词返回全部 */
  private visibleItems(): HistoryItem[] {
    const keyword = this.filterText.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.items;
    }
    const out: HistoryItem[] = [];
    for (const item of this.items) {
      if (item.title.toLowerCase().indexOf(keyword) >= 0) {
        out.push(item);
      }
    }
    return out;
  }

  /** 今天 / 昨天 / 更早 三段（本地日历日），空结果返回空数组 */
  private sections(): HistorySection[] {
    const items: HistoryItem[] = this.visibleItems();
    const out: HistorySection[] = [];
    if (items.length === 0) {
      return out;
    }
    const now: Date = new Date();
    const yesterday: Date = new Date(now.getTime() - 86400000);
    for (const item of items) {
      const at: Date = new Date(item.updatedAt);
      let label: string = '更早';
      if (HistoryView.isSameDay(at, now)) {
        label = '今天';
      } else if (HistoryView.isSameDay(at, yesterday)) {
        label = '昨天';
      }
      let section: HistorySection | null = null;
      if (out.length > 0 && out[out.length - 1].label === label) {
        section = out[out.length - 1];
      } else {
        section = new HistorySection();
        section.label = label;
        out.push(section);
      }
      section.items.push(item);
    }
    return out;
  }

  private static isSameDay(a: Date, b: Date): boolean {
    return a.getFullYear() === b.getFullYear()
      && a.getMonth() === b.getMonth()
      && a.getDate() === b.getDate();
  }

  private winWidth(): number {
    return this.viewWidth > 0 ? this.viewWidth : 360;
  }

  /** 车机文字加两档：15.6 寸屏 + 驾驶观看距离，11/13vp 的字看不清 */
  private carFont(size: number): number {
    return this.carMode ? size + 2 : size;
  }

  private pad(): number {
    return Breakpoints.pagePadding(this.winWidth());
  }

  private cardWidth(): number {
    return Breakpoints.cardWidth(this.winWidth(),
      Breakpoints.gridColumns(this.winWidth(), this.carMode));
  }

  private posterHeight(): number {
    return Math.round(this.cardWidth() * Metrics.posterRatio);
  }

  /** 相对时间：比绝对时间更容易判断「这剧我还记不记得」 */
  private timeAgo(updatedAt: number): string {
    if (updatedAt <= 0) {
      return '';
    }
    const diff = Date.now() - updatedAt;
    if (diff < 60000) {
      return '刚刚';
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)} 分钟前`;
    }
    if (diff < 86400000) {
      return `${Math.floor(diff / 3600000)} 小时前`;
    }
    const days = Math.floor(diff / 86400000);
    if (days === 1) {
      return '昨天';
    }
    if (days < 30) {
      return `${days} 天前`;
    }
    return `${Math.floor(days / 30)} 个月前`;
  }

  /** 长按卡片：单条删除 */
  @Builder
  historyMenu(item: HistoryItem) {
    Menu() {
      MenuItem({ content: '删除这条记录' })
        .onClick(() => {
          AppState.history.remove(item.seriesId);
          this.refresh();
        })
    }
  }

  @Builder
  historyCard(item: HistoryItem) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 封面 + 右上角集数角标（手机 3 列时卡片只有 ~99vp，横排「看到第 N 集 + 百分比」会直接重叠）
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(item.cover)
            .width('100%')
            .height(this.posterHeight())
            .objectFit(ImageFit.Cover)
            // 官方《性能提升建议》：源图远大于显示尺寸时开启自动降采样，
            // 避免按原分辨率解码吃掉内存（信息流封面最典型）
            .autoResize(true)
            .backgroundColor($r('app.color.surfaceHigh'))
            .alt($r('app.media.startIcon'))

          Text(`第 ${item.episodeIndex} 集`)
            .fontSize(this.carFont(Metrics.tinySize))
            .fontColor(Color.White)
            // 静态半透明黑底：历史列表同屏多张卡片，不挂实时模糊
            .backgroundColor('#73000000')
            .border({ width: 1, color: '#33FFFFFF' })
            .padding({ left: this.carMode ? 9 : 7, right: this.carMode ? 9 : 7,
              top: this.carMode ? 4 : 3, bottom: this.carMode ? 4 : 3 })
            .borderRadius(6)
            .margin({ right: this.carMode ? 10 : 7, top: this.carMode ? 10 : 7 })
        }
        .width('100%')
        .height(this.posterHeight())

        // 进度条压在封面最底部，先垫一层轻渐变保证浅色封面上也看得见
        Column() {
          Text('')
            .width('100%')
            .height(26)
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0], ['#66000000', 1]]
            })

          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .backgroundColor('#4DFFFFFF')
            Row()
              .width(`${Math.round(item.progress * 100)}%`)
              .height(3)
              .backgroundColor($r('app.color.accent'))
          }
          .width('100%')
          .height(3)
        }
        .width('100%')
      }
      .width('100%')
      .height(this.posterHeight())
      .borderRadius(Metrics.posterRadius)
      .clip(true)

      Text(item.title)
        .fontSize(this.carFont(Metrics.smallSize))
        .lineHeight(this.carMode ? 24 : 18)
        .fontColor($r('app.color.text'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .height(this.carMode ? 48 : 36)

      Text(`${Math.round(item.progress * 100)}% · ${this.timeAgo(item.updatedAt)}`)
        .fontSize(this.carFont(Metrics.tinySize))
        .fontColor($r('app.color.textFaint'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(this.cardWidth())
    .bindContextMenu(this.historyMenu(item), ResponseType.LongPress)
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
      this.onOpen(item.seriesId, item.episodeIndex);
    })
  }

  build() {
    Column() {
      Row() {
        Text('观看历史')
          .fontSize(this.carMode ? Metrics.heroTitle + 4 : Metrics.heroTitle)
          .fontColor($r('app.color.text'))
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)

        if (this.items.length > 0) {
          // 清空按钮：车机上放大字号与高度——实车反馈它在标题行里小得几乎点不中
          Text('清空')
            .fontSize(this.carFont(Metrics.smallSize))
            .fontColor($r('app.color.textDim'))
            .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
            .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
            .borderRadius((this.carMode ? 52 : Metrics.chipHeight) / 2)
            .height(this.carMode ? 52 : Metrics.chipHeight)
            .padding({ left: this.carMode ? 26 : 18, right: this.carMode ? 26 : 18 })
            .textAlign(TextAlign.Center)
            .onClick(() => {
              AppState.history.clear();
              this.refresh();
            })
        }
      }
      .width('100%')
      .padding({ left: this.pad(), right: this.pad(), top: this.topInset + 10, bottom: 14 })

      // 搜索筛选：记录多于 6 条才有查找价值，少了直接扫一遍更快
      if (this.items.length > 6) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索剧名筛选记录', text: this.filterText })
            .onChange((value: string) => {
              this.filterText = value;
            })
            .height(40)
            .fontSize(this.carFont(Metrics.smallSize))
            .fontColor($r('app.color.text'))
            .placeholderColor($r('app.color.textFaint'))
            .backgroundColor($r('app.color.surfaceHigh'))
            .borderRadius(20)
            .padding({ left: 16, right: 16 })
            .layoutWeight(1)

          if (this.filterText.length > 0) {
            Text('清除')
              .fontSize(this.carFont(Metrics.smallSize))
              .fontColor($r('app.color.textDim'))
              .height(40)
              .padding({ left: 14, right: 14 })
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.filterText = '';
              })
          }
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad(), bottom: 16 })
      }

      if (this.items.length === 0) {
        StateHint({ message: '还没有观看记录', detail: '看过的剧会自动出现在这里' })
          .layoutWeight(1)
      } else if (this.visibleItems().length === 0) {
        StateHint({ message: '没有匹配的记录', detail: '换个关键词试试' })
          .layoutWeight(1)
      } else {
        Scroll() {
          Column({ space: 20 }) {
            ForEach(this.sections(), (section: HistorySection) => {
              Column() {
                Text(`${section.label} · ${section.items.length} 部`)
                  .fontSize(this.carFont(Metrics.smallSize))
                  .fontColor($r('app.color.textFaint'))
                  .width('100%')
                  .padding({ left: 4 })
                  .margin({ bottom: 10 })

                Flex({
                  wrap: FlexWrap.Wrap,
                  justifyContent: FlexAlign.Start,
                  space: { main: LengthMetrics.vp(Metrics.cardGap), cross: LengthMetrics.vp(18) }
                }) {
                  ForEach(section.items, (item: HistoryItem) => {
                    this.historyCard(item)
                  }, (item: HistoryItem) => `${item.seriesId}-${item.updatedAt}`)
                }
                .width('100%')
              }
              .width('100%')
            }, (section: HistorySection) =>
              `${section.label}-${section.items.length}-${section.items[0].seriesId}`)
          }
          .width('100%')
          .padding({ left: this.pad(), right: this.pad(), top: 2, bottom: this.bottomInset })
        }
        .layoutWeight(1)
        .width('100%')
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
