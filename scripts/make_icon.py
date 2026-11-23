# -*- coding: utf-8 -*-
"""
生成「青芒短视频」应用图标（鸿蒙分层图标）。

设计：提香红对角渐变底 + 白色圆角播放三角 + 一圈极淡描边圆。
- background.png：铺满 1024x1024，无任何边距（避免桌面出现黑边）
- foreground.png：透明底，图形限制在中央安全区（约 62%），供系统裁圆角/圆形
- app_icon.png：两者合成，兼容旧式单层图标与启动页

配色取自用户偏好：提香红 #D34947（品牌主色）、申布伦黄 #F9D46C（高光点缀）。
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'AppScope', 'resources', 'base', 'media')
ENTRY_MEDIA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                           'entry', 'src', 'main', 'resources', 'base', 'media')

# 提香红系渐变端点
C_TOP = (228, 84, 82)     # #E45452 提香红提亮
C_BOTTOM = (150, 22, 30)  # #96161E 收敛后的深红


def lerp(a, b, t):
    return int(round(a + (b - a) * t))


def build_background():
    """对角渐变 + 中心柔和高光，1024x1024 全铺满"""
    buf = bytearray(SIZE * SIZE * 3)
    cx = cy = (SIZE - 1) / 2.0
    max_d = math.hypot(cx, cy)
    idx = 0
    for y in range(SIZE):
        for x in range(SIZE):
            # 对角渐变：左上亮、右下深
            t = (x + y) / (2.0 * (SIZE - 1))
            t = t * t * (3 - 2 * t)  # smoothstep，过渡更自然
            r = lerp(C_TOP[0], C_BOTTOM[0], t)
            g = lerp(C_TOP[1], C_BOTTOM[1], t)
            b = lerp(C_TOP[2], C_BOTTOM[2], t)

            # 中心偏上的柔光，避免大片纯色显得廉价
            d = math.hypot(x - cx * 0.92, y - cy * 0.62) / max_d
            glow = max(0.0, 1.0 - d * 1.55) ** 2 * 26
            r = min(255, int(r + glow))
            g = min(255, int(g + glow * 0.72))
            b = min(255, int(b + glow * 0.68))

            buf[idx] = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            idx += 3
    return Image.frombytes('RGB', (SIZE, SIZE), bytes(buf))


def triangle_mask(center, w, h, radius, fill=255):
    """
    圆角三角遮罩。

    不在顶点补圆（那样圆会外凸成三个球），而是先画尖角三角，
    再高斯模糊 + 取阈值，让三个角自然内切圆滑。
    """
    cx, cy = center
    ox = w * 0.055  # 视觉重心右移一点，三角才显得居中
    pts = [
        (cx - w / 2 + ox, cy - h / 2),
        (cx - w / 2 + ox, cy + h / 2),
        (cx + w / 2 + ox, cy),
    ]
    m = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(m).polygon(pts, fill=fill)
    m = m.filter(ImageFilter.GaussianBlur(radius))
    m = m.point(lambda a: 255 if a > 128 else 0)
    return m


def build_foreground():
    """透明前景：图形控制在中央安全区内"""
    layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    center = (SIZE / 2, SIZE / 2 - SIZE * 0.022)

    # 主图形：白色圆角播放三角
    mask = triangle_mask(center, SIZE * 0.335, SIZE * 0.385, radius=SIZE * 0.016)
    white = Image.new('RGBA', (SIZE, SIZE), (255, 255, 255, 255))
    layer.paste(white, (0, 0), mask)

    # 底部一条短横线，暗示进度条，避免整体过于空
    bar_w = SIZE * 0.34
    bar_h = SIZE * 0.026
    bar_y = center[1] + SIZE * 0.226
    draw.rounded_rectangle(
        [center[0] - bar_w / 2, bar_y - bar_h / 2, center[0] + bar_w / 2, bar_y + bar_h / 2],
        radius=bar_h / 2,
        fill=(255, 255, 255, 160),
    )

    return layer


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(ENTRY_MEDIA, exist_ok=True)

    bg = build_background()
    fg = build_foreground()

    bg.save(os.path.join(OUT, 'background.png'))
    fg.save(os.path.join(OUT, 'foreground.png'))

    composed = bg.convert('RGBA')
    composed.alpha_composite(fg)
    composed.convert('RGB').save(os.path.join(OUT, 'app_icon.png'), quality=95)

    # 桌面图标取的是 ability 的 icon（startIcon），所以这里必须是完整合成图，
    # 不能只放透明前景——否则桌面上只剩一个白三角，看起来像没有底。
    composed.convert('RGB').save(os.path.join(ENTRY_MEDIA, 'startIcon.png'))

    print('background.png / foreground.png / app_icon.png / startIcon.png 已生成')
    print('尺寸:', composed.size)


if __name__ == '__main__':
    main()
