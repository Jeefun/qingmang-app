/**
 * 沉浸光感（immersive system material）接入层。
 *
 * 只有系统组件才支持材质：Navigation/NavDestination 标题栏、Tabs 底部页签、
 * 弹窗与菜单、Slider / Toggle / Select / Button。手写的 Row/Column 不在生效范围内，
 * 给它们挂 systemMaterial 只会换来一条 "Material inactive: out of scope" 日志。
 *
 * 因此本工程的分工是：
 *   - 标题栏：迁到 Navigation.title，材质由系统渲染（本文件提供材质对象）；
 *   - 底部胶囊：手写 Row，保留 backgroundBlurStyle 兜底方案（HDS 未引入前不上材质）；
 *   - Toggle / Slider / Button：应用级开关打开后系统默认接管，不额外挂材质。
 *
 * 材质需要 API 26 且设备侧能力开关为 true，两处都判过才返回对象；
 * 否则返回 undefined，调用方回落到改造前的渐变 / 模糊方案，老设备不崩。
 */
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'QingMangMaterial';
/** 沉浸光感（uiMaterial 模块）起始 API 版本 */
const MATERIAL_API: number = 26;

export class Immersive {
  /**
   * 当前设备能否使用 ImmersiveMaterial。
   * 先看 API 版本再看设备能力：低版本上连 uiMaterial 模块都不保证存在，
   * 直接调用会抛异常，所以版本判断必须在最前面。
   */
  static supported(): boolean {
    if (deviceInfo.sdkApiVersion < MATERIAL_API) {
      return false;
    }
    try {
      return uiMaterial.isImmersiveMaterialSupported();
    } catch (error) {
      return false;
    }
  }

  /**
   * 标题栏材质：超薄 + 智能反色 + 按压形变 + 点光源。
   * 超薄是官方推荐给「悬浮、轻量」层的样式，标题栏正好属于这一层；
   * 智能反色只在 THIN/ULTRA_THIN 上容易触发，与超薄选择一致。
   */
  static titleMaterial(): uiMaterial.ImmersiveMaterial | undefined {
    if (!Immersive.supported()) {
      return undefined;
    }
    try {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        colorInvert: true,
        interactive: true,
        lightEffect: {}
      });
    } catch (error) {
      return undefined;
    }
  }

  /**
   * 显式关闭材质的空对象。
   *
   * 注意：给 systemMaterial 传 undefined 只是「不设置」，应用级开关处于 ENABLE 时
   * 系统仍会按默认规则接管标题栏（实测：传 undefined 后顶部依旧有模糊带）。
   * 真要关掉必须传 Material.empty。
   */
  static noneMaterial(): uiMaterial.Material {
    return uiMaterial.Material.empty;
  }

  /** 材质档位可读名，仅用于日志 */
  private static levelName(): string {
    try {
      const level: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
      if (level === uiMaterial.MaterialLevel.EXQUISITE) {
        return 'EXQUISITE';
      }
      if (level === uiMaterial.MaterialLevel.GENTLE) {
        return 'GENTLE';
      }
      return 'SMOOTH';
    } catch (error) {
      return 'UNKNOWN';
    }
  }

  /** 材质启用状态可读名，仅用于日志 */
  private static stateName(): string {
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      if (info.state === uiMaterial.MaterialState.ENABLE) {
        return 'ENABLE';
      }
      if (info.state === uiMaterial.MaterialState.DISABLE) {
        return 'DISABLE';
      }
      return 'DEFAULT';
    } catch (error) {
      return 'UNAVAILABLE';
    }
  }

  /**
   * 打印一次材质状态，供真机 / 车机流转时用 `hdc shell hilog | grep VERIFY` 采集。
   * 应用级开关读的是 module.json5 里的 metadata，读不到说明配置没进包。
   */
  static logState(): void {
    hilog.info(0x0001, TAG,
      `[VERIFY] material state=${Immersive.stateName()} level=${Immersive.levelName()} ` +
      `supported=${Immersive.supported()} apiVersion=${deviceInfo.sdkApiVersion}`);
  }
}
