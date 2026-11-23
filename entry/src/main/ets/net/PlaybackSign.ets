/**
 * 内容源 App 新一代播放接口风控头：X-Khronos / X-Helios / X-Medusa / X-SS-STUB（V5 签名）。
 *
 * 上游 11/20 起取流走 video_tab / multi_video_model 接口，签名从旧版
 * X-Gorgon 家族切换为 V5：ticket 暴力探测（≤1024 次）+ 自研哈希 + 载荷加密。
 * 算法逐字节对齐上游模块实现，任何偏移都会导致接口返回空。
 * 来源派生自 N3urda/hongguoTV Signer/AesV3/V5Constants 与 drpys 22261ad（GPL-3.0-only）。
 */
import { md5, toHex, toHexUpper, fromHex, utf8 } from './Md5';
import { sm3 } from './Sm3';
import { encodeQuery } from './Sign';
import { util } from '@kit.ArkTS';

const MASK64: bigint = 0xFFFFFFFFFFFFFFFFn;

const V5_MAGIC_HEX = '2d4b4fca49750d433fb5ae2c226dcc56';
const V5_SIGN_KEY_HEX = 'b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d';

const V5_SBOX_HEX =
  '53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d' +
  'f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a' +
  '80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d' +
  'd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912' +
  '38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65' +
  'b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe' +
  '1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8' +
  '94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc' +
  'd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d' +
  'e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e' +
  '47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28' +
  '8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5' +
  'd09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9' +
  '1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f' +
  'd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168' +
  '1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e';

const V5_HASH_TABLE: number[] = [
  0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
  0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
  0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
  0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
  0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
  0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
  0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
  0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586
];

const CARRIER_CON: number[][] = [
  [2, 0, 3, 1], [1, 3, 2, 0], [3, 2, 1, 0], [2, 3, 1, 0]
];
const CARRIER_ORDER: number[][] = [
  [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
  [0, 9, 14, 11, 4, 13, 2, 3, 8, 1, 6, 15, 12, 5, 10, 7],
  [0, 9, 14, 3, 4, 13, 2, 15, 8, 1, 6, 11, 12, 5, 10, 7],
  [0, 9, 14, 15, 4, 13, 2, 3, 8, 1, 6, 11, 12, 5, 10, 7]
];
const CARRIER_INITIAL: number[] = [0xbbb5de72, 0xd4638d5b, 0x92a5f73b, 0x89f8a1c9];

/** 进程级 Medusa 状态：同一进程内 nonce / 启动时间保持不变 */
let processNonce: string = '';
let processStarted: number = 0;

// ---------- 基础字节工具 ----------

function randomBytes(size: number): Uint8Array {
  const out = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    out[i] = Math.floor(Math.random() * 256);
  }
  return out;
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

function pad16(data: Uint8Array): Uint8Array {
  const padding = 16 - (data.length % 16);
  const out = new Uint8Array(data.length + padding);
  out.set(data, 0);
  for (let i = 0; i < padding; i++) {
    out[data.length + i] = padding;
  }
  return out;
}

function le32(value: number): Uint8Array {
  return new Uint8Array([value & 255, (value >>> 8) & 255, (value >>> 16) & 255, (value >>> 24) & 255]);
}

function putUint32BE(data: Uint8Array, offset: number, value: number): void {
  data[offset] = (value >>> 24) & 255;
  data[offset + 1] = (value >>> 16) & 255;
  data[offset + 2] = (value >>> 8) & 255;
  data[offset + 3] = value & 255;
}

function u32le(data: Uint8Array, offset: number): number {
  return (data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)) >>> 0;
}

function rotl32(value: number, bits: number): number {
  const shift = bits & 31;
  if (shift === 0) {
    return value >>> 0;
  }
  return ((value << shift) | (value >>> (32 - shift))) >>> 0;
}

function rotl8(value: number, bits: number): number {
  return ((value << bits) | (value >>> (8 - bits))) & 255;
}

function rotl64(value: bigint, bits: number): bigint {
  const shift = ((bits % 64) + 64) % 64;
  if (shift === 0) {
    return value & MASK64;
  }
  return ((value << BigInt(shift)) | (value >> BigInt(64 - shift))) & MASK64;
}

