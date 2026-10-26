import sys, math
from PIL import Image, ImageDraw
from rbxm import read_rbxm
import numpy as np

# Building local frame: f = along facade (world ~ +Z), dvec = depth (world ~ +X)
F = np.array([-0.02205, 0, 0.99976]); F /= np.linalg.norm(F)
D = np.array([F[2], 0, -F[0]])  # perpendicular, ~ +X
ORG = np.array([36.72, 0.0, -1485.35])  # first column center

def to_local(p):
    p = np.array(p) - ORG
    return np.array([p @ F, p[1], p @ D])  # (u along facade, y, v depth)

def part_local_aabb(cf, size):
    (px,py,pz), rot = cf
    Rm = np.array(rot).reshape(3,3)  # rows R00 R01 R02 ...
    sx,sy,sz = size
    # 8 corners
    corners = []
    for dx in (-1,1):
        for dy in (-1,1):
            for dz in (-1,1):
                local = np.array([dx*sx/2, dy*sy/2, dz*sz/2])
                world = np.array([px,py,pz]) + Rm @ local
                corners.append(to_local(world))
    c = np.array(corners)
    return c.min(axis=0), c.max(axis=0)

def load(path):
    d = read_rbxm(path)
    I = d['insts']
    parts = []
    def walk(ref, path_):
        inst = I[ref]
        nm = inst['props'].get('Name', (0,b'?'))[1].decode()
        if inst['cls'] in ('Part','Seat','MeshPart','WedgePart','CornerWedgePart','TrussPart'):
            p = inst['props']
            if 'CFrame' in p and 'size' in p:
                lo, hi = part_local_aabb(p['CFrame'][1], p['size'][1])
                col = p.get('Color3uint8', (0,(163,162,165)))[1]
                tr = p.get('Transparency', (0,0.0))[1]
                parts.append({'ref': ref, 'name': nm, 'path': path_, 'lo': lo, 'hi': hi, 'col': tuple(col), 'tr': tr})
        for c in inst['children']:
            walk(c, path_ + '/' + nm)
    for r in d['roots']:
        walk(r, '')
    return d, parts

def render_elevation(parts, out, umin, umax, ymin, ymax, vmax, scale=8, vmin=-100):
    W = int((umax-umin)*scale); H = int((ymax-ymin)*scale)
    img = Image.new('RGB', (W, H), (90, 140, 200)); dr = ImageDraw.Draw(img)
    sel = [p for p in parts if p['lo'][2] < vmax and p['hi'][2] > vmin and p['tr'] < 0.9]
    sel.sort(key=lambda p: -p['hi'][2])  # far (big v) first
    for p in sel:
        x0 = (p['lo'][0]-umin)*scale; x1 = (p['hi'][0]-umin)*scale
        y0 = H-(p['hi'][1]-ymin)*scale; y1 = H-(p['lo'][1]-ymin)*scale
        dr.rectangle([x0,y0,x1,y1], fill=p['col'])
    # grid every 10 studs
    for u in range(int(umin), int(umax)+1, 10):
        x = (u-umin)*scale; dr.line([x,0,x,H], fill=(255,0,255), width=1); dr.text((x+2,2), str(u), fill=(255,255,0))
    img.save(out)

def render_plan(parts, out, umin, umax, vmin, vmax, ymin, ymax, scale=8):
    W = int((umax-umin)*scale); H = int((vmax-vmin)*scale)
    img = Image.new('RGB', (W, H), (30,30,30)); dr = ImageDraw.Draw(img)
    sel = [p for p in parts if p['lo'][1] < ymax and p['hi'][1] >= ymin and p['tr'] < 0.9]
    sel.sort(key=lambda p: p['hi'][1])  # low first, high drawn on top
    for p in sel:
        x0 = (p['lo'][0]-umin)*scale; x1 = (p['hi'][0]-umin)*scale
        y0 = (p['lo'][2]-vmin)*scale; y1 = (p['hi'][2]-vmin)*scale
        dr.rectangle([x0,y0,x1,y1], fill=p['col'])
    for u in range(int(umin), int(umax)+1, 10):
        x = (u-umin)*scale; dr.line([x,0,x,H], fill=(255,0,255), width=1); dr.text((x+2,2), str(u), fill=(255,255,0))
    for v in range(int(vmin), int(vmax)+1, 10):
        y = (v-vmin)*scale; dr.line([0,y,W,y], fill=(255,0,255), width=1); dr.text((2,y+2), str(v), fill=(255,255,0))
    img.save(out)

if __name__ == '__main__':
    d, parts = load(sys.argv[1])
    lo = np.min([p['lo'] for p in parts], axis=0); hi = np.max([p['hi'] for p in parts], axis=0)
    print("local extents u,y,v:", lo, hi)
    out = sys.argv[2]
    render_elevation(parts, out+'/elev_facade.png', lo[0]-2, hi[0]+2, -1, 29, vmax=3.0, vmin=-100, scale=8)
    render_elevation(parts, out+'/elev_ground_cut.png', lo[0]-2, hi[0]+2, -1, 14, vmax=1.5, vmin=-100, scale=10)
    render_plan(parts, out+'/plan_ground.png', lo[0]-2, hi[0]+2, lo[2]-2, hi[2]+2, 0.5, 13.0, scale=6)
    render_plan(parts, out+'/plan_upper.png', lo[0]-2, hi[0]+2, lo[2]-2, hi[2]+2, 14.3, 26.0, scale=6)
