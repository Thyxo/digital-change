#!/usr/bin/env python3
"""Lægger de to Bicycle Rider Back-referencer (ref/rider-blue.jpg, ref/rider-red.jpg) præcist oven på hinanden.

Ingen gentegning: hvert output-pixel er en (Lanczos-)prøve af originalfotoet, kun flyttet geometrisk.

1. Blå (flad scanning): kortets venstre-, højre- og topkant måles med subpixel-præcision. Bunden er beskåret i
   scanningen og sættes ud fra mønstrets 180°-symmetri (samme topkant som bundkant om mønstrets centrum).
   De fire hjørner giver en homografi til et retvinklet "kanonisk" kort (1024 px bredt, scanningens proportioner).
2. Rød (produktfoto): registreres mod den blå på mønstret (ECC på lysstyrke, homografi, grov→fin),
   plus en blød 3.-grads korrektion af de resterende sub-pixel-afvigelser (fotoets linse).
3. Hvid baggrund fjernes (alfa = kortets afrundede omrids, antialiaseret). Scannerens skygge langs blå kant og
   den røde kant, som fotoet ikke dækker (det røde motiv har smallere kant), fyldes ved at spejle kortets egen
   papirstruktur ind fra kanten – ikke ved at tegne noget nyt.
4. Papirhvidt normaliseres, så rødt og blåt papir har samme farve (blækket er uændret i forhold til papiret).

Output:
  ios/Cards/rider-blue.png, rider-red.png   1024 px brede RGBA (visning i appen)
  ios/Cards/rider-blue.rgb, rider-red.rgb   256 px brede rå RGB8 (analyse i appen og tests)
  ios/Cards/rider.json                      geometri (størrelse, hjørneradius, mønsterramme, målte afvigelser)
  demo/rider-blue.png, demo/rider-red.png   til WebGL-demoen
  ref/rider-check.png                       kontrolbillede (blå | rød | skiftevis felter | forskel)

Kræver: pip install opencv-python-headless numpy
"""
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(ROOT, "ref")
OUT = os.path.join(ROOT, "ios", "Cards")
DEMO = os.path.join(ROOT, "demo")

CANON_W = 1024          # kanonisk bredde (px)
ANALYSIS_W = 256        # analyseskabelonens bredde
CRIT = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 400, 1e-8)


def load(name):
    im = cv2.imread(os.path.join(REF, name), cv2.IMREAD_COLOR)
    if im is None:
        sys.exit(f"mangler {name}")
    return cv2.cvtColor(im, cv2.COLOR_BGR2RGB).astype(np.float32)


def darkness(im):
    """Lysstyrke (luma, fuld opløsning – JPEG'ens farvekanaler er halv opløsning) vendt: blæk = 1, papir = 0."""
    y = 0.299 * im[..., 0] + 0.587 * im[..., 1] + 0.114 * im[..., 2]
    hi, lo = np.percentile(y, 99), np.percentile(y, 1)
    return ((hi - y) / (hi - lo)).clip(0, 1).astype(np.float32)


def srgb_to_lin(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055) * 255.0


# ---------------------------------------------------------------- 1. Blå: kanter, centrum, hjørner

