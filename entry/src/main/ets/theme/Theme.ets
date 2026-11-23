/**
 * 设计与主题 token。
 *
 * 颜色不在这里：全部走 `$r('app.color.*')`，由 resources/base（日间）与
 * resources/dark（夜览）两份 color.json 提供，系统在深浅色切换时自动生效，
 * 因此颜色相关的代码不需要订阅状态。
 *
 * 尺寸按手机实测换算：屏幕 1260px / 360vp，比例 3.5。
 * 例如实测左右边距 52px → 15vp，卡片内边距 55px → 16vp。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { Prefs } from '../store/Prefs';

export class Metrics {
  /** 页面左右边距（实测 52px） */
  static readonly safeMargin: number = 15;
  /** 顶部标题栏高度：容纳 28vp 大标题 + 44vp 圆形功能钮，对齐系统应用的标题栏规格 */
  static readonly topBarHeight: number = 60;
  /** 吸顶大标题字号（应用市场「探索」页实测规格） */
  static readonly topTitleSize: number = 28;
  /** 标题栏右侧圆形功能钮直径（搜索/更多） */
  static readonly roundBtnSize: number = 44;
  /** 圆形功能钮内箭头/图标字号 */
  static readonly roundBtnGlyph: number = 26;

  /** 横屏 / 投屏时的左侧导航 */
  static readonly navWidth: number = 96;
  static readonly navHeight: number = 56;

  /** 底部浮起胶囊：左右各留 25vp，条高 52vp */
  static readonly floatNavMargin: number = 25;
  static readonly floatNavHeight: number = 52;
  /** 单项高 48 + 上下 padding 2×2 = 52，与 floatNavHeight 对齐 */
  static readonly floatNavItemHeight: number = 48;
  /**
   * 导航图标容器尺寸的唯一来源（底部胶囊与宽屏侧栏共用）。
   * 27vp 是「视觉笔画」而非外框：SVG 图形只占 viewBox 约 68%，
   * 27 × 0.68 ≈ 18.4vp 才是对齐文字标签后的实际观感尺寸。
   * 改这里即可，不要在 NavIcon 里再写死数字。
   */
  static readonly floatNavIcon: number = 27;

  /**
   * 卡片圆角。对齐系统应用（应用市场）的大圆角卡片规范：
   * 卡片 20、海报 16、面板 28，视觉上比早期 12/10/20 更接近官方应用的柔和感。
   */
  static readonly cardRadius: number = 20;
  static readonly posterRadius: number = 16;
  static readonly sheetRadius: number = 28;
  static readonly cardGap: number = 12;
  /** 卡片内边距（实测 55px） */
  static readonly cardPadding: number = 16;
  /** 卡片弥散投影半径：足够大才像「浮起来」，太小就成硬边 */
  static readonly cardShadowRadius: number = 18;
  static readonly cardShadowOffsetY: number = 6;

  /** 三列网格海报宽（实测 345px） */
  static readonly posterWidth: number = 99;
  /** 海报高宽比 1.5，短剧竖版封面 */
  static readonly posterRatio: number = 1.5;

  /** 分段控件 / 集数按钮高度（对齐系统应用的 44vp 触控规格） */
  static readonly chipHeight: number = 44;
  static readonly chipGap: number = 8;
  /** 筛选胶囊圆角：选中态做成应用市场式的实心圆角胶囊 */
  static readonly chipRadius: number = 22;

  static readonly searchHeight: number = 44;
  /** 主按钮高度与圆角：对齐系统应用的全宽主按钮规格 */
  static readonly primaryButtonHeight: number = 56;
  static readonly primaryButtonRadius: number = 28;

  /** 最小可点击热区 */
  static readonly touchMin: number = 44;

  /** 字号 */
  static readonly heroTitle: number = 26;
  static readonly titleSize: number = 19;
  static readonly bodySize: number = 15;
  static readonly smallSize: number = 13;
  static readonly tinySize: number = 11;
  static readonly navLabelSize: number = 10;
  /** 统计数据行的大数字字号（对齐系统应用详情页的「评分/安装量」规格） */
  static readonly statValueSize: number = 22;
  /** 统计数据行的行高与分隔线长度 */
  static readonly statDividerHeight: number = 26;

  /** 播放器视频区占屏幕高度的比例（实测 1632/2720） */
  static readonly videoHeightRatio: number = 0.6;
  static readonly videoAspect: number = 16 / 9;
}

export enum ThemeMode {
  System = 0,
  Light = 1,
  Dark = 2
}

/** 断点档位。手机竖屏 = Sm，平板/分屏 = Md，超级桌面车机宽屏 = Lg/Xl */
export enum Bp {
  Sm = 0,
  Md = 1,
  Lg = 2,
  Xl = 3
}