function readU64le(data: Uint8Array, offset: number): bigint {
  let value = 0n;
  for (let i = 7; i >= 0; i--) {
    value = (value << 8n) | BigInt(data[offset + i]);
  }
  return value;
}

function writeU64le(data: Uint8Array, offset: number, value: bigint): void {
  let v = value;
  for (let i = 0; i < 8; i++) {
    data[offset + i] = Number(v & 0xffn);
    v >>= 8n;
  }
}

function base64(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

// ---------- protobuf 变长编码（数值走 zigzag） ----------

function appendUvarint(out: number[], value: bigint): void {
  let v = value;
  while (v >= 0x80n) {
    out.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  out.push(Number(v));
}

/** 字段类型：0 = 数值（zigzag varint），1 = 文本，2 = 原始字节 */
class V5Field {
  tag: number = 0;
  kind: number = 0;
  num: bigint = 0n;
  text: string = '';
  data: Uint8Array = new Uint8Array(0);
}

function fNum(tag: number, value: number): V5Field {
  const field = new V5Field();
  field.tag = tag;
  field.kind = 0;
  field.num = BigInt(Math.trunc(value));
  return field;
}

function fText(tag: number, value: string): V5Field {
  const field = new V5Field();
  field.tag = tag;
  field.kind = 1;
  field.text = value;
  return field;
}

function fBytes(tag: number, value: Uint8Array): V5Field {
  const field = new V5Field();
  field.tag = tag;
  field.kind = 2;
  field.data = value;
  return field;
}

function v5Proto(fields: V5Field[]): Uint8Array {
  const out: number[] = [];
  for (const field of fields) {
    if (field.kind === 0) {
      appendUvarint(out, BigInt(field.tag * 8));
      const zigzag = field.num < 0n ? -field.num * 2n - 1n : field.num * 2n;
      appendUvarint(out, zigzag);
    } else {
      const bytes = field.kind === 1 ? utf8(field.text) : field.data;
      if (bytes.length !== 0) {
        appendUvarint(out, BigInt(field.tag * 8 + 2));
        appendUvarint(out, BigInt(bytes.length));
        for (let i = 0; i < bytes.length; i++) {
          out.push(bytes[i]);
        }
      }
    }
  }
  return new Uint8Array(out);
}

// ---------- V5 哈希 ----------

function v5IV(queryHashBytes: Uint8Array, bodyMd5Bytes: Uint8Array, ts: number): number {
  let value = 0x20230928;
  const parts: Uint8Array[] = [queryHashBytes, bodyMd5Bytes, le32(ts)];
  for (const data of parts) {
    for (let index = 0; index < data.length; index++) {
      value = (index & 1) === 0
        ? (value >>> 4) ^ value ^ (value << 6) ^ data[index]
        : ~((value >>> 7) ^ value ^ (data[index] | (value << 12)));
    }
  }
  return value;
}

function v5Hash(queryHashBytes: Uint8Array, bodyMd5Bytes: Uint8Array, ts: number): Uint8Array {
  if (queryHashBytes.length !== 32 || bodyMd5Bytes.length !== 16) {
    throw new Error('V5 哈希要求 32 字节 query 哈希与 16 字节 body 哈希');
  }
  if ((v5IV(queryHashBytes, bodyMd5Bytes, ts) & 15) !== 12) {
    throw new Error('不支持的 V5 哈希分支');
  }
  const iv = 0x9d4a97c2;
  const count = (iv + ts) | 0;
  const table: number[] = [];
  for (const value of V5_HASH_TABLE) {
    table.push(rotl32(value, -((count + 1) & 255)));
  }
  const shift = (count + 2) & 7;
  const paddingSource: number[] = [0xfa, 0x45, 0x61, 0xd7];
  const padding = new Uint8Array(4);
  for (let i = 0; i < 4; i++) {
    padding[i] = ((paddingSource[i] | (paddingSource[i] << 8)) >>> shift) & 255;
  }
  const data = concat([queryHashBytes, bodyMd5Bytes, le32(ts), padding, new Uint8Array([0, 0, 0, 0, 0, 0, 1, 0xa0])]);

  const words: number[] = [];
  for (let index = 0; index < data.length; index += 4) {
    words.push((data[index] << 24) | (data[index + 1] << 16) | (data[index + 2] << 8) | data[index + 3]);
  }
  for (let index = 0; index < 112; index++) {
    const x = words[index + 1];
    const y = words[index + 14];
    words.push((words[index] + words[index + 9] +
      (rotl32(x, 14) ^ rotl32(x, 25) ^ (x >>> 3)) +
      (rotl32(y, 13) ^ rotl32(y, 15) ^ (y >>> 10))) | 0);
  }

  const initialSource: number[] = [
    0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
    984304912, 3005047866, 2874125293, 2152413264
  ];
  const initial: number[] = [];
  for (const value of initialSource) {
    initial.push(rotl32(value, -count));
  }
  const state: number[] = initial.slice();

  for (let index = 0; index < 96; index++) {
    const base = (iv + index) | 0;
    const choose = ((state[4] ^ state[0]) & state[1]) ^ state[4];
    const sigma1 = rotl32(state[1], 26) ^ rotl32(state[1], 21) ^ rotl32(state[1], 7);
    const mixed = (words[base & 127] + choose + sigma1 + table[base & 63] + state[6]) | 0;
    const sigma0 = rotl32(state[3], 30) ^ rotl32(state[3], 19) ^ rotl32(state[3], 10);
    const majority = (state[3] & state[5]) | ((state[3] | state[5]) & state[2]);
    const old = state[7];
    const popped = state.pop();
    state.unshift(popped === undefined ? 0 : popped);
    state[7] = (sigma0 + majority + mixed) | 0;
    state[0] = (old + mixed) | 0;
  }

  const digest = new Uint8Array(32);
  for (let index = 0; index < 8; index++) {
    putUint32BE(digest, index * 4, (state[index] + initial[index]) | 0);
  }
  const folded = new Uint8Array(16);
  for (let index = 0; index < 16; index++) {
    folded[index] = digest[index] ^ digest[index + 16];
  }
  let check = 0x20220420;
  for (let index = 0; index < 12; index++) {
    const even = (index & 1) === 0;
    const temp = (check >>> (even ? 3 : 5)) ^ check;
    check = (even ? folded[index] ^ (check << 7) : ~(folded[index] | (check << 11))) ^ temp;
  }
  return concat([folded, le32(((check | 4) ^ 0x1000000) | 0x20)]);
}

// ---------- V5 载荷加密 ----------

function carrierXt(value: number): number {
  return ((value << 1) ^ ((value & 128) !== 0 ? 0x1b : 0)) & 255;
}

function carrierAddCon(rows: number[][], expanded: Uint8Array, con: number[], offset: number): void {
  for (let i = 0; i < 4; i++) {
    for (let j = 0; j < 4; j++) {
      rows[i][j] ^= expanded[(offset + i) * 4 + con[j]];
    }
  }
}

function carrierBlock(value: Uint8Array, expanded: Uint8Array, box: Uint8Array,
  con: number[], order: number[]): Uint8Array {
  let rows: number[][] = [];
  for (let i = 0; i < 4; i++) {
    const row: number[] = [];
    for (let j = 0; j < 4; j++) {
      row.push(value[i * 4 + j]);
    }
    rows.push(row);
  }
  carrierAddCon(rows, expanded, con, 0);
  for (let round = 1; round <= 2; round++) {
    // SubBytes
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 4; j++) {
        rows[i][j] = box[rows[i][j]];
      }
    }
    // 行重排
    const before: number[][] = [];
    for (const row of rows) {
      before.push(row.slice());
    }
    rows = [];
    for (const index of con) {
      rows.push(before[index]);
    }
    // order 换位
    const flat: number[] = [];
    for (const row of rows) {
      for (const v of row) {
        flat.push(v);
      }
    }
    for (let index = 0; index < 16; index++) {
      rows[Math.floor(index / 4)][index % 4] = flat[order[index]];
    }
    if (round === 1) {
      // 列重排
      const permuted: number[][] = [];
      for (const row of rows) {
        const copy: number[] = [];
        for (const index of con) {
          copy.push(row[index]);
        }
        permuted.push(copy);
      }
      rows = permuted;
      // 列混合
      for (let index = 0; index < 4; index++) {
        const mixed = rows[0][index] ^ rows[1][index] ^ rows[2][index] ^ rows[3][index];
        const first = rows[0][index];
        rows[0][index] ^= mixed ^ carrierXt(rows[0][index] ^ rows[1][index]);
        rows[1][index] ^= mixed ^ carrierXt(rows[1][index] ^ rows[2][index]);
        rows[2][index] ^= mixed ^ carrierXt(rows[2][index] ^ rows[3][index]);
        rows[3][index] ^= mixed ^ carrierXt(rows[3][index] ^ first);
      }
    }
    carrierAddCon(rows, expanded, con, round * 4);
  }
  // 末轮密钥
  const out = new Uint8Array(16);
  for (let i = 0; i < 4; i++) {
    for (let j = 0; j < 4; j++) {
      out[i * 4 + j] = rows[i][j] ^ expanded[(4 + i) * 4 + j];
    }
  }
  return out;
}

