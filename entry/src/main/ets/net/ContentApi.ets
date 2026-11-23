/**
 * 内容源接口客户端。
 *
 * 流程：先向 log.snssdk.com 注册伪设备拿到 device_id / iid，之后每个业务请求
 * 都要带 X-Gorgon / X-Argus / X-Ladon 风控头，并且 query 排序方式必须与上游一致，
 * 否则接口返回空 body（HTTP 200 但无数据）。
 *
 * 取流（对齐上游 1.2.0 多车道自适应）：multi_video_model 播放器接口优先，
 * 默认旧版 X-Gorgon 家族签名 + 短 X-Medusa（1.2.0 实测稳定），v5-stripped / v5
 * 依次回退；video_tab 接口兜底（V5 签名）；仅 H.266（bytevc2）线路时换辅助设备
 * 重试，仍失败走 fallback_api 备用线路。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpRequest, HttpResponse } from './Http';
import { buildSignedHeaders, encodeQuery, SignInput } from './Sign';
import { fromHex, utf8 } from './Md5';
import { sha512 } from './Sha512';
import { signPlaybackV5 } from './PlaybackSign';
import { contentKeyFromSpade } from './Cenc';
import { Prefs } from '../store/Prefs';
import { DanmakuComment, Drama, DramaDetail, Episode, FeedPage, PlaySource } from '../model/Models';

/**
 * 兼容性常量：以下主机名、User-Agent、设备注册参数都必须与上游服务逐字一致，
 * 否则请求会被风控判为非法而返回空 body。它们属于**通信协议的一部分**，
 * 不是本应用的品牌标识，因此不参与去品牌化改造；请勿按「敏感词」清理。
 * 同理，本文件下方的 display_name 是设备注册的固定取值，也不能改。
 *
 * 这里刻意没有任何明文 http:// 地址：官方《Remote Communication Kit 开发准备》
 * 明确 cleartextTraffic 缺省为 false，API 20 起 Network Kit 同样受管控。
 * 全站只用 HTTPS，因此也**不需要** network_config.json 去放行明文——
 * 为一个不存在的请求开全局明文，是白白降低安全性。
 */
const APP_BASE = 'https://api5-normal-sinfonlineb.fqnovel.com';
/** 播放器接口（multi_video_model）走另一个域，与 video_tab 不同 */
const PLAYBACK_BASE = 'https://api5-normal-sinfonlinea.fqnovel.com';
const REGISTER_URL = 'https://log.snssdk.com/service/2/device_register/';

const USER_AGENT = 'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
/** 取流接口（multi_video_model / video_tab）使用的 UA 与身份档位：73932 四元组必须自洽 */
const PLAYBACK_USER_AGENT = 'com.phoenix.read/73932 (Linux; U; Android 16; zh_CN_#Hans; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
/** gorgon 车道的短 X-Medusa 固定值：1.2.0 实测配 X-Gorgon 稳定通过 */
const PLAYBACK_MEDUSA = 'WSQEa3FvS6EV';

/** 取流接口路径（对齐上游 1.2.0：1.0.7 的 /player/v1 端点已下线恒空） */
const PATH_VIDEO_TAB = '/reading/bookapi/video_tab/multi_video_model/v1/';
const PATH_VIDEO_MODEL = '/novel/player/multi_video_model/v1/';
const PATH_VIDEO_DETAIL = '/novel/player/video_detail/v1/';

/** 取流域名双车道：b 域为主（multi-main / tab-main），a 域为备（multi-alt / tab-alt） */
const MEDIA_BASES: string[] = [APP_BASE, PLAYBACK_BASE];
/** 播放器接口签名车道：gorgon 为 1.2.0 默认，v5-stripped（去 X-Helios）/ v5 依次回退 */
const PLAYBACK_SIGNERS: string[] = ['gorgon', 'v5-stripped', 'v5'];

/** 媒体直链的 Referer，取流与网页一致 */
const MEDIA_REFERER = 'https://novel.snssdk.com/';

/** fallback_api 备用线路的播放地址是 AES 加密的：固定头 + 密文，密钥由 sha512(key_seed + 盐) 派生 */
const PLAY_URL_SALTS: string[] = [
  '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58'
];
const PLAY_URL_HEADER_SIZE = 4;
const PLAY_URL_PATTERN = /^https?:\/\/\S+$/;
/** 备用线路按 codec_type 依次尝试：1 = H.264、3 = H.265 */
const FALLBACK_CODEC_TYPES: string[] = ['1', '3'];

/** 网络诊断日志：域名 0x0B01 + TAG，hdc 抓 hilog 时按 TAG 过滤 */
const LOG_DOMAIN = 0x0B01;
const LOG_TAG = 'QingmangNet';

const KEY_DEVICE_ID = 'hg_device_id';
const KEY_INSTALL_ID = 'hg_install_id';
/** 辅助设备：同一套注册参数再注册一台“设备”，用于 H.266 场景换取 H.265 线路 */
const KEY_HELPER_DEVICE_ID = 'hg_helper_device_id';
const KEY_HELPER_INSTALL_ID = 'hg_helper_install_id';
/** 注册被拒后的冷却时长：期间不再发起注册，避免连续失败触发风控（对齐上游 10 分钟） */
const REGISTER_PAUSE_MS = 10 * 60 * 1000;

/** 弹幕（comment）通道固定的渠道参数，与内容源 App 客户端一致 */
const COMMENT_SOURCE = 601;
const SERVER_CHANNEL = 1000;
/** 单次拉取条数上限；服务端实际会按窗口裁剪，这里给足即可 */
const DANMAKU_PAGE_SIZE = 90;
/** 单集最多翻几页，避免长视频连续请求触发风控 */
const DANMAKU_MAX_PAGES = 4;

interface SelectItems {
  genre: string[];
  sort: string[];
  gender: string[];
  category_dim_theme: string[];
  category_dim_role: string[];
  category_dim_epoch: string[];
  online_time: string[];
  creation_status: string[];
}

interface FeedPayload {
  req_scene: string;
  offset: number;
  limit: number;
  req_type: string;
  need_selector_panel: boolean;
  client_req_type: number;
  session_id: string;
  filter_ids: string;
  select_items: SelectItems;
}

interface DetailPayload {
  series_id: string;
}

interface PlaybackRef {
  content_type: number;
  from_video_id: string;
  series_id: string;
  vid: string;
  video_platform: number;
}

interface RegisterHeader {
  display_name: string;
  aid: number;
  app_version: string;
  version_code: number;
  manifest_version_code: number;
  update_version_code: number;
  channel: string;
  package: string;
  app_language: string;
  os: string;
  os_version: string;
  os_api: number;
  device_model: string;
  device_brand: string;
  device_manufacturer: string;
  cpu_abi: string;
  density_dpi: number;
  display_density: string;
  resolution: string;
  language: string;
  timezone: number;
  access: string;
  openudid: string;
  clientudid: string;
  cdid: string;
  region: string;
  tz_name: string;
  tz_offset: number;
  sim_region: string;
  device_platform: string;
  not_request_sender: number;
  is_system_app: number;
  sdk_flavor: string;
  rom: string;
  rom_version: string;
}

interface RegisterBody {
  magic_tag: string;
  header: RegisterHeader;
  _gen_time: number;
}

export class ApiError extends Error {
  code: string = '';

  constructor(message: string, code: string = '') {
    super(message);
    this.code = code;
  }
}

// ---------- JSON 取值工具（ArkTS 不允许 any，逐层断言） ----------

function asRecord(value: Object | undefined | null): Record<string, Object> | null {
  if (value === null || value === undefined) {
    return null;
  }
  if (typeof value !== 'object') {
    return null;
  }
  return value as Record<string, Object>;
}

function asArray(value: Object | undefined | null): Object[] {
  if (value === null || value === undefined) {
    return [];
  }
  if (!Array.isArray(value)) {
    return [];
  }
  return value as Object[];
}

