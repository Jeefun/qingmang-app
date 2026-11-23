/**
 * 内容源 App 接口风控头：X-Gorgon / X-Khronos / X-SS-STUB / X-Argus / X-Ladon。
 *
 * 逐字节对齐 上游签名实现：
 *   X-Gorgon  20 字节载荷经过异或 + 4 位循环 + 位反转
 *   X-Argus   protobuf 序列化后自研 Feistel 混淆，再 AES-128-CBC
 *   X-Ladon   34 轮 Feistel
 * 这里的算法必须与上游完全一致，任何一处偏移都会导致接口返回空。
 */
import { md5, toHex, toHexUpper, fromHex, utf8, ByteBuilder } from './Md5';
import { sm3 } from './Sm3';
import { aes128CbcEncrypt, padPkcs7 } from './Aes';
import { util } from '@kit.ArkTS';

const MASK64: bigint = 0xFFFFFFFFFFFFFFFFn;

const ARGUS_KEY_HEX = 'ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c';

const GORGON_KEY: number[] = [
  0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93,
  0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4, 0xa4, 0x96, 0x93, 0x8f
];

function rotl8(value: number, shift: number): number {
  return ((value << shift) | (value >>> (8 - shift))) & 0xff;
}

function reverse8(value: number): number {
  let out = 0;
  for (let i = 0; i < 8; i++) {
    out = (out << 1) | ((value >>> i) & 1);
  }
  return out & 0xff;
}

function rotl64(value: bigint, shift: number): bigint {
  const s = BigInt(((shift % 64) + 64) % 64);
  if (s === 0n) {
    return value & MASK64;
  }
  return ((value << s) | (value >> (64n - s))) & MASK64;
}

function rotr64(value: bigint, shift: number): bigint {
  return rotl64(value, -shift);
}

function leU64(bytes: Uint8Array, offset: number): bigint {
  let value = 0n;
  for (let i = 7; i >= 0; i--) {
    value = (value << 8n) | BigInt(bytes[offset + i]);
  }
  return value;
}

function writeLeU64(bytes: Uint8Array, offset: number, value: bigint): void {
  let v = value;
  for (let i = 0; i < 8; i++) {
    bytes[offset + i] = Number(v & 0xffn);
    v >>= 8n;
  }
}

