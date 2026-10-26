"""Oblique (cabinet-style) 3D preview of parts in the local frame. Each AABB is drawn as 3 shaded faces.
Usage: from render3d import render_oblique; render_oblique(parts, 'out.png', ...) where parts = list of dicts {lo, hi, col, tr}
or render_ctx3d(ctx, 'out.png', idx=None, ymax=None, ...)."""
import numpy as np
from PIL import Image, ImageDraw
from build import part_aabb_local

def collect_ctx(ctx, idx=None):
    ids = range(len(ctx.insts)) if idx is None else ctx.descendants(idx)
    ps = []
    for i in ids:
        inst = ctx.insts[i]
        if 'CFrame' in inst['props'] and 'size' in inst['props']:
            lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
            col = inst['props'].get('Color3uint8', (0,(163,162,165)))[1]
            tr = inst['props'].get('Transparency', (0,0.0))[1]
            ps.append({'lo': lo, 'hi': hi, 'col': tuple(int(c) for c in col), 'tr': tr})
    return ps

def render_oblique(ps, out, scale=12, k=0.5, ang_deg=35, ymax=None, ymin=None, umin=None, umax=None, vmin=None, vmax=None,
                   look='front', bg=(28,30,38)):
    """look='front': viewer in the courtyard (u right, y up, +v recedes up-right). look='back': viewer behind the back wall."""
    a = np.radians(ang_deg)
    sel = []
    for p in ps:
        if p['tr'] >= 0.95: continue
        if ymax is not None and p['lo'][1] > ymax: continue
        if ymin is not None and p['hi'][1] < ymin: continue
        if umin is not None and p['hi'][0] < umin: continue
        if umax is not None and p['lo'][0] > umax: continue
        if vmin is not None and p['hi'][2] < vmin: continue
        if vmax is not None and p['lo'][2] > vmax: continue
        q = dict(p)
        if ymax is not None: q['hi'] = np.minimum(q['hi'], [1e9, ymax, 1e9])
        sel.append(q)
    if not sel: raise ValueError('nothing to draw')
    sgn = 1 if look == 'front' else -1
    def proj(u, y, v):
        vv = v if look == 'front' else -v
        uu = u if look == 'front' else -u
        return uu + k*vv*np.cos(a), y + k*vv*np.sin(a)
    pts = []
    for p in sel:
        for cu in (p['lo'][0], p['hi'][0]):
            for cy in (p['lo'][1], p['hi'][1]):
                for cv in (p['lo'][2], p['hi'][2]):
                    pts.append(proj(cu, cy, cv))
    pts = np.array(pts)
    x0, y0 = pts.min(axis=0); x1, y1 = pts.max(axis=0)
    W = int((x1-x0)*scale)+20; H = int((y1-y0)*scale)+20
    img = Image.new('RGB', (W, H), bg); dr = ImageDraw.Draw(img)
    def S(x, y): return (10 + (x-x0)*scale, H - 10 - (y-y0)*scale)
    # painter: far first. "far" = larger v (front look) ; tie-break lower y first, then u
    sel.sort(key=lambda p: (-(p['lo'][2]+p['hi'][2])*sgn, (p['lo'][1]+p['hi'][1]), ))
    for p in sel:
        lo, hi = p['lo'], p['hi']
        c = p['col']; t = p['tr']
        def shade(f):
            return tuple(int(min(255, max(0, c[i]*f))*(1-t) + bg[i]*t) for i in range(3))
        uL, uR = (lo[0], hi[0]) if look == 'front' else (lo[0], hi[0])
        vN, vF = (lo[2], hi[2]) if look == 'front' else (hi[2], lo[2])   # near / far faces
        # front face (near, vN)
        f = [S(*proj(lo[0], lo[1], vN)), S(*proj(hi[0], lo[1], vN)), S(*proj(hi[0], hi[1], vN)), S(*proj(lo[0], hi[1], vN))]
        # top face
        tp = [S(*proj(lo[0], hi[1], vN)), S(*proj(hi[0], hi[1], vN)), S(*proj(hi[0], hi[1], vF)), S(*proj(lo[0], hi[1], vF))]
        # right side face (at hi u for front look)
        su = hi[0] if look == 'front' else lo[0]
        sd = [S(*proj(su, lo[1], vN)), S(*proj(su, lo[1], vF)), S(*proj(su, hi[1], vF)), S(*proj(su, hi[1], vN))]
        dr.polygon(sd, fill=shade(0.72)); dr.polygon(tp, fill=shade(1.0)); dr.polygon(f, fill=shade(0.86))
    img.save(out)
    return img.size

def render_ctx3d(ctx, out, idx=None, **kw):
    return render_oblique(collect_ctx(ctx, idx), out, **kw)

if __name__ == '__main__':
    import sys
    from render import load
    d, parts = load(sys.argv[1])
    ps = [{'lo': p['lo'], 'hi': p['hi'], 'col': p['col'], 'tr': p['tr']} for p in parts]
    print(render_oblique(ps, sys.argv[2], scale=6, ymax=float(sys.argv[3]) if len(sys.argv) > 3 else None))
