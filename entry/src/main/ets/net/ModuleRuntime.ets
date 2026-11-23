/**
 * 站源模块运行时。
 *
 * ArkTS 没有 eval，也没有同步 HTTP，而上游模块契约（api:1）要求模块以
 * CommonJS 形式执行、宿主 `host` 全部为同步语义。这里用一个隐藏的 Web
 * 组件（挂在 Index 根 Stack，1x1 透明）做 JS 沙箱：
 *   - 页面 HTML = rawfile 宿主环境（module_host.js）+ 模块 main.js 内联，
 *     经 loadData 加载，baseUrl 设为模块站点 origin，模块内同步 XHR 即为
 *     同域请求，天然带上 cookie / referer，无需 ArkTS 侧同步网络；
 *   - ArkTS → JS：runJavaScript 调 window.__qm.invoke(callId, fn, argsJson)；
 *   - JS → ArkTS：javaScriptProxy 注册的 __qmNative.onResult(callId, ok, payload)
 *     回调，按 callId 唤醒等待中的 Promise；
 *   - 单次调用 45 秒超时；超时后标记页面失效，下次调用重新 loadData 复位
 *     可能卡死的同步请求。
 *
 * 沙箱内宿主实现见 resources/rawfile/module_host.js：md5 / sha / aes /
 * gcm / ecdh / hkdf / gzip 全部纯 JS 实现，fetch 走同步 XHR（同域），
 * 缓存与状态经 __qmNative.persist 写回 filesDir/modules-state。
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'QingMangModule';

/** 单次模块调用超时（毫秒）：同步 XHR 卡死时的兜底 */
const INVOKE_TIMEOUT_MS: number = 45000;
/** 页面加载超时（毫秒） */
const LOAD_TIMEOUT_MS: number = 30000;
/** 等待 Web 组件挂载的超时（毫秒） */
const ATTACH_TIMEOUT_MS: number = 12000;

/** rawfile 里的宿主环境脚本，模块代码替换文件尾部的占位注释 */
const MODULE_PLACEHOLDER: string = '/*__QM_MODULE__*/';

/** 模块运行时状态目录（filesDir 下） */
const STATE_DIR: string = 'modules-state';

/** 沙箱页面 UA：与模块常见的移动端站点预期一致 */
const SANDBOX_UA: string =
  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/** javaScriptProxy 桥对象：页面 JS 通过 __qmNative.onResult 回传结果，persist/log 回写状态与日志 */
export class ModuleBridge {
  onResult(callId: number, ok: boolean, payload: string): void {
    ModuleRuntime.onResult(callId, ok, payload);
  }

  persist(moduleId: string, json: string): void {
    ModuleRuntime.persistState(moduleId, json);
  }

  log(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE-JS] %{public}s', message);
  }
}

/** 一笔在途调用 */
class ModulePending {
  callId: number = 0;
  resolve: (payload: string) => void = (_payload: string) => {
  };
  reject: (error: Error) => void = (_error: Error) => {
  };
  timer: number = -1;
}

export class ModuleRuntime {
  static readonly controller: webview.WebviewController = new webview.WebviewController();
  static readonly bridge: ModuleBridge = new ModuleBridge();

  private static context: common.Context | null = null;
  private static attached: boolean = false;
  private static pageReady: boolean = false;
  private static loadedModuleId: string = '';
  private static callSeq: number = 0;
  private static readonly pending: Map<number, ModulePending> = new Map();
  /** 加载串行化：并发 ensureLoaded 排队执行，避免互相覆盖页面 */
  private static queue: Promise<void> = Promise.resolve();
  /** 当前页面加载完成的唤醒器 */
  private static loadResolve: (() => void) | null = null;
  private static loadTimer: number = -1;

  static setContext(context: common.Context): void {
    ModuleRuntime.context = context;
  }

