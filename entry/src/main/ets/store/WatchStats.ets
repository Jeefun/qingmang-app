/**
 * 观看时长统计：按天累计播放秒数，只在本地记录。
 * 「我的」页用今日 / 本周两个口径展示。
 */
import { Prefs } from './Prefs';

const KEY_DAILY = 'watch_stats_daily';
/** 只保留最近 30 天，防止记录无限增长 */
const KEEP_DAYS = 30;

export class WatchStats {
  /** key=YYYY-MM-DD（本地时区），value=当天累计秒数 */
  private daily: Record<string, number> = {};
  private loaded: boolean = false;
  private dirty: boolean = false;

  private load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw = Prefs.getString(KEY_DAILY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const out: Record<string, number> = {};
      const keys = Object.keys(parsed);
      for (const key of keys) {
        const value = parsed[key];
        if (typeof value === 'number') {
          out[key] = value;
        }
      }
      this.daily = out;
    } catch (error) {
      this.daily = {};
    }
  }

  addSeconds(sec: number): void {
    if (sec <= 0) {
      return;
    }
    this.load();
    const key = WatchStats.dayKey(new Date());
    const current = this.daily[key] ?? 0;
    this.daily[key] = current + sec;
    this.dirty = true;
  }

  /** 落盘；无改动直接返回，避免播放中频繁写偏好库 */
  flush(): void {
    this.load();
    if (!this.dirty) {
      return;
    }
    this.dirty = false;
    const cutoff = Date.now() - KEEP_DAYS * 86400000;
    const kept: Record<string, number> = {};
    const keys = Object.keys(this.daily);
    for (const key of keys) {
      const day = new Date(`${key}T00:00:00`);
      if (!Number.isNaN(day.getTime()) && day.getTime() >= cutoff) {
        kept[key] = this.daily[key] ?? 0;
      }
    }
    this.daily = kept;
    Prefs.setString(KEY_DAILY, JSON.stringify(this.daily));
  }

  todaySeconds(): number {
    this.load();
    return this.daily[WatchStats.dayKey(new Date())] ?? 0;
  }

  /** 最近 7 天（含今天）累计秒数 */
  weekSeconds(): number {
    this.load();
    let sum = 0;
    for (let i = 0; i < 7; i++) {
      const date = new Date();
      date.setDate(date.getDate() - i);
      sum += this.daily[WatchStats.dayKey(date)] ?? 0;
    }
    return sum;
  }

  static dayKey(date: Date): string {
    const month = date.getMonth() + 1;
    const day = date.getDate();
    const monthText = month < 10 ? `0${month}` : `${month}`;
    const dayText = day < 10 ? `0${day}` : `${day}`;
    return `${date.getFullYear()}-${monthText}-${dayText}`;
  }
}
