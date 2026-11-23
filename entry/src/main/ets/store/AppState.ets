/**
 * 全局单例：接口客户端与历史存储。页面之间共享同一份实例，
 * 避免重复注册设备导致风控命中。
 */
import { ContentGateway } from '../net/ContentGateway';
import { HistoryStore } from './HistoryStore';
import { SearchHistoryStore } from './SearchHistoryStore';
import { FavoriteStore } from './FavoriteStore';
import { CacheIndex } from './CacheIndex';
import { WatchStats } from './WatchStats';

export class AppState {
  /** 内容网关：内置源直连，站源模块走沙箱运行时，按活动源 / seriesId 前缀分发 */
  static readonly api: ContentGateway = new ContentGateway();
  static readonly history: HistoryStore = new HistoryStore();
  static readonly searchHistory: SearchHistoryStore = new SearchHistoryStore();
  static readonly favorites: FavoriteStore = new FavoriteStore();
  static readonly cacheIndex: CacheIndex = new CacheIndex();
  static readonly watchStats: WatchStats = new WatchStats();
  /** 是否运行在车机（超级桌面虚拟屏）上 */
  static carMode: boolean = false;
  static displayId: number = 0;
  private static ready: Promise<void> | null = null;

  /** 首次使用前确保设备号已就绪；并发调用共享同一个 Promise */
  static ensureReady(): Promise<void> {
    if (AppState.api.deviceReady) {
      return Promise.resolve();
    }
    if (AppState.ready === null) {
      AppState.ready = AppState.api.registerDevice()
        .then(() => {
        })
        .catch((error: Error) => {
          AppState.ready = null;
          throw error;
        });
    }
    return AppState.ready;
  }
}