function carrier(keyBytes: Uint8Array, ivBytes: Uint8Array, sourceBytes: Uint8Array, ts: number): Uint8Array {
  if (keyBytes.length !== 16 || ivBytes.length !== 16 || sourceBytes.length < 248) {
    throw new Error('V5 载荷要求 16 字节密钥 / IV 且源数据不少于 248 字节');
  }
  const sbox = fromHex(V5_SBOX_HEX);
  const variant = ts & 3;
  const box = sbox.subarray(variant * 256, (variant + 1) * 256);
  const con = CARRIER_CON[variant];
  const order = CARRIER_ORDER[variant];
  const initial = CARRIER_INITIAL[variant];
  const initialBytes = le32(initial);

  const expanded = new Uint8Array(48);
  for (let index = 0; index < 16; index++) {
    expanded[index] = initialBytes[index & 3] ^ keyBytes[index];
  }
  let rounds = 8;
  for (let index = 4; index < 12; index++) {
    const at = 4 * (index - 1);
    let a = expanded[at];
    let b = expanded[at + 1];
    let c = expanded[at + 2];
    let d = expanded[at + 3];
    if ((index & 3) === 0) {
      const next = ((initial >> (rounds & 24)) ^ box[b]) & 255;
      b = box[c];
      c = box[d];
      d = box[a];
      a = next;
    }
    rounds += 2;
    expanded[at + 4] = a ^ expanded[at - 12];
    expanded[at + 5] = b ^ expanded[at - 11];
    expanded[at + 6] = c ^ expanded[at - 10];
    expanded[at + 7] = d ^ expanded[at - 9];
  }

  const wire: number[] = [6, 5, 3, 4, 2, 7, 1, 0];
  const compact: number[] = [1, 7, 3, 6, 2, 0, 4, 5];
  const plaintext = new Uint8Array(32);
  for (let i = 0; i < 31; i++) {
    for (let j = 0; j < 8; j++) {
      plaintext[i] |= ((sourceBytes[i * 8 + j] >>> wire[j]) & 1) << compact[j];
    }
  }
  plaintext[31] = 1;

  const input = new Uint8Array(16);
  for (let index = 0; index < 16; index++) {
    input[index] = plaintext[index] ^ ivBytes[index];
  }
  const first = carrierBlock(input, expanded, box, con, order);
  for (let index = 0; index < 16; index++) {
    input[index] = plaintext[index + 16] ^ first[index];
  }
  const key = concat([first, carrierBlock(input, expanded, box, con, order)]);

  const out = new Uint8Array(sourceBytes.length + 1);
  out[0] = key[31];
  out.set(sourceBytes, 1);
  for (let i = 0; i < 31; i++) {
    for (let j = 0; j < 8; j++) {
      const at = 1 + i * 8 + j;
      out[at] = (out[at] & ~(1 << wire[j])) | (((key[i] >>> compact[j]) & 1) << wire[j]);
    }
  }
  return out;
}

