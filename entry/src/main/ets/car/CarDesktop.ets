/**
 * 超级桌面投屏检测（手机应用侧，不需要车机权限）。
 *
 * 手机应用被超级桌面投到车机屏时，会运行在虚拟屏上（displayId !== 0），
 * 这是最可靠的判断依据：不依赖任何私有接口，手机独立使用时天然为 false。
 * Car Kit 事件监听属于增强能力，个人调试证书通常拿不到，失败即静默降级。
 */
import { smartMobilityCommon } from '@kit.CarKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'QingMangCar';

export class CarDesktop {
  private awareness: smartMobilityCommon.SmartMobilityAwareness | null = null;
  private listening: boolean = false;
  private subscribedTypes: smartMobilityCommon.SmartMobilityType[] = [];
  /** 当前是否运行在车机虚拟屏上 */
  runningOnCarScreen: boolean = false;

  /** 通过 displayId 判断是否被投到车机屏 */
  detectDisplay(context: common.UIAbilityContext): number {
    try {
      const config = context.config;
      const displayId = config.displayId;
      if (typeof displayId === 'number') {
        this.runningOnCarScreen = displayId > 0;
        return displayId;
      }
    } catch (error) {
      hilog.warn(0x0001, TAG, '读取 displayId 失败');
    }
    return 0;
  }

  /** 监听超级桌面事件；只有真机 + release 包才可能收到回调 */
  start(onChange: (running: boolean) => void): void {
    if (this.listening) {
      return;
    }
    try {
      this.awareness = smartMobilityCommon.getSmartMobilityAwareness();
      const types: smartMobilityCommon.SmartMobilityType[] = [
        smartMobilityCommon.SmartMobilityType.SUPER_LAUNCHER
      ];
      this.subscribedTypes = types;
      this.awareness.on('smartMobilityEvent', types, (event: smartMobilityCommon.SmartMobilityEvent) => {
        const onCar = event.type === smartMobilityCommon.SmartMobilityType.SUPER_LAUNCHER;
        this.runningOnCarScreen = onCar;
        onChange(onCar);
        hilog.info(0x0001, TAG, `超级桌面事件 type=${event.type}`);
      });
      this.listening = true;
    } catch (error) {
      // 非鸿蒙智行车型、非中国大陆、或未授予车服务权限时走这里
      hilog.warn(0x0001, TAG, 'Car Kit 不可用，按普通大屏模式运行');
    }
  }

  stop(): void {
    if (this.awareness !== null && this.listening) {
      try {
        this.awareness.off('smartMobilityEvent', this.subscribedTypes);
      } catch (error) {
        // ignore
      }
    }
    this.listening = false;
    this.awareness = null;
  }
}
