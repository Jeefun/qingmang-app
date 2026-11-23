/**
 * 站源模块运行时的宿主环境（注入隐藏 Web 沙箱页面）。
 *
 * 上游契约（api:1）：模块以 CommonJS 形式书写，执行时注入全局 `host`，
 * 全部宿主 API 为同步语义。本文件把宿主环境在页面内用纯 JS 实现：
 *   - 同步 XHR 承载 host.fetchText / host.fetch（页面 origin 经 loadData
 *     的 baseUrl 设为模块站点，请求天然同域；跨域请求显式抛出明确错误，
 *     模块按自身逻辑降级到网页回退路径）；
 *   - md5 / sha256 / sha512 / aes / gcm / ecdh / hkdf / gzip 全部纯 JS 实现，
 *     摘要常数运行时由素数经整数大数根（Newton 迭代）生成，避免手抄错误；
 *   - cacheSet / saveState 经 400ms 防抖写回原生侧（filesDir/modules-state），
 *     页面重建时从注入的 __QM_PERSIST__ 恢复；
 *   - 域名白名单取清单 hosts / aliases / hostSuffixes / baseUrl，
 *     `*.` 前缀匹配子域，hosts 为空不限制。
 *
 * 宿主内部实现全部封在第一个 IIFE 里，与模块代码（第二个 IIFE）隔离，
 * 模块顶层声明不会遮蔽宿主内部函数。
 *
 * 文件尾部的 /*__QM_MODULE__*\/ 占位：运行时会把模块 main.js 源码
 * 替换进去并执行，随后 window.__qmModule 即模块导出对象。
 */
