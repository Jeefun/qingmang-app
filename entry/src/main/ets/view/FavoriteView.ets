/**
 * 收藏页。卡片网格复用历史页的断点（手机 3 列、宽屏按窗口宽度铺满）。
 * 点开进详情；长按卡片弹底部操作面板「置顶 / 设置分组 / 取消收藏」。
 * 有分组时顶部出现筛选 chip：全部 / 未分组 / 各分组。
 * 面板全部状态驱动（Stack 蒙层 + 底部卡片），不依赖 Menu 弹窗 API。
 */
import { LengthMetrics } from '@kit.ArkUI';
import { FavoriteItem } from '../model/Models';
import { AppState } from '../store/AppState';
import { Breakpoints, Metrics } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';
import { PosterCard, StateHint } from './Widgets';

@Component
export struct FavoriteView {
  @State items: FavoriteItem[] = [];
  @State viewWidth: number = 0;
  /** 车机虚拟屏：卡片列数、字号随之放大（EntryAbility 实时维护） */
  @StorageProp('carMode') carMode: boolean = false;
  /** 分组筛选：'' 全部、'__none' 未分组、其余为分组名 */
  @State activeGroup: string = '';
  /** 长按弹出的操作面板对应的 seriesId；空串表示面板未弹出 */
  @State menuId: string = '';
  /** 正在编辑分组的 seriesId；空串表示面板未弹出 */
  @State groupEditId: string = '';
  @State groupInput: string = '';
  /** 已在使用的分组名列表 */
  @State groupNames: string[] = [];

  /** 顶部标题栏占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;

  onOpen: (seriesId: string) => void = () => {
  };
  onScroll: () => void = () => {
  };

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = AppState.favorites.list();
    this.groupNames = AppState.favorites.groups();
    // 分组被清空后，筛选态若指向不存在的分组就回「全部」
    if (this.activeGroup !== '' && this.activeGroup !== '__none'
      && this.groupNames.indexOf(this.activeGroup) < 0) {
      this.activeGroup = '';
    }
  }

  /** 按当前筛选返回列表；置顶排序已由 FavoriteStore 完成 */
  private visibleItems(): FavoriteItem[] {
    if (this.activeGroup === '') {
      return this.items;
    }
    const out: FavoriteItem[] = [];
    for (const item of this.items) {
      if (this.activeGroup === '__none') {
        if (item.group.length === 0) {
          out.push(item);
        }
      } else if (item.group === this.activeGroup) {
        out.push(item);
      }
    }
    return out;
  }

  /** 长按面板对应的条目，找不到返回空串 */
  private menuTitle(): string {
    for (const item of this.items) {
      if (item.seriesId === this.menuId) {
        return item.title;
      }
    }
    return '';
  }

  private menuPinned(): boolean {
    for (const item of this.items) {
      if (item.seriesId === this.menuId) {
        return item.pinned;
      }
    }
    return false;
  }

  private menuGroup(): string {
    for (const item of this.items) {
      if (item.seriesId === this.menuId) {
        return item.group;
      }
    }
    return '';
  }

  /** 卡片右下角角标：置顶 > 分组名 > 空 */
  private cardMeta(item: FavoriteItem): string {
    if (item.pinned) {
      return item.group.length > 0 ? `置顶 · ${item.group}` : '置顶';
    }
    return item.group;
  }

  /** 正在编辑分组的条目，找不到返回空标题 */
  private groupEditTitle(): string {
    for (const item of this.items) {
      if (item.seriesId === this.groupEditId) {
        return item.title;
      }
    }
    return '';
  }

  /** 保存 / 清除正在编辑条目的分组 */
  private saveGroup(clear: boolean): void {
    const id = this.groupEditId;
    const name = clear ? '' : this.groupInput.trim();
    if (id.length > 0) {
      AppState.favorites.setGroup(id, name);
    }
    this.groupEditId = '';
    this.groupInput = '';
    this.refresh();
  }

