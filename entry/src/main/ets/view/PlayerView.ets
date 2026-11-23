/**
 * 播放页（沉浸式 + 官方弹幕 + 播放设置）。
 *
 * 四条设计红线：
 * 1. 画面绝不拉伸。surface 按视频真实宽高比设尺寸，多余区域由外层黑底承担。
 * 2. 上下分区。上半屏是纯黑视窗，下半屏是「简介 / 选集」双 Tab，互不挤压。
 * 3. 控件即浮层。顶部/底部渐变蒙层压在画面上，3 秒无操作淡出，轻触任意处唤醒。
 * 4. 弹幕只读。只展示内容源自己的弹幕（comment 通道），不做发送。
 *
 * 用 AVPlayer + XComponent Surface 而不是 Video 组件：内容源 CDN 会校验 Referer，
 * 只有 createMediaSourceWithUrl 才能带上请求头，Video 组件不支持自定义头。
 *
 * 内容源的 mp4 是 CENC-AES-CTR 加密的，AVPlayer 不能直接解，所以先下载到本地、
 * 按样本解密并改写加密标记盒，再当普通本地文件播放。解密结果按集缓存，回看不重复下载。
 */
import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { curves, PiPWindow, window } from '@kit.ArkUI';
import { httpRequestBuffer } from '../net/Http';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { DanmakuComment, DramaDetail, Episode, FavoriteItem, HistoryItem, PlaySource } from '../model/Models';
import { AppState } from '../store/AppState';
import { CachedEpisode } from '../store/CacheIndex';
import { Settings } from '../store/Settings';
import { CardSync } from '../store/CardSync';
import { Breakpoints, Metrics, ThemeController } from '../theme/Theme';
import { Glass } from '../theme/Glass';
import { CencResult, contentKeyFromSpade, decryptCencMp4 } from '../net/Cenc';
import { fromHex } from '../net/Md5';

class CacheEntry {
  name: string = '';
  mtime: number = 0;
}

/**
 * 屏幕上正在滚动的一条弹幕。
 * x 是左边缘横坐标（vp），每帧减小；w 是估算宽度，用于轨道占用与出屏判断；
 * spd 是速度系数（按轨道固定），同轨恒速防追尾、异轨异速让弹幕场错落有致。
 */
class DanmakuItem {
  id: number = 0;
  text: string = '';
  x: number = 0;
  lane: number = 0;
  w: number = 0;
  spd: number = 1;
  /** 合并计数：同文本弹幕还在屏上时累加，渲染为「文本 ×N」 */
  repeat: number = 1;
}

/**
 * 单条弹幕必须独立成 @Component，坐标走 @Prop。
 *
 * 真机（Mate 60 Pro / API 26）实测过的坑：DanmakuItem 是普通 class，
 * 若直接写 Text(item.text).position({ x: item.x })，ArkUI 观察不到 item.x 的变化。
 * ForEach 的 key 是稳定的 item.id，复用同一个组件时 position 永远停在首次渲染的
 * 「右边界入场位置」，整条弹幕被父层 .clip(true) 裁掉——
 * 症状是接口有数据、组件树里也有文本（origBounds 宽 293px 正常），
 * 但 bounds 被裁成 1px、屏幕上一条都看不见。
 * 改成 @Prop 后，父组件每帧重赋值 danmakuLive 会把新坐标同步进子组件。
 */
@Component
struct DanmakuText {
  @Prop dmText: string = '';
  @Prop dmX: number = 0;
  @Prop dmY: number = 0;
  @Prop dmFont: number = 15;
  @Prop dmAlpha: number = 1;
  @Prop dmColor: string = '#FFFFFF';

  build() {
    Text(this.dmText)
      .fontSize(this.dmFont)
      .fontColor(this.dmColor)
      .fontWeight(FontWeight.Medium)
      .maxLines(1)
      .opacity(this.dmAlpha)
      // 只留一层柔和投影：真机实测多层深色 textShadow 会把白字衬成黑字
      // （13~18vp 的小字号被四向 85% 黑描边包住，视觉上只剩轮廓）。
      // 单层浅影足以保证亮色画面上的可读性，且弹幕主体保持纯白。
      .textShadow([{ radius: 2, color: '#66000000', offsetX: 0, offsetY: 1 }])
      .position({ x: this.dmX, y: this.dmY })
  }
}

/**
 * 倍速档位。
 * 注意：这些是「真实倍数」，交给 setPlaybackRate，不是 PlaybackSpeed 枚举的下标。
 * PlaybackSpeed 只有 0.75/1.0/1.25/1.75/2.0 五档（下标 0~4），
 * 把倍数当下标传进去会整体错位，而且 2.5 以上根本表达不了。
 */
const SPEED_OPTIONS: number[] = [0.75, 1, 1.5, 1.75, 2, 2.5, 3, 4, 5];

/** 弹幕字号档位（vp） */
const DM_SIZE_OPTIONS: number[] = [13, 15, 18];
/** 定时关闭档位（分钟）：到点暂停播放并释放息屏听剧任务 */
const SLEEP_OPTIONS: number[] = [15, 30, 60, 90, 120];
/** 弹幕显示区域档位：标题 / 占比 */
const DM_AREA_LABELS: string[] = ['顶部', '中部', '全屏'];
const DM_AREA_VALUES: number[] = [0.3, 0.55, 1];

/** 控件淡入淡出时长 */
const FADE_MS: number = 220;
/** 无操作自动收起延时 */
const AUTO_HIDE_MS: number = 3000;
/** 双击判定窗口：两次单击间隔小于该值视为双击 */
const TAP_DOUBLE_MS: number = 280;
/** 双击左右分区快进 / 快退的步长（毫秒） */
const NUDGE_STEP_MS: number = 10000;
/** 选集网格列数 */
const EPISODE_COLUMNS: number = 4;
/** 选集卡片高度与圆角 */
const EPISODE_TILE_H: number = 44;
const EPISODE_TILE_RADIUS: number = 10;
const EPISODE_GAP: number = 9;

/** 弹幕刷新间隔：33ms ≈ 30fps，肉眼看来是连续滚动的最低成本 */
const DM_TICK_MS: number = 33;
/** 一条弹幕从右边缘走到左边缘的时间，越小越快 */
const DM_TRAVEL_MS: number = 8200;
/** 提前量：到点前 60ms 出现，避免「听到台词才看到弹幕」的滞后感 */
const DM_LEAD_MS: number = 60;
/**
 * 同屏弹幕默认上限（密度「标准」档）。实际取 Settings.danmakuDensity：
 * 6=稀疏 / 12=标准 / 20=密集，播放设置面板与「我的」页都可调。
 * 实车（问界座舱）反馈「弹幕成堆出现」：内容源在同一时间点会下发大量
 * 相同/相近弹幕，没有上限时多轨道会同时铺满，视觉上一团糊。
 */
const DM_MAX_ONSCREEN: number = 12;
/** 弹幕密度档位（同屏上限）与文案 */
const DM_DENSITY_VALUES: number[] = [6, 12, 20];
const DM_DENSITY_LABELS: string[] = ['稀疏', '标准', '密集'];
/** 弹幕颜色档位：白 / 黄 / 青 / 粉 / 绿 */
const DM_COLOR_VALUES: string[] = ['#FFFFFF', '#FFE24A', '#4AF0FF', '#FF7AC8', '#6CFF66'];
/** 弹幕滚动速度倍数档位与文案（数值是 DM_TRAVEL_MS 的除数） */
const DM_SPEED_VALUES: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
const DM_SPEED_LABELS: string[] = ['慢速', '稍慢', '标准', '稍快', '快速', '极速'];

/** 弹幕加载状态 */
const DM_IDLE: number = 0;
const DM_LOADING: number = 1;
const DM_OK: number = 2;
const DM_EMPTY: number = 3;
const DM_ERROR: number = 4;

/** 已拉取过的弹幕按 vid 缓存，切集来回不重复请求 */
const DANMAKU_CACHE: Map<string, DanmakuComment[]> = new Map();

/**
 * 以下三个接口是 @Builder 按引用传参的载体，**不能改回多参数形式**。
 *
 * 官方 FAQ（faqs-arkui-1078）：私有 @Builder 多参数 = 按值传递，
 * 参数随状态变化时 UI 不刷新；传「单个对象字面量」才按引用传递、随状态刷新。
 * 实测症状：设置 1.75 倍速后播放生效，但底部「倍速」胶囊仍显示 1.0x——
 * label 是按值快照，this.speed 变了它不变。投屏/小窗胶囊、弹幕开关图标、
 * 上下集置灰、画质 chip 激活态同理，全部改走对象字面量后修复。
 */
interface RoundBtnOpt {
  key: string;
  glyph: string;
  size: number;
  enabled: boolean;
  label: string;
  action: () => void;
}

interface PillOpt {
  key: string;
  label: string;
  active: boolean;
  action: () => void;
}

interface ChipOpt {
  key: string;
  label: string;
  active: boolean;
  action: () => void;
}

/**
 * 播放器图标。
 *
 * 这里用 SVG 资源，而不是 Path().commands()：
 * 同一套 Path 写法在本机上 fill 会被解析成透明（dump 出来 fillColor=#00000000），
 * 图标只剩看不见的轮廓，换成 SVG 后能稳定出图。
 * 颜色直接写在 SVG 里（#F7F2EF），不要再叠 fillColor——见下方 build() 的说明。
 */
@Component
struct PlyIcon {
  @Prop glyph: string = 'play';
  /** 置灰态（上一集/下一集不可用） */
  @Prop dim: boolean = false;
  /** 图标边长（vp）：车机上随按钮一起放大，默认手机规格 24 */
  @Prop glyphSize: number = 24;

  private src(): Resource {
    if (this.glyph === 'pause') {
      return $r('app.media.ic_pause');
    }
    if (this.glyph === 'prev') {
      return $r('app.media.ic_prev');
    }
    if (this.glyph === 'next') {
      return $r('app.media.ic_next');
    }
    if (this.glyph === 'fullscreen') {
      return $r('app.media.ic_expand');
    }
    if (this.glyph === 'exitFull') {
      return $r('app.media.ic_collapse');
    }
    if (this.glyph === 'back') {
      return $r('app.media.ic_back');
    }
    if (this.glyph === 'danmaku') {
      return $r('app.media.ic_danmaku');
    }
    if (this.glyph === 'danmakuOff') {
      return $r('app.media.ic_danmaku_off');
    }
    if (this.glyph === 'settings') {
      return $r('app.media.ic_settings');
    }
    if (this.glyph === 'close') {
      return $r('app.media.ic_close');
    }
    if (this.glyph === 'fav') {
      return $r('app.media.ic_fav');
    }
    if (this.glyph === 'favOn') {
      return $r('app.media.ic_fav_on');
    }
    if (this.glyph === 'ratio') {
      return $r('app.media.ic_ratio');
    }
    if (this.glyph === 'lock') {
      return $r('app.media.ic_lock');
    }
    if (this.glyph === 'unlock') {
      return $r('app.media.ic_unlock');
    }
    return $r('app.media.ic_play');
  }

  build() {
    Image(this.src())
      .width(this.glyphSize)
      .height(this.glyphSize)
      .objectFit(ImageFit.Contain)
      // 不能再用 fillColor：它会把描边型 SVG 的 fill="none" 覆盖成实心，
      // 返回箭头 / 全屏这类描边图标会被填成一块实心楔形。颜色已写进 SVG，
      // 置灰态改用透明度表达。
      .opacity(this.dim ? 0.35 : 1)
  }
}

@Component
export struct PlayerView {
  seriesId: string = '';
  startIndex: number = 1;

  @State title: string = '';
  @State desc: string = '';
  @State tags: string = '';
  @State cover: string = '';
  @State currentIndex: number = 1;
  @State episodeCount: number = 0;

  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State playing: boolean = false;
  @State loading: boolean = true;
  @State message: string = '';
  @State detailText: string = '';

  /** 0=简介 1=选集 */
  @State tab: number = 0;
  /** 控件不透明度：0 完全淡出、1 完全显示，淡入淡出走 animateTo */
  @State controlsOpacity: number = 1;
  @State isFullscreen: boolean = false;
  @State speed: number = Settings.speed;
  /** 0=自动，其余对应 sources 下标 + 1 */
  @State qualityIdx: number = 0;
  @State qualityLabels: string[] = ['自动'];
  @State descExpanded: boolean = false;
  /** 按下的控件标识，用于统一的按压缩放反馈 */
  @State pressKey: string = '';

  /** 设置面板：挂载开关 + 0~1 的滑入进度 */
  @State settingsOpen: boolean = false;
  @State sheetShift: number = 0;
  /**
   * 全屏选集面板：挂载开关 + 0~1 的滑入进度。
   * 车机进播放页即全屏，全屏下没有简介/选集分栏——从历史卡片直接进来的
   * 用户将完全没有选集入口（实车「只能点续播」的直接根因），
   * 用底部滑入面板补上这个入口。
   */
  @State episodesOpen: boolean = false;
  @State epSheetShift: number = 0;
  @State autoNext: boolean = Settings.autoNext;

  /** 弹幕 */
  @State danmakuOn: boolean = Settings.danmaku;
  @State dmSize: number = Settings.danmakuSize;
  @State dmArea: number = Settings.danmakuArea;
  @State dmDensity: number = Settings.danmakuDensity;
  @State dmOpacity: number = Settings.danmakuOpacity;
  @State danmakuLive: DanmakuItem[] = [];
  @State danmakuCount: number = 0;
  @State danmakuStatus: number = DM_IDLE;
  /** 短暂的提示文案（如「本集暂无弹幕」），2.6 秒后自动消失 */
  @State dmHint: string = '';
  /** 弹幕颜色档下标（DM_COLOR_VALUES） */
  @State dmColorIdx: number = Settings.danmakuColor;
  /** 合并重复弹幕 */
  @State dmMerge: boolean = Settings.danmakuMerge;
  /** 弹幕滚动速度倍数 */
  @State dmSpeedMul: number = Settings.danmakuSpeed;
  /**
   * 播放器锁：锁定后忽略轻触/双击/长按/滑动与控件唤起，
   * 仅保留右上角解锁钮，防止口袋误触与躺着看时的手滑。
   */
  @State playerLocked: boolean = false;

  /** 息屏听剧（=后台播放）：锁屏/切后台继续出声，面板内可切 */
  @State bgPlayOn: boolean = Settings.backgroundPlay;
  /** 普通播放的 audioPlayback 长时任务是否在跑（投屏的独立标记是 castTaskRunning） */
  private audioTaskRunning: boolean = false;
  /** 定时关闭剩余秒数；-1 = 未开启 */
  @State sleepRemainSec: number = -1;
  /** 定时关闭当前选中的档位（分钟）；0 = 未选（用于档位芯片高亮） */
  @State sleepPickMin: number = 0;
  /** 定时关闭秒级倒计时；-1 表示未启动 */
  private sleepTimer: number = -1;

  /** 是否已收藏本剧（进入页面时读一次，顶栏心形按钮跟随） */
  @State favored: boolean = false;

  /** 拖动进度条时的临时比例 0~1 */
  @State dragRatio: number = 0;
  @State dragging: boolean = false;
  /** 进度条容器宽度（vp），用于给时间浮标定位 */
  @State sliderW: number = 0;
  /** 控件层整体位移，淡出时轻微下沉，比纯透明度更有质感 */
  @State controlsOffset: number = 0;

  /** 双击分区快进/快退的浮标文案（'+10 秒' / '-10 秒'），空串不显示 */
  @State seekHint: string = '';
  /** 浮标靠左（快退）还是靠右（快进） */
  @State seekHintLeft: boolean = false;
  /** 长按临时 2 倍速进行中 */
  @State boostOn: boolean = false;
  /** 亮度/音量手势进行中：0 无、1 亮度（左半屏）、2 音量（右半屏） */
  @State gestMode: number = 0;
  /** 手势当前值（0~1），驱动指示条与百分比 */
  @State gestPercent: number = 0;
  /** 画面比例：false 自适应（contain）、true 填充（surface 铺满容器，左右拉伸、不裁切，字幕完整） */
  @State fitFill: boolean = false;
  /** 车机默认填充只做一次（首次拿到片源尺寸时）；用户手动切回后不再强推 */
  private fitDefaulted: boolean = false;

  @State viewWidth: number = 0;
  /** 播放页容器实测高度（onAreaChange）：车机圆角浮窗比物理屏小一截，全屏布局必须以它为基准 */
  @State viewHeight: number = 0;
  @State videoW: number = 0;
  @State videoH: number = 0;
  @StorageProp('safeTop') safeTopPx: number = 0;
  @StorageProp('screenHeight') screenHeightVp: number = 780;
  @StorageProp('safeBottom') safeBottomPx: number = 0;
  /**
   * 车机形态（EntryAbility 在流转/迁回时实时维护）。
   * 车机上两件事跟着变：触控目标放大（屏幕物理大、观看距离远，34vp 圆钮
   * 在车里点起来像米粒）；进播放页直接全屏（横屏分栏会把竖屏短剧
   * 压成窗口中央一小条，四周全是黑边——实车复现的问题 2）。
   */
  @StorageProp('carMode') carMode: boolean = false;
  /**
   * 系统返回手势信号（Index.onBackPress 写入）。
   * 播放页的面板/全屏状态都在本组件里，父层拦截返回后用信号转进来，
   * 按顶栏返回钮同一套层级处理：收设置面板 → 退全屏 → 退页。
   */
  @StorageProp('playerBackSignal') @Watch('onSystemBack') backSignal: number = 0;

  private avPlayer: media.AVPlayer | null = null;
  private surfaceId: string = '';
  /** 已经绑给播放器的 surfaceId，用来识别「surface 被换掉」这种意外 */
  private boundSurfaceId: string = '';
  private xController: XComponentController = new XComponentController();
  private episodes: Episode[] = [];
  private sources: PlaySource[] = [];
  private pendingSurface: boolean = false;
  private released: boolean = false;
  private mediaFile: fs.File | null = null;
  private hideTimer: number = -1;
  /** 切清晰度时用于回到原进度 */
  private pendingSeekMs: number = 0;

  /** 当前集的官方弹幕，按时间升序；不直接参与渲染，所以不放 @State */
  private danmakuAll: DanmakuComment[] = [];
  /** 下一条待出场的弹幕下标 */
  private danmakuCursor: number = 0;
  private danmakuTimer: number = -1;
  private danmakuSeq: number = 0;
  /** 弹幕 tick 计数，仅用于低频诊断日志 */
  private dmTickCount: number = 0;
  /** 下一条弹幕的起始轨道（轮询）：让入场位置在轨道间均匀分布，不扎堆顶部 */
  private dmNextLane: number = 0;
  /** 当前集 vid，弹幕开关重新打开时用它补拉 */
  private danmakuVid: string = '';
  /** 请求序号：切集后旧请求回来要丢掉，否则会把上一集的弹幕贴到这一集 */
  private danmakuReqId: number = 0;
  private dmHintTimer: number = -1;
  /**
   * 一次性延时任务也必须登记并在 aboutToDisappear 里清掉。
   * 组件销毁后回调仍会执行：关闭面板的回调要写 @State，
   * 全屏切换的回调会重算弹幕轨道，两者都会碰到已释放的组件状态。
   */
  private sheetCloseTimer: number = -1;
  /** 选集面板的关闭计时器：动画结束后才真正卸载，避免中途点开关闪跳 */
  private epCloseTimer: number = -1;
  private fullscreenTimer: number = -1;
  /** 手动双击检测：上一次单击的时间与横坐标（ClickEvent 没有原生双击） */
  private lastTapMs: number = 0;
  private lastTapX: number = -1;
  /** 延迟确认的单击：280ms 内没有第二击才执行「唤醒/收起控件」 */
  private tapTimer: number = -1;
  /** 双击快进退浮标的自动消失计时 */
  private seekHintTimer: number = -1;
  /** 手势起点值（亮度或音量，0~1） */
  private gestStartValue: number = 0;
  /** 手势指示条自动隐藏计时 */
  private gestHintTimer: number = -1;
  /** 手势调过的窗口亮度缓存；-1 表示没调过，退出时不做恢复 */
  private brightnessVal: number = -1;
  /** 亮度应用节流（毫秒时间戳） */
  private lastBrightApply: number = 0;
  /** 主窗口缓存：手势期间避免每帧 getLastWindow */
  private mainWindow: window.Window | null = null;
  /** 播放器音量（0~1），右半屏手势调节；换集后在 prepared 状态重放 */
  private playerVolume: number = 1;
  /** 观看时长统计：每 5 秒记一次，满 30 秒落一次盘 */
  private statsTimer: number = -1;
  private statsTicks: number = 0;

