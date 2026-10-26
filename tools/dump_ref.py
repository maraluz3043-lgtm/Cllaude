"""Dump reference models (parts in building-local coords relative to the model's bbox min) + render views."""
import sys, math, os
import numpy as np
from rbxm import read_rbxm
from render import load
from views import model_parts, draw_view
from build import B, MAT, world_to_local
from PIL import Image, ImageDraw
MATN = {v:k for k,v in MAT.items()}
SRC = '/root/.claude/uploads/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/159d5810-Donde_pondras_los_salones_faltantes.rbxm'
d, parts = load(SRC)
I = d['insts']
def nm(r): return I[r]['props'].get('Name',(0,b''))[1].decode()
def local_rot(rot):
    R = np.array(rot).reshape(3,3)
    M = B.T @ R   # local rotation in (u,y,w) frame
    # try to express as yaw/pitch/roll (approx): yaw from M[0,0], M[0,2]
    yaw = math.degrees(math.atan2(M[0,2], M[0,0]))
    pitch = math.degrees(math.atan2(-M[1,2], M[1,1])) if abs(M[1,1]) > 1e-6 else 0.0
    roll = math.degrees(math.atan2(M[1,0], M[0,0])) if abs(M[0,0]) > 1e-6 else 90.0
    return yaw, pitch, roll, M
def dump(spec, outdir):
    name, _, cnt = spec.partition(':')
    cands = sorted(r for r in I if I[r]['cls']=='Model' and nm(r)==name)
    chosen = None
    for r in cands:
        ps = model_parts(d, parts, r)
        if not cnt or len(ps) == int(cnt): chosen = (r, ps); break
    if not chosen: print('no match', spec); return
    r, ps = chosen
    lo = np.min([p['lo'] for p in ps], axis=0); hi = np.max([p['hi'] for p in ps], axis=0)
    lines = [f"# Modelo de referencia '{name}' (ref {r}) — {len(ps)} parts. Extensión (u,y,v) = {np.round(hi-lo,2).tolist()}",
             f"# Coordenadas: centro relativo a la esquina mínima del bbox del modelo (u,y,v). size=(w,h,d) en ejes del part. yaw/pitch/roll en grados.",
             "# cls | name | center(u,y,v) | size(w,h,d) | color RGB | material | transparency | shape | yaw,pitch,roll"]
    def walk(ref, depth):
        inst = I[ref]
        if inst['cls'] == 'Model':
            lines.append('  '*depth + f"[Model '{nm(ref)}']")
        elif 'CFrame' in inst['props']:
            p = inst['props']
            (px,py,pz), rot = p['CFrame'][1]
            u,y,v = world_to_local((px,py,pz))
            sx,sy,sz = p['size'][1]
            col = p.get('Color3uint8',(0,(0,0,0)))[1]
            mat = MATN.get(p.get('Material',(0,256))[1], p.get('Material',(0,256))[1])
            tr = p.get('Transparency',(0,0))[1]
            shape = {0:'Ball',1:'Block',2:'Cylinder',3:'Wedge',4:'CornerWedge'}.get(p.get('shape',(0,1))[1],'?')
            yaw, pitch, roll, M = local_rot(rot)
            if abs(yaw)<0.3: yaw=0.0
            if abs(pitch)<0.3: pitch=0.0
            if abs(roll)<0.3: roll=0.0
            extra = ''
            for c in inst['children']:
                ci = I[c]
                if ci['cls'] in ('SurfaceGui','SpecialMesh','PointLight','SurfaceLight','Decal','Texture'):
                    extra += f" +{ci['cls']}" + (f"(MeshType={ci['props'].get('MeshType',(0,'?'))[1]},Scale={tuple(round(x,2) for x in ci['props'].get('Scale',(0,(1,1,1)))[1])})" if ci['cls']=='SpecialMesh' else '')
                    for g in ci['children']:
                        if I[g]['cls']=='TextLabel': extra += f" text='{I[g]['props']['Text'][1].decode()}'"
            lines.append('  '*depth + f"{inst['cls']} | {nm(ref)} | ({u-lo[0]:.2f},{y-lo[1]:.2f},{v-lo[2]:.2f}) | ({sx:.2f},{sy:.2f},{sz:.2f}) | {tuple(int(c) for c in col)} | {mat} | {tr:.2f} | {shape} | {yaw:.0f},{pitch:.0f},{roll:.0f}{extra}")
        for c in inst['children']:
            if I[c]['cls'] in ('Model',) or 'CFrame' in I[c]['props']:
                walk(c, depth+1)
    walk(r, 0)
    safe = name.replace(' ','_')
    open(os.path.join(outdir, f"{safe}.txt"), 'w').write('\n'.join(lines)+'\n')
    scale = max(8, min(60, int(600/max(hi-lo))))
    front = draw_view(ps, 0, 1, 2, -1, scale); side = draw_view(ps, 2, 1, 0, -1, scale); top = draw_view(ps, 0, 2, 1, 1, scale)
    W = front.width + side.width + top.width + 20; H = max(front.height, side.height, top.height) + 14
    img = Image.new('RGB', (W, H), (0,0,0)); dr = ImageDraw.Draw(img)
    dr.text((2,0), f"{name} parts={len(ps)} vistas: frente(desde el corredor) | lado(desde -u) | planta — escala {scale}px/stud", fill=(255,255,0))
    img.paste(front, (0,14)); img.paste(side, (front.width+10, 14)); img.paste(top, (front.width+side.width+20, 14))
    img.save(os.path.join(outdir, f"{safe}.png"))
    print(f"{safe}: {len(ps)} parts, extent {np.round(hi-lo,2).tolist()}")
for spec in sys.argv[2:]:
    dump(spec, sys.argv[1])
