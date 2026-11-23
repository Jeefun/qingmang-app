/**
 * 通用 UI 组件。
 *
 * 尺寸取自手机实测（1260px / 360vp，比例 3.5），见 docs/phone-reference。
 * 手机是触屏操作，不需要车机那套焦点放大 + 描边，交互只保留按压反馈。
 */
import { Metrics } from '../theme/Theme';
import { Glass, GlassTier } from '../theme/Glass';

/** 海报卡：竖版 2:3 封面 + 右下角集数标签 + 下方两行剧名 */
@Component
export struct PosterCard {
  @Prop title: string = '';
  @Prop cover: string = '';
  /** 右下角标签，如「全 20 集」 */
  @Prop meta: string = '';
  @Prop cardWidth: number = Metrics.posterWidth;
  /** 字号缩放：车机传 1.15（卡片放大后 11/13vp 的字跟不上），手机默认 1 */
  @Prop fontBoost: number = 1;
  seriesId: string = '';
  @State pressed: boolean = false;
  onSelect: (seriesId: string) => void = () => {
  };

  private posterHeight(): number {
    return Math.round(this.cardWidth * Metrics.posterRatio);
  }

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.cover)
          .width('100%')
          .height(this.posterHeight())
          .objectFit(ImageFit.Cover)
          // 官方《性能提升建议》：源图远大于显示尺寸时开启自动降采样，
          // 避免按原分辨率解码吃掉内存（信息流封面最典型）
          .autoResize(true)
          .borderRadius(Metrics.posterRadius)
          .backgroundColor($r('app.color.surfaceHigh'))
          .alt($r('app.media.startIcon'))

        if (this.meta.length > 0) {
          Text(this.meta)
            .fontSize(Math.round(Metrics.tinySize * this.fontBoost))
            .fontColor(Color.White)
            // 静态半透明黑底：信息流同屏 6+ 张海报，逐张挂实时模糊是滚动掉帧大户；
            // 半透明黑蒙版在封面上的观感与模糊版几乎一致
            .backgroundColor('#73000000')
            .border({ width: 1, color: '#33FFFFFF' })
            .padding({ left: Math.round(7 * this.fontBoost), right: Math.round(7 * this.fontBoost),
              top: Math.round(3 * this.fontBoost), bottom: Math.round(3 * this.fontBoost) })
            .borderRadius(6)
            .margin({ right: Math.round(7 * this.fontBoost), bottom: Math.round(7 * this.fontBoost) })
        }
      }
      .width('100%')
      .height(this.posterHeight())
      .clip(true)

      Text(this.title)
        .fontSize(Math.round(Metrics.smallSize * this.fontBoost))
        .fontColor($r('app.color.text'))
        .lineHeight(Math.round(18 * this.fontBoost))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .height(Math.round(36 * this.fontBoost))
    }
    .width(this.cardWidth)
    .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
    .opacity(this.pressed ? 0.9 : 1)
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onSelect(this.seriesId);
    })
  }
}

/** 小节标题，如「继续观看」「简介」「选集」 */
@Component
export struct SectionTitle {
  @Prop text: string = '';
  @Prop trailing: string = '';

  build() {
    Row() {
      Text(this.text)
        .fontSize(Metrics.bodySize)
        .fontColor($r('app.color.text'))
        .fontWeight(FontWeight.Medium)
      Blank()
      if (this.trailing.length > 0) {
        Text(this.trailing)
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textFaint'))
      }
    }
    .width('100%')
    .margin({ bottom: 10 })
  }
}

/** 分段控件中的单个胶囊（主题三选、倍速五选、集数选择） */
@Component
export struct SegmentedChip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  @Prop chipWidth: number = 95;
  @State pressed: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(Metrics.smallSize + 1)
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.active ? $r('app.color.inkOn') : $r('app.color.textDim'))
      // 选中 = 强调色实底，未选中 = 静态半透明底。
      // 分段胶囊在全站数以十计（设置页一屏 20+），逐个挂实时模糊 + 阴影
      // 是设置页掉帧的主因，全部改为静态底色。
      .backgroundColor(this.active ? Glass.accentTint() : Glass.listTint())
      .border({ width: 1, color: this.active ? Color.Transparent : Glass.listBorder() })
      .borderRadius(Metrics.chipHeight / 2)
      .height(Metrics.chipHeight)
      .width(this.chipWidth)
      .textAlign(TextAlign.Center)
      .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
      // 选中态换底不再瞬变，轻微 180ms 过渡让「点下去」有回应
      .animation({ duration: 180, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
        }
      })
      .onClick(() => {
        this.onTap();
      })
  }
}

/** 白底圆角卡片容器，「我的」页每个分组用一张 */
@Component
export struct SettingCard {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(Metrics.cardPadding)
    // 设置卡片：常规档玻璃。页面底色会从卡片里透出来一点，
    // 分组之间靠弥散阴影拉开层次，不再靠一块死白底
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

/** 设置分组标题，小号灰字 */
@Component
export struct GroupLabel {
  @Prop text: string = '';