function pickString(record: Record<string, Object> | null, keys: string[]): string {
  if (record === null) {
    return '';
  }
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
    if (typeof value === 'number') {
      return value.toString();
    }
  }
  return '';
}

function pickNumber(record: Record<string, Object> | null, keys: string[]): number {
  if (record === null) {
    return 0;
  }
  for (const key of keys) {
    const value = record[key];
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'string' && value.length > 0) {
      const parsed = parseInt(value, 10);
      if (!isNaN(parsed)) {
        return parsed;
      }
    }
  }
  return 0;
}

function randomHex(length: number): string {
  let out = '';
  for (let i = 0; i < length; i++) {
    out += Math.floor(Math.random() * 16).toString(16);
  }
  return out;
}

function uuidLike(): string {
  return `${randomHex(8)}-${randomHex(4)}-${randomHex(4)}-${randomHex(4)}-${randomHex(12)}`;
}

function base64Encode(text: string): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(utf8(text));
}

function base64Decode(text: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(text);
}

/** AES-128-CBC 解密：用于备用线路（fallback_api）播放地址的解密 */
function aesCbcDecrypt(data: Uint8Array, key: Uint8Array, iv: Uint8Array): Uint8Array {
  const roundKeys = expandKey(key);
  const out = new Uint8Array(data.length);
  let previous = iv;
  for (let offset = 0; offset < data.length; offset += 16) {
    const block = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      block[i] = data[offset + i];
    }
    const decrypted = decryptBlock(block, roundKeys);
    for (let i = 0; i < 16; i++) {
      out[offset + i] = decrypted[i] ^ previous[i];
    }
    previous = data.subarray(offset, offset + 16);
  }
  return out;
}

const SBOX: number[] = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
];

const INV_SBOX: number[] = [
  0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
  0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
  0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
  0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
  0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
  0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
  0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
  0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
  0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
  0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
  0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
  0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
  0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
  0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
  0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
  0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d
];

const RCON: number[] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

function xtime(value: number): number {
  const shifted = value << 1;
  return (shifted ^ (shifted > 0xff ? 0x1b : 0)) & 0xff;
}

function gmul(a: number, b: number): number {
  let result = 0;
  let x = a;
  let y = b;
  while (y > 0) {
    if ((y & 1) === 1) {
      result ^= x;
    }
    x = xtime(x);
    y >>= 1;
  }
  return result & 0xff;
}

function expandKey(key: Uint8Array): number[] {
  const w: number[] = [];
  for (let i = 0; i < 16; i++) {
    w.push(key[i]);
  }
  for (let i = 4; i < 44; i++) {
    let t0 = w[(i - 1) * 4];
    let t1 = w[(i - 1) * 4 + 1];
    let t2 = w[(i - 1) * 4 + 2];
    let t3 = w[(i - 1) * 4 + 3];
    if (i % 4 === 0) {
      const tmp = t0;
      t0 = SBOX[t1] ^ RCON[i / 4 - 1];
      t1 = SBOX[t2];
      t2 = SBOX[t3];
      t3 = SBOX[tmp];
    }
    w.push(w[(i - 4) * 4] ^ t0, w[(i - 4) * 4 + 1] ^ t1, w[(i - 4) * 4 + 2] ^ t2, w[(i - 4) * 4 + 3] ^ t3);
  }
  return w;
}