def blue_geometry(blue):
    g = cv2.GaussianBlur(blue.mean(2), (0, 0), 0.8)
    h, w = g.shape
    bg = np.median(g[0:4, 100:430])
    border = np.median(g[30:40, 150:380])
    thr = (bg + border) / 2

    def cross(line):
        """Første krydsning af tærsklen (baggrund → kort), i pixelcentrum-koordinater."""
        idx = np.where(line < thr)[0]
        if len(idx) == 0 or idx[0] == 0:
            return np.nan
        i = idx[0]
        a, b = line[i - 1], line[i]
        return i - 1 + (a - thr) / (a - b)

    ys = np.arange(h, dtype=np.float64)
    xs = np.arange(w, dtype=np.float64)
    left = np.array([cross(g[y, :80]) for y in range(h)])
    right = np.array([w - 1 - cross(g[y, ::-1][:80]) for y in range(h)])
    top = np.array([cross(g[:80, x]) for x in range(w)])
    sy = (ys >= 120) & (ys <= 600)
    sx = (xs >= 110) & (xs <= 420)
    kl = np.polyfit(ys[sy], left[sy], 1)     # x = kl0*y + kl1
    kr = np.polyfit(ys[sy], right[sy], 1)
    kt = np.polyfit(xs[sx], top[sx], 1)      # y = kt0*x + kt1
    res = {
        "left": float(np.std(left[sy] - np.polyval(kl, ys[sy]))),
        "right": float(np.std(right[sy] - np.polyval(kr, ys[sy]))),
        "top": float(np.std(top[sx] - np.polyval(kt, xs[sx]))),
    }

    # Mønstrets 180°-symmetricentrum
    d = darkness(blue)
    rot = cv2.rotate(d, cv2.ROTATE_180)
    W = np.eye(2, 3, dtype=np.float32)
    for sig in (2.0, 1.0):
        _, W = cv2.findTransformECC(cv2.GaussianBlur(d, (0, 0), sig), cv2.GaussianBlur(rot, (0, 0), sig), W,
                                    cv2.MOTION_EUCLIDEAN, CRIT, None, 1)
    # d(x) ≈ d((w-1,h-1) − W·x)  ⇒  fast punkt c = ((w-1,h-1) − t) / 2 (W's lineære del ≈ 1)
    A = np.eye(2) + W[:, :2].astype(np.float64)
    c = np.linalg.solve(A, np.array([w - 1, h - 1], np.float64) - W[:, 2])

    def inter(kx, ky):
        # x = kx0*y + kx1 ; y = ky0*x + ky1
        y = (ky[0] * kx[1] + ky[1]) / (1 - ky[0] * kx[0])
        return np.array([kx[0] * y + kx[1], y])

    tl = inter(kl, kt)
    tr = inter(kr, kt)
    # Bundkant = topkant spejlet gennem centrum
    kb = np.array([kt[0], 2 * c[1] - kt[1] - 2 * kt[0] * c[0]])
    bl = inter(kl, kb)
    br = inter(kr, kb)
    return np.array([tl, tr, br, bl]), c, res


def corner_radius_blue(blue, corners):
    """Hjørneradius fra de to øverste (ubeskårne) hjørner: afstanden t langs diagonalen fra det skarpe hjørne
    (kantlinjernes skæring) ind til kortet er r·(√2 − 1)."""
    g = cv2.GaussianBlur(blue.mean(2), (0, 0), 0.8)
    bg = np.median(g[0:4, 100:430]); border = np.median(g[30:40, 150:380]); thr = (bg + border) / 2
    radii = []
    for (cx, cy), (dx, dy) in zip(corners[:2], ((1, 1), (-1, 1))):
        ts = np.arange(0, 30, 0.02)
        xs = cx + dx * ts / np.sqrt(2); ys = cy + dy * ts / np.sqrt(2)
        v = cv2.remap(g, xs.astype(np.float32)[None], ys.astype(np.float32)[None], cv2.INTER_LINEAR)[0]
        i = np.where(v < thr)[0][0]
        f = (v[i - 1] - thr) / (v[i - 1] - v[i])
        radii.append(float((ts[i - 1] + f * (ts[i] - ts[i - 1])) / (np.sqrt(2) - 1)))
    return radii


# ---------------------------------------------------------------- 2. Rød: registrering mod blå