  // ---------------- 预缓存 / 小窗 / 投屏 ----------------

  /** 预缓存下一集的防重入标记 */
  private prefetchBusy: boolean = false;

  /** 画中画控制器（XComponent 模式：复用本页 surface，不重建播放器） */
  private pipController: PiPWindow.PiPController | null = null;
  private pipBusy: boolean = false;
  @State pipActive: boolean = false;

  /** 媒体会话与投屏 */
  private avSessionObj: avSession.AVSession | null = null;
  private castPickerHelper: avSession.AVCastPickerHelper | null = null;
  private castController: avSession.AVCastController | null = null;
  /** 投播期间保持打开的本地缓存文件句柄（fdSrc 引用它） */
  private castFile: fs.File | null = null;
  private castBusy: boolean = false;
  private castTaskRunning: boolean = false;
  @State casting: boolean = false;

  onBack: () => void = () => {
  };

  aboutToAppear(): void {
    // 播放页激活期间状态栏图标强制白色（压在深色视频上），退出时恢复主题色。
    // EntryAbility.applySystemBar 读同一个标记，主题变化重刷系统栏时也保持一致。
    AppStorage.setOrCreate('playerActive', true);
    this.applyPlayerBar('#FFFFFF');
    // 车机上直接进全屏沉浸：竖屏短剧在横屏窗口里走分栏只会被右侧面板 +
    // 上下留白三层挤压，实车表现为「播放内容区域四周大黑边」。
    // 手机（carMode=false）保持原半屏形态，行为零变化。
    if (this.carMode) {
      this.isFullscreen = true;
      // 车机沉浸：隐藏系统状态栏与 Dock，不再压在画面上下两端（实车问题 2）
      this.applyCarImmersive(true);
      // 车机窗口常晚于播放页挂载才定型（流转/maximize 异步完成），
      // 沉浸式 API 只在「全屏/最大化主窗口」状态生效——晚一拍再补一次，
      // 避免首次调用撞上窗口尚未就绪而静默失效
      setTimeout(() => {
        if (!this.released && this.isFullscreen) {
          this.applyCarImmersive(true);
        }
      }, 1200);
    }
    this.load();
    // 观看时长统计：只在真正出画面（playing）时累计，后台暂停不计
    this.statsTimer = setInterval(() => {
      if (this.playing) {
        AppState.watchStats.addSeconds(5);
        this.statsTicks++;
      }
      if (this.statsTicks >= 6) {
        this.statsTicks = 0;
        AppState.watchStats.flush();
      }
    }, 5000);
  }

  aboutToDisappear(): void {
    AppStorage.setOrCreate('playerActive', false);
    this.applyPlayerBar(ThemeController.isDark ? '#FFFFFF' : '#241A16');
    // 车机退出播放页：恢复系统栏（进入时隐藏过才需要恢复，非车机为空操作）
    this.applyCarImmersive(false);
    this.saveProgress();
    this.clearHideTimer();
    this.stopDanmakuTicker();
    if (this.dmHintTimer !== -1) {
      clearTimeout(this.dmHintTimer);
      this.dmHintTimer = -1;
    }
    if (this.sheetCloseTimer !== -1) {
      clearTimeout(this.sheetCloseTimer);
      this.sheetCloseTimer = -1;
    }
    if (this.epCloseTimer !== -1) {
      clearTimeout(this.epCloseTimer);
      this.epCloseTimer = -1;
    }
    if (this.fullscreenTimer !== -1) {
      clearTimeout(this.fullscreenTimer);
      this.fullscreenTimer = -1;
    }
    if (this.tapTimer !== -1) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
    if (this.seekHintTimer !== -1) {
      clearTimeout(this.seekHintTimer);
      this.seekHintTimer = -1;
    }
    if (this.gestHintTimer !== -1) {
      clearTimeout(this.gestHintTimer);
      this.gestHintTimer = -1;
    }
    if (this.statsTimer !== -1) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
    if (this.sleepTimer !== -1) {
      clearInterval(this.sleepTimer);
      this.sleepTimer = -1;
    }
    AppState.watchStats.flush();
    this.restoreBrightness();
    // 息屏听剧长时任务随播放页释放（后台继续听需要留在播放页）
    this.stopAudioTask();
    this.stopPip();
    this.releaseAvSession();
    this.releasePlayer();
  }

  /** 直接改主窗口系统栏图标颜色（进播放页强制白色 / 退出恢复主题色） */
  private async applyPlayerBar(contentColor: string): Promise<void> {
    try {
      const host = this.getUIContext().getHostContext();
      if (host === undefined) {
        return;
      }
      const win = await window.getLastWindow(host);
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
    } catch (error) {
      // 流转中窗口可能暂时不可用，等 EntryAbility.applySystemBar 下次刷新兜底
    }
  }

  /**
   * 车机沉浸锁定（对齐华为视频实车形态：播放时上下系统栏隐藏、画面铺满全屏）。
   * 双保险：setWindowSystemBarEnable 定可见模式 + setSpecificSystemBarEnabled 逐条设置
   * —— 官方 FAQ（应用未显示系统导航栏）指出部分机型前者的 navigation 参数无效，
   * 需用后者逐条隐藏。两个 API 都只在「全屏/最大化主窗口」下生效，
   * EntryAbility 的 maximize(ENTER_IMMERSIVE_...) 兜底负责把窗口送进这个状态。
   * 仅车机生效；手机全屏保持「系统栏叠加」原形态，行为零变化。
   */
  private async applyCarImmersive(hide: boolean): Promise<void> {
    if (!this.carMode) {
      return;
    }
    try {
      const host = this.getUIContext().getHostContext();
      if (host === undefined) {
        return;
      }
      const win = await window.getLastWindow(host);
      // 关键前置：隐藏系统栏的两个 API 只在「全屏/最大化主窗口」下生效
      //（SDK 文档原文：does not take effect in non-full-screen mode, such as floating window）。
      // 红果/华为视频在车机上能铺满全屏，走的就是这条路——它们播放时窗口是最大化主窗口。
      // 流转窗口初始可能是悬浮态，EntryAbility 启动时的 maximize 若未生效，
      // 这里不补一下的话，后面的隐藏调用会全部静默失效（实车照片里
      // 状态栏 08:04 / 底部空调栏压在画面上的直接原因）。
      if (hide) {
        try {
          await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
          hilog.info(0x0001, 'QingMangCar', '[VERIFY] immersive: maximize(ENTER_IMMERSIVE) 成功');
        } catch (maxError) {
          const maxErr = maxError as BusinessError;
          hilog.warn(0x0001, 'QingMangCar',
            `[VERIFY] immersive: maximize 不可用 code=${maxErr.code}（可能已是全屏，继续隐藏系统栏）`);
        }
      }
      await win.setWindowSystemBarEnable(hide ? [] : ['status', 'navigation']);
      // 逐条补一遍：部分机型只有 setSpecificSystemBarEnabled 才藏得住底部导航/Dock
      try {
        await win.setSpecificSystemBarEnabled('status', !hide);
        await win.setSpecificSystemBarEnabled('navigation', !hide);
        await win.setSpecificSystemBarEnabled('navigationIndicator', !hide);
      } catch (specificError) {
        const specificErr = specificError as BusinessError;
        hilog.warn(0x0001, 'QingMangCar',
          `[VERIFY] immersive: setSpecificSystemBarEnabled 不可用 code=${specificErr.code}`);
      }
      // [VERIFY] 实车排查：生效后避让区应缩为 0；若仍大于 0，
      // 说明窗口没进全屏主窗口（API 文档：非全屏/悬浮窗态下设置不生效）
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      hilog.info(0x0001, 'QingMangCar',
        `[VERIFY] immersive: hide=${hide} sysTop=${sys.topRect.height} navBottom=${nav.bottomRect.height}`);
    } catch (error) {
      // 流转中窗口可能暂时不可用；退出路径（aboutToDisappear）失败时
      // 由 EntryAbility 下次 applySystemBar 的系统默认形态兜底
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangCar', `[VERIFY] immersive: 失败 code=${err.code} msg=${err.message}`);
    }
  }

  // ---------------- 控件显隐 ----------------

  private controlsShown(): boolean {
    return this.controlsOpacity > 0.01;
  }