function decryptBlock(input: Uint8Array, roundKeys: number[]): Uint8Array {
  const state: number[] = [];
  for (let i = 0; i < 16; i++) {
    state.push(input[i] ^ roundKeys[160 + i]);
  }

  for (let r = 9; r >= 0; r--) {
    // InvShiftRows
    const shifted: number[] = [];
    for (let c = 0; c < 4; c++) {
      for (let row = 0; row < 4; row++) {
        shifted[c * 4 + row] = state[((c - row + 4) % 4) * 4 + row];
      }
    }
    // InvSubBytes
    for (let i = 0; i < 16; i++) {
      shifted[i] = INV_SBOX[shifted[i]];
    }
    // AddRoundKey
    for (let i = 0; i < 16; i++) {
      shifted[i] ^= roundKeys[r * 16 + i];
    }
    if (r > 0) {
      // InvMixColumns
      for (let c = 0; c < 4; c++) {
        const a0 = shifted[c * 4];
        const a1 = shifted[c * 4 + 1];
        const a2 = shifted[c * 4 + 2];
        const a3 = shifted[c * 4 + 3];
        state[c * 4] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
        state[c * 4 + 1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
        state[c * 4 + 2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
        state[c * 4 + 3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
      }
    } else {
      for (let i = 0; i < 16; i++) {
        state[i] = shifted[i];
      }
    }
  }

  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    out[i] = state[i];
  }
  return out;
}

export class ContentApi {
  private deviceId: string = '';
  private installId: string = '';
  private registered: boolean = false;
  private helperDeviceId: string = '';
  private helperInstallId: string = '';
  private helperRegistered: boolean = false;
  /** 注册冷却截止时间（毫秒时间戳）；HTTP 非 200 或未返回设备号时进入冷却 */
  private registerPausedUntil: number = 0;
  /** 并发注册去重：同一时刻只发一次注册请求，后续调用共享结果 */
  private registerPromise: Promise<void> | null = null;
  private helperRegisterPromise: Promise<void> | null = null;
  private lastError: string = '';

  get deviceReady(): boolean {
    return this.registered;
  }

  get errorText(): string {
    return this.lastError;
  }

  init(): void {
    this.deviceId = Prefs.getString(KEY_DEVICE_ID, '');
    this.installId = Prefs.getString(KEY_INSTALL_ID, '');
    this.registered = this.deviceId.length > 0 && this.installId.length > 0;
    this.helperDeviceId = Prefs.getString(KEY_HELPER_DEVICE_ID, '');
    this.helperInstallId = Prefs.getString(KEY_HELPER_INSTALL_ID, '');
    this.helperRegistered = this.helperDeviceId.length > 0 && this.helperInstallId.length > 0;
  }

  private baseParams(helper: boolean = false): Map<string, string[]> {
    const params = new Map<string, string[]>();
    params.set('aid', ['8662']);
    params.set('app_name', ['novelread']);
    params.set('version_code', ['73532']);
    params.set('version_name', ['7.3.5.32']);
    params.set('manifest_version_code', ['73532']);
    params.set('update_version_code', ['73532']);
    params.set('channel', ['update_64']);
    params.set('device_platform', ['android']);
    params.set('os', ['android']);
    params.set('ssmix', ['a']);
    params.set('device_type', ['25053RT47C']);
    params.set('device_brand', ['Redmi']);
    params.set('language', ['zh']);
    params.set('os_api', ['36']);
    params.set('os_version', ['16']);
    params.set('resolution', ['1280*2772']);
    params.set('dpi', ['520']);
    params.set('ac', ['wifi']);
    const devId = helper ? this.helperDeviceId : this.deviceId;
    const instId = helper ? this.helperInstallId : this.installId;
    if (devId.length > 0) {
      params.set('device_id', [devId]);
      params.set('iid', [instId]);
    }
    return params;
  }

  /**
   * 发起一次设备注册（主设备 / 辅助设备共用），返回 [deviceId, installId]。
   * 这一步不带签名；注册被拒时进入冷却。
   */
  private async requestRegistration(): Promise<string[]> {
    if (Date.now() < this.registerPausedUntil) {
      throw new ApiError('设备注册暂不可用，请稍后再试', 'REGISTER');
    }
    const header: RegisterHeader = {
      // 上行协议字段，服务端按此值识别客户端类型；不是界面文案，请勿按品牌词清理。
      // 详见文件头「兼容性常量」说明：改一个字符就会导致注册返回空 body。
      display_name: '红果免费短剧',
      aid: 8662,
      app_version: '7.3.5.32',
      version_code: 73532,
      manifest_version_code: 73532,
      update_version_code: 73532,
      channel: 'update_64',
      package: 'com.phoenix.read',
      app_language: 'zh',
      os: 'Android',
      os_version: '16',
      os_api: 36,
      device_model: '25053RT47C',
      device_brand: 'Redmi',
      device_manufacturer: 'Xiaomi',
      cpu_abi: 'arm64-v8a',
      density_dpi: 520,
      display_density: 'xxhdpi',
      resolution: '2772x1280',
      language: 'zh',
      timezone: 8,
      access: 'wifi',
      openudid: randomHex(8),
      clientudid: uuidLike(),
      cdid: uuidLike(),
      region: 'CN',
      tz_name: 'Asia/Shanghai',
      tz_offset: 28800,
      sim_region: 'cn',
      device_platform: 'android',
      not_request_sender: 0,
      is_system_app: 0,
      sdk_flavor: 'china',
      rom: 'OS2.0',
      rom_version: 'BP2A.250605.031.A3'
    };
    const payload: RegisterBody = {
      magic_tag: 'ss_app_log',
      header: header,
      _gen_time: Date.now()
    };

    const params = this.baseParams();
    params.delete('device_id');
    params.delete('iid');
    params.set('req_id', [uuidLike()]);
    params.set('_rticket', [Date.now().toString()]);
    const body = JSON.stringify(payload);

    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8'
    };

    const response = await httpRequest(`${REGISTER_URL}?${encodeQuery(params)}`,
      http.RequestMethod.POST, headers, body, 20000);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'register resp status=%{public}d len=%{public}d head=%{public}s',
      response.statusCode, response.body.length, response.body.substring(0, 300));
    if (response.statusCode !== 200) {
      // 注册被拒：进入冷却，避免后续请求连环注册加重风控
      this.registerPausedUntil = Date.now() + REGISTER_PAUSE_MS;
      throw new ApiError(`设备注册失败 HTTP ${response.statusCode}`, 'REGISTER');
    }

    const root = asRecord(JSON.parse(response.body) as Object);
    const deviceId = pickString(root, ['device_id_str', 'device_id']);
    const installId = pickString(root, ['install_id_str', 'install_id']);
    if (deviceId.length === 0 || installId.length === 0 || deviceId === '0') {
      this.registerPausedUntil = Date.now() + REGISTER_PAUSE_MS;
      throw new ApiError('设备注册未返回有效设备号', 'REGISTER');
    }
    return [deviceId, installId];
  }

  /** 注册主设备；并发调用共享同一次注册请求 */
  async registerDevice(): Promise<void> {
    if (this.registerPromise !== null) {
      return this.registerPromise;
    }
    this.registerPromise = this.doRegisterDevice();
    try {
      await this.registerPromise;
    } finally {
      this.registerPromise = null;
    }
  }

  private async doRegisterDevice(): Promise<void> {
    const ids = await this.requestRegistration();
    this.deviceId = ids[0];
    this.installId = ids[1];
    this.registered = true;
    Prefs.setString(KEY_DEVICE_ID, this.deviceId);
    Prefs.setString(KEY_INSTALL_ID, this.installId);
  }

  /**
   * 注册辅助设备（幂等）：与主设备同一套注册参数，只是再拿一套
   * device_id / install_id。少数剧集对部分设备只下发 H.266（bytevc2）流，
   * AVPlayer 不支持该编码；换一台“设备”重新取流即可拿到 H.265 线路。
   */
  async registerHelperDevice(force: boolean = false): Promise<void> {
    if (force) {
      // 换号：丢弃旧辅助设备号，重新注册拿一套新号
      this.helperRegistered = false;
      this.helperDeviceId = '';
      this.helperInstallId = '';
      this.helperRegisterPromise = null;
    }
    if (this.helperRegistered) {
      return;
    }
    if (this.helperRegisterPromise === null) {
      this.helperRegisterPromise = this.doRegisterHelperDevice()
        .then(() => {
          this.helperRegisterPromise = null;
        })
        .catch((error: Error) => {
          this.helperRegisterPromise = null;
          throw error;
        });
    }
    return this.helperRegisterPromise;
  }

  private async doRegisterHelperDevice(): Promise<void> {
    const ids = await this.requestRegistration();
    this.helperDeviceId = ids[0];
    this.helperInstallId = ids[1];
    this.helperRegistered = true;
    Prefs.setString(KEY_HELPER_DEVICE_ID, this.helperDeviceId);
    Prefs.setString(KEY_HELPER_INSTALL_ID, this.helperInstallId);
  }

  /**
   * 带风控头的业务请求。空 body 视为设备号被风控失效，自动换新设备号重试一次。
   */
  private async call(method: http.RequestMethod, path: string,
    extra: Map<string, string[]> | null, payload: string | null,
    comment: boolean = false, helper: boolean = false): Promise<Record<string, Object>> {
    try {
      return await this.callOnce(method, path, extra, payload, comment, helper);
    } catch (error) {
      const apiError = error as ApiError;
      if (apiError.code === 'EMPTY' && !comment && !helper) {
        // 主设备号可能已失效：重新注册换新号再试一次（对齐上游的设备轮换）
        hilog.info(LOG_DOMAIN, LOG_TAG, 'rotate: EMPTY on %{public}s, re-registering', path);
        await this.registerDevice();
        return await this.callOnce(method, path, extra, payload, comment, helper);
      }
      throw error as Error;
    }
  }

  private async callOnce(method: http.RequestMethod, path: string,
    extra: Map<string, string[]> | null, payload: string | null,
    comment: boolean, helper: boolean): Promise<Record<string, Object>> {
    if (helper && !this.helperRegistered) {
      throw new ApiError('辅助设备不可用', 'HELPER');
    }
    const params = this.baseParams(helper);
    if (extra !== null) {
      extra.forEach((values: string[], key: string) => {
        params.set(key, values);
      });
    }
    params.set('_rticket', [Date.now().toString()]);

    const rawQuery = encodeQuery(params);
    const bodyBytes = payload === null ? null : utf8(payload);
    const signInput = new SignInput();
    signInput.rawQuery = rawQuery;
    // 弹幕走的 comment 通道与普通接口不同：stub 传空串、Argus 按空 body 计算，
    // 与内容源 App 自己的实现一致（照搬 md5(body) 会被判为签名不匹配而返回空列表）
    signInput.body = comment ? null : bodyBytes;
    signInput.deviceID = helper ? this.helperDeviceId : this.deviceId;
    signInput.aid = '8662';
    signInput.timestampMs = Date.now();
    const signed = buildSignedHeaders(signInput);

    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'application/json',
      'X-XS-From-Web': '0',
      'Sdk-Version': '2'
    };
    if (payload !== null) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    if (comment) {
      headers['comment-source'] = `${COMMENT_SOURCE}`;
      headers['server-channel'] = `${SERVER_CHANNEL}`;
    }
    for (const key of Object.keys(signed)) {
      headers[key] = signed[key];
    }
    if (comment) {
      headers['X-SS-STUB'] = '';
    }

    const url = `${APP_BASE}${path}?${rawQuery}`;
    // 诊断日志：接口排障用，完整记录 query / 签名头 / 响应概况
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'req dev=%{public}s q=%{public}s', signInput.deviceID, rawQuery);
    if (payload !== null) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'req body=%{public}s', payload);
    }
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'hdr khronos=%{public}s gorgon=%{public}s ladon=%{public}s argus=%{public}s',
      signed['X-Khronos'] ?? '', signed['X-Gorgon'] ?? '',
      signed['X-Ladon'] ?? '', signed['X-Argus'] ?? '');
    const response: HttpResponse = await httpRequest(url, method, headers, payload, 20000);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'resp %{public}s status=%{public}d len=%{public}d head=%{public}s',
      path, response.statusCode, response.body.length, response.body.substring(0, 300));
    if (response.statusCode !== 200) {
      throw new ApiError(`接口返回 HTTP ${response.statusCode}`, 'HTTP');
    }
    if (response.body.length === 0) {
      throw new ApiError('接口未返回数据（设备号可能已失效）', 'EMPTY');
    }

    const root = asRecord(JSON.parse(response.body) as Object);
    const code = pickString(root, ['code', 'Code', 'status_code']);
    if (code.length > 0 && code !== '0') {
      throw new ApiError(`接口不可用（${code}）`, code);
    }
    return root === null ? {} : root;
  }

  /** 分类信息流 */
  async feed(genreKey: string, scene: string, offset: number,
    sessionId: string, seen: string[]): Promise<FeedPage> {
    const selectItems: SelectItems = {
      genre: [genreKey],
      sort: [],
      gender: [],
      category_dim_theme: [],
      category_dim_role: [],
      category_dim_epoch: [],
      online_time: [],
      creation_status: []
    };
    const payload: FeedPayload = {
      req_scene: scene,
      offset: offset,
      limit: 54,
      req_type: 'only_content',
      need_selector_panel: false,
      client_req_type: offset > 0 ? 2 : 3,
      session_id: sessionId,
      filter_ids: seen.join(','),
      select_items: selectItems
    };

    const root = await this.call(http.RequestMethod.POST,
      '/reading/distribution/category/landpage/v/', null, JSON.stringify(payload));
    const data = asRecord(root['data']);
    if (data === null) {
      throw new ApiError('信息流返回格式异常', 'FEED');
    }

    const page = new FeedPage();
    page.items = this.parseDramaRows(asArray(data['video_data']), '短剧');
    page.hasMore = data['has_more'] === true;
    page.nextOffset = pickNumber(data, ['next_offset']);
    page.sessionId = pickString(data, ['session_id']);
    if (page.items.length === 0) {
      throw new ApiError('这一分类暂时没有内容', 'FEED_EMPTY');
    }
    return page;
  }

  /** 剧集详情 + 全部分集 */
  async detail(seriesId: string): Promise<DramaDetail> {    const payload: DetailPayload = { series_id: seriesId };
    const root = await this.call(http.RequestMethod.POST,
      PATH_VIDEO_DETAIL, null, JSON.stringify(payload));
    const data = asRecord(root['data']);
    const videoData = data === null ? null : asRecord(data['video_data']);
    if (videoData === null) {
      throw new ApiError('详情接口未返回剧集数据', 'DETAIL');
    }

    const detail = new DramaDetail();
    detail.drama = this.parseDrama(videoData, '短剧');

    const episodes: Episode[] = [];
    for (const row of asArray(videoData['video_list'])) {
      const record = asRecord(row);
      const vid = pickString(record, ['vid']);
      const index = pickNumber(record, ['vid_index']);
      if (vid.length === 0 || index < 1) {
        continue;
      }
      const episode = new Episode();
      episode.index = index;
      episode.vid = vid;
      episode.title = `第${index}集`;
      episode.vertical = record !== null && record['vertical'] === true;
      episodes.push(episode);
    }
    episodes.sort((left: Episode, right: Episode) => left.index - right.index);
    detail.episodes = episodes;

    if (episodes.length === 0) {
      throw new ApiError('该剧集没有可播放的分集', 'DETAIL_EMPTY');
    }
    return detail;
  }

  /**
   * 官方弹幕（只读）。
   *
   * 走内容源 App 的 comment 列表接口，`comment_type=20` 取的是弹幕条，
   * 返回项的 `expand.offset_time` 是它在视频时间轴上的毫秒位置。
   *
   * 两个容易踩错的地方（都已在真机外的等价环境里跑通验证）：
   *   1. `playlet_item_duration` 必须传**毫秒**，传秒会让服务端认为时长 0 而返回空列表；
   *   2. `start_offset_time` 同样是毫秒，传 0 时服务端会一次性给完整个时长窗口。
   * 因此短剧（单集 1~3 分钟）一次请求就能取全；长视频按 next 游标继续翻页，最多 4 页。
   */
  async danmaku(seriesId: string, vid: string, durationMs: number): Promise<DanmakuComment[]> {
    const collected: DanmakuComment[] = [];
    const seen = new Set<string>();
    let startMs = 0;
    let cursor = '';
    let pages = 0;

    while (pages < DANMAKU_MAX_PAGES) {
      pages++;
      const biz: DanmakuBusinessParam = {
        book_id: seriesId,
        start_offset_time: startMs,
        playlet_item_duration: durationMs > 0 ? durationMs : 0,
        need_danmaku_guide_type: [1, 3, 4, 2]
      };
      const payload: DanmakuPayload = {
        comment_source: COMMENT_SOURCE,
        server_channel: SERVER_CHANNEL,
        group_id: vid,
        group_type: 30,
        comment_type: 20,
        sort: 1,
        business_param: biz,
        count: DANMAKU_PAGE_SIZE,
        cursor: cursor,
        aid: 8662,
        compliance_status: 0
      };

      const root = await this.call(http.RequestMethod.POST,
        `/novel/commentapi/comment/list/${encodeURIComponent(vid)}/v1/`,
        null, JSON.stringify(payload), true);
      const data = asRecord(root['data']);
      if (data === null) {
        break;
      }
      for (const row of asArray(data['data_list'])) {
        const rowRecord = asRecord(row);
        if (rowRecord === null) {
          continue;
        }
        const comment = asRecord(rowRecord['comment']);
        if (comment === null) {
          continue;
        }
        const common = asRecord(comment['common']);
        const content = common === null ? null : asRecord(common['content']);
        const expand = asRecord(comment['expand']);
        const id = pickString(comment, ['comment_id']);
        const text = pickString(content, ['text']).replace(/[\r\n]+/g, ' ').trim();
        const offset = pickNumber(expand, ['offset_time']);
        if (text.length === 0 || offset < 0) {
          continue;
        }
        const key = id.length > 0 ? id : `${offset}:${text}`;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        const item = new DanmakuComment();
        item.id = key;
        item.text = text;
        item.offsetMs = offset;
        item.digg = pickNumber(asRecord(comment['stat']), ['digg_count']);
        collected.push(item);
      }

      const info = asRecord(data['common_list_info']);
      const extra = asRecord(data['extra']);
      const next = pickNumber(extra, ['next_query_danmaku_list_time']);
      const hasMore = info !== null && info['has_more'] === true;
      // 没有下一页游标、游标不前进、或已经走到视频末尾，都停下来
      if (next <= startMs) {
        break;
      }
      if (durationMs > 0 && next >= durationMs) {
        break;
      }
      if (!hasMore && durationMs > 0) {
        break;
      }
      startMs = next;
      cursor = pickString(info, ['cursor']);
      if (cursor.length === 0 && !hasMore) {
        break;
      }
    }

    collected.sort((left: DanmakuComment, right: DanmakuComment) => left.offsetMs - right.offsetMs);
    return collected;
  }

  /** 搜索（内容源 tab 搜索，tab_type=29 为剧集） */
  async search(keyword: string, offset: number, searchId: string): Promise<FeedPage> {
    const extra = new Map<string, string[]>();
    extra.set('query', [keyword]);
    extra.set('offset', [offset.toString()]);
    extra.set('count', ['10']);
    extra.set('tab_type', ['29']);
    if (offset > 0 && searchId.length > 0) {
      extra.set('passback', [offset.toString()]);
      extra.set('search_id', [searchId]);
    }

    const root = await this.call(http.RequestMethod.GET, '/reading/bookapi/search/tab/v/', extra, null);
    const page = new FeedPage();

    let tab: Record<string, Object> | null = null;
    for (const item of asArray(root['search_tabs'])) {
      const candidate = asRecord(item);
      if (candidate !== null && pickString(candidate, ['tab_type']) === '29') {
        tab = candidate;
      }
    }
    if (tab === null) {
      throw new ApiError('搜索没有返回结果', 'SEARCH');
    }

    page.sessionId = pickString(tab, ['search_id']);
    page.hasMore = tab['has_more'] === true;

    const items: Drama[] = [];
    for (const cell of asArray(tab['data'])) {
      const row = asRecord(cell);
      if (row === null) {
        continue;
      }
      for (const video of asArray(row['video_data'])) {
        const wrapper: Record<string, Object> = { 'video_data': video };
        const drama = this.parseDrama(wrapper, '短剧');
        if (drama.seriesId.length > 0) {
          items.push(drama);
        }
      }
    }
    page.items = items;
    return page;
  }

  /**
   * 取全部清晰度列表（对齐上游 2026-11 修复后的取流流程）：
   * 1. video_tab 接口（GET + V5 签名）优先；
   * 2. 失败走 multi_video_model 播放器接口（POST + V5 签名，独立域名）；
   * 3. 仅 H.266（bytevc2）线路时换辅助设备重试（服务端按设备分配编码线路）；
   * 4. 仍失败走 fallback_api 备用线路（codec_type 置换 + 解密播放地址）。
   * 返回按清晰度从高到低排序、且同清晰度只保留一条的结果。
   */
  async playbackVariants(seriesId: string, videoId: string): Promise<PlaySource[]> {
    // 主设备
    try {
      return await this.fetchAppMedia(videoId, false);
    } catch (error) {
      if (!(error as NoMediaError).noCompatibleMedia) {
        throw error as Error;
      }
    }
    // 辅助设备：服务端按设备分配编码线路，换一台“设备”可换到 H.265
    try {
      await this.registerHelperDevice();
      return await this.fetchAppMedia(videoId, true);
    } catch (error) {
      if (!(error as NoMediaError).noCompatibleMedia) {
        throw error as Error;
      }
    }
    // 两个设备都拿不到兼容线路：重新注册辅助设备（换号）再试最后一轮
    await this.registerHelperDevice(true);
    return await this.fetchAppMedia(videoId, true);
  }

  /** 播放器接口优先、video_tab 兜底，共用同一设备（对齐 1.2.0：两条车道索引与风控判定不同，必须各试一遍） */
  private async fetchAppMedia(videoId: string, helper: boolean): Promise<PlaySource[]> {
    let playerError: Error;
    try {
      return await this.fetchPlayerMedia(videoId, helper);
    } catch (error) {
      playerError = error as Error;
    }
    try {
      return await this.fetchTabMedia(videoId, helper);
    } catch (error) {
      const tabError = error as Error;
      // 任一接口判「无兼容编码」都按无兼容处理：上层换辅助设备可能换到 H.265 线路
      if ((playerError as NoMediaError).noCompatibleMedia) {
        throw playerError;
      }
      if ((tabError as NoMediaError).noCompatibleMedia) {
        throw tabError;
      }
      throw new ApiError(`${playerError.message}；视频列表接口：${tabError.message}`, 'PLAY');
    }
  }

  /** video_tab：GET + V5 签名，主备域名各试一次（1.2.0 里仅作播放器接口的兜底） */
  private async fetchTabMedia(videoId: string, helper: boolean): Promise<PlaySource[]> {
    let lastError: Error = new Error('视频列表接口不可用');
    for (const base of MEDIA_BASES) {
      const params = this.baseParams(helper);
      params.set('video_id', [videoId]);
      params.set('video_id_type', ['0']);
      params.set('device_level', ['1']);
      params.set('need_all_video_definition', ['1']);
      params.set('need_mp4_align', ['0']);
      params.set('use_os_player', ['0']);
      params.set('video_platform', ['1024']);
      params.set('source', ['0']);
      params.set('from_video_id', ['']);
      try {
        const root = await this.callPlayback(http.RequestMethod.GET, base,
          PATH_VIDEO_TAB, params, null, helper, 'v5');
        const data = asRecord(root['data']);
        const models = nestedRecord(data, 'video_model_data');
        const modelData = models === null ? null : asRecord(models[videoId]);
        if (modelData === null) {
          // 本域名没有该集：换备用域名再试，别整单判死
          lastError = new Error('未返回所请求分集的播放信息');
          continue;
        }
        return await this.mediaFromModel(readAppVideoModel(modelData));
      } catch (error) {
        if ((error as NoMediaError).noCompatibleMedia) {
          throw error as Error;
        }
        lastError = error as Error;
      }
    }
    throw lastError;
  }

  /**
   * multi_video_model 播放器接口：POST，双请求体 × 双域名 × 三种签名依次尝试。
   * 两套请求体（默认档位 + dr_scene / 高设备档位 + 无 dr_scene）对应服务端
   * 不同版本的必填项；域名或签名被风控判空都换下一档继续。
   */
  private async fetchPlayerMedia(videoId: string, helper: boolean): Promise<PlaySource[]> {
    let lastError: Error = new Error('播放器接口不可用');
    for (const payload of this.playerModelPayloads(videoId)) {
      for (const base of MEDIA_BASES) {
        for (const signer of PLAYBACK_SIGNERS) {
          try {
            const root = await this.callPlayback(http.RequestMethod.POST, base,
              PATH_VIDEO_MODEL, this.playbackParams(helper), JSON.stringify(payload), helper, signer);
            const entries = asRecord(root['data']);
            const byCode = entries === null ? null : nestedRecord(entries, '1004');
            const container = byCode === null ? entries : byCode;
            const modelData = container === null ? null : asRecord(container[videoId]);
            if (modelData === null) {
              lastError = new Error('未返回所请求分集的播放信息');
              continue;
            }
            return await this.mediaFromModel(readAppVideoModel(modelData));
          } catch (error) {
            if ((error as NoMediaError).noCompatibleMedia) {
              throw error as Error;
            }
            lastError = error as Error;
          }
        }
      }
    }
    throw lastError;
  }

  /** 播放器接口的两套请求体：服务端不同版本必填项不一致，两种都试（对齐 1.2.0） */
  private playerModelPayloads(videoId: string): PlayerModelPayload[] {
    const first: PlayerModelPayload = {
      biz_param: {
        detail_page_version: 0,
        device_level: 1,
        disable_digg_stat: false,
        disable_video_relate_book: false,
        need_all_video_definition: true,
        need_mp4_align: false,
        use_os_player: false,
        use_server_dns: false,
        video_platform: 1024
      },
      mixed_video_id_map: { '1004': [videoId] },
      dr_scene: 'player'
    };
    const second: PlayerModelPayload = {
      biz_param: {
        detail_page_version: 0,
        device_level: 3,
        disable_digg_stat: false,
        need_all_video_definition: true,
        need_mp4_align: false,
        use_os_player: false,
        use_server_dns: false,
        video_platform: 1024
      },
      mixed_video_id_map: { '1004': [videoId] }
    };
    return [first, second];
  }

  /**
   * 播放器接口专用 query（对齐 1.2.0 playbackQuery）：版本四元组 73932 必须自洽，
   * 任一缺失或对不上，服务器都会静默返回空体；pv_player 与版本档位同值。
   */
  private playbackParams(helper: boolean): Map<string, string[]> {
    const params = new Map<string, string[]>();
    params.set('aid', ['8662']);
    params.set('app_name', ['novelread']);
    params.set('version_code', ['73932']);
    params.set('version_name', ['7.3.9.32']);
    params.set('manifest_version_code', ['73932']);
    params.set('update_version_code', ['73932']);
    params.set('channel', ['update_64']);
    params.set('device_platform', ['android']);
    params.set('os', ['android']);
    params.set('ssmix', ['a']);
    params.set('device_type', ['25053RT47C']);
    params.set('device_brand', ['Redmi']);
    params.set('language', ['zh']);
    params.set('os_api', ['36']);
    params.set('os_version', ['16']);
    params.set('resolution', ['1280*2772']);
    params.set('dpi', ['520']);
    params.set('ac', ['wifi']);
    params.set('pv_player', ['73932']);
    params.set('host_abi', ['arm64-v8a']);
    params.set('dragon_device_type', ['phone']);
    params.set('compliance_status', ['0']);
    params.set('need_personal_recommend', ['1']);
    params.set('player_so_load', ['1']);
    params.set('is_android_pad_screen', ['0']);
    params.set('device_id', [helper ? this.helperDeviceId : this.deviceId]);
    params.set('iid', [helper ? this.helperInstallId : this.installId]);
    return params;
  }

  /**
   * 取流请求：按 signer 选签名车道。
   * gorgon      旧 X-Gorgon 家族 + 短 X-Medusa 固定值（1.2.0 默认，实测稳定）
   * v5          X-Khronos / X-Helios / X-Medusa 全套
   * v5-stripped 同 v5 但去掉 X-Helios：实测 Helios 与长 Medusa 同现会被风控判空
   */
  private async callPlayback(method: http.RequestMethod, base: string, path: string,
    params: Map<string, string[]>, payload: string | null, helper: boolean,
    signer: string): Promise<Record<string, Object>> {
    if (helper && !this.helperRegistered) {
      throw new ApiError('辅助设备不可用', 'HELPER');
    }
    const bodyBytes = payload === null ? null : utf8(payload);
    const headers: Record<string, string> = {
      'User-Agent': PLAYBACK_USER_AGENT,
      'Accept': 'application/json; charset=utf-8,application/x-protobuf'
    };
    let url = '';
    if (signer === 'gorgon') {
      params.set('_rticket', [Date.now().toString()]);
      const rawQuery = encodeQuery(params);
      const signInput = new SignInput();
      signInput.rawQuery = rawQuery;
      signInput.body = bodyBytes;
      signInput.deviceID = helper ? this.helperDeviceId : this.deviceId;
      signInput.aid = '8662';
      signInput.timestampMs = Date.now();
      const signed = buildSignedHeaders(signInput);
      headers['X-Xs-From-Web'] = '0';
      headers['Sdk-Version'] = '2';
      headers['X-Medusa'] = PLAYBACK_MEDUSA;
      for (const key of Object.keys(signed)) {
        headers[key] = signed[key];
      }
      url = `${base}${path}?${rawQuery}`;
    } else {
      const signed = signPlaybackV5(`${base}${path}`, params, bodyBytes, Date.now());
      for (const key of Object.keys(signed.headers)) {
        if (signer === 'v5-stripped' && key === 'X-Helios') {
          continue;
        }
        headers[key] = signed.headers[key];
      }
      url = signed.url;
    }
    if (payload !== null) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'playback req %{public}s signer=%{public}s base=%{public}s',
      path, signer, base);
    const response: HttpResponse = await httpRequest(url, method, headers, payload, 20000);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'playback resp %{public}s signer=%{public}s status=%{public}d len=%{public}d head=%{public}s',
      path, signer, response.statusCode, response.body.length, response.body.substring(0, 200));
    if (response.statusCode !== 200) {
      throw new ApiError(`取流接口返回 HTTP ${response.statusCode}`, 'HTTP');
    }
    if (response.body.length === 0) {
      throw new ApiError('取流接口未返回数据', 'EMPTY');
    }
    const root = asRecord(JSON.parse(response.body) as Object);
    const code = pickString(root, ['code', 'Code', 'status_code']);
    if (code.length > 0 && code !== '0') {
      throw new ApiError(`取流接口不可用（${code}）`, code);
    }
    return root === null ? {} : root;
  }

  /** 解析播放信息：优先兼容线路；全部不兼容（如仅 H.266）时走 fallback_api 备用线路 */
  private async mediaFromModel(model: Record<string, Object>): Promise<PlaySource[]> {
    try {
      return selectAppMedia(model);
    } catch (error) {
      if ((error as NoMediaError).noCompatibleMedia) {
        return await this.fallbackMedia(model, error as Error);
      }
      throw error as Error;
    }
  }

  /** fallback_api 备用线路：换 codec_type 重新取流，播放地址需解密 */
  private async fallbackMedia(model: Record<string, Object>, original: Error): Promise<PlaySource[]> {
    const api = nestedRecord(model, 'fallback_api');
    const endpoint = api === null ? '' : pickString(api, ['fallback_api']);
    if (endpoint.length === 0) {
      throw original;
    }
    let lastError: Error = original;
    for (const codecType of FALLBACK_CODEC_TYPES) {
      try {
        const data = await this.fetchFallbackPlay(endpoint, codecType);
        const wrapped: Record<string, Object> = {};
        wrapped['video_list'] = fallbackVariants(data) as Object;
        return selectAppMedia(wrapped);
      } catch (error) {
        if (!(error as NoMediaError).noCompatibleMedia) {
          throw new ApiError(`${original.message}；备用线路：${(error as Error).message}`, 'PLAY');
        }
        lastError = error as Error;
      }
    }
    throw new ApiError(`${original.message}；备用线路：${lastError.message}`, 'PLAY_EMPTY');
  }

  /** 备用线路请求：不带签名，仅替换 / 追加 codec_type 参数 */
  private async fetchFallbackPlay(endpoint: string, codecType: string): Promise<Record<string, Object>> {
    const pattern = /([?&])codec_type=[^&]*/;
    const address = pattern.test(endpoint)
      ? endpoint.replace(pattern, `$1codec_type=${codecType}`)
      : endpoint + (endpoint.includes('?') ? '&' : '?') + 'codec_type=' + codecType;
    const headers: Record<string, string> = {
      'User-Agent': PLAYBACK_USER_AGENT,
      'Accept': 'application/json'
    };
    const response: HttpResponse = await httpRequest(address, http.RequestMethod.GET,
      headers, null, 20000);
    if (response.statusCode !== 200) {
      throw new ApiError(`备用线路 HTTP ${response.statusCode}`, 'PLAY');
    }
    let root: Record<string, Object> = {};
    try {
      root = asRecord(JSON.parse(response.body) as Object) as Record<string, Object>;
    } catch (error) {
      root = {};
    }
    const info = nestedRecord(root, 'video_info');
    const data = nestedRecord(info, 'data');
    if (data === null) {
      throw new ApiError('备用线路未返回有效数据', 'PLAY');
    }
    return data;
  }

  /**
   * 单个可播地址：优先明文最高清，否则最高清加密流。
   * 保留该方法是为了兼容详情页等只需要一个地址的调用方。
   */
  async playback(seriesId: string, videoId: string): Promise<PlaySource> {
    const sources = await this.playbackVariants(seriesId, videoId);
    if (sources.length === 0) {
      throw new ApiError('该集没有兼容的播放地址', 'PLAY_EMPTY');
    }
    const clear = sources.find((item: PlaySource) => !item.encrypted);
    return clear !== undefined ? clear : sources[0];
  }

  private parseDrama(record: Record<string, Object>, category: string): Drama {
    const inner = asRecord(record['video_data']);
    const source = inner === null ? record : inner;

    const drama = new Drama();
    drama.seriesId = pickString(source, ['series_id_str', 'series_id', 'keyword']);
    if (drama.seriesId.length === 0) {
      drama.seriesId = pickString(record, ['series_id_str', 'series_id']);
    }
    drama.title = pickString(source, ['series_title', 'series_name', 'title', 'name']);
    drama.cover = pickString(source, ['series_cover', 'cover']);
    drama.description = pickString(source, ['series_intro', 'video_desc']);
    drama.category = pickString(source, ['category_name', 'categoryName', 'category']);
    drama.episodeCount = pickNumber(source, ['episode_cnt']);

    const tags: string[] = [];
    for (const tag of asArray(source['tags'])) {
      if (typeof tag === 'string' && tag.length > 0 && !tags.includes(tag)) {
        tags.push(tag);
      }
    }
    for (const item of asArray(source['category_list'])) {
      const tag = pickString(asRecord(item), ['name']);
      if (tag.length > 0 && !tags.includes(tag)) {
        tags.push(tag);
      }
    }

    /**
     * 题材的真正来源是 category_schema，不是 tags / category_list。
     *
     * 实测：信息流里 tags 与 category_list 全为空，category_name 一律是「短剧」，
     * 按那三个字段筛，任何题材都命中 0 条。category_schema 是一段 JSON 字符串，
     * 形如 [{"category_id":5024,"name":"喜剧"},{"name":"穿书"},…]，
     * 才是源站给出的官方题材（实测 160 部样本里有 138 种不同题材）。
     */
    const schemaTags: string[] = [];
    const schemaRaw: string = pickString(source, ['category_schema']);
    if (schemaRaw.length > 0) {
      try {
        const parsed: Object = JSON.parse(schemaRaw);
        for (const entry of asArray(parsed)) {
          const name: string = pickString(asRecord(entry), ['name']);
          if (name.length > 0 && !schemaTags.includes(name)) {
            schemaTags.push(name);
          }
        }
      } catch (error) {
        // 源站偶尔给非 JSON 字符串；题材只是筛选增强项，不能因此丢掉整条数据
      }
    }

    // 展示串只取前 3 个题材，详情页不至于被一长串标签撑破；
    // 筛选用的 tagList 则保留全部。
    const displayTags: string[] = tags.slice();
    for (const tag of schemaTags) {
      if (displayTags.length >= 3) {
        break;
      }
      if (!displayTags.includes(tag)) {
        displayTags.push(tag);
      }
    }
    drama.tags = displayTags.join(' · ');
    if (drama.category.length === 0) {
      drama.category = category;
    }

    // 筛选标签 = 展示标签 + 全部题材 + 分类名 + 标题。
    // 纳入标题是有实测依据的：源站题材表里没有「修仙」「科幻」这两个词，
    // 但标题里大量出现（如「全球修仙」「穿越修仙，末世归途」）。
    // 只放标题、不放简介——简介里「不恐怖」「并非言情」这类否定句会误命中。
    const allTags: string[] = [];
    for (const tag of displayTags) {
      if (!allTags.includes(tag)) {
        allTags.push(tag);
      }
    }
    for (const tag of schemaTags) {
      if (!allTags.includes(tag)) {
        allTags.push(tag);
      }
    }
    if (drama.category.length > 0 && !allTags.includes(drama.category)) {
      allTags.push(drama.category);
    }
    if (drama.title.length > 0 && !allTags.includes(drama.title)) {
      allTags.push(drama.title);
    }
    drama.tagList = allTags;

    const status = pickString(source, ['series_status']);
    if (status === '1') {
      drama.score = '已完结';
    } else if (status === '0') {
      drama.score = '连载中';
    }
    return drama;
  }

  private parseDramaRows(rows: Object[], category: string): Drama[] {
    const out: Drama[] = [];
    const seen = new Set<string>();
    for (const row of rows) {
      const record = asRecord(row);
      if (record === null) {
        continue;
      }
      const drama = this.parseDrama(record, category);
      if (drama.seriesId.length > 0 && !seen.has(drama.seriesId)) {
        seen.add(drama.seriesId);
        out.push(drama);
      }
    }
    return out;
  }
}

