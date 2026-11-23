/**
 * 收藏剧集更新提醒。
 *
 * 打开应用时（节流 15 分钟）逐个拉收藏剧的详情，对比 Prefs 里记着的
 * 「上次已知集数」：变多了就发一条本地通知。通知点击只拉起应用，
 * 落地页由通知参数后续接续（当前版本仅提醒）。
 */
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from './Prefs';
import { AppState } from './AppState';
import { common } from '@kit.AbilityKit';

const KEY_KNOWN_COUNTS = 'fav_ep_counts';
const KEY_LAST_CHECK = 'update_check_ts';
/** 节流：两次检查至少间隔 15 分钟 */
const CHECK_INTERVAL_MS: number = 15 * 60 * 1000;
/** 单轮最多检查的收藏数，防止收藏过多时启动风暴 */
const MAX_CHECK: number = 10;
const TAG = 'QingMangUpdate';

export class UpdateNotify {
  /** 上次授权请求是否已发起过（会话内只问一次） */
  private static authAsked: boolean = false;

  private static readCounts(): Record<string, number> {
    const raw = Prefs.getString(KEY_KNOWN_COUNTS, '');
    const out: Record<string, number> = {};
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const keys = Object.keys(parsed);
      for (const key of keys) {
        const value = parsed[key];
        if (typeof value === 'number') {
          out[key] = value;
        }
      }
    } catch (error) {
      // 损坏数据当作空处理
    }
    return out;
  }

  private static writeCounts(counts: Record<string, number>): void {
    Prefs.setString(KEY_KNOWN_COUNTS, JSON.stringify(counts));
  }

  /** 应用启动后调用：有新集就发通知（内部节流，重复调用安全） */
  static async check(context: common.UIAbilityContext): Promise<void> {
    const now = Date.now();
    const last = Prefs.getNumber(KEY_LAST_CHECK, 0);
    if (now - last < CHECK_INTERVAL_MS) {
      return;
    }
    Prefs.setNumber(KEY_LAST_CHECK, now);

    const favorites = AppState.favorites.list();
    if (favorites.length === 0) {
      return;
    }
    try {
      await AppState.ensureReady();
    } catch (error) {
      return;
    }
    await UpdateNotify.ensureAuth(context);

    const counts = UpdateNotify.readCounts();
    let changed = false;
    let checked = 0;
    for (const fav of favorites) {
      if (checked >= MAX_CHECK) {
        break;
      }
      checked++;
      try {
        const detail = await AppState.api.detail(fav.seriesId);
        const count = detail.episodes.length;
        const key = fav.seriesId;
        const known = counts[key];
        if (known !== undefined && count > known) {
          UpdateNotify.publish(fav.title, count);
        }
        if (counts[key] !== count) {
          counts[key] = count;
          changed = true;
        }
      } catch (error) {
        // 单部失败不影响其他收藏的检查
      }
    }
    if (changed) {
      UpdateNotify.writeCounts(counts);
    }
  }

  /** 通知授权：拒绝过就不再骚扰，会话内只问一次 */
  private static async ensureAuth(context: common.UIAbilityContext): Promise<void> {
    if (UpdateNotify.authAsked) {
      return;
    }
    UpdateNotify.authAsked = true;
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (error) {
      hilog.warn(0x0001, TAG, '通知授权被拒绝，更新提醒不可用');
    }
  }

  private static publish(title: string, episodeCount: number): void {
    try {
      const name = title.length > 0 ? title : '你收藏的剧';
      const basic: notificationManager.NotificationBasicContent = {
        title: `${name} 更新啦`,
        text: `已更新到第 ${episodeCount} 集，快来看`,
        additionalText: '青芒短视频'
      };
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: basic
      };
      const request: notificationManager.NotificationRequest = {
        id: UpdateNotify.hashId(name),
        label: 'fav_update',
        content: content
      };
      notificationManager.publish(request);
      hilog.info(0x0001, TAG, `已发布更新通知：${name} → ${episodeCount} 集`);
    } catch (error) {
      hilog.warn(0x0001, TAG, '发布通知失败');
    }
  }

  private static hashId(text: string): number {
    let hash = 0;
    for (let i = 0; i < text.length; i++) {
      hash = (hash * 31 + text.charCodeAt(i)) % 100000;
    }
    return hash;
  }
}
