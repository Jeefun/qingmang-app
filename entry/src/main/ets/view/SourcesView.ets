/**
 * 站源管理页：已安装 / 在线仓库 / 内置源 / 手动安装 四段式。
 *
 * 模块在应用内隐藏 Web 沙箱中执行取流（net/ModuleRuntime.ets），
 * 安装完成即可在首页「切换站源」里启用。
 * 页面视觉与「我的」页同一套卡片语言（SettingCard + GroupLabel）。
 */
import { common } from '@kit.AbilityKit';
import { InstalledModule, ModuleIndexEntry } from '../model/SourceModels';
import { SourceRegistry } from '../store/SourceRegistry';
import { Metrics } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';
import { StateHint } from './Widgets';

/** 在线仓库状态 */
const IDX_IDLE: number = 0;
const IDX_LOADING: number = 1;
const IDX_OK: number = 2;
const IDX_ERROR: number = 3;

const TAB_LABELS: string[] = ['已安装', '在线仓库', '内置源', '手动安装'];

@Component
export struct SourcesView {
  @StorageProp('safeTop') safeTopPx: number = 0;
  @StorageProp('safeBottom') safeBottomPx: number = 0;
  @State tabIdx: number = 0;
  /** 已安装模块（进入页面与每次变更后刷新） */
  @State installedList: InstalledModule[] = [];
  /** 在线索引 */
  @State indexEntries: ModuleIndexEntry[] = [];
  @State indexState: number = IDX_IDLE;
  @State indexError: string = '';
  /** 安装中的模块 id 集合（去重） */
  @State installingIds: string[] = [];
  /** 手动安装表单 */
  @State manualRepo: string = '';
  @State manualTag: string = '';
  @State manualBusy: boolean = false;
  @State manualHint: string = '';
  @State viewWidth: number = 0;
  /** Tab chip / 列表项按压态 */
  @State pressKey: string = '';
  @State uninstallingId: string = '';

  onBack: () => void = () => {
  };
  onScroll: () => void = () => {
  };

  aboutToAppear(): void {
    this.refreshInstalled();
    if (this.indexState === IDX_IDLE) {
      this.loadIndex();
    }
  }

  private refreshInstalled(): void {
    this.installedList = SourceRegistry.installed().slice();
  }

