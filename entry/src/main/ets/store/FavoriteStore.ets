/**
 * 我的收藏。上限 200 条，按收藏时间倒序。
 * 与播放历史分开存：历史是自动记账，收藏是用户主动动作，语义和清理策略都不同。
 */
import { FavoriteItem } from '../model/Models';
import { Prefs } from './Prefs';

const KEY_FAVORITES = 'favorite_list';
const MAX_ITEMS = 200;

export class FavoriteStore {
  private items: FavoriteItem[] = [];
  private loaded: boolean = false;

  load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw = Prefs.getString(KEY_FAVORITES, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Object[];
      const out: FavoriteItem[] = [];
      for (const row of parsed) {
        const record = row as Record<string, Object>;
        const item = new FavoriteItem();
        item.seriesId = typeof record['seriesId'] === 'string' ? record['seriesId'] as string : '';
        item.title = typeof record['title'] === 'string' ? record['title'] as string : '';
        item.cover = typeof record['cover'] === 'string' ? record['cover'] as string : '';
        item.createdAt = typeof record['createdAt'] === 'number' ? record['createdAt'] as number : 0;
        item.pinned = record['pinned'] === true;
        item.group = typeof record['group'] === 'string' ? record['group'] as string : '';
        if (item.seriesId.length > 0) {
          out.push(item);
        }
      }
      this.items = out;
    } catch (error) {
      this.items = [];
    }
  }

  /** 置顶项排最前，其余按收藏时间倒序 */
  list(): FavoriteItem[] {
    this.load();
    const pinned: FavoriteItem[] = [];
    const normal: FavoriteItem[] = [];
    for (const item of this.items) {
      if (item.pinned) {
        pinned.push(item);
      } else {
        normal.push(item);
      }
    }
    return pinned.concat(normal);
  }

  /** 置顶 / 取消置顶 */
  togglePin(seriesId: string): void {
    this.load();
    for (const item of this.items) {
      if (item.seriesId === seriesId) {
        item.pinned = !item.pinned;
        this.persist();
        return;
      }
    }
  }

  /** 设置分组；传空串清除分组 */
  setGroup(seriesId: string, group: string): void {
    this.load();
    for (const item of this.items) {
      if (item.seriesId === seriesId) {
        item.group = group;
        this.persist();
        return;
      }
    }
  }

  /** 已在使用的分组名（去重，按出现顺序） */
  groups(): string[] {
    this.load();
    const out: string[] = [];
    for (const item of this.items) {
      if (item.group.length > 0 && out.indexOf(item.group) < 0) {
        out.push(item.group);
      }
    }
    return out;
  }

  has(seriesId: string): boolean {
    this.load();
    for (const item of this.items) {
      if (item.seriesId === seriesId) {
        return true;
      }
    }
    return false;
  }

  /** 收藏 / 取消收藏切换。返回切换后的收藏状态。 */
  toggle(item: FavoriteItem): boolean {
    this.load();
    if (this.has(item.seriesId)) {
      this.remove(item.seriesId);
      return false;
    }
    item.createdAt = Date.now();
    this.items.unshift(item);
    if (this.items.length > MAX_ITEMS) {
      this.items = this.items.slice(0, MAX_ITEMS);
    }
    this.persist();
    return true;
  }

  remove(seriesId: string): void {
    this.load();
    const next: FavoriteItem[] = [];
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
    this.load();
    this.items = [];
    this.persist();
  }

  private persist(): void {
    Prefs.setString(KEY_FAVORITES, JSON.stringify(this.items));
  }
}
