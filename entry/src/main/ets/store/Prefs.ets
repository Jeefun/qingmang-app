/**
 * 本地键值存储。只存设备号、播放历史、上次浏览位置这类小数据。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * 偏好库名属于**磁盘文件标识**，不是品牌文案。
 * 改名会让系统新建一个空库，用户已保存的主题、倍速、弹幕开关、播放历史全部丢失。
 * 应用显示名已改为「青芒短视频」，这里刻意保留旧值。
 */
const STORE_NAME = 'guoapp_store';

export class Prefs {
  private static store: preferences.Preferences | null = null;

  static init(context: common.Context): void {
    if (Prefs.store !== null) {
      return;
    }
    try {
      Prefs.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (error) {
      Prefs.store = null;
    }
  }

  static getString(key: string, fallback: string): string {
    if (Prefs.store === null) {
      return fallback;
    }
    try {
      const value = Prefs.store.getSync(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (error) {
      return fallback;
    }
  }

  static setString(key: string, value: string): void {
    if (Prefs.store === null) {
      return;
    }
    try {
      Prefs.store.putSync(key, value);
      Prefs.store.flush();
    } catch (error) {
      // 存储失败不影响主流程
    }
  }

  static getNumber(key: string, fallback: number): number {
    if (Prefs.store === null) {
      return fallback;
    }
    try {
      const value = Prefs.store.getSync(key, fallback);
      return typeof value === 'number' ? value : fallback;
    } catch (error) {
      return fallback;
    }
  }

  static setNumber(key: string, value: number): void {
    if (Prefs.store === null) {
      return;
    }
    try {
      Prefs.store.putSync(key, value);
      Prefs.store.flush();
    } catch (error) {
      // ignore
    }
  }
}