(function () {
  var SOURCE_ID = window.__QM_SOURCE_ID__;
  var MANIFEST = window.__QM_MANIFEST__ || {};
  var PERSIST = window.__QM_PERSIST__ || {};

  // ---------------- 基础字节工具 ----------------

  var textEncoder = new TextEncoder();
  var textDecoder = new TextDecoder('utf-8');

  /** 任意字节输入（Uint8Array / 数组 / 数字 / 字符串按 UTF-8）归一为 Uint8Array */
  function toBytes(input) {
    if (input instanceof Uint8Array) {
      return input;
    }
    if (Array.isArray(input)) {
      var out = new Uint8Array(input.length);
      for (var i = 0; i < input.length; i++) {
        var n = Number(input[i]);
        out[i] = Number.isFinite(n) ? (n & 0xff) : 0;
      }
      return out;
    }
    if (typeof input === 'number' && Number.isFinite(input)) {
      var one = new Uint8Array(1);
      one[0] = input & 0xff;
      return one;
    }
    if (typeof input === 'string') {
      return textEncoder.encode(input);
    }
    throw new Error('字节参数类型无效');
  }

  function utf8Encode(text) {
    return textEncoder.encode(String(text === undefined || text === null ? '' : text));
  }

  function utf8Decode(input) {
    return textDecoder.decode(toBytes(input));
  }

  function bytesToBinaryString(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  }

  function binaryStringToBytes(text) {
    var out = new Uint8Array(text.length);
    for (var i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xff;
    }
    return out;
  }

  function hexEncode(input) {
    var bytes = toBytes(input);
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += bytes[i] < 16 ? '0' + bytes[i].toString(16) : bytes[i].toString(16);
    }
    return out;
  }

  function hexDecode(input) {
    if (typeof input !== 'string') {
      input = utf8Decode(input);
    }
    var clean = input.replace(/[^0-9a-fA-F]/g, '');
    if (clean.length % 2 !== 0) {
      throw new Error('十六进制串长度无效');
    }
    var out = new Uint8Array(clean.length / 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = parseInt(clean.substring(i * 2, i * 2 + 2), 16);
    }
    return out;
  }

  function base64Encode(input) {
    return btoa(bytesToBinaryString(toBytes(input)));
  }

  function base64Decode(input) {
    if (typeof input !== 'string') {
      input = utf8Decode(input);
    }
    var clean = input.replace(/[\s\r\n]+/g, '');
    return binaryStringToBytes(atob(clean));
  }

  function concatBytes() {
    var parts = [];
    var total = 0;
    for (var i = 0; i < arguments.length; i++) {
      var part = toBytes(arguments[i]);
      parts.push(part);
      total += part.length;
    }
    var out = new Uint8Array(total);
    var off = 0;
    for (var j = 0; j < parts.length; j++) {
      out.set(parts[j], off);
      off += parts[j].length;
    }
    return out;
  }

  function bigintFromBytes(bytes) {
    var v = 0n;
    for (var i = 0; i < bytes.length; i++) {
      v = (v << 8n) | BigInt(bytes[i]);
    }
    return v;
  }

  function bytesFromBigint(value, length) {
    var out = new Uint8Array(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = Number(v & 0xffn);
      v >>= 8n;
    }
    return out;
  }

  // ---------------- 素数表与大数根（摘要常数运行时生成） ----------------

  var PRIMES = (function () {
    var list = [];
    var candidate = 2;
    while (list.length < 80) {
      var ok = true;
      for (var i = 0; i < list.length; i++) {
        if (list[i] * list[i] > candidate) {
          break;
        }
        if (candidate % list[i] === 0) {
          ok = false;
          break;
        }
      }
      if (ok) {
        list.push(candidate);
      }
      candidate++;
    }
    return list;
  })();

  function bigBitLength(n) {
    var bits = 0;
    while (n > 0n) {
      bits++;
      n >>= 1n;
    }
    return bits;
  }

  function bigSqrtFloor(n) {
    if (n < 2n) {
      return n;
    }
    var x = 1n << BigInt(Math.ceil(bigBitLength(n) / 2) + 1);
    while (true) {
      var y = (x + n / x) >> 1n;
      if (y >= x) {
        return x;
      }
      x = y;
    }
  }

  function bigCbrtFloor(n) {
    if (n < 2n) {
      return n;
    }
    var x = 1n << BigInt(Math.ceil(bigBitLength(n) / 3) + 1);
    while (true) {
      var y = (2n * x + n / (x * x)) / 3n;
      if (y >= x) {
        return x;
      }
      x = y;
    }
  }

  /** sqrt(p) 小数部分的定点表示（fracBits 位，BigInt） */
  function fracSqrtBits(p, fracBits) {
    var scaled = bigSqrtFloor(BigInt(p) << BigInt(2 * fracBits));
    var whole = bigSqrtFloor(BigInt(p));
    return scaled - (whole << BigInt(fracBits));
  }

  /** cbrt(p) 小数部分的定点表示（fracBits 位，BigInt） */
  function fracCbrtBits(p, fracBits) {
    var scaled = bigCbrtFloor(BigInt(p) << BigInt(3 * fracBits));
    var whole = bigCbrtFloor(BigInt(p));
    return scaled - (whole << BigInt(fracBits));
  }

  // ---------------- MD5 ----------------

  var MD5_K = (function () {
    var table = new Uint32Array(64);
    for (var i = 0; i < 64; i++) {
      table[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296);
    }
    return table;
  })();

  var MD5_S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];

  function md5Bytes(input) {
    var msg = toBytes(input);
    var len = msg.length;
    var blocks = (((len + 8) >>> 6) + 1) << 6;
    var padded = new Uint8Array(blocks);
    padded.set(msg);
    padded[len] = 0x80;
    var bitLenLo = (len << 3) >>> 0;
    var bitLenHi = Math.floor(len / 0x20000000);
    var dv = blocks - 8;
    padded[dv] = bitLenLo & 0xff;
    padded[dv + 1] = (bitLenLo >>> 8) & 0xff;
    padded[dv + 2] = (bitLenLo >>> 16) & 0xff;
    padded[dv + 3] = (bitLenLo >>> 24) & 0xff;
    padded[dv + 4] = bitLenHi & 0xff;
    padded[dv + 5] = (bitLenHi >>> 8) & 0xff;
    padded[dv + 6] = (bitLenHi >>> 16) & 0xff;
    padded[dv + 7] = (bitLenHi >>> 24) & 0xff;

    var a0 = 0x67452301 | 0;
    var b0 = 0xefcdab89 | 0;
    var c0 = 0x98badcfe | 0;
    var d0 = 0x10325476 | 0;
    var M = new Uint32Array(16);
    for (var chunk = 0; chunk < blocks; chunk += 64) {
      for (var j = 0; j < 16; j++) {
        var o = chunk + j * 4;
        M[j] = padded[o] | (padded[o + 1] << 8) | (padded[o + 2] << 16) | (padded[o + 3] << 24);
      }
      var A = a0;
      var B = b0;
      var C = c0;
      var D = d0;
      for (var r = 0; r < 64; r++) {
        var F = 0;
        var g = 0;
        if (r < 16) {
          F = (B & C) | (~B & D);
          g = r;
        } else if (r < 32) {
          F = (D & B) | (~D & C);
          g = (5 * r + 1) % 16;
        } else if (r < 48) {
          F = B ^ C ^ D;
          g = (3 * r + 5) % 16;
        } else {
          F = C ^ (B | ~D);
          g = (7 * r) % 16;
        }
        F = (F + A + MD5_K[r] + M[g]) | 0;
        A = D;
        D = C;
        C = B;
        var shift = MD5_S[r];
        B = (B + ((F << shift) | (F >>> (32 - shift)))) | 0;
      }
      a0 = (a0 + A) | 0;
      b0 = (b0 + B) | 0;
      c0 = (c0 + C) | 0;
      d0 = (d0 + D) | 0;
    }
    var out = new Uint8Array(16);
    var vals = [a0, b0, c0, d0];
    for (var k = 0; k < 4; k++) {
      out[k * 4] = vals[k] & 0xff;
      out[k * 4 + 1] = (vals[k] >>> 8) & 0xff;
      out[k * 4 + 2] = (vals[k] >>> 16) & 0xff;
      out[k * 4 + 3] = (vals[k] >>> 24) & 0xff;
    }
    return out;
  }

  // ---------------- SHA-256 ----------------

  function rotr32(x, n) {
    return ((x >>> n) | (x << (32 - n))) >>> 0;
  }

  var SHA256_K = (function () {
    var table = new Uint32Array(64);
    for (var i = 0; i < 64; i++) {
      table[i] = Number(fracCbrtBits(PRIMES[i], 64) >> 32n);
    }
    return table;
  })();

  var SHA256_H = (function () {
    var table = new Uint32Array(8);
    for (var i = 0; i < 8; i++) {
      table[i] = Number(fracSqrtBits(PRIMES[i], 64) >> 32n);
    }
    return table;
  })();

  function sha256Bytes(input) {
    var msg = toBytes(input);
    var len = msg.length;
    var blocks = (((len + 8) >>> 6) + 1) << 6;
    var padded = new Uint8Array(blocks);
    padded.set(msg);
    padded[len] = 0x80;
    var bitLenLo = (len << 3) >>> 0;
    var bitLenHi = Math.floor(len / 0x20000000);
    var dv = blocks - 8;
    padded[dv] = (bitLenHi >>> 24) & 0xff;
    padded[dv + 1] = (bitLenHi >>> 16) & 0xff;
    padded[dv + 2] = (bitLenHi >>> 8) & 0xff;
    padded[dv + 3] = bitLenHi & 0xff;
    padded[dv + 4] = (bitLenLo >>> 24) & 0xff;
    padded[dv + 5] = (bitLenLo >>> 16) & 0xff;
    padded[dv + 6] = (bitLenLo >>> 8) & 0xff;
    padded[dv + 7] = bitLenLo & 0xff;

    var H = SHA256_H.slice();
    var W = new Uint32Array(64);
    for (var chunk = 0; chunk < blocks; chunk += 64) {
      for (var j = 0; j < 16; j++) {
        var o = chunk + j * 4;
        W[j] = ((padded[o] << 24) | (padded[o + 1] << 16) | (padded[o + 2] << 8) | padded[o + 3]) >>> 0;
      }
      for (var j2 = 16; j2 < 64; j2++) {
        var s0 = rotr32(W[j2 - 15], 7) ^ rotr32(W[j2 - 15], 18) ^ (W[j2 - 15] >>> 3);
        var s1 = rotr32(W[j2 - 2], 17) ^ rotr32(W[j2 - 2], 19) ^ (W[j2 - 2] >>> 10);
        W[j2] = (W[j2 - 16] + s0 + W[j2 - 7] + s1) | 0;
      }
      var a = H[0];
      var b = H[1];
      var c = H[2];
      var d = H[3];
      var e = H[4];
      var f = H[5];
      var g = H[6];
      var h = H[7];
      for (var r = 0; r < 64; r++) {
        var S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        var ch = (e & f) ^ (~e & g);
        var t1 = (h + S1 + ch + SHA256_K[r] + W[r]) | 0;
        var S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) | 0;
        h = g;
        g = f;
        f = e;
        e = (d + t1) | 0;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) | 0;
      }
      H[0] = (H[0] + a) | 0;
      H[1] = (H[1] + b) | 0;
      H[2] = (H[2] + c) | 0;
      H[3] = (H[3] + d) | 0;
      H[4] = (H[4] + e) | 0;
      H[5] = (H[5] + f) | 0;
      H[6] = (H[6] + g) | 0;
      H[7] = (H[7] + h) | 0;
    }
    var out = new Uint8Array(32);
    for (var k = 0; k < 8; k++) {
      out[k * 4] = (H[k] >>> 24) & 0xff;
      out[k * 4 + 1] = (H[k] >>> 16) & 0xff;
      out[k * 4 + 2] = (H[k] >>> 8) & 0xff;
      out[k * 4 + 3] = H[k] & 0xff;
    }
    return out;
  }

  // ---------------- SHA-512 ----------------

  var M64 = 0xffffffffffffffffn;

  function rotr64(x, n) {
    return ((x >> BigInt(n)) | (x << BigInt(64 - n))) & M64;
  }

  var SHA512_K = (function () {
    var table = [];
    for (var i = 0; i < 80; i++) {
      table.push(fracCbrtBits(PRIMES[i], 128) >> 64n);
    }
    return table;
  })();

  var SHA512_H = (function () {
    var table = [];
    for (var i = 0; i < 8; i++) {
      table.push(fracSqrtBits(PRIMES[i], 128) >> 64n);
    }
    return table;
  })();

  function sha512Bytes(input) {
    var msg = toBytes(input);
    var len = msg.length;
    var blocks = (((len + 16) >>> 7) + 1) << 7;
    var padded = new Uint8Array(blocks);
    padded.set(msg);
    padded[len] = 0x80;
    var bitLen = BigInt(len) * 8n;
    var dv = blocks - 8;
    var tail = bytesFromBigint(bitLen, 8).reverse();
    for (var t = 0; t < 8; t++) {
      padded[dv + t] = tail[t];
    }

    var H = SHA512_H.slice();
    var W = new Array(80);
    for (var chunk = 0; chunk < blocks; chunk += 128) {
      for (var j = 0; j < 16; j++) {
        var o = chunk + j * 8;
        W[j] = bigintFromBytes(padded.subarray(o, o + 8));
      }
      for (var j2 = 16; j2 < 80; j2++) {
        var s0 = rotr64(W[j2 - 15], 1) ^ rotr64(W[j2 - 15], 8) ^ (W[j2 - 15] >> 7n);
        var s1 = rotr64(W[j2 - 2], 19) ^ rotr64(W[j2 - 2], 61) ^ (W[j2 - 2] >> 6n);
        W[j2] = (W[j2 - 16] + s0 + W[j2 - 7] + s1) & M64;
      }
      var a = H[0];
      var b = H[1];
      var c = H[2];
      var d = H[3];
      var e = H[4];
      var f = H[5];
      var g = H[6];
      var h = H[7];
      for (var r = 0; r < 80; r++) {
        var S1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
        var ch = (e & f) ^ (~e & g);
        var t1 = (h + S1 + ch + SHA512_K[r] + W[r]) & M64;
        var S0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) & M64;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & M64;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & M64;
      }
      H[0] = (H[0] + a) & M64;
      H[1] = (H[1] + b) & M64;
      H[2] = (H[2] + c) & M64;
      H[3] = (H[3] + d) & M64;
      H[4] = (H[4] + e) & M64;
      H[5] = (H[5] + f) & M64;
      H[6] = (H[6] + g) & M64;
      H[7] = (H[7] + h) & M64;
    }
    var out = new Uint8Array(64);
    for (var k = 0; k < 8; k++) {
      out.set(bytesFromBigint(H[k], 8), k * 8);
    }
    return out;
  }

  // ---------------- HMAC / HKDF ----------------

  function hmacBytes(hashFn, hashLen, key, data) {
    var keyBytes = toBytes(key);
    if (keyBytes.length > hashLen) {
      keyBytes = hashFn(keyBytes);
    }
    var pad = new Uint8Array(hashLen);
    pad.set(keyBytes);
    var inner = new Uint8Array(hashLen);
    var outer = new Uint8Array(hashLen);
    for (var i = 0; i < hashLen; i++) {
      inner[i] = pad[i] ^ 0x36;
      outer[i] = pad[i] ^ 0x5c;
    }
    return hashFn(concatBytes(outer, hashFn(concatBytes(inner, data))));
  }

  function hmacSha256(key, data) {
    return hmacBytes(sha256Bytes, 64, key, data);
  }

  function hkdfSha256(ikm, salt, info, length) {
    var saltBytes = toBytes(salt);
    if (saltBytes.length === 0) {
      saltBytes = new Uint8Array(32);
    }
    var prk = hmacSha256(saltBytes, ikm);
    var infoBytes = toBytes(info);
    var out = new Uint8Array(length);
    var offset = 0;
    var counter = 1;
    var previous = new Uint8Array(0);
    while (offset < length) {
      previous = hmacSha256(prk, concatBytes(previous, infoBytes, [counter]));
      var take = Math.min(previous.length, length - offset);
      out.set(previous.subarray(0, take), offset);
      offset += take;
      counter++;
    }
    return out;
  }

  // ---------------- AES（CBC / CTR，不含填充） ----------------

  var AES_EXP = (function () {
    var table = new Uint8Array(255);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      table[i] = x;
      x ^= (x << 1) ^ ((x & 0x80) !== 0 ? 0x11b : 0);
    }
    return table;
  })();

  var AES_LOG = (function () {
    var table = new Uint8Array(256);
    for (var i = 0; i < 255; i++) {
      table[AES_EXP[i]] = i;
    }
    return table;
  })();

  function aesMul(a, b) {
    var product = 0;
    for (var i = 0; i < 8; i++) {
      if ((b & 1) !== 0) {
        product ^= a;
      }
      var hi = a & 0x80;
      a = (a << 1) & 0xff;
      if (hi !== 0) {
        a ^= 0x1b;
      }
      b >>= 1;
    }
    return product & 0xff;
  }

  var AES_SBOX = (function () {
    var table = new Uint8Array(256);
    for (var i = 0; i < 256; i++) {
      if (i === 0) {
        table[0] = 0x63;
      } else {
        var inv = AES_EXP[(255 - AES_LOG[i]) % 255];
        var s = inv;
        s ^= ((inv << 1) | (inv >>> 7)) & 0xff;
        s ^= ((inv << 2) | (inv >>> 6)) & 0xff;
        s ^= ((inv << 3) | (inv >>> 5)) & 0xff;
        s ^= ((inv << 4) | (inv >>> 4)) & 0xff;
        table[i] = (s ^ 0x63) & 0xff;
      }
    }
    return table;
  })();

  var AES_INV_SBOX = (function () {
    var table = new Uint8Array(256);
    for (var i = 0; i < 256; i++) {
      table[AES_SBOX[i]] = i;
    }
    return table;
  })();

  var AES_RCON = (function () {
    var table = [1];
    for (var i = 1; i < 15; i++) {
      table.push(aesMul(table[i - 1], 2));
    }
    return table;
  })();

  function aesExpandKey(key) {
    var keyBytes = toBytes(key);
    if (keyBytes.length !== 16 && keyBytes.length !== 32) {
      throw new Error('AES 密钥长度仅支持 128/256 位');
    }
    var nk = keyBytes.length / 4;
    var rounds = nk + 6;
    var words = new Uint32Array(4 * (rounds + 1));
    for (var i = 0; i < nk; i++) {
      words[i] = ((keyBytes[i * 4] << 24) | (keyBytes[i * 4 + 1] << 16) |
        (keyBytes[i * 4 + 2] << 8) | keyBytes[i * 4 + 3]) >>> 0;
    }
    for (var j = nk; j < words.length; j++) {
      var temp = words[j - 1];
      if (j % nk === 0) {
        temp = (((temp << 8) | (temp >>> 24)) >>> 0);
        var b0 = AES_SBOX[(temp >>> 24) & 0xff];
        var b1 = AES_SBOX[(temp >>> 16) & 0xff];
        var b2 = AES_SBOX[(temp >>> 8) & 0xff];
        var b3 = AES_SBOX[temp & 0xff];
        temp = ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3) >>> 0;
        temp = (temp ^ (AES_RCON[j / nk - 1] << 24)) >>> 0;
      } else if (nk > 6 && j % nk === 4) {
        var c0 = AES_SBOX[(temp >>> 24) & 0xff];
        var c1 = AES_SBOX[(temp >>> 16) & 0xff];
        var c2 = AES_SBOX[(temp >>> 8) & 0xff];
        var c3 = AES_SBOX[temp & 0xff];
        temp = ((c0 << 24) | (c1 << 16) | (c2 << 8) | c3) >>> 0;
      }
      words[j] = (words[j - nk] ^ temp) >>> 0;
    }
    return { words: words, rounds: rounds };
  }

  function aesEncryptBlock(schedule, block) {
    var w = schedule.words;
    var rounds = schedule.rounds;
    var s = new Uint8Array(block);
    for (var i = 0; i < 16; i++) {
      s[i] ^= (w[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
    }
    for (var round = 1; round <= rounds; round++) {
      for (var j = 0; j < 16; j++) {
        s[j] = AES_SBOX[s[j]];
      }
      var shifted = new Uint8Array(16);
      shifted[0] = s[0];
      shifted[1] = s[5];
      shifted[2] = s[10];
      shifted[3] = s[15];
      shifted[4] = s[4];
      shifted[5] = s[9];
      shifted[6] = s[14];
      shifted[7] = s[3];
      shifted[8] = s[8];
      shifted[9] = s[13];
      shifted[10] = s[2];
      shifted[11] = s[7];
      shifted[12] = s[12];
      shifted[13] = s[1];
      shifted[14] = s[6];
      shifted[15] = s[11];
      s = shifted;
      if (round < rounds) {
        var mixed = new Uint8Array(16);
        for (var col = 0; col < 4; col++) {
          var a0 = s[col * 4];
          var a1 = s[col * 4 + 1];
          var a2 = s[col * 4 + 2];
          var a3 = s[col * 4 + 3];
          mixed[col * 4] = aesMul(a0, 2) ^ aesMul(a1, 3) ^ a2 ^ a3;
          mixed[col * 4 + 1] = a0 ^ aesMul(a1, 2) ^ aesMul(a2, 3) ^ a3;
          mixed[col * 4 + 2] = a0 ^ a1 ^ aesMul(a2, 2) ^ aesMul(a3, 3);
          mixed[col * 4 + 3] = aesMul(a0, 3) ^ a1 ^ a2 ^ aesMul(a3, 2);
        }
        s = mixed;
      }
      var rk = round * 4;
      for (var k = 0; k < 16; k++) {
        s[k] ^= (w[rk + (k >>> 2)] >>> (24 - (k % 4) * 8)) & 0xff;
      }
    }
    return s;
  }

  function aesDecryptBlock(schedule, block) {
    var w = schedule.words;
    var rounds = schedule.rounds;
    var s = new Uint8Array(block);
    var last = rounds * 4;
    for (var i = 0; i < 16; i++) {
      s[i] ^= (w[last + (i >>> 2)] >>> (24 - (i % 4) * 8)) & 0xff;
    }
    for (var round = rounds; round >= 1; round--) {
      var invShifted = new Uint8Array(16);
      invShifted[0] = s[0];
      invShifted[1] = s[13];
      invShifted[2] = s[10];
      invShifted[3] = s[7];
      invShifted[4] = s[4];
      invShifted[5] = s[1];
      invShifted[6] = s[14];
      invShifted[7] = s[11];
      invShifted[8] = s[8];
      invShifted[9] = s[5];
      invShifted[10] = s[2];
      invShifted[11] = s[15];
      invShifted[12] = s[12];
      invShifted[13] = s[9];
      invShifted[14] = s[6];
      invShifted[15] = s[3];
      s = invShifted;
      for (var j = 0; j < 16; j++) {
        s[j] = AES_INV_SBOX[s[j]];
      }
      var rk = (round - 1) * 4;
      for (var k = 0; k < 16; k++) {
        s[k] ^= (w[rk + (k >>> 2)] >>> (24 - (k % 4) * 8)) & 0xff;
      }
      if (round > 1) {
        var mixed = new Uint8Array(16);
        for (var col = 0; col < 4; col++) {
          var a0 = s[col * 4];
          var a1 = s[col * 4 + 1];
          var a2 = s[col * 4 + 2];
          var a3 = s[col * 4 + 3];
          mixed[col * 4] = aesMul(a0, 14) ^ aesMul(a1, 11) ^ aesMul(a2, 13) ^ aesMul(a3, 9);
          mixed[col * 4 + 1] = aesMul(a0, 9) ^ aesMul(a1, 14) ^ aesMul(a2, 11) ^ aesMul(a3, 13);
          mixed[col * 4 + 2] = aesMul(a0, 13) ^ aesMul(a1, 9) ^ aesMul(a2, 14) ^ aesMul(a3, 11);
          mixed[col * 4 + 3] = aesMul(a0, 11) ^ aesMul(a1, 13) ^ aesMul(a2, 9) ^ aesMul(a3, 14);
        }
        s = mixed;
      }
    }
    return s;
  }

  function aesCbcEncrypt(key, iv, input) {
    var schedule = aesExpandKey(key);
    var ivBytes = toBytes(iv);
    if (ivBytes.length !== 16) {
      throw new Error('AES IV 长度必须为 16 字节');
    }
    var data = toBytes(input);
    if (data.length % 16 !== 0) {
      throw new Error('CBC 明文长度必须是 16 的倍数');
    }
    var out = new Uint8Array(data.length);
    var prev = ivBytes;
    for (var off = 0; off < data.length; off += 16) {
      var block = new Uint8Array(16);
      for (var i = 0; i < 16; i++) {
        block[i] = data[off + i] ^ prev[i];
      }
      prev = aesEncryptBlock(schedule, block);
      out.set(prev, off);
    }
    return out;
  }

  function aesCbcDecrypt(key, iv, input) {
    var schedule = aesExpandKey(key);
    var ivBytes = toBytes(iv);
    if (ivBytes.length !== 16) {
      throw new Error('AES IV 长度必须为 16 字节');
    }
    var data = toBytes(input);
    if (data.length % 16 !== 0) {
      throw new Error('CBC 密文长度必须是 16 的倍数');
    }
    var out = new Uint8Array(data.length);
    var prev = ivBytes;
    for (var off = 0; off < data.length; off += 16) {
      var cipherBlock = data.subarray(off, off + 16);
      var plain = aesDecryptBlock(schedule, cipherBlock);
      for (var i = 0; i < 16; i++) {
        out[off + i] = plain[i] ^ prev[i];
      }
      prev = new Uint8Array(cipherBlock);
    }
    return out;
  }

  function aesCtr(key, iv, input) {
    var schedule = aesExpandKey(key);
    var ivBytes = toBytes(iv);
    if (ivBytes.length !== 16) {
      throw new Error('AES IV 长度必须为 16 字节');
    }
    var data = toBytes(input);
    var out = new Uint8Array(data.length);
    var counter = new Uint8Array(ivBytes);
    for (var off = 0; off < data.length; off += 16) {
      var stream = aesEncryptBlock(schedule, counter);
      var take = Math.min(16, data.length - off);
      for (var i = 0; i < take; i++) {
        out[off + i] = data[off + i] ^ stream[i];
      }
      for (var c = 15; c >= 0; c--) {
        counter[c] = (counter[c] + 1) & 0xff;
        if (counter[c] !== 0) {
          break;
        }
      }
    }
    return out;
  }

  // ---------------- AES-GCM ----------------

  function gf128mul(x, y) {
    var z = 0n;
    var v = x & M64;
    for (var i = 0; i < 64; i++) {
      if (((y >> BigInt(i)) & 1n) !== 0n) {
        z ^= v;
      }
      if ((v & 1n) !== 0n) {
        v = (v >> 1n) ^ 0xe100000000000000n;
      } else {
        v >>= 1n;
      }
    }
    return z & M64;
  }

  function ghashBlocks(hashSubkey, data) {
    var y = 0n;
    for (var off = 0; off < data.length; off += 16) {
      var block = bigintFromBytes(data.subarray(off, off + 16));
      y = gf128mul(y ^ block, hashSubkey);
    }
    return y;
  }

  function gcmComputeJ0(iv) {
    var j0 = new Uint8Array(16);
    j0.set(iv);
    j0[15] = 1;
    return j0;
  }

  function gctrIncrement(counter) {
    var out = new Uint8Array(counter);
    for (var i = 15; i >= 12; i--) {
      out[i] = (out[i] + 1) & 0xff;
      if (out[i] !== 0) {
        break;
      }
    }
    return out;
  }

  function aesGcmEncrypt(key, iv, plaintext, aad) {
    var ivBytes = toBytes(iv);
    if (ivBytes.length !== 12) {
      throw new Error('GCM IV 长度必须为 12 字节');
    }
    var data = toBytes(plaintext);
    if (data.length > 64 * 1024 * 1024) {
      throw new Error('GCM 明文过大');
    }
    var schedule = aesExpandKey(key);
    var h = aesEncryptBlock(schedule, new Uint8Array(16));
    var hashSubkey = bigintFromBytes(h);
    var j0 = gcmComputeJ0(ivBytes);
    var c = new Uint8Array(data.length);
    var counter = new Uint8Array(j0);
    for (var off = 0; off < data.length; off += 16) {
      counter = gctrIncrement(counter);
      var stream = aesEncryptBlock(schedule, counter);
      var take = Math.min(16, data.length - off);
      for (var i = 0; i < take; i++) {
        c[off + i] = data[off + i] ^ stream[i];
      }
    }
    var aadBytes = toBytes(aad === undefined ? new Uint8Array(0) : aad);
    var macData = new Uint8Array(aadBytes.length + c.length + 32);
    macData.set(aadBytes, 0);
    macData.set(c, aadBytes.length);
    var lenBlock = concatBytes(bytesFromBigint(BigInt(aadBytes.length * 8), 8).reverse(),
      bytesFromBigint(BigInt(c.length * 8), 8).reverse());
    macData.set(lenBlock, aadBytes.length + c.length);
    var s = ghashBlocks(hashSubkey, macData);
    var tag = aesCtr(key, j0, bytesFromBigint(s, 16));
    return concatBytes(c, tag);
  }

  /** AES-GCM 解密并校验标签，失败抛错 */
  function aesGcmOpen(key, nonce, sealed, aad) {
    var ivBytes = toBytes(nonce);
    if (ivBytes.length !== 12) {
      throw new Error('GCM IV 长度必须为 12 字节');
    }
    var data = toBytes(sealed);
    if (data.length < 16) {
      throw new Error('GCM 密文长度无效');
    }
    var c = data.subarray(0, data.length - 16);
    var tag = data.subarray(data.length - 16);
    var schedule = aesExpandKey(key);
    var h = aesEncryptBlock(schedule, new Uint8Array(16));
    var hashSubkey = bigintFromBytes(h);
    var j0 = gcmComputeJ0(ivBytes);
    var aadBytes = toBytes(aad === undefined ? new Uint8Array(0) : aad);
    var macData = new Uint8Array(aadBytes.length + c.length + 32);
    macData.set(aadBytes, 0);
    macData.set(c, aadBytes.length);
    var lenBlock = concatBytes(bytesFromBigint(BigInt(aadBytes.length * 8), 8).reverse(),
      bytesFromBigint(BigInt(c.length * 8), 8).reverse());
    macData.set(lenBlock, aadBytes.length + c.length);
    var s = ghashBlocks(hashSubkey, macData);
    var expected = aesCtr(key, j0, bytesFromBigint(s, 16));
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= expected[i] ^ tag[i];
    }
    if (diff !== 0) {
      throw new Error('GCM 校验失败');
    }
    var out = new Uint8Array(c.length);
    var counter = new Uint8Array(j0);
    for (var off = 0; off < c.length; off += 16) {
      counter = gctrIncrement(counter);
      var stream = aesEncryptBlock(schedule, counter);
      var take = Math.min(16, c.length - off);
      for (var j = 0; j < take; j++) {
        out[off + j] = c[off + j] ^ stream[j];
      }
    }
    return out;
  }

  // ---------------- ECDH P-256 ----------------

  var P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn;
  var P256_A = -3n;
  var P256_B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604bn;
  var P256_GX = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n;
  var P256_GY = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n;
  var P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

  function p256Mod(value) {
    var v = ((value % P256_P) + P256_P) % P256_P;
    return v;
  }

  function p256Sqrt(value) {
    var root = 1n;
    var exp = (P256_P + 1n) >> 2n;
    var base = p256Mod(value);
    while (exp > 0n) {
      if ((exp & 1n) !== 0n) {
        root = (root * base) % P256_P;
      }
      base = (base * base) % P256_P;
      exp >>= 1n;
    }
    return (root * root) % P256_P === p256Mod(value) ? root : null;
  }

  function pointCreate(x, y, z) {
    return { x: p256Mod(x), y: p256Mod(y), z: p256Mod(z) };
  }

  function pointIsInfinity(point) {
    return point.z === 0n;
  }

  function pointDouble(point) {
    if (pointIsInfinity(point) || point.y === 0n) {
      return pointCreate(1n, 1n, 0n);
    }
    var a = P256_A;
    var b = (point.x * point.x) % P256_P;
    var c = (point.y * point.y) % P256_P;
    var d = (c * c) % P256_P;
    var xpy = (point.x + c) % P256_P;
    var e = (xpy * xpy - b - d) % P256_P;
    e = (e + e) % P256_P;
    var f = 3n * b + a * point.z * point.z;
    f = f % P256_P;
    var x3 = (f * f - e - e) % P256_P;
    var y3 = (f * (e - x3) - 8n * d) % P256_P;
    var z3 = (2n * point.y * point.z) % P256_P;
    return pointCreate(x3, y3, z3);
  }

  function pointAdd(p, q) {
    if (pointIsInfinity(p)) {
      return q;
    }
    if (pointIsInfinity(q)) {
      return p;
    }
    var z1z1 = (p.z * p.z) % P256_P;
    var z2z2 = (q.z * q.z) % P256_P;
    var u1 = (p.x * z2z2) % P256_P;
    var u2 = (q.x * z1z1) % P256_P;
    var s1 = (p.y * z2z2 * q.z) % P256_P;
    var s2 = (q.y * z1z1 * p.z) % P256_P;
    if (u1 === u2) {
      if (s1 !== s2) {
        return pointCreate(1n, 1n, 0n);
      }
      return pointDouble(p);
    }
    var h = (u2 - u1) % P256_P;
    var i = (4n * h * h) % P256_P;
    var j = (h * i) % P256_P;
    var r = 2n * (s2 - s1);
    r = r % P256_P;
    var v = (u1 * i) % P256_P;
    var x3 = (r * r - j - 2n * v) % P256_P;
    var y3 = (r * (v - x3) - 2n * s1 * j) % P256_P;
    var z3 = (2n * h * p.z * q.z) % P256_P;
    return pointCreate(x3, y3, z3);
  }

  function pointMul(k, point) {
    var result = pointCreate(1n, 1n, 0n);
    var addend = point;
    var scalar = ((k % P256_N) + P256_N) % P256_N;
    while (scalar > 0n) {
      if ((scalar & 1n) !== 0n) {
        result = pointAdd(result, addend);
      }
      addend = pointDouble(addend);
      scalar >>= 1n;
    }
    return result;
  }

  function p256DecodePublicKey(input) {
    var bytes = toBytes(input);
    if (bytes.length === 65 && bytes[0] === 0x04) {
      var x = bigintFromBytes(bytes.subarray(1, 33));
      var y = bigintFromBytes(bytes.subarray(33, 65));
      return pointCreate(x, y, 1n);
    }
    if (bytes.length === 33 && (bytes[0] === 0x02 || bytes[0] === 0x03)) {
      var cx = bigintFromBytes(bytes.subarray(1, 33));
      var alpha = (cx * cx * cx + P256_A * cx + P256_B) % P256_P;
      var cy = p256Sqrt(alpha);
      if (cy === null) {
        throw new Error('公钥点不在曲线上');
      }
      var wantOdd = bytes[0] === 0x03;
      if ((cy & 1n) !== 0n !== wantOdd) {
        cy = P256_P - cy;
      }
      return pointCreate(cx, cy, 1n);
    }
    throw new Error('公钥长度仅支持 33/65 字节');
  }

  function p256Inverse(value) {
    var result = 1n;
    var base = ((value % P256_P) + P256_P) % P256_P;
    var exponent = P256_P - 2n;
    while (exponent > 0n) {
      if ((exponent & 1n) !== 0n) {
        result = result * base % P256_P;
      }
      base = base * base % P256_P;
      exponent >>= 1n;
    }
    return result;
  }

  function ecdhP256(privateKey, publicKey) {
    var privBytes = toBytes(privateKey);
    if (privBytes.length !== 32) {
      throw new Error('ECDH 私钥长度必须为 32 字节');
    }
    var d = bigintFromBytes(privBytes);
    if (d === 0n || d >= P256_N) {
      throw new Error('ECDH 私钥超出范围');
    }
    var pub = p256DecodePublicKey(publicKey);
    if (pointIsInfinity(pub)) {
      throw new Error('公钥无效');
    }
    var shared = pointMul(d, pub);
    if (pointIsInfinity(shared)) {
      throw new Error('ECDH 共享点为无穷远点');
    }
    var zInv = p256Inverse(shared.z);
    var x = shared.x * zInv % P256_P;
    return bytesFromBigint(x, 32);
  }

  /** 生成 P-256 密钥对：privateKey 32 字节，publicKey 65 字节非压缩 */
  function ecdhP256KeyPair() {
    var priv = randomBytes(32);
    var d = bigintFromBytes(priv);
    while (d === 0n || d >= P256_N) {
      priv = randomBytes(32);
      d = bigintFromBytes(priv);
    }
    var shared = pointMul(d, pointCreate(P256_GX, P256_GY, 1n));
    if (pointIsInfinity(shared)) {
      throw new Error('密钥生成失败');
    }
    var zInv = p256Inverse(shared.z);
    var x = shared.x * zInv % P256_P;
    var y = shared.y * zInv % P256_P * zInv % P256_P;
    return {
      privateKey: priv,
      publicKey: concatBytes(new Uint8Array([0x04]), bytesFromBigint(x, 32), bytesFromBigint(y, 32))
    };
  }

  // ---------------- 随机字节 ----------------

  function randomBytes(length) {
    if (typeof length !== 'number' || length < 0 || length > 1048576) {
      throw new Error('随机字节长度无效');
    }
    var out = new Uint8Array(length);
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      crypto.getRandomValues(out);
    } else {
      for (var i = 0; i < length; i++) {
        out[i] = Math.floor(Math.random() * 256);
      }
    }
    return out;
  }

  // ---------------- CRC32 / gzip ----------------

  var CRC32_TABLE = (function () {
    var table = new Uint32Array(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c >>> 0;
    }
    return table;
  })();

  function crc32(bytes) {
    var crc = 0xffffffff;
    for (var i = 0; i < bytes.length; i++) {
      crc = CRC32_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  function gzipCompress(input) {
    var data = toBytes(input);
    var out = [];
    out.push(0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff);
    var pos = 0;
    while (pos < data.length) {
      var take = Math.min(65535, data.length - pos);
      var last = pos + take >= data.length ? 1 : 0;
      out.push(last, 0xfd);
      out.push(take & 0xff, (take >> 8) & 0xff);
      var nlen = (~take) & 0xffff;
      out.push(nlen & 0xff, (nlen >> 8) & 0xff);
      for (var i = 0; i < take; i++) {
        out.push(data[pos + i]);
      }
      pos += take;
    }
    if (data.length === 0) {
      out.push(1, 0xfd, 0x00, 0x00, 0xff, 0xff);
    }
    var crc = crc32(data);
    out.push(crc & 0xff, (crc >> 8) & 0xff, (crc >> 16) & 0xff, (crc >>> 24) & 0xff);
    var isize = data.length & 0xffffffff;
    out.push(isize & 0xff, (isize >> 8) & 0xff, (isize >> 16) & 0xff, (isize >>> 24) & 0xff);
    return new Uint8Array(out);
  }

  function BitReader(bytes) {
    this.bytes = bytes;
    this.pos = 0;
    this.bitBuf = 0;
    this.bitCount = 0;
  }

  BitReader.prototype.getBits = function (count) {
    while (this.bitCount < count) {
      if (this.pos >= this.bytes.length) {
        throw new Error('gzip 数据意外结束');
      }
      this.bitBuf |= this.bytes[this.pos++] << this.bitCount;
      this.bitCount += 8;
    }
    var value = this.bitBuf & ((1 << count) - 1);
    this.bitBuf >>>= count;
    this.bitCount -= count;
    return value;
  };

  BitReader.prototype.alignByte = function () {
    this.bitBuf = 0;
    this.bitCount = 0;
  };

  function buildHuffman(lengths) {
    var counts = new Uint16Array(16);
    for (var i = 0; i < lengths.length; i++) {
      counts[lengths[i]]++;
    }
    counts[0] = 0;
    var offsets = new Uint16Array(16);
    var total = 0;
    for (var i2 = 1; i2 <= 15; i2++) {
      offsets[i2] = total;
      total += counts[i2];
    }
    var symbols = new Uint16Array(total);
    for (var j = 0; j < lengths.length; j++) {
      if (lengths[j] !== 0) {
        symbols[offsets[lengths[j]]++] = j;
      }
    }
    return { counts: counts, symbols: symbols };
  }

  function decodeSymbol(reader, huffman) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var len = 1; len <= 15; len++) {
      code |= reader.getBits(1);
      var count = huffman.counts[len];
      if (code - count < first) {
        return huffman.symbols[index + (code - first)];
      }
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('gzip 霍夫曼编码无效');
  }

  var INFLATE_LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  var INFLATE_LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  var INFLATE_DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
  var INFLATE_DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  var INFLATE_CODE_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

  var MAX_INFLATE_OUTPUT = 20 * 1024 * 1024;

  function inflateRaw(reader) {
    var out = [];
    while (true) {
      var last = reader.getBits(1);
      var type = reader.getBits(2);
      if (type === 0) {
        reader.alignByte();
        if (reader.pos + 4 > reader.bytes.length) {
          throw new Error('gzip 数据意外结束');
        }
        var len = reader.bytes[reader.pos] | (reader.bytes[reader.pos + 1] << 8);
        reader.pos += 4;
        if (reader.pos + len > reader.bytes.length) {
          throw new Error('gzip 数据意外结束');
        }
        for (var i = 0; i < len; i++) {
          out.push(reader.bytes[reader.pos + i]);
          if (out.length > MAX_INFLATE_OUTPUT) {
            throw new Error('gzip 解压结果超过大小限制');
          }
        }
        reader.pos += len;
      } else if (type === 1 || type === 2) {
        var literalHuffman;
        var distanceHuffman;
        if (type === 1) {
          var fixedLengths = new Uint8Array(288);
          for (var f = 0; f < 144; f++) {
            fixedLengths[f] = 8;
          }
          for (var f2 = 144; f2 < 256; f2++) {
            fixedLengths[f2] = 9;
          }
          for (var f3 = 256; f3 < 280; f3++) {
            fixedLengths[f3] = 7;
          }
          for (var f4 = 280; f4 < 288; f4++) {
            fixedLengths[f4] = 8;
          }
          literalHuffman = buildHuffman(fixedLengths);
          distanceHuffman = buildHuffman(new Uint8Array(30).fill(5));
        } else {
          var hlit = reader.getBits(5) + 257;
          var hdist = reader.getBits(5) + 1;
          var hclen = reader.getBits(4) + 4;
          var codeLengths = new Uint8Array(19);
          for (var c = 0; c < hclen; c++) {
            codeLengths[INFLATE_CODE_ORDER[c]] = reader.getBits(3);
          }
          var codeHuffman = buildHuffman(codeLengths);
          var allLengths = new Uint8Array(hlit + hdist);
          var idx = 0;
          while (idx < hlit + hdist) {
            var symbol = decodeSymbol(reader, codeHuffman);
            if (symbol < 16) {
              allLengths[idx++] = symbol;
            } else if (symbol === 16) {
              if (idx === 0) {
                throw new Error('gzip 编码长度无效');
              }
              var repeat = 3 + reader.getBits(2);
              var prev = allLengths[idx - 1];
              for (var r1 = 0; r1 < repeat && idx < hlit + hdist; r1++) {
                allLengths[idx++] = prev;
              }
            } else if (symbol === 17) {
              var repeat2 = 3 + reader.getBits(3);
              idx += repeat2;
            } else {
              var repeat3 = 11 + reader.getBits(7);
              idx += repeat3;
            }
          }
          if (idx > hlit + hdist) {
            throw new Error('gzip 编码长度表越界');
          }
          literalHuffman = buildHuffman(allLengths.subarray(0, hlit));
          distanceHuffman = buildHuffman(allLengths.subarray(hlit));
        }
        while (true) {
          var lit = decodeSymbol(reader, literalHuffman);
          if (lit < 256) {
            out.push(lit);
            if (out.length > MAX_INFLATE_OUTPUT) {
              throw new Error('gzip 解压结果超过大小限制');
            }
          } else if (lit === 256) {
            break;
          } else {
            var li = lit - 257;
            if (li >= INFLATE_LENGTH_BASE.length) {
              throw new Error('gzip 长度符号无效');
            }
            var length = INFLATE_LENGTH_BASE[li] + reader.getBits(INFLATE_LENGTH_EXTRA[li]);
            var distSym = decodeSymbol(reader, distanceHuffman);
            if (distSym >= INFLATE_DIST_BASE.length) {
              throw new Error('gzip 距离符号无效');
            }
            var distance = INFLATE_DIST_BASE[distSym] + reader.getBits(INFLATE_DIST_EXTRA[distSym]);
            if (distance > out.length) {
              throw new Error('gzip 回溯距离无效');
            }
            var from = out.length - distance;
            for (var r2 = 0; r2 < length; r2++) {
              out.push(out[from + r2]);
              if (out.length > MAX_INFLATE_OUTPUT) {
                throw new Error('gzip 解压结果超过大小限制');
              }
            }
          }
        }
      } else {
        throw new Error('gzip 块类型无效');
      }
      if (last === 1) {
        break;
      }
    }
    return new Uint8Array(out);
  }

  function gzipDecompress(input) {
    var data = toBytes(input);
    if (data.length < 18 || data[0] !== 0x1f || data[1] !== 0x8b || data[2] !== 0x08) {
      throw new Error('gzip 头部无效');
    }
    var flags = data[3];
    var pos = 10;
    if ((flags & 0x04) !== 0) {
      if (pos + 2 > data.length) {
        throw new Error('gzip 数据意外结束');
      }
      var xlen = data[pos] | (data[pos + 1] << 8);
      pos += 2 + xlen;
    }
    if ((flags & 0x08) !== 0) {
      while (pos < data.length && data[pos] !== 0) {
        pos++;
      }
      pos++;
    }
    if ((flags & 0x10) !== 0) {
      while (pos < data.length && data[pos] !== 0) {
        pos++;
      }
      pos++;
    }
    if ((flags & 0x02) !== 0) {
      pos += 2;
    }
    if (pos >= data.length) {
      throw new Error('gzip 数据意外结束');
    }
    var reader = new BitReader(data.subarray(pos));
    var result = inflateRaw(reader);
    reader.alignByte();
    var consumed = pos + reader.pos;
    if (consumed + 8 > data.length) {
      throw new Error('gzip 尾部缺失');
    }
    var expectedCrc = (data[consumed] | (data[consumed + 1] << 8) |
      (data[consumed + 2] << 16) | (data[consumed + 3] << 24)) >>> 0;
    if (crc32(result) !== expectedCrc) {
      throw new Error('gzip CRC32 校验失败');
    }
    var isize = (data[consumed + 4] | (data[consumed + 5] << 8) |
      (data[consumed + 6] << 16) | (data[consumed + 7] << 24)) >>> 0;
    if ((result.length & 0xffffffff) !== isize) {
      throw new Error('gzip 长度校验失败');
    }
    return result;
  }

  // ---------------- 网络 ----------------

  var DEFAULT_FETCH_LIMIT = 4 * 1024 * 1024;
  var FETCH_TEXT_TTL_MS = 2 * 60 * 1000;
  var preferredSiteValue = '';
  var reserveCounter = 0;

  /** 清单声明的域名白名单：hosts / aliases / hostSuffixes / baseUrl / 页面 origin */
  var ALLOWED_HOSTS = (function () {
    var list = [];
    function add(value) {
      if (typeof value !== 'string') {
        return;
      }
      var name = value.trim().toLowerCase();
      if (name === '') {
        return;
      }
      if (name.indexOf('://') >= 0) {
        try {
          name = new URL(name).hostname;
        } catch (error) {
          return;
        }
      }
      if (name.indexOf('/') >= 0) {
        name = name.split('/')[0];
      }
      if (name.indexOf(':') >= 0) {
        name = name.split(':')[0];
      }
      if (name !== '' && list.indexOf(name) < 0) {
        list.push(name);
      }
    }
    function addAll(values) {
      if (!Array.isArray(values)) {
        return;
      }
      for (var i = 0; i < values.length; i++) {
        add(values[i]);
      }
    }
    addAll(MANIFEST.hosts);
    addAll(MANIFEST.aliases);
    addAll(MANIFEST.hostSuffixes);
    add(MANIFEST.baseUrl);
    if (typeof location !== 'undefined' && location.hostname) {
      add(location.hostname);
    }
    return list;
  })();

  function hostAllowed(hostname) {
    if (ALLOWED_HOSTS.length === 0) {
      return true;
    }
    var name = String(hostname).toLowerCase();
    for (var i = 0; i < ALLOWED_HOSTS.length; i++) {
      var entry = ALLOWED_HOSTS[i];
      if (entry === name) {
        return true;
      }
      if (entry.indexOf('*.') === 0) {
        var bare = entry.slice(2);
        var suffix = entry.slice(1);
        if (name === bare || name.slice(-suffix.length) === suffix) {
          return true;
        }
      }
    }
    return false;
  }

  /** 校验请求地址：协议、域名白名单；非法或越权直接抛错 */
  function guardUrl(rawUrl) {
    var parsed = parseUrl(rawUrl);
    if (parsed.scheme !== 'http' && parsed.scheme !== 'https') {
      throw new Error('仅支持 http/https 地址');
    }
    if (parsed.hostname !== '' && !hostAllowed(parsed.hostname)) {
      throw new Error('跨域请求暂不受支持：' + parsed.hostname);
    }
    return parsed;
  }

  function noteSuccessSite(url, actualUrl) {
    try {
      var parsed = new URL(actualUrl || url);
      preferredSiteValue = parsed.protocol + '//' + parsed.host;
    } catch (error) {
    }
  }

  var FORBIDDEN_HEADERS = {
    'user-agent': 1, 'referer': 1, 'referrer': 1, 'cookie': 1, 'host': 1,
    'origin': 1, 'connection': 1, 'content-length': 1, 'accept-encoding': 1
  };

  /**
   * 同步 XHR。限制：跨域抛 NetworkError、responseType 禁用、
   * UA/Referer 等受保护头禁改、二进制用 x-user-defined 文本通道。
   */
  function syncRequest(options, binary) {
    var url = String(options.url || '');
    var method = String(options.method || 'GET').toUpperCase();
    var xhr = new XMLHttpRequest();
    try {
      xhr.open(method, url, false);
    } catch (error) {
      throw new Error('请求地址无效');
    }
    if (binary) {
      try {
        xhr.overrideMimeType('text/plain; charset=x-user-defined');
      } catch (error) {
      }
    }
    var headers = options.headers;
    if (headers !== null && typeof headers === 'object') {
      for (var name in headers) {
        if (!Object.prototype.hasOwnProperty.call(headers, name)) {
          continue;
        }
        var value = headers[name];
        if (value === undefined || value === null) {
          continue;
        }
        if (typeof value !== 'string' && typeof value !== 'number') {
          value = utf8Decode(value);
        }
        if (FORBIDDEN_HEADERS[String(name).toLowerCase()] === 1) {
          continue;
        }
        try {
          xhr.setRequestHeader(String(name), String(value));
        } catch (error) {
        }
      }
    }
    var body = options.body;
    var payload = null;
    if (body !== undefined && body !== null && body !== '') {
      payload = typeof body === 'string' ? body : bytesToBinaryString(toBytes(body));
    }
    try {
      xhr.send(payload);
    } catch (error) {
      var target = '';
      try {
        target = parseUrl(url).hostname;
      } catch (parseError) {
        target = '';
      }
      if (target !== '' && typeof location !== 'undefined' &&
        target !== location.hostname.toLowerCase()) {
        throw new Error('跨域请求暂不受支持：' + target);
      }
      throw new Error('网络请求失败');
    }
    if (xhr.status === 0) {
      throw new Error('网络请求失败');
    }
    return xhr;
  }

  /**
   * host.fetch(request)。字段：method/url/headers/body/ticket/limit/timeoutMs/
   * followRedirects/anyStatus/acceptStatus/binary/background/direct。
   * 响应：{ status, body, headers, url }；错误带 status/body/blocked/oversized。
   */
  function fetchImpl(request) {
    var options = request || {};
    var url = String(options.url || '');
    if (url === '') {
      throw new Error('请求缺少地址');
    }
    guardUrl(url);
    var binary = options.binary === true;
    var limit = Number(options.limit);
    if (!Number.isFinite(limit) || limit <= 0) {
      limit = DEFAULT_FETCH_LIMIT;
    }
    var xhr = syncRequest(options, binary);
    var text = '';
    try {
      text = xhr.responseText || '';
    } catch (error) {
      text = '';
    }
    if (text.length > limit) {
      var oversizeError = new Error('响应超过大小限制');
      oversizeError.oversized = true;
      throw oversizeError;
    }
    var status = xhr.status;
    var accepted = options.anyStatus === true;
    if (!accepted && Array.isArray(options.acceptStatus)) {
      accepted = options.acceptStatus.indexOf(status) >= 0;
    }
    if (!accepted && status >= 400) {
      var httpError = new Error('站点返回 HTTP ' + status);
      httpError.status = status;
      httpError.body = text;
      httpError.blocked = status === 403 || status === 412 || status === 429;
      throw httpError;
    }
    if (status < 400) {
      noteSuccessSite(url, xhr.responseURL);
    }
    return {
      status: status,
      body: binary ? binaryStringToBytes(text) : text,
      headers: xhr.getAllResponseHeaders(),
      url: xhr.responseURL || url
    };
  }

  /**
   * host.fetchText(request)：网页文本抓取。字段 url/referer/noCache/mirrors/limit。
   * mirrors 仅在网络级失败（status 0）时依次推进；任意 HTTP 状态都返回响应。
   * 成功响应按 url 缓存 2 分钟，noCache 跳过缓存读。
   */
  function fetchTextImpl(request) {
    var options = request || {};
    var url = String(options.url || '');
    if (url === '') {
      throw new Error('请求缺少地址');
    }
    guardUrl(url);
    var cacheKey = '__fetchText:' + url;
    if (options.noCache !== true) {
      var cached = cacheGet(cacheKey);
      if (cached !== null && typeof cached === 'object' && typeof cached.body === 'string') {
        return cached;
      }
    }
    var candidates = [url];
    if (Array.isArray(options.mirrors)) {
      for (var i = 0; i < options.mirrors.length; i++) {
        var mirror = options.mirrors[i];
        if (typeof mirror === 'string' && mirror !== '' && candidates.indexOf(mirror) < 0) {
          candidates.push(mirror);
        }
      }
    }
    var lastNetworkError = null;
    for (var c = 0; c < candidates.length; c++) {
      var attempt = {
        method: 'GET',
        url: candidates[c],
        headers: options.headers,
        limit: options.limit,
        anyStatus: true
      };
      var response;
      try {
        response = fetchImpl(attempt);
      } catch (error) {
        if (error && (error.oversized === true || error.status !== undefined)) {
          throw error;
        }
        lastNetworkError = error;
        continue;
      }
      if (response.status < 400) {
        cacheSet(cacheKey, response, FETCH_TEXT_TTL_MS);
      }
      return response;
    }
    throw lastNetworkError || new Error('网络请求失败');
  }

  /** host.reserve({url, lane, background})：先占限流名额。沙箱内不限流，只做白名单校验 */
  function reserve(request) {
    var options = request || {};
    guardUrl(String(options.url || ''));
    reserveCounter += 1;
    return 'ticket:' + reserveCounter;
  }

  // ---------------- 缓存 / 状态 / 持久化 ----------------

  var CACHE_ENTRY_LIMIT = 2000;
  var PERSIST_DELAY_MS = 400;
  var memCache = {};
  var stateStore = {};
  var persistTimer = 0;

  /** 从注入的 __QM_PERSIST__ 恢复缓存与状态 */
  (function restorePersist() {
    if (PERSIST === null || typeof PERSIST !== 'object') {
      return;
    }
    var cache = PERSIST.cache;
    if (cache !== null && typeof cache === 'object') {
      for (var key in cache) {
        if (!Object.prototype.hasOwnProperty.call(cache, key)) {
          continue;
        }
        var entry = cache[key];
        if (entry !== null && typeof entry === 'object') {
          memCache[key] = { v: entry.v, e: entry.e };
        }
      }
    }
    var states = PERSIST.states;
    if (states !== null && typeof states === 'object') {
      for (var name in states) {
        if (Object.prototype.hasOwnProperty.call(states, name)) {
          stateStore[name] = states[name];
        }
      }
    }
  })();

  function persistNow() {
    if (persistTimer !== 0) {
      clearTimeout(persistTimer);
      persistTimer = 0;
    }
    try {
      __qmNative.persist(SOURCE_ID, JSON.stringify({ cache: memCache, states: stateStore }));
    } catch (error) {
    }
  }

  function schedulePersist() {
    if (persistTimer !== 0) {
      return;
    }
    persistTimer = setTimeout(function () {
      persistTimer = 0;
      persistNow();
    }, PERSIST_DELAY_MS);
  }

  function cacheGet(key) {
    var name = String(key);
    var entry = memCache[name];
    if (entry === undefined) {
      return null;
    }
    if (entry.e !== 0 && Date.now() > entry.e) {
      delete memCache[name];
      schedulePersist();
      return null;
    }
    return entry.v;
  }

  function cacheSet(key, value, ttlMs) {
    var name = String(key);
    if (value === null || value === undefined) {
      if (memCache[name] !== undefined) {
        delete memCache[name];
        schedulePersist();
      }
      return;
    }
    var ttl = Number(ttlMs);
    if (!Number.isFinite(ttl) || ttl < 0) {
      ttl = 0;
    }
    memCache[name] = { v: value, e: ttl === 0 ? 0 : Date.now() + ttl };
    if (Object.keys(memCache).length > CACHE_ENTRY_LIMIT) {
      var now = Date.now();
      for (var existing in memCache) {
        if (memCache[existing].e !== 0 && memCache[existing].e < now) {
          delete memCache[existing];
        }
      }
      while (Object.keys(memCache).length > CACHE_ENTRY_LIMIT) {
        var oldest = null;
        for (var candidate in memCache) {
          if (oldest === null || memCache[candidate].e < memCache[oldest].e) {
            oldest = candidate;
          }
        }
        if (oldest === null) {
          break;
        }
        delete memCache[oldest];
      }
    }
    schedulePersist();
  }

  function loadState(name) {
    var key = String(name);
    return Object.prototype.hasOwnProperty.call(stateStore, key) ? stateStore[key] : null;
  }

  function saveState(name, value) {
    stateStore[String(name)] = value === undefined ? null : value;
    persistNow();
  }

  // ---------------- 并发 / 进度 ----------------

  var exclusiveBusy = false;

  /** 互斥执行；同一模块实例内不可重入，嵌套调用抛错 */
  function exclusive(fn) {
    if (exclusiveBusy) {
      throw new Error('exclusive 不可重入');
    }
    exclusiveBusy = true;
    try {
      return fn();
    } finally {
      exclusiveBusy = false;
    }
  }

  /** 同步等待，上限 3 秒（页面内只能忙等，隐藏沙箱可接受） */
  function sleep(ms) {
    var wait = Number(ms);
    if (!Number.isFinite(wait) || wait <= 0) {
      return;
    }
    if (wait > 3000) {
      wait = 3000;
    }
    var end = Date.now() + wait;
    while (Date.now() < end) {
    }
  }

  var knownIds = {};

  function isKnown(id) {
    return Object.prototype.hasOwnProperty.call(knownIds, String(id));
  }

  function reportProgress(items) {
    if (!Array.isArray(items)) {
      return;
    }
    for (var i = 0; i < items.length; i++) {
      var row = items[i];
      if (row !== null && typeof row === 'object' && row.id !== undefined && row.id !== null) {
        knownIds[String(row.id)] = 1;
      }
    }
  }

  function logBridge(message) {
    try {
      __qmNative.log(String(message));
    } catch (error) {
    }
  }

  // ---------------- 解析 ----------------

  /**
   * host.parseUrl(raw)。字段：scheme/host/hostname/port/userInfo/path/query。
   * 相对路径（无协议无主机）返回 scheme/host 为空的对象，不抛错。
   */
  function parseUrl(raw) {
    var text = String(raw === undefined || raw === null ? '' : raw).trim();
    if (text === '') {
      throw new Error('地址为空');
    }
    var parsed = null;
    try {
      parsed = new URL(text);
    } catch (error) {
      if (typeof MANIFEST.baseUrl === 'string' && MANIFEST.baseUrl !== '') {
        try {
          parsed = new URL(text, MANIFEST.baseUrl);
        } catch (withBaseError) {
          parsed = null;
        }
      }
    }
    if (parsed === null) {
      if (text.charAt(0) === '/') {
        return { scheme: '', host: '', hostname: '', port: '', userInfo: '', path: text, query: '' };
      }
      throw new Error('地址无效');
    }
    var userInfo = '';
    if (parsed.username !== '' || parsed.password !== '') {
      userInfo = parsed.username + (parsed.password !== '' ? ':' + parsed.password : '');
    }
    return {
      scheme: parsed.protocol.replace(':', ''),
      host: parsed.host,
      hostname: parsed.hostname,
      port: parsed.port,
      userInfo: userInfo,
      path: parsed.pathname,
      query: parsed.search.charAt(0) === '?' ? parsed.search.slice(1) : parsed.search
    };
  }

  function resolveUrl(base, ref) {
    return new URL(String(ref), String(base)).href;
  }

  /**
   * host.preserveIntegers(text)：把 JSON 文本里超出安全范围的整数
   * 改成字符串，再交给模块 JSON.parse。
   */
  function preserveIntegers(text) {
    var input = String(text);
    var out = '';
    var i = 0;
    while (i < input.length) {
      var ch = input.charAt(i);
      if (ch === '"') {
        var j = i + 1;
        while (j < input.length) {
          if (input.charAt(j) === '\\') {
            j += 2;
            continue;
          }
          if (input.charAt(j) === '"') {
            j += 1;
            break;
          }
          j += 1;
        }
        out += input.slice(i, j);
        i = j;
        continue;
      }
      if (ch === '-' || (ch >= '0' && ch <= '9')) {
        var k = ch === '-' ? i + 1 : i;
        var start = k;
        while (k < input.length && input.charAt(k) >= '0' && input.charAt(k) <= '9') {
          k += 1;
        }
        var digits = k - start;
        if (digits === 0) {
          out += ch;
          i += 1;
          continue;
        }
        var after = input.charAt(k);
        if (digits > 15 && after !== '.' && after !== 'e' && after !== 'E') {
          var value = BigInt(input.slice(start, k));
          if (value > 9007199254740991n) {
            out += '"' + input.slice(i, k) + '"';
            i = k;
            continue;
          }
        }
        out += input.slice(i, k);
        i = k;
        continue;
      }
      out += ch;
      i += 1;
    }
    return out;
  }

  // ---------------- HTML 解析 ----------------

  var VOID_TAGS = {
    area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1,
    link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1
  };

  var HTML_ENTITIES = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
    '#39': "'", '#x27': "'", '#x2F': '/', '#47': '/'
  };

  function decodeEntities(text) {
    if (text.indexOf('&') < 0) {
      return text;
    }
    return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, function (whole, name) {
      var known = HTML_ENTITIES[name];
      if (known !== undefined) {
        return known;
      }
      if (name.charAt(0) === '#') {
        var code = name.charAt(1) === 'x' || name.charAt(1) === 'X'
          ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
        if (code > 0 && code < 0x110000) {
          try {
            return String.fromCodePoint(code);
          } catch (error) {
            return whole;
          }
        }
      }
      return whole;
    });
  }

  function parseTagHead(inner) {
    var trimmed = inner.trim();
    var nameMatch = /^[a-zA-Z][^\s/>]*/.exec(trimmed);
    var name = nameMatch !== null ? nameMatch[0].toLowerCase() : '';
    var attrs = {};
    var rest = trimmed.slice(name.length);
    var pattern = /([^\s=/>]+)(?:\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]*)))?/g;
    var match;
    while ((match = pattern.exec(rest)) !== null) {
      var attrName = match[1].toLowerCase();
      var value = match[3] !== undefined ? match[3] : (match[4] !== undefined ? match[4] : (match[5] !== undefined ? match[5] : ''));
      if (attrs[attrName] === undefined) {
        attrs[attrName] = decodeEntities(value);
      }
    }
    var selfClosing = /\/\s*$/.test(trimmed);
    return { name: name, attrs: attrs, selfClosing: selfClosing };
  }

  function appendTextNode(parent, text) {
    if (text === '') {
      return;
    }
    var node = { text: decodeEntities(text) };
    node.parent = parent;
    parent.children.push(node);
  }

  /**
   * host.parseHtml(text)：解析为 { tag, attrs, children, parent } 节点树，
   * 文本节点为 { text }（tag 未定义）。script/style 内容保留为单个文本子节点。
   */
  function parseHtml(markup) {
    var input = String(markup);
    var root = { tag: '', attrs: {}, children: [] };
    root.parent = null;
    var stack = [root];
    var i = 0;
    while (i < input.length) {
      var current = stack[stack.length - 1];
      var lt = input.indexOf('<', i);
      if (lt < 0) {
        appendTextNode(current, input.slice(i));
        break;
      }
      if (lt > i) {
        appendTextNode(current, input.slice(i, lt));
      }
      if (input.startsWith('<!--', lt)) {
        var commentEnd = input.indexOf('-->', lt + 4);
        i = commentEnd < 0 ? input.length : commentEnd + 3;
        continue;
      }
      if (input.charAt(lt + 1) === '!' || input.charAt(lt + 1) === '?') {
        var bangEnd = input.indexOf('>', lt);
        i = bangEnd < 0 ? input.length : bangEnd + 1;
        continue;
      }
      var close = input.indexOf('>', lt);
      if (close < 0) {
        appendTextNode(current, input.slice(lt));
        break;
      }
      var inner = input.slice(lt + 1, close);
      if (inner.charAt(0) === '/') {
        var closeName = inner.slice(1).trim().toLowerCase();
        for (var depth = stack.length - 1; depth > 0; depth--) {
          if (stack[depth].tag === closeName) {
            stack.length = depth;
            break;
          }
        }
        i = close + 1;
        continue;
      }
      var head = parseTagHead(inner);
      if (head.name === '') {
        appendTextNode(current, input.slice(lt, close + 1));
        i = close + 1;
        continue;
      }
      var node = { tag: head.name, attrs: head.attrs, children: [] };
      node.parent = current;
      current.children.push(node);
      if (head.name === 'script' || head.name === 'style') {
        var closePattern = new RegExp('</' + head.name + '\\s*>', 'i');
        var restText = input.slice(close + 1);
        var closeMatch = closePattern.exec(restText);
        var raw = closeMatch !== null ? restText.slice(0, closeMatch.index) : restText;
        if (raw !== '') {
          var rawNode = { text: raw };
          rawNode.parent = node;
          node.children.push(rawNode);
        }
        i = closeMatch !== null ? close + 1 + closeMatch.index + closeMatch[0].length : input.length;
        continue;
      }
      if (head.selfClosing || VOID_TAGS[head.name] === 1) {
        i = close + 1;
        continue;
      }
      stack.push(node);
      i = close + 1;
    }
    return root;
  }

  // ---------------- 媒体透传 ----------------

  function prepareWebMedia(media, sourceName) {
    return media;
  }

  function finishMedia(media) {
    if (media === null || typeof media !== 'object' || typeof media.url !== 'string' || media.url === '') {
      throw new Error('媒体缺少播放地址');
    }
    return media;
  }

  // ---------------- host 组装 ----------------

  var host = {
    // 标识
    source: SOURCE_ID,
    dramaId: function (sourceId) {
      return SOURCE_ID + ':' + String(sourceId);
    },
    chapterId: function (seriesId, key) {
      return SOURCE_ID + ':' + String(seriesId) + ':' + String(key);
    },
    // 网络
    fetch: fetchImpl,
    fetchText: fetchTextImpl,
    fetchPlaylist: fetchTextImpl,
    reserve: reserve,
    retries: function () {
      return 2;
    },
    maxPages: function () {
      return 200;
    },
    sleep: sleep,
    preferredSite: function () {
      return preferredSiteValue;
    },
    // 目录
    catalogContext: function () {
      return { more: true, background: false };
    },
    isKnown: isKnown,
    reportProgress: reportProgress,
    // 数据
    loadState: loadState,
    saveState: saveState,
    cacheGet: cacheGet,
    cacheSet: cacheSet,
    exclusive: exclusive,
    log: logBridge,
    // 解析
    parseUrl: parseUrl,
    resolveUrl: resolveUrl,
    parseHtml: parseHtml,
    preserveIntegers: preserveIntegers,
    // 字节与编码
    utf8Encode: utf8Encode,
    utf8Decode: utf8Decode,
    hexEncode: hexEncode,
    hexDecode: hexDecode,
    base64Encode: base64Encode,
    base64Decode: base64Decode,
    // 摘要（返回 Uint8Array 字节）
    md5: md5Bytes,
    sha256: sha256Bytes,
    sha512: sha512Bytes,
    hmacSha256: hmacSha256,
    // 加密
    randomBytes: randomBytes,
    aesCbcEncrypt: aesCbcEncrypt,
    aesCbcDecrypt: aesCbcDecrypt,
    aesGcmSeal: aesGcmEncrypt,
    aesGcmOpen: aesGcmOpen,
    ecdhP256KeyPair: ecdhP256KeyPair,
    ecdhP256: ecdhP256,
    hkdfSha256: hkdfSha256,
    gzip: gzipCompress,
    gunzip: gzipDecompress,
    // 媒体
    prepareWebMedia: prepareWebMedia,
    finishMedia: finishMedia
  };

  window.host = host;
  window.__qmFlush = persistNow;
})();

