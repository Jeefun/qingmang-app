/**
 * 站源模块适配层：把模块（api:1）返回的 JSON 映射到应用数据模型。
 *
 * 模块返回形状（对象字段由模块约定，全部按可选处理、逐层判空）：
 *   - 分类：[{ id, name }]（categories(force)，可返回 { items, incomplete }）
 *   - 目录/搜索：{ items: [卡片], hasMore, warning }
 *   - 详情：{ drama: 卡片, chapters: [章节] }
 *   - 取流：{ url, referer, cencKey?, durationMs?, variants?: [{ url, referer, cencKey? }] }
 *   - 弹幕：danmakuIds(task) → { series, video } | null；
 *     danmaku(series, video, startMs, durationMs) → { items: [{ id, text, timeMs }], nextMs }
 *
 * ID 约定（与模块侧 host.dramaId / splitDramaId 对齐）：
 *   - 应用内剧集 seriesId = "{moduleId}:{sourceId}"（首个冒号前是模块 id）；
 *   - resolveMedia / danmakuIds 的 task.dramaId = "{moduleId}:{sourceId}"，
 *     模块按第一个冒号拆出 host.source 与 sourceId；
 *   - 分集 vid 即章节 id，detail 时缓存「vid → 章节 JSON」供取流与弹幕重建 task。
 *
 * cencKey 兼容 32 位 hex 与 Base64（16 字节）两种写法，统一归一为 32 位 hex。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { DanmakuComment, Drama, DramaDetail, Episode, FeedPage, Genre, PlaySource } from '../model/Models';
import { ModuleRuntime } from './ModuleRuntime';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'QingMangModule';

/** 章节缓存上限：超过即整表清空，避免长会话内存无界增长 */
const CHAPTER_CACHE_LIMIT: number = 400;
/** 弹幕分页上限：页数与总条数双保险，防模块死循环 */
const DANMAKU_PAGE_LIMIT: number = 240;
const DANMAKU_ITEM_LIMIT: number = 5000;

export class ModuleApi {
  /** vid（章节 id）→ 章节 JSON，resolveMedia / danmaku 重建 task 用 */
  private static readonly chapters: Map<string, Object> = new Map();

  /** 模块分类列表。force 为 true 时模块应跳过自身缓存重取 */
  static async categories(moduleId: string, force: boolean = false): Promise<Genre[]> {
    const result = await ModuleRuntime.invoke(moduleId, 'categories', JSON.stringify([force]));
    const rows: Object[] = ModuleApi.itemsOf(result);
    const out: Genre[] = [];
    for (const row of rows) {
      const record = ModuleApi.asRecord(row);
      if (record === null) {
        continue;
      }
      const key = ModuleApi.pickString(record, ['id', 'key']);
      const name = ModuleApi.pickString(record, ['name', 'title']);
      if (key.length > 0 && name.length > 0) {
        out.push(new Genre(key, name, ''));
      }
    }
    return out;
  }