// ---------- X-Helios / X-Medusa ----------

function v5Xmxor(data: Uint8Array, key: Uint8Array): Uint8Array {
  const encoded = new Uint8Array(data.length);
  for (let index = 0; index < data.length; index++) {
    const at = (index * 4) & 28;
    const d0 = key[at];
    const d1 = key[at + 1];
    let mixed = rotl8(data[index], 4) + d0;
    mixed = ~mixed ^ d1;
    mixed = rotl8(mixed & 255, 3);
    mixed = (mixed + d1) & 255;
    mixed ^= d0;
    encoded[data.length - index - 1] = ~mixed & 255;
  }
  const lastIndex = encoded.length - 1;
  const last = encoded[lastIndex] ^ encoded[lastIndex - 1];
  const first = encoded[0];
  encoded[0] = (~last + first) & 255;
  encoded[1] = ((encoded[0] ^ encoded[lastIndex] ^ 254) + encoded[1]) & 255;
  encoded[2] = (encoded[2] + ((last - first) ^ rotl8(encoded[1], 3) ^ 2)) & 255;
  for (let index = 0; index < encoded.length - 4; index++) {
    const mixed = rotl8(encoded[index + 2], 3) ^ encoded[index + 1] ^ (index + 3);
    encoded[index + 3] = (~mixed + encoded[index + 3]) & 255;
  }
  encoded[lastIndex] ^= encoded[lastIndex - 1];
  let sum = 0;
  for (let index = 1; index < encoded.length; index++) {
    sum += encoded[index];
  }
  encoded[0] = ((encoded[0] ^ encoded[1]) + sum) & 255;
  return encoded;
}