  private winWidth(): number {
    return this.viewWidth > 0 ? this.viewWidth : 360;
  }

  private pad(): number {
    return Breakpoints.pagePadding(this.winWidth());
  }

  private cardWidth(): number {
    return Breakpoints.cardWidth(this.winWidth(),
      Breakpoints.gridColumns(this.winWidth(), this.carMode));
  }

  /** 分组筛选 chip */
  @Builder
  groupChip(label: string, value: string) {
    Text(label)
      .fontSize(Metrics.tinySize + 1)
      .fontWeight(this.activeGroup === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.activeGroup === value ? $r('app.color.chipOn') : $r('app.color.text'))
      .padding({ left: 15, right: 15, top: 7, bottom: 7 })
      .backgroundColor(this.activeGroup === value ? $r('app.color.lime') : Glass.listTint())
      .border({
        width: this.activeGroup === value ? 0 : 1,
        color: Glass.listBorder()
      })
      .borderRadius(Metrics.chipRadius)
      .onClick(() => {
        this.activeGroup = value;
      })
  }

  /** 长按操作面板的单行按钮 */
  @Builder
  sheetButton(label: string, danger: boolean, action: () => void) {
    Text(label)
      .fontSize(Metrics.bodySize)
      .fontWeight(FontWeight.Medium)
      .fontColor(danger ? '#FF7A6B' : $r('app.color.text'))
      .width('100%')
      .height(48)
      .textAlign(TextAlign.Center)
      .backgroundColor($r('app.color.surfaceHigh'))
      .borderRadius(24)
      .onClick(() => {
        action();
      })
  }