  /** Index 里 Web 组件的 onControllerAttached 回调 */
  static onControllerAttached(): void {
    ModuleRuntime.attached = true;
    try {
      ModuleRuntime.controller.setCustomUserAgent(SANDBOX_UA);
      hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE] sandbox attached');
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '[MODULE] setCustomUserAgent failed');
    }
  }

  /** Index 里 Web 组件的 onPageEnd 回调：页面（含模块代码）执行完毕 */
  static onPageEnd(): void {
    if (ModuleRuntime.loadResolve !== null) {
      clearTimeout(ModuleRuntime.loadTimer);
      ModuleRuntime.loadTimer = -1;
      const resolve = ModuleRuntime.loadResolve;
      ModuleRuntime.loadResolve = null;
      ModuleRuntime.pageReady = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, '[MODULE] page ready: %{public}s', ModuleRuntime.loadedModuleId);
      resolve();
    }
  }

  /**
   * 调用模块导出的方法。
   * argsJson 是「参数数组的 JSON」：调用方自行 JSON.stringify([arg1, arg2...])，
   * 这样对象参数（如 resolveMedia 的 task）可以原样传递。
   * 返回模块返回值经 JSON 反序列化后的对象。
   */
  static async invoke(moduleId: string, fn: string, argsJson: string): Promise<Object> {
    await ModuleRuntime.ensureLoaded(moduleId);
    ModuleRuntime.callSeq += 1;
    const callId: number = ModuleRuntime.callSeq;
    const script: string =
      `window.__qm.invoke(${callId}, ${JSON.stringify(fn)}, ${JSON.stringify(argsJson)})`;
    return new Promise<Object>((resolve, reject) => {
      const entry = new ModulePending();
      entry.callId = callId;
      entry.resolve = (payload: string) => {
        resolve(JSON.parse(payload) as Object);
      };
      entry.reject = (error: Error) => {
        reject(error);
      };
      entry.timer = setTimeout(() => {
        ModuleRuntime.pending.delete(callId);
        reject(new Error('模块执行超时，请稍后重试'));
        // 沙箱可能被卡死的同步请求占住，标记失效让下次调用重新加载复位
        ModuleRuntime.pageReady = false;
        ModuleRuntime.loadedModuleId = '';
      }, INVOKE_TIMEOUT_MS);
      ModuleRuntime.pending.set(callId, entry);
      ModuleRuntime.controller.runJavaScript(script).catch((error: BusinessError) => {
        const stale = ModuleRuntime.pending.get(callId);
        if (stale !== undefined) {
          clearTimeout(stale.timer);
          ModuleRuntime.pending.delete(callId);
        }
        reject(new Error(`模块调用失败（${error.code}）：${error.message}`));
      });
    });
  }

  /** JS 桥回调入口：ModuleBridge 转发，按 callId 唤醒等待中的调用（勿在 ArkTS 侧直接调用） */
  static onResult(callId: number, ok: boolean, payload: string): void {
    const entry = ModuleRuntime.pending.get(callId);
    if (entry === undefined) {
      return;
    }
    clearTimeout(entry.timer);
    ModuleRuntime.pending.delete(callId);
    if (ok) {
      entry.resolve(payload);
    } else {
      entry.reject(new Error(payload.length > 0 ? payload : '模块执行失败'));
    }
  }

  /** 确保沙箱已加载指定模块；并发调用排队，同一模块只加载一次 */
  private static async ensureLoaded(moduleId: string): Promise<void> {
    if (ModuleRuntime.loadedModuleId === moduleId && ModuleRuntime.pageReady) {
      return;
    }
    const previous = ModuleRuntime.queue;
    let release: () => void = () => {
    };
    ModuleRuntime.queue = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      if (ModuleRuntime.loadedModuleId === moduleId && ModuleRuntime.pageReady) {
        return;
      }
      await ModuleRuntime.doLoad(moduleId);
    } finally {
      release();
    }
  }

  private static async doLoad(moduleId: string): Promise<void> {
    await ModuleRuntime.waitAttached();
    const page = await ModuleRuntime.buildPage(moduleId);
    ModuleRuntime.pageReady = false;
    ModuleRuntime.loadedModuleId = moduleId;

    const ready = new Promise<void>((resolve, reject) => {
      ModuleRuntime.loadResolve = resolve;
      ModuleRuntime.loadTimer = setTimeout(() => {
        ModuleRuntime.loadResolve = null;
        ModuleRuntime.loadTimer = -1;
        reject(new Error('模块加载超时，请稍后重试'));
      }, LOAD_TIMEOUT_MS);
    });

    try {
      ModuleRuntime.controller.loadData(page.html, 'text/html', 'utf-8', page.baseUrl, page.baseUrl);
    } catch (error) {
      clearTimeout(ModuleRuntime.loadTimer);
      ModuleRuntime.loadTimer = -1;
      ModuleRuntime.loadResolve = null;
      ModuleRuntime.loadedModuleId = '';
      const err = error as BusinessError;
      throw new Error(`模块沙箱加载失败（${err.code}）：${err.message}`);
    }
    await ready;
  }

  private static async waitAttached(): Promise<void> {
    let waited = 0;
    while (!ModuleRuntime.attached) {
      if (waited >= ATTACH_TIMEOUT_MS) {
        throw new Error('模块沙箱尚未就绪，请稍后重试');
      }
      await ModuleRuntime.delay(100);
      waited += 100;
    }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 组装沙箱页面：宿主环境 + 模块代码；baseUrl 取模块站点；注入清单与持久化状态 */
  private static async buildPage(moduleId: string): Promise<PageBundle> {
    const context = ModuleRuntime.context;
    if (context === null) {
      throw new Error('模块沙箱尚未初始化');
    }
    const dir: string = `${context.filesDir}/modules/${moduleId}`;
    const manifestPath: string = `${dir}/manifest.json`;
    const mainPath: string = `${dir}/main.js`;
    if (!fs.accessSync(manifestPath) || !fs.accessSync(mainPath)) {
      throw new Error('模块文件缺失，请重新安装');
    }
    const manifestRaw: string = ModuleRuntime.readTextFile(manifestPath);
    const mainJs: string = ModuleRuntime.readTextFile(mainPath);
    let manifest: Record<string, Object> = {};
    let baseUrl: string = '';
    try {
      manifest = JSON.parse(manifestRaw) as Record<string, Object>;
      if (typeof manifest['baseUrl'] === 'string') {
        baseUrl = manifest['baseUrl'] as string;
      }
    } catch (error) {
      manifest = {};
      baseUrl = '';
    }
    if (baseUrl.length === 0) {
      baseUrl = 'about:blank';
    }

    const shim: string = ModuleRuntime.readRawFile(context, 'module_host.js');
    // 用 split/join 替换占位，避免 String.replace 的 $ 模式被模块代码误命中
    const parts: string[] = shim.split(MODULE_PLACEHOLDER);
    if (parts.length < 2) {
      throw new Error('模块宿主环境损坏，请更新应用');
    }
    // </script 会提前终结内联脚本，统一转义；JS 字符串里 <\/script 与 </script 等价
    const safeJs: string = mainJs.split('</script').join('<\\/script');
    const manifestLiteral: string = ModuleRuntime.inlineJsonLiteral(JSON.stringify(manifest));
    const persistLiteral: string = ModuleRuntime.inlineJsonLiteral(ModuleRuntime.readState(moduleId));
    const sourceLine: string = `window.__QM_SOURCE_ID__ = ${JSON.stringify(moduleId)};` +
      `window.__QM_MANIFEST__ = ${manifestLiteral};` +
      `window.__QM_PERSIST__ = ${persistLiteral};`;
    const body: string = `${sourceLine}\n${parts[0]}${safeJs}${parts[1]}`;
    const html: string = `<!DOCTYPE html><html><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width,initial-scale=1"></head>` +
      `<body><script>${body}</script></body></html>`;

    const bundle = new PageBundle();
    bundle.html = html;
    bundle.baseUrl = baseUrl;
    return bundle;
  }

  /**
   * 把 JSON 文本安全地作为内联脚本里的对象字面量：
   * < 转义防 </script> 提前终结，解析失败回退空对象。
   */
  private static inlineJsonLiteral(json: string): string {
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (error) {
      parsed = null;
    }
    if (parsed === null) {
      return '{}';
    }
    return JSON.stringify(parsed).split('<').join('\\u003c');
  }

  /** 写回模块运行时状态（缓存 + states），模块 id 做路径安全校验 */
  static persistState(moduleId: string, json: string): void {
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(moduleId)) {
      return;
    }
    if (json.length > 2 * 1024 * 1024) {
      return;
    }
    const context = ModuleRuntime.context;
    if (context === null) {
      return;
    }
    const dir: string = `${context.filesDir}/${STATE_DIR}`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const file = fs.openSync(`${dir}/${moduleId}.json`,
        fs.OpenMode.READ_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '[MODULE] persist %{public}s failed', moduleId);
    }
  }

  /** 读取模块运行时状态；无状态或损坏时返回 {} */
  static readState(moduleId: string): string {
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(moduleId)) {
      return '{}';
    }
    const context = ModuleRuntime.context;
    if (context === null) {
      return '{}';
    }
    const path: string = `${context.filesDir}/${STATE_DIR}/${moduleId}.json`;
    try {
      if (!fs.accessSync(path)) {
        return '{}';
      }
      return ModuleRuntime.readTextFile(path);
    } catch (error) {
      return '{}';
    }
  }

  /** 删除模块运行时状态（卸载时调用） */
  static deleteState(moduleId: string): void {
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(moduleId)) {
      return;
    }
    const context = ModuleRuntime.context;
    if (context === null) {
      return;
    }
    const path: string = `${context.filesDir}/${STATE_DIR}/${moduleId}.json`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '[MODULE] delete state %{public}s failed', moduleId);
    }
  }

  private static readTextFile(path: string): string {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(path).size;
      const buffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
    } finally {
      fs.closeSync(file);
    }
  }

  private static readRawFile(context: common.Context, name: string): string {
    const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(name);
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }
}

/** 沙箱页面组装结果 */
class PageBundle {
  html: string = '';
  baseUrl: string = 'about:blank';
}
