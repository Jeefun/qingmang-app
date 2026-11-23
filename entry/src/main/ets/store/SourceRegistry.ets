/**
 * 站源注册表：内置源 + 上游模块仓库（索引拉取 / 安装 / 卸载 / sha256 校验）。
 *
 * 上游索引在模块索引仓库的 index.json（raw 与 jsDelivr 双通道）；
 * 模块文件按 {repo}/{tag} 定位。安装结果落在 files/modules/{id}/，
 * 已安装列表持久化到 Prefs。
 *
 * 模块由应用内隐藏 Web 沙箱执行（net/ModuleRuntime.ets），
 * 已安装模块即可激活取流，首页「切换站源」里可直接选用。
 */
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { httpRequest } from '../net/Http';
import { ModuleRuntime } from '../net/ModuleRuntime';
import { InstalledModule, ModuleIndexEntry, ModuleManifest, ModuleRanking, SourceInfo } from '../model/SourceModels';
import { Prefs } from './Prefs';
import { Settings } from './Settings';

const KEY_INSTALLED = 'installed_modules';

/** 索引地址：raw 优先，jsDelivr 兜底（部分网络环境 raw 不通） */
const INDEX_URLS: string[] = [
  'https://raw.githubusercontent.com/guoapp-modules/index/main/index.json',
  'https://cdn.jsdelivr.net/gh/guoapp-modules/index@main/index.json'
];

/** 已安装模块列表文件名 */
const MODULE_FILES: string[] = ['manifest.json', 'main.js'];

export class SourceRegistry {
  static readonly BUILTIN_ID: string = 'builtin';
  static readonly BUILTIN_NAME: string = '内置内容源';

  private static cache: InstalledModule[] | null = null;

  /** 已安装模块（持久化列表，按安装时间倒序） */
  static installed(): InstalledModule[] {
    if (SourceRegistry.cache !== null) {
      return SourceRegistry.cache;
    }
    const raw: string = Prefs.getString(KEY_INSTALLED, '');
    const out: InstalledModule[] = [];
    if (raw.length > 0) {
      try {
        const parsed = JSON.parse(raw) as Object[];
        for (const row of parsed) {
          const record = row as Record<string, Object>;
          const item = new InstalledModule();
          item.id = typeof record['id'] === 'string' ? record['id'] as string : '';
          item.name = typeof record['name'] === 'string' ? record['name'] as string : '';
          item.version = typeof record['version'] === 'string' ? record['version'] as string : '';
          item.description = typeof record['description'] === 'string' ? record['description'] as string : '';
          item.adult = record['adult'] === true;
          item.installedAt = typeof record['installedAt'] === 'number' ? record['installedAt'] as number : 0;
          if (record['aliases'] instanceof Array) {
            for (const alias of record['aliases'] as Object[]) {
              if (typeof alias === 'string' && (alias as string).length > 0) {
                item.aliases.push(alias as string);
              }
            }
          }
          if (record['capabilities'] instanceof Array) {
            for (const capability of record['capabilities'] as Object[]) {
              if (typeof capability === 'string' && (capability as string).length > 0) {
                item.capabilities.push(capability as string);
              }
            }
          }
          if (record['rankings'] instanceof Array) {
            for (const row of record['rankings'] as Object[]) {
              if (typeof row !== 'object' || row === null || Array.isArray(row)) {
                continue;
              }
              const board = row as Record<string, Object>;
              const ranking = new ModuleRanking();
              ranking.id = typeof board['id'] === 'string' ? board['id'] as string : '';
              ranking.name = typeof board['name'] === 'string' ? board['name'] as string : '';
              ranking.description = typeof board['description'] === 'string' ? board['description'] as string : '';
              if (ranking.id.length > 0 && ranking.name.length > 0) {
                item.rankings.push(ranking);
              }
            }
          }
          if (item.id.length > 0) {
            out.push(item);
          }
        }
      } catch (error) {
        out.length = 0;
      }
    }
    SourceRegistry.cache = out;
    return out;
  }