interface DanmakuBusinessParam {
  book_id: string;
  start_offset_time: number;
  playlet_item_duration: number;
  need_danmaku_guide_type: number[];
}

interface DanmakuPayload {
  comment_source: number;
  server_channel: number;
  group_id: string;
  group_type: number;
  comment_type: number;
  sort: number;
  business_param: DanmakuBusinessParam;
  count: number;
  cursor: string;
  aid: number;
  compliance_status: number;
}

/** multi_video_model 播放器接口的请求体 */
interface PlayerBizParam {
  detail_page_version: number;
  device_level: number;
  disable_digg_stat: boolean;
  disable_video_relate_book?: boolean;
  need_all_video_definition: boolean;
  need_mp4_align: boolean;
  use_os_player: boolean;
  use_server_dns: boolean;
  video_platform: number;
}

interface PlayerModelPayload {
  biz_param: PlayerBizParam;
  mixed_video_id_map: Record<string, string[]>;
  dr_scene?: string;
}

/** 「返回了线路但没有一条兼容」标记：换设备 / 走备用线路的依据 */
class NoMediaError extends Error {
  noCompatibleMedia: boolean = true;
}

function nestedRecord(parent: Record<string, Object> | null, key: string): Record<string, Object> | null {
  if (parent === null) {
    return null;
  }
  return asRecord(parent[key]);
}

