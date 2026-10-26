"""True-rotation oblique render (each part drawn as its 6 rotated faces, painter's algorithm) for checking
tilted parts (palm fronds, flags, broom sticks) that the AABB previews cannot show.
Usage: from render_rot import render_rot; render_rot(ctx, 'out.png', idx=None, scale=40, az=-35, el=25)
"""
import math
import numpy as np
from PIL import Image, ImageDraw
from build import world_to_local

LIGHT = np.array([-0.4, 0.85, -0.55]); LIGHT /= np.linalg.norm(LIGHT)
FACES = [((0, 1, 2, 3), (0, 0, -1)), ((4, 5, 6, 7), (0, 0, 1)), ((0, 1, 5, 4), (0, -1, 0)), ((2, 3, 7, 6), (0, 1, 0)),
         ((0, 3, 7, 4), (-1, 0, 0)), ((1, 2, 6, 5), (1, 0, 0))]
CORNERS = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]


def _parts(ctx, idx):
    ids = range(len(ctx.insts)) if idx is None else ctx.descendants(idx)
    out = []
    for i in ids:
        inst = ctx.insts[i]
        p = inst['props']
        if 'CFrame' not in p or 'size' not in p:
            continue
        (px, py, pz), rot = p['CFrame'][1]
        R = np.array(rot).reshape(3, 3)
        sx, sy, sz = p['size'][1]
        pos = np.array([px, py, pz])
        corners = [np.array(world_to_local(pos + R @ np.array([cx * sx / 2, cy * sy / 2, cz * sz / 2]))) for cx, cy, cz in CORNERS]
        c0 = np.array(world_to_local(pos))
        # local-frame axes of the part (for face normals): columns of R mapped to local
        ax = [np.array(world_to_local(pos + R[:, k])) - c0 for k in range(3)]
        col = p.get('Color3uint8', (0, (163, 162, 165)))[1]
        tr = p.get('Transparency', (0, 0.0))[1]
        out.append((corners, ax, tuple(int(c) for c in col), float(tr)))
    return out


def render_rot(ctx, out, idx=None, scale=40, az=-35, el=25, bg=(30, 32, 44), pad=0.6):
    a, e = math.radians(az), math.radians(el)
    def proj(P):
        u, y, v = P
        u2 = u * math.cos(a) + v * math.sin(a)
        v2 = -u * math.sin(a) + v * math.cos(a)
        return u2, y * math.cos(e) + v2 * math.sin(e), v2 * math.cos(e) - y * math.sin(e)
    polys = []
    pts = []
    for corners, ax, col, tr in _parts(ctx, idx):
        if tr >= 0.95:
            continue
        pc = [proj(c) for c in corners]
        pts.extend(pc)
        for (ids, nloc) in FACES:
            n = sum(ax[k] * nloc[k] for k in range(3))
            n = n / (np.linalg.norm(n) + 1e-9)
            shade = 0.5 + 0.5 * max(0.0, float(n @ LIGHT))
            depth = sum(pc[i][2] for i in ids) / 4
            polys.append((depth, [(pc[i][0], pc[i][1]) for i in ids], tuple(int(min(255, c * shade)) for c in col), tr))
    pts = np.array(pts)
    x0, y0 = pts[:, 0].min() - pad, pts[:, 1].min() - pad
    x1, y1 = pts[:, 0].max() + pad, pts[:, 1].max() + pad
    W, H = int((x1 - x0) * scale) + 1, int((y1 - y0) * scale) + 1
    img = Image.new('RGBA', (W, H), bg + (255,))
    dr = ImageDraw.Draw(img)
    polys.sort(key=lambda t: -t[0])
    for depth, poly, col, tr in polys:
        pts2 = [((x - x0) * scale, H - (y - y0) * scale) for x, y in poly]
        if tr > 0.02:
            layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
            ImageDraw.Draw(layer).polygon(pts2, fill=col + (int(255 * (1 - tr)),))
            img = Image.alpha_composite(img, layer)
            dr = ImageDraw.Draw(img)
        else:
            dr.polygon(pts2, fill=col + (255,), outline=tuple(max(0, c - 40) for c in col) + (255,))
    img.convert('RGB').save(out)
    return W, H
