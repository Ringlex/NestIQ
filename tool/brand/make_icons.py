#!/usr/bin/env python3
"""Generuje ikonę, tło splasha i grafiki marki NestIQ (Android, iOS, aplikacja).

Uruchom z katalogu głównego projektu: python3 tool/brand/make_icons.py
Wymaga Pillow. Kolory pochodzą z motywu aplikacji (seed #1F6F78).
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SEED = (0x1F, 0x6F, 0x78)
LIGHT = (0x3C, 0xA7, 0xB0)   # jaśniejszy odcień seeda (góra)
DEEP = (0x0F, 0x3E, 0x46)    # ciemniejszy odcień seeda (dół)
AMBER = (0xFF, 0xD9, 0x8E)
AMBER_HOT = (0xFF, 0xC3, 0x5C)
MINT = (0xB9, 0xEB, 0xF3)    # kolor awatara z palety profili

N = 1024  # praca na dużym płótnie, potem zmniejszanie


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_bg(size=N):
    """Przekątny gradient turkusu z miękkim blaskiem i koncentrycznymi falami sygnału."""
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x * .35 + y * .65) / size
            px[x, y] = lerp(LIGHT, DEEP, min(1, max(0, t)) ** 1.1)
    img = img.convert('RGBA')

    # blask za domkiem
    glow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    c = size * .5
    gd.ellipse([c - size * .36, c - size * .34, c + size * .36, c + size * .38], fill=(*MINT, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(size * .08))
    img.alpha_composite(glow)

    # fale
    rings = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rings)
    for k, alpha in ((.46, 34), (.62, 24), (.80, 16)):
        r = size * k
        rd.ellipse([c - r, c * 1.08 - r, c + r, c * 1.08 + r], outline=(255, 255, 255, alpha), width=int(size * .006))
    img.alpha_composite(rings)
    return img


def house_mask(size, scale):
    """Domek z zaokrąglonymi narożnikami (rozmycie + próg zaokrągla też dach)."""
    big = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(big)
    s = size * scale
    o = (size - s) / 2

    def p(x, y):
        return (o + x * s, o + y * s)

    d.polygon([p(.50, .10), p(.93, .50), p(.82, .50), p(.82, .88), p(.18, .88), p(.18, .50), p(.07, .50)], fill=255)
    r = size * .022
    blurred = big.filter(ImageFilter.GaussianBlur(r))
    return blurred.point(lambda v: 255 if v > 128 else 0).filter(ImageFilter.GaussianBlur(1.2)), (o, s)


def foreground(size=N, scale=1.0):
    """Domek ze szklistym gradientem, cieniem i świecącym węzłem; tło przezroczyste."""
    mask, (o, s) = house_mask(size, scale)

    def p(x, y):
        return (o + x * s, o + y * s)

    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))

    # cień
    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    shadow.paste((5, 30, 36, 150), (0, int(size * .018)), mask)
    out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(size * .022)))

    # korpus: biel z lekkim miętowym przejściem ku dołowi
    body = Image.new('RGBA', (size, size))
    bp = body.load()
    top, bottom = (255, 255, 255), (214, 238, 242)
    for y in range(size):
        c = (*lerp(top, bottom, max(0, min(1, (y - o) / s))), 255)
        for x in range(size):
            bp[x, y] = c
    out.paste(body, (0, 0), mask)

    # połysk na dachu
    fade = Image.linear_gradient('L').resize((size, size)).point(lambda v: 255 - v)  # góra jasna, dół znika
    gloss_a = ImageChops.multiply(fade, mask).point(lambda v: int(v * .30))
    gloss = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    gloss.putalpha(gloss_a)
    out.alpha_composite(gloss)

    # świecący węzeł i fale sygnału
    cx, cy = p(.50, .665)
    r = .095 * s
    halo = Image.new('RGBA', (size, size), (*AMBER, 0))  # kolor w przezroczystych pikselach, żeby rozmycie nie brudziło
    hd = ImageDraw.Draw(halo)
    hd.ellipse([cx - r * 2.3, cy - r * 2.3, cx + r * 2.3, cy + r * 2.3], fill=(*AMBER, 150))
    halo = halo.filter(ImageFilter.GaussianBlur(r * .9))
    halo.putalpha(ImageChops.multiply(halo.getchannel('A'), mask))  # blask tylko wewnątrz domku
    out.alpha_composite(halo)

    arcs = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arcs)
    for k, a in ((1.75, 255), (2.6, 170)):
        rr = r * k
        ad.arc([cx - rr, cy - rr, cx + rr, cy + rr], 218, 322, fill=(*AMBER_HOT, a), width=int(.03 * s))
    # łuki tylko wewnątrz korpusu
    arcs.putalpha(ImageChops.multiply(arcs.getchannel('A'), mask))
    out.alpha_composite(arcs)

    dot = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dot)
    dd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*AMBER_HOT, 255))
    dd.ellipse([cx - r * .72, cy - r * .78, cx + r * .72, cy + r * .66], fill=(*AMBER, 255))
    dd.ellipse([cx - r * .42, cy - r * .62, cx + r * .1, cy - r * .2], fill=(255, 246, 224, 230))
    out.alpha_composite(dot)
    return out


def tile(size, radius_ratio=0.0):
    bg = gradient_bg()
    bg.alpha_composite(foreground(N, .74))
    if radius_ratio:
        m = Image.new('L', (N, N), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, N - 1, N - 1], radius=int(N * radius_ratio), fill=255)
        bg.putalpha(m)
    return bg.resize((size, size), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


RES = 'android/app/src/main/res'
BG = gradient_bg()
FG = foreground(N, 1.0)

# Android: klasyczne (zaokrąglony kafel) i adaptacyjne (tło + pierwszy plan, 108dp)
for folder, px in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
    save(tile(px, .22), f'{RES}/mipmap-{folder}/ic_launcher.png')
for folder, px in (('mdpi', 108), ('hdpi', 162), ('xhdpi', 216), ('xxhdpi', 324), ('xxxhdpi', 432)):
    save(BG.convert('RGB').resize((px, px), Image.LANCZOS), f'{RES}/mipmap-{folder}/ic_launcher_background.png')
    # strefa bezpieczna to środkowe 66% kadru; domek zajmuje ok. 62%
    fg = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    inner = FG.resize((int(N * .66), int(N * .66)), Image.LANCZOS)
    fg.paste(inner, ((N - inner.width) // 2, (N - inner.height) // 2))
    save(fg.resize((px, px), Image.LANCZOS), f'{RES}/mipmap-{folder}/ic_launcher_foreground.png')

# Splash Androida: sam domek na turkusie
for folder, px in (('mdpi', 96), ('hdpi', 144), ('xhdpi', 192), ('xxhdpi', 288), ('xxxhdpi', 384)):
    save(FG.resize((px, px), Image.LANCZOS), f'{RES}/drawable-{folder}/splash_logo.png')

# iOS: kafel bez przezroczystości i bez zaokrągleń (system sam zaokrągla)
ICONS = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
master = tile(1024).convert('RGB')
for name in os.listdir(ICONS):
    if name.endswith('.png'):
        label = name[9:-4]
        if label == '1024x1024@1x':
            px = 1024
        else:
            base, scale = label.split('@')
            px = round(float(base.split('x')[0]) * int(scale[0]))
        master.resize((px, px), Image.LANCZOS).save(f'{ICONS}/{name}')

LAUNCH = 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
for name, px in (('LaunchImage.png', 160), ('LaunchImage@2x.png', 320), ('LaunchImage@3x.png', 480)):
    save(FG.resize((px, px), Image.LANCZOS), f'{LAUNCH}/{name}')

save(FG.resize((512, 512), Image.LANCZOS), 'assets/brand/logo.png')
print('gotowe')
