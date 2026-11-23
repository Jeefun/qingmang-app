/**
 * 内容源媒体流的 CENC 解密。
 *
 * 背景：官方 video_model 接口返回的 mp4 是 CENC-AES-CTR 加密的，
 * 安卓端靠 ffmpeg 的 `-decryption_key` 解密，鸿蒙 AVPlayer 没有这个能力，
 * 所以这里自己做：解析 moov 取样本表 → 逐样本 AES-128-CTR 解密 → 改写加密标记盒。
 *
 * 算法与上游 Go（上游媒体解密实现）逐字节对齐，
 * 并已在真实剧集上验证：解密后 NAL 序列为 VPS→SPS→PPS→SEI→IDR→P 帧。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

class Mp4Box {
  type: string = '';
  start: number = 0;
  size: number = 0;
  body: number = 0;
  end: number = 0;
}

class TrackTables {
  /** 每个样本在文件内的起始偏移 */
  offsets: number[] = [];
  /** 每个样本的加密初始化向量（8 或 16 字节） */
  ivs: number[][] = [];
  /** 每样本字节数 */
  sizes: number[] = [];
}

function readU32(view: DataView, offset: number): number {
  return view.getUint32(offset, false);
}

function readU16(view: DataView, offset: number): number {
  return view.getUint16(offset, false);
}

/** 64 位偏移：用两次 32 位读取拼，避免依赖 BigInt */
function readU64(view: DataView, offset: number): number {
  const high = view.getUint32(offset, false);
  const low = view.getUint32(offset + 4, false);
  return high * 4294967296 + low;
}

function readType(view: DataView, offset: number): string {
  let text = '';
  for (let i = 0; i < 4; i++) {
    text += String.fromCharCode(view.getUint8(offset + i));
  }
  return text;
}

/** 只在给定区间内解析同层盒子，遇到结构异常立即停止，避免越界 */
function readBoxes(view: DataView, start: number, end: number): Mp4Box[] {
  const list: Mp4Box[] = [];
  let offset = start;
  const total = view.byteLength;
  while (offset + 8 <= end && offset + 8 <= total) {
    let size = readU32(view, offset);
    const type = readType(view, offset + 4);
    let header = 8;
    if (size === 1) {
      if (offset + 16 > end) {
        break;
      }
      size = readU64(view, offset + 8);
      header = 16;
    } else if (size === 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end || offset + size > total) {
      break;
    }
    const box = new Mp4Box();
    box.type = type;
    box.start = offset;
    box.size = size;
    box.body = offset + header;
    box.end = offset + size;
    list.push(box);
    offset += size;
  }
  return list;
}

function findBox(list: Mp4Box[], type: string): Mp4Box | null {
  for (const box of list) {
    if (box.type === type) {
      return box;
    }
  }
  return null;
}

/** 按路径向下取盒，最后一段直接返回盒子本身（不再下降一层） */
function dig(view: DataView, start: number, end: number, path: string[]): Mp4Box | null {
  let list = readBoxes(view, start, end);
  let node: Mp4Box | null = null;
  for (let i = 0; i < path.length; i++) {
    node = findBox(list, path[i]);
    if (node === null) {
      return null;
    }
    if (i < path.length - 1) {
      list = readBoxes(view, node.body, node.end);
    }
  }
  return node;
}

class SampleEntryInfo {
  entryStart: number = 0;
  entryType: string = '';
  ivSize: number = 0;
  isProtected: boolean = false;
  isHevc: boolean = false;
}

