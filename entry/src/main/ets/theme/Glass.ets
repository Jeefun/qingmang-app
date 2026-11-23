/**
 * 液态玻璃 / 高级光感材质系统。
 *
 * ── 为什么不用 systemMaterial 做主体 ──
 * 本工程已在 ALN-AL00（7.0.0.111 / API 26 / materialLevel=GENTLE）实测：
 * systemMaterial 按规范挂在 Navigation.title 上、无 "out of scope" 日志，
 * 但材质层没有任何可见渲染（改 materialColor 为半透明红、style 从 ULTRA_THIN
 * 换到 ULTRA_THICK、甚至 Material.empty，三种情况截图完全一致）。
 * 也就是说：**系统材质在当前设备/版本上不产出画面**，不能作为视觉主体。
 *
 * ── 所以主体是这套「手工液态玻璃」──
 * 用 backgroundEffect 的四个可调项做真实折射感：
 *   radius      模糊半径（越大越像厚玻璃）
 *   saturation  饱和度（关键：> 1 才能让背后的内容透色，纯模糊会发灰）
 *   brightness  亮度（1.0 以上微提亮，模拟光穿过玻璃）
 *   color       薄纱染色（必须带 alpha，完全不透明会把模糊全挡住）
 * 再叠三样东西才有「液态」的边界感：
 *   ① 1px 高光描边（顶部亮、底部暗，模拟折射亮边）
 *   ② 顶部内侧高光条（玻璃上沿的那道反光）
 *   ③ 弥散阴影（大半径、低透明度，让玻璃浮起来而不是贴上去）
 *
 * ── 分工 ──
 *   Glass.spec()     取某档位的全部参数（颜色随深浅色自动切）
 *   GlassSurface     玻璃容器（卡片、面板、导航条都能用）
 *   GlassButton      玻璃按钮（主按钮 / 次按钮 / 图标圆钮）
 * 首选用这两个组件，不要再手写 backgroundColor + backgroundBlurStyle。
 */
import { ThemeController } from './Theme';
import { Settings } from '../store/Settings';

/** 玻璃厚度档位。数值越大越厚、越不透明、模糊越强 */
export enum GlassTier {
  /** 超薄：浮在内容上的小控件（图标钮、chip），背景要能透出来 */
  Thin = 0,
  /** 常规：导航条、按钮、卡片 */
  Regular = 1,
  /** 厚：需要压住内容的地方（弹层、面板） */
  Thick = 2
}

/**
 * 一档玻璃的全部参数。
 *
 * 颜色都是带 alpha 的字符串：ArkUI 的 #AARRGGBB 格式（alpha 在前）。
 * 深色模式下的 tint 用低 alpha 黑，浅色模式用低 alpha 白——
 * 反过来做的话，深色模式下玻璃会发白发脏。
 */
export class GlassSpec {
  /** backgroundEffect 模糊半径 */
  blurRadius: number = 24;
  /** 饱和度增益，> 1 让背景颜色透出来 */
  saturation: number = 1.8;
  /** 亮度增益 */
  brightness: number = 1.05;
  /** 薄纱染色（#AARRGGBB） */
  tint: string = '#1AFFFFFF';
  /** 1px 描边色 */
  borderColor: string = '#33FFFFFF';
  /** 顶部内侧高光色 */
  highlightColor: string = '#4DFFFFFF';
  /** 弥散阴影色 */
  shadowColor: string = '#26000000';
  shadowRadius: number = 22;
  shadowOffsetY: number = 8;
  /** 圆角 */
  radius: number = 20;
  /** backgroundEffect 参数缓存：与该 spec 绑定，由 Glass.effect() 填充 */
  effectOptions?: BackgroundEffectOptions;
}

export class Glass {
  /**
   * spec 结果缓存：build 每帧会调几十次 Glass.spec()，
   * 不缓存的话一次渲染就分配 50+ 个 GlassSpec，滚动时是稳定的 GC 压力源。
   * key = 档位+深浅色+降低透明度，主题切换时旧缓存自然失效（key 变了）。
   */
  private static cache: Record<string, GlassSpec> = {};

