#!/usr/bin/env python3
"""青芒短视频 图标生成器。

用途：改一次 icon-qingmang.svg 的配色/造型，跑一次这个脚本，
     把 1024 母版同步到所有图标落点。

为什么要有这个脚本：图标有多个落点（桌面图标、启动图标），
手工逐张 P 图很容易出现「桌面换了、启动页还是旧图」这种不一致。
全部从同一张母版派生，改一处即全站同步。

关于 AppScope/media 下的 foreground.png / background.png：
那是分层图标（layered icon）的前景/背景层，但当前 app.json5 的 icon 直接指向
app_icon.png，没有任何配置引用它们，改了也不影响显示。若将来要启用分层图标，
需要单独出一张「纯渐变、无符号」的背景图 + 一张「透明底、符号居中缩到 56%」的前景图，
不能用本脚本的母版直接顶替（母版本身是实心带符号的，直接当背景会导致符号重复绘制）。

依赖：Chrome/Edge（渲染 SVG）+ Pillow（缩放）
用法：python docs/icon/build-icon.py
"""
import os
import subprocess
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ICON_DIR = os.path.join(ROOT, 'docs', 'icon')
SVG = os.path.join(ICON_DIR, 'icon-qingmang.svg')
MASTER = os.path.join(ICON_DIR, 'icon-1024.png')

CHROME_CANDIDATES = [
    r'C:/Program Files/Google/Chrome/Application/chrome.exe',
    r'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    r'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
]

# 落点：相对工程根目录的路径 -> 边长
TARGETS = [
    ('AppScope/resources/base/media/app_icon.png', 1024),          # 桌面图标
    ('entry/src/main/resources/base/media/startIcon.png', 1024),   # 启动窗口图标
    # 预览用的小图：核对缩到桌面尺寸后主符号是否还立得住
    ('docs/icon/icon-160.png', 160),
]


def find_chrome() -> str:
    for p in CHROME_CANDIDATES:
        if os.path.exists(p):
            return p
    sys.exit('未找到 Chrome/Edge，无法渲染 SVG')


def render_svg() -> None:
    """把 SVG 渲染成 1024 母版。

    必须用 --force-device-scale-factor=1，否则高分屏下会按系统缩放比渲染成 2048，
    桌面图标看似正常、实际被系统二次压缩后发虚。
    """
    chrome = find_chrome()
    url = 'file:///' + SVG.replace('\\', '/').lstrip('/')
    cmd = [
        chrome, '--headless=new', '--disable-gpu', '--hide-scrollbars',
        '--force-device-scale-factor=1',
        '--window-size=1024,1024',
        '--screenshot=' + MASTER,
        '--virtual-time-budget=1500',
        url,
    ]
    subprocess.run(cmd, capture_output=True, check=False)
    if not os.path.exists(MASTER):
        sys.exit('渲染失败：没有产出 ' + MASTER)
    print('母版已渲染:', MASTER)


def export() -> None:
    master = Image.open(MASTER).convert('RGB')
    if master.size != (1024, 1024):
        sys.exit('母版尺寸异常: %s' % (master.size,))

    for rel, size in TARGETS:
        dst = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if size == 1024:
            master.save(dst, optimize=True)
        else:
            master.resize((size, size), Image.LANCZOS).save(dst, optimize=True)
        print('  ->', rel, '%dx%d' % (size, size))


if __name__ == '__main__':
    render_svg()
    export()
    print('完成。')