/** 读 stsd 里第一个样本描述，取编码类型与 tenc 的 IV 长度 */
function readSampleEntry(view: DataView, trak: Mp4Box): SampleEntryInfo | null {
  const stsd = dig(view, trak.body, trak.end, ['mdia', 'minf', 'stbl', 'stsd']);
  if (stsd === null) {
    return null;
  }
  const entries = readBoxes(view, stsd.body + 8, stsd.end);
  if (entries.length === 0) {
    return null;
  }
  const entry = entries[0];
  const info = new SampleEntryInfo();
  info.entryStart = entry.start;
  info.entryType = entry.type;

  // 视频样本描述头 78 字节、音频 28 字节，其后是子盒
  const childStart = entry.body + (entry.type === 'enca' || entry.type === 'mp4a' ? 28 : 78);
  const children = readBoxes(view, childStart, entry.end);
  for (const child of children) {
    if (child.type === 'hvcC' || child.type === 'hevC') {
      info.isHevc = true;
    }
  }
  const sinf = findBox(children, 'sinf');
  if (sinf === null) {
    return info;
  }
  const schi = findBox(readBoxes(view, sinf.body, sinf.end), 'schi');
  if (schi === null) {
    return info;
  }
  const tenc = findBox(readBoxes(view, schi.body, schi.end), 'tenc');
  if (tenc === null) {
    return info;
  }
  const version = view.getUint8(tenc.body);
  const base = tenc.body + 4;
  const protectOffset = version === 0 ? base + 2 : base + 3;
  const ivOffset = protectOffset + 1;
  info.isProtected = view.getUint8(protectOffset) === 1;
  info.ivSize = view.getUint8(ivOffset);
  return info;
}

class SampleLayout {
  offsets: number[] = [];
  sizes: number[] = [];
}

/** 由 stsz / stco / stsc 还原每个样本的物理偏移与长度 */
function readSampleLayout(view: DataView, trak: Mp4Box): SampleLayout {
  const layout = new SampleLayout();
  const stsz = dig(view, trak.body, trak.end, ['mdia', 'minf', 'stbl', 'stsz']);
  if (stsz === null) {
    return layout;
  }
  const fixedSize = readU32(view, stsz.body + 4);
  const count = readU32(view, stsz.body + 8);
  const sizes: number[] = [];
  for (let i = 0; i < count; i++) {
    sizes.push(fixedSize > 0 ? fixedSize : readU32(view, stsz.body + 12 + i * 4));
  }

  const chunkOffsets: number[] = [];
  const stco = dig(view, trak.body, trak.end, ['mdia', 'minf', 'stbl', 'stco']);
  const co64 = dig(view, trak.body, trak.end, ['mdia', 'minf', 'stbl', 'co64']);
  if (stco !== null) {
    const n = readU32(view, stco.body + 4);
    for (let i = 0; i < n; i++) {
      chunkOffsets.push(readU32(view, stco.body + 8 + i * 4));
    }
  } else if (co64 !== null) {
    const n = readU32(view, co64.body + 4);
    for (let i = 0; i < n; i++) {
      chunkOffsets.push(readU64(view, co64.body + 8 + i * 8));
    }
  }
  if (chunkOffsets.length === 0) {
    return layout;
  }

  const stsc = dig(view, trak.body, trak.end, ['mdia', 'minf', 'stbl', 'stsc']);
  if (stsc === null) {
    return layout;
  }
  const entryCount = readU32(view, stsc.body + 4);
  const firstChunk: number[] = [];
  const perChunk: number[] = [];
  for (let i = 0; i < entryCount; i++) {
    const base = stsc.body + 8 + i * 12;
    firstChunk.push(readU32(view, base));
    perChunk.push(readU32(view, base + 4));
  }

  const offsets: number[] = [];
  let sample = 0;
  for (let chunk = 1; chunk <= chunkOffsets.length && sample < count; chunk++) {
    let per = perChunk.length > 0 ? perChunk[0] : 1;
    for (let i = 0; i < firstChunk.length; i++) {
      if (chunk >= firstChunk[i]) {
        per = perChunk[i];
      }
    }
    let cursor = chunkOffsets[chunk - 1];
    for (let i = 0; i < per && sample < count; i++) {
      offsets.push(cursor);
      cursor += sizes[sample];
      sample++;
    }
  }
  layout.offsets = offsets;
  layout.sizes = sizes;
  return layout;
}

