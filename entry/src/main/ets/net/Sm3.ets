/**
 * SM3 摘要算法（GB/T 32905-2016）。
 * 内容源风控头 X-Argus 依赖 SM3，鸿蒙侧没有直接可用的同步实现，这里用纯 TS 补上，
 * 保证签名计算可以在 UI 线程外同步完成。
 */

const IV: number[] = [
  0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
  0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e
];

function rotl(x: number, n: number): number {
  const s = n & 31;
  if (s === 0) {
    return x >>> 0;
  }
  return ((x << s) | (x >>> (32 - s))) >>> 0;
}

function p0(x: number): number {
  return (x ^ rotl(x, 9) ^ rotl(x, 17)) >>> 0;
}

function p1(x: number): number {
  return (x ^ rotl(x, 15) ^ rotl(x, 23)) >>> 0;
}

function ff(x: number, y: number, z: number, j: number): number {
  return j < 16 ? (x ^ y ^ z) >>> 0 : ((x & y) | (x & z) | (y & z)) >>> 0;
}

function gg(x: number, y: number, z: number, j: number): number {
  return j < 16 ? (x ^ y ^ z) >>> 0 : ((x & y) | (~x & z)) >>> 0;
}

export function sm3(input: Uint8Array): Uint8Array {
  const len = input.length;
  const padTail = (len % 64) < 56 ? 56 - (len % 64) : 120 - (len % 64);
  const total = len + padTail + 8;

  const msg = new Uint8Array(total);
  msg.set(input, 0);
  msg[len] = 0x80;

  // 64 位比特长度，大端写入
  const hi = Math.floor(len / 536870912); // len * 8 / 2^32
  const lo = (len * 8) % 4294967296;
  msg[total - 8] = (hi >>> 24) & 0xff;
  msg[total - 7] = (hi >>> 16) & 0xff;
  msg[total - 6] = (hi >>> 8) & 0xff;
  msg[total - 5] = hi & 0xff;
  msg[total - 4] = (lo >>> 24) & 0xff;
  msg[total - 3] = (lo >>> 16) & 0xff;
  msg[total - 2] = (lo >>> 8) & 0xff;
  msg[total - 1] = lo & 0xff;

  const v: number[] = IV.slice();
  const w: number[] = new Array<number>(68).fill(0);
  const w1: number[] = new Array<number>(64).fill(0);

  for (let offset = 0; offset < total; offset += 64) {
    for (let j = 0; j < 16; j++) {
      const p = offset + j * 4;
      w[j] = ((msg[p] << 24) | (msg[p + 1] << 16) | (msg[p + 2] << 8) | msg[p + 3]) >>> 0;
    }
    for (let j = 16; j < 68; j++) {
      w[j] = (p1((w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) >>> 0) ^ rotl(w[j - 13], 7) ^ w[j - 6]) >>> 0;
    }
    for (let j = 0; j < 64; j++) {
      w1[j] = (w[j] ^ w[j + 4]) >>> 0;
    }

    let a = v[0];
    let b = v[1];
    let c = v[2];
    let d = v[3];
    let e = v[4];
    let f = v[5];
    let g = v[6];
    let h = v[7];

    for (let j = 0; j < 64; j++) {
      const t = j < 16 ? 0x79cc4519 : 0x7a879d8a;
      const a12 = rotl(a, 12);
      const ss1 = rotl((a12 + e + rotl(t, j)) >>> 0, 7);
      const ss2 = (ss1 ^ a12) >>> 0;
      const tt1 = (ff(a, b, c, j) + d + ss2 + w1[j]) >>> 0;
      const tt2 = (gg(e, f, g, j) + h + ss1 + w[j]) >>> 0;

      d = c;
      c = rotl(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = rotl(f, 19);
      f = e;
      e = p0(tt2);
    }

    v[0] = (v[0] ^ a) >>> 0;
    v[1] = (v[1] ^ b) >>> 0;
    v[2] = (v[2] ^ c) >>> 0;
    v[3] = (v[3] ^ d) >>> 0;
    v[4] = (v[4] ^ e) >>> 0;
    v[5] = (v[5] ^ f) >>> 0;
    v[6] = (v[6] ^ g) >>> 0;
    v[7] = (v[7] ^ h) >>> 0;
  }

  const out = new Uint8Array(32);
  for (let i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (v[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (v[i] >>> 8) & 0xff;
    out[i * 4 + 3] = v[i] & 0xff;
  }
  return out;
}
