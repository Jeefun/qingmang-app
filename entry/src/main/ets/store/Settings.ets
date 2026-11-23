/**
 * 用户可调项。全部落 Preferences，重启后保持。
 * 主题不在这里，由 ThemeController 管理。
 */
import { Prefs } from './Prefs';

const KEY_SPEED = 'play_speed';
const KEY_QUALITY = 'play_quality';
const KEY_DANMAKU = 'danmaku_on';
const KEY_DANMAKU_OPACITY = 'danmaku_opacity';
const KEY_DANMAKU_SIZE = 'danmaku_size';
const KEY_DANMAKU_AREA = 'danmaku_area';
const KEY_DANMAKU_DENSITY = 'danmaku_density';
const KEY_DANMAKU_BLOCKED = 'danmaku_blocked_words';
const KEY_DANMAKU_COLOR = 'danmaku_color';
const KEY_DANMAKU_MERGE = 'danmaku_merge';
const KEY_DANMAKU_SPEED = 'danmaku_speed';
const KEY_ACTIVE_SOURCE = 'active_source';
const KEY_BACKGROUND = 'background_play';
const KEY_AUTOPLAY_NEXT = 'auto_next';
const KEY_REDUCE_ALPHA = 'reduce_transparency';
const KEY_REDUCE_MOTION = 'reduce_motion';
const KEY_CACHE_KEEP = 'cache_keep';

export class Settings {
  /** 默认倍速，播放页进入时套用 */
  static speed: number = 1;
  /** auto=自动最高，或具体清晰度 key */
  static quality: string = 'auto';
  static danmaku: boolean = true;
  static danmakuOpacity: number = 0.9;
  /** 弹幕字号（vp）：13 小 / 15 中 / 18 大 */
  static danmakuSize: number = 15;
  /** 弹幕占视频区高度的比例：0.3 上 / 0.55 中 / 1 全屏 */
  static danmakuArea: number = 0.55;
  /** 同屏弹幕上限：6 稀疏 / 12 标准 / 20 密集 */
  static danmakuDensity: number = 12;
  /** 弹幕屏蔽关键词（小写，只影响本机显示，不改数据） */
  static danmakuBlocked: string[] = [];
  /** 弹幕颜色档：0 白 / 1 黄 / 2 青 / 3 粉 / 4 绿，色值表在 PlayerView */
  static danmakuColor: number = 0;
  /** 合并重复弹幕：同文本合并为一条并显示 ×N */
  static danmakuMerge: boolean = true;
  /** 弹幕滚动速度倍数：0.5 ~ 2 */
  static danmakuSpeed: number = 1;
  /** 当前站源 id：builtin 为内置内容源，其余为已安装模块 id */
  static activeSourceId: string = 'builtin';
  static backgroundPlay: boolean = true;
  static autoNext: boolean = true;
  /** 降低透明度：玻璃质感改实色，边框更明确 */
  static reduceTransparency: boolean = false;
  /** 减弱动效：切换与收纳改为淡入淡出 */
  static reduceMotion: boolean = false;
  /** 本地保留多少集解密缓存（超过由播放器按时间淘汰） */
  static cacheKeep: number = 6;

  static load(): void {
    Settings.speed = Prefs.getNumber(KEY_SPEED, 1);
    Settings.quality = Prefs.getString(KEY_QUALITY, 'auto');
    Settings.danmaku = Prefs.getNumber(KEY_DANMAKU, 1) === 1;
    Settings.danmakuOpacity = Prefs.getNumber(KEY_DANMAKU_OPACITY, 0.9);
    Settings.danmakuSize = Prefs.getNumber(KEY_DANMAKU_SIZE, 15);
    Settings.danmakuArea = Prefs.getNumber(KEY_DANMAKU_AREA, 0.55);
    Settings.danmakuDensity = Prefs.getNumber(KEY_DANMAKU_DENSITY, 12);
    Settings.danmakuBlocked = Settings.parseBlocked(Prefs.getString(KEY_DANMAKU_BLOCKED, ''));
    Settings.danmakuColor = Prefs.getNumber(KEY_DANMAKU_COLOR, 0);
    Settings.danmakuMerge = Prefs.getNumber(KEY_DANMAKU_MERGE, 1) === 1;
    Settings.danmakuSpeed = Prefs.getNumber(KEY_DANMAKU_SPEED, 1);
    Settings.activeSourceId = Prefs.getString(KEY_ACTIVE_SOURCE, 'builtin');
    Settings.backgroundPlay = Prefs.getNumber(KEY_BACKGROUND, 1) === 1;
    Settings.autoNext = Prefs.getNumber(KEY_AUTOPLAY_NEXT, 1) === 1;
    Settings.reduceTransparency = Prefs.getNumber(KEY_REDUCE_ALPHA, 0) === 1;
    Settings.reduceMotion = Prefs.getNumber(KEY_REDUCE_MOTION, 0) === 1;
    Settings.cacheKeep = Prefs.getNumber(KEY_CACHE_KEEP, 6);
  }

