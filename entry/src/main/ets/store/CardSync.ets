/**
 * 桌面「继续观看」卡片的数据同步。
 *
 * 卡片本身由 EntryFormAbility 提供初始数据；本页播放进度变化后，
 * 通过 formProvider.updateForm 主动把最新一集推给所有已添加的卡片。
 * formId 在 onAddForm 时落 Prefs，删卡片由系统通知 onRemoveForm 清理。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Prefs } from './Prefs';
import { AppState } from './AppState';

const KEY_FORM_IDS = 'card_form_ids';
const TAG = 'QingMangCard';

export class CardSync {
  /** 上次推送时间（毫秒时间戳），90 秒节流，避免进度保存频繁刷卡片 */
  private static lastPush: number = 0;

  private static formIds(): string[] {
    const raw = Prefs.getString(KEY_FORM_IDS, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as Object[];
      const out: string[] = [];
      for (const row of parsed) {
        if (typeof row === 'string' && row.length > 0) {
          out.push(row);
        }
      }
      return out;
    } catch (error) {
      return [];
    }
  }

  static rememberFormId(formId: string): void {
    if (formId.length === 0) {
      return;
    }
    const ids = CardSync.formIds();
    if (ids.indexOf(formId) >= 0) {
      return;
    }
    ids.push(formId);
    Prefs.setString(KEY_FORM_IDS, JSON.stringify(ids));
  }

  static forgetFormId(formId: string): void {
    const ids = CardSync.formIds();
    const next: string[] = [];
    for (const id of ids) {
      if (id !== formId) {
        next.push(id);
      }
    }
    if (next.length !== ids.length) {
      Prefs.setString(KEY_FORM_IDS, JSON.stringify(next));
    }
  }

  /** 卡片展示数据：取最近一条播放历史 */
  static cardData(): Record<string, string | number> {
    const items = AppState.history.list();
    if (items.length === 0) {
      const empty: Record<string, string | number> = {
        'title': '打开青芒，开始追剧',
        'sub': '看过的剧会出现在这里',
        'seriesId': '',
        'episodeIndex': 0,
        'cover': ''
      };
      return empty;
    }
    const latest = items[0];
    const data: Record<string, string | number> = {
      'title': latest.title.length > 0 ? latest.title : '继续上次观看',
      'sub': `第 ${latest.episodeIndex} 集 · 点击继续播放`,
      'seriesId': latest.seriesId,
      'episodeIndex': latest.episodeIndex,
      'cover': latest.cover
    };
    return data;
  }

  /** 有新卡片数据时推给所有已添加的卡片（节流 90 秒） */
  static pushUpdate(force: boolean = false): void {
    const ids = CardSync.formIds();
    if (ids.length === 0) {
      return;
    }
    const now = Date.now();
    if (!force && now - CardSync.lastPush < 90000) {
      return;
    }
    CardSync.lastPush = now;
    for (const id of ids) {
      try {
        formProvider.updateForm(id, formBindingData.createFormBindingData(CardSync.cardData()));
      } catch (error) {
        // 卡片可能已被用户删除（formId 失效），静默忽略
        hilog.warn(0x0001, TAG, `updateForm 失败 id=${id}`);
      }
    }
  }
}
