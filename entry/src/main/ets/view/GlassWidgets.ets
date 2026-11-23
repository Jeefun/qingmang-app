/**
 * 玻璃质感的基础组件。
 *
 * 全站按钮 / 导航条 / 卡片都应该走这里，不要再手写
 * `backgroundColor` + `backgroundBlurStyle` 的组合——
 * 那样做出来是「磨砂塑料」而不是「液态玻璃」：缺高光描边、缺上沿反光、
 * 缺让元素浮起来的弥散阴影，也没有饱和度增益，背景的颜色透不上来。
 *
 * 三层结构（缺一层都会塌）：
 *   ① 玻璃本体：backgroundEffect(radius / saturation / brightness / color)
 *   ② 折射亮边：1px 描边 + 顶部两端淡出的高光条 + 底部微暗压边
 *   ③ 弥散投影：大半径低透明度，让组件从背景里浮起来
 */
import { Glass, GlassSpec, GlassTier } from '../theme/Glass';
import { Metrics } from '../theme/Theme';

/**
 * 玻璃容器。
 *
 * 用法：`GlassSurface({ tier: GlassTier.Thick, radius: 28 }) { ...内容... }`
 * pressable 打开后自动带按压缩放 + 高光增强。
 */
@Component
export struct GlassSurface {
  /** 玻璃厚度档位，见 GlassTier */
  @Prop tier: number = GlassTier.Regular;
  @Prop radius: number = 20;
  /** 是否响应按压（纯展示容器不要开，否则会被触摸态干扰） */
  @Prop pressable: boolean = false;
  /** 固定宽度；0 表示撑满父容器。导航条这类需要精确宽度的场景传具体值 */
  @Prop fixedWidth: number = 0;
  @State pressed: boolean = false;

  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;

  private spec(): GlassSpec {
    return Glass.spec(this.tier as GlassTier);
  }

  /** 顶部折射高光：两端透明、中间亮，才是玻璃边缘而不是一条白线 */
  @Builder
  topHighlight() {
    Row()
      .width('86%')
      .height(1)
      .borderRadius(0.5)
      .linearGradient({
        angle: 90,
        colors: [
          ['#00FFFFFF', 0.0],
          [this.spec().highlightColor, 0.5],
          ['#00FFFFFF', 1.0]
        ]
      })
  }

  /** 底部压边：一道极淡的暗线，给玻璃一点厚度，不然边缘会「飘」 */
  @Builder
  bottomEdge() {
    Row()
      .width('70%')
      .height(1)
      .borderRadius(0.5)
      .linearGradient({
        angle: 90,
        colors: [
          ['#00000000', 0.0],
          ['#14000000', 0.5],
          ['#00000000', 1.0]
        ]
      })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.content()
    }
    .width(this.fixedWidth > 0 ? this.fixedWidth : '100%')
    .borderRadius(this.radius)
    .backgroundEffect(Glass.effect(this.spec()))
    .border({ width: 1, color: this.spec().borderColor })
    .overlay(this.topHighlight(), { align: Alignment.Top, offset: { x: 0, y: 1 } })
    .overlay(this.bottomEdge(), { align: Alignment.Bottom, offset: { x: 0, y: -1 } })
    .shadow({
      radius: this.pressed ? this.spec().shadowRadius * 0.6 : this.spec().shadowRadius,
      color: this.spec().shadowColor,
      offsetX: 0,
      offsetY: this.pressed ? 2 : this.spec().shadowOffsetY
    })
    .scale({ x: this.pressed && this.pressable ? 0.97 : 1, y: this.pressed && this.pressable ? 0.97 : 1 })
    .animation({ duration: 160, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (!this.pressable) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}

/** 按钮视觉风格 */
export enum GlassButtonKind {
  /** 强调色：页面里唯一的主操作 */
  Primary = 0,
  /** 中性玻璃：次操作、工具按钮 */
  Neutral = 1,
  /** 仅图标：播放器里的圆钮、工具条 */
  Icon = 2
}

/**
 * 玻璃按钮。
 *
 * 不用系统 Button 组件：它的默认背景 / 内边距 / 按压态都要一条条覆盖，
 * 覆盖到后面反而比自绘更难控。这里用 Row + Text 自绘，语义靠 fontSize/热区保证。
 */
@Component
export struct GlassButton {
  @Prop label: string = '';
  @Prop kind: number = GlassButtonKind.Neutral;
  @Prop btnHeight: number = Metrics.primaryButtonHeight;
  /** Icon 形态下的直径 */
  @Prop diameter: number = Metrics.touchMin;
  @Prop btnEnabled: boolean = true;
  @State pressed: boolean = false;
  onTap: () => void = () => {
  };

  private spec(): GlassSpec {
    const tier: GlassTier = this.kind === GlassButtonKind.Icon ? GlassTier.Thin : GlassTier.Regular;
    return Glass.spec(tier);
  }

  private radius(): number {
    return this.kind === GlassButtonKind.Icon ? this.diameter / 2 : this.btnHeight / 2;
  }

  private tint(): string {
    if (this.kind === GlassButtonKind.Primary) {
      return Glass.accentTint();
    }
    if (this.pressed) {
      return Glass.pressLight();
    }
    return this.spec().tint;
  }

  private fontColor(): Resource {
    if (this.kind === GlassButtonKind.Primary) {
      return $r('app.color.inkOn');
    }
    return $r('app.color.text');
  }

  private widthValue(): Length {
    if (this.kind === GlassButtonKind.Icon) {
      return this.diameter;
    }
    return 'auto';
  }

  build() {
    Row({ space: 6 }) {
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(this.kind === GlassButtonKind.Primary ? Metrics.bodySize : Metrics.smallSize + 1)
          .fontWeight(this.kind === GlassButtonKind.Primary ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.fontColor())
          .maxLines(1)
      }
    }
    .width(this.widthValue())
    .height(this.kind === GlassButtonKind.Icon ? this.diameter : this.btnHeight)
    .padding(this.kind === GlassButtonKind.Icon
      ? { left: 0, right: 0, top: 0, bottom: 0 }
      : { left: 18, right: 18, top: 0, bottom: 0 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.radius())
    .backgroundEffect({
      radius: this.spec().blurRadius,
      saturation: this.spec().saturation,
      brightness: this.pressed ? this.spec().brightness + 0.05 : this.spec().brightness,
      color: this.tint()
    })
    .border({ width: 1, color: this.spec().borderColor })
    .overlay(this.topHighlight(), { align: Alignment.Top, offset: { x: 0, y: 1 } })
    .shadow({
      radius: this.pressed ? this.spec().shadowRadius * 0.5 : this.spec().shadowRadius,
      color: this.spec().shadowColor,
      offsetX: 0,
      offsetY: this.pressed ? 2 : this.spec().shadowOffsetY
    })
    // 按压缩小 + 提亮：一次手势里同时给出「被按进去了」和「指尖有光」两个反馈
    .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
    .opacity(this.btnEnabled ? 1 : 0.45)
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (!this.btnEnabled) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      if (this.btnEnabled) {
        this.onTap();
      }
    })
  }

  @Builder
  topHighlight() {
    Row()
      .width('80%')
      .height(1)
      .borderRadius(0.5)
      .linearGradient({
        angle: 90,
        colors: [
          ['#00FFFFFF', 0.0],
          [this.spec().highlightColor, 0.5],
          ['#00FFFFFF', 1.0]
        ]
      })
  }
}