function isHttpAddress(text: string): boolean {
  return text.startsWith('http://') || text.startsWith('https://');
}

function decodeBase64Text(text: string): string | null {
  try {
    return util.TextDecoder.create('utf-8').decodeToString(base64Decode(text)).trim();
  } catch (error) {
    return null;
  }
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) {
    total += part.length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function parseIntSafe(text: string): number {
  const parsed = parseInt(text, 10);
  return isNaN(parsed) ? 0 : parsed;
}

/** video_model 可能是对象、base64 包裹的 JSON，或直接把 video_list 提上来 */
function readAppVideoModel(data: Record<string, Object>): Record<string, Object> {
  let model: Record<string, Object> | null = null;
  const raw = data['video_model'];
  if (typeof raw === 'string' && raw.length > 0) {
    let encoded = raw;
    const decoded = decodeBase64Text(encoded);
    if (decoded !== null && decoded.length > 0) {
      encoded = decoded;
    }
    try {
      model = asRecord(JSON.parse(encoded) as Object);
    } catch (error) {
      throw new ApiError('播放信息格式异常', 'PLAY');
    }
  } else {
    model = asRecord(raw);
  }
  if ((model === null || Object.keys(model).length === 0) && asArray(data['video_list']).length > 0) {
    const fallback: Record<string, Object> = {};
    fallback['video_list'] = data['video_list'] as Object;
    if (data['video_duration'] !== undefined) {
      fallback['video_duration'] = data['video_duration'];
    }
    if (data['duration'] !== undefined) {
      fallback['duration'] = data['duration'];
    }
    return fallback;
  }
  if (model === null) {
    const empty: Record<string, Object> = {};
    return empty;
  }
  return model;
}

/** 兼容的地址键，按优先级排列 */
const ADDRESS_KEYS: string[] = ['main_url', 'backup_url', 'backup_url_1', 'backup_url_2', 'backup_urls', 'url_list'];

function mediaAddresses(info: Record<string, Object>): string[] {
  const out: string[] = [];
  for (const key of ADDRESS_KEYS) {
    collectAddresses(info[key], out);
  }
  return out;
}

/** 地址可能是明文串、base64 包裹的串，或字符串数组 */
function collectAddresses(value: Object | undefined, out: string[]): void {
  if (value === undefined || value === null) {
    return;
  }
  if (typeof value === 'string') {
    let address = value.trim();
    if (address.length > 8192) {
      return;
    }
    if (!isHttpAddress(address)) {
      const decoded = decodeBase64Text(address);
      if (decoded === null || decoded.length === 0) {
        return;
      }
      address = decoded;
    }
    if (isHttpAddress(address) && !out.includes(address)) {
      out.push(address);
    }
    return;
  }
  const list = asArray(value);
  for (const item of list) {
    collectAddresses(item, out);
  }
}

/** video_list 可能是数组，也可能是 清晰度名 -> 变体 的映射 */
function collectVariants(model: Record<string, Object>): Object[] {
  const list = model['video_list'];
  const direct = asArray(list);
  if (direct.length > 0) {
    return direct;
  }
  const mapped = asRecord(list);
  const out: Object[] = [];
  if (mapped !== null) {
    const keys = Object.keys(mapped).sort();
    for (const key of keys) {
      const item = mapped[key];
      if (item !== undefined && item !== null) {
        out.push(item as Object);
      }
    }
  }
  return out;
}

/**
 * 从 video_model 挑出兼容线路（跳过 H.266 / 无地址 / 密钥异常），
 * 按清晰度从高到低排序、同档去重（明文优先）。
 * 全部不兼容时抛 NoMediaError，由调用方决定换设备还是走备用线路。
 */
function selectAppMedia(model: Record<string, Object>): PlaySource[] {
  const variants = collectVariants(model);
  let keyError: Error | null = null;
  let unsupported = 0;
  let unaddressed = 0;
  const sources: PlaySource[] = [];

  for (const item of variants) {
    const variant = asRecord(item);
    if (variant === null) {
      continue;
    }
    const meta = asRecord(variant['video_meta']);
    const codec = pickString(meta, ['codec_type']).toLowerCase();
    // AVPlayer 不支持 bytevc2（H.266），跳过但计数
    if (codec === 'bytevc2' || pickString(variant, ['gear_des_key']).toLowerCase().includes('bytevc2')) {
      unsupported++;
      continue;
    }
    const addresses = mediaAddresses(variant);
    if (addresses.length === 0) {
      unaddressed++;
      continue;
    }
    const encryption = asRecord(variant['encrypt_info']);
    const spade = pickString(encryption, ['spade_a']);
    const encrypted = spade.length > 0 ||
      (encryption !== null && encryption['encrypt'] === true) ||
      pickString(encryption, ['encryption_method']) === 'cenc-aes-ctr';
    if (encrypted && contentKeyFromSpade(spade) === null) {
      keyError = new Error('媒体密钥不可用');
      continue;
    }
    let height = parseIntSafe(pickString(meta, ['vheight']));
    const definitionText = pickString(meta, ['definition']);
    const definitionMatch = definitionText.match(/[0-9]+/);
    const definition = definitionMatch === null ? 0 : parseIntSafe(definitionMatch[0]);
    const width = parseIntSafe(pickString(meta, ['vwidth']));
    if (definition > 0) {
      height = definition;
    } else if (width > 0 && (height === 0 || width < height)) {
      height = width;
    }
    for (const address of addresses) {
      const source = new PlaySource();
      source.url = address;
      source.referer = MEDIA_REFERER;
      source.quality = height;
      // spade_a 存在即代表该集带 CENC 加密，解密在播放前单独处理
      source.keyHex = encrypted ? 'cenc' : '';
      source.spadeA = spade;
      sources.push(source);
    }
  }

  if (sources.length > 0) {
    sources.sort((left: PlaySource, right: PlaySource) => right.quality - left.quality);
    // 同一清晰度可能同时有加密/明文多条，优先留明文，少走一次下载解密
    const deduped: PlaySource[] = [];
    for (const item of sources) {
      const exists = deduped.findIndex((it: PlaySource) => it.quality === item.quality);
      if (exists < 0) {
        deduped.push(item);
      } else if (deduped[exists].encrypted && !item.encrypted) {
        deduped[exists] = item;
      }
    }
    return deduped;
  }
  if (keyError !== null) {
    throw new ApiError(`内容源媒体密钥不可用：${keyError.message}`, 'PLAY');
  }
  if (variants.length === 0) {
    throw new NoMediaError('没有返回任何线路');
  }
  if (unsupported === 0) {
    throw new NoMediaError('返回的线路都没有播放地址');
  }
  if (unaddressed === 0) {
    throw new NoMediaError('已跳过不支持的编码');
  }
  throw new NoMediaError('已跳过不支持的编码，其余线路没有播放地址');
}

/** fallback_api 响应里的 video_list：数组或映射 */
function fallbackEntries(data: Record<string, Object>): Object[] {
  const list = data['video_list'];
  const direct = asArray(list);
  if (direct.length > 0) {
    return direct;
  }
  const mapped = asRecord(list);
  const out: Object[] = [];
  if (mapped !== null) {
    for (const key of Object.keys(mapped)) {
      const item = mapped[key];
      if (item !== undefined && item !== null) {
        out.push(item as Object);
      }
    }
  }
  return out;
}

/** 把备用线路条目转换成 video_model 变体结构；播放地址先经 decodePlayUrl 解密 */
function fallbackVariants(data: Record<string, Object>): Object[] {
  const seed = pickString(data, ['key_seed']);
  const variants: Object[] = [];
  let versionError: Error | null = null;
  let decoded = 0;
  for (const entry of fallbackEntries(data)) {
    const item = asRecord(entry);
    if (item === null) {
      continue;
    }
    const variant: Record<string, Object> = {};
    variant['gear_des_key'] = pickString(item, ['gear_des_key']);
    const meta: Record<string, Object> = {};
    meta['codec_type'] = pickString(item, ['codec_type']);
    meta['definition'] = pickString(item, ['definition']);
    meta['vwidth'] = pickString(item, ['vwidth']);
    meta['vheight'] = pickString(item, ['vheight']);
    variant['video_meta'] = meta;
    for (const key of ['main_url', 'backup_url_1', 'backup_url_2']) {
      let address = '';
      try {
        address = decodePlayUrl(pickString(item, [key]), seed);
      } catch (error) {
        versionError = error as Error;
        continue;
      }
      if (address.length > 0) {
        variant[key] = address;
        decoded++;
      }
    }
    const spade = pickString(item, ['spade_a']);
    const method = pickString(item, ['encryption_method']);
    if (spade.length > 0 || method.length > 0 || item['encrypt'] === true) {
      const encryptInfo: Record<string, Object> = {};
      encryptInfo['spade_a'] = spade;
      encryptInfo['encryption_method'] = method;
      encryptInfo['encrypt'] = item['encrypt'] === true;
      variant['encrypt_info'] = encryptInfo;
    }
    variants.push(variant);
  }
  if (versionError !== null && decoded === 0) {
    throw versionError;
  }
  return variants;
}

/** 备用线路的播放地址：base64 密文，sha512 派生密钥后 AES-128-CBC 解密 */
function decodePlayUrl(encoded: string, seed: string): string {
  if (encoded.length === 0 || seed.length === 0) {
    return encoded;
  }
  let key: Uint8Array;
  let raw: Uint8Array;
  try {
    key = base64Decode(seed);
    raw = base64Decode(encoded);
  } catch (error) {
    return encoded;
  }
  if (raw.length < 20 || raw[0] !== 0xa8 || raw[1] !== 0x00 ||
    (raw.length - PLAY_URL_HEADER_SIZE) % 16 !== 0) {
    return encoded;
  }
  for (const salt of PLAY_URL_SALTS) {
    const address = decryptPlayUrl(raw, key, salt);
    if (address.length > 0) {
      return address;
    }
  }
  throw new ApiError(`备用线路编码版本 ${raw[2] | (raw[3] << 8)} 暂不支持`, 'PLAY');
}

function decryptPlayUrl(raw: Uint8Array, seed: Uint8Array, salt: string): string {
  try {
    const digest = sha512(concatBytes([sha512(seed), fromHex(salt)]));
    const plain = aesCbcDecrypt(raw.subarray(PLAY_URL_HEADER_SIZE),
      digest.subarray(0, 16), digest.subarray(16, 32));
    const pad = plain[plain.length - 1];
    if (pad < 1 || pad > 16 || pad > plain.length) {
      return '';
    }
    for (let index = plain.length - pad; index < plain.length; index++) {
      if (plain[index] !== pad) {
        return '';
      }
    }
    const address = util.TextDecoder.create('utf-8')
      .decodeToString(plain.subarray(0, plain.length - pad));
    return PLAY_URL_PATTERN.test(address) ? address : '';
  } catch (error) {
    return '';
  }
}
