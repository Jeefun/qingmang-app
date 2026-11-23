/**
 * 用 Chrome DevTools Protocol 精确测量预览页的几何，并按元素裁图。
 * 目的：不靠肉眼看截图判断「有没有压住、有没有溢出」。
 *
 * 用法：node measure.mjs
 */
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';

const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PAGE = 'file:///D:/App/guoapp-harmony/docs/preview/player-preview.html';
const PORT = 9333;
const OUT = 'D:/App/guoapp-harmony/docs/preview';

mkdirSync(OUT, { recursive: true });

const proc = spawn(CHROME, [
  '--headless=new',
  '--disable-gpu',
  '--hide-scrollbars',
  `--remote-debugging-port=${PORT}`,
  '--user-data-dir=D:/App/guoapp-harmony/docs/preview/.chrome-profile',
  '--window-size=1000,1300',
  'about:blank'
], { stdio: 'ignore' });

async function wsUrl() {
  for (let i = 0; i < 40; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = await res.json();
      const page = list.find((t) => t.type === 'page');
      if (page) return page.webSocketDebuggerUrl;
    } catch { /* 还没起来 */ }
    await delay(250);
  }
  throw new Error('chrome 没起来');
}

const ws = new WebSocket(await wsUrl());
await new Promise((r) => ws.addEventListener('open', r, { once: true }));

let id = 0;
const pending = new Map();
ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
  }
});

function send(method, params = {}) {
  const mid = ++id;
  ws.send(JSON.stringify({ id: mid, method, params }));
  return new Promise((resolve, reject) => pending.set(mid, { resolve, reject }));
}

async function evaluate(expr) {
  const r = await send('Runtime.evaluate', {
    expression: expr,
    returnByValue: true,
    awaitPromise: true
  });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + ' ' + (r.exceptionDetails.exception?.description ?? ''));
  return r.result.value;
}

await send('Page.enable');
await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride', {
  width: 1000, height: 1300, deviceScaleFactor: 2, mobile: false
});

async function open(state, waitMs = 1400) {
  // 用 ?state= 而不是 #hash：锚点会让浏览器自动滚到那个元素，测量全乱
  const url = state ? `${PAGE}?state=${state}&t=${Date.now()}` : `${PAGE}?t=${Date.now()}`;
  await send('Page.navigate', { url });
  await delay(700);
  await send('Runtime.evaluate', { expression: 'window.scrollTo(0,0)' });
  await delay(waitMs);
}

/** 读取关键元素的位置，判断越界/重叠 */
const MEASURE = `(() => {
  const px = (v) => Math.round(v * 10) / 10;
  const rect = (el) => {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: px(r.x), y: px(r.y), w: px(r.width), h: px(r.height), r: px(r.right), b: px(r.bottom) };
  };
  const q = (s) => document.querySelector(s);
  const phone = q('.phone');
  const scale = phone ? phone.getBoundingClientRect().width / 360 : 0;

  // 弹幕越界检查：弹幕层必须和画面盒子完全重合（这样左右黑边上不可能有字）
  const vbox = rect(q('.vbox'));
  const layer = rect(q('.dm-layer'));
  const dms = [...document.querySelectorAll('.dm')].map((el) => {
    const r = rect(el);
    return { text: el.textContent.slice(0, 8), ...r };
  });
  const layerMatchesPic = layer && vbox
    ? Math.abs(layer.x - vbox.x) < 1 && Math.abs(layer.w - vbox.w) < 1 && Math.abs(layer.b - vbox.b) < 1
    : false;

  const row = q('.btn-row');
  const rowChildren = row ? [...row.children].map((c) => rect(c)) : [];
  const overflow = row ? row.scrollWidth - row.clientWidth : 0;

  return {
    scale: px(scale),
    phone: rect(phone),
    video: rect(q('.video')),
    vbox,
    topbar: rect(q('.topbar')),
    btnRow: rect(row),
    btnRowOverflowPx: px(overflow),
    btnRowChildren: rowChildren,
    sheet: rect(q('.sheet')),
    sheetBody: rect(q('.sheet-body')),
    sheetScroll: q('.sheet-body') ? q('.sheet-body').scrollHeight - q('.sheet-body').clientHeight : 0,
    dmCount: dms.length,
    dmLayerMatchesPicture: layerMatchesPic,
    dmLayer: layer,
    dmSample: dms.slice(0, 3),
    dmTop: dms.length ? Math.min(...dms.map((d) => d.y)) : null,
    hint: q('#dmHint') ? {
      ...rect(q('#dmHint')),
      shown: q('#dmHint').classList.contains('show'),
      cls: q('#dmHint').className
    } : null,
    topbarBottom: rect(q('.topbar')) ? rect(q('.topbar')).b : null
  };
})()`;

const results = {};

for (const [name, state] of [['half', ''], ['full', 'full'], ['sheet', 'sheet']]) {
  await open(state);
  results[name] = await evaluate(MEASURE);

  // 只截手机那块，2 倍像素
  const clip = await evaluate(`(() => {
    const r = document.querySelector('.phone').getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height, scale: 1 };
  })()`);
  const shot = await send('Page.captureScreenshot', {
    format: 'png',
    clip: { x: clip.x, y: clip.y, width: clip.width, height: clip.height, scale: 1.6 },
    captureBeyondViewport: true
  });
  writeFileSync(`${OUT}/shot-${name}.png`, Buffer.from(shot.data, 'base64'));
}

writeFileSync(`${OUT}/measure.json`, JSON.stringify(results, null, 2));
console.log(JSON.stringify(results, null, 2));

ws.close();
proc.kill();
process.exit(0);