/**
 * 响应式断点。
 *
 * 一切以「应用窗口宽度」为准，不看设备类型——手机通过超级桌面流转到车机后，
 * 设备仍是手机，但窗口会变成宽屏，布局必须跟着窗口走。
 */
export class Breakpoints {
  /** 手机竖屏上限 */
  static readonly md: number = 600;
  /** 平板 / 分屏 */
  static readonly lg: number = 840;
  /** 车机宽屏 */
  static readonly xl: number = 1280;

  /** 宽屏下正文最大宽度，避免一行字拉到 1500vp 读不动 */
  static readonly readingMax: number = 760;

  static of(width: number): Bp {
    if (width >= Breakpoints.xl) {
      return Bp.Xl;
    }
    if (width >= Breakpoints.lg) {
      return Bp.Lg;
    }
    if (width >= Breakpoints.md) {
      return Bp.Md;
    }
    return Bp.Sm;
  }

  static isWide(width: number): boolean {
    return width >= Breakpoints.md;
  }

  /** 页面左右边距：宽屏放大一些，手机保持 15 */
  static pagePadding(width: number): number {
    if (width >= Breakpoints.xl) {
      return 32;
    }
    if (width >= Breakpoints.lg) {
      return 26;
    }
    if (width >= Breakpoints.md) {
      return 20;
    }
    return Metrics.safeMargin;
  }

  /**
   * 信息流列数。手机固定 3 列，宽屏按「目标卡宽 132vp」铺满，
   * 保证不管窗口多宽，右侧都不会出现一条突兀的空白。
   *
   * carMode（车机虚拟屏）：目标卡宽整体上调到 200/168——
   * 车机屏物理大、观看距离远，132vp 的卡片在实车上就是一排小邮票，
   * 配套的海报、标题、角标全部跟着变大（实车反馈「内容小、看着费劲」）。
   */
  static gridColumns(width: number, carMode: boolean = false): number {
    if (!Breakpoints.isWide(width)) {
      return 3;
    }
    const gap: number = Metrics.cardGap;
    const avail: number = width - Breakpoints.pagePadding(width) * 2;
    let target: number = width >= Breakpoints.xl ? 148 : 132;
    if (carMode) {
      target = width >= Breakpoints.xl ? 200 : 168;
    }
    let columns: number = Math.floor((avail + gap) / (target + gap));
    if (columns < 4) {
      columns = 4;
    }
    if (columns > 12) {
      columns = 12;
    }
    return columns;
  }

  /** 由列数反推卡宽，扣掉 (n-1) 个间距后均分 */
  static cardWidth(width: number, columns: number): number {
    const avail: number = width - Breakpoints.pagePadding(width) * 2;
    const gap: number = Metrics.cardGap;
    const each: number = Math.floor((avail - gap * (columns - 1)) / columns);
    return each > 64 ? each : 64;
  }
}

const KEY_THEME = 'theme_mode';

/**
 * 主题控制。默认日间——手机实测版本默认是浅色，看剧在明亮的室内更舒服，
 * 夜里想压暗可在「我的」里切夜览或跟随系统。
 */
export class ThemeController {
  static mode: ThemeMode = ThemeMode.Light;
  /** 当前是否深色，供需要按代码分支取色的地方使用（如弹幕、视频遮罩） */
  static isDark: boolean = false;
  /** 主题变化回调，由 EntryAbility 注册用于同步状态栏图标明暗 */
  static onThemeChanged: ((dark: boolean) => void) | null = null;

  static init(context: common.Context): void {
    const saved = Prefs.getNumber(KEY_THEME, ThemeMode.Light);
    ThemeController.apply(context, saved as ThemeMode, false);
  }

  static setMode(context: common.Context, mode: ThemeMode): void {
    ThemeController.apply(context, mode, true);
  }

  private static apply(context: common.Context, mode: ThemeMode, persist: boolean): void {
    ThemeController.mode = mode;
    ThemeController.isDark = mode === ThemeMode.Dark;

    let target: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    if (mode === ThemeMode.Dark) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (mode === ThemeMode.System) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }

    try {
      context.getApplicationContext().setColorMode(target);
    } catch (error) {
      // 能力不可用时保持系统当前表现
    }

    if (persist) {
      Prefs.setNumber(KEY_THEME, mode as number);
    }

    if (ThemeController.onThemeChanged !== null) {
      ThemeController.onThemeChanged(ThemeController.isDark);
    }
  }

  static label(mode: ThemeMode): string {
    if (mode === ThemeMode.Light) {
      return '日间';
    }
    if (mode === ThemeMode.Dark) {
      return '夜览';
    }
    return '跟随系统';
  }
}
