"""Render front/side/top orthographic views of a named model (first match or by ref) into one PNG."""
import sys
from PIL import Image, ImageDraw
from render import load
import numpy as np

def model_parts(d, parts, ref):
    I = d['insts']
    want = set()
    def walk(r):
        want.add(r)
        for c in I[r]['children']: walk(c)
    walk(ref)
    return [p for p in parts if p['ref'] in want]

def draw_view(ps, ax, ay, depth_axis, depth_sign, scale, pad=1.0):
    lo = np.min([p['lo'] for p in ps], axis=0); hi = np.max([p['hi'] for p in ps], axis=0)
    W = int((hi[ax]-lo[ax]+2*pad)*scale); H = int((hi[ay]-lo[ay]+2*pad)*scale)
    img = Image.new('RGB', (max(W,1), max(H,1)), (40,40,60)); dr = ImageDraw.Draw(img)
    ps2 = sorted(ps, key=lambda p: depth_sign*((p['lo'][depth_axis]+p['hi'][depth_axis])/2))
    for p in ps2:
        if p['tr'] >= 0.95: continue
        x0 = (p['lo'][ax]-lo[ax]+pad)*scale; x1 = (p['hi'][ax]-lo[ax]+pad)*scale
        if ay == 1:
            y0 = H-(p['hi'][ay]-lo[ay]+pad)*scale; y1 = H-(p['lo'][ay]-lo[ay]+pad)*scale
        else:
            y0 = (p['lo'][ay]-lo[ay]+pad)*scale; y1 = (p['hi'][ay]-lo[ay]+pad)*scale
        col = tuple(int(c*(1-0.5*p['tr'])) for c in p['col'])
        dr.rectangle([x0,y0,x1,y1], fill=col, outline=tuple(max(0,c-40) for c in col))
    return img

if __name__ == '__main__':
    path, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
    scale = float(sys.argv[4]) if len(sys.argv) > 4 else 40
    idx = int(sys.argv[5]) if len(sys.argv) > 5 else 0
    d, parts = load(path)
    I = d['insts']
    matches = [r for r in I if I[r]['cls']=='Model' and I[r]['props'].get('Name',(0,b''))[1].decode()==name]
    matches.sort()
    ref = matches[idx]
    ps = model_parts(d, parts, ref)
    front = draw_view(ps, 0, 1, 2, -1, scale)   # looking from corridor (-v) toward +v: u horizontal, y vertical ; near = small v drawn last
    side = draw_view(ps, 2, 1, 0, -1, scale)    # looking from -u: v horizontal, y vertical
    top = draw_view(ps, 0, 2, 1, 1, scale)      # from above: u horizontal, v vertical
    W = front.width + side.width + top.width + 20; H = max(front.height, side.height, top.height)
    img = Image.new('RGB', (W, H), (0,0,0))
    img.paste(front, (0,0)); img.paste(side, (front.width+10, 0)); img.paste(top, (front.width+side.width+20, 0))
    img.save(out)
    lo = np.min([p['lo'] for p in ps], axis=0); hi = np.max([p['hi'] for p in ps], axis=0)
    print(name, 'ref', ref, 'parts', len(ps), 'extent u/y/v:', np.round(hi-lo,2), 'lo', np.round(lo,2))
