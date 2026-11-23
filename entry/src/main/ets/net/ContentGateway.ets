/**
 * 内容网关：按活动站源分发请求。
 *
 * 站源有两类：
 *   - 内置内容源：ContentApi 直连（设备注册 / feed / detail / 弹幕 / 取流）；
 *   - 已安装站源模块：ModuleRuntime 沙箱执行 main.js，ModuleApi 映射返回值。
 *
 * 分发规则：
 *   - feed / search / deviceReady：按「当前激活源」分发——首页与搜索天然只看激活源；
 *   - detail / danmaku / playbackVariants：按 seriesId 前缀分发——
 *     模块剧集的 seriesId 统一带 `{moduleId}:` 前缀（见 ModuleApi.mapCard），
 *     历史 / 收藏里的内置剧集 id 是纯数字，不含冒号，切换源后仍走内置源。
 *
 * 模块激活时 deviceReady 恒为 true：模块不需要设备注册，
 * AppState.ensureReady 首判即短路；此时若收到无前缀的内置剧集请求
 * （历史、收藏、收藏更新检查），内置源还没注册过，这里补一次注册。
 */
import { ContentApi } from './ContentApi';
import { ModuleApi } from './ModuleApi';
import { DanmakuComment, DramaDetail, FeedPage, PlaySource } from '../model/Models';
import { SourceRegistry } from '../store/SourceRegistry';

/** 模块剧集 seriesId 的前缀分隔符 */
const MODULE_PREFIX: string = ':';

export class ContentGateway {
  private readonly builtin: ContentApi = new ContentApi();

  get deviceReady(): boolean {
    if (this.activeModuleId().length > 0) {
      return true;
    }
    return this.builtin.deviceReady;
  }

  get errorText(): string {
    return this.builtin.errorText;
  }

  init(): void {
    this.builtin.init();
  }

  /** 设备注册：模块源走 devices(register)，内置源走原生注册 */
  async registerDevice(): Promise<void> {
    const moduleId = this.activeModuleId();
    if (moduleId.length > 0) {
      await ModuleApi.devices(moduleId);
      return;
    }
    await this.builtin.registerDevice();
  }

  /** 首页信息流：激活源为模块时按分类页取，否则内置源 */
  async feed(genreKey: string, scene: string, offset: number,
    sessionId: string, seen: string[]): Promise<FeedPage> {
    const moduleId = this.activeModuleId();
    if (moduleId.length > 0) {
      return ModuleApi.feed(moduleId, genreKey, offset);
    }
    await this.ensureBuiltinReady();
    return this.builtin.feed(genreKey, scene, offset, sessionId, seen);
  }

  /** 剧集详情：按 seriesId 前缀分发，内置剧集在模块激活时补注册 */
  async detail(seriesId: string): Promise<DramaDetail> {
    const moduleId = this.moduleBySeriesId(seriesId);
    if (moduleId.length > 0) {
      return ModuleApi.detail(moduleId, this.stripPrefix(seriesId));
    }
    await this.ensureBuiltinReady();
    return this.builtin.detail(seriesId);
  }

  /** 弹幕：按 seriesId 前缀分发，模块源分页聚合模块弹幕，内置源走原生接口 */
  async danmaku(seriesId: string, vid: string, durationMs: number): Promise<DanmakuComment[]> {
    const moduleId = this.moduleBySeriesId(seriesId);
    if (moduleId.length > 0) {
      return ModuleApi.danmaku(moduleId, this.stripPrefix(seriesId), vid, durationMs);
    }
    await this.ensureBuiltinReady();
    return this.builtin.danmaku(seriesId, vid, durationMs);
  }

  /**
   * 搜索：激活源为模块时按模块搜索。
   * 搜索页的翻页步长固定为 10（内置源约定），模块侧页码 = offset / 10 + 1。
   */
  async search(keyword: string, offset: number, searchId: string): Promise<FeedPage> {
    const moduleId = this.activeModuleId();
    if (moduleId.length > 0) {
      return ModuleApi.search(moduleId, keyword, Math.floor(offset / 10) + 1);
    }
    await this.ensureBuiltinReady();
    return this.builtin.search(keyword, offset, searchId);
  }

  /** 取流：按 seriesId 前缀分发；模块剧集先还原分集上下文再 resolveMedia */
  async playbackVariants(seriesId: string, videoId: string): Promise<PlaySource[]> {
    const moduleId = this.moduleBySeriesId(seriesId);
    if (moduleId.length > 0) {
      return ModuleApi.variants(moduleId, this.stripPrefix(seriesId), videoId);
    }
    await this.ensureBuiltinReady();
    return this.builtin.playbackVariants(seriesId, videoId);
  }

  /** 当前激活源对应的模块 id；内置源或模块未安装时返回空串 */
  private activeModuleId(): string {
    const id: string = SourceRegistry.activeId();
    if (id === SourceRegistry.BUILTIN_ID || !SourceRegistry.isInstalled(id)) {
      return '';
    }
    return id;
  }

  /**
   * seriesId 是否属于某个已安装模块。
   * 前缀（首个冒号之前）命中已安装模块 id 才分发；
   * 内置剧集 id 是纯数字，天然不会命中。
   */
  private moduleBySeriesId(seriesId: string): string {
    const at = seriesId.indexOf(MODULE_PREFIX);
    if (at <= 0) {
      return '';
    }
    const moduleId = seriesId.substring(0, at);
    return SourceRegistry.isInstalled(moduleId) ? moduleId : '';
  }

  private stripPrefix(seriesId: string): string {
    const at = seriesId.indexOf(MODULE_PREFIX);
    if (at <= 0) {
      return seriesId;
    }
    return seriesId.substring(at + MODULE_PREFIX.length);
  }

  /** 模块激活时 ensureReady 会短路，内置剧集的请求在这里补注册（registerDevice 自带并发去重与冷却） */
  private async ensureBuiltinReady(): Promise<void> {
    if (!this.builtin.deviceReady) {
      await this.builtin.registerDevice();
    }
  }
}
