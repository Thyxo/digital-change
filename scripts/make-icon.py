#!/usr/bin/env python3
"""Tegner et Kamera-agtigt app-ikon (1024 px) – bruges indtil ref/hjemmeskaerm.png findes.
Lys grå gradient, sort kamerahus med linse (iOS' Kamera-ikon i mørk tilstand ligner det)."""
from PIL import Image, ImageDraw, ImageFilter


def draw(size=1024):
    S = size * 4
    img = Image.new('RGB', (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):  # baggrund: lys grå → mellemgrå
        v = int(232 - 70 * y / S)
        d.line([(0, y), (S, y)], fill=(v, v, v + 2))
    k = S / 1024
    # kamerahus
    body = (180 * k, 330 * k, 844 * k, 760 * k)
    d.rounded_rectangle(body, radius=70 * k, fill=(28, 28, 30))
    d.rounded_rectangle((300 * k, 270 * k, 470 * k, 350 * k), radius=26 * k, fill=(28, 28, 30))  # søgerhus
    # linse
    cx, cy, r = 512 * k, 545 * k, 165 * k
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(205, 205, 210))
    r2 = r * 0.78
    d.ellipse((cx - r2, cy - r2, cx + r2, cy + r2), fill=(28, 28, 30))
    r3 = r * 0.5
    d.ellipse((cx - r3, cy - r3, cx + r3, cy + r3), fill=(60, 62, 70))
    d.ellipse((cx - r3 * 0.5 + 30 * k, cy - r3 * 0.5 - 30 * k, cx - r3 * 0.1 + 30 * k, cy - r3 * 0.1 - 30 * k), fill=(150, 152, 160))
    # gul prik (blitz)
    d.ellipse((730 * k, 390 * k, 780 * k, 440 * k), fill=(245, 200, 60))
    return img.resize((size, size), Image.LANCZOS)


if __name__ == '__main__':
    draw().save('icon-1024.png')
