/**
 * 播放历史。只保留最近 60 条，按更新时间倒序。
 */
import { HistoryItem } from '../model/Models';
import { Prefs } from './Prefs';

const KEY_HISTORY = 'play_history';
const MAX_ITEMS = 60;

export class HistoryStore {
  private items: HistoryItem[] = [];
  private loaded: boolean = false;

  load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw = Prefs.getString(KEY_HISTORY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Object[];
      const out: HistoryItem[] = [];
      for (const row of parsed) {
        const record = row as Record<string, Object>;
        const item = new HistoryItem();
        item.seriesId = typeof record['seriesId'] === 'string' ? record['seriesId'] as string : '';
        item.title = typeof record['title'] === 'string' ? record['title'] as string : '';
        item.cover = typeof record['cover'] === 'string' ? record['cover'] as string : '';
        item.episodeIndex = typeof record['episodeIndex'] === 'number' ? record['episodeIndex'] as number : 1;
        item.positionMs = typeof record['positionMs'] === 'number' ? record['positionMs'] as number : 0;
        item.durationMs = typeof record['durationMs'] === 'number' ? record['durationMs'] as number : 0;
        item.updatedAt = typeof record['updatedAt'] === 'number' ? record['updatedAt'] as number : 0;
        if (item.seriesId.length > 0) {
          out.push(item);
        }
      }
      this.items = out;
    } catch (error) {
      this.items = [];
    }
  }

  list(): HistoryItem[] {
    this.load();
    return this.items;
  }

  find(seriesId: string): HistoryItem | null {
    this.load();
    for (const item of this.items) {
      if (item.seriesId === seriesId) {
        return item;
      }
    }
    return null;
  }

  record(item: HistoryItem): void {
    this.load();
    const next: HistoryItem[] = [];
    for (const existing of this.items) {
      if (existing.seriesId !== item.seriesId) {
        next.push(existing);
      }
    }
    item.updatedAt = Date.now();
    next.unshift(item);
    this.items = next.slice(0, MAX_ITEMS);
    this.persist();
  }

  /** 删除单条记录（长按菜单用） */
  remove(seriesId: string): void {
    this.load();
    const next: HistoryItem[] = [];
    for (const item of this.items) {
      if (item.seriesId !== seriesId) {
        next.push(item);
      }
    }
    if (next.length !== this.items.length) {
      this.items = next;
      this.persist();
    }
  }

  clear(): void {
    this.items = [];
    this.persist();
  }

  private persist(): void {
    Prefs.setString(KEY_HISTORY, JSON.stringify(this.items));
  }
}