  static save(): void {
    Prefs.setNumber(KEY_SPEED, Settings.speed);
    Prefs.setString(KEY_QUALITY, Settings.quality);
    Prefs.setNumber(KEY_DANMAKU, Settings.danmaku ? 1 : 0);
    Prefs.setNumber(KEY_DANMAKU_OPACITY, Settings.danmakuOpacity);
    Prefs.setNumber(KEY_DANMAKU_SIZE, Settings.danmakuSize);
    Prefs.setNumber(KEY_DANMAKU_AREA, Settings.danmakuArea);
    Prefs.setNumber(KEY_DANMAKU_DENSITY, Settings.danmakuDensity);
    Prefs.setString(KEY_DANMAKU_BLOCKED, JSON.stringify(Settings.danmakuBlocked));
    Prefs.setNumber(KEY_DANMAKU_COLOR, Settings.danmakuColor);
    Prefs.setNumber(KEY_DANMAKU_MERGE, Settings.danmakuMerge ? 1 : 0);
    Prefs.setNumber(KEY_DANMAKU_SPEED, Settings.danmakuSpeed);
    Prefs.setString(KEY_ACTIVE_SOURCE, Settings.activeSourceId);
    Prefs.setNumber(KEY_BACKGROUND, Settings.backgroundPlay ? 1 : 0);
    Prefs.setNumber(KEY_AUTOPLAY_NEXT, Settings.autoNext ? 1 : 0);
    Prefs.setNumber(KEY_REDUCE_ALPHA, Settings.reduceTransparency ? 1 : 0);
    Prefs.setNumber(KEY_REDUCE_MOTION, Settings.reduceMotion ? 1 : 0);
    Prefs.setNumber(KEY_CACHE_KEEP, Settings.cacheKeep);
  }

  /** 屏蔽词持久化格式与小写归一 */
  private static parseBlocked(raw: string): string[] {
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as Object[];
      const out: string[] = [];
      for (const row of parsed) {
        if (typeof row === 'string' && row.length > 0 && out.indexOf(row) < 0) {
          out.push(row);
        }
      }
      return out;
    } catch (error) {
      return [];
    }
  }

  /** 命中屏蔽词的弹幕文本判定（大小写不敏感，含空格的词按原样匹配） */
  static isDanmakuBlocked(text: string): boolean {
    const lower: string = text.toLowerCase();
    for (const word of Settings.danmakuBlocked) {
      if (word.length > 0 && lower.indexOf(word) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 返回新增是否成功（重复/空串返回 false） */
  static addBlockedWord(word: string): boolean {
    const trimmed: string = word.trim().toLowerCase();
    if (trimmed.length === 0 || Settings.danmakuBlocked.indexOf(trimmed) >= 0) {
      return false;
    }
    Settings.danmakuBlocked.push(trimmed);
    Settings.save();
    return true;
  }

  static removeBlockedWord(word: string): void {
    const next: string[] = [];
    for (const item of Settings.danmakuBlocked) {
      if (item !== word) {
        next.push(item);
      }
    }
    if (next.length !== Settings.danmakuBlocked.length) {
      Settings.danmakuBlocked = next;
      Settings.save();
    }
  }

  /**
   * 倍速文案：统一成一位小数。
   * 整数补 .0（1.0x / 2.0x / 5.0x），小数原样（0.75x / 1.75x / 2.5x），
   * 避免同一排按钮里 2x 和 1.75x 混着显得参差。
   */
  static speedLabel(v: number): string {
    const text: string = `${v}`;
    return text.indexOf('.') < 0 ? `${text}.0x` : `${text}x`;
  }
}
