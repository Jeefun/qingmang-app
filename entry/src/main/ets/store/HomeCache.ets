/**
 * 首页信息流的进程内快照。
 *
 * 为什么需要它：Index 用 if/else 分支切换页面，HomeView 每次切走（切 Tab、
 * 进详情、进播放）都会被销毁重建。列表只放在组件的 @State 里，用户回来时
 * 就必然看到骨架屏并重新打一次 feed 接口，滚动位置也回到顶部。
 * 这里把列表、分页游标、筛选态和滚动位置提到组件生命周期之外，重建时直接回填。
 *
 * 缓存生命周期 = 进程生命周期，会话内不做自动过期：
 *   1. 内容源是推荐流，自动过期后台刷新会重新引入「切回来内容变了 / 位置跳了」，
 *      与「别老刷新」的诉求直接冲突；
 *   2. 冷启动时内存快照本来就是空的，天然会重新拉一次最新数据，已覆盖内容时效；
 *   3. 会话内想主动更新，重复点当前分类 Tab 即为强制刷新（见 HomeView.genreTabs）。
 * 想让冷启动也秒开，需要另做一层磁盘快照，但那会把旧推荐流固化到磁盘，暂不做。
 *
 * 只做内存缓存，不落盘：Drama 是带 getter 的类实例，序列化再还原成本高、容易脏。
 */
import { Drama } from '../model/Models';
import { TAG_ALL } from '../model/Tags';

export class HomeSnapshot {
  items: Drama[] = [];
  /** 分页三件套：少一个都会让「加载更多」从第一页重新开始 */
  nextOffset: number = 0;
  sessionId: string = '';
  seen: string[] = [];
  hasMore: boolean = false;
  /** 当前分类下标与题材筛选，回来时要保持用户上一次的选择 */
  genreIndex: number = 0;
  activeTag: string = TAG_ALL;
  /** 上次滚动偏移，单位 vp */
  scrollY: number = 0;
  /** 数据实际拉取时间，只用于诊断日志，不参与失效判断 */
  fetchedAt: number = 0;
  /** 拉取时激活的站源 id：切源后旧快照直接作废重新拉取 */
  sourceId: string = 'builtin';
}

export class HomeCache {
  private static snap: HomeSnapshot | null = null;

  static get(): HomeSnapshot | null {
    return HomeCache.snap;
  }

  /** 只保存引用；fetchedAt 由 HomeView 在请求成功后显式写入 */
  static save(s: HomeSnapshot): void {
    HomeCache.snap = s;
  }
}
