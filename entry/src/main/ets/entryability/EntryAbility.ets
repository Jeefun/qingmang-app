import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { Prefs } from '../store/Prefs';
import { ThemeController } from '../theme/Theme';
import { AppState } from '../store/AppState';

const TAG = 'QingMangEntry';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  /**
   * 已经挂过监听的窗口实例。
   *
   * 超级桌面的应用流转会在车机侧再建一个窗口舞台（新的 window stage / 新的窗口），
   * 用布尔量做「只注册一次」的闸门会导致车机窗口挂不上监听、窗口尺寸变化收不到，
   * 所以这里按实例判断：同一个窗口不重复挂，换了窗口重新挂。
   */
  private boundWindow: window.Window | null = null;
  /** 全屏兜底的尝试次数与重入保护：maximize 失败时不能无限重试 */
  private fillTries: number = 0;
  private filling: boolean = false;
  /** 是否由本应用主动把窗口改成横屏（断开座舱后要还原，不能把手机锁死在横屏） */
  private forcedLandscape: boolean = false;
  private orienting: boolean = false;
  /** 是否已开启多窗横向模式（对应 module.json5 的 landscape_auto，断开座舱时要关掉） */
  private landscapeMultiOn: boolean = false;
  /**
   * 窗口当前所在屏幕 id：手机主屏为 0，超级桌面流转后是车机虚拟屏的 id。
   * 启动时从 Ability 配置读初始值，之后由 window 的 displayIdChange 事件实时维护——
   * 超级桌面本质是「窗口跨屏迁移」，context.config.displayId 只反映启动瞬间，
   * 会话中途被流转/迁回时必须靠事件更新，否则车机判定会停留在旧值。
   */
  private currentDisplayId: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0001, TAG, 'onCreate');
    // 颜色与主题都依赖 Prefs，顺序不能反
    Prefs.init(this.context);
    ThemeController.init(this.context);
    // 超级桌面也可能直接从车机拉起本应用：此时启动配置里 displayId 已是车机虚拟屏
    this.currentDisplayId = this.readConfigDisplayId();
    AppStorage.setOrCreate('carMode', this.currentDisplayId > 0);
    // 主题切换后同步状态栏图标明暗
    ThemeController.onThemeChanged = (dark: boolean) => {
      this.applySystemBar(dark);
    };
    // 桌面卡片 / 跨设备接续拉起：解析启动参数里的续播指令
    this.resolvePendingPlay(want);
  }

  /**
   * 解析启动/新意图参数中的续播指令，写入 AppStorage 'pendingPlay'。
   *
   * 两个来源：
   * ① 桌面卡片 postCardAction router（params.seriesId / params.episodeIndex）；
   * ② 跨设备接续（目标端 onCreate 收到的 parameters.continuePlay，JSON 字符串）。
   * Index 页面用 @StorageProp 监听该值并跳转播放页，随后清空避免重复触发。
   */
  private resolvePendingPlay(want: Want): void {
    try {
      const params = want.parameters;
      if (params === undefined) {
        return;
      }
      // ① 卡片点击（冷启动走这里；热启动走 onNewWant）
      const cardSeries = params['seriesId'];
      if (typeof cardSeries === 'string' && cardSeries.length > 0) {
        const rawEpisode = params['episodeIndex'];
        const episode: number = typeof rawEpisode === 'number' ? rawEpisode : 0;
        AppStorage.setOrCreate('pendingPlay',
          JSON.stringify({ 'seriesId': cardSeries, 'episodeIndex': episode }));
        hilog.info(0x0001, TAG, `[VERIFY] 卡片续播入口: ${cardSeries} 第${episode}集`);
        return;
      }
      // ② 跨设备接续：目标端冷启动时迁移数据随 want 下发
      const continuePayload = params['continuePlay'];
      if (typeof continuePayload === 'string' && continuePayload.length > 0) {
        AppStorage.setOrCreate('pendingPlay', continuePayload);
        hilog.info(0x0001, TAG, '[VERIFY] 跨设备接续入口: 已接收续播数据');
      }
    } catch (error) {
      hilog.warn(0x0001, TAG, '[VERIFY] 解析续播参数失败');
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已在后台运行、由卡片/通知再次拉起：同样解析续播指令
    this.resolvePendingPlay(want);
  }

  /**
   * 跨设备接续播放（源端回调）：
   * 用户在另一台设备的任务中心/接续入口触发，把「最近在看」随 wantParam 带到目标端。
   * 目标端靠同账号历史记录自然续播进度，这里只传定位用的 seriesId/episodeIndex。
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    try {
      const latest = AppState.history.list();
      if (latest.length > 0) {
        const item = latest[0];
        wantParam['continuePlay'] = JSON.stringify({
          'seriesId': item.seriesId,
          'episodeIndex': item.episodeIndex
        });
        hilog.info(0x0001, TAG,
          `[VERIFY] 接续迁移: ${item.seriesId} 第${item.episodeIndex}集`);
        return AbilityConstant.OnContinueResult.AGREE;
      }
      hilog.info(0x0001, TAG, '[VERIFY] 接续迁移: 无历史记录，同意空迁移');
      return AbilityConstant.OnContinueResult.AGREE;
    } catch (error) {
      hilog.warn(0x0001, TAG, '[VERIFY] 接续迁移失败，拒绝继续');
      return AbilityConstant.OnContinueResult.MISMATCH;
    }
  }

  /** 应用当前所在屏幕的 id：手机主屏为 0，流转到车机后是车机虚拟屏的 id */
  private winDisplayId(): number {
    return this.currentDisplayId;
  }

  /** 启动瞬间从 Ability 配置读初始屏幕 id（此后由 displayIdChange 事件维护） */
  private readConfigDisplayId(): number {
    try {
      const id = this.context.config.displayId;
      return typeof id === 'number' ? id : 0;
    } catch (error) {
      return 0;
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(0x0001, TAG, `加载页面失败: ${err.code}`);
        return;
      }
      hilog.info(0x0001, TAG, '页面已加载');
      this.setupWindow(windowStage);
    });
  }

  /**
   * 沉浸式窗口：内容延伸到状态栏与手势条下方，页面自己按安全区留白。
   * 这样顶部没有一条白带，底部导航也能铺到屏幕底。
   */
  private async setupWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const win = await windowStage.getMainWindow();
      this.mainWindow = win;
      // 超级桌面会给车机侧另建窗口舞台：新窗口 = 新的全屏兜底预算
      this.fillTries = 0;

      await win.setWindowLayoutFullScreen(true);
      await win.setWindowKeepScreenOn(true);

      await this.logEnv();
      // 先摆正方向，再要尺寸：窗口形状跟着应用方向走，顺序反了会白算一次布局
      await this.syncCarOrientation();
      // 先把窗口要到最大，再算尺寸：否则页面会用座舱下发的窄宽度排一次版
      await this.ensureFillScreen();
      // 车机侧窗口有时在 setup 之后才最终定型，再补一次（次数有上限，不会循环）
      setTimeout(() => {
        this.ensureFillScreen();
      }, 900);

      // 先按当前状态算一遍，再挂监听：启动瞬间不会有一帧用错尺寸
      this.syncWindowMetrics();
      this.bindWindowEvents(win);

      await this.applySystemBar(ThemeController.isDark);
    } catch (error) {
      hilog.warn(0x0001, TAG, '窗口沉浸式设置失败');
    }
  }

  /**
   * 窗口尺寸与避让区监听。
   *
   * 手机通过超级桌面流转到车机时窗口会重新创建/拉伸，DPI 与避让区也和手机不同；
   * 迁回手机同样会再变一次，所以这里必须是「每次变化都重算」，不能只在启动时读一次。
   */
  private bindWindowEvents(win: window.Window): void {
    if (this.boundWindow === win) {
      return;
    }
    this.boundWindow = win;

    win.on('windowSizeChange', (size: window.Size) => {
      // [VERIFY] 统一前缀：车机流转时用 hdc shell hilog | grep VERIFY 直接抓
      hilog.info(0x0001, TAG, `[VERIFY] windowSizeChange: width=${size.width}, height=${size.height}`);
      this.syncWindowMetrics();
      // 流转 / 迁移后座舱可能重新按手机比例下发窗口：先校正方向，再兜一次尺寸
      this.syncCarOrientation();
      this.ensureFillScreen();
    });

    win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
      // 车机侧避让区与手机不同（状态栏 / 异形屏 / 手势条位置都不一样），
      // 这里必须把四个方向都打出来，页面才能据此判断要不要额外留白
      hilog.info(0x0001, TAG,
        `[VERIFY] avoidAreaChange: type=${data.type}, top=${data.area.topRect.height}, ` +
        `bottom=${data.area.bottomRect.height}, left=${data.area.leftRect.width}, ` +
        `right=${data.area.rightRect.width}`);
      this.syncWindowMetrics();
    });

    // 折叠屏 / 车机分屏切换时会触发，同样需要重排
    win.on('windowStatusChange', (status: window.WindowStatusType) => {
      hilog.info(0x0001, TAG, `[VERIFY] windowStatusChange: ${status}`);
      this.syncWindowMetrics();
    });

    // 超级桌面流转/迁回：窗口被挪到车机虚拟屏（或挪回手机主屏）时触发。
    // 这是「独立窗口投屏」形态下最可靠的时机信号（API 14+）——
    // 比轮询 getAllDisplays 准，且能覆盖「会话中途上车/下车」的完整生命周期。
    win.on('displayIdChange', (id: number) => {
      hilog.info(0x0001, TAG,
        `[VERIFY] displayIdChange: ${this.currentDisplayId} -> ${id}（0=手机主屏，>0=车机虚拟屏）`);
      this.currentDisplayId = id;
      AppStorage.setOrCreate('carMode', id > 0);
      // 换了屏 = 新的全屏兜底预算：车机侧要重新铺满一次
      this.fillTries = 0;
      // 与启动时同一套顺序：先方向、再尺寸、最后刷新布局度量
      this.syncCarOrientation();
      this.ensureFillScreen();
      this.syncWindowMetrics();
    });
  }

  /**
   * 环境快照：流转到车机后排查问题，靠这一行看清「设备类型 / 所有屏幕 / 窗口」的关系。
   *
   * 关键判据：应用流转到车机后窗口挂在车机的虚拟屏上，
   * 若某块屏是横的（如 1920x1256）而窗口只有一半宽（如 605x1256），
   * 就是座舱按「手机比例」下发了窗口，不是布局问题。
   */
  private async logEnv(): Promise<void> {
    try {
      const win = this.mainWindow;
      let winSize: string = 'n/a';
      if (win !== null) {
        const rect: window.Rect = win.getWindowProperties().windowRect;
        winSize = `${rect.width}x${rect.height}@(${rect.left},${rect.top})`;
      }
      const displays: display.Display[] = await display.getAllDisplays();
      let list: string = '';
      for (const item of displays) {
        list += ` [id=${item.id} ${item.width}x${item.height} d=${item.densityPixels} r=${item.rotation}]`;
      }
      hilog.info(0x0001, TAG,
        `[VERIFY] env: deviceType=${deviceInfo.deviceType} api=${deviceInfo.sdkApiVersion} ` +
        `displayId=${this.winDisplayId()} window=${winSize} displays:${list}`);
    } catch (error) {
      hilog.warn(0x0001, TAG, '[VERIFY] env 读取失败');
    }
  }

  /**
   * 车机上把窗口变成横向——「只有中间一条」的根因修复。
   *
   * 超级桌面走应用流转通道，座舱默认把应用当「手机应用」映射到中控屏：
   * 窗口形状跟着应用方向走，应用是竖的中控上就是一条竖窗。只有窗口本身变横，
   * 座舱才会按横向铺开——横屏类应用能满屏，本质就是它们跑在横屏窗口里。
   *
   * 两条路径，顺序不可颠倒（依据：官方《窗口旋转》「旋转接口的行为限制」）：
   *
   * ① 主路径 enableLandscapeMultiWindow()：多窗横向。
   *    官方原文：智慧多窗悬浮窗、分屏、多任务、应用后台、自由多窗等场景下，
   *    「应用设置旋转策略后，系统忽略此旋转策略，接口可正常调用，但应用显示方向并不会改变」。
   *    超级桌面在车机上正是投屏/多窗形态，所以 setPreferredOrientation 在这里会
   *    **静默失效**——Promise 正常 resolve、方向纹丝不动，这解释了为什么以前
   *    「改了没变化，日志里也没有报错」。此时真正有效的是多窗横向开关。
   *    它有两个硬前提（SDK 注释）：只对主窗口生效；module.json5 的
   *    preferMultiWindowOrientation 必须为 landscape_auto（已按此配置）。
   *
   * ② 辅路径 setPreferredOrientation(LANDSCAPE)：只在全屏窗口下才有意义。
   *    官方：「主窗口全屏显示时旋转策略立即生效；非全屏时变更不会立即生效，
   *    要等主窗口进入全屏后才生效」。且「显示方向强依赖 sensor，无 sensor 的设备
   *    （如 TV）调用该接口不会生效」——车机无 sensor，所以这条只能当补刀。
   *
   * 「被投到第二块屏」用 getAllDisplays().length > 1 判断：手机自身永远只有一块屏，
   * 连上座舱才多出车机那块屏，判定不需要任何权限。断开后两条路径都还原。
   */
  private async syncCarOrientation(): Promise<void> {
    const win: window.Window | null = this.mainWindow;
    if (win === null || this.orienting) {
      return;
    }
    this.orienting = true;
    try {
      const displays: display.Display[] = await display.getAllDisplays();
      const onCar: boolean = displays.length > 1 || deviceInfo.deviceType === 'car' || this.winDisplayId() > 0;
      const rect: window.Rect = win.getWindowProperties().windowRect;
      const portrait: boolean = rect.height > rect.width;

      if (onCar) {
        // ① 多窗横向：车机超级桌面场景下唯一真正生效的一步
        if (!this.landscapeMultiOn) {
          try {
            await win.enableLandscapeMultiWindow();
            this.landscapeMultiOn = true;
            hilog.info(0x0001, TAG,
              `[VERIFY] multiwin: enable 成功（${displays.length} 块屏 / displayId=${this.winDisplayId()}）` +
              ` window=${rect.width}x${rect.height}`);
          } catch (mwError) {
            const mwErr = mwError as BusinessError;
            // 1300002=窗口状态异常 1300003=窗口服务异常；失败也要继续走兜底
            hilog.warn(0x0001, TAG, `[VERIFY] multiwin: enable 失败 code=${mwErr.code}`);
          }
        }
        // ② 仍是竖的才请求固定横屏；已经是横的就不折腾用户
        if (portrait) {
          try {
            await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
            this.forcedLandscape = true;
            hilog.info(0x0001, TAG, `[VERIFY] orient: 请求横屏 window=${rect.width}x${rect.height}`);
          } catch (orientError) {
            const oErr = orientError as BusinessError;
            hilog.warn(0x0001, TAG, `[VERIFY] orient: 设置失败 code=${oErr.code}`);
          }
        }
      } else if (this.landscapeMultiOn || this.forcedLandscape) {
        // 已离开座舱：两条路径都要还原，绝不能把手机锁死在横屏
        this.fillTries = 0;
        if (this.landscapeMultiOn) {
          try {
            await win.disableLandscapeMultiWindow();
            this.landscapeMultiOn = false;
            hilog.info(0x0001, TAG, '[VERIFY] multiwin: 已离开车机屏，关闭多窗横向');
          } catch (disError) {
            const dErr = disError as BusinessError;
            hilog.warn(0x0001, TAG, `[VERIFY] multiwin: disable 失败 code=${dErr.code}`);
          }
        }
        if (this.forcedLandscape) {
          try {
            await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
            this.forcedLandscape = false;
            hilog.info(0x0001, TAG, '[VERIFY] orient: 已离开车机屏，还原自动旋转');
          } catch (restoreError) {
            const rErr = restoreError as BusinessError;
            hilog.warn(0x0001, TAG, `[VERIFY] orient: 还原失败 code=${rErr.code}`);
          }
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, TAG, `[VERIFY] orient: 判定失败 code=${err.code}`);
    } finally {
      this.orienting = false;
    }
  }

  /**
   * 车机全屏兜底：窗口明显窄于车机屏时，主动要一次整屏。
   *
   * 顺序上是 syncCarOrientation() 之后再跑——先让窗口变成横的（形状对了），
   * 再试着让它变大（尺寸对了）。两步都失败时保持现状，不影响任何功能。
   *
    * 触发条件收得很窄：必须「确实在车机上」（多屏或设备类型 car）且
    * 「窗口宽或高任一与车机屏的缺口超过 48px」——只查宽度会漏掉「宽度铺满、
    * 高度不足」的形态（车机上下黑边），按比例阈值又会放过 5% 左右的窄边。
    * 手机上永远命中不到，绝不会去动用户的窗口；
    * 尝试次数上限 3 次，失败也不会反复折腾。
   */
  private async ensureFillScreen(): Promise<void> {
    const win: window.Window | null = this.mainWindow;
    if (win === null || this.filling || this.fillTries >= 3) {
      return;
    }
    this.filling = true;
    try {
      const before: window.Rect = win.getWindowProperties().windowRect;
      const displays: display.Display[] = await display.getAllDisplays();
      // 只在「被投到车机」时动手：手机自身只有一块屏，绝不干预用户自己的窗口
      const onCar: boolean = displays.length > 1 || deviceInfo.deviceType === 'car' || this.winDisplayId() > 0;
      if (!onCar) {
        return;
      }
      // 首选「窗口所在的屏」（displayIdChange 实时维护）：流转后要铺满的就是那块车机虚拟屏；
      // 读取失败才兜底「面积最大的横屏」。手机主屏是竖的，不会被兜底逻辑选中。
      let target: display.Display | null = null;
      if (this.currentDisplayId > 0) {
        try {
          target = display.getDisplayByIdSync(this.currentDisplayId);
        } catch (targetError) {
          target = null;
        }
      }
      if (target === null) {
        for (const item of displays) {
          if (item.width <= item.height) {
            continue;
          }
          if (target === null || item.width * item.height > target.width * target.height) {
            target = item;
          }
        }
      }
      if (target === null) {
        return;
      }
      // 黑边判定从「九成铺满」改为绝对值：车机屏 2560x1440 上九成阈值会放过
      // 上下各 ~72px 的黑边（约 5%），实车肉眼看就是两条明显的边框。
      // 任一方向缺口超过 48px（2560x1440 屏、density 3.25 下约 15vp，半个触控热区）
      // 就认为还需要补铺。
      if (target.width - before.width <= 48 && target.height - before.height <= 48) {
        return;
      }
      // 只有「真的需要动手」才消耗次数：手机上永远命中不到这里，不会把额度用光
      this.fillTries++;
      hilog.info(0x0001, TAG,
        `[VERIFY] fill: try#${this.fillTries} window=${before.width}x${before.height} ` +
        `target=${target.width}x${target.height} id=${target.id} deviceType=${deviceInfo.deviceType}`);

      // 第一步：交给系统最大化。自由窗口/大屏上这是系统认可的做法，
      // 会顺带处理沉浸式布局，比手工改尺寸更稳。
      // 显式传 ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER：最大化进沉浸并
      // 禁用标题栏/Dock 悬停，车机上不透明的标题条/停靠条不再压在画面上。
      try {
        await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER);
      } catch (maxError) {
        const maxErr = maxError as BusinessError;
        // 801=设备不支持；1300004=窗口不可最大化。都属预期，继续下一步
        hilog.warn(0x0001, TAG, `[VERIFY] fill: maximize 不可用 code=${maxErr.code}`);
        try {
          await win.maximize();
        } catch (retryError) {
          hilog.warn(0x0001, TAG, '[VERIFY] fill: maximize(默认) 也不可用');
        }
      }

      // 第二步：maximize 没生效时，先把自己声明的窗口上限抬到整屏再 resize。
      // 部分设备会把应用默认上限压成手机尺寸，不抬上限 resize 会被静默夹住。
      // 同样用绝对黑边判定（任一方向缺口 > 48px 就补），与入口判定保持同一把尺子。
      let after: window.Rect = win.getWindowProperties().windowRect;
      if (target.width - after.width > 48 || target.height - after.height > 48) {
        try {
          await win.setWindowLimits({
            maxWidth: target.width,
            maxHeight: target.height,
            minWidth: 320,
            minHeight: 320
          });
        } catch (limitError) {
          const limitErr = limitError as BusinessError;
          hilog.warn(0x0001, TAG, `[VERIFY] fill: setWindowLimits 不可用 code=${limitErr.code}`);
        }
        try {
          await win.resize(target.width, target.height);
          await win.moveWindowTo(0, 0);
        } catch (resizeError) {
          const resizeErr = resizeError as BusinessError;
          hilog.warn(0x0001, TAG, `[VERIFY] fill: resize 被拒绝 code=${resizeErr.code}`);
        }
        after = win.getWindowProperties().windowRect;
      }
      // 终态与目标并排打印：上车看一眼就能判断「还差多少、差在哪个维度」
      const stillShort: boolean = target.width - after.width > 48 || target.height - after.height > 48;
      hilog.info(0x0001, TAG,
        `[VERIFY] fill: after=${after.width}x${after.height}@(${after.left},${after.top}) ` +
        `target=${target.width}x${target.height} ${stillShort ? 'STILL_SHORT' : 'FILLED'}`);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0001, TAG, `[VERIFY] fill: 失败 code=${err.code} msg=${err.message}`);
    } finally {
      this.filling = false;
    }
  }

  /**
   * 把窗口矩形与避让区换算成 vp 写进 AppStorage，页面用 @StorageProp 订阅。
   *
   * 用 windowRect 而不是 display 物理尺寸：超级桌面下车机屏幕宽度 ≠ 应用窗口宽度，
   * 按物理屏反推会把内容算宽。densityPixels 每次都重新取，迁移后可能变。
   */
  private syncWindowMetrics(): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      // 密度必须取「窗口所在屏」的：车机虚拟屏密度与手机主屏通常不同，
      // 若用主屏密度换算，车机上的宽度/避让区全都会算错，布局跟着错。
      let density = display.getDefaultDisplaySync().densityPixels;
      if (this.currentDisplayId > 0) {
        try {
          density = display.getDisplayByIdSync(this.currentDisplayId).densityPixels;
        } catch (error) {
          hilog.warn(0x0001, TAG, '[VERIFY] metrics: 读取车机屏密度失败，回退主屏密度');
        }
      }
      const rect = win.getWindowProperties().windowRect;
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);

      // 左右避让取两者较大值：横屏时手势条会跑到侧边
      const left = Math.max(sys.leftRect.width, nav.leftRect.width) / density;
      const right = Math.max(sys.rightRect.width, nav.rightRect.width) / density;

      AppStorage.setOrCreate('safeTop', sys.topRect.height / density);
      AppStorage.setOrCreate('safeBottom', nav.bottomRect.height / density);
      AppStorage.setOrCreate('safeLeft', left);
      AppStorage.setOrCreate('safeRight', right);
      AppStorage.setOrCreate('screenWidth', rect.width / density);
      AppStorage.setOrCreate('screenHeight', rect.height / density);
      // 车机侧有异形/圆角时用避让区判断，页面据此决定是否额外留白
      AppStorage.setOrCreate('hasAvoidSide', left > 0 || right > 0);

      // [VERIFY] 换算成 vp 后的最终值：日志里直接看这个，不用再拿 px 反推
      hilog.info(0x0001, TAG,
        `[VERIFY] metrics: ${Math.round(rect.width / density)}x${Math.round(rect.height / density)}vp ` +
        `safeTop=${Math.round(sys.topRect.height / density)}vp ` +
        `safeBottom=${Math.round(nav.bottomRect.height / density)}vp ` +
        `safeSide=${Math.round(left)}/${Math.round(right)}vp`);
    } catch (error) {
      hilog.warn(0x0001, TAG, '窗口尺寸读取失败');
    }
  }

  /** 系统栏透明 + 图标随主题反色 */
  private async applySystemBar(dark: boolean): Promise<void> {
    if (this.mainWindow === null) {
      return;
    }
    // 播放页处于激活状态时，状态栏压在深色视频画面上：
    // 浅色主题的深棕图标（#241A16）在黑底上不可见，强制切白色。
    const playerActive = AppStorage.get<boolean>('playerActive') === true;
    const contentColor = dark || playerActive ? '#FFFFFF' : '#241A16';
    try {
      await this.mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
    } catch (error) {
      hilog.warn(0x0001, TAG, '系统栏配色设置失败');
    }
  }

  onWindowStageDestroy(): void {
    // 不能在这里解绑/清空窗口：超级桌面的应用流转会先建车机舞台、再销毁手机舞台
    // （顺序不保证），一旦在这里把 mainWindow 置空，就丢掉刚建好的车机窗口，
    // 后续尺寸变化全部收不到。窗口实例的监听会随窗口一起释放，不需要手工回收。
    hilog.info(0x0001, TAG, 'onWindowStageDestroy');
  }
}