/** Go url.Values.Encode() 的等价实现：key 升序、空格转 + */
export function queryEscape(text: string): string {
  return encodeURIComponent(text)
    .replace(/[!'()*]/g, (ch: string) => `%${ch.charCodeAt(0).toString(16).toUpperCase()}`)
    .replace(/%20/g, '+');
}

export function encodeQuery(params: Map<string, string[]>): string {
  const keys: string[] = [];
  params.forEach((_value: string[], key: string) => {
    keys.push(key);
  });
  keys.sort();

  const parts: string[] = [];
  for (const key of keys) {
    const values = params.get(key);
    if (values === undefined || values.length === 0) {
      continue;
    }
    const sorted = values.slice();
    sorted.sort();
    for (const value of sorted) {
      parts.push(`${queryEscape(key)}=${queryEscape(value)}`);
    }
  }
  return parts.join('&');
}

function base64(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function concat(parts: Uint8Array[]): Uint8Array {
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

// ---------- protobuf 变长编码 ----------

function appendUvarint(out: number[], value: bigint): void {
  let v = value;
  while (v >= 0x80n) {
    out.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  out.push(Number(v));
}

function varintField(out: number[], field: number, value: bigint): void {
  appendUvarint(out, BigInt(field) * 8n);
  appendUvarint(out, value);
}

function bytesField(out: number[], field: number, value: Uint8Array): void {
  appendUvarint(out, BigInt(field) * 8n + 2n);
  appendUvarint(out, BigInt(value.length));
  for (let i = 0; i < value.length; i++) {
    out.push(value[i]);
  }
}

function ascii(text: string): Uint8Array {
  return utf8(text);
}

// ---------- X-Argus ----------

function buildArgus(query: string, body: Uint8Array | null, timestamp: number, deviceID: string): string {
  const key = fromHex(ARGUS_KEY_HEX);

  const zero16 = new Uint8Array(16);
  let bodyHash: Uint8Array = sm3(zero16);
  if (body !== null) {
    bodyHash = sm3(md5(body));
  }
  const queryHash: Uint8Array = sm3(utf8(query));

  const counters: number[] = [];
  varintField(counters, 1, 1n);
  varintField(counters, 2, 1n);
  varintField(counters, 3, 1n);
  varintField(counters, 7, 3348294860n);

  const environment: number[] = [];
  bytesField(environment, 1, ascii('25053RT47C'));
  bytesField(environment, 2, ascii('16'));
  bytesField(environment, 3, ascii('update_64'));
  varintField(environment, 4, 2147483648n);

  // nonce 取随机值，同一请求内保持稳定，避免同秒内出现完全相同的 X-Argus
  const nonce32 = Math.floor(Math.random() * 0x7fffffff);

  const message: number[] = [];
  varintField(message, 1, BigInt(0x20200929 * 2));
  varintField(message, 2, 2n);
  varintField(message, 3, BigInt(nonce32 & 0x7fffffff));
  bytesField(message, 4, ascii('8662'));
  bytesField(message, 5, ascii(deviceID));
  bytesField(message, 6, ascii('1611921764'));
  bytesField(message, 7, ascii('7.3.5.32'));
  bytesField(message, 8, ascii('v04.07.01-ml-android'));
  varintField(message, 9, 135135744n);
  bytesField(message, 10, new Uint8Array(8));
  varintField(message, 11, 0n);
  varintField(message, 12, BigInt(timestamp) * 2n);
  bytesField(message, 13, bodyHash.slice(0, 6));
  bytesField(message, 14, queryHash.slice(0, 6));
  bytesField(message, 15, new Uint8Array(counters));
  bytesField(message, 16, new Uint8Array(0));
  bytesField(message, 20, ascii('none'));
  varintField(message, 21, 738n);
  bytesField(message, 23, new Uint8Array(environment));
  varintField(message, 25, 2n);

  let data = padPkcs7(new Uint8Array(message));

  const seed = concat([key, new Uint8Array([0x3c, 0xcc, 0x56, 0x7b]), key]);
  const derived = sm3(seed);

  const rounds: bigint[] = [];
  for (let i = 0; i < 4; i++) {
    rounds.push(leU64(derived, i * 8));
  }
  const coinConst = 0x3dc94c3a046d678bn;
  for (let i = 4; i < 72; i++) {
    let mixed = rotr64(rounds[i - 1], 3) ^ rounds[i - 3];
    mixed = mixed ^ rotr64(mixed, 1);
    const bit = (coinConst >> BigInt((i - 4) % 62)) & 1n;
    rounds.push((~rounds[i - 4] ^ mixed ^ bit ^ 3n) & MASK64);
  }

  for (let offset = 0; offset < data.length; offset += 16) {
    let left = leU64(data, offset);
    let right = leU64(data, offset + 8);
    for (const round of rounds) {
      const next = left ^ ((rotl64(right, 1) & rotl64(right, 8)) ^ rotl64(right, 2)) ^ round;
      left = right;
      right = next & MASK64;
    }
    writeLeU64(data, offset, left);
    writeLeU64(data, offset + 8, right);
  }

  const xorMask: number[] = [0xd0, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
  for (let i = 0; i < data.length; i++) {
    data[i] ^= xorMask[i % 8];
  }

  const tail = new Uint8Array(xorMask);
  data = concat([tail, data]);
  // 头尾反转
  for (let left = 0, right = data.length - 1; left < right; left++, right--) {
    const tmp = data[left];
    data[left] = data[right];
    data[right] = tmp;
  }

  const head = new Uint8Array([0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18]);
  let container = concat([head, data]);
  container = padPkcs7(concat([container, new Uint8Array([0x56, 0x7b])]));

  const aesKey = md5(key.slice(0, 16));
  const iv = md5(key.slice(16, 32));
  const encrypted = aes128CbcEncrypt(container, aesKey, iv);

  return base64(concat([new Uint8Array([0x3c, 0xcc]), encrypted]));
}

// ---------- X-Ladon ----------

function buildLadon(aid: string, timestamp: number, prefix: Uint8Array): string {
  const hash = md5(concat([prefix, utf8(aid)]));
  const digest = utf8(toHex(hash));

  let left = leU64(digest, 0);
  let right = leU64(digest, 8);
  const queue: bigint[] = [leU64(digest, 16), leU64(digest, 24)];
  const keys: bigint[] = [];

  for (let i = 0; i < 34; i++) {
    keys.push(left);
    const mixed = (((rotr64(right, 8) + left) & MASK64) ^ BigInt(i));
    queue.push(mixed);
    left = mixed ^ rotl64(left, 3);
    right = queue[0];
    queue.shift();
  }

  const payload = utf8(`${timestamp}-1611921764-${aid}`);
  const data = padPkcs7(payload);

  for (let offset = 0; offset < data.length; offset += 16) {
    let l = leU64(data, offset);
    let r = leU64(data, offset + 8);
    for (const key of keys) {
      // 与上游一致：先更新 right，再用新的 right 更新 left
      const nextRight = key ^ ((l + rotr64(r, 8)) & MASK64);
      const nextLeft = nextRight ^ rotl64(l, 3);
      l = nextLeft & MASK64;
      r = nextRight & MASK64;
    }
    writeLeU64(data, offset, l);
    writeLeU64(data, offset + 8, r);
  }

  return base64(concat([prefix, data]));
}

// ---------- 对外入口 ----------

export class SignInput {
  rawQuery: string = '';
  body: Uint8Array | null = null;
  deviceID: string = '';
  aid: string = '8662';
  timestampMs: number = 0;
}

/**
 * 生成整套风控头。返回可直接写入 http 请求头的 Record。
 */
export function buildSignedHeaders(input: SignInput): Record<string, string> {
  const now = input.timestampMs > 0 ? input.timestampMs : Date.now();
  const stamp = Math.floor(now / 1000);
  const headers: Record<string, string> = {};

  const queryHash = md5(utf8(input.rawQuery));
  const payload = new Uint8Array(20);
  payload.set(queryHash.slice(0, 4), 0);

  if (input.body !== null) {
    const bodyHash = md5(input.body);
    payload.set(bodyHash.slice(0, 4), 4);
    headers['X-SS-STUB'] = toHexUpper(bodyHash);
  }

  payload[12] = 0;
  payload[13] = 6;
  payload[14] = 11;
  payload[15] = 28;
  const timestamp32 = stamp >>> 0;
  payload[16] = (timestamp32 >>> 24) & 0xff;
  payload[17] = (timestamp32 >>> 16) & 0xff;
  payload[18] = (timestamp32 >>> 8) & 0xff;
  payload[19] = timestamp32 & 0xff;

  for (let i = 0; i < 20; i++) {
    payload[i] = payload[i] ^ GORGON_KEY[i];
  }
  for (let i = 0; i < 20; i++) {
    const mixed = rotl8(payload[i], 4) ^ payload[(i + 1) % 20];
    payload[i] = reverse8(mixed) ^ 0xff ^ 20;
  }

  const signature = concat([new Uint8Array([0x84, 0x04, 0x40, 0x1c, 0, 0]), payload]);
  headers['X-Khronos'] = stamp.toString();
  headers['X-Gorgon'] = toHex(signature);
  headers['X-SS-Req-Ticket'] = now.toString();
  headers['X-Argus'] = buildArgus(input.rawQuery, input.body, stamp, input.deviceID);

  const ladonPrefix = new Uint8Array(4);
  for (let i = 0; i < 4; i++) {
    ladonPrefix[i] = Math.floor(Math.random() * 256);
  }
  headers['X-Ladon'] = buildLadon(input.aid, stamp, ladonPrefix);

  return headers;
}
