/**
 * 搜索历史。只存关键词字符串，最近 12 条、去重、最新的排最前。
 *
 * 和播放历史一样落在 preferences 里：手机关掉重开、流转到车机后，
 * 最近搜过的词还在，用户不用重新打字。
 */
import { Prefs } from './Prefs';

const KEY_SEARCH = 'search_history';
const MAX_ITEMS = 12;

export class SearchHistoryStore {
  private items: string[] = [];
  private loaded: boolean = false;

  load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw = Prefs.getString(KEY_SEARCH, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Object[];
      const out: string[] = [];
      for (const row of parsed) {
        if (typeof row === 'string') {
          const word = (row as string).trim();
          if (word.length > 0 && out.indexOf(word) < 0 && out.length < MAX_ITEMS) {
            out.push(word);
          }
        }
      }
      this.items = out;
    } catch (error) {
      this.items = [];
    }
  }

  list(): string[] {
    this.load();
    return this.items;
  }

  /** 记录一次搜索：已存在的词提到最前，不会重复堆积 */
  add(word: string): void {
    const key = word.trim();
    if (key.length === 0) {
      return;
    }
    this.load();
    const next: string[] = [key];
    for (const existing of this.items) {
      if (existing !== key && next.length < MAX_ITEMS) {
        next.push(existing);
      }
    }
    this.items = next;
    this.persist();
  }

  clear(): void {
    this.items = [];
    this.persist();
  }

  private persist(): void {
    Prefs.setString(KEY_SEARCH, JSON.stringify(this.items));
  }
}