  static isInstalled(id: string): boolean {
    for (const item of SourceRegistry.installed()) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  private static saveInstalled(list: InstalledModule[]): void {
    SourceRegistry.cache = list;
    Prefs.setString(KEY_INSTALLED, JSON.stringify(list));
  }

  /** 切换面板用的统一站源列表：内置源在前，已安装模块随后 */
  static sources(): SourceInfo[] {
    const out: SourceInfo[] = [];
    const builtin = new SourceInfo();
    builtin.id = SourceRegistry.BUILTIN_ID;
    builtin.name = SourceRegistry.BUILTIN_NAME;
    builtin.description = '默认内容源，开箱即用';
    builtin.kind = 'builtin';
    builtin.runnable = true;
    out.push(builtin);
    for (const module of SourceRegistry.installed()) {
      const info = new SourceInfo();
      info.id = module.id;
      info.name = module.name;
      info.description = module.description;
      info.kind = 'module';
      info.runnable = true;
      info.adult = module.adult;
      out.push(info);
    }
    return out;
  }

  static activeId(): string {
    return Settings.activeSourceId;
  }

  /** 按 id 取已安装模块记录；未安装返回 null */
  static moduleById(id: string): InstalledModule | null {
    for (const item of SourceRegistry.installed()) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  /** 当前激活站的展示名：模块按安装信息取名，回落内置名 */
  static activeName(): string {
    const id: string = SourceRegistry.activeId();
    for (const info of SourceRegistry.sources()) {
      if (info.id === id) {
        return info.name;
      }
    }
    return SourceRegistry.BUILTIN_NAME;
  }

  /** 激活站源：内置源或已安装模块均可 */
  static activate(id: string): boolean {
    if (id === SourceRegistry.BUILTIN_ID || SourceRegistry.isInstalled(id)) {
      Settings.activeSourceId = id;
      Settings.save();
      return true;
    }
    return false;
  }

  /** 已装模块数是否非零：Index 据此挂载沙箱 Web 组件（AppStorage 'modulesPresent'） */
  static syncModulesPresent(): void {
    AppStorage.setOrCreate('modulesPresent', SourceRegistry.installed().length > 0);
  }

  /** 拉取在线模块索引（raw / jsDelivr 双通道，先成先得） */
  static async fetchIndex(): Promise<ModuleIndexEntry[]> {
    let lastError: Error = new Error('索引拉取失败');
    for (const url of INDEX_URLS) {
      try {
        const response = await httpRequest(url, http.RequestMethod.GET, {}, null, 15000);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = new Error(`索引响应异常（${response.statusCode}）`);
          continue;
        }
        return SourceRegistry.parseIndex(response.body);
      } catch (error) {
        lastError = error as Error;
      }
    }
    throw lastError;
  }

  private static parseIndex(body: string): ModuleIndexEntry[] {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const modulesRaw = parsed['modules'];
    if (!(modulesRaw instanceof Array)) {
      throw new Error('索引格式不正确');
    }
    const out: ModuleIndexEntry[] = [];
    for (const row of modulesRaw as Object[]) {
      const record = row as Record<string, Object>;
      const entry = new ModuleIndexEntry();
      entry.id = typeof record['id'] === 'string' ? record['id'] as string : '';
      entry.name = typeof record['name'] === 'string' ? record['name'] as string : '';
      entry.version = typeof record['version'] === 'string' ? record['version'] as string : '';
      entry.description = typeof record['description'] === 'string' ? record['description'] as string : '';
      entry.api = typeof record['api'] === 'number' ? record['api'] as number : 1;
      entry.adult = record['adult'] === true;
      entry.repo = typeof record['repo'] === 'string' ? record['repo'] as string : '';
      entry.tag = typeof record['tag'] === 'string' ? record['tag'] as string : '';
      const shaRaw = record['sha256'];
      if (shaRaw !== undefined && shaRaw !== null) {
        const shaRecord = shaRaw as Record<string, Object>;
        entry.shaManifest = typeof shaRecord['manifest.json'] === 'string'
          ? shaRecord['manifest.json'] as string : '';
        entry.shaMain = typeof shaRecord['main.js'] === 'string' ? shaRecord['main.js'] as string : '';
      }
      if (entry.id.length > 0 && entry.repo.length > 0 && entry.tag.length > 0) {
        out.push(entry);
      }
    }
    return out;
  }

  /**
   * 安装模块：下载 manifest.json + main.js，sha256 校验后落盘，
   * 记入已安装列表。重复安装按新版本覆盖（先卸载旧文件）。
   */
  static async install(entry: ModuleIndexEntry, context: common.Context): Promise<InstalledModule> {
    if (entry.id.length === 0 || entry.repo.length === 0 || entry.tag.length === 0) {
      throw new Error('模块信息不完整');
    }
    const manifestBody: string = await SourceRegistry.fetchModuleFile(entry, 'manifest.json');
    const mainBody: string = await SourceRegistry.fetchModuleFile(entry, 'main.js');
    if (entry.shaManifest.length > 0) {
      SourceRegistry.verifySha256(manifestBody, entry.shaManifest, 'manifest.json');
    }
    if (entry.shaMain.length > 0) {
      SourceRegistry.verifySha256(mainBody, entry.shaMain, 'main.js');
    }
    const manifest: ModuleManifest = SourceRegistry.parseManifest(manifestBody);
    SourceRegistry.validateManifest(manifest);
    if (manifest.id !== entry.id) {
      throw new Error('模块标识与索引不符');
    }
    const conflict: string = SourceRegistry.conflictOf(manifest.id, manifest.aliases);
    if (conflict.length > 0) {
      throw new Error(conflict);
    }

    SourceRegistry.removeModuleFiles(context, entry.id);
    const dir: string = SourceRegistry.moduleDir(context, entry.id);
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    SourceRegistry.writeTextFile(`${dir}/manifest.json`, manifestBody);
    SourceRegistry.writeTextFile(`${dir}/main.js`, mainBody);

    const installed = new InstalledModule();
    installed.id = entry.id;
    installed.name = manifest.name.length > 0 ? manifest.name : entry.name;
    installed.version = manifest.version.length > 0 ? manifest.version : entry.version;
    installed.description = manifest.description.length > 0 ? manifest.description : entry.description;
    installed.adult = manifest.adult || entry.adult;
    installed.installedAt = Date.now();
    installed.aliases = manifest.aliases;
    installed.capabilities = manifest.capabilities;
    installed.rankings = manifest.rankings;

    const next: InstalledModule[] = [];
    for (const existing of SourceRegistry.installed()) {
      if (existing.id !== installed.id) {
        next.push(existing);
      }
    }
    next.unshift(installed);
    SourceRegistry.saveInstalled(next);
    SourceRegistry.syncModulesPresent();
    return installed;
  }

  /** 手动安装：跳过索引，直接按 repo + tag 拉取并落盘 */
  static async installManual(repo: string, tag: string,
    context: common.Context): Promise<InstalledModule> {
    const entry = new ModuleIndexEntry();
    entry.repo = repo;
    entry.tag = tag;
    const manifestBody: string = await SourceRegistry.fetchModuleFile(entry, 'manifest.json');
    const mainBody: string = await SourceRegistry.fetchModuleFile(entry, 'main.js');
    const manifest: ModuleManifest = SourceRegistry.parseManifest(manifestBody);
    SourceRegistry.validateManifest(manifest);
    if (manifest.id.length === 0) {
      throw new Error('manifest.json 缺少模块标识');
    }
    const conflict: string = SourceRegistry.conflictOf(manifest.id, manifest.aliases);
    if (conflict.length > 0) {
      throw new Error(conflict);
    }
    entry.id = manifest.id;
    entry.name = manifest.name;
    entry.version = manifest.version;
    entry.description = manifest.description;

    SourceRegistry.removeModuleFiles(context, entry.id);
    const dir: string = SourceRegistry.moduleDir(context, entry.id);
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    SourceRegistry.writeTextFile(`${dir}/manifest.json`, manifestBody);
    SourceRegistry.writeTextFile(`${dir}/main.js`, mainBody);

    const installed = new InstalledModule();
    installed.id = manifest.id;
    installed.name = manifest.name;
    installed.version = manifest.version;
    installed.description = manifest.description;
    installed.adult = manifest.adult;
    installed.installedAt = Date.now();
    installed.aliases = manifest.aliases;
    installed.capabilities = manifest.capabilities;
    installed.rankings = manifest.rankings;
    const next: InstalledModule[] = [];
    for (const existing of SourceRegistry.installed()) {
      if (existing.id !== installed.id) {
        next.push(existing);
      }
    }
    next.unshift(installed);
    SourceRegistry.saveInstalled(next);
    SourceRegistry.syncModulesPresent();
    return installed;
  }

  static uninstall(id: string, context: common.Context): void {
    SourceRegistry.removeModuleFiles(context, id);
    ModuleRuntime.deleteState(id);
    const next: InstalledModule[] = [];
    for (const item of SourceRegistry.installed()) {
      if (item.id !== id) {
        next.push(item);
      }
    }
    SourceRegistry.saveInstalled(next);
    SourceRegistry.syncModulesPresent();
    // 卸载的是当前激活源时回落到内置源，避免悬空引用
    if (Settings.activeSourceId === id) {
      Settings.activeSourceId = SourceRegistry.BUILTIN_ID;
      Settings.save();
    }
  }

  private static moduleDir(context: common.Context, id: string): string {
    return `${context.filesDir}/modules/${id}`;
  }

  private static removeModuleFiles(context: common.Context, id: string): void {
    if (id.length === 0) {
      return;
    }
    const dir: string = SourceRegistry.moduleDir(context, id);
    if (!fs.accessSync(dir)) {
      return;
    }
    for (const name of MODULE_FILES) {
      const path: string = `${dir}/${name}`;
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    }
    fs.rmdirSync(dir);
  }

  private static writeTextFile(path: string, content: string): void {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, content);
    fs.closeSync(file);
  }

