"""Render front/side/top views of everything in a Ctx (or under a given model index) to a PNG.
Usage inside a script:  from preview import render_ctx; render_ctx(ctx, 'out.png', idx=None, scale=40)
Front view = seen from the courtyard (u to the right, y up); side view = seen from -u (v to the right); top = plan (u right, v down).
"""
import numpy as np
from PIL import Image, ImageDraw
from build import part_aabb_local

def _collect(ctx, idx):
    ids = range(len(ctx.insts)) if idx is None else ctx.descendants(idx)
    ps = []
    for i in ids:
        inst = ctx.insts[i]
        if 'CFrame' in inst['props'] and 'size' in inst['props']:
            lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
            col = inst['props'].get('Color3uint8', (0,(163,162,165)))[1]
            tr = inst['props'].get('Transparency', (0,0.0))[1]
            ps.append({'lo': lo, 'hi': hi, 'col': tuple(int(c) for c in col), 'tr': tr, 'name': inst['props']['Name'][1].decode()})
    return ps

def _view(ps, ax, ay, depth_axis, depth_sign, scale, pad=0.5, bg=(40,40,60)):
    lo = np.min([p['lo'] for p in ps], axis=0); hi = np.max([p['hi'] for p in ps], axis=0)
    W = int((hi[ax]-lo[ax]+2*pad)*scale)+1; H = int((hi[ay]-lo[ay]+2*pad)*scale)+1
    img = Image.new('RGB', (W, H), bg); dr = ImageDraw.Draw(img)
    for p in sorted(ps, key=lambda p: depth_sign*((p['lo'][depth_axis]+p['hi'][depth_axis])/2)):
        if p['tr'] >= 0.95: continue
        x0 = (p['lo'][ax]-lo[ax]+pad)*scale; x1 = (p['hi'][ax]-lo[ax]+pad)*scale
        if ay == 1:
            y0 = H-(p['hi'][ay]-lo[ay]+pad)*scale; y1 = H-(p['lo'][ay]-lo[ay]+pad)*scale
        else:
            y0 = (p['lo'][ay]-lo[ay]+pad)*scale; y1 = (p['hi'][ay]-lo[ay]+pad)*scale
        col = tuple(int(c*(1-0.6*p['tr'])+bg[k]*0.6*p['tr']) for k,c in enumerate(p['col']))
        dr.rectangle([x0,y0,x1,y1], fill=col, outline=tuple(max(0,c-35) for c in col))
    return img

def render_ctx(ctx, out, idx=None, scale=40, views=('front','side','top')):
    ps = _collect(ctx, idx)
    if not ps:
        raise ValueError('no parts')
    imgs = []
    if 'front' in views: imgs.append(_view(ps, 0, 1, 2, -1, scale))   # near (small v) drawn last
    if 'back' in views: imgs.append(_view(ps, 0, 1, 2, 1, scale))
    if 'side' in views: imgs.append(_view(ps, 2, 1, 0, -1, scale))
    if 'top' in views: imgs.append(_view(ps, 0, 2, 1, 1, scale))
    W = sum(i.width for i in imgs) + 10*(len(imgs)-1); H = max(i.height for i in imgs)
    big = Image.new('RGB', (W, H), (0,0,0)); x = 0
    for i in imgs: big.paste(i, (x, 0)); x += i.width + 10
    big.save(out)
    lo = np.min([p['lo'] for p in ps], axis=0); hi = np.max([p['hi'] for p in ps], axis=0)
    return lo, hi