/** 取 senc 中每样本的初始化向量 */
function readSampleIvs(view: DataView, trak: Mp4Box, ivSize: number): number[][] {
  const senc = dig(view, trak.body, trak.end, ['mdia', 'minf', 'stbl', 'senc']);
  if (senc === null || ivSize <= 0) {
    return [];
  }
  const flags = readU32(view, senc.body) & 0xFFFFFF;
  const count = readU32(view, senc.body + 4);
  const ivs: number[][] = [];
  let cursor = senc.body + 8;
  for (let i = 0; i < count; i++) {
    if (cursor + ivSize > senc.end) {
      break;
    }
    const iv: number[] = [];
    for (let b = 0; b < ivSize; b++) {
      iv.push(view.getUint8(cursor + b));
    }
    ivs.push(iv);
    cursor += ivSize;
    if ((flags & 2) !== 0) {
      // 子样本模式：跳过 subsample 列表（内容源当前流不启用，仍按规范处理）
      if (cursor + 2 > senc.end) {
        break;
      }
      const subsamples = readU16(view, cursor);
      cursor += 2 + subsamples * 6;
    }
  }
  return ivs;
}

/**
 * 从 spade_a 还原 AES-128 密钥。
 * 结构：首字节异或得到标签长度，尾部是异或混淆的标签，正文逐字节滚动还原为十六进制串。
 */
export function contentKeyFromSpade(spade: string): Uint8Array | null {
  if (spade.length === 0 || spade.length > 1024) {
    return null;
  }
  let raw: Uint8Array;
  try {
    raw = new util.Base64Helper().decodeSync(spade);
  } catch (error) {
    return null;
  }
  if (raw.length < 3) {
    return null;
  }
  const tagLength = (raw[0] ^ raw[1] ^ raw[2]) - 48;
  const contentLength = raw.length - tagLength - 1;
  if (tagLength < 1 || contentLength < 33 || contentLength >= raw.length) {
    return null;
  }
  const seed = raw[raw.length - tagLength - 2] ^ raw[raw.length - tagLength - 1];
  let tag = '';
  for (let i = 0; i < tagLength; i++) {
    tag += String.fromCharCode((raw[raw.length - tagLength + i] ^ seed) & 0xFF);
  }
  if (tag === 'app_v2' || tag === 'web_v2') {
    return null;
  }

  const decoded: number[] = [];
  let previousEven = 250;
  let previousOdd = 85;
  for (let index = 0; index < contentLength; index++) {
    const current = raw[1 + index];
    let previous = previousEven;
    if (index % 2 === 0) {
      previousEven = current;
    } else {
      previous = previousOdd;
      previousOdd = current;
    }
    let bits = 0;
    let counter = index;
    while (counter > 0) {
      bits += counter & 1;
      counter >>= 1;
    }
    decoded.push(((previous ^ current) - 21 - bits) & 0xFF);
  }

  const padding = parseInt(String.fromCharCode(decoded[0]), 36);
  if (isNaN(padding) || contentLength - padding - 1 !== 32) {
    return null;
  }
  const key = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    const high = parseInt(String.fromCharCode(decoded[1 + i * 2]), 16);
    const low = parseInt(String.fromCharCode(decoded[2 + i * 2]), 16);
    if (isNaN(high) || isNaN(low)) {
      return null;
    }
    key[i] = (high << 4) | low;
  }
  return key;
}

class CryptoWorker {
  private key: cryptoFramework.SymKey;
  private cipher: cryptoFramework.Cipher;

  constructor(keyBytes: Uint8Array) {
    const generator = cryptoFramework.createSymKeyGenerator('AES128');
    this.key = generator.convertKeySync({ data: keyBytes });
    this.cipher = cryptoFramework.createCipher('AES128|CTR|NoPadding');
  }