  private hostContext(): common.UIAbilityContext | undefined {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return undefined;
    }
    return host as common.UIAbilityContext;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 1800 });
  }

  private async loadIndex(): Promise<void> {
    this.indexState = IDX_LOADING;
    this.indexError = '';
    try {
      this.indexEntries = await SourceRegistry.fetchIndex();
      this.indexState = IDX_OK;
    } catch (error) {
      this.indexError = (error as Error).message;
      this.indexState = IDX_ERROR;
    }
  }

  private isInstalling(id: string): boolean {
    return this.installingIds.indexOf(id) >= 0;
  }

  private markInstalling(id: string, on: boolean): void {
    const next: string[] = [];
    for (const item of this.installingIds) {
      if (item !== id) {
        next.push(item);
      }
    }
    if (on) {
      next.push(id);
    }
    this.installingIds = next;
  }

  private async installEntry(entry: ModuleIndexEntry): Promise<void> {
    if (this.isInstalling(entry.id)) {
      return;
    }
    const context = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.markInstalling(entry.id, true);
    try {
      await SourceRegistry.install(entry, context);
      this.refreshInstalled();
      this.toast(`已安装「${entry.name}」，可在首页切换使用`);
    } catch (error) {
      this.toast(`安装失败：${(error as Error).message}`);
    } finally {
      this.markInstalling(entry.id, false);
    }
  }

  private async installManual(): Promise<void> {
    const repo: string = this.manualRepo.trim();
    const tag: string = this.manualTag.trim();
    if (repo.length === 0 || tag.length === 0) {
      this.toast('请填写模块仓库（owner/repo）与版本标签');
      return;
    }
    if (this.manualBusy) {
      return;
    }
    const context = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.manualBusy = true;
    this.manualHint = '';
    try {
      const installed = await SourceRegistry.installManual(repo, tag, context);
      this.refreshInstalled();
      this.manualRepo = '';
      this.manualTag = '';
      this.toast(`已安装「${installed.name}」，可在首页切换使用`);
    } catch (error) {
      this.manualHint = (error as Error).message;
    } finally {
      this.manualBusy = false;
    }
  }

  private uninstall(id: string): void {
    const context = this.hostContext();
    if (context === undefined) {
      this.toast('无法获取应用上下文');
      return;
    }
    this.uninstallingId = id;
    SourceRegistry.uninstall(id, context);
    this.refreshInstalled();
    this.uninstallingId = '';
    this.toast('已卸载该模块');
  }

  private pad(): number {
    return Math.max(Metrics.safeMargin, (this.viewWidth - 560) / 2);
  }

  private isBuiltinActive(): boolean {
    return SourceRegistry.activeId() === SourceRegistry.BUILTIN_ID;
  }

  private activateBuiltin(): void {
    SourceRegistry.activate(SourceRegistry.BUILTIN_ID);
    this.toast('已切换到内置内容源');
  }

  /** 四段式 Tab 胶囊 */
  @Builder
  tabRow() {
    Row({ space: 8 }) {
      ForEach(TAB_LABELS, (label: string, idx: number) => {
        Text(label)
          .fontSize(Metrics.smallSize)
          .fontWeight(idx === this.tabIdx ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(idx === this.tabIdx ? $r('app.color.inkOn') : $r('app.color.textDim'))
          .height(Metrics.chipHeight)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Center)
          .backgroundColor(idx === this.tabIdx ? Glass.accentTint() : Glass.listTint())
          .border({ width: 1, color: idx === this.tabIdx ? Color.Transparent : Glass.listBorder() })
          .borderRadius(Metrics.chipHeight / 2)
          .scale({ x: this.pressKey === `tab${idx}` ? 0.95 : 1, y: this.pressKey === `tab${idx}` ? 0.95 : 1 })
          .animation({ duration: 150, curve: Curve.EaseOut })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.pressKey = `tab${idx}`;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressKey = '';
            }
          })
          .onClick(() => {
            this.tabIdx = idx;
            if (idx === 1 && this.indexState === IDX_IDLE) {
              this.loadIndex();
            }
          })
      }, (label: string, idx: number) => `tab${idx}_${label}`)
    }
    .width('100%')
  }

  /** 已安装模块行 */
  @Builder
  installedRow(module: InstalledModule) {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text(module.name)
            .fontSize(Metrics.bodySize)
            .fontColor($r('app.color.text'))
          Text(`v${module.version} · 已就绪`)
            .fontSize(Metrics.smallSize - 1)
            .fontColor($r('app.color.textFaint'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.uninstallingId === module.id ? '卸载中' : '卸载')
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textDim'))
          .height(Metrics.chipHeight)
          .padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Center)
          .backgroundColor(Glass.listTint())
          .border({ width: 1, color: Glass.listBorder() })
          .borderRadius(Metrics.chipHeight / 2)
          .scale({ x: this.pressKey === `un${module.id}` ? 0.95 : 1,
            y: this.pressKey === `un${module.id}` ? 0.95 : 1 })
          .animation({ duration: 140, curve: Curve.EaseOut })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.pressKey = `un${module.id}`;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressKey = '';
            }
          })
          .onClick(() => {
            this.uninstall(module.id);
          })
      }
      .width('100%')

      if (module.description.length > 0) {
        Text(module.description)
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textFaint'))
          .margin({ top: 6 })
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  /** 在线索引行 */
  @Builder
  indexRow(entry: ModuleIndexEntry) {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(entry.name)
              .fontSize(Metrics.bodySize)
              .fontColor($r('app.color.text'))
            Text(`v${entry.version}`)
              .fontSize(Metrics.smallSize - 1)
              .fontColor($r('app.color.textFaint'))
            if (entry.adult) {
              Text('18+')
                .fontSize(Metrics.tinySize)
                .fontColor($r('app.color.textFaint'))
                .border({ width: 1, color: Glass.listBorder() })
                .borderRadius(5)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            }
          }
          if (entry.description.length > 0) {
            Text(entry.description)
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textFaint'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.isInstalling(entry.id)) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color($r('app.color.accent'))
            .margin({ left: 10 })
        } else if (SourceRegistry.isInstalled(entry.id)) {
          Text('已安装')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textFaint'))
            .margin({ left: 10 })
        } else {
          Text('安装')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.inkOn'))
            .height(Metrics.chipHeight)
            .padding({ left: 16, right: 16 })
            .textAlign(TextAlign.Center)
            .backgroundColor(Glass.accentTint())
            .borderRadius(Metrics.chipHeight / 2)
            .margin({ left: 10 })
            .scale({ x: this.pressKey === `in${entry.id}` ? 0.95 : 1,
              y: this.pressKey === `in${entry.id}` ? 0.95 : 1 })
            .animation({ duration: 140, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.pressKey = `in${entry.id}`;
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.pressKey = '';
              }
            })
            .onClick(() => {
              this.installEntry(entry);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  /** 已安装 Tab */
  @Builder
  installedPane() {
    if (this.installedList.length === 0) {
      Row() {
        StateHint({
          message: '还没有安装模块',
          detail: '切到「在线仓库」浏览可安装的内容源模块',
          actionText: '去在线仓库',
          onAction: () => {
            this.tabIdx = 1;
          }
        })
      }
      .width('100%')
      .height(320)
    } else {
      Column() {
        ForEach(this.installedList, (module: InstalledModule) => {
          this.installedRow(module)
          if (this.installedList.indexOf(module) < this.installedList.length - 1) {
            Divider().color(Glass.listBorder()).margin({ top: 4, bottom: 4 })
          }
        }, (module: InstalledModule) => `${module.id}-${module.version}`)
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
    }
  }

  /** 在线仓库 Tab */
  @Builder
  indexPane() {
    if (this.indexState === IDX_LOADING) {
      Row() {
        StateHint({ message: '正在拉取模块索引…', busy: true })
      }
      .width('100%')
      .height(320)
    } else if (this.indexState === IDX_ERROR) {
      Row() {
        StateHint({
          message: '索引拉取失败',
          detail: this.indexError,
          actionText: '重试',
          onAction: () => {
            this.loadIndex();
          }
        })
      }
      .width('100%')
      .height(320)
    } else if (this.indexEntries.length === 0) {
      Row() {
        StateHint({ message: '仓库里暂时没有模块' })
      }
      .width('100%')
      .height(320)
    } else {
      Column() {
        ForEach(this.indexEntries, (entry: ModuleIndexEntry) => {
          this.indexRow(entry)
          if (this.indexEntries.indexOf(entry) < this.indexEntries.length - 1) {
            Divider().color(Glass.listBorder()).margin({ top: 4, bottom: 4 })
          }
        }, (entry: ModuleIndexEntry) => `${entry.id}-${entry.tag}`)
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
    }
  }

  /** 内置源 Tab */
  @Builder
  builtinPane() {
    Column({ space: 14 }) {
      Column() {
        Row() {
          Column({ space: 4 }) {
            Text(SourceRegistry.BUILTIN_NAME)
              .fontSize(Metrics.bodySize + 1)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text'))
            Text('应用默认内容源，安装即用，无需模块运行时')
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textFaint'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.isBuiltinActive()) {
            Text('当前使用')
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.inkOn'))
              .height(Metrics.chipHeight)
              .padding({ left: 12, right: 12 })
              .textAlign(TextAlign.Center)
              .backgroundColor(Glass.accentTint())
              .borderRadius(Metrics.chipHeight / 2)
          } else {
            Text('启用')
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textDim'))
              .height(Metrics.chipHeight)
              .padding({ left: 16, right: 16 })
              .textAlign(TextAlign.Center)
              .backgroundColor(Glass.listTint())
              .border({ width: 1, color: Glass.listBorder() })
              .borderRadius(Metrics.chipHeight / 2)
              .onClick(() => {
                this.activateBuiltin();
              })
          }
        }
        .width('100%')
        .padding({ top: 14, bottom: 14 })
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

      Text('第三方模块在应用内沙箱中运行取流；已安装模块可在首页「切换站源」处直接启用。')
        .fontSize(Metrics.smallSize)
        .fontColor($r('app.color.textFaint'))
        .width('100%')
        .padding({ left: 4, right: 4 })
    }
    .width('100%')
  }

  /** 手动安装 Tab */
  @Builder
  manualPane() {
    Column({ space: 14 }) {
      Column() {
        Column({ space: 10 }) {
          Text('按仓库地址安装')
            .fontSize(Metrics.bodySize)
            .fontColor($r('app.color.text'))
            .width('100%')

          TextInput({ placeholder: '模块仓库（owner/repo）', text: this.manualRepo })
            .onChange((value: string) => {
              this.manualRepo = value;
            })
            .height(42)
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.text'))
            .placeholderColor($r('app.color.textFaint'))
            .backgroundColor($r('app.color.surfaceHigh'))
            .borderRadius(12)
            .width('100%')

          TextInput({ placeholder: '版本标签（如 v1.0.1）', text: this.manualTag })
            .onChange((value: string) => {
              this.manualTag = value;
            })
            .height(42)
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.text'))
            .placeholderColor($r('app.color.textFaint'))
            .backgroundColor($r('app.color.surfaceHigh'))
            .borderRadius(12)
            .width('100%')

          if (this.manualBusy) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color($r('app.color.accent'))
              Text('正在下载并校验模块…')
                .fontSize(Metrics.smallSize)
                .fontColor($r('app.color.textFaint'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 4 })
          } else {
            Text('安装')
              .fontSize(Metrics.bodySize)
              .fontColor($r('app.color.inkOn'))
              .height(Metrics.primaryButtonHeight)
              .width('100%')
              .textAlign(TextAlign.Center)
              .backgroundColor(Glass.accentTint())
              .borderRadius(Metrics.primaryButtonHeight / 2)
              .margin({ top: 4 })
              .scale({ x: this.pressKey === 'manualGo' ? 0.97 : 1, y: this.pressKey === 'manualGo' ? 0.97 : 1 })
              .animation({ duration: 140, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.pressKey = 'manualGo';
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.pressKey = '';
                }
              })
              .onClick(() => {
                this.installManual();
              })
          }

          if (this.manualHint.length > 0) {
            Text(this.manualHint)
              .fontSize(Metrics.smallSize)
              .fontColor($r('app.color.textFaint'))
              .width('100%')
          }
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

      Text('安装将拉取该仓库指定标签下的 manifest.json 与 main.js；校验通过后保存在本机，即可在首页切换使用。')
        .fontSize(Metrics.smallSize)
        .fontColor($r('app.color.textFaint'))
        .width('100%')
        .padding({ left: 4, right: 4 })
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Row() {
          Image($r('app.media.ic_src_back'))
            .width(22)
            .height(22)
            .objectFit(ImageFit.Contain)
        }
        .width(Metrics.roundBtnSize)
        .height(Metrics.roundBtnSize)
        .borderRadius(Metrics.roundBtnSize / 2)
        .backgroundEffect(Glass.effect(Glass.spec(GlassTier.Thin)))
        .border({ width: 1, color: Glass.spec(GlassTier.Thin).borderColor })
        .scale({ x: this.pressKey === 'back' ? 0.92 : 1, y: this.pressKey === 'back' ? 0.92 : 1 })
        .animation({ duration: 150, curve: Curve.EaseOut })
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

        Text('站源管理')
          .fontSize(Metrics.heroTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .layoutWeight(1)
          .margin({ left: 12 })

        if (this.tabIdx === 1) {
          Text(this.indexState === IDX_LOADING ? '刷新中' : '刷新')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textDim'))
            .height(Metrics.chipHeight)
            .padding({ left: 14, right: 14 })
            .textAlign(TextAlign.Center)
            .backgroundColor(Glass.listTint())
            .border({ width: 1, color: Glass.listBorder() })
            .borderRadius(Metrics.chipHeight / 2)
            .onClick(() => {
              this.loadIndex();
            })
        }
      }
      .width('100%')
      .padding({ left: this.pad(), right: this.pad(), top: this.safeTopPx + 8, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Row() {
        this.tabRow()
      }
      .width('100%')
      .padding({ left: this.pad(), right: this.pad(), bottom: 14 })

      Scroll() {
        Column({ space: 14 }) {
          if (this.tabIdx === 0) {
            this.installedPane()
          } else if (this.tabIdx === 1) {
            this.indexPane()
          } else if (this.tabIdx === 2) {
            this.builtinPane()
          } else {
            this.manualPane()
          }
        }
        .width('100%')
        .padding({ left: this.pad(), right: this.pad(), top: 2, bottom: this.safeBottomPx + 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onDidScroll(() => {
        this.onScroll();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.viewWidth = Number(newValue.width);
    })
  }
}