  /** 模块目录页。offset 即页码（1 起），hasMore 时下一页 = 当前页 + 1 */
  static async feed(moduleId: string, categoryKey: string, offset: number): Promise<FeedPage> {
    const page: number = offset <= 0 ? 1 : offset;
    const result = await ModuleRuntime.invoke(moduleId, 'catalogPage',
      JSON.stringify([page, categoryKey]));
    const record = ModuleApi.asRecord(result);
    const hasMore: boolean = record !== null && record['hasMore'] === true;
    const dramas: Drama[] = ModuleApi.mapCards(moduleId, record === null ? undefined : record['items']);
    if (dramas.length === 0) {
      throw new Error('这一分类暂时没有内容');
    }
    const feed = new FeedPage();
    feed.items = dramas;
    feed.hasMore = hasMore;
    feed.nextOffset = hasMore ? page + 1 : 0;
    feed.sessionId = '';
    hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE] feed %{public}s page=%{public}d items=%{public}d',
      moduleId, page, dramas.length);
    return feed;
  }

  /** 模块搜索。offset 即页码（1 起） */
  static async search(moduleId: string, keyword: string, offset: number): Promise<FeedPage> {
    const page: number = offset <= 0 ? 1 : offset;
    const result = await ModuleRuntime.invoke(moduleId, 'search',
      JSON.stringify([page, keyword]));
    const record = ModuleApi.asRecord(result);
    const hasMore: boolean = record !== null && record['hasMore'] === true;
    const dramas: Drama[] = ModuleApi.mapCards(moduleId, record === null ? undefined : record['items']);
    const feed = new FeedPage();
    feed.items = dramas;
    feed.hasMore = hasMore && dramas.length > 0;
    feed.nextOffset = feed.hasMore ? page + 1 : 0;
    feed.sessionId = '';
    hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE] search %{public}s page=%{public}d items=%{public}d',
      moduleId, page, dramas.length);
    return feed;
  }

  /** 模块详情：卡片 + 章节列表，章节 id 即分集 vid */
  static async detail(moduleId: string, sourceId: string): Promise<DramaDetail> {
    const result = await ModuleRuntime.invoke(moduleId, 'detail',
      JSON.stringify([sourceId]));
    const record = ModuleApi.asRecord(result);
    if (record === null) {
      throw new Error('模块未返回详情数据');
    }
    const drama = ModuleApi.mapCard(moduleId, record['drama']);
    if (drama === null) {
      throw new Error('详情缺少剧集信息');
    }
    const detail = new DramaDetail();
    detail.drama = drama;

    const episodes: Episode[] = [];
    let sequence = 0;
    for (const row of ModuleApi.asArray(record['chapters'])) {
      const chapter = ModuleApi.asRecord(row);
      if (chapter === null) {
        continue;
      }
      const chapterId = ModuleApi.pickString(chapter, ['id']);
      if (chapterId.length === 0) {
        continue;
      }
      sequence += 1;
      const claimed = ModuleApi.pickNumber(chapter, ['currentEpisode', 'index']);
      let index = claimed >= 1 ? claimed : sequence;
      // 集号重复或越界时回退为顺序号，保证播放器按 index 取集不越界
      if (index > 100000) {
        index = sequence;
      }
      const episode = new Episode();
      episode.index = index;
      episode.vid = chapterId;
      episode.title = ModuleApi.pickString(chapter, ['title']);
      if (episode.title.length === 0) {
        episode.title = `第${index}集`;
      }
      episode.vertical = false;
      episode.audio = ModuleApi.pickString(chapter, ['mediaType']) === 'audio';
      episodes.push(episode);
      ModuleApi.cacheChapter(chapterId, row);
    }
    episodes.sort((left: Episode, right: Episode) => left.index - right.index);
    detail.episodes = episodes;
    if (episodes.length === 0) {
      throw new Error('该剧集没有可播放的分集');
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE] detail %{public}s episodes=%{public}d',
      sourceId, episodes.length);
    return detail;
  }

  /**
   * 模块取流：resolveMedia(task) → PlaySource 列表。
   * 模块可返回多线路 variants，每条独立归一 cencKey。
   */
  static async variants(moduleId: string, sourceId: string, vid: string): Promise<PlaySource[]> {
    const chapter = ModuleApi.chapters.get(vid);
    if (chapter === undefined) {
      throw new Error('播放分集信息缺失，请重新进入详情页');
    }
    const task: Record<string, Object> = {
      'dramaId': `${moduleId}:${sourceId}` as Object,
      'chapter': chapter
    };
    const result = await ModuleRuntime.invoke(moduleId, 'resolveMedia', JSON.stringify([task]));
    const record = ModuleApi.asRecord(result);
    if (record === null) {
      throw new Error('模块未返回播放地址');
    }
    const sources: PlaySource[] = [];
    for (const row of ModuleApi.asArray(record['variants'])) {
      const source = ModuleApi.playSourceOf(row);
      if (source !== null) {
        sources.push(source);
      }
    }
    if (sources.length === 0) {
      const single = ModuleApi.playSourceOf(result);
      if (single === null) {
        throw new Error('该集没有可用播放地址');
      }
      sources.push(single);
    }
    return sources;
  }

  /**
   * 模块弹幕：danmakuIds(task) 解析出站点侧 series/video，
   * 按 startMs → nextMs 分页拉取 danmaku(series, video, startMs, durationMs)，
   * 按 id 去重、时间轴升序。模块不支持弹幕（danmakuIds 为 null）返回空列表。
   */
  static async danmaku(moduleId: string, sourceId: string, vid: string,
    durationMs: number): Promise<DanmakuComment[]> {
    const chapter = ModuleApi.chapters.get(vid);
    if (chapter === undefined || durationMs <= 0) {
      return [];
    }
    const task: Record<string, Object> = {
      'dramaId': `${moduleId}:${sourceId}` as Object,
      'chapter': chapter
    };
    let ids: Record<string, Object> | null = null;
    try {
      ids = ModuleApi.asRecord(await ModuleRuntime.invoke(moduleId, 'danmakuIds',
        JSON.stringify([task])));
    } catch (error) {
      return [];
    }
    if (ids === null) {
      return [];
    }
    const series = ModuleApi.pickString(ids, ['series']);
    const video = ModuleApi.pickString(ids, ['video']);
    if (series.length === 0 || video.length === 0) {
      return [];
    }
    const comments: DanmakuComment[] = [];
    const seen = new Set<string>();
    let startMs = 0;
    for (let page = 0; page < DANMAKU_PAGE_LIMIT && comments.length < DANMAKU_ITEM_LIMIT; page++) {
      let result: Record<string, Object> | null = null;
      try {
        result = ModuleApi.asRecord(await ModuleRuntime.invoke(moduleId, 'danmaku',
          JSON.stringify([series, video, startMs, Math.round(durationMs)])));
      } catch (error) {
        break;
      }
      if (result === null) {
        break;
      }
      for (const row of ModuleApi.asArray(result['items'])) {
        const record = ModuleApi.asRecord(row);
        if (record === null) {
          continue;
        }
        const id = ModuleApi.pickString(record, ['id']);
        if (id.length === 0 || seen.has(id)) {
          continue;
        }
        seen.add(id);
        const comment = new DanmakuComment();
        comment.id = id;
        comment.text = ModuleApi.pickString(record, ['text']);
        comment.offsetMs = ModuleApi.pickNumber(record, ['timeMs', 'offsetMs']);
        comments.push(comment);
        if (comments.length >= DANMAKU_ITEM_LIMIT) {
          break;
        }
      }
      const nextMs = ModuleApi.pickNumber(result, ['nextMs']);
      if (nextMs <= startMs || nextMs >= durationMs) {
        break;
      }
      startMs = nextMs;
    }
    comments.sort((left: DanmakuComment, right: DanmakuComment) => left.offsetMs - right.offsetMs);
    hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE] danmaku %{public}s video=%{public}s items=%{public}d',
      moduleId, video, comments.length);
    return comments;
  }

  /** 模块设备注册（devices 能力）：返回是否就绪，失败按未就绪处理 */
  static async devices(moduleId: string): Promise<boolean> {
    try {
      const result = await ModuleRuntime.invoke(moduleId, 'devices', '[true]');
      return typeof result === 'boolean' && result;
    } catch (error) {
      return false;
    }
  }

  private static cacheChapter(vid: string, chapter: Object): void {
    if (ModuleApi.chapters.size > CHAPTER_CACHE_LIMIT) {
      ModuleApi.chapters.clear();
    }
    ModuleApi.chapters.set(vid, chapter);
  }

  /** 媒体 JSON → PlaySource；缺 url 返回 null。cencKey 兼容 hex / Base64(16 字节) */
  private static playSourceOf(raw: Object | undefined): PlaySource | null {
    const record = ModuleApi.asRecord(raw);
    if (record === null) {
      return null;
    }
    const url = ModuleApi.pickString(record, ['url']);
    if (url.length === 0) {
      return null;
    }
    const source = new PlaySource();
    source.url = url;
    source.referer = ModuleApi.pickString(record, ['referer', 'referrer']);
    source.quality = ModuleApi.pickNumber(record, ['quality', 'height']);
    source.keyHex = ModuleApi.normalizeCencKey(ModuleApi.pickString(record, ['cencKey', 'hlsKey', 'key']));
    source.spadeA = '';
    return source;
  }

  /** cencKey 归一：32 位 hex 直用（转小写），否则按 Base64 解出 16 字节转 hex，失败返回空串 */
  private static normalizeCencKey(value: string): string {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (/^[0-9a-fA-F]{32}$/.test(trimmed)) {
      return trimmed.toLowerCase();
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(trimmed);
      if (bytes.length !== 16) {
        return '';
      }
      let hex = '';
      for (let i = 0; i < bytes.length; i++) {
        hex += bytes[i] < 16 ? `0${bytes[i].toString(16)}` : bytes[i].toString(16);
      }
      return hex;
    } catch (error) {
      return '';
    }
  }

  private static mapCards(moduleId: string, raw: Object | undefined): Drama[] {
    const out: Drama[] = [];
    const seen = new Set<string>();
    for (const row of ModuleApi.itemsOf(raw)) {
      const drama = ModuleApi.mapCard(moduleId, row);
      if (drama !== null && drama.seriesId.length > 0 && !seen.has(drama.seriesId)) {
        seen.add(drama.seriesId);
        out.push(drama);
      }
    }
    return out;
  }

  /** 模块卡片/详情 drama JSON → 应用 Drama。无冒号的裸 id 补 {moduleId}: 前缀 */
  private static mapCard(moduleId: string, raw: Object | undefined): Drama | null {
    const record = ModuleApi.asRecord(raw);
    if (record === null) {
      return null;
    }
    const drama = new Drama();
    let seriesId = ModuleApi.pickString(record, ['id', 'dramaId']);
    const sourceId = ModuleApi.pickString(record, ['sourceId']);
    if (seriesId.length === 0) {
      seriesId = sourceId;
    }
    if (seriesId.length === 0) {
      return null;
    }
    if (seriesId.indexOf(':') < 0) {
      seriesId = `${moduleId}:${seriesId}`;
    }
    drama.seriesId = seriesId;
    drama.title = ModuleApi.pickString(record, ['title', 'name']);
    drama.cover = ModuleApi.pickString(record, ['cover', 'coverUrl']);
    drama.description = ModuleApi.pickString(record, ['desc', 'intro']);
    drama.category = ModuleApi.pickString(record, ['categoryName', 'channelName']);
    drama.episodeCount = ModuleApi.pickNumber(record, ['episodeCount', 'totalEpisode']);
    drama.score = ModuleApi.pickString(record, ['score']);
    const tags: string[] = [];
    for (const tag of ModuleApi.asArray(record['tags'])) {
      if (typeof tag === 'string' && tag.length > 0 && !tags.includes(tag)) {
        tags.push(tag);
      }
    }
    drama.tags = tags.join(' · ');
    drama.tagList = tags;
    const remark = ModuleApi.pickString(record, ['remark']);
    if (drama.score.length === 0 && remark.length > 0) {
      drama.score = remark;
    }
    return drama;
  }

  // ---------- JSON 取值工具（模块返回不透明，逐层判空） ----------

  /** 分类结果兼容数组与 { items, incomplete } 两种形状 */
  private static itemsOf(result: Object | undefined): Object[] {
    const record = ModuleApi.asRecord(result);
    if (record !== null) {
      return ModuleApi.asArray(record['items']);
    }
    return ModuleApi.asArray(result);
  }

  private static asRecord(value: Object | undefined | null): Record<string, Object> | null {
    if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  private static asArray(value: Object | undefined | null): Object[] {
    if (value === null || value === undefined || !Array.isArray(value)) {
      return [];
    }
    return value as Object[];
  }

  private static pickString(record: Record<string, Object> | null, keys: string[]): string {
    if (record === null) {
      return '';
    }
    for (const key of keys) {
      const value = record[key];
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
      if (typeof value === 'number' && isFinite(value)) {
        return value.toString();
      }
    }
    return '';
  }

  private static pickNumber(record: Record<string, Object> | null, keys: string[]): number {
    if (record === null) {
      return 0;
    }
    for (const key of keys) {
      const value = record[key];
      if (typeof value === 'number' && isFinite(value)) {
        return value;
      }
      if (typeof value === 'string' && value.length > 0 && isFinite(Number(value))) {
        return Number(value);
      }
    }
    return 0;
  }
}