function v5Helios(ts: number): string {
  const prefix = randomBytes(4);
  const ascii = utf8(toHex(md5(concat([prefix, utf8('8662')]))));
  let left = readU64le(ascii, 0);
  let right = readU64le(ascii, 8);
  const queue: bigint[] = [readU64le(ascii, 16), readU64le(ascii, 24)];
  const keys: bigint[] = [];
  for (let index = 0; index < 34; index++) {
    keys.push(left);
    const mixed = ((rotl64(right, -8) + left) & MASK64) ^ BigInt(index);
    queue.push(mixed);
    left = mixed ^ rotl64(left, 3);
    const shifted = queue.shift();
    right = shifted === undefined ? 0n : shifted;
  }
  const data = pad16(utf8(`${ts}-646637794-8662`));
  for (let offset = 0; offset < data.length; offset += 16) {
    let a = readU64le(data, offset);
    let b = readU64le(data, offset + 8);
    for (const key of keys) {
      b = key ^ ((a + rotl64(b, -8)) & MASK64);
      a = b ^ rotl64(a, 3);
    }
    writeU64le(data, offset, a);
    writeU64le(data, offset + 8, b);
  }
  return base64(concat([prefix, data]));
}

interface V5Who {
  deviceId: string;
  versionName: string;
  osVersion: string;
  deviceType: string;
  channel: string;
  deviceBrand: string;
}

function v5Medusa(queryHash: Uint8Array, f13: Uint8Array, ts: number, who: V5Who, nowMs: number): string {
  if (processNonce.length === 0) {
    let nonceText = base64(randomBytes(18));
    nonceText = nonceText.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    processNonce = nonceText;
    processStarted = nowMs;
  }
  const magic = fromHex(V5_MAGIC_HEX);
  const signKey = fromHex(V5_SIGN_KEY_HEX);
  const flags = new Uint8Array(8);
  const deviceInfo = v5Proto([
    fNum(1, 1), fNum(2, 2), fText(3, '8662'), fText(4, who.deviceId), fText(5, processNonce),
    fText(6, '!noperm!'), fText(12, 'Asia/Shanghai,8'), fText(13, 'zh_CN'), fText(22, who.osVersion),
    fNum(25, processStarted), fText(30, who.deviceType), fText(31, who.deviceBrand),
    fText(32, who.deviceType), fText(34, who.deviceBrand)
  ]);
  const env = v5Proto([
    fText(6, 'v04.10.03.04-bugfix'), fText(8, who.channel), fBytes(12, deviceInfo), fText(14, who.versionName)
  ]);
  const message = v5Proto([
    fBytes(1, magic), fNum(2, 5), fNum(3, u32le(randomBytes(4), 0)), fText(4, '8662'),
    fText(5, who.deviceId), fText(6, '646637794'), fText(7, who.versionName), fText(8, 'v04.10.03-ml-android'),
    fNum(9, 0x040a0300), fBytes(10, flags), fNum(12, ts), fBytes(13, f13), fBytes(14, queryHash.subarray(0, 6)),
    fBytes(15, v5Proto([fNum(1, 1), fNum(2, 1), fNum(3, 1), fNum(5, 1)])), fNum(17, ts), fText(20, 'none'),
    fNum(21, 377), fBytes(23, env),
    fText(24, '{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}')
  ]);
  const nonce = u32le(randomBytes(4), 0);
  const hash = sm3(concat([signKey, le32(nonce), signKey]));
  const high = (nonce >>> 16) & 255;
  const seed = le32(~(((high << 11) | (nonce >>> 24)) ^ (high >>> 5) ^ high));
  const transformed = concat([flags, v5Xmxor(message, hash)]).reverse();
  for (let index = 0; index < transformed.length; index++) {
    transformed[index] ^= seed[(~index) & 3];
  }
  const check = 0x18000001 | ((queryHash[0] & 63) << 14) | ((f13[0] & 63) << 8);
  const packed = concat([
    new Uint8Array([0xca]), randomBytes(4), le32(check), transformed,
    new Uint8Array([(nonce >>> 16) & 255, (nonce >>> 24) & 255])
  ]);
  const encrypted = carrier(
    md5(signKey.subarray(0, 16)),
    md5(signKey.subarray(16, 32)),
    packed,
    ts
  );
  const prefix = concat([le32(5), magic]);
  const stamp = le32(ts);
  for (let index = 0; index < prefix.length; index++) {
    prefix[index] ^= stamp[index & 3];
  }
  return base64(concat([prefix, new Uint8Array([nonce & 255, (nonce >>> 8) & 255, 0, 1]), encrypted]));
}

