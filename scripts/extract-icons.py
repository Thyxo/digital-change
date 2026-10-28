#!/usr/bin/env python3
"""Skærer kameraets glyffer ud af dine egne screenshots i ref/ og laver app-ikonet.

- Glyffer (ref/kamera-2.webp og ref/kamera-1.webp, 923×2000 px = 393×852 pt): måne, flash, live,
  "mere" (2×3 prikker), søger-knappens pile (udvid/sammentryk) og vend-kamera. Gemmes som hvide PNG'er
  med gennemsigtighed i Assets.xcassets/glyph-*.imageset (skabelon-billeder, som glyphs/ i CalcPlus).
- App-ikon: findes ref/hjemmeskaerm.png, skæres Kamera-ikonet ud (angiv centrum og størrelse med
  --icon x,y,størrelse i pixels). Ellers tegnes et Kamera-agtigt ikon (scripts/make-icon.py).

Kør: python3 scripts/extract-icons.py [--icon 540,1720,190]   (kræver Pillow + numpy)
"""
import json, os, sys
import numpy as np
from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), '..')
REF = os.path.join(ROOT, 'ref')
ASSETS = os.path.join(ROOT, 'ios', 'KameraPlus', 'Assets.xcassets')
PT = 923 / 393  # px pr. punkt i screenshots


def save_imageset(name, img):
    d = os.path.join(ASSETS, f'{name}.imageset')
    os.makedirs(d, exist_ok=True)
    img.save(os.path.join(d, f'{name}.png'), optimize=True)
    json.dump({
        'images': [{'filename': f'{name}.png', 'idiom': 'universal'}],
        'info': {'author': 'xcode', 'version': 1},
        'properties': {'template-rendering-intent': 'template', 'preserves-vector-representation': False},
    }, open(os.path.join(d, 'Contents.json'), 'w'), indent=2)


def glyph(file, cx, cy, size, name, lift=14, clear_border=2):
    """Kvadrat omkring (cx, cy) i px → hvid glyf, alfa ud fra hvor meget lysere pixlen er end baggrunden."""
    im = Image.open(os.path.join(REF, file)).convert('RGB')
    h = size / 2
    a = np.asarray(im.crop((round(cx - h), round(cy - h), round(cx + h), round(cy + h)))).astype(np.float64)
    lum = a.min(axis=2)
    edge = np.concatenate([lum[0], lum[-1], lum[:, 0], lum[:, -1]])
    bg = np.median(edge) + lift
    alpha = ((lum - bg) / (255 - bg)).clip(0, 1)
    if clear_border:
        alpha[:clear_border, :] = alpha[-clear_border:, :] = 0
        alpha[:, :clear_border] = alpha[:, -clear_border:] = 0
    rgba = np.zeros(a.shape[:2] + (4,), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = (alpha * 255).round().astype(np.uint8)
    out = Image.fromarray(rgba, 'RGBA').resize((size * 2, size * 2), Image.LANCZOS)
    save_imageset(f'glyph-{name}', out)
    print(f'glyph-{name}: {size} px = {size / PT:.1f} pt')


def glyphs():
    # Top-pillen (screenshot 2, ikonerne står lige): centre x 597, 679, 761, 843 px, y 210 px
    glyph('kamera-2.webp', 597, 210, 64, 'moon')
    glyph('kamera-2.webp', 679, 210, 64, 'flash-off')
    glyph('kamera-2.webp', 761, 210, 64, 'live-auto')
    glyph('kamera-2.webp', 843, 210, 64, 'more')
    # Søger-knappen (Ø 88 px): screenshot 2 = "udvid" (pile udad), screenshot 1 = "sammentryk"
    glyph('kamera-2.webp', 461, 1422, 56, 'expand', lift=40)
    glyph('kamera-1.webp', 461, 1422, 56, 'collapse', lift=40)
    # Vend kamera (Ø 112 px), screenshot 2
    glyph('kamera-2.webp', 787, 1863, 78, 'flip', lift=20)


def app_icon(spec):
    d = os.path.join(ASSETS, 'AppIcon.appiconset')
    os.makedirs(d, exist_ok=True)
    home = os.path.join(REF, 'hjemmeskaerm.png')
    if spec and os.path.exists(home):
        x, y, s = [int(v) for v in spec.split(',')]
        im = Image.open(home).convert('RGB').crop((x - s // 2, y - s // 2, x + s // 2, y + s // 2))
        if s < 180:
            print(f'Advarsel: ikonet er kun {s} px – 1024 px-ikonet bliver blødt. Tag gerne et større screenshot.')
        im.resize((1024, 1024), Image.LANCZOS).save(os.path.join(d, 'icon-1024.png'))
        print('app-ikon skåret ud af', home)
    else:
        import importlib.util
        spec_ = importlib.util.spec_from_file_location('mk', os.path.join(os.path.dirname(__file__), 'make-icon.py'))
        mk = importlib.util.module_from_spec(spec_)
        spec_.loader.exec_module(mk)
        mk.draw().save(os.path.join(d, 'icon-1024.png'))
        print('app-ikon tegnet (ref/hjemmeskaerm.png mangler)')
    json.dump({
        'images': [{'filename': 'icon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
        'info': {'author': 'xcode', 'version': 1},
    }, open(os.path.join(d, 'Contents.json'), 'w'), indent=2)


if __name__ == '__main__':
    spec = None
    if '--icon' in sys.argv:
        spec = sys.argv[sys.argv.index('--icon') + 1]
    os.makedirs(ASSETS, exist_ok=True)
    json.dump({'info': {'author': 'xcode', 'version': 1}}, open(os.path.join(ASSETS, 'Contents.json'), 'w'), indent=2)
    glyphs()
    app_icon(spec)