// 模块代码在独立作用域执行，顶层声明不会遮蔽宿主内部实现
(function () {
  var module = { exports: {} };
  var exports = module.exports;
  /*__QM_MODULE__*/
  window.__qmModule = module.exports;
})();

window.__qm = {
  invoke: function (callId, name, argsJson) {
    var target = window.__qmModule;
    var fn = target === null || target === undefined ? null : target[name];
    if (typeof fn !== 'function') {
      __qmNative.onResult(callId, false, '模块不支持 ' + name);
      return;
    }
    var args = [];
    try {
      var parsed = JSON.parse(argsJson === undefined || argsJson === null ? '[]' : argsJson);
      if (Array.isArray(parsed)) {
        args = parsed;
      }
    } catch (error) {
      __qmNative.onResult(callId, false, '调用参数无效');
      return;
    }
    try {
      var value = fn.apply(null, args);
      var flush = window.__qmFlush;
      if (typeof flush === 'function') {
        flush();
      }
      __qmNative.onResult(callId, true, JSON.stringify(value === undefined ? null : value));
    } catch (error) {
      var flushOnFail = window.__qmFlush;
      if (typeof flushOnFail === 'function') {
        flushOnFail();
      }
      var message = error !== null && error !== undefined && error.message
        ? String(error.message) : String(error);
      __qmNative.onResult(callId, false, message);
    }
  }
};