  /**
   * 取一档玻璃参数。
   *
   * 「降低透明度」开关打开时退化为实色：这条开关的语义就是
   * 「玻璃材质改为实色背景」，此时不只要把 alpha 提到不透明，
   * 连模糊也要一并去掉——半透明实色叠模糊会出现脏边。
   */
  static spec(tier: GlassTier): GlassSpec {
    const dark: boolean = ThemeController.isDark;
    const key = `${tier}_${dark}_${Settings.reduceTransparency}`;
    const cached: GlassSpec = Glass.cache[key];
    if (cached !== undefined) {
      return cached;
    }
    const spec: GlassSpec = new GlassSpec();

    if (tier === GlassTier.Thin) {
      spec.blurRadius = 10;
      spec.saturation = 1.8;
      spec.brightness = 1.05;
      spec.shadowRadius = 8;
      spec.shadowOffsetY = 4;
    } else if (tier === GlassTier.Thick) {
      spec.blurRadius = 24;
      spec.saturation = 2.2;
      spec.brightness = 1.08;
      spec.shadowRadius = 18;
      spec.shadowOffsetY = 10;
    } else {
      // Regular 是最常被看到的一档（导航条、主按钮、卡片）。
      // 模糊半径从 32 降到 16：GPU 开销大约随半径平方增长，
      // 32 在中端机上一屏 10+ 块玻璃必掉帧；16 仍有折射感，帧率稳得多。
      spec.blurRadius = 16;
      spec.saturation = 2.0;
      spec.brightness = 1.06;
      spec.shadowRadius = 12;
      spec.shadowOffsetY = 6;
    }

    if (dark) {
      // 夜览：极淡黑纱 + 白色高光。
      // 这里最容易犯的错是把 tint 写到 0.5 以上——那样模糊层被彻底盖住，
      // 玻璃就退化成一个实色底板，除了圆角什么都没有。
      spec.tint = tier === GlassTier.Thick ? '#8C0A0809' : '#3D14100F';
      spec.borderColor = '#33FFFFFF';
      spec.highlightColor = '#5CFFFFFF';
      spec.shadowColor = '#66000000';
    } else {
      // 日间：**不用纯白**。
      // 纯白玻璃放在暖白背景（#F7F5F2）上等于隐形，这是「看不出玻璃」的主因之一。
      // 改用一点点暖灰做染色，玻璃会成为「比纸略深的一块磨砂」，
      // 背后有海报滚过时再被饱和度增益染上颜色——这才是玻璃该有的观感。
      spec.tint = tier === GlassTier.Thick ? '#C7FFFFFF' : '#4DE4E0DB';
      spec.borderColor = '#66FFFFFF';
      spec.highlightColor = '#8CFFFFFF';
      spec.shadowColor = '#26000000';
    }

    if (Settings.reduceTransparency) {
      spec.blurRadius = 0;
      spec.saturation = 1;
      spec.brightness = 1;
      spec.tint = dark ? '#FF100C0E' : '#FFF7F5F2';
      spec.highlightColor = '#00FFFFFF';
    }
    Glass.cache[key] = spec;
    return spec;
  }

  /**
   * 滚动列表项的静态底色：不用实时模糊，一块半透明实色 + 1px 描边。
   * 信息流 / 历史 / 收藏 / 搜索结果这类「同屏几十条、还要滚动」的区域，
   * 每条都挂 backgroundEffect 会把 GPU 打满，是滚动掉帧的主因；
   * 换静态底后视觉略「实」，但滚动满帧。
   */
  static listTint(): string {
    if (Settings.reduceTransparency) {
      return ThemeController.isDark ? '#FF1A1719' : '#FFFFFFFF';
    }
    return ThemeController.isDark ? '#66191518' : '#B3FFFFFF';
  }

  /** 列表项描边色（与 listTint 配套） */
  static listBorder(): string {
    if (Settings.reduceTransparency) {
      return ThemeController.isDark ? '#33FFFFFF' : '#1F000000';
    }
    return ThemeController.isDark ? '#26FFFFFF' : '#66FFFFFF';
  }

  /** backgroundEffect 的参数对象。结果缓存在 spec 实例上，build 每帧调用不再重复分配 */
  static effect(spec: GlassSpec): BackgroundEffectOptions {
    if (spec.effectOptions === undefined) {
      spec.effectOptions = {
        radius: spec.blurRadius,
        saturation: spec.saturation,
        brightness: spec.brightness,
        color: spec.tint
      };
    }
    return spec.effectOptions;
  }

  /** 按压时的高光色：比常态亮一档，制造「指尖打光」 */
  static pressLight(): string {
    return ThemeController.isDark ? '#33FFFFFF' : '#4DFFFFFF';
  }

  /** 主按钮的强调色玻璃（染色走 accent，仍保留折射） */
  static accentTint(): string {
    return ThemeController.isDark ? '#CC6ECC54' : '#D96ECC54';
  }

  /**
   * 导航选中项的药丸底色。
   *
   * 这里刻意不再叠背景模糊：选中项面积小、背后又是玻璃导航条本身，
   * 二次模糊会让图标变糊。用「半透明白 + 高光边」反而更像一块被照亮的玻璃凸起。
   */
  static selectedPill(): string {
    if (Settings.reduceTransparency) {
      return ThemeController.isDark ? '#33FFFFFF' : '#FFFFFFFF';
    }
    return ThemeController.isDark ? '#26FFFFFF' : '#B3FFFFFF';
  }

  /** 选中项的微光晕，让药丸从导航条上浮起来 */
  static selectedGlow(): string {
    return ThemeController.isDark ? '#33000000' : '#1F000000';
  }
}