def register_red(blue, red):
    B = darkness(blue)
    R = darkness(red)

    def bbox(I):
        ys, xs = np.where(I > 0.5)
        return xs.min(), ys.min(), xs.max(), ys.max()

    bb, rb = bbox(B), bbox(R)
    sx = (bb[2] - bb[0]) / (rb[2] - rb[0]); sy = (bb[3] - bb[1]) / (rb[3] - rb[1])
    H0 = np.array([[sx, 0, bb[0] - sx * rb[0]], [0, sy, bb[1] - sy * rb[1]], [0, 0, 1]])
    H = np.linalg.inv(H0).astype(np.float32)     # blå → rød
    k = (rb[2] - rb[0]) / (bb[2] - bb[0])
    ecc = 0.0
    for sig in (4.0, 2.0, 1.2, 0.8, 0.5):
        ecc, H = cv2.findTransformECC(cv2.GaussianBlur(B, (0, 0), sig), cv2.GaussianBlur(R, (0, 0), sig * k),
                                      H, cv2.MOTION_HOMOGRAPHY, CRIT, None, 1)
    return H.astype(np.float64), float(ecc)


def patch_shifts(A, Bimg, mask_rect, size=56, step=20, sigma=0.7):
    """Lokal forskydning (ECC, translation) mellem to billeder i samme koordinater. Retur: (x, y, dx, dy)."""
    a0 = cv2.GaussianBlur(A, (0, 0), sigma); b0 = cv2.GaussianBlur(Bimg, (0, 0), sigma)
    x0r, y0r, x1r, y1r = mask_rect
    out = []
    for y0 in range(int(y0r), int(y1r) - size, step):
        for x0 in range(int(x0r), int(x1r) - size, step):
            a = a0[y0:y0 + size, x0:x0 + size]; b = b0[y0:y0 + size, x0:x0 + size]
            if a.std() < 0.15:
                continue
            W = np.eye(2, 3, dtype=np.float32)
            try:
                cc, W = cv2.findTransformECC(a, b, W, cv2.MOTION_TRANSLATION,
                                             (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 80, 1e-6), None, 1)
            except cv2.error:
                continue
            if cc > 0.85:
                out.append((x0 + size / 2 - 0.5, y0 + size / 2 - 0.5, W[0, 2], W[1, 2]))
    return np.array(out)


def poly_basis(x, y, w, h, deg=3):
    u = (x - w / 2) / (w / 2); v = (y - h / 2) / (h / 2)
    return np.stack([u ** i * v ** j for i in range(deg + 1) for j in range(deg + 1 - i)], -1)


# ---------------------------------------------------------------- 3. Afrundede rektangler

def rrect_sdf(px, py, x0, y0, x1, y1, r):
    """Signeret afstand til et akseparallelt afrundet rektangel (negativ indenfor)."""
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
    qx, qy = np.abs(px - cx) - hx, np.abs(py - cy) - hy
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - r


def mirror_into(px, py, rect, r):
    """Punkter uden for det afrundede rektangel spejles ind over kanten (afstand e ud → e ind)."""
    x0, y0, x1, y1 = rect
    d = rrect_sdf(px, py, x0, y0, x1, y1, r)
    out = d > 0
    # gradient af afstandsfeltet = udadvendt normal
    eps = 0.25
    gx = (rrect_sdf(px + eps, py, *rect, r) - rrect_sdf(px - eps, py, *rect, r)) / (2 * eps)
    gy = (rrect_sdf(px, py + eps, *rect, r) - rrect_sdf(px, py - eps, *rect, r)) / (2 * eps)
    n = np.hypot(gx, gy) + 1e-9
    gx, gy = gx / n, gy / n
    mx = np.where(out, px - 2 * d * gx, px)
    my = np.where(out, py - 2 * d * gy, py)
    return mx, my, out


def coverage(px, py, rect, r, ss=4):
    """Antialiaseret dækning af et pixel (supersampling ss×ss) – alfakanalen."""
    acc = np.zeros_like(px)
    for i in range(ss):
        for j in range(ss):
            ox = (i + 0.5) / ss - 0.5; oy = (j + 0.5) / ss - 0.5
            acc += (rrect_sdf(px + ox, py + oy, *rect, r) <= 0)
    return acc / (ss * ss)


# ---------------------------------------------------------------- hoved

