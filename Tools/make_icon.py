#!/usr/bin/env python3
"""生成 tqLLM Control Center 应用图标：白底圆角 + 深灰线性 sliders（对齐原型 brand-icon）。"""
from PIL import Image, ImageDraw
import sys, os

out = sys.argv[1] if len(sys.argv) > 1 else "icon_1024.png"
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# 圆角白色卡片背景
r = 224
d.rounded_rectangle([32, 32, S - 32, S - 32], radius=r, fill=(255, 255, 255, 255),
                    outline=(231, 233, 236, 255), width=6)
ink = (31, 41, 46, 255)
lw = 44
# 两条水平线 + 两个竖直滑块（原型 sliders 图标）
y1, y2 = 392, 632
d.line([256, y1, 768, y1], fill=ink, width=lw)
d.line([256, y2, 768, y2], fill=ink, width=lw)
for x, ytop, ybot in [(420, 288, 496), (604, 528, 736)]:
    d.line([x, ytop, x, ybot], fill=ink, width=lw)
    d.ellipse([x - 56, (ytop + ybot) // 2 - 56, x + 56, (ytop + ybot) // 2 + 56],
              fill=(255, 255, 255, 255), outline=ink, width=lw)
img.save(out)
print("saved", out)