// ---------- 签名入口 ----------

function queryValue(query: string, name: string): string {
  const parts = query.split('&');
  for (const part of parts) {
    if (part.length === 0) {
      continue;
    }
    const separator = part.indexOf('=');
    const key = separator < 0 ? part : part.substring(0, separator);
    if (key === name) {
      if (separator < 0) {
        return '';
      }
      const value = part.substring(separator + 1).replace(/\+/g, ' ');
      try {
        return decodeURIComponent(value);
      } catch (error) {
        return value;
      }
    }
  }
  return '';
}

export class PlaybackSignedRequest {
  url: string = '';
  headers: Record<string, string> = {};
}

/**
 * V5 播放签名：在 1024 次 ticket 探测内找到满足 (iv & 15) === 12 的 _rticket，
 * 产出 X-Khronos / X-Helios / X-Medusa（+ 有 body 时的 X-SS-STUB）。
 * params 会被写入 _rticket，调用方须传入独占的 Map。
 */
export function signPlaybackV5(base: string, params: Map<string, string[]>,
  bodyBytes: Uint8Array | null, nowMs: number): PlaybackSignedRequest {
  const ts = Math.floor(nowMs / 1000) | 0;
  const hasBody = bodyBytes !== null;
  const bodyMd5 = hasBody && bodyBytes !== null ? md5(bodyBytes) : new Uint8Array(16);

  for (let offset = 0; offset < 1024; offset++) {
    params.set('_rticket', [(nowMs + offset).toString()]);
    const query = encodeQuery(params);
    const queryHash = sm3(utf8(query));
    if ((v5IV(queryHash, bodyMd5, ts) & 15) !== 12) {
      continue;
    }
    const whoNames: string[] = ['device_id', 'version_name', 'os_version', 'device_type', 'channel'];
    const whoValues: string[] = [];
    for (const name of whoNames) {
      const value = queryValue(query, name);
      if (value.length === 0) {
        throw new Error(`播放签名缺少设备字段：${name}`);
      }
      whoValues.push(value);
    }
    const brandRaw = queryValue(query, 'device_brand');
    const who: V5Who = {
      deviceId: whoValues[0],
      versionName: whoValues[1],
      osVersion: whoValues[2],
      deviceType: whoValues[3],
      channel: whoValues[4],
      deviceBrand: brandRaw.length === 0 ? 'HONOR' : brandRaw
    };
    const f13 = v5Hash(queryHash, bodyMd5, ts);
    const result = new PlaybackSignedRequest();
    result.url = `${base}?${query}`;
    result.headers['X-Khronos'] = ts.toString();
    result.headers['X-Helios'] = v5Helios(ts);
    result.headers['X-Medusa'] = v5Medusa(queryHash, f13, ts, who, nowMs);
    if (hasBody && bodyBytes !== null) {
      result.headers['X-SS-STUB'] = toHexUpper(md5(bodyBytes));
      result.headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    return result;
  }
  throw new Error('无法在 1024 次 ticket 尝试内生成 V5 播放签名');
}
