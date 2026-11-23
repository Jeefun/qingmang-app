/**
 * 已缓存剧集的索引（台账）。
 *
 * 播放器落盘的解密分片只有 `ep_{vid}_{quality}.mp4` 一个文件名，
 * 「我的 → 存储」要展示剧名、集号就得另存一份元数据。
 * 真实文件始终以 cacheDir 为准：索引里可能有过期条目（文件被系统清理），
 * 消费方展示前按文件存在性过滤即可，不做强一致。
 */
import { Prefs } from './Prefs';

export class CachedEpisode {
  vid: string = '';
  quality: number = 0;
  seriesId: string = '';
  title: string = '';
  episodeIndex: number = 1;
  createdAt: number = 0;

  get fileName(): string {
    return `ep_${this.vid}_${this.quality}.mp4`;
  }
}

const KEY_CACHE_INDEX = 'cache_index';
const MAX_ENTRIES = 64;

export class CacheIndex {
  private items: CachedEpisode[] = [];
  private loaded: boolean = false;

  load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw = Prefs.getString(KEY_CACHE_INDEX, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Object[];
      const out: CachedEpisode[] = [];
      for (const row of parsed) {
        const record = row as Record<string, Object>;
        const item = new CachedEpisode();
        item.vid = typeof record['vid'] === 'string' ? record['vid'] as string : '';
        item.quality = typeof record['quality'] === 'number' ? record['quality'] as number : 0;
        item.seriesId = typeof record['seriesId'] === 'string' ? record['seriesId'] as string : '';
        item.title = typeof record['title'] === 'string' ? record['title'] as string : '';
        item.episodeIndex = typeof record['episodeIndex'] === 'number'
          ? record['episodeIndex'] as number : 1;
        item.createdAt = typeof record['createdAt'] === 'number' ? record['createdAt'] as number : 0;
        if (item.vid.length > 0) {
          out.push(item);
        }
      }
      this.items = out;
    } catch (error) {
      this.items = [];
    }
  }

  list(): CachedEpisode[] {
    this.load();
    return this.items;
  }

  /** 记录 / 更新一条缓存（按 vid + quality 去重） */
  record(entry: CachedEpisode): void {
    this.load();
    const next: CachedEpisode[] = [];
    for (const existing of this.items) {
      if (existing.vid !== entry.vid || existing.quality !== entry.quality) {
        next.push(existing);
      }
    }
    entry.createdAt = Date.now();
    next.unshift(entry);
    this.items = next.slice(0, MAX_ENTRIES);
    this.persist();
  }

  remove(vid: string, quality: number): void {
    this.load();
    const next: CachedEpisode[] = [];
    for (const item of this.items) {
      if (item.vid !== vid || item.quality !== quality) {
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
    Prefs.setString(KEY_CACHE_INDEX, JSON.stringify(this.items));
  }
}