  /** 长按卡片：置顶 / 分组 / 取消收藏（纯状态驱动，稳定可靠） */
  @Builder
  actionSheet() {
    Column() {
      Blank()
      Column({ space: 10 }) {
        Text(this.menuTitle())
          .fontSize(Metrics.bodySize + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.menuGroup().length > 0) {
          Text(`当前分组：${this.menuGroup()}`)
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textFaint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        this.sheetButton(this.menuPinned() ? '取消置顶' : '置顶', false, () => {
          AppState.favorites.togglePin(this.menuId);
          this.menuId = '';
          this.refresh();
        })
        this.sheetButton(this.menuGroup().length > 0 ? '修改分组' : '设置分组', false, () => {
          this.groupEditId = this.menuId;
          this.groupInput = this.menuGroup();
          this.menuId = '';
        })
        this.sheetButton('取消收藏', true, () => {
          AppState.favorites.remove(this.menuId);
          this.menuId = '';
          this.refresh();
        })
        Text('关闭')
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textFaint'))
          .width('100%')
          .height(36)
          .textAlign(TextAlign.Center)
          .margin({ top: 4 })
          .onClick(() => {
            this.menuId = '';
          })
      }
      .padding(18)
      .borderRadius(22)
      .backgroundColor($r('app.color.bg'))
      .width('100%')
      .onClick(() => {
        // 消费点击，避免透传到底层蒙层把面板关掉
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.pad(), right: this.pad(), bottom: 24 })
    .backgroundColor('#66000000')
    .onClick(() => {
      this.menuId = '';
    })
  }

  /** 设置分组面板：输入新分组名，或点已有分组 chip 直接带上 */
  @Builder
  groupPanel() {
    Column() {
      Blank()
      Column({ space: 14 }) {
        Text('设置分组')
          .fontSize(Metrics.bodySize + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text'))
          .width('100%')
        Text(this.groupEditTitle())
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textFaint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        TextInput({ placeholder: '输入分组名，如「待看」「下饭」', text: this.groupInput })
          .onChange((value: string) => {
            this.groupInput = value;
          })
          .height(44)
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.text'))
          .placeholderColor($r('app.color.textFaint'))
          .backgroundColor($r('app.color.surfaceHigh'))
          .borderRadius(12)

        if (this.groupNames.length > 0) {
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            ForEach(this.groupNames, (name: string) => {
              Text(name)
                .fontSize(Metrics.tinySize + 1)
                .fontColor($r('app.color.text'))
                .padding({ left: 13, right: 13, top: 6, bottom: 6 })
                .backgroundColor($r('app.color.surfaceHigh'))
                .borderRadius(Metrics.chipRadius)
                .onClick(() => {
                  this.groupInput = name;
                })
            }, (name: string) => name)
          }
          .width('100%')
        }

        Row({ space: 10 }) {
          Text('取消')
            .fontSize(Metrics.bodySize)
            .fontColor($r('app.color.textDim'))
            .layoutWeight(1)
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.surfaceHigh'))
            .borderRadius(21)
            .onClick(() => {
              this.groupEditId = '';
              this.groupInput = '';
            })
          Text('清除分组')
            .fontSize(Metrics.bodySize)
            .fontColor($r('app.color.textDim'))
            .layoutWeight(1)
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.surfaceHigh'))
            .borderRadius(21)
            .onClick(() => {
              this.saveGroup(true);
            })
          Text('保存')
            .fontSize(Metrics.bodySize)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accentOn'))
            .layoutWeight(1)
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor($r('app.color.accent'))
            .borderRadius(21)
            .onClick(() => {
              this.saveGroup(false);
            })
        }
        .width('100%')
        .margin({ top: 2 })
      }
      .padding(18)
      .borderRadius(22)
      .backgroundColor($r('app.color.bg'))
      .width('100%')
      .onClick(() => {
        // 消费点击，避免透传到底层蒙层把面板关掉
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.pad(), right: this.pad(), bottom: 24 })
    .backgroundColor('#66000000')
    .onClick(() => {
      this.groupEditId = '';
      this.groupInput = '';
    })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('我的收藏')
            .fontSize(this.carMode ? Metrics.heroTitle + 4 : Metrics.heroTitle)
            .fontColor($r('app.color.text'))
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)

          if (this.items.length > 0) {
            Text(`${this.items.length} 部`)
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textFaint'))
          }
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad(), top: this.topInset + 10, bottom: 14 })

        // 分组筛选 chip：只在确实建过分组时出现
        if (this.groupNames.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              this.groupChip('全部', '')
              this.groupChip('未分组', '__none')
              ForEach(this.groupNames, (name: string) => {
                this.groupChip(name, name)
              }, (name: string) => name)
            }
            .padding({ right: this.pad() })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ left: this.pad() })
          .margin({ bottom: 14 })
        }

        if (this.items.length === 0) {
          StateHint({ message: '还没有收藏', detail: '在详情页点「收藏」，喜欢的剧就会出现在这里' })
            .layoutWeight(1)
        } else if (this.visibleItems().length === 0) {
          StateHint({ message: '这个分组暂时没有收藏', detail: '长按卡片可以调整分组' })
            .layoutWeight(1)
        } else {
          Scroll() {
            Column() {
              Flex({
                wrap: FlexWrap.Wrap,
                justifyContent: FlexAlign.Start,
                space: { main: LengthMetrics.vp(Metrics.cardGap), cross: LengthMetrics.vp(18) }
              }) {
                ForEach(this.visibleItems(), (item: FavoriteItem) => {
                  PosterCard({
                    title: item.title,
                    cover: item.cover,
                    meta: this.cardMeta(item),
                    cardWidth: this.cardWidth(),
                    fontBoost: this.carMode ? 1.15 : 1,
                    seriesId: item.seriesId,
                    onSelect: (id: string) => {
                      this.onOpen(id);
                    }
                  })
                    .gesture(LongPressGesture({ repeat: false, duration: 400 })
                      .onAction(() => {
                        this.menuId = item.seriesId;
                      }))
                }, (item: FavoriteItem) => `${item.seriesId}-${item.createdAt}-${item.pinned}-${item.group}`)
              }
              .width('100%')
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

      if (this.menuId.length > 0) {
        this.actionSheet()
      }

      if (this.groupEditId.length > 0) {
        this.groupPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}