  /** CTR 是流模式，样本可整体一次解完；缺省 IV 为 8 字节，高位补零 */
  decrypt(iv: number[], data: Uint8Array): Uint8Array {
    const ivBytes = new Uint8Array(16);
    for (let i = 0; i < iv.length && i < 16; i++) {
      ivBytes[i] = iv[i];
    }
    const spec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: ivBytes }
    };
    this.cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, this.key, spec);
    const output = this.cipher.doFinalSync({ data: data });
    return output.data;
  }
}

export class CencResult {
  /** 成功解密的样本数 */
  samples: number = 0;
  /** 处理过的轨道数 */
  tracks: number = 0;
  /** 是否确实是 CENC 流（false 表示本来就是明文） */
  encrypted: boolean = false;
}

/**
 * 就地解密整个 mp4，并把加密标记盒改名，使播放器当成普通明文流。
 * 文件长度不变，偏移表无需重算。
 */
export function decryptCencMp4(buffer: ArrayBuffer, keyBytes: Uint8Array): CencResult {
  const result = new CencResult();
  const view = new DataView(buffer);
  const total = view.byteLength;
  const top = readBoxes(view, 0, total);
  const moov = findBox(top, 'moov');
  if (moov === null) {
    throw new Error('文件结构异常：未找到 moov');
  }

  const traks = readBoxes(view, moov.body, moov.end).filter((box: Mp4Box) => box.type === 'trak');
  let worker: CryptoWorker | null = null;
  const payload = new Uint8Array(buffer);

  for (const trak of traks) {
    const info = readSampleEntry(view, trak);
    if (info === null) {
      continue;
    }
    if (!info.isProtected || info.entryType !== 'encv' && info.entryType !== 'enca') {
      continue;
    }
    result.encrypted = true;
    const layout = readSampleLayout(view, trak);
    const ivs = readSampleIvs(view, trak, info.ivSize);
    if (layout.offsets.length === 0 || ivs.length === 0) {
      throw new Error('文件结构异常：加密样本表不完整');
    }
    if (worker === null) {
      worker = new CryptoWorker(keyBytes);
    }

    const count = Math.min(layout.offsets.length, ivs.length);
    for (let i = 0; i < count; i++) {
      const offset = layout.offsets[i];
      const size = layout.sizes[i];
      if (size <= 0 || offset + size > total) {
        continue;
      }
      const slice = payload.subarray(offset, offset + size);
      const plain = worker.decrypt(ivs[i], slice);
      if (plain.length === size) {
        payload.set(plain, offset);
        result.samples++;
      }
    }
    result.tracks++;

    // encv/enca 改成真实编码类型，播放器才会按 hvcC/avcC 正常解码
    const codec = info.entryType === 'enca' ? 'mp4a' : (info.isHevc ? 'hvc1' : 'avc1');
    writeType(view, info.entryStart + 4, codec);
  }

  // sinf / senc 留着会让部分播放器继续按加密处理，统一改名成 free 占位
  neutralize(view, top, total);
  return result;
}

function writeType(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < 4 && i < text.length; i++) {
    view.setUint8(offset + i, text.charCodeAt(i));
  }
}

/** 只在盒子边界处改名，避免误伤样本数据里偶然出现的同名字节 */
function neutralize(view: DataView, boxes: Mp4Box[], limit: number): void {
  const containers: string[] = ['moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf', 'mvex', 'moof', 'traf', 'sinf', 'schi', 'encv', 'enca', 'mp4a', 'avc1', 'hvc1'];
  for (const box of boxes) {
    if (box.type === 'sinf' || box.type === 'senc') {
      writeType(view, box.start + 4, 'free');
      continue;
    }
    if (containers.indexOf(box.type) < 0) {
      continue;
    }
    let childStart = box.body;
    if (box.type === 'encv' || box.type === 'avc1' || box.type === 'hvc1') {
      childStart = box.body + 78;
    } else if (box.type === 'enca' || box.type === 'mp4a') {
      childStart = box.body + 28;
    }
    if (childStart >= box.end || childStart >= limit) {
      continue;
    }
    neutralize(view, readBoxes(view, childStart, box.end), limit);
  }
}
