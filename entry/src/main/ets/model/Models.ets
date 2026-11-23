/**
 * 数据模型。字段与服务端返回结构对齐，只保留端上需要的部分：
 * 剧集、分集、分页信息流、播放源、弹幕。
 *
 * 命名约定：不出现任何第三方平台或商标名称，统一用「内容源 / 上游服务」指代。
 */

export class Drama {
  /** 内容源的剧集 id，纯数字 */
  seriesId: string = '';
  title: string = '';
  cover: string = '';
  description: string = '';
  category: string = '';
  episodeCount: number = 0;
  score: string = '';
  /** 热度文案（模块 drama.heat），如「1.2 亿」 */
  heat: string = '';
  /** 上线日期文案（模块 drama.onlineDate），详情页展示 */
  onlineDate: string = '';
  /** 榜单名次（>0 时卡片左上角出名次角标） */
  rank: number = 0;
  /** 展示用的标签串，以「 · 」连接，见详情页 */
  tags: string = '';
  /**
   * 筛选用的结构化标签。
   * 与 tags 分开存：tags 已经是拼好的字符串，再 split 回来既慢又容易丢分隔符，
   * 筛选逻辑应该直接吃数组（见 model/Tags.ets）。
   */
  tagList: string[] = [];
  /** 竖屏短剧为 true，车机横屏播放时做留白处理 */
  vertical: boolean = false;

  get displayTitle(): string {
    return this.title.length > 0 ? this.title : `短剧 ${this.seriesId}`;
  }

  get displayMeta(): string {
    if (this.episodeCount > 0) {
      return `全 ${this.episodeCount} 集`;
    }
    return this.category;
  }
}

export class Episode {
  /** 集号，从 1 开始 */
  index: number = 1;
  vid: string = '';
  title: string = '';
  vertical: boolean = false;
  /** 音频分集（模块 mediaType: "audio"）：播放时显示封面并隐藏画面比例 */
  audio: boolean = false;
}

export class DramaDetail {
  drama: Drama = new Drama();
  episodes: Episode[] = [];
}

/** 一页信息流。nextOffset / sessionId 用于翻页，缺一不可。 */
export class FeedPage {
  items: Drama[] = [];
  nextOffset: number = 0;
  sessionId: string = '';
  hasMore: boolean = false;
  cellId: string = '';
  showType: string = '';
  /** 榜单页的更新时间文案（模块 rankingPage.updatedText），仅榜单分类有值 */
  updatedText: string = '';
}

/** 榜单（模块 rankings 能力）的一页结果 */
export class RankingPage {
  items: Drama[] = [];
  hasMore: boolean = false;
  totalPages: number = 0;
  updatedText: string = '';
}

/** 一季（模块 seasons 能力）：季号 + 该季的剧 */
export class Season {
  number: number = 0;
  drama: Drama = new Drama();
}

/** 分类频道，key 对应上游内容服务的频道标识。 */
export class Genre {
  key: string = '';
  name: string = '';
  scene: string = '';

  constructor(key: string, name: string, scene: string) {
    this.key = key;
    this.name = name;
    this.scene = scene;
  }
}

export class PlaySource {
  url: string = '';
  referer: string = '';
  quality: number = 0;
  /** CENC 密钥（hex）。为空表示明文直链。 */
  keyHex: string = '';
  /** 原始 spade_a 字段，用于还原 CENC 的 AES-128 密钥 */
  spadeA: string = '';
  /** 是否为加密内容——加密内容当前版本无法直接播放，UI 需提示 */
  get encrypted(): boolean {
    return this.keyHex.length > 0;
  }
}

/**
 * 一条官方弹幕。
 *
 * 只读：来自内容源的评论列表接口（comment_type=20 即弹幕），
 * offsetMs 是弹幕挂在视频时间轴上的毫秒位置，不是发送顺序。
 */
export class DanmakuComment {
  id: string = '';
  text: string = '';
  /** 出现在视频第几毫秒 */
  offsetMs: number = 0;
  /** 点赞数，用于同屏时优先保留高赞 */
  digg: number = 0;
}

/** 一条收藏。只存展示详情卡片所需的最小字段。 */
export class FavoriteItem {
  seriesId: string = '';
  title: string = '';
  cover: string = '';
  createdAt: number = 0;
  /** 置顶：列表里排在最前 */
  pinned: boolean = false;
  /** 分组名，空串表示未分组 */
  group: string = '';
}

export class HistoryItem {
  seriesId: string = '';
  title: string = '';
  cover: string = '';
  episodeIndex: number = 1;
  positionMs: number = 0;
  durationMs: number = 0;
  updatedAt: number = 0;

  get progress(): number {
    if (this.durationMs <= 0) {
      return 0;
    }
    const ratio = this.positionMs / this.durationMs;
    return ratio > 1 ? 1 : ratio;
  }
}

/**
 * 首页栏目，顺序即展示顺序，也决定启动后默认选中的一项（下标 0）。
 * 当前偏好：AI剧 » 漫剧 » 真人剧。
 */
export const GENRES: Genre[] = [
  new Genre('ai_series', 'AI剧', 'ai_series'),
  new Genre('comic_series', '漫剧', 'comic_series'),
  new Genre('short_play', '真人剧', 'default')
];