  /** 模块文件双通道地址 */
  private static moduleFileUrls(entry: ModuleIndexEntry, name: string): string[] {
    return [
      `https://raw.githubusercontent.com/${entry.repo}/${entry.tag}/${name}`,
      `https://cdn.jsdelivr.net/gh/${entry.repo}@${entry.tag}/${name}`
    ];
  }

  private static async fetchModuleFile(entry: ModuleIndexEntry, name: string): Promise<string> {
    let lastError: Error = new Error(`模块文件 ${name} 下载失败`);
    for (const url of SourceRegistry.moduleFileUrls(entry, name)) {
      try {
        const response = await httpRequest(url, http.RequestMethod.GET, {}, null, 30000);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastError = new Error(`模块文件 ${name} 响应异常（${response.statusCode}）`);
          continue;
        }
        return response.body;
      } catch (error) {
        lastError = error as Error;
      }
    }
    throw lastError;
  }

  private static parseManifest(body: string): ModuleManifest {
    const parsed = JSON.parse(body) as Record<string, Object>;
    const manifest = new ModuleManifest();
    manifest.id = typeof parsed['id'] === 'string' ? parsed['id'] as string : '';
    manifest.name = typeof parsed['name'] === 'string' ? parsed['name'] as string : '';
    manifest.version = typeof parsed['version'] === 'string' ? parsed['version'] as string : '';
    manifest.description = typeof parsed['description'] === 'string' ? parsed['description'] as string : '';
    manifest.api = typeof parsed['api'] === 'number' ? parsed['api'] as number : 1;
    manifest.adult = parsed['adult'] === true;
    manifest.runtime = typeof parsed['runtime'] === 'string' ? parsed['runtime'] as string : '';
    manifest.baseUrl = typeof parsed['baseUrl'] === 'string' ? parsed['baseUrl'] as string : '';
    if (parsed['aliases'] instanceof Array) {
      for (const alias of parsed['aliases'] as Object[]) {
        if (typeof alias === 'string' && (alias as string).length > 0) {
          manifest.aliases.push(alias as string);
        }
      }
    }
    if (parsed['capabilities'] instanceof Array) {
      for (const capability of parsed['capabilities'] as Object[]) {
        if (typeof capability === 'string' && (capability as string).length > 0) {
          manifest.capabilities.push(capability as string);
        }
      }
    }
    if (parsed['rankings'] instanceof Array) {
      for (const row of parsed['rankings'] as Object[]) {
        if (typeof row !== 'object' || row === null || Array.isArray(row)) {
          continue;
        }
        const record = row as Record<string, Object>;
        const board = new ModuleRanking();
        board.id = typeof record['id'] === 'string' ? record['id'] as string : '';
        board.name = typeof record['name'] === 'string' ? record['name'] as string : '';
        board.description = typeof record['description'] === 'string' ? record['description'] as string : '';
        if (board.id.length > 0 && board.name.length > 0) {
          manifest.rankings.push(board);
        }
      }
    }
    return manifest;
  }

  /** manifest 校验：标识格式、api 版本、runtime 类型；不合法抛错 */
  private static validateManifest(manifest: ModuleManifest): void {
    if (!/^[a-z0-9_-]{1,32}$/.test(manifest.id)) {
      throw new Error('模块标识不合法（仅小写字母、数字、_、-，最长 32 位）');
    }
    if (manifest.api !== 1) {
      throw new Error(`暂不支持模块接口版本 api=${manifest.api}`);
    }
    if (manifest.runtime.length > 0 && manifest.runtime !== 'js') {
      throw new Error(`暂不支持模块运行时 ${manifest.runtime}`);
    }
  }

  /**
   * 安装冲突检测：返回错误文案，空串表示可安装。
   * 同 id 覆盖安装视为更新放行；别名撞已装模块的标识/别名、
   * 新标识撞已装模块的别名时拒绝；builtin 为内置源保留标识。
   */
  private static conflictOf(id: string, aliases: string[]): string {
    if (id === SourceRegistry.BUILTIN_ID) {
      return '该标识为内置源保留，不能用于模块';
    }
    for (const item of SourceRegistry.installed()) {
      if (item.id === id) {
        continue;
      }
      if (aliases.indexOf(item.id) >= 0) {
        return `别名与已装站源「${item.name}」的标识冲突`;
      }
      if (item.aliases.indexOf(id) >= 0) {
        return `标识与已装站源「${item.name}」的别名冲突`;
      }
      for (const existing of item.aliases) {
        if (aliases.indexOf(existing) >= 0) {
          return `别名与已装站源「${item.name}」的别名冲突`;
        }
      }
    }
    return '';
  }

  /** sha256（hex，小写）校验：不匹配直接抛错，不落盘 */
  private static verifySha256(content: string, expected: string, name: string): void {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(content);
    const hash = cryptoFramework.createMd('SHA256');
    hash.updateSync({ data: bytes });
    const digest: Uint8Array = hash.digestSync().data;
    let hex: string = '';
    for (let i = 0; i < digest.length; i++) {
      const part: string = digest[i] < 16 ? `0${digest[i].toString(16)}` : digest[i].toString(16);
      hex += part;
    }
    if (hex !== expected.toLowerCase()) {
      throw new Error(`${name} 校验失败，文件可能被篡改`);
    }
  }
}
