/**
 * 站源模型。
 *
 * 对齐上游模块仓库契约（api:1）：索引 index.json 列出全部模块，
 * 模块文件为各自仓库 {repo}/{tag} 下的 manifest.json + main.js。
 * 上游宿主用 JS 引擎同步执行 main.js；鸿蒙 ArkTS 侧本轮只做
 * 安装与索引管理，模块执行留待运行时支持。
 *
 * 命名约定：不出现第三方平台或商标名称，统一用「内容源 / 上游服务」指代。
 */

/** 站源信息：内置源与已安装模块统一成一张列表供切换面板展示 */
export class SourceInfo {
  /** builtin 为内置内容源，其余为模块 id */
  id: string = '';
  name: string = '';
  description: string = '';
  /** builtin / module */
  kind: string = '';
  /** 是否可实际取流播放（模块在本轮为 false） */
  runnable: boolean = false;
  /** 成人内容标记：管理页展示，不参与过滤 */
  adult: boolean = false;
}

/** 在线仓库索引里的一条模块记录 */
export class ModuleIndexEntry {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  api: number = 1;
  adult: boolean = false;
  repo: string = '';
  tag: string = '';
  /** 文件名 -> sha256（hex），索引缺失时为空串、安装时跳过校验 */
  shaManifest: string = '';
  shaMain: string = '';
}

/** 模块清单里声明的一个榜单 */
export class ModuleRanking {
  id: string = '';
  name: string = '';
  description: string = '';
}

/** 已安装模块的本地记录（Prefs 持久化） */
export class InstalledModule {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  adult: boolean = false;
  installedAt: number = 0;
  /** 模块清单声明的别名（域名等），安装时用于冲突检测 */
  aliases: string[] = [];
  /** 模块清单声明的能力（suggestions / rankings / seasons / metadata…） */
  capabilities: string[] = [];
  /** 模块清单声明的榜单列表 */
  rankings: ModuleRanking[] = [];
}

/** 模块 manifest.json 的字段集 */
export class ModuleManifest {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  api: number = 1;
  adult: boolean = false;
  /** 运行时类型，当前只支持 js（缺省视为 js） */
  runtime: string = '';
  /** 站点基地址，沙箱页面 origin 与相对地址解析用 */
  baseUrl: string = '';
  /** 别名列表，与已装模块冲突时拒绝安装 */
  aliases: string[] = [];
  /** 声明能力（suggestions / rankings / seasons / metadata…），声明了宿主才会调用 */
  capabilities: string[] = [];
  /** 榜单列表（rankings 能力的板块清单） */
  rankings: ModuleRanking[] = [];
}