  private clearHideTimer(): void {
    if (this.hideTimer !== -1) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private fadeControls(show: boolean): void {
    // 淡出时整层轻微下沉 6vp，回来时归位：比单纯改透明度更「有重量」，
    // 也不会像 scale 那样让文字发虚。
    const curve = Settings.reduceMotion ? Curve.Linear : curves.cubicBezierCurve(0.4, 0, 0.2, 1);
    const duration = Settings.reduceMotion ? 1 : FADE_MS;
    animateTo({ duration: duration, curve: curve }, () => {
      this.controlsOpacity = show ? 1 : 0;
      this.controlsOffset = show ? 0 : 6;
    });
  }

  private showControls(): void {
    this.fadeControls(true);
  }

  private hideControls(): void {
    this.settingsOpen = false;
    this.sheetShift = 0;
    this.fadeControls(false);
  }

  /** 播放中 3 秒无操作自动收起；暂停、拖拽、设置展开时保持常驻 */
  private scheduleHide(): void {
    this.clearHideTimer();
    if (!this.playing || this.dragging || this.settingsOpen) {
      return;
    }
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (this.playing && !this.dragging && !this.settingsOpen) {
        this.hideControls();
      }
    }, AUTO_HIDE_MS);
  }

  /** 任意一次交互都刷新倒计时 */
  private touchControls(): void {
    if (this.playerLocked) {
      return;
    }
    this.showControls();
    this.scheduleHide();
  }

  private onVideoTap(): void {
    if (this.playerLocked) {
      return;
    }
    if (this.settingsOpen) {
      this.closeSettings();
      return;
    }
    if (this.episodesOpen) {
      this.closeEpisodes();
      return;
    }
    if (this.controlsShown()) {
      this.clearHideTimer();
      this.hideControls();
    } else {
      this.touchControls();
    }
  }

  // ---------------- 视频区手势：双击快进退 / 长按倍速 ----------------

  private clearTapTimer(): void {
    if (this.tapTimer !== -1) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  /** 双击快进/快退后短暂出现的浮标，650ms 后自动消失 */
  private showSeekHint(text: string, left: boolean): void {
    this.seekHint = text;
    this.seekHintLeft = left;
    if (this.seekHintTimer !== -1) {
      clearTimeout(this.seekHintTimer);
    }
    this.seekHintTimer = setTimeout(() => {
      this.seekHintTimer = -1;
      this.seekHint = '';
    }, 650);
  }

  /** 双击左右分区：±10 秒 */
  private nudgeSeek(deltaMs: number, left: boolean): void {
    if (this.durationMs <= 0) {
      return;
    }
    let target = this.positionMs + deltaMs;
    if (target < 0) {
      target = 0;
    }
    if (target > this.durationMs) {
      target = this.durationMs;
    }
    this.remoteSeek(target);
    this.showSeekHint(deltaMs > 0 ? '+10 秒' : '-10 秒', left);
    this.touchControls();
  }

  /**
   * 视频区点击：手动双击检测。
   * ClickEvent 没有原生双击，系统多击回调在控件显隐场景下又容易闪烁，
   * 这里用「延迟确认」：280ms 内来了第二击按双击处理（左 35% 快退 / 右 65% 快进 /
   * 中央播放暂停），否则才执行单击的「唤醒/收起控件」。
   */
  private onVideoClick(event: ClickEvent): void {
    if (this.playerLocked) {
      return;
    }
    if (this.settingsOpen) {
      this.closeSettings();
      return;
    }
    if (this.episodesOpen) {
      this.closeEpisodes();
      return;
    }
    const now: number = Date.now();
    const isDouble: boolean = this.lastTapMs > 0
      && now - this.lastTapMs < TAP_DOUBLE_MS
      && Math.abs(event.x - this.lastTapX) < 64;
    if (isDouble) {
      this.clearTapTimer();
      this.lastTapMs = 0;
      const width: number = this.boxAreaWidth();
      if (width > 0 && event.x < width * 0.35) {
        this.nudgeSeek(-NUDGE_STEP_MS, true);
      } else if (width > 0 && event.x > width * 0.65) {
        this.nudgeSeek(NUDGE_STEP_MS, false);
      } else {
        this.togglePlay();
      }
      return;
    }
    this.lastTapMs = now;
    this.lastTapX = event.x;
    this.clearTapTimer();
    this.tapTimer = setTimeout(() => {
      this.tapTimer = -1;
      if (!this.released) {
        this.onVideoTap();
      }
    }, TAP_DOUBLE_MS);
  }

  /** 长按期间临时 2 倍速；投屏中本地播放器只是备源，不参与 */
  private beginBoost(): void {
    if (this.playerLocked) {
      return;
    }
    const player = this.avPlayer;
    if (player === null || this.casting || this.boostOn || !this.playing) {
      return;
    }
    try {
      player.setPlaybackRate(2);
      this.boostOn = true;
    } catch (error) {
      // 长按倍速失败不打断播放
    }
  }

  /** 松手恢复用户设定的倍速 */
  private endBoost(): void {
    if (!this.boostOn) {
      return;
    }
    this.boostOn = false;
    const player = this.avPlayer;
    if (player !== null) {
      this.applySpeed(player);
    }
  }

  // ---------------- 设置面板 ----------------

  private openSettings(): void {
    this.clearHideTimer();
    this.showControls();
    this.settingsOpen = true;
    // 先挂载再动画：直接在同一个 tick 里从 0 到 1 会拿到终值，看不到滑入
    animateTo({
      duration: Settings.reduceMotion ? 1 : 280,
      curve: curves.cubicBezierCurve(0.22, 1, 0.36, 1)
    }, () => {
      this.sheetShift = 1;
    });
  }

  private closeSettings(): void {
    animateTo({ duration: Settings.reduceMotion ? 1 : 180, curve: Curve.EaseIn }, () => {
      this.sheetShift = 0;
    });
    if (this.sheetCloseTimer !== -1) {
      clearTimeout(this.sheetCloseTimer);
    }
    this.sheetCloseTimer = setTimeout(() => {
      this.sheetCloseTimer = -1;
      if (this.sheetShift < 0.01) {
        this.settingsOpen = false;
      }
    }, 190);
    this.touchControls();
  }

  // ---------------- 全屏选集面板 ----------------

  private openEpisodes(): void {
    this.clearHideTimer();
    this.showControls();
    this.episodesOpen = true;
    animateTo({
      duration: Settings.reduceMotion ? 1 : 280,
      curve: curves.cubicBezierCurve(0.22, 1, 0.36, 1)
    }, () => {
      this.epSheetShift = 1;
    });
  }

  private closeEpisodes(): void {
    animateTo({ duration: Settings.reduceMotion ? 1 : 180, curve: Curve.EaseIn }, () => {
      this.epSheetShift = 0;
    });
    if (this.epCloseTimer !== -1) {
      clearTimeout(this.epCloseTimer);
    }
    this.epCloseTimer = setTimeout(() => {
      this.epCloseTimer = -1;
      if (this.epSheetShift < 0.01) {
        this.episodesOpen = false;
      }
    }, 190);
    this.touchControls();
  }

  private pressOn(key: string): void {
    this.pressKey = key;
  }

  private pressOff(): void {
    this.pressKey = '';
  }

  private isDown(key: string): boolean {
    return this.pressKey === key;
  }

  // ---------------- 数据加载 ----------------

  private async load(): Promise<void> {
    this.loading = true;
    this.message = '';
    try {
      await AppState.ensureReady();
      const detail: DramaDetail = await AppState.api.detail(this.seriesId);
      this.episodes = detail.episodes;
      this.title = detail.drama.displayTitle;
      this.cover = detail.drama.cover;
      this.desc = detail.drama.description;
      this.tags = detail.drama.tags;
      this.episodeCount = detail.episodes.length;

      // 接着上次看的位置
      const history = AppState.history.find(this.seriesId);
      this.favored = AppState.favorites.has(this.seriesId);
      let target = this.startIndex;
      if (target < 1 || target > this.episodeCount) {
        target = 1;
      }
      let resume = 0;
      if (history !== null && history.episodeIndex === target && history.positionMs > 3000) {
        resume = history.positionMs;
      }
      this.currentIndex = target;
      await this.playEpisode(target, resume);
    } catch (error) {
      this.message = '播放失败';
      this.detailText = (error as Error).message;
      this.loading = false;
    }
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

  private async playEpisode(index: number, resumeMs: number = 0): Promise<void> {
    if (index < 1 || index > this.episodes.length) {
      return;
    }
    this.loading = true;
    this.message = '';
    this.detailText = '';
    this.positionMs = resumeMs;
    this.durationMs = 0;
    this.currentIndex = index;
    this.pendingSeekMs = resumeMs;
    // 换集时画面比例会变，先清空旧值，等 videoSizeChange 回报再撑开容器
    this.videoW = 0;
    this.videoH = 0;

    const episode = this.episodes[index - 1];
    // 弹幕跟集走：先清屏再拉新集，避免上一集的弹幕继续飘
    this.loadDanmaku(episode.vid, 0);

    let variants: PlaySource[];
    try {
      variants = await AppState.api.playbackVariants(this.seriesId, episode.vid);
    } catch (error) {
      this.loading = false;
      this.message = '取播放地址失败';
      this.detailText = (error as Error).message;
      return;
    }

    this.sources = variants;
    this.refreshQualityLabels();
    // 新会话进入时 qualityIdx 还是 0（自动）：按用户上次选过的画质匹配一遍，
    // 匹配不上（该集没有这一档）就保持自动。切集时 qualityIdx 已非 0，不会重复匹配。
    if (this.qualityIdx === 0 && Settings.quality !== 'auto') {
      const wanted: string = Settings.quality;
      for (let i = 0; i < variants.length; i++) {
        if (`${variants[i].quality}` === wanted) {
          this.qualityIdx = i + 1;
          break;
        }
      }
    }
    if (this.qualityIdx > variants.length) {
      this.qualityIdx = 0;
    }

    let source: PlaySource;
    if (this.qualityIdx === 0) {
      const clear = variants.find((it: PlaySource) => !it.encrypted);
      source = clear !== undefined ? clear : variants[0];
    } else {
      source = variants[this.qualityIdx - 1];
    }

    if (source.keyHex.length > 0) {
      await this.playEncrypted(source, episode);
      return;
    }
    await this.preparePlayer(source);
  }

  private refreshQualityLabels(): void {
    // 短剧多数只有一个档位，这种情况直接显示实际分辨率，比"自动"更有信息量
    if (this.sources.length === 1) {
      this.qualityLabels = [PlayerView.qualityLabel(this.sources[0].quality)];
      return;
    }
    const labels: string[] = ['自动'];
    for (const item of this.sources) {
      labels.push(PlayerView.qualityLabel(item.quality));
    }
    this.qualityLabels = labels;
  }

  /**
   * 还原 CENC 密钥：
   *   - 32 位 hex（站源模块直接下发 cencKey）→ fromHex 直转字节；
   *   - 其余（内置源的 'cenc' 加密标记）→ 按 spade_a 还原。
   */
  private static cencKeyOf(source: PlaySource): Uint8Array | null {
    if (/^[0-9a-fA-F]{32}$/.test(source.keyHex)) {
      return fromHex(source.keyHex.toLowerCase());
    }
    return contentKeyFromSpade(source.spadeA);
  }

  private static qualityLabel(q: number): string {
    if (q >= 2160) {
      return '4K';
    }
    if (q >= 1080) {
      return '1080P';
    }
    if (q >= 720) {
      return '720P';
    }
    if (q >= 540) {
      return '540P';
    }
    if (q >= 480) {
      return '480P';
    }
    if (q >= 360) {
      return '360P';
    }
    // 接口偶尔返回 1/2/3 这种档位序号
    const names: string[] = ['', '标清', '高清', '超清', '蓝光'];
    if (q >= 1 && q <= 4) {
      return names[q];
    }
    return '默认';
  }

  private async switchQuality(idx: number): Promise<void> {
    if (idx === this.qualityIdx) {
      return;
    }
    this.qualityIdx = idx;
    Settings.quality = idx === 0 ? 'auto' : `${this.sources[idx - 1].quality}`;
    Settings.save();
    const resume = this.positionMs;
    await this.playEpisode(this.currentIndex, resume);
    this.touchControls();
  }

  /**
   * 加密集：下载 → 解密 → 落盘 → 本地播放。
   * 解密结果按 vid 缓存，同一集回看不再下载。
   */
  private async playEncrypted(source: PlaySource, episode: Episode): Promise<void> {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      this.loading = false;
      this.message = '本集无法播放';
      this.detailText = '拿不到应用上下文';
      return;
    }
    const ctx = host as common.UIAbilityContext;
    // 缓存文件名带上清晰度，切清晰度时不会误用另一档的解密结果
    const path = `${ctx.cacheDir}/ep_${episode.vid}_${source.quality}.mp4`;
    let cached = false;
    try {
      cached = fs.statSync(path).size > 1024;
    } catch (error) {
      cached = false;
    }

    if (!cached) {
      this.message = '正在准备本集';
      this.detailText = '首次播放需下载并解密，约 8 MB';
      try {
        const headers: Record<string, string> = {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
          'Referer': source.referer.length > 0 ? source.referer : 'https://novel.snssdk.com/'
        };
        const response = await httpRequestBuffer(source.url, headers, 90000);
        if (response.statusCode < 200 || response.statusCode >= 300 || response.data.byteLength === 0) {
          throw new Error(`下载失败（HTTP ${response.statusCode}）`);
        }
        this.detailText = '正在解密…';
        const key = PlayerView.cencKeyOf(source);
        if (key === null) {
          throw new Error('密钥解析失败，该集加密参数不完整');
        }
        const outcome: CencResult = decryptCencMp4(response.data, key);
        if (outcome.encrypted && outcome.samples === 0) {
          throw new Error('解密失败：未解出任何样本');
        }
        const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, response.data);
        } finally {
          fs.closeSync(file);
        }
        this.recordCachedEpisode(episode, source);
        this.pruneCache(ctx.cacheDir, Settings.cacheKeep);
      } catch (error) {
        this.loading = false;
        this.message = '本集无法播放';
        this.detailText = (error as Error).message;
        return;
      }
    }

    await this.prepareLocalPlayer(path);
  }

  /** 每集解密后约 4~8 MB，只保留最近几集（上限用户可在「我的 → 存储」调），避免把缓存撑到几百 MB */
  private pruneCache(directory: string, keep: number): void {
    try {
      const entries: CacheEntry[] = [];
      for (const name of fs.listFileSync(directory)) {
        if (!name.startsWith('ep_') || !name.endsWith('.mp4')) {
          continue;
        }
        const entry = new CacheEntry();
        entry.name = name;
        entry.mtime = fs.statSync(`${directory}/${name}`).mtime;
        entries.push(entry);
      }
      if (entries.length > keep) {
        entries.sort((left: CacheEntry, right: CacheEntry) => left.mtime - right.mtime);
        for (let i = 0; i < entries.length - keep; i++) {
          fs.unlinkSync(`${directory}/${entries[i].name}`);
        }
      }
      this.reconcileCacheIndex(directory);
    } catch (error) {
      // 清理失败不影响播放
    }
  }

  /** 落盘成功后写一条台账：「我的 → 存储」据此列出可管理的缓存 */
  private recordCachedEpisode(episode: Episode, source: PlaySource): void {
    const entry = new CachedEpisode();
    entry.vid = episode.vid;
    entry.quality = source.quality;
    entry.seriesId = this.seriesId;
    entry.title = this.title;
    entry.episodeIndex = episode.index;
    AppState.cacheIndex.record(entry);
  }

  /** 台账里指向已不存在文件的条目清掉，避免存储页列出点不动的空记录 */
  private reconcileCacheIndex(directory: string): void {
    const stale: CachedEpisode[] = [];
    for (const entry of AppState.cacheIndex.list()) {
      try {
        fs.statSync(`${directory}/${entry.fileName}`);
      } catch (error) {
        stale.push(entry);
      }
    }
    for (const entry of stale) {
      AppState.cacheIndex.remove(entry.vid, entry.quality);
    }
  }

  // ---------------- 官方弹幕 ----------------

  /**
   * 拉取本集官方弹幕。
   *
   * 时长在起播前还拿不到（durationUpdate 要等 prepared 之后），这里传 0：
   * 实测接口在 `playlet_item_duration=0` 时仍会按 start=0 把整个窗口给全，
   * 短剧单集一两分钟，一次请求就够；后续 durationUpdate 到了也不重复请求。
   */
  private async loadDanmaku(vid: string, durationMs: number): Promise<void> {
    if (vid.length === 0) {
      return;
    }
    this.danmakuVid = vid;
    this.danmakuReqId++;
    const reqId = this.danmakuReqId;
    this.danmakuAll = [];
    this.danmakuLive = [];
    this.danmakuCursor = 0;
    this.danmakuCount = 0;
    this.stopDanmakuTicker();

    const cached = DANMAKU_CACHE.get(vid);
    if (cached !== undefined) {
      this.applyDanmaku(reqId, cached);
      return;
    }
    if (!this.danmakuOn) {
      this.danmakuStatus = DM_IDLE;
      return;
    }

    this.danmakuStatus = DM_LOADING;
    try {
      const list = await AppState.api.danmaku(this.seriesId, vid, durationMs);
      if (reqId !== this.danmakuReqId) {
        return;
      }
      // 空结果同样缓存：内容源不少冷门剧整集一条弹幕都没有，
      // 不缓存的话每次开关弹幕都会再打一次接口，白等几百毫秒还多一次请求
      if (DANMAKU_CACHE.size >= 16) {
        DANMAKU_CACHE.clear();
      }
      DANMAKU_CACHE.set(vid, list);
      this.applyDanmaku(reqId, list);
    } catch (error) {
      if (reqId !== this.danmakuReqId) {
        return;
      }
      this.danmakuStatus = DM_ERROR;
    }
  }

  private applyDanmaku(reqId: number, list: DanmakuComment[]): void {
    if (reqId !== this.danmakuReqId) {
      return;
    }
    // 屏蔽词过滤：只影响本机显示（弹幕只读红线不动数据源），
    // 在进工作集前剔除，密度上限/去重/轨道逻辑无需感知屏蔽词
    const filtered: DanmakuComment[] = [];
    for (const comment of list) {
      if (!Settings.isDanmakuBlocked(comment.text)) {
        filtered.push(comment);
      }
    }
    this.danmakuAll = filtered;
    this.danmakuCount = filtered.length;
    this.danmakuStatus = filtered.length > 0 ? DM_OK : DM_EMPTY;
    // 内容源的弹幕密度本身很低（冷门剧集整集为 0），空结果给一句说明，
    // 否则用户只会看到「开了弹幕却什么都没出现」，误以为功能坏了
    if (filtered.length === 0 && this.danmakuOn) {
      this.showDanmakuHint(list.length > 0 ? '本集弹幕都被屏蔽词滤掉了' : '本集暂无弹幕');
    } else if (filtered.length > 0 && this.danmakuOn) {
      this.showDanmakuHint(`本集 ${filtered.length} 条弹幕`);
    }
    this.resetDanmaku(this.positionMs);
  }

  private showDanmakuHint(text: string): void {
    this.dmHint = text;
    if (this.dmHintTimer !== -1) {
      clearTimeout(this.dmHintTimer);
    }
    this.dmHintTimer = setTimeout(() => {
      this.dmHintTimer = -1;
      this.dmHint = '';
    }, 2600);
  }

  private retryDanmaku(): void {
    if (this.danmakuVid.length === 0) {
      return;
    }
    // 手动重试要绕过缓存，否则拿到的是上次那份空结果，点了跟没点一样
    DANMAKU_CACHE.delete(this.danmakuVid);
    this.danmakuStatus = DM_IDLE;
    this.loadDanmaku(this.danmakuVid, this.durationMs);
  }

  /** 二分找到第一条「时间 >= 当前进度」的弹幕，拖动后从这里继续 */
  private indexOfTime(ms: number): number {
    let lo = 0;
    let hi = this.danmakuAll.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.danmakuAll[mid].offsetMs < ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /** 进度跳变（拖动/切集/全屏切换）后重新对齐时间轴 */
  private resetDanmaku(positionMs: number): void {
    this.stopDanmakuTicker();
    this.danmakuLive = [];
    this.danmakuCursor = this.indexOfTime(positionMs);
    // 轨道轮询起点也复位：新时间轴从头分布，避免继承上半场的扫描位置
    this.dmNextLane = 0;
    if (this.danmakuOn && this.danmakuAll.length > 0 && this.playing) {
      this.startDanmakuTicker();
    }
  }

  private startDanmakuTicker(): void {
    if (this.danmakuTimer !== -1) {
      return;
    }
    this.danmakuTimer = setInterval(() => {
      this.tickDanmaku();
    }, DM_TICK_MS);
  }

  private stopDanmakuTicker(): void {
    if (this.danmakuTimer !== -1) {
      clearInterval(this.danmakuTimer);
      this.danmakuTimer = -1;
    }
  }

  /** 每帧：整体左移 + 到点的弹幕入场 + 出屏的移除 */
  private tickDanmaku(): void {
    if (!this.danmakuOn) {
      if (this.danmakuLive.length > 0) {
        this.danmakuLive = [];
      }
      return;
    }
    const areaW: number = this.dmAreaWidth();
    // 滚动速度倍数：travel 缩短 = 走得快；倍数越大越快
    const travelMs: number = DM_TRAVEL_MS / (this.dmSpeedMul > 0 ? this.dmSpeedMul : 1);
    const baseStep: number = areaW / travelMs * DM_TICK_MS;
    const live: DanmakuItem[] = [];
    for (const item of this.danmakuLive) {
      // 每帧生成新对象而不是原地改 item.x：ForEach 对「同一对象引用 + 同一 key」
      // 会跳过 itemGenerator，子组件的 @Prop 就收不到新坐标，弹幕会永远停在
      // 入场位置被 clip 掉。换成新引用，itemGenerator 才会重新求值。
      const moved: DanmakuItem = new DanmakuItem();
      moved.id = item.id;
      moved.text = item.text;
      moved.lane = item.lane;
      moved.w = item.w;
      moved.spd = item.spd;
      moved.repeat = item.repeat;
      moved.x = item.x - baseStep * item.spd;
      if (moved.x + moved.w > 0) {
        live.push(moved);
      }
    }
    this.spawnDue(live, areaW);
    this.danmakuLive = live;
    // 低频诊断：真机上 grep '[DM]' 就能确认 ticker 是否在跑、坐标有没有推进。
    // 每 60 帧（约 2 秒）一条，不会刷屏。
    this.dmTickCount++;
    if (this.dmTickCount % 60 === 0) {
      const first: string = live.length > 0 ? live[0].x.toFixed(1) : '-';
      hilog.info(0x0001, 'QingMangDanmaku',
        `[DM] n=${live.length} areaW=${areaW.toFixed(1)} step=${baseStep.toFixed(2)} ` +
        `x0=${first} playing=${this.playing}`);
    }
  }

  private spawnDue(live: DanmakuItem[], areaW: number): void {
    if (this.danmakuAll.length === 0) {
      return;
    }
    const now: number = this.positionMs;
    const lanes: number = this.laneCount();
    // 单帧入场上限 3：原值 6 会把「同一时间戳的一撮弹幕」一帧全部糊上屏，
    // 是实车「弹幕成堆」的放大器；配合同屏上限与同文本去重三重限流。
    let guard = 0;
    while (this.danmakuCursor < this.danmakuAll.length && guard < 3) {
      const next: DanmakuComment = this.danmakuAll[this.danmakuCursor];
      if (next.offsetMs > now + DM_LEAD_MS) {
        break;
      }
      this.danmakuCursor++;
      guard++;
      // 落后超过 3 秒说明这一条的时间点已经过去了（多半是刚从后台回来或拖动过），
      // 直接跳过，不要一次性把积压的十几条全糊到屏幕上
      if (now - next.offsetMs > 3000) {
        continue;
      }
      // 同文本处理：内容源常见「同一句话被不同用户刷十几条」。
      // 开合并：并入还在屏上的那一条并累加 ×N 计数，刷屏变可见的共鸣；
      // 关合并：同条还在屏上时不放第二条（弹幕走完约 8 秒，即天然 8 秒去重窗）。
      let dupIdx = -1;
      for (let i = 0; i < live.length; i++) {
        if (live[i].text === next.text) {
          dupIdx = i;
          break;
        }
      }
      if (dupIdx >= 0) {
        if (this.dmMerge) {
          // live 里的对象都是本帧新建的副本，直接改不会污染上一帧状态
          const merged: DanmakuItem = live[dupIdx];
          merged.repeat++;
          merged.w = this.measureDanmaku(this.dmDisplayText(merged));
        }
        continue;
      }
      // 同屏上限（密度可调：稀疏6/标准12/密集20）：满了就停发
      // （break 而非 continue——后面到点的只会更多，
      // 继续遍历没有意义，下一帧屏上少了会再补）
      if (live.length >= this.dmDensityCap()) {
        break;
      }
      const lane: number = this.pickLane(live, lanes, areaW);
      if (lane < 0) {
        continue;
      }
      const item = new DanmakuItem();
      item.id = this.danmakuSeq++;
      item.text = next.text;
      item.w = this.measureDanmaku(next.text);
      item.lane = lane;
      // 速度挂在轨道上：同轨恒速永不追尾，异轨 0.9/1.0/1.1 交替，
      // 弹幕场整体错落、不再是「一根传送带拖一排字」的呆板匀速。
      item.spd = this.laneSpeed(lane);
      item.x = areaW;
      live.push(item);
    }
  }

  /** 轨道速度系数：相邻轨道交替 0.9 / 1.0 / 1.1，视觉上有快有慢更自然 */
  private laneSpeed(lane: number): number {
    return 0.9 + (lane % 3) * 0.1;
  }

  /**
   * 找一条尾巴已经进入画面的轨道；找不到就丢弃这条，宁缺不叠。
   *
   * 从 dmNextLane 起轮询扫描而不是固定从轨道 0 找起：
   * 固定从头找会把弹幕全部堆在最上面几条轨道（实车反馈「比较集中」），
   * 轮询起点每次前移一条，入场的弹幕在可用轨道间均匀分布。
   */
  private pickLane(live: DanmakuItem[], lanes: number, areaW: number): number {
    const start: number = this.dmNextLane % lanes;
    // 同轨水平间距门槛：车机 ≥ 2 倍行高（验收标准，杜绝「首尾相接」）；
    // 手机保持原 18vp。同轨恒速，间距入场后保持不变。
    const tailGap: number = this.carMode ? this.danmakuLineHeight() * 2 : 18;
    for (let i = 0; i < lanes; i++) {
      const lane = (start + i) % lanes;
      let busy = false;
      for (const item of live) {
        if (item.lane === lane && item.x + item.w > areaW - tailGap) {
          busy = true;
          break;
        }
      }
      if (!busy) {
        // 起点前移一条，下一条优先换轨道，弹幕不再扎堆
        this.dmNextLane = lane + 1;
        return lane;
      }
    }
    return -1;
  }

  /**
   * 估算文本宽度。
   * 弹幕是滚动的，宽度只用于轨道占用与出屏判断，允许误差；
   * 真实测量要拿到 Text 的布局结果，每帧做一次会明显拖慢渲染。
   */
  private measureDanmaku(text: string): number {
    let units = 0;
    for (let i = 0; i < text.length; i++) {
      units += text.charCodeAt(i) > 0x2e80 ? 1 : 0.56;
    }
    return Math.max(28, units * this.dmShowSize());
  }

  private danmakuLineHeight(): number {
    return this.dmShowSize() + 9;
  }

  /**
   * 弹幕实际渲染字号：车机放大两档。轨道占用、行高、渲染三处必须
   * 用同一个值，否则碰撞判定按小字算、渲染按大字画，会重新叠字。
   */
  private dmShowSize(): number {
    if (!this.carMode) {
      return this.dmSize;
    }
    // 车机：+3 档之上再设下限——字号至少为画面高的 3.5%（验收标准）。
    // 车机观看距离远，白字小于这个比例在亮场景里读不出。
    const floor: number = Math.round(this.dmAreaHeight() * 0.035);
    return Math.max(this.dmSize + 3, floor);
  }

  /**
   * 单条弹幕的显示透明度：入场/出场各留 8% 画宽的渐变带，
   * 不再「砰地出现/咔地消失」，滚动观感柔和。底值再乘用户设置的整体不透明度。
   */
  private dmItemAlpha(item: DanmakuItem, areaW: number): number {
    const span: number = areaW * 0.08;
    let a: number = 1;
    if (span > 0) {
      if (areaW - item.x < span) {
        a = (areaW - item.x) / span;
      }
      if (item.x + item.w < span && (item.x + item.w) / span < a) {
        a = (item.x + item.w) / span;
      }
      if (a < 0.15) {
        a = 0.15;
      }
    }
    return a * this.dmOpacity;
  }

  /**
   * 弹幕只在「真实画面」里滚。
   *
   * 竖屏短剧在半屏里必然左右留黑（360 宽的容器里画面只有 ~253 宽），
   * 如果按容器宽算，弹幕会滚到黑边上，甚至压着黑边外的屏幕边缘走。
   */
  /** 车机弹幕左右安全边（14vp，验收 12–16vp）：裁切只发生在画面内侧，文字不贴画面左右缘 */
  private dmSideSafe(): number {
    return this.carMode ? 14 : 0;
  }

  private dmAreaWidth(): number {
    return Math.max(0, this.visibleVideoWidth() - this.dmSideSafe() * 2);
  }

  private dmAreaHeight(): number {
    return this.visibleVideoHeight();
  }

  /** 画面顶边在容器内的 y（contain 上下留出的黑边） */
  private dmTopInBox(): number {
    const gap: number = (this.boxAreaHeight() - this.dmAreaHeight()) / 2;
    return gap > 0 ? gap : 0;
  }

  /** 画面左边在容器内的 x */
  private dmLeft(): number {
    const gap: number = (this.boxAreaWidth() - this.dmAreaWidth()) / 2;
    return gap > 0 ? gap : 0;
  }

  /** 弹幕可用高度：从轨道起点到画面下沿 */
  private dmUsableHeight(): number {
    const bottom: number = this.dmTopInBox() + this.dmAreaHeight();
    const usable: number = bottom - this.danmakuTop();
    return usable > 0 ? usable : 0;
  }

  private laneCount(): number {
    const area: number = this.dmUsableHeight() * this.dmArea;
    let count: number = Math.floor(area / this.danmakuLineHeight());
    if (count < 1) {
      count = 1;
    }
    if (count > 9) {
      count = 9;
    }
    return count;
  }

  private danmakuTop(): number {
    // 顶栏（返回/弹幕/画质/设置）就压在最上面，弹幕从它下沿开始，
    // 否则第一轨会和按钮叠在一起；画面本身更矮时以画面顶边为准
    const belowBar: number = this.safeTopPx + 48;
    const picTop: number = this.dmTopInBox() + 4;
    return belowBar > picTop ? belowBar : picTop;
  }

  /**
   * 提示条位置：贴画面下沿往上一点（控制条上方），当轻量 toast 用。
   * 早期放在弹幕区下沿，结果在竖屏片源上正好落到画面正中、压着中央播放键，
   * 看着像一条「悬浮在剧情中间的横幅」。
   */
  private dmHintTop(): number {
    const bottom: number = this.dmTopInBox() + this.dmAreaHeight();
    // 128 是底部控制条的整体高度（时间行 + 进度条 + 按钮行），再往上就压不到控件了
    const toast: number = bottom - 128;
    const floor: number = this.danmakuTop() + 40;
    return toast > floor ? toast : floor;
  }

  private toggleDanmaku(): void {
    this.danmakuOn = !this.danmakuOn;
    Settings.danmaku = this.danmakuOn;
    Settings.save();
    if (this.danmakuOn) {
      if (this.danmakuAll.length === 0 && this.danmakuVid.length > 0
        && this.danmakuStatus !== DM_LOADING) {
        this.loadDanmaku(this.danmakuVid, this.durationMs);
      } else {
        this.resetDanmaku(this.positionMs);
        if (this.playing) {
          this.startDanmakuTicker();
        }
      }
    } else {
      this.danmakuLive = [];
      this.stopDanmakuTicker();
    }
    this.touchControls();
  }

  private setDanmakuSize(size: number): void {
    this.dmSize = size;
    Settings.danmakuSize = size;
    Settings.save();
    this.resetDanmaku(this.positionMs);
  }

  private setDanmakuArea(area: number): void {
    this.dmArea = area;
    Settings.danmakuArea = area;
    Settings.save();
    this.resetDanmaku(this.positionMs);
  }

  private setDanmakuOpacity(value: number): void {
    this.dmOpacity = value;
    Settings.danmakuOpacity = value;
    Settings.save();
  }

  /** 同屏弹幕上限（密度档位），落盘后当场生效（下一帧 spawnDue 即按新上限） */
  private dmDensityCap(): number {
    const cap: number = this.dmDensity > 0 ? this.dmDensity : DM_MAX_ONSCREEN;
    // 车机同屏上限压到 6（验收 4–6 条）：坐远看高密度弹幕只会糊成一片
    return this.carMode ? Math.min(cap, 6) : cap;
  }

  private setDmDensity(value: number): void {
    this.dmDensity = value;
    Settings.danmakuDensity = value;
    Settings.save();
    this.touchControls();
  }

  /** 合并后的展示文本：重复 1 次原样，多次带 ×N */
  private dmDisplayText(item: DanmakuItem): string {
    return item.repeat > 1 ? `${item.text} ×${item.repeat}` : item.text;
  }

  private dmColorValue(): string {
    const idx: number = this.dmColorIdx;
    if (idx >= 0 && idx < DM_COLOR_VALUES.length) {
      return DM_COLOR_VALUES[idx];
    }
    return DM_COLOR_VALUES[0];
  }

  private setDmColor(idx: number): void {
    this.dmColorIdx = idx;
    Settings.danmakuColor = idx;
    Settings.save();
    this.touchControls();
  }

  private toggleDmMerge(): void {
    this.dmMerge = !this.dmMerge;
    Settings.danmakuMerge = this.dmMerge;
    Settings.save();
    // 关闭合并后，已在屏上的 ×N 文案立即回落为原始文本
    this.resetDanmaku(this.positionMs);
    this.touchControls();
  }

  private setDmSpeed(value: number): void {
    this.dmSpeedMul = value;
    Settings.danmakuSpeed = value;
    Settings.save();
    this.touchControls();
  }

  /** 息屏听剧（= 后台播放）：设置页与播放面板共用同一持久化键 */
  private toggleBgPlay(): void {
    this.bgPlayOn = !this.bgPlayOn;
    Settings.backgroundPlay = this.bgPlayOn;
    Settings.save();
    // 开 = 申请 audioPlayback 长时任务（锁屏/切后台不冻结）；
    // 关 = 释放任务，系统冻结策略恢复默认（切后台几秒后停声）
    if (this.bgPlayOn) {
      this.startAudioTask();
    } else {
      this.stopAudioTask();
    }
    this.touchControls();
  }

  /** 普通播放的息屏听剧长时任务；投屏任务已在跑时不重复申请 */
  private async startAudioTask(): Promise<void> {
    if (this.audioTaskRunning || this.castTaskRunning || !this.bgPlayOn) {
      return;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const ctx = host as common.UIAbilityContext;
    try {
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.audioTaskRunning = true;
      hilog.info(0x0001, 'QingMangAudio', '[AUDIO] 息屏听剧长时任务已启动');
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangAudio', `长时任务启动失败 ${err.code} ${err.message}`);
    }
  }

  private async stopAudioTask(): Promise<void> {
    if (!this.audioTaskRunning) {
      return;
    }
    this.audioTaskRunning = false;
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const ctx = host as common.UIAbilityContext;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      hilog.info(0x0001, 'QingMangAudio', '[AUDIO] 息屏听剧长时任务已释放');
    } catch (error) {
      // 任务可能已被系统回收
    }
  }

  // ---------------- 定时关闭 ----------------

  /** 档位选中：设定/重置倒计时（重复点同一档视为重置） */
  private pickSleep(minutes: number): void {
    this.sleepPickMin = minutes;
    if (this.sleepTimer !== -1) {
      clearInterval(this.sleepTimer);
      this.sleepTimer = -1;
    }
    this.sleepRemainSec = minutes * 60;
    this.sleepTimer = setInterval(() => {
      this.sleepRemainSec--;
      if (this.sleepRemainSec <= 0) {
        this.fireSleepTimer();
      }
    }, 1000);
    hilog.info(0x0001, 'QingMangSleep', `[SLEEP] 定时关闭已设定：${minutes} 分钟`);
    this.touchControls();
  }

  /** 取消定时关闭（手动取消与到点清理共用） */
  private cancelSleepTimer(): void {
    if (this.sleepTimer !== -1) {
      clearInterval(this.sleepTimer);
      this.sleepTimer = -1;
    }
    this.sleepRemainSec = -1;
    this.sleepPickMin = 0;
  }

  /** 到点：暂停播放（本地/投屏统一走播控入口），释放息屏听剧任务 */
  private fireSleepTimer(): void {
    this.cancelSleepTimer();
    this.applyRemotePlay(false);
    // 睡前场景大概率开着息屏听剧：任务一并释放，不空占后台；
    // 之后恢复播放时 playing 态会自动重新申请，无需额外处理
    this.stopAudioTask();
    this.getUIContext().getPromptAction().showToast({ message: '定时时间到，已暂停播放', duration: 2000 });
    hilog.info(0x0001, 'QingMangSleep', '[SLEEP] 定时到点，已暂停播放');
    this.touchControls();
  }

  /** 剩余时间文案：<1h 用 m:ss，≥1h 用 h:mm:ss */
  private sleepRemainLabel(): string {
    const two = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    const sec = Math.max(0, this.sleepRemainSec);
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
  }

  // ---------------- 播放器 ----------------

  private attachPlayer(player: media.AVPlayer): void {
    player.on('stateChange', (state: string) => {
      if (state === 'initialized') {
        // surfaceId 只能在 initialized 状态设置，prepare 之后再设会报 5400102
        this.applySurface(player);
        player.prepare();
      } else if (state === 'prepared') {
        // 起播后清掉“正在下载/解密”的提示，否则会一直盖在画面上
        this.message = '';
        this.detailText = '';
        this.applyScaleType(player);
        this.applyVolumeTo(player);
        player.play();
        this.loading = false;
        // 提前建好媒体会话：播控中心/耳机线控立刻可用，投屏也依赖它
        this.ensureAvSession();
      } else if (state === 'playing') {
        this.playing = true;
        this.applySpeed(player);
        this.applyScaleType(player);
        // 倍速/比例都在 playing 重放，音量也要重放：
        // 手势若发生在切集/缓冲等过渡态，setVolume 会静默失败，这里统一纠正
        this.applyVolumeTo(player);
        // 息屏听剧开着：起播即申请 audioPlayback 长时任务，锁屏/切后台不断声
        this.startAudioTask();
        if (this.pendingSeekMs > 0) {
          const target = this.pendingSeekMs;
          this.pendingSeekMs = 0;
          try {
            player.seek(target, media.SeekMode.SEEK_CLOSEST);
          } catch (error) {
            // 定位失败就从当前位置播
          }
        }
        if (this.casting) {
          // 投屏中切集：本地播放器只负责把新一集准备好（加密集要先落缓存），
          // 就绪后立刻暂停本地、把新一集推给远端，避免本地远端同时出声
          player.pause();
          this.pushCastEpisode();
        } else {
          this.syncAvMetadata();
          this.syncAvPlayback(avSession.PlaybackState.PLAYBACK_STATE_PLAY);
          this.prefetchNext();
        }
        this.updatePipPlayStatus();
        this.resetDanmaku(this.positionMs);
        this.scheduleHide();
      } else if (state === 'paused') {
        this.playing = false;
        if (!this.casting) {
          this.syncAvPlayback(avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
        }
        this.updatePipPlayStatus();
        // 暂停时弹幕停在原地（时间轴也停了），停表省电
        this.stopDanmakuTicker();
        this.clearHideTimer();
        this.showControls();
      } else if (state === 'completed') {
        this.playing = false;
        if (!this.casting) {
          this.syncAvPlayback(avSession.PlaybackState.PLAYBACK_STATE_COMPLETED);
        }
        this.updatePipPlayStatus();
        this.stopDanmakuTicker();
        this.clearHideTimer();
        this.saveProgress();
        if (Settings.autoNext && this.currentIndex < this.episodeCount) {
          // 自动连播换集：控件层保持现状，不再「先弹出、起播后又收起」闪一次
          this.playEpisode(this.currentIndex + 1);
        } else {
          this.showControls();
        }
      }
    });

    player.on('timeUpdate', (time: number) => {
      // 拖动时以手指位置为准，别让回调把滑块拽回去
      if (!this.dragging) {
        this.positionMs = time;
      }
    });

    player.on('durationUpdate', (duration: number) => {
      this.durationMs = duration;
    });

    // 真实宽高决定容器高度，这是「不拉伸」的数据来源
    player.on('videoSizeChange', (width: number, height: number) => {
      if (width > 0 && height > 0 && (width !== this.videoW || height !== this.videoH)) {
        this.videoW = width;
        this.videoH = height;
        this.applyCarDefaultFit(width, height);
      }
    });

    player.on('error', (error: BusinessError) => {
      this.loading = false;
      this.message = '播放出错';
      this.detailText = `${error.code}：${error.message}`;
    });
  }

  /** 统一 contain：保持原始长宽比居中渲染，多出来的地方留黑，绝不 fill、绝不裁切 */
  private applyScaleType(player: media.AVPlayer): void {
    try {
      player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    } catch (error) {
      // 个别流不支持设置，回落到默认缩放；真正的「不变形」由 videoBoxWidth/Height 兜底
    }
  }

  /**
   * 车机默认铺满：横屏片源（绝大多数短剧转的 16:9）默认填充，
   * 车机屏比 16:9 更宽，拉伸铺满后左右撑开、上下不裁，字幕完整可见；
   * 竖屏片源保持自适应，避免全屏拉伸把人拉得走形。只做一次，用户切回自适应后尊重选择。
   */
  private applyCarDefaultFit(width: number, height: number): void {
    if (!this.carMode || this.fitDefaulted) {
      return;
    }
    this.fitDefaulted = true;
    if (width >= height) {
      this.fitFill = true;
    }
  }

  /**
   * 应用倍速。
   * 用 setPlaybackRate 而不是 setSpeed：后者收的是 PlaybackSpeed 枚举
   * （0.75→0、1.0→1、1.25→2、1.75→3、2.0→4），把倍数直接当参数传会整体错位
   * —— 选 1.5 实际按 1.75 播，选 2.5 更是直接越界。
   * setPlaybackRate 收真实倍数，API 25 起上限 8.0，0.75~5.0 这一整套都合法。
   */
  private applySpeed(player: media.AVPlayer): void {
    try {
      player.setPlaybackRate(this.speed);
    } catch (error) {
      const err = error as BusinessError;
      // 5400108 = 参数越界：老机型上限仍是 4.0，回落到 1.0 而不是停在一个假档位上
      if (err.code === 5400108) {
        try {
          player.setPlaybackRate(1);
        } catch (fallbackError) {
          // 回落也失败就保持播放器原有速率
        }
      }
    }
  }

  private async prepareLocalPlayer(path: string): Promise<void> {
    this.releasePlayer();
    try {
      const size = fs.statSync(path).size;
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      this.mediaFile = file;
      const player = await media.createAVPlayer();
      this.avPlayer = player;
      this.attachPlayer(player);
      player.fdSrc = { fd: file.fd, offset: 0, length: size };
    } catch (error) {
      this.loading = false;
      this.message = '播放器初始化失败';
      this.detailText = (error as Error).message;
    }
  }

  private async preparePlayer(source: PlaySource): Promise<void> {
    this.releasePlayer();
    try {
      const player = await media.createAVPlayer();
      this.avPlayer = player;
      this.attachPlayer(player);

      const headers: Record<string, string> = {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
        'Referer': source.referer.length > 0 ? source.referer : 'https://novel.snssdk.com/'
      };
      const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(source.url, headers);
      const strategy: media.PlaybackStrategy = { preferredBufferDuration: 4 };
      player.setMediaSource(mediaSource, strategy);
    } catch (error) {
      this.loading = false;
      this.message = '播放器初始化失败';
      this.detailText = (error as Error).message;
    }
  }

  private applySurface(player: media.AVPlayer): void {
    if (this.surfaceId.length > 0) {
      try {
        player.surfaceId = this.surfaceId;
        this.boundSurfaceId = this.surfaceId;
      } catch (error) {
        // surface 尚未就绪时忽略，等 onLoad 再补
      }
    } else {
      this.pendingSurface = true;
    }
  }

  private releasePlayer(): void {
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.off('stateChange');
        this.avPlayer.off('timeUpdate');
        this.avPlayer.off('durationUpdate');
        this.avPlayer.off('videoSizeChange');
        this.avPlayer.off('error');
        this.avPlayer.release();
      } catch (error) {
        // 释放失败不阻塞切集
      }
      this.avPlayer = null;
    }
    if (this.mediaFile !== null) {
      try {
        fs.closeSync(this.mediaFile);
      } catch (error) {
        // 文件句柄关闭失败忽略
      }
      this.mediaFile = null;
    }
    this.playing = false;
  }

  private saveProgress(): void {
    if (this.currentIndex < 1 || this.title.length === 0) {
      return;
    }
    const item = new HistoryItem();
    item.seriesId = this.seriesId;
    item.title = this.title;
    item.cover = this.cover;
    item.episodeIndex = this.currentIndex;
    item.positionMs = this.positionMs;
    item.durationMs = this.durationMs;
    AppState.history.record(item);
    // 桌面续播卡片：历史变化后推送最新一集（内部 90 秒节流，可放心高频调用）
    CardSync.pushUpdate();
  }

  // ---------------- 预缓存下一集 ----------------

  /**
   * 起播后预取下一集：走和播放完全相同的「下载 → 解密 → 落缓存」链路，
   * 换集时 playEncrypted 命中缓存直接开播，省掉几秒到十几秒的等待。
   * 失败完全静默，不打扰当前播放。
   */
  private async prefetchNext(): Promise<void> {
    if (this.prefetchBusy || this.released) {
      return;
    }
    const nextIndex = this.currentIndex + 1;
    if (nextIndex > this.episodes.length) {
      return;
    }
    const episode = this.episodes[nextIndex - 1];
    if (episode === undefined) {
      return;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const ctx = host as common.UIAbilityContext;
    this.prefetchBusy = true;
    try {
      const variants = await AppState.api.playbackVariants(this.seriesId, episode.vid);
      let source: PlaySource;
      if (this.qualityIdx === 0) {
        const clear = variants.find((it: PlaySource): boolean => !it.encrypted);
        source = clear !== undefined ? clear : variants[0];
      } else {
        source = this.qualityIdx - 1 < variants.length ? variants[this.qualityIdx - 1] : variants[0];
      }
      // 明文流是边下边播，没有「先落缓存」一说，不预取
      if (source.keyHex.length === 0) {
        return;
      }
      const path = `${ctx.cacheDir}/ep_${episode.vid}_${source.quality}.mp4`;
      try {
        if (fs.statSync(path).size > 1024) {
          return;
        }
      } catch (error) {
        // 未缓存，继续预取
      }
      const headers: Record<string, string> = {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
        'Referer': source.referer.length > 0 ? source.referer : 'https://novel.snssdk.com/'
      };
      const response = await httpRequestBuffer(source.url, headers, 90000);
      if (response.statusCode < 200 || response.statusCode >= 300 || response.data.byteLength === 0) {
        return;
      }
      const key = PlayerView.cencKeyOf(source);
      if (key === null) {
        return;
      }
      const outcome: CencResult = decryptCencMp4(response.data, key);
      if (outcome.encrypted && outcome.samples === 0) {
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, response.data);
      } finally {
        fs.closeSync(file);
      }
      this.recordCachedEpisode(episode, source);
      this.pruneCache(ctx.cacheDir, Settings.cacheKeep);
    } catch (error) {
      // 预取失败不影响播放，换集时按正常流程现下
    } finally {
      this.prefetchBusy = false;
    }
  }

  // ---------------- 画中画 ----------------

  /**
   * 进入小窗。XComponent 模式：复用本页 surface 与 AVPlayer，播放不中断。
   * 单页面应用无需 navigationId；只能在应用前台调 startPiP，
   * 退后台自动进小窗由 setAutoStartEnabled(true) 接管。
   */
  private async enterPip(): Promise<void> {
    if (this.pipBusy) {
      return;
    }
    if (!PiPWindow.isPiPEnabled()) {
      this.showDanmakuHint('此设备不支持小窗播放');
      return;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    this.pipBusy = true;
    try {
      if (this.pipController === null) {
        const config: PiPWindow.PiPConfiguration = {
          context: host,
          componentController: this.xController,
          templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
          contentWidth: this.videoW > 0 ? this.videoW : 720,
          contentHeight: this.videoH > 0 ? this.videoH : 1280
        };
        const controller = await PiPWindow.create(config);
        controller.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
          if (state === PiPWindow.PiPState.STARTED) {
            this.pipActive = true;
          } else if (state === PiPWindow.PiPState.STOPPED) {
            this.pipActive = false;
          }
        });
        controller.on('controlPanelActionEvent',
          (event: PiPWindow.PiPActionEventType, status?: number) => {
            if (event === 'playbackStateChanged') {
              this.applyRemotePlay(status === PiPWindow.PiPControlStatus.PLAY);
            } else if (event === 'nextVideo') {
              this.jumpEpisode(1);
            } else if (event === 'previousVideo') {
              this.jumpEpisode(-1);
            }
          });
        controller.setAutoStartEnabled(true);
        this.pipController = controller;
      }
      await this.pipController.startPiP();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangPip', `小窗启动失败 ${err.code} ${err.message}`);
      this.showDanmakuHint('小窗启动失败');
    } finally {
      this.pipBusy = false;
    }
  }

  private async stopPip(): Promise<void> {
    const controller = this.pipController;
    if (controller === null) {
      return;
    }
    this.pipController = null;
    this.pipActive = false;
    try {
      await controller.stopPiP();
    } catch (error) {
      // 小窗可能已被用户手动关闭
    }
  }

  /** 把当前播放态同步给小窗面板的播放/暂停按钮 */
  private updatePipPlayStatus(): void {
    const controller = this.pipController;
    if (controller === null) {
      return;
    }
    try {
      controller.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        this.playing ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
    } catch (error) {
      // 控制器已随小窗销毁
    }
  }

  // ---------------- 媒体会话与投屏 ----------------

  /**
   * 创建/复用媒体会话：注册播控回调（播控中心、耳机线控立即生效），
   * 并声明 url-cast 能力 + Cast+/DLNA 协议，投屏选择器据此发现设备。
   */
  private async ensureAvSession(): Promise<void> {
    if (this.avSessionObj !== null) {
      return;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    try {
      const session = await avSession.createAVSession(host, 'qingmangPlayer', 'video');
      this.avSessionObj = session;
      session.on('play', () => {
        this.applyRemotePlay(true);
      });
      session.on('pause', () => {
        this.applyRemotePlay(false);
      });
      session.on('stop', () => {
        const player = this.avPlayer;
        if (player !== null && !this.casting) {
          player.stop();
        }
      });
      session.on('playNext', () => {
        this.jumpEpisode(1);
      });
      session.on('playPrevious', () => {
        this.jumpEpisode(-1);
      });
      session.on('seek', (time: number) => {
        this.remoteSeek(time);
      });
      session.on('setSpeed', (speed: number) => {
        this.pickSpeed(speed);
      });
      session.on('outputDeviceChange',
        (state: avSession.ConnectionState, device: avSession.OutputDeviceInfo) => {
          this.onCastDeviceChange(state, device);
        });
      const extras: Record<string, Object> = { 'requireAbilityList': ['url-cast'] };
      await session.setExtras(extras);
      await session.activate();
      this.syncAvMetadata();
      this.syncAvPlayback(this.playing
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangCast', `AVSession 创建失败 ${err.code} ${err.message}`);
      this.avSessionObj = null;
    }
  }

  /** 播放/暂停统一入口：投屏中转发给远端，否则控本地播放器 */
  private applyRemotePlay(play: boolean): void {
    if (this.casting) {
      const controller = this.castController;
      if (controller !== null) {
        const command: avSession.AVCastControlCommand = { command: play ? 'play' : 'pause' };
        controller.sendControlCommand(command).catch((error: BusinessError) => {
          hilog.warn(0x0001, 'QingMangCast', `投播控制失败 ${error.code}`);
        });
      }
      return;
    }
    const player = this.avPlayer;
    if (player !== null) {
      if (play) {
        player.play();
      } else {
        player.pause();
      }
    }
  }

  /** 进度跳转统一入口：投屏中转发给远端，否则控本地播放器 */
  private remoteSeek(timeMs: number): void {
    if (this.casting) {
      const controller = this.castController;
      if (controller !== null && timeMs >= 0) {
        const command: avSession.AVCastControlCommand = { command: 'seek', parameter: timeMs };
        controller.sendControlCommand(command).catch((error: BusinessError) => {
          hilog.warn(0x0001, 'QingMangCast', `投播进度失败 ${error.code}`);
        });
        this.positionMs = timeMs;
      }
      return;
    }
    const player = this.avPlayer;
    if (player !== null && timeMs >= 0) {
      player.seek(timeMs, media.SeekMode.SEEK_PREV_SYNC);
      this.positionMs = timeMs;
      this.resetDanmaku(timeMs);
      this.syncAvPlayback(this.playing
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE);
    }
  }

  private syncAvMetadata(): void {
    const session = this.avSessionObj;
    if (session === null) {
      return;
    }
    const episode = this.episodes[this.currentIndex - 1];
    if (episode === undefined) {
      return;
    }
    const meta: avSession.AVMetadata = {
      assetId: episode.vid,
      title: `${this.title} 第${this.currentIndex}集`,
      subtitle: this.title,
      duration: this.durationMs,
      // 同时声明 Cast+ 与 DLNA，投屏选择器才会发现这两类设备
      filter: avSession.ProtocolType.TYPE_CAST_PLUS_STREAM | avSession.ProtocolType.TYPE_DLNA
    };
    session.setAVMetadata(meta).catch((error: BusinessError) => {
      hilog.warn(0x0001, 'QingMangCast', `setAVMetadata ${error.code}`);
    });
  }

  private syncAvPlayback(state: avSession.PlaybackState): void {
    const session = this.avSessionObj;
    if (session === null) {
      return;
    }
    const pos: avSession.PlaybackPosition = {
      elapsedTime: this.positionMs,
      updateTime: new Date().getTime()
    };
    const pb: avSession.AVPlaybackState = {
      state: state,
      speed: this.speed,
      position: pos,
      duration: this.durationMs,
      bufferedTime: this.positionMs
    };
    session.setAVPlaybackState(pb).catch((error: BusinessError) => {
      hilog.warn(0x0001, 'QingMangCast', `setAVPlaybackState ${error.code}`);
    });
  }

  /** 当前集实际选用的播放源（画质档位已套用），供投屏组装 AVQueueItem */
  private currentSource(): PlaySource | null {
    if (this.sources.length === 0) {
      return null;
    }
    if (this.qualityIdx === 0) {
      const clear = this.sources.find((it: PlaySource): boolean => !it.encrypted);
      return clear !== undefined ? clear : this.sources[0];
    }
    const idx = this.qualityIdx - 1;
    return idx < this.sources.length ? this.sources[idx] : this.sources[0];
  }

  /** 拉起系统投屏选择器（Cast+ / DLNA 设备发现与连接 UI 全由系统承担） */
  private async openCastPicker(): Promise<void> {
    if (this.castBusy) {
      return;
    }
    this.castBusy = true;
    try {
      await this.ensureAvSession();
      if (this.avSessionObj === null) {
        this.showDanmakuHint('媒体会话创建失败，无法投屏');
        return;
      }
      const host = this.getUIContext().getHostContext();
      if (host === undefined) {
        return;
      }
      if (this.castPickerHelper === null) {
        this.castPickerHelper = new avSession.AVCastPickerHelper(host);
      }
      const options: avSession.AVCastPickerOptions = { sessionType: 'video' };
      await this.castPickerHelper.select(options);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangCast', `投屏选择器打开失败 ${err.code} ${err.message}`);
      this.showDanmakuHint('打开投屏选择器失败');
    } finally {
      this.castBusy = false;
    }
  }

  /** 已连接设备里是否有真正的投播设备（蓝牙耳机等本地音频设备不算） */
  private hasCastDevice(device: avSession.OutputDeviceInfo): boolean {
    for (const item of device.devices) {
      const protocols: number = item.supportedProtocols ?? 0;
      if ((protocols & avSession.ProtocolType.TYPE_CAST_PLUS_STREAM) !== 0
        || (protocols & avSession.ProtocolType.TYPE_DLNA) !== 0) {
        return true;
      }
    }
    return false;
  }

  private async onCastDeviceChange(state: avSession.ConnectionState,
    device: avSession.OutputDeviceInfo): Promise<void> {
    if (state === avSession.ConnectionState.STATE_CONNECTED && this.hasCastDevice(device)) {
      await this.startCast();
    } else if (state === avSession.ConnectionState.STATE_DISCONNECTED && this.casting) {
      this.casting = false;
      this.playing = false;
      this.castController = null;
      this.closeCastFile();
      this.stopCastBackgroundTask();
      this.showDanmakuHint('已停止投屏');
      this.showControls();
      this.updatePipPlayStatus();
    }
  }

  /** 连接建立后：取投播控制器，把当前集推给远端并暂停本地 */
  private async startCast(): Promise<void> {
    const session = this.avSessionObj;
    if (session === null || this.casting) {
      return;
    }
    try {
      const controller = await session.getAVCastController();
      this.castController = controller;
      controller.on('playbackStateChange', 'all', (state: avSession.AVPlaybackState) => {
        if (state.state !== undefined) {
          this.playing = state.state === avSession.PlaybackState.PLAYBACK_STATE_PLAY
            || state.state === avSession.PlaybackState.PLAYBACK_STATE_FAST_FORWARD
            || state.state === avSession.PlaybackState.PLAYBACK_STATE_REWIND;
        }
        if (state.position !== undefined) {
          this.positionMs = state.position.elapsedTime;
        }
        if (state.duration !== undefined && state.duration > 0) {
          this.durationMs = state.duration;
        }
        this.updatePipPlayStatus();
      });
      controller.on('endOfStream', () => {
        if (Settings.autoNext && this.currentIndex < this.episodeCount) {
          this.saveProgress();
          this.playEpisode(this.currentIndex + 1, 0);
        }
      });
      controller.on('error', (error: BusinessError) => {
        hilog.warn(0x0001, 'QingMangCast', `投播出错 ${error.code} ${error.message}`);
      });
      const item = await this.buildCastItem();
      if (item === null) {
        this.showDanmakuHint('本集暂不支持投屏');
        this.castController = null;
        return;
      }
      await controller.prepare(item);
      await controller.start(item);
      this.casting = true;
      // 本地画面停住、声音掐掉，播放交给远端
      const player = this.avPlayer;
      if (player !== null) {
        player.pause();
      }
      await this.startCastBackgroundTask();
      this.showDanmakuHint('已开始投屏');
      this.showControls();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangCast', `投屏启动失败 ${err.code} ${err.message}`);
      this.showDanmakuHint('投屏失败');
    }
  }

  /** 投屏中切集：把新一集推给远端（本地播放器已在 playing 回调里暂停） */
  private async pushCastEpisode(): Promise<void> {
    const controller = this.castController;
    if (controller === null) {
      return;
    }
    try {
      const item = await this.buildCastItem();
      if (item === null) {
        this.showDanmakuHint('本集暂不支持投屏');
        return;
      }
      await controller.start(item);
    } catch (error) {
      this.showDanmakuHint('投屏切集失败');
    }
  }

  /**
   * 组装当前集的投播条目：
   * - 明文流：直接把 CDN 地址交给系统投播（url-cast）。
   * - 加密集：解密产物在本地缓存，用 fdSrc 让系统读文件推流（系统负责传输，无需自建服务）。
   */
  private async buildCastItem(): Promise<avSession.AVQueueItem | null> {
    const episode = this.episodes[this.currentIndex - 1];
    if (episode === undefined) {
      return null;
    }
    const source = this.currentSource();
    if (source === null) {
      return null;
    }
    const desc: avSession.AVMediaDescription = {
      assetId: episode.vid,
      title: `${this.title} 第${this.currentIndex}集`,
      mediaType: 'video',
      startPosition: 0
    };
    if (this.durationMs > 0) {
      desc.duration = this.durationMs;
    }
    if (source.keyHex.length === 0) {
      desc.mediaUri = source.url;
    } else {
      const host = this.getUIContext().getHostContext();
      if (host === undefined) {
        return null;
      }
      const ctx = host as common.UIAbilityContext;
      const path = `${ctx.cacheDir}/ep_${episode.vid}_${source.quality}.mp4`;
      try {
        const size = fs.statSync(path).size;
        if (size <= 1024) {
          return null;
        }
        this.closeCastFile();
        const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
        this.castFile = file;
        const fdSrc: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: size };
        desc.fdSrc = fdSrc;
      } catch (error) {
        return null;
      }
    }
    const item: avSession.AVQueueItem = {
      itemId: this.currentIndex,
      description: desc
    };
    return item;
  }

  /** 主动断开投屏，收尾由 outputDeviceChange 的断开分支完成 */
  private stopCast(): void {
    const session = this.avSessionObj;
    if (session !== null) {
      session.stopCasting().catch((error: BusinessError) => {
        hilog.warn(0x0001, 'QingMangCast', `stopCasting ${error.code}`);
      });
    }
  }

  private closeCastFile(): void {
    if (this.castFile !== null) {
      try {
        fs.closeSync(this.castFile);
      } catch (error) {
        // 句柄可能已被系统回收
      }
      this.castFile = null;
    }
  }

  /** 投播期间申请长时任务，锁屏/切后台不被冻结 */
  private async startCastBackgroundTask(): Promise<void> {
    if (this.castTaskRunning) {
      return;
    }
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const ctx = host as common.UIAbilityContext;
    try {
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.castTaskRunning = true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, 'QingMangCast', `长时任务启动失败 ${err.code} ${err.message}`);
    }
  }

  private async stopCastBackgroundTask(): Promise<void> {
    if (!this.castTaskRunning) {
      return;
    }
    this.castTaskRunning = false;
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      return;
    }
    const ctx = host as common.UIAbilityContext;
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (error) {
      // 任务可能已被系统回收
    }
  }

  /** 退出播放页时释放媒体会话与投播资源 */
  private async releaseAvSession(): Promise<void> {
    const session = this.avSessionObj;
    this.avSessionObj = null;
    this.castController = null;
    this.castPickerHelper = null;
    this.casting = false;
    if (session !== null) {
      try {
        session.off('play');
        session.off('pause');
        session.off('stop');
        session.off('playNext');
        session.off('playPrevious');
        session.off('seek');
        session.off('setSpeed');
        session.off('outputDeviceChange');
        try {
          await session.stopCasting();
        } catch (error) {
          // 没有进行中的投播
        }
        await session.deactivate();
        await session.destroy();
      } catch (error) {
        // 会话清理尽力而为
      }
    }
    this.closeCastFile();
    await this.stopCastBackgroundTask();
  }

  // ---------------- 交互 ----------------

  private togglePlay(): void {
    // 投屏中本地播放器只是备源，播控必须转发远端；无播放器且未投屏时按重新开播处理
    if (this.avPlayer === null && !this.casting) {
      this.playEpisode(this.currentIndex);
      return;
    }
    this.applyRemotePlay(!this.playing);
    this.touchControls();
  }

  private seekTo(ratio: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    const clamped = ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
    const target = Math.floor(this.durationMs * clamped);
    // remoteSeek 内部处理投屏转发、本地 seek、弹幕重置和播控中心状态同步
    this.remoteSeek(target);
  }

  private jumpEpisode(delta: number): void {
    const target = this.currentIndex + delta;
    if (target < 1 || target > this.episodeCount) {
      return;
    }
    this.saveProgress();
    this.playEpisode(target, 0);
    this.touchControls();
  }

  private openEpisode(index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    this.saveProgress();
    this.playEpisode(index, 0);
  }

  /** 系统返回手势：与顶栏返回钮同一套返回层级 */
  private onSystemBack(): void {
    if (this.settingsOpen) {
      this.closeSettings();
      return;
    }
    if (this.episodesOpen) {
      this.closeEpisodes();
      return;
    }
    if (this.isFullscreen && !this.carMode) {
      this.toggleFullscreen();
      return;
    }
    this.saveProgress();
    this.onBack();
  }

  /**
   * 全屏 = 视频铺满整屏（竖屏），不转横屏。
   * 短剧源基本都是竖屏，转横屏只会把画面裁掉大半，还会打断播放。
   */
  private toggleFullscreen(): void {
    animateTo({ duration: Settings.reduceMotion ? 1 : 320, curve: curves.cubicBezierCurve(0.22, 1, 0.36, 1) }, () => {
      this.isFullscreen = !this.isFullscreen;
    });
    // 车机：全屏 = 隐藏系统栏，退出全屏 = 恢复；手机不动系统栏
    this.applyCarImmersive(this.isFullscreen);
    // 全屏切换后视频区尺寸变了，弹幕轨道要重算
    if (this.fullscreenTimer !== -1) {
      clearTimeout(this.fullscreenTimer);
    }
    this.fullscreenTimer = setTimeout(() => {
      this.fullscreenTimer = -1;
      // released 是释放标记：延时回调可能在退出播放页之后才到，别再碰组件状态
      if (!this.released) {
        this.resetDanmaku(this.positionMs);
      }
    }, 340);
    this.touchControls();
  }

  private cycleTap(): void {
    if (this.isFullscreen) {
      this.toggleFullscreen();
      return;
    }
    this.togglePlay();
  }

  // ---------------- 亮度 / 音量手势 ----------------

  private applyVolumeTo(player: media.AVPlayer): void {
    try {
      player.setVolume(this.playerVolume);
    } catch (error) {
      const err = error as BusinessError;
      // 个别状态下 setVolume 会抛 5400102；playing 态和手势结束都会补调，这里只留痕
      hilog.warn(0x0001, 'QingMangVol', `setVolume 失败 ${err.code} ${err.message} val=${this.playerVolume}`);
    }
  }

  /** 窗口亮度：-1 表示恢复跟随系统 */
  private async applyBrightness(value: number): Promise<void> {
    try {
      if (this.mainWindow === null) {
        const host = this.getUIContext().getHostContext();
        if (host === undefined) {
          return;
        }
        this.mainWindow = await window.getLastWindow(host);
      }
      await this.mainWindow.setWindowBrightness(value);
    } catch (error) {
      this.mainWindow = null;
    }
  }

  /** 退出播放页把窗口亮度还给系统，否则手势调过的亮度会带到其他页面 */
  private restoreBrightness(): void {
    if (this.brightnessVal < 0) {
      return;
    }
    this.brightnessVal = -1;
    this.applyBrightness(-1);
  }

  private gestStart(event: GestureEvent): void {
    if (this.playerLocked || this.casting || this.pipActive) {
      return;
    }
    const fingers = event.fingerList;
    if (fingers.length === 0) {
      return;
    }
    const isLeft = fingers[0].localX < this.boxAreaWidth() / 2;
    this.gestMode = isLeft ? 1 : 2;
    if (isLeft) {
      // 没调过亮度时以 50% 为基准；系统实际亮度读不到，从 0 起跳会闪瞎
      if (this.brightnessVal < 0) {
        this.brightnessVal = 0.5;
      }
      this.gestStartValue = this.brightnessVal;
    } else {
      this.gestStartValue = this.playerVolume;
    }
    this.gestPercent = this.gestStartValue;
  }

  private gestUpdate(event: GestureEvent): void {
    if (this.gestMode === 0) {
      return;
    }
    // 上滑增大：拖满约 0.7 倍容器高度即从 0 到 1
    const span = Math.max(160, this.boxAreaHeight() * 0.7);
    let value = this.gestStartValue - event.offsetY / span;
    value = value < 0 ? 0 : (value > 1 ? 1 : value);
    if (this.gestMode === 1 && value < 0.05) {
      value = 0.05;
    }
    this.gestPercent = value;
    if (this.gestMode === 1) {
      this.brightnessVal = value;
      const now = Date.now();
      if (now - this.lastBrightApply > 90) {
        this.lastBrightApply = now;
        this.applyBrightness(value);
      }
    } else {
      this.playerVolume = value;
      const player = this.avPlayer;
      if (player !== null) {
        this.applyVolumeTo(player);
      }
    }
  }

  private gestEnd(): void {
    if (this.gestMode === 1) {
      this.applyBrightness(this.gestPercent);
    } else if (this.gestMode === 2) {
      // 手势结束再补一次最终值：滑动过程中的个别失败调用会被这次覆盖
      this.playerVolume = this.gestPercent;
      const player = this.avPlayer;
      if (player !== null) {
        this.applyVolumeTo(player);
      }
    }
    if (this.gestHintTimer !== -1) {
      clearTimeout(this.gestHintTimer);
    }
    this.gestHintTimer = setTimeout(() => {
      this.gestHintTimer = -1;
      this.gestMode = 0;
    }, 450);
  }

  /** 画面比例切换：自适应（保持视频真实比例，多余留黑）/ 填充（拉伸铺满容器，不裁切） */
  private toggleFit(): void {
    this.fitFill = !this.fitFill;
    this.getUIContext().getPromptAction().showToast({
      message: this.fitFill ? '画面比例：填充铺满' : '画面比例：自适应',
      duration: 1200
    });
    this.touchControls();
  }

  private pickSpeed(value: number): void {
    this.speed = value;
    Settings.speed = value;
    Settings.save();
    const player = this.avPlayer;
    if (player !== null) {
      this.applySpeed(player);
    }
    this.touchControls();
  }

  private toggleAutoNext(): void {
    this.autoNext = !this.autoNext;
    Settings.autoNext = this.autoNext;
    Settings.save();
  }

  /** 锁定播放器：收起面板与控件，此后轻触/双击/长按/滑动全部忽略 */
  private lockPlayer(): void {
    if (this.settingsOpen) {
      this.closeSettings();
    }
    if (this.episodesOpen) {
      this.closeEpisodes();
    }
    this.clearHideTimer();
    this.playerLocked = true;
    this.hideControls();
  }

  private unlockPlayer(): void {
    this.playerLocked = false;
    this.touchControls();
  }

  // ---------------- 计算 ----------------

  private formatTime(ms: number): string {
    const total = Math.floor(ms / 1000);
    if (total < 0) {
      return '0:00';
    }
    const minute = Math.floor(total / 60);
    const second = total % 60;
    return `${minute}:${second < 10 ? '0' : ''}${second}`;
  }

  private progressRatio(): number {
    if (this.dragging) {
      return this.dragRatio;
    }
    if (this.durationMs <= 0) {
      return 0;
    }
    const ratio = this.positionMs / this.durationMs;
    return ratio > 1 ? 1 : ratio;
  }

  /** 拖动中的时间浮标文本 */
  private dragTimeText(): string {
    return this.formatTime(this.dragRatio * this.durationMs);
  }

  /**
   * 视频区高度：按真实视频比例自适应，不做固定宽高比。
   * - 竖屏（高 > 宽）：先算「铺满宽度」所需高度，再按屏高上限截断，
   *   超出部分由 contain 自动留黑边，画面居中不裁切。
   * - 横屏：按真实比例算，同样有屏高上限，16:9 片源自然就是 56.25%。
   * - 还没收到 videoSizeChange 时先按 16:9 占位，收到后立刻修正。
   *
   * 宽屏（超级桌面/平板）走左栏，容器宽度是「窗口宽 - 右侧面板宽」，
   * 高度上限放宽到九成屏高——车机屏高足够，不必再压成半屏。
   */
  private videoAreaHeight(): Length {
    if (this.isFullscreen) {
      return '100%';
    }
    const width: number = this.wide() ? this.stageWidth() : this.winWidth();
    const screen: number = this.stageAvailHeight();
    const portraitCap: number = Math.round(screen * (this.wide() ? 0.9 : 0.58));
    const landscapeCap: number = Math.round(screen * (this.wide() ? 0.9 : 0.44));
    if (this.videoW > 0 && this.videoH > 0) {
      const natural: number = width * this.videoH / this.videoW;
      const cap: number = this.videoH >= this.videoW ? portraitCap : landscapeCap;
      return Math.round(natural) > cap ? cap : Math.round(natural);
    }
    return Math.round(width * 9 / 16);
  }

  private winWidth(): number {
    return this.viewWidth > 0 ? this.viewWidth : 360;
  }

  /**
   * 车机触控目标放大：1.4 倍。34vp 圆钮 → 48vp，36vp 返回钮 → 50vp。
   * 依据：车机 HMI 触控目标应明显大于手机（观看距离远、行驶颠簸），
   * 44vp 是手机无障碍下限，车机取 48vp 以上才有稳定命中率。
   * 手机上原值直通，不碰任何既有观感。
   */
  private carBtn(size: number): number {
    return this.carMode ? Math.round(size * 1.4) : size;
  }

  /** 车机上文字整体加两档：小字在 15.6 寸屏上坐远一点就糊成一片 */
  private carFont(size: number): number {
    return this.carMode ? size + 2 : size;
  }

  /**
   * 车机触控热区下限：×1.4 放大后仍不足 48vp 的补到 48（验收：可点元素 ≥48vp）。
   * 34vp 圆钮 ×1.4 只有 47.6、28vp 胶囊只有 39.2，都差一口气。
   * 只用于可点元素的高度/边长，不碰 carBtn 的圆角、padding 语义。
   */
  private carTouch(size: number): number {
    if (!this.carMode) {
      return size;
    }
    const scaled: number = Math.round(size * 1.4);
    return scaled < 48 ? 48 : scaled;
  }

  /** 视频容器当前可用尺寸（宽, 高），单位 vp */
  private boxAreaWidth(): number {
    if (this.isFullscreen) {
      return this.winWidth();
    }
    return this.wide() ? this.stageWidth() : this.winWidth();
  }

  private boxAreaHeight(): number {
    if (this.isFullscreen) {
      // 全屏基准必须是「容器实测高」而不是 AppStorage 屏高：
      // 车机上是圆角浮窗（比物理屏小一截），按整屏算会把 surface 撑得比容器还高，
      // 画面底部被裁、上下各留一条黑带 —— 实车「仅占屏高 73%」的直接根因。
      return this.stageAvailHeight();
    }
    return Number(this.videoAreaHeight());
  }

  /**
   * 播放页容器的实际可用高度：优先 onAreaChange 实测（viewHeight），
   * 实测未就绪（首帧前）才退回 AppStorage 屏高兜底。
   * 车机圆角浮窗、分屏、超级桌面投屏下，窗口高 ≠ 屏幕高，这里才是唯一可信基准。
   */
  private stageAvailHeight(): number {
    if (this.viewHeight > 0) {
      return this.viewHeight;
    }
    return this.screenHeightVp > 0 ? this.screenHeightVp : 777;
  }

  /**
   * 画面（surface）宽度：按视频真实比例在容器内排布。
   * - 自适应（contain）：surface 缩到真实比例，多余区域由外层黑底承担。
   * - 填充：surface 直接铺满容器。AVPlayer 的 VIDEO_SCALE_TYPE_FIT 本义就是
   *   「拉伸至与窗口等大」，所以画面会跟着 surface 左右拉伸铺满——
   *   不放大、不裁切，底部字幕始终完整（此前 cover 等比放大把字幕裁掉是直接根因）。
   * 视频还没回报尺寸时先铺满容器，收到 videoSizeChange 立刻修正。
   */
  private videoBoxWidth(): number {
    const areaW: number = this.boxAreaWidth();
    const areaH: number = this.boxAreaHeight();
    if (this.fitFill) {
      return areaW;
    }
    if (this.videoW <= 0 || this.videoH <= 0) {
      return areaW;
    }
    const byHeight: number = areaH * this.videoW / this.videoH;
    return Math.round(byHeight < areaW ? byHeight : areaW);
  }

  private videoBoxHeight(): number {
    const areaW: number = this.boxAreaWidth();
    const areaH: number = this.boxAreaHeight();
    if (this.fitFill) {
      return areaH;
    }
    if (this.videoW <= 0 || this.videoH <= 0) {
      return areaH;
    }
    const byHeight: number = areaH * this.videoW / this.videoH;
    if (byHeight < areaW) {
      return Math.round(areaH);
    }
    return Math.round(areaW * this.videoH / this.videoW);
  }

  /**
   * 可见画面宽（vp）：弹幕、提示条等叠加层的排版基准。
   * 填充时 surface 就是容器本身，可见部分也是容器；
   * 自适应时可见部分就是 surface 本身。
   */
  private visibleVideoWidth(): number {
    if (this.fitFill) {
      return this.boxAreaWidth();
    }
    const w: number = this.videoBoxWidth();
    return w > 0 ? w : this.boxAreaWidth();
  }

  private visibleVideoHeight(): number {
    if (this.fitFill) {
      return this.boxAreaHeight();
    }
    const h: number = this.videoBoxHeight();
    return h > 0 ? h : this.boxAreaHeight();
  }

  /** 宽屏：左右分栏（左视频、右简介/选集） */
  private wide(): boolean {
    return Breakpoints.isWide(this.winWidth());
  }

  /** 真是「宽屏分栏」形态：全屏时一律不分栏，视频独占整块 */
  private wideScreen(): boolean {
    return this.wide() && !this.isFullscreen;
  }

  /** 宽屏右侧面板宽度 */
  private sidePanelWidth(): number {
    return this.winWidth() >= 1280 ? 400 : 340;
  }

  /** 宽屏左栏（视频舞台）宽度 */
  private stageWidth(): number {
    const width: number = this.winWidth() - this.sidePanelWidth();
    return width > 240 ? width : 240;
  }

  /** 视频区高度（数值形态；全屏返回 '100%'，此时按容器实测高兜底） */
  private videoAreaHeightNum(): number {
    const h: Length = this.videoAreaHeight();
    if (typeof h === 'number') {
      return h;
    }
    return this.stageAvailHeight();
  }

  /**
   * 设置面板遮罩的宿主宽度：全屏铺满整页；
   * 宽屏分栏只罩左栏视频区，右侧简介/选集不被蒙层压暗、保持可点。
   */
  private sheetHostWidth(): Length {
    if (this.isFullscreen) {
      return '100%';
    }
    return this.wideScreen() ? this.stageWidth() : '100%';
  }

  /** 设置面板遮罩的宿主高度：半屏/分栏只罩视频区，下方简介/选集不被挡住 */
  private sheetHostHeight(): Length {
    if (this.isFullscreen) {
      return '100%';
    }
    return this.videoAreaHeight();
  }

  /** 分栏时视频在左栏垂直居中，遮罩顶点要跟着视频区走，不能固定贴顶罩偏 */
  private sheetHostTop(): number {
    if (this.isFullscreen || !this.wideScreen()) {
      return 0;
    }
    const screen: number = this.stageAvailHeight();
    const top: number = Math.round((screen - this.videoAreaHeightNum()) / 2);
    return top > 0 ? top : 0;
  }

  /**
   * 设置面板最大高度：半屏时收进视频区，全屏沿用整屏策略。
   * 半屏要扣掉面板整副「外壳」：上内边距12 + 标题行30 + 间距10 + 下内边距16 + 底部留白12 = 80。
   * 横版片源视频区只有 ~218vp，此前只扣 44，面板整体高出视频区 36vp，标题行会被 clip 裁没。
   */
  private sheetMaxHeight(): number {
    const screen: number = this.stageAvailHeight();
    if (this.isFullscreen) {
      return Math.min(430, Math.max(280, screen * 0.56));
    }
    const avail: number = this.videoAreaHeightNum() - 80;
    return Math.max(80, Math.min(430, avail));
  }

  /** 全屏选集面板高度：车机窗口矮（≤360vp），取整屏 60% 且不低于 240；手机全屏封顶 430 */
  private epSheetHeight(): number {
    const screen: number = this.stageAvailHeight();
    const height: number = Math.round(screen * 0.6);
    if (height < 240) {
      return 240;
    }
    return height > 430 ? 430 : height;
  }

  /** 选集面板列数：车机宽窗 8 列，手机与分栏选集列表保持 4 列 */
  private sheetEpisodeColumns(): number {
    return this.carMode ? 8 : EPISODE_COLUMNS;
  }

  /**
   * 控件层上/下渐变蒙层高度：横版片源半屏时视频区只有 ~218vp，
   * 两段渐变（safeTop+96 上段、150 下段）加起来 283vp 会超出视频区，
   * Column/Stack 默认不裁剪，下段渐变会漏画到下方简介/选集上。
   * 各自封顶视频区一半，保证任意片源下都装得下。
   */
  private gradientTopH(): number {
    const want: number = this.safeTopPx + 96;
    const cap: number = Math.round(this.videoAreaHeightNum() * 0.5);
    return want > cap ? cap : want;
  }

  private gradientBottomH(): number {
    const cap: number = Math.round(this.videoAreaHeightNum() * 0.5);
    return 150 > cap ? cap : 150;
  }

  /** 竖屏视频在半屏里会左右留黑，给出提示条让用户知道可以全屏 */
  private isPortraitVideo(): boolean {
    return this.videoW > 0 && this.videoH > this.videoW;
  }

  /** 时间浮标横坐标，夹在进度条两端内 */
  private bubbleX(): number {
    const track: number = this.sliderW > 0 ? this.sliderW : 240;
    const x: number = track * this.dragRatio - 26;
    if (x < 0) {
      return 0;
    }
    return x > track - 52 ? track - 52 : x;
  }

  private glass(alpha: number): string {
    // 降低透明度开关：去掉半透明，直接给实色，边框更明确
    if (Settings.reduceTransparency) {
      return alpha >= 0.5 ? '#CC000000' : '#99000000';
    }
    return alpha >= 0.5 ? '#4D000000' : '#33000000';
  }

  /**
   * 播放控件的玻璃底色。
   *
   * 播放器背后就是视频画面，玻璃在这里收益最大：模糊会把当前帧的颜色吸进按钮，
   * 浅色画面里按钮不会糊成一块白、深色画面里也不会糊成一团黑，
   * 比固定写死 #4D000000 稳得多。brightness 在按下时抬一档，作为「指尖打光」。
   */
  private glassEffect(down: boolean): BackgroundEffectOptions {
    const opt: BackgroundEffectOptions = {
      radius: 16,
      saturation: 1.5,
      brightness: down ? 1.14 : 1.0,
      color: down ? '#40FFFFFF' : this.glass(0.5)
    };
    return opt;
  }

  /** 强调色玻璃：倍速、画质这类「当前选中」的胶囊 */
  private accentGlassEffect(): BackgroundEffectOptions {
    const opt: BackgroundEffectOptions = {
      radius: 14,
      saturation: 1.4,
      brightness: 1.05,
      color: Settings.reduceTransparency ? '#E66ECC54' : Glass.accentTint()
    };
    return opt;
  }

  /** 设置面板里小格子的玻璃：选中强调色，未选中中性 */
  private chipGlassEffect(active: boolean): BackgroundEffectOptions {
    if (active) {
      return this.accentGlassEffect();
    }
    const opt: BackgroundEffectOptions = {
      radius: 12,
      saturation: 1.4,
      brightness: 1.02,
      color: '#1FFFFFFF'
    };
    return opt;
  }

  /**
   * 设置面板的染色。
   *
   * alpha 从 #E6 降到 #C4：面板要做成厚玻璃，90% 不透明的话背后画面根本透不出来，
   * 看起来还是一块黑底。77% 配 brightness 0.88，文字对比度仍然够（面板本身有模糊）。
   */
  private sheetBg(): string {
    if (Settings.reduceTransparency) {
      return '#F20F0C0E';
    }
    return '#C4131012';
  }

  /** 弹幕状态文案，只出现在设置面板里，不干扰正片 */
  private danmakuStatusText(): string {
    if (this.danmakuStatus === DM_LOADING) {
      return '正在加载官方弹幕…';
    }
    if (this.danmakuStatus === DM_OK) {
      return `已加载 ${this.danmakuCount} 条官方弹幕`;
    }
    if (this.danmakuStatus === DM_EMPTY) {
      return '本集暂时没有弹幕';
    }
    if (this.danmakuStatus === DM_ERROR) {
      return '弹幕加载失败，点击重试';
    }
    return '打开弹幕开关后自动加载';
  }

  // ---------------- UI：浮层控件 ----------------

  @Builder
  /**
   * 纯图标圆钮。opt.label 是必填参数：图标本身对读屏用户没有语义，
   * 官方无障碍规范要求这类控件必须提供 accessibilityText，否则整个播放页不可读。
   * 尺寸经 carBtn() 放大：车机上 34vp→48vp，图标 24→34vp 同步放大。
   * 参数必须是单个对象字面量（按引用传递），glyph/enabled 等才会随状态刷新。
   */
  roundButton(opt: RoundBtnOpt) {
    Row() {
      PlyIcon({ glyph: opt.glyph, dim: !opt.enabled, glyphSize: Math.round(this.carTouch(opt.size) * 0.7) })
    }
    .width(this.carTouch(opt.size))
    .height(this.carTouch(opt.size))
    .borderRadius(this.carTouch(opt.size) / 2)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(opt.label)
    .backgroundEffect(this.glassEffect(this.isDown(opt.key)))
    // 高光描边：圆钮有了边缘折射才像玻璃珠，否则只是个半透明圆片
    .border({ width: 1, color: '#2EFFFFFF' })
    .shadow({
      radius: this.isDown(opt.key) ? 6 : 14,
      color: '#33000000',
      offsetX: 0,
      offsetY: this.isDown(opt.key) ? 1 : 4
    })
    .scale({
      x: this.isDown(opt.key) ? 0.9 : 1,
      y: this.isDown(opt.key) ? 0.9 : 1
    })
    .animation({ duration: 120, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressOn(opt.key);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressOff();
      }
    })
    .onClick(() => {
      if (opt.enabled) {
        opt.action();
      }
    })
  }

  @Builder
  pill(opt: PillOpt) {
    Text(opt.label)
      .fontSize(this.carFont(Metrics.tinySize + 1))
      .fontColor(opt.active ? $r('app.color.accentOn') : $r('app.color.playerText'))
      .height(this.carTouch(28))
      .padding({ left: this.carBtn(12), right: this.carBtn(12) })
      .borderRadius(this.carTouch(28) / 2)
      .backgroundEffect(opt.active ? this.accentGlassEffect() : this.glassEffect(this.isDown(opt.key)))
      .border({ width: 1, color: opt.active ? '#4DFFFFFF' : '#2EFFFFFF' })
      .textAlign(TextAlign.Center)
      .shadow({
        radius: this.isDown(opt.key) ? 5 : 12,
        color: '#33000000',
        offsetX: 0,
        offsetY: this.isDown(opt.key) ? 1 : 3
      })
      .scale({
        x: this.isDown(opt.key) ? 0.94 : 1,
        y: this.isDown(opt.key) ? 0.94 : 1
      })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressOn(opt.key);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressOff();
        }
      })
      .onClick(opt.action)
  }

  @Builder
  topBar() {
    Row({ space: 8 }) {
      this.roundButton({
        key: 'back', glyph: 'back', size: 36, enabled: true, label: '返回',
        action: () => {
          // 车机进页即全屏（aboutToAppear），若先退全屏会落回「分栏 + 四周黑边」
          // 的中间态，且该形态在车机上本就刻意绕开 —— 车机直接返回，不经过中间态。
          if (this.isFullscreen && !this.carMode) {
            this.toggleFullscreen();
          } else {
            this.saveProgress();
            this.onBack();
          }
        }
      })

      Text(this.isFullscreen ? this.title : '')
        .fontSize(this.carFont(Metrics.bodySize))
        .fontColor($r('app.color.playerText'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 2 })

      if (!this.isFullscreen) {
        Blank()
      }

      this.roundButton({
        key: 'dm',
        glyph: this.danmakuOn ? 'danmaku' : 'danmakuOff',
        size: 34,
        enabled: true,
        label: this.danmakuOn ? '关闭弹幕' : '开启弹幕',
        action: () => {
          this.toggleDanmaku();
        }
      })

      this.roundButton({
        key: 'fav',
        glyph: this.favored ? 'favOn' : 'fav',
        size: 34,
        enabled: true,
        label: this.favored ? '取消收藏' : '收藏',
        action: () => {
          this.toggleFavorite();
        }
      })

      Text(this.qualityLabels[this.qualityIdx])
        .fontSize(this.carFont(Metrics.tinySize + 1))
        .fontColor(this.qualityLabels.length > 1 ? $r('app.color.playerText') : '#99FFFFFF')
        .height(this.carTouch(28))
        .padding({ left: this.carBtn(11), right: this.carBtn(11) })
        .borderRadius(this.carTouch(28) / 2)
        .backgroundEffect(this.glassEffect(false))
        .border({ width: 1, color: '#2EFFFFFF' })
        .textAlign(TextAlign.Center)
        .onClick(() => {
          if (this.qualityLabels.length <= 1) {
            return;
          }
          this.openSettings();
        })

      if (this.sleepRemainSec > 0) {
        Text(`定时 ${this.sleepRemainLabel()}`)
          .fontSize(this.carFont(Metrics.tinySize + 1))
          .fontColor($r('app.color.playerText'))
          .height(this.carTouch(28))
          .padding({ left: this.carBtn(11), right: this.carBtn(11) })
          .borderRadius(this.carTouch(28) / 2)
          .backgroundEffect(this.glassEffect(false))
          .border({ width: 1, color: '#2EFFFFFF' })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.openSettings();
          })
      }

      this.roundButton({
        key: 'ratio',
        glyph: 'ratio',
        size: 34,
        enabled: true,
        label: this.fitFill ? '切换为自适应比例' : '切换为填充比例',
        action: () => {
          this.toggleFit();
        }
      })

      this.roundButton({
        key: 'lock',
        glyph: 'unlock',
        size: 34,
        enabled: true,
        label: '锁定播放器',
        action: () => {
          this.lockPlayer();
        }
      })

      this.roundButton({
        key: 'set', glyph: 'settings', size: 34, enabled: true, label: '播放设置',
        action: () => {
          this.openSettings();
        }
      })
    }
    .width('100%')
    .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin, top: this.safeTopPx + 6 })
    .alignItems(VerticalAlign.Center)
    .position({ x: 0, y: 0 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  centerPlay() {
    Column() {
      Row() {
        PlyIcon({ glyph: this.playing ? 'pause' : 'play', glyphSize: Math.round(this.carBtn(46) * 0.52) })
      }
      .width(this.carBtn(46))
      .height(this.carBtn(46))
      .borderRadius(this.carBtn(46) / 2)
      .justifyContent(FlexAlign.Center)
      .accessibilityText(this.playing ? '暂停' : '播放')
      // 中央播放键是画面上唯一的大玻璃球：模糊会吸进当前帧的颜色，
      // 按下时提亮 + 阴影收紧，像被指尖按进去
      .backgroundEffect(this.glassEffect(this.isDown('center')))
      .border({ width: 1, color: '#40FFFFFF' })
      .shadow({
        radius: this.isDown('center') ? 8 : 22,
        color: '#66000000',
        offsetX: 0,
        offsetY: this.isDown('center') ? 2 : 6
      })
      .scale({
        x: this.isDown('center') ? 0.9 : 1,
        y: this.isDown('center') ? 0.9 : 1
      })
      .animation({ duration: 130, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressOn('center');
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressOff();
        }
      })
      .onClick(() => {
        this.cycleTap();
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  progressBar() {
    Column({ space: 0 }) {
      // 时间浮标槽位常驻 22vp 高：出现/消失不推动下方进度条，避免跳动
      Stack() {
        if (this.dragging) {
          Text(this.dragTimeText())
            .fontSize(Metrics.tinySize + 1)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .height(22)
            .padding({ left: 9, right: 9 })
            .borderRadius(11)
            .backgroundColor('#E6000000')
            .border({ width: 1, color: '#33FFFFFF' })
            .textAlign(TextAlign.Center)
            .position({ x: this.bubbleX(), y: 0 })
            .translate({ y: -2 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 120 }))
        }
      }
      .width('100%')
      .height(22)
      .alignContent(Alignment.TopStart)

      // 热区：控件本身 40vp 高（车机 56vp），比轨道大十几倍，无需再加透明 padding
      Slider({
        value: this.progressRatio() * 100,
        min: 0,
        max: 100,
        step: 0.1,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .height(this.carBtn(40))
        .blockSize({ width: this.carBtn(13), height: this.carBtn(13) })
        .blockColor($r('app.color.playerText'))
        .selectedColor($r('app.color.accent'))
        .trackColor('#59FFFFFF')
        .trackThickness(this.carMode ? 5 : 3)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.sliderW = Number(newValue.width);
        })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin) {
            this.dragging = true;
            this.dragRatio = value / 100;
            this.clearHideTimer();
            this.showControls();
            this.stopDanmakuTicker();
          } else if (mode === SliderChangeMode.Moving) {
            this.dragRatio = value / 100;
          } else {
            // End / Click：松手才真正 seek，拖动全程不掉帧
            this.dragging = false;
            this.seekTo(value / 100);
            this.scheduleHide();
          }
        })
    }
    .width('100%')
  }

  @Builder
  bottomControls() {
    Column() {
      Row() {
        Text(this.formatTime(this.positionMs))
          .fontSize(this.carFont(Metrics.tinySize))
          .fontColor('#D9FFFFFF')
          .width(this.carBtn(42))
        Column() {
          this.progressBar()
        }
        .layoutWeight(1)
        Text(this.formatTime(this.durationMs))
          .fontSize(this.carFont(Metrics.tinySize))
          .fontColor('#D9FFFFFF')
          .width(this.carBtn(42))
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin })
      .alignItems(VerticalAlign.Center)

      Row({ space: 6 }) {
        this.roundButton({
          key: 'prev', glyph: 'prev', size: 34, enabled: this.currentIndex > 1, label: '上一集',
          action: () => {
            this.jumpEpisode(-1);
          }
        })

        this.roundButton({
          key: 'next', glyph: 'next', size: 34, enabled: this.currentIndex < this.episodeCount,
          label: '下一集',
          action: () => {
            this.jumpEpisode(1);
          }
        })

        Blank()

        // 车机全屏没有分栏选集：从历史卡片直达播放时，这是唯一的选集入口
        if (this.carMode && this.isFullscreen) {
          this.pill({
            key: 'eps',
            label: `选集 ${this.currentIndex}/${this.episodeCount}`,
            active: this.episodesOpen,
            action: () => {
              if (this.episodesOpen) {
                this.closeEpisodes();
              } else {
                this.openEpisodes();
              }
            }
          })
        }

        // 竖屏片源在半屏里必然左右留黑，给一个直达竖屏全屏的入口
        if (this.isPortraitVideo() && !this.isFullscreen) {
          this.pill({
            key: 'portrait', label: '竖屏全屏', active: false,
            action: () => {
              this.toggleFullscreen();
            }
          })
        }

        this.pill({
          key: 'speed', label: Settings.speedLabel(this.speed), active: this.speed !== 1,
          action: () => {
            this.openSettings();
          }
        })

        this.pill({
          key: 'pip', label: '小窗', active: this.pipActive,
          action: () => {
            if (this.pipActive) {
              this.stopPip();
            } else {
              this.enterPip();
            }
          }
        })

        this.pill({
          key: 'cast', label: this.casting ? '退出投屏' : '投屏', active: this.casting,
          action: () => {
            if (this.casting) {
              this.stopCast();
            } else {
              this.openCastPicker();
            }
          }
        })

        this.roundButton({
          key: 'fs',
          glyph: this.isFullscreen ? 'exitFull' : 'fullscreen',
          size: 34,
          enabled: true,
          label: this.isFullscreen ? '退出全屏' : '进入全屏',
          action: () => {
            this.toggleFullscreen();
          }
        })
      }
      .width('100%')
      .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin, bottom: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ bottom: this.isFullscreen ? this.safeBottomPx : 0 })
  }

  // ---------------- UI：设置面板 ----------------

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(Metrics.tinySize + 1)
      .fontColor('#8CFFFFFF')
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ top: 4, bottom: 2 })
  }

  @Builder
  chip(opt: ChipOpt) {
    Text(opt.label)
      .fontSize(this.carFont(Metrics.tinySize + 2))
      .fontColor(opt.active ? $r('app.color.accentOn') : '#E6FFFFFF')
      .fontWeight(opt.active ? FontWeight.Medium : FontWeight.Normal)
      .height(this.carTouch(32))
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(this.carBtn(9))
      .backgroundEffect(this.chipGlassEffect(opt.active))
      .border({ width: 1, color: opt.active ? '#4DFFFFFF' : '#26FFFFFF' })
      .scale({
        x: this.isDown(opt.key) ? 0.95 : 1,
        y: this.isDown(opt.key) ? 0.95 : 1
      })
      .animation({ duration: 110, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressOn(opt.key);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressOff();
        }
      })
      .onClick(opt.action)
  }

  @Builder
  settingsSheet() {
    Column({ space: 10 }) {
      // 抓手 + 标题
      Row() {
        Column({ space: 2 }) {
          Text('播放设置')
            .fontSize(Metrics.bodySize)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2FFFFFF')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          PlyIcon({ glyph: 'close' })
            .scale({ x: 0.72, y: 0.72 })
            .opacity(0.7)
        }
        .width(this.carBtn(30))
        .height(this.carBtn(30))
        .borderRadius(this.carBtn(15))
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isDown('setClose') ? '#33FFFFFF' : '#1FFFFFFF')
        .scale({
          x: this.isDown('setClose') ? 0.9 : 1,
          y: this.isDown('setClose') ? 0.9 : 1
        })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.pressOn('setClose');
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressOff();
          }
        })
        .onClick(() => {
          this.closeSettings();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 10 }) {
          this.sectionTitle('播放速度')
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(SPEED_OPTIONS, (value: number) => {
              Text(Settings.speedLabel(value))
                .fontSize(this.carFont(Metrics.tinySize + 2))
                .fontColor(value === this.speed ? $r('app.color.accentOn') : '#E6FFFFFF')
                .width(this.carBtn(64))
                .height(this.carBtn(32))
                .textAlign(TextAlign.Center)
                .borderRadius(this.carBtn(9))
                .margin({ right: 6, bottom: 6 })
                .backgroundColor(value === this.speed ? $r('app.color.accent') : '#1FFFFFFF')
                .scale({
                  x: this.isDown(`sp${value}`) ? 0.93 : 1,
                  y: this.isDown(`sp${value}`) ? 0.93 : 1
                })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressOn(`sp${value}`);
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressOff();
                  }
                })
                .onClick(() => {
                  this.pickSpeed(value);
                })
            }, (value: number) => `s${value}`)
          }
          .width('100%')

          if (this.qualityLabels.length > 1) {
            this.sectionTitle('画质')
            Row({ space: 6 }) {
              ForEach(this.qualityLabels, (label: string, idx: number) => {
                this.chip({
                  key: `q${idx}`, label: label, active: idx === this.qualityIdx,
                  action: () => {
                    this.switchQuality(idx);
                  }
                })
              }, (label: string, idx: number) => `q${idx}_${label}`)
            }
            .width('100%')
          }

          Row() {
            Text('自动连播下一集')
              .fontSize(Metrics.smallSize + 1)
              .fontColor('#E6FFFFFF')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.autoNext })
              .selectedColor($r('app.color.accent'))
              .onChange(() => {
                this.toggleAutoNext();
              })
          }
          .width('100%')
          .height(42)

          Row() {
            Column({ space: 2 }) {
              Text('息屏听剧')
                .fontSize(Metrics.smallSize + 1)
                .fontColor('#E6FFFFFF')
              Text('锁屏或切后台后继续出声')
                .fontSize(Metrics.tinySize)
                .fontColor('#7AFFFFFF')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.bgPlayOn })
              .selectedColor($r('app.color.accent'))
              .onChange(() => {
                this.toggleBgPlay();
              })
          }
          .width('100%')
          .height(44)

          Row() {
            Text('定时关闭')
              .fontSize(Metrics.tinySize + 1)
              .fontColor('#8CFFFFFF')
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
            if (this.sleepRemainSec > 0) {
              Text(`${this.sleepRemainLabel()} 后暂停`)
                .fontSize(Metrics.tinySize)
                .fontColor($r('app.color.accent'))
            }
          }
          .width('100%')

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(SLEEP_OPTIONS, (minutes: number) => {
              Text(`${minutes}分钟`)
                .fontSize(this.carFont(Metrics.tinySize + 2))
                .fontColor(this.sleepPickMin === minutes ? $r('app.color.accentOn') : '#E6FFFFFF')
                .width(this.carBtn(76))
                .height(this.carBtn(32))
                .textAlign(TextAlign.Center)
                .borderRadius(this.carBtn(9))
                .margin({ right: 6, bottom: 6 })
                .backgroundColor(this.sleepPickMin === minutes ? $r('app.color.accent') : '#1FFFFFFF')
                .scale({
                  x: this.isDown(`sl${minutes}`) ? 0.93 : 1,
                  y: this.isDown(`sl${minutes}`) ? 0.93 : 1
                })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressOn(`sl${minutes}`);
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressOff();
                  }
                })
                .onClick(() => {
                  this.pickSleep(minutes);
                })
            }, (minutes: number) => `sl${minutes}`)
            if (this.sleepRemainSec >= 0) {
              Text('取消定时')
                .fontSize(this.carFont(Metrics.tinySize + 2))
                .fontColor('#E6FFFFFF')
                .width(this.carBtn(76))
                .height(this.carBtn(32))
                .textAlign(TextAlign.Center)
                .borderRadius(this.carBtn(9))
                .margin({ right: 6, bottom: 6 })
                .backgroundColor('#1FFFFFFF')
                .border({ width: 1, color: '#33FFFFFF' })
                .scale({
                  x: this.isDown('slCancel') ? 0.93 : 1,
                  y: this.isDown('slCancel') ? 0.93 : 1
                })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressOn('slCancel');
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressOff();
                  }
                })
                .onClick(() => {
                  this.cancelSleepTimer();
                  this.touchControls();
                })
            }
          }
          .width('100%')

          Divider().color('#1FFFFFFF').margin({ top: 2, bottom: 2 })

          Row() {
            Text('弹幕')
              .fontSize(Metrics.smallSize + 1)
              .fontColor('#E6FFFFFF')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(this.danmakuStatusText())
              .fontSize(Metrics.tinySize)
              .fontColor(this.danmakuStatus === DM_ERROR ? $r('app.color.accent') : '#7AFFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                if (this.danmakuStatus === DM_ERROR) {
                  this.retryDanmaku();
                }
              })
            Toggle({ type: ToggleType.Switch, isOn: this.danmakuOn })
              .selectedColor($r('app.color.accent'))
              .margin({ left: 8 })
              .onChange(() => {
                this.toggleDanmaku();
              })
          }
          .width('100%')
          .height(42)

          if (this.danmakuOn) {
            Row() {
              Text('不透明度')
                .fontSize(Metrics.smallSize)
                .fontColor('#B3FFFFFF')
                .width(58)
              Slider({ value: this.dmOpacity * 100, min: 20, max: 100, step: 5 })
                .layoutWeight(1)
                .height(32)
                .blockSize({ width: 12, height: 12 })
                .selectedColor($r('app.color.accent'))
                .trackColor('#33FFFFFF')
                .trackThickness(3)
                .onChange((value: number) => {
                  this.setDanmakuOpacity(value / 100);
                })
              Text(`${Math.round(this.dmOpacity * 100)}%`)
                .fontSize(Metrics.tinySize)
                .fontColor('#8CFFFFFF')
                .width(38)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .height(38)

            Row({ space: 6 }) {
              Text('字号')
                .fontSize(Metrics.smallSize)
                .fontColor('#B3FFFFFF')
                .width(58)
              ForEach(DM_SIZE_OPTIONS, (size: number) => {
                this.chip({
                  key: `ds${size}`,
                  label: size === 13 ? '小' : (size === 15 ? '中' : '大'),
                  active: size === this.dmSize,
                  action: () => {
                    this.setDanmakuSize(size);
                  }
                })
              }, (size: number) => `dms${size}`)
            }
            .width('100%')

            Row({ space: 6 }) {
              Text('区域')
                .fontSize(Metrics.smallSize)
                .fontColor('#B3FFFFFF')
                .width(58)
              ForEach(DM_AREA_LABELS, (label: string, idx: number) => {
                this.chip({
                  key: `da${idx}`, label: label, active: DM_AREA_VALUES[idx] === this.dmArea,
                  action: () => {
                    this.setDanmakuArea(DM_AREA_VALUES[idx]);
                  }
                })
              }, (label: string, idx: number) => `dma${idx}_${label}`)
            }
            .width('100%')

            Row({ space: 6 }) {
              Text('密度')
                .fontSize(Metrics.smallSize)
                .fontColor('#B3FFFFFF')
                .width(58)
              ForEach(DM_DENSITY_LABELS, (label: string, idx: number) => {
                this.chip({
                  key: `dd${idx}`, label: label, active: DM_DENSITY_VALUES[idx] === this.dmDensity,
                  action: () => {
                    this.setDmDensity(DM_DENSITY_VALUES[idx]);
                  }
                })
              }, (label: string, idx: number) => `dmd${idx}_${label}`)
            }
            .width('100%')

            Row({ space: 10 }) {
              Text('颜色')
                .fontSize(Metrics.smallSize)
                .fontColor('#B3FFFFFF')
                .width(58)
              ForEach(DM_COLOR_VALUES, (color: string, idx: number) => {
                Stack({ alignContent: Alignment.Center }) {
                  Circle({ width: 20, height: 20 }).fill(color)
                  if (idx === this.dmColorIdx) {
                    Circle({ width: 26, height: 26 })
                      .fill(Color.Transparent)
                      .stroke('#E6FFFFFF')
                      .strokeWidth(1.6)
                  }
                }
                .width(28)
                .height(28)
                .scale({ x: this.isDown(`dc${idx}`) ? 0.85 : 1, y: this.isDown(`dc${idx}`) ? 0.85 : 1 })
                .animation({ duration: 120, curve: Curve.EaseOut })
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.pressOn(`dc${idx}`);
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.pressOff();
                  }
                })
                .onClick(() => {
                  this.setDmColor(idx);
                })
              }, (color: string, idx: number) => `dc${idx}_${color}`)
            }
            .width('100%')
            .height(34)

            Row() {
              Column({ space: 2 }) {
                Text('合并重复弹幕')
                  .fontSize(Metrics.smallSize)
                  .fontColor('#B3FFFFFF')
                Text('相同弹幕合并为一条并标注条数')
                  .fontSize(Metrics.tinySize)
                  .fontColor('#7AFFFFFF')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.dmMerge })
                .selectedColor($r('app.color.accent'))
                .onChange(() => {
                  this.toggleDmMerge();
                })
            }
            .width('100%')
            .height(38)

            Row({ space: 6 }) {
              Text('速度')
                .fontSize(Metrics.smallSize)
                .fontColor('#B3FFFFFF')
                .width(58)
              ForEach(DM_SPEED_LABELS, (label: string, idx: number) => {
                this.chip({
                  key: `dv${idx}`, label: label, active: DM_SPEED_VALUES[idx] === this.dmSpeedMul,
                  action: () => {
                    this.setDmSpeed(DM_SPEED_VALUES[idx]);
                  }
                })
              }, (label: string, idx: number) => `dmv${idx}_${label}`)
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 4 })
      }
      .width('100%')
      // 高度上限按形态取：半屏收进视频区，全屏按整屏比例（上限仍 430）
      .constraintSize({ maxHeight: this.sheetMaxHeight() })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .constraintSize({ maxWidth: 560 })
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    // 面板是厚玻璃：背后就是视频画面，模糊 + 压暗既保证文字可读，
    // 又不会像纯黑底那样把整个播放页「切断」
    .backgroundEffect({
      radius: 34,
      saturation: 1.8,
      brightness: Settings.reduceTransparency ? 1 : 0.88,
      color: this.sheetBg()
    })
    .borderRadius(20)
    .border({ width: 1, color: '#26FFFFFF' })
    .shadow({ radius: 32, color: '#B3000000', offsetX: 0, offsetY: 12 })
  }

  /**
   * 全屏选集面板：车机进播放页即全屏，全屏下没有简介/选集分栏——
   * 从历史卡片直达播放时将完全没有选集入口。面板视觉与设置面板同族
   * （厚玻璃 + 圆角 + 底部滑入），网格与分栏选集列表同一套格子样式。
   */
  @Builder
  episodeSheet() {
    Column({ space: 10 }) {
      // 标题行 + 关闭
      Row() {
        Text(`选集 · 共 ${this.episodeCount} 集`)
          .fontSize(this.carFont(Metrics.bodySize))
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2FFFFFF')
        Blank()
        Text(`当前 第 ${this.currentIndex} 集`)
          .fontSize(this.carFont(Metrics.tinySize + 1))
          .fontColor($r('app.color.accent'))
        Row() {
          PlyIcon({ glyph: 'close' })
            .scale({ x: 0.72, y: 0.72 })
            .opacity(0.7)
        }
        .width(this.carBtn(30))
        .height(this.carBtn(30))
        .borderRadius(this.carBtn(15))
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isDown('epClose') ? '#33FFFFFF' : '#1FFFFFFF')
        .scale({
          x: this.isDown('epClose') ? 0.9 : 1,
          y: this.isDown('epClose') ? 0.9 : 1
        })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.pressOn('epClose');
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressOff();
          }
        })
        .onClick(() => {
          this.closeEpisodes();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 选集网格：自身可滚，车机宽窗 8 列、手机 4 列
      Grid() {
        ForEach(this.episodes, (episode: Episode) => {
          GridItem() {
            Text(`${episode.index}`)
              .fontSize(this.carFont(Metrics.smallSize + 1))
              .fontWeight(episode.index === this.currentIndex ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(episode.index === this.currentIndex ? $r('app.color.inkOn') : $r('app.color.textDim'))
              .backgroundColor(episode.index === this.currentIndex ? $r('app.color.chipOn') : $r('app.color.chipBg'))
              .borderRadius(this.carBtn(EPISODE_TILE_RADIUS))
              .width('100%')
              .height(this.carBtn(EPISODE_TILE_H))
              .textAlign(TextAlign.Center)
              .scale({
                x: this.pressKey === `sep${episode.index}` ? 0.94 : 1,
                y: this.pressKey === `sep${episode.index}` ? 0.94 : 1
              })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.pressOn(`sep${episode.index}`);
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.pressOff();
                }
              })
              .onClick(() => {
                this.openEpisode(episode.index);
                this.closeEpisodes();
              })
          }
          .height(this.carBtn(EPISODE_TILE_H))
        }, (episode: Episode) => `${episode.index}_${episode.index === this.currentIndex}`)
      }
      .columnsTemplate(`repeat(${this.sheetEpisodeColumns()}, 1fr)`)
      .columnsGap(EPISODE_GAP)
      .rowsGap(EPISODE_GAP)
      .width('100%')
      .layoutWeight(1)
      .padding({ bottom: 4 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height(this.epSheetHeight())
    .constraintSize({ maxWidth: 720 })
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    // 与设置面板同一块厚玻璃：保证网格文字在任意画面亮度下可读
    .backgroundEffect({
      radius: 34,
      saturation: 1.8,
      brightness: Settings.reduceTransparency ? 1 : 0.88,
      color: this.sheetBg()
    })
    .borderRadius(20)
    .border({ width: 1, color: '#26FFFFFF' })
    .shadow({ radius: 32, color: '#B3000000', offsetX: 0, offsetY: 12 })
  }

  // ---------------- UI：视频区 ----------------

  @Builder
  videoArea() {
    Stack({ alignContent: Alignment.Center }) {
      // 底色恒为黑：contain 留下的画面外区域就是它
      XComponent({
        id: 'qingmang_video',
        type: XComponentType.SURFACE,
        controller: this.xController
      })
        // 关键：surface 本身按视频真实比例设尺寸（而不是 100% 撑满容器）。
        // 实测本机 AVPlayer 即使设了 VIDEO_SCALE_TYPE_FIT，画面仍会被拉满 surface，
        // 竖屏片源在半屏里被横向压扁。把 surface 缩成真实比例后，
        // 无论底层怎么缩放都不可能变形，多余区域由外层黑底承担。
        .width(this.videoBoxWidth())
        .height(this.videoBoxHeight())
        .onLoad(() => {
          this.surfaceId = this.xController.getXComponentSurfaceId();
          if (this.pendingSurface) {
            // surface 比播放器晚就绪：重建播放器，让 initialized 阶段就能拿到 surfaceId
            this.pendingSurface = false;
            this.playEpisode(this.currentIndex, this.positionMs);
            return;
          }
          // 兜底：surface 换了而播放器还活着 —— 说明画面还挂在已销毁的旧 surface 上，
          // 只会剩声音。surfaceId 只允许在 initialized 状态绑定，所以只能重建播放器
          // 并 seek 回原位置（布局已经保证旋转不重建 XComponent，这里是防平台强重建）。
          if (this.avPlayer !== null && this.boundSurfaceId.length > 0
            && this.boundSurfaceId !== this.surfaceId) {
            this.playEpisode(this.currentIndex, this.positionMs);
          }
        })
        .onDestroy(() => {
          this.surfaceId = '';
        })

      // 弹幕层：只在真实画面范围内滚动并裁切。
      // 竖屏片源在半屏里左右有黑边，弹幕如果按容器定位就会滚到黑边上、甚至
      // 跑到屏幕边缘外面去；这里把层本身收成画面大小再 clip，越界自然被切掉。
      if (this.danmakuOn) {
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.danmakuLive, (item: DanmakuItem) => {
            // 坐标必须由 @Prop 传入，不能在子组件里直接读普通对象的 item.x，
            // 否则 ForEach 复用组件时 position 不会随帧更新（详见 DanmakuText 注释）。
            DanmakuText({
              dmText: this.dmDisplayText(item),
              dmX: item.x,
              dmY: this.danmakuTop() - this.dmTopInBox() + item.lane * this.danmakuLineHeight(),
              dmFont: this.dmShowSize(),
              dmAlpha: this.dmItemAlpha(item, this.dmAreaWidth()),
              dmColor: this.dmColorValue()
            })
          /**
           * key 必须带上坐标：只按 id 做 key 时，弹幕滚动期间数组长度与 id 序列不变，
           * ArkUI 的 ForEach 会判定「无需重新生成」并直接复用组件，子组件的 @Prop
           * 收不到新的 dmX，position 永远停在入场位置，弹幕被 clip 裁光。
           * 真机（API 26）实测：日志里 x 每帧递减、组件树里 origBounds 却纹丝不动，
           * 就是这个原因。坐标量化到 1vp，约每帧换一次 key，Text 很轻，开销可控。
           */
          }, (item: DanmakuItem) => `${item.id}_${Math.round(item.x)}_${item.repeat}`)
        }
        .width(this.dmAreaWidth())
        .height(this.dmAreaHeight())
        .position({ x: this.dmLeft(), y: this.dmTopInBox() })
        .clip(true)
        .hitTestBehavior(HitTestMode.None)
      }

      // 弹幕状态提示：只在刚加载完的几秒出现，滚起来后就不再打扰
      if (this.dmHint.length > 0 && this.danmakuOn) {
        Column() {
          Text(this.dmHint)
            .fontSize(Metrics.tinySize + 1)
            .fontColor('#D9FFFFFF')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor('#73000000')
            .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.dmHintTop() })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }

      // 加载 / 错误蒙层
      if (this.loading || this.message.length > 0) {
        Column({ space: 10 }) {
          if (this.loading) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.accent'))
            Text('正在取流…')
              .fontSize(Metrics.smallSize)
              .fontColor('#D9FFFFFF')
          } else {
            Text(this.message)
              .fontSize(Metrics.bodySize)
              .fontColor('#FFFFFF')
              .textAlign(TextAlign.Center)
            if (this.detailText.length > 0) {
              Text(this.detailText)
                .fontSize(Metrics.smallSize)
                .fontColor('#CCFFFFFF')
                .textAlign(TextAlign.Center)
                .maxLines(6)
                .padding({ left: 24, right: 24 })
            }
            if (this.message === '播放出错' || this.message === '取播放地址失败') {
              Text('重试')
                .fontSize(Metrics.smallSize)
                .fontColor($r('app.color.accentOn'))
                .height(34)
                .padding({ left: 22, right: 22 })
                .borderRadius(17)
                .backgroundColor($r('app.color.accent'))
                .margin({ top: 4 })
                .onClick(() => {
                  this.playEpisode(this.currentIndex, this.positionMs);
                })
            }
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }

      // ---- 浮层控件 ----
      // 控件层只承载「看得见的东西」，空白处轻触统一由外层视频容器的 onClick 兜底
      Stack({ alignContent: Alignment.Bottom }) {

        // 上下渐变蒙层：不拦截触摸
        Column() {
          Text('')
            .width('100%')
            .height(this.gradientTopH())
            .linearGradient({
              angle: 180,
              colors: [['#A6000000', 0.0], ['#00000000', 1.0]]
            })
          Blank()
          Text('')
            .width('100%')
            .height(this.gradientBottomH())
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#B3000000', 0.62], ['#CC000000', 1.0]]
            })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)

        this.topBar()

        this.centerPlay()

        Column() {
          Blank()
          this.bottomControls()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .opacity(this.controlsOpacity)
      .translate({ y: this.controlsOffset })
      // 隐去时整层不参与命中（否则摸黑点到看不见的按钮）；控件上的按钮自己消费事件，
      // 空白处的触摸冒泡到外层视频容器，由它的 onClick 完成「轻触唤醒 / 再触收起」
      .hitTestBehavior(this.controlsShown() ? HitTestMode.Default : HitTestMode.None)
      // 兜底：控件层任何子元素都不越出视频区，杜绝再画到下方简介/选集上
      .clip(true)

      // 双击快进/快退浮标：出现在点击侧，650ms 后淡出
      if (this.seekHint.length > 0) {
        Column() {
          Text(this.seekHint)
            .fontSize(Metrics.bodySize + 1)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor('#B3000000')
            .border({ width: 1, color: '#33FFFFFF' })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(this.seekHintLeft ? HorizontalAlign.Start : HorizontalAlign.End)
        .padding({ left: 40, right: 40 })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 120 }))
      }

      // 长按临时 2 倍速指示
      if (this.boostOn) {
        Column() {
          Text('2.0x 快放中')
            .fontSize(Metrics.tinySize + 1)
            .fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor('#73000000')
            .border({ width: 1, color: '#33FFFFFF' })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .position({ x: 0, y: this.safeTopPx + 54 })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 120 }))
      }

      // 锁定态：仅保留右上角解锁钮，其余控件与手势全部失效
      if (this.playerLocked) {
        Row() {
          PlyIcon({ glyph: 'lock', glyphSize: Math.round(this.carTouch(34) * 0.62) })
        }
        .width(this.carTouch(34))
        .height(this.carTouch(34))
        .borderRadius(this.carTouch(34) / 2)
        .justifyContent(FlexAlign.Center)
        .accessibilityText('解锁播放器')
        .backgroundEffect(this.glassEffect(this.isDown('lockFloat')))
        .border({ width: 1, color: '#2EFFFFFF' })
        .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
        .scale({ x: this.isDown('lockFloat') ? 0.9 : 1, y: this.isDown('lockFloat') ? 0.9 : 1 })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .position({ x: this.boxAreaWidth() - this.carTouch(34) - 14, y: this.safeTopPx + 10 })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.pressOn('lockFloat');
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressOff();
          }
        })
        .onClick(() => {
          this.unlockPlayer();
        })
      }

      // 亮度/音量手势指示：跟随手势所在半屏贴边显示
      if (this.gestMode !== 0) {
        Column({ space: 9 }) {
          Text(this.gestMode === 1 ? '亮度' : '音量')
            .fontSize(Metrics.tinySize + 1)
            .fontColor('#E6FFFFFF')
          Stack({ alignContent: Alignment.Bottom }) {
            Column()
              .width(4)
              .height(110)
              .borderRadius(2)
              .backgroundColor('#33FFFFFF')
            Column()
              .width(4)
              .height(Math.max(4, Math.round(this.gestPercent * 110)))
              .borderRadius(2)
              .backgroundColor($r('app.color.accent'))
          }
          Text(`${Math.round(this.gestPercent * 100)}%`)
            .fontSize(Metrics.tinySize)
            .fontColor('#CCFFFFFF')
        }
        .padding({ left: 13, right: 13, top: 15, bottom: 15 })
        .borderRadius(15)
        .backgroundColor('#8C000000')
        .border({ width: 1, color: '#33FFFFFF' })
        .position({
          x: this.gestMode === 1 ? 22 : this.boxAreaWidth() - 78,
          y: this.boxAreaHeight() / 2 - 82
        })
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 120 }))
      }
    }
    .width('100%')
    .height(this.videoAreaHeight())
    .backgroundColor($r('app.color.playerBg'))
    // 不加圆角、不加裁切：此前车机全屏给画面四角切 22vp 圆角，
    // 露出底下浅色页面底色，实车看就是「投屏四周一圈白色圆角」。
    // 填充模式下 surface 与容器等大，也无溢出需要裁。
    .clip(this.fitFill)
    // 轻触兜底：控件可见时空白处点击收起，控件隐去后点击唤醒。
    // 按钮自己有 onClick 会消费事件，不会误触到这里。
    .onClick((event: ClickEvent) => {
      this.onVideoClick(event);
    })
    // 长按 = 临时 2 倍速，松手恢复原倍速
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.beginBoost();
        })
        .onActionEnd(() => {
          this.endBoost();
        })
    )
    // 垂直滑动 = 左半屏调亮度、右半屏调音量（各带贴边指示条）
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: 10 })
        .onActionStart((event: GestureEvent) => {
          this.gestStart(event);
        })
        .onActionUpdate((event: GestureEvent) => {
          this.gestUpdate(event);
        })
        .onActionEnd(() => {
          this.gestEnd();
        })
        .onActionCancel(() => {
          this.gestEnd();
        })
    )
  }

  // ---------------- UI：下方内容区 ----------------

  @Builder
  tabBar() {
    Row() {
      Column() {
        Text('简介')
          .fontSize(Metrics.bodySize)
          .fontColor(this.tab === 0 ? $r('app.color.text') : $r('app.color.textFaint'))
          .fontWeight(this.tab === 0 ? FontWeight.Medium : FontWeight.Normal)
        Row()
          .width(this.tab === 0 ? 20 : 6)
          .height(3)
          .borderRadius(2)
          .backgroundColor(this.tab === 0 ? $r('app.color.accent') : Color.Transparent)
          .margin({ top: 5 })
          .animation({ duration: 200, curve: Curve.EaseOut })
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.tab = 0;
      })

      Column() {
        Text('选集')
          .fontSize(Metrics.bodySize)
          .fontColor(this.tab === 1 ? $r('app.color.text') : $r('app.color.textFaint'))
          .fontWeight(this.tab === 1 ? FontWeight.Medium : FontWeight.Normal)
        Row()
          .width(this.tab === 1 ? 20 : 6)
          .height(3)
          .borderRadius(2)
          .backgroundColor(this.tab === 1 ? $r('app.color.accent') : Color.Transparent)
          .margin({ top: 5 })
          .animation({ duration: 200, curve: Curve.EaseOut })
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.tab = 1;
      })
    }
    .width('100%')
    .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  tagRow() {
    Row({ space: 6 }) {
      Text(this.currentIndex <= this.episodeCount ? `更新至 ${this.episodeCount} 集` : '全剧完结')
        .fontSize(Metrics.tinySize)
        .fontColor($r('app.color.accent'))
        .height(22)
        .padding({ left: 8, right: 8 })
        .borderRadius(6)
        .backgroundColor($r('app.color.accentSoft'))

      Text(`共 ${this.episodeCount} 集`)
        .fontSize(Metrics.tinySize)
        .fontColor($r('app.color.textDim'))
        .height(22)
        .padding({ left: 8, right: 8 })
        .borderRadius(6)
        .backgroundColor($r('app.color.chipBg'))

      if (this.tags.length > 0) {
        Text(this.tags)
          .fontSize(Metrics.tinySize)
          .fontColor($r('app.color.textDim'))
          .height(22)
          .padding({ left: 8, right: 8 })
          .borderRadius(6)
          .backgroundColor($r('app.color.chipBg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Blank()
      }
    }
    .width('100%')
  }

  @Builder
  descPane() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.title)
          .fontSize(Metrics.titleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text'))
          .width('100%')

        this.tagRow()

        Column({ space: 6 }) {
          Text(this.desc.length > 0 ? this.desc : '暂无简介')
            .fontSize(Metrics.smallSize + 1)
            .fontColor($r('app.color.textDim'))
            .lineHeight(22)
            .width('100%')
            .maxLines(this.descExpanded ? 99 : 3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.desc.length > 60) {
            Text(this.descExpanded ? '收起' : '展开全部')
              .fontSize(Metrics.tinySize + 1)
              .fontColor($r('app.color.accent'))
              .height(24)
              .onClick(() => {
                this.descExpanded = !this.descExpanded;
              })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 选集快捷入口，比切 Tab 少一步
        Row() {
          Text(`第 ${this.currentIndex} 集`)
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.text'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('选集 ›')
            .fontSize(Metrics.smallSize)
            .fontColor($r('app.color.textDim'))
        }
        .width('100%')
        .height(44)
        .padding({ left: 14, right: 14 })
        .borderRadius(Metrics.cardRadius)
        .backgroundColor($r('app.color.surface'))
        .border({ width: 1, color: $r('app.color.border') })
        .onClick(() => {
          this.tab = 1;
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin, top: 14, bottom: 28 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  /**
   * 选集网格：Grid + 1fr 四等分，天然铺满、右侧不留白。
   * 卡片 44 高 / 10 圆角，当前集反色高亮，按下 0.96 缩放给手感。
   */
  @Builder
  episodePane() {
    Column() {
      Row() {
        Text(`选集 · 共 ${this.episodeCount} 集`)
          .fontSize(Metrics.tinySize + 1)
          .fontColor($r('app.color.textDim'))
        Blank()
        Text(`当前 第 ${this.currentIndex} 集`)
          .fontSize(Metrics.tinySize + 1)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin, top: 12, bottom: 8 })

      Grid() {
        ForEach(this.episodes, (episode: Episode) => {
          GridItem() {
            Text(`${episode.index}`)
              .fontSize(Metrics.smallSize + 1)
              .fontWeight(episode.index === this.currentIndex ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(episode.index === this.currentIndex ? $r('app.color.inkOn') : $r('app.color.textDim'))
              .backgroundColor(episode.index === this.currentIndex ? $r('app.color.chipOn') : $r('app.color.chipBg'))
              .borderRadius(this.carBtn(EPISODE_TILE_RADIUS))
              .width('100%')
              .height(this.carBtn(EPISODE_TILE_H))
              .textAlign(TextAlign.Center)
              .scale({
                x: this.pressKey === `ep${episode.index}` ? 0.94 : 1,
                y: this.pressKey === `ep${episode.index}` ? 0.94 : 1
              })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.pressOn(`ep${episode.index}`);
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.pressOff();
                }
              })
              .onClick(() => {
                this.openEpisode(episode.index);
              })
          }
          .height(this.carBtn(EPISODE_TILE_H))
        }, (episode: Episode) => `${episode.index}_${episode.index === this.currentIndex}`)
      }
      .columnsTemplate(`repeat(${EPISODE_COLUMNS}, 1fr)`)
      .columnsGap(EPISODE_GAP)
      .rowsGap(EPISODE_GAP)
      .width('100%')
      .layoutWeight(1)
      .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin, bottom: 24 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 竖屏与宽屏共用同一条父链：Row > Column > videoArea。
      // 为什么必须这样：XComponent(SURFACE) 一旦被销毁重建，surfaceId 就换了，
      // 而正在播的 AVPlayer 仍指向旧 surface —— 表现就是「有声音、画面全黑」。
      // 以前竖屏/宽屏是两个完全不同的分支（Column 直接包 vs Row 里再包），
      // 手机一旋转就整棵子树重建，正是黑屏的根因。
      // 现在只让「视频下方」与「右侧面板」这两块的条件变化，videoArea 位置恒定。
      Row() {
        Column() {
          this.videoArea()

          // 竖屏：简介 / 选集接在视频下方
          if (!this.wideScreen() && !this.isFullscreen) {
            this.tabBar()

            if (this.tab === 0) {
              this.descPane()
            } else {
              this.episodePane()
            }
          }
        }
        .layoutWeight(1)
        .height('100%')
        // 宽屏只剩视频一个子节点，居中显示；竖屏是被 Video + Tab + 面板填满，Start 即可
        .justifyContent(this.wideScreen() && !this.isFullscreen ? FlexAlign.Center : FlexAlign.Start)
        .backgroundColor(this.wideScreen() && !this.isFullscreen
          ? $r('app.color.playerBg')
          : Color.Transparent)

        // 宽屏（超级桌面 / 平板 / 横屏）：简介与选集放右侧，互不挤压
        if (this.wideScreen() && !this.isFullscreen) {
          Column() {
            this.tabBar()

            if (this.tab === 0) {
              this.descPane()
            } else {
              this.episodePane()
            }
          }
          .width(this.sidePanelWidth())
          .height('100%')
          .backgroundColor($r('app.color.bg'))
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .height('100%')

      // 设置面板：全屏时整页遮罩 + 底部滑入；
      // 半屏/分栏时遮罩与面板都收在视频区内部 —— 简介、选集在蒙层之外，
      // 保持可见可点，面板自身在视频区内滚动，不再压住下方内容。
      if (this.settingsOpen) {
        Stack({ alignContent: Alignment.Bottom }) {
          Text('')
            .width('100%')
            .height('100%')
            .backgroundColor('#8A000000')
            .opacity(this.sheetShift)
            .onClick(() => {
              this.closeSettings();
            })

          Column() {
            this.settingsSheet()
          }
          .width('100%')
          .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin })
          .margin({ bottom: this.isFullscreen ? this.safeBottomPx + 12 : 12 })
          .opacity(this.sheetShift)
          .translate({ y: (1 - this.sheetShift) * 460 })
          // 面板几乎占满视频区时关闭按钮太小难点：点面板任意非交互位置（标题、留白）也直接收起。
          // 倍速/画质/弹幕选项自带 onClick，手势仲裁内层优先，点选项不会误关。
          .onClick(() => {
            this.closeSettings();
          })
        }
        .width(this.sheetHostWidth())
        .height(this.sheetHostHeight())
        .position({ x: 0, y: this.sheetHostTop() })
        // 滑入动画期间面板会被 translate 推到宿主外，clip 掉防止越界画到简介/选集上
        .clip(true)
        .zIndex(40)
      }

      // 全屏选集面板：只在车机全屏出现（底部控制条的「选集」胶囊触发），
      // 整页遮罩 + 底部滑入，与设置面板同一套视觉语言
      if (this.episodesOpen) {
        Stack({ alignContent: Alignment.Bottom }) {
          Text('')
            .width('100%')
            .height('100%')
            .backgroundColor('#8A000000')
            .opacity(this.epSheetShift)
            .onClick(() => {
              this.closeEpisodes();
            })

          Column() {
            this.episodeSheet()
          }
          .width('100%')
          .padding({ left: Metrics.safeMargin, right: Metrics.safeMargin })
          .margin({ bottom: this.safeBottomPx + 12 })
          .opacity(this.epSheetShift)
          .translate({ y: (1 - this.epSheetShift) * 460 })
        }
        .width('100%')
        .height('100%')
        .clip(true)
        .zIndex(40)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.viewWidth = Number(newValue.width);
      this.viewHeight = Number(newValue.height);
    })
  }
}