  build() {
    Text(this.text)
      .fontSize(Metrics.smallSize)
      .fontColor($r('app.color.textFaint'))
      .width('100%')
      .padding({ left: 4 })
      .margin({ top: 22, bottom: 10 })
  }
}

/** 设置项：标题 + 说明 + 右侧开关 */
@Component
export struct SettingSwitchRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop on: boolean = false;
  onToggle: (value: boolean) => void = () => {
  };

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(Metrics.bodySize)
          .fontColor($r('app.color.text'))
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(Metrics.smallSize - 1)
            .fontColor($r('app.color.textFaint'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .selectedColor($r('app.color.accent'))
        .width(46)
        .height(26)
        .onChange((value: boolean) => {
          this.onToggle(value);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }
}

@Component
export struct StateHint {
  @Prop message: string = '';
  @Prop detail: string = '';
  @Prop busy: boolean = false;
  @Prop actionText: string = '';
  onAction: () => void = () => {
  };

  build() {
    Column({ space: 12 }) {
      if (this.busy) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color($r('app.color.accent'))
      }
      Text(this.message)
        .fontSize(Metrics.bodySize + 2)
        .fontColor($r('app.color.text'))
        .textAlign(TextAlign.Center)
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(Metrics.smallSize)
          .fontColor($r('app.color.textFaint'))
          .textAlign(TextAlign.Center)
          .maxLines(3)
      }
      if (this.actionText.length > 0) {
        Button(this.actionText)
          .fontSize(Metrics.bodySize)
          .height(Metrics.touchMin)
          // 空态里的主操作：强调色玻璃，与全站按钮同一套材质
          .backgroundEffect({
            radius: Glass.spec(GlassTier.Regular).blurRadius,
            saturation: Glass.spec(GlassTier.Regular).saturation,
            brightness: Glass.spec(GlassTier.Regular).brightness,
            color: Glass.accentTint()
          })
          .border({ width: 1, color: Glass.spec(GlassTier.Regular).borderColor })
          .fontColor($r('app.color.inkOn'))
          .borderRadius(Metrics.touchMin / 2)
          .shadow({
            radius: Glass.spec(GlassTier.Regular).shadowRadius,
            color: Glass.spec(GlassTier.Regular).shadowColor,
            offsetX: 0,
            offsetY: 6
          })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Metrics.safeMargin * 2)
  }
}

/** 通用胶囊标签（分类、题材等） */
@Component
export struct TagChip {
  @Prop text: string = '';
  @Prop active: boolean = false;
  @State pressed: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.text)
      .fontSize(Metrics.smallSize)
      .fontColor(this.active ? $r('app.color.inkOn') : $r('app.color.textDim'))
      // 同 SegmentedChip：静态底色，不挂实时模糊与阴影
      .backgroundColor(this.active ? Glass.accentTint() : Glass.listTint())
      .border({ width: 1, color: this.active ? Color.Transparent : Glass.listBorder() })
      .borderRadius(14)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
      .animation({ duration: 150, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
        }
      })
      .onClick(() => {
        this.onTap();
      })
  }
}

/**
 * 导航图标。
 *
 * 这里必须用 SVG 资源，不能再用 Path().commands() 手绘：
 * 同一套 commands 在 Path 组件里只有第一段子路径会被描边，后面几段直接丢——
 * 实测症状就是放大镜没有手柄、时钟没有指针、人像糊成一个小方点。
 * SVG 由 skia 解析，多段子路径、单线段都正常。
 *
 * 颜色写死在 SVG 里（base 深墨、dark 浅墨两套 media），不走 fillColor：
 * fillColor 会把 stroke 型图标的 fill="none" 覆盖成实心，图形会走样。
 * 未选中态只用透明度压低，避免再维护第二套色值。
 */
@Component
export struct NavIcon {
  /** home / search / history / profile */
  @Prop type: string = '';
  @Prop active: boolean = false;
  /** 图标边长（vp）：默认走 token；车机侧栏传入放大值，底部胶囊保持 token 不变 */
  @Prop iconSize: number = Metrics.floatNavIcon;

  private src(): Resource {
    if (this.type === 'search') {
      return $r('app.media.ic_nav_search');
    }
    if (this.type === 'history') {
      return $r('app.media.ic_nav_history');
    }
    if (this.type === 'fav') {
      return $r('app.media.ic_nav_fav');
    }
    if (this.type === 'profile') {
      return $r('app.media.ic_nav_profile');
    }
    return $r('app.media.ic_nav_home');
  }

  build() {
    Image(this.src())
      // 尺寸统一走 token：底部胶囊与宽屏侧栏共用同一个 NavIcon，
      // 以前这里写死 23 而 Metrics.floatNavIcon 是 22，两处对不上、改 token 也不生效。
      .width(this.iconSize)
      .height(this.iconSize)
      .objectFit(ImageFit.Contain)
      // 未选中态 0.58 太淡，四个里三个都显得比实际更小；0.72 仍有主次但不「发虚」。
      .opacity(this.active ? 1 : 0.72)
      .animation({ duration: 180, curve: Curve.EaseOut })
  }
}