def main():
    os.makedirs(OUT, exist_ok=True)
    blue = load("rider-blue.jpg")
    red = load("rider-red.jpg")
    bh, bw = blue.shape[:2]
    rh, rw = red.shape[:2]

    corners, center, edge_res = blue_geometry(blue)
    radii = corner_radius_blue(blue, corners)
    widthB = (np.linalg.norm(corners[1] - corners[0]) + np.linalg.norm(corners[2] - corners[3])) / 2
    heightB = (np.linalg.norm(corners[3] - corners[0]) + np.linalg.norm(corners[2] - corners[1])) / 2
    s = CANON_W / widthB
    CW = CANON_W
    CH = int(round(heightB * s))
    radius_c = float(np.mean(radii)) * s

    # kanonisk (kant-konvention: kortet fylder [0,CW]×[0,CH]) → blå (pixelcentrum-konvention)
    canon_pts = np.float32([[0, 0], [CW, 0], [CW, CH], [0, CH]])
    blue_pts = np.float32(corners + 0.0)
    # kantlinjerne er målt som overgang baggrund→kort, dvs. selve kanten; pixelcentrum = kant − 0,5 er allerede
    # taget med i cross() (centrum-konvention), så hjørnerne bruges direkte.
    P = cv2.getPerspectiveTransform(canon_pts, blue_pts).astype(np.float64)

    Hbr, ecc = register_red(blue, red)

    # Blød restkorrektion (i blå koordinater)
    B = darkness(blue)
    Rw = cv2.warpPerspective(darkness(red), Hbr, (bw, bh), flags=cv2.INTER_CUBIC | cv2.WARP_INVERSE_MAP)
    pr = (48, 48, bw - 48, bh - 40)
    shifts0 = patch_shifts(B, Rw, pr)
    m0 = np.hypot(shifts0[:, 2], shifts0[:, 3])
    A = poly_basis(shifts0[:, 0], shifts0[:, 1], bw, bh)
    cx = np.linalg.lstsq(A, shifts0[:, 2], rcond=None)[0]
    cy = np.linalg.lstsq(A, shifts0[:, 3], rcond=None)[0]

    # kanoniske pixelcentre
    gx, gy = np.meshgrid(np.arange(CW, dtype=np.float64) + 0.5, np.arange(CH, dtype=np.float64) + 0.5)

    def apply_h(M, x, y):
        X = M[0, 0] * x + M[0, 1] * y + M[0, 2]
        Y = M[1, 0] * x + M[1, 1] * y + M[1, 2]
        Z = M[2, 0] * x + M[2, 1] * y + M[2, 2]
        return X / Z, Y / Z

    # Blå: gyldigt område = kortet minus 5 px (scannerens skygge langs kanten)
    inset_b = 5.0 * s
    valid_b = (inset_b, inset_b, CW - inset_b, CH - inset_b)
    mx, my, _ = mirror_into(gx, gy, valid_b, max(1.0, radius_c - inset_b))
    bx, by = apply_h(P, mx, my)

    # Rød: gyldigt område = rødfotoets eget kort (hele billedet, afrundede hjørner) minus 3 px, i kanoniske koordinater
    Hrb = np.linalg.inv(Hbr)
    Pinv = np.linalg.inv(P)
    rin = 3.0
    rc = np.array([[rin, rin], [rw - 1 - rin, rin], [rw - 1 - rin, rh - 1 - rin], [rin, rh - 1 - rin]])
    cc = np.array([apply_h(Pinv, *apply_h(Hrb, x, y)) for x, y in rc])
    valid_r = (max(cc[0, 0], cc[3, 0]), max(cc[0, 1], cc[1, 1]), min(cc[1, 0], cc[2, 0]), min(cc[2, 1], cc[3, 1]))
    # rødfotoets hjørneradius: diagonalt fra billedhjørnet til første kortpixel, r = t / (1 − 1/√2)
    rg = cv2.GaussianBlur(red.mean(2), (0, 0), 0.8)
    ts = []
    for (x0, y0, dx, dy) in ((0, 0, 1, 1), (rw - 1, 0, -1, 1), (rw - 1, rh - 1, -1, -1), (0, rh - 1, 1, -1)):
        for t in np.arange(0, 40, 0.25):
            if rg[int(round(y0 + dy * t)), int(round(x0 + dx * t))] < 245:
                ts.append(t); break
    r_red = float(np.mean(ts)) / (1 - 1 / np.sqrt(2))
    scale_rc = (valid_r[2] - valid_r[0]) / (rw - 1 - 2 * rin)
    mx, my, red_filled = mirror_into(gx, gy, valid_r, max(1.0, (r_red - rin) * scale_rc))
    ux, uy = apply_h(P, mx, my)                      # blå koordinater
    U = poly_basis(ux, uy, bw, bh)
    ux2 = ux + U @ cx
    uy2 = uy + U @ cy
    rx, ry = apply_h(Hbr, ux2, uy2)

    def sample(img, x, y):
        return cv2.remap(img, x.astype(np.float32), y.astype(np.float32), cv2.INTER_LANCZOS4,
                         borderMode=cv2.BORDER_REFLECT)

    canon_b = sample(blue, bx, by)
    canon_r = sample(red, rx, ry)

    # 4. Papirhvidt: samme papir i begge (lineært lys, pr. kanal), målt i den hvide kant
    border_band = (rrect_sdf(gx, gy, 0, 0, CW, CH, radius_c) < -16 * s) & \
                  (rrect_sdf(gx, gy, 0, 0, CW, CH, radius_c) > -30 * s)
    paper_b = np.median(srgb_to_lin(canon_b[border_band]), axis=0)
    paper_r = np.median(srgb_to_lin(canon_r[border_band]), axis=0)
    canon_r = lin_to_srgb(srgb_to_lin(canon_r) * (paper_b / paper_r))

    # 3. Alfa: kortets omrids
    alpha = coverage(gx, gy, (0, 0, CW, CH), radius_c) * 255.0

    def rgba(img):
        out = np.dstack([np.clip(img, 0, 255), alpha]).round().astype(np.uint8)
        return out

    blue_rgba, red_rgba = rgba(canon_b), rgba(canon_r)

    # Kontrol: resterende afvigelse mellem de færdige billeder
    Bd, Rd = darkness(canon_b), darkness(canon_r)
    shifts1 = patch_shifts(Bd, Rd, (60 * s, 60 * s, CW - 60 * s, CH - 60 * s), size=112, step=40, sigma=1.4)
    m1 = np.hypot(shifts1[:, 2], shifts1[:, 3]) / s      # i blå-scanningens pixels
    ecc_final, _ = cv2.findTransformECC(cv2.GaussianBlur(Bd, (0, 0), 1.0), cv2.GaussianBlur(Rd, (0, 0), 1.0),
                                        np.eye(2, 3, dtype=np.float32), cv2.MOTION_TRANSLATION, CRIT, None, 1)

    # Mønsterets ramme (yderkant af blækket) i kanoniske koordinater
    dm = cv2.GaussianBlur(Bd, (0, 0), 1.0)
    def first_ink(profile):
        idx = np.where(profile > 0.5)[0]
        return float(idx[0]) if len(idx) else np.nan
    mid = slice(int(CH * 0.3), int(CH * 0.7)); midx = slice(int(CW * 0.3), int(CW * 0.7))
    fl = np.nanmedian([first_ink(dm[y, :]) for y in range(mid.start, mid.stop, 7)])
    fr = CW - np.nanmedian([first_ink(dm[y, ::-1]) for y in range(mid.start, mid.stop, 7)])
    ft = np.nanmedian([first_ink(dm[:, x]) for x in range(midx.start, midx.stop, 7)])
    fb = CH - np.nanmedian([first_ink(dm[::-1, x]) for x in range(midx.start, midx.stop, 7)])

    # Gem
    def save_png(path, arr):
        cv2.imwrite(path, cv2.cvtColor(arr, cv2.COLOR_RGBA2BGRA), [cv2.IMWRITE_PNG_COMPRESSION, 9])

    for name, arr in (("blue", blue_rgba), ("red", red_rgba)):
        save_png(os.path.join(OUT, f"rider-{name}.png"), arr)
        save_png(os.path.join(DEMO, f"rider-{name}.png"), cv2.resize(arr, (CW // 2, int(round(CH / 2))),
                                                                     interpolation=cv2.INTER_AREA))
        # analyseskabelon: præmultipliceret mod papir uden for kortet er ligegyldigt – alfa gemmes ikke,
        # appen kender omridset fra rider.json
        ah = int(round(CH * ANALYSIS_W / CW))
        small = cv2.resize(arr[..., :3], (ANALYSIS_W, ah), interpolation=cv2.INTER_AREA)
        with open(os.path.join(OUT, f"rider-{name}.rgb"), "wb") as f:
            f.write(small.astype(np.uint8).tobytes())

    def r3(v): return round(float(v), 3)
    meta = {
        "comment": "Genereret af scripts/prepare-cards.py fra ref/rider-blue.jpg og ref/rider-red.jpg",
        "width": CW, "height": CH,
        "cornerRadius": r3(radius_c),
        "pattern": {"minX": r3(fl), "minY": r3(ft), "maxX": r3(fr), "maxY": r3(fb)},
        "analysis": {"width": ANALYSIS_W, "height": int(round(CH * ANALYSIS_W / CW))},
        "paper": [r3(v) for v in lin_to_srgb(paper_b)],
        "measurements": {
            "blueEdgeLineStd": {k: r3(v) for k, v in edge_res.items()},
            "blueCornerRadii": [r3(v) for v in radii],
            "bluePatternCenter": [r3(center[0]), r3(center[1])],
            "blueCorners": [[r3(x), r3(y)] for x, y in corners],
            "redCornerRadius": r3(r_red),
            "redEcc": r3(ecc),
            "residualBeforePx": {"mean": r3(m0.mean()), "p90": r3(np.percentile(m0, 90)), "max": r3(m0.max())},
            "residualAfterPx": {"mean": r3(m1.mean()), "p90": r3(np.percentile(m1, 90)), "max": r3(m1.max()),
                                "patches": int(len(m1))},
            "finalEcc": r3(ecc_final),
            "redFilledFraction": r3(float((red_filled & (alpha > 0)).mean())),
        },
    }
    with open(os.path.join(OUT, "rider.json"), "w") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
        f.write("\n")

    # Kontrolbillede: blå | rød | skiftevis felter (64 px) | forskel i mønstret (forstærket)
    tile = 64
    cb = ((gx // tile + gy // tile) % 2 == 0)[..., None]
    mix = np.where(cb, canon_b, canon_r)
    diff = np.abs(Bd - Rd)
    diff_img = np.dstack([diff * 255 * 2] * 3).clip(0, 255)
    def on_gray(img):
        a = alpha[..., None] / 255.0
        return img * a + 60 * (1 - a)
    panel = np.concatenate([on_gray(canon_b), np.full((CH, 16, 3), 60.0), on_gray(canon_r), np.full((CH, 16, 3), 60.0),
                            on_gray(mix), np.full((CH, 16, 3), 60.0), on_gray(diff_img)], 1)
    panel = cv2.resize(panel.astype(np.float32), None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA)
    cv2.imwrite(os.path.join(REF, "rider-check.png"), cv2.cvtColor(panel.clip(0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR))

    print(json.dumps(meta["measurements"], indent=2))
    print(f"kanonisk {CW}×{CH}, hjørneradius {radius_c:.1f}, mønster {fl:.1f},{ft:.1f}–{fr:.1f},{fb:.1f}")


if __name__ == "__main__":
    main()
