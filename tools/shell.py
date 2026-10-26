"""Room shells, replacement facade, merge with the original building, overlap checks."""
import math
import numpy as np
from build import Ctx, cframe, part_aabb_local, world_to_local, MAT
from rbxm import read_rbxm

import os
SRC_PATH = os.environ.get('RBXM_ORIGINAL', '/root/.claude/uploads/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/159d5810-Donde_pondras_los_salones_faltantes.rbxm')  # archivo original del usuario

# ---- building constants (local frame) ----
Y_FLOOR = 0.42          # finished floor / sidewalk top
Y_CEIL = 13.03          # underside of the existing ground-floor slab
V_FACADE_OUT, V_FACADE_IN = 0.40, 1.40
V_BACK = 21.40
WALL_T = 0.6            # new partition thickness
COL_U = [0.0, 11.2, 23.19, 35.19, 47.19, 58.38, 61.79, 72.99, 84.99, 96.98, 108.98, 120.18]
WIN_U = [5.15, 17.15, 29.15, 41.15, 53.15, 67.05, 79.05, 91.05, 103.05, 115.05]   # existing window centres per bay
DOOR_W, DOOR_H = 4.2, 8.6
COL_FACADE = (222, 224, 226); MAT_FACADE = 816   # same as the original MuroFrontal
COL_ZOC = (150, 22, 26)
COL_WALL = (236, 236, 230)
COL_FLOOR = (168, 72, 48)

ROOMS = [
    # name, u0, u1, door opening (ul, ur), calado/half-window (ul, ur), window bays (full), half-window height
    dict(key='salon1', nombre='Salon_1_Grado5', texto='GRADO 5°', u0=0.2, u1=35.19-WALL_T/2, door=(12.7, 16.9), half=(17.3, 21.7), bays=[0, 2], halfwin_h=2.8, door_variant='morada', hinge='izq', open_deg=0,
         left_existing=True, right_existing=False),
    dict(key='salon2', nombre='Salon_2_Cuarto', texto='CUARTO', u0=35.19+WALL_T/2, u1=58.2, door=(36.7, 40.9), half=(41.3, 45.7), bays=[4], halfwin_h=5.7, door_variant='azul', hinge='izq', open_deg=0,
         left_existing=False, right_existing=True),
    dict(key='salon3', nombre='Salon_3_6C', texto='6C', u0=62.0, u1=96.98-WALL_T/2, door=(79.3, 83.5), half=(74.5, 78.9), bays=[5, 7], halfwin_h=5.7, door_variant='blanca_6C', hinge='der', open_deg=75,
         left_existing=True, right_existing=False),
]
HALLS = [dict(u0=-0.8, u1=59.2, doors=[(12.7, 16.9), (36.7, 40.9)]), dict(u0=61.007, u1=121.006, doors=[(79.3, 83.5)])]

def build_fachada_reemplazo(ctx, parent):
    """Replacement for the two original 'MuroFrontal' and 'ZocaloFrontal' parts, with door openings."""
    m = ctx.model('Fachada_Reemplazo', parent)
    vc = (V_FACADE_OUT + V_FACADE_IN) / 2; vt = V_FACADE_IN - V_FACADE_OUT
    y0, y1 = 0.025, 13.025
    for h in HALLS:
        cuts = sorted(h['doors'])
        u = h['u0']
        for (dl, dr) in cuts:
            ctx.box('MuroFrontal_Tramo', ((u+dl)/2, (y0+y1)/2, vc), (dl-u, y1-y0, vt), color=COL_FACADE, material=MAT_FACADE, parent=m)
            # lintel above the door and sill strip below the threshold
            ctx.box('MuroFrontal_Dintel', ((dl+dr)/2, (Y_FLOOR+DOOR_H+y1)/2, vc), (dr-dl, y1-(Y_FLOOR+DOOR_H), vt), color=COL_FACADE, material=MAT_FACADE, parent=m)
            ctx.box('MuroFrontal_BaseUmbral', ((dl+dr)/2, (y0+Y_FLOOR)/2, vc), (dr-dl, Y_FLOOR-y0, vt), color=COL_FACADE, material=MAT_FACADE, parent=m)
            u = dr
        ctx.box('MuroFrontal_Tramo', ((u+h['u1'])/2, (y0+y1)/2, vc), (h['u1']-u, y1-y0, vt), color=COL_FACADE, material=MAT_FACADE, parent=m)
        # exterior red baseboard (ZocaloFrontal) y 0.4..1.2 at v 0.30..0.40, split at doors
        u = h['u0']
        for (dl, dr) in cuts:
            ctx.box('ZocaloFrontal', ((u+dl)/2, 0.825, 0.35), (dl-u, 0.8, 0.10), color=COL_ZOC, material=816, parent=m)
            u = dr
        ctx.box('ZocaloFrontal', ((u+h['u1'])/2, 0.825, 0.35), (h['u1']-u, 0.8, 0.10), color=COL_ZOC, material=816, parent=m)
    return m

def build_cascaron(ctx, parent, room):
    """Floor, partitions, wall skins, baseboards for one room. Returns model idx."""
    m = ctx.model('Estructura', parent)
    u0, u1 = room['u0'], room['u1']
    dl, dr = room['door']
    # floor slab (terracotta ceramic tiles), top flush with the sidewalk
    ctx.box('Piso_Baldosa', ((u0+u1)/2, (Y_FLOOR-0.10)/2, (V_FACADE_IN+V_BACK)/2), (u1-u0, Y_FLOOR+0.10, V_BACK-V_FACADE_IN), color=COL_FLOOR, material='CeramicTiles', parent=m)
    # new partition walls (only where there is no existing wall)
    hwall = Y_CEIL - Y_FLOOR
    if not room['left_existing']:
        ctx.box('Tabique_Izquierdo', (u0-WALL_T/2, (Y_FLOOR+Y_CEIL)/2, (V_FACADE_IN+V_BACK)/2), (WALL_T, hwall, V_BACK-V_FACADE_IN), color=COL_WALL, material='Plaster', parent=m)
    if not room['right_existing']:
        ctx.box('Tabique_Derecho', (u1+WALL_T/2, (Y_FLOOR+Y_CEIL)/2, (V_FACADE_IN+V_BACK)/2), (WALL_T, hwall, V_BACK-V_FACADE_IN), color=COL_WALL, material='Plaster', parent=m)
    # paint skins over existing concrete walls (facade inner face, back wall, existing side walls)
    sk = 0.04
    yc = (Y_FLOOR+Y_CEIL)/2
    # facade inner face, cut around the door opening
    ctx.box('Piel_Fachada_Izq', ((u0+dl)/2, yc, V_FACADE_IN+sk/2), (dl-u0, hwall, sk), color=COL_WALL, material='Plaster', parent=m)
    ctx.box('Piel_Fachada_Der', ((dr+u1)/2, yc, V_FACADE_IN+sk/2), (u1-dr, hwall, sk), color=COL_WALL, material='Plaster', parent=m)
    ytop = Y_FLOOR + DOOR_H
    ctx.box('Piel_Fachada_Dintel', ((dl+dr)/2, (ytop+Y_CEIL)/2, V_FACADE_IN+sk/2), (dr-dl, Y_CEIL-ytop, sk), color=COL_WALL, material='Plaster', parent=m)
    ctx.box('Piel_Trasera', ((u0+u1)/2, yc, V_BACK-sk/2), (u1-u0, hwall, sk), color=COL_WALL, material='Plaster', parent=m)
    if room['left_existing']:
        ctx.box('Piel_Lateral_Izq', (u0+sk/2, yc, (V_FACADE_IN+V_BACK)/2), (sk, hwall, V_BACK-V_FACADE_IN), color=COL_WALL, material='Plaster', parent=m)
    if room['right_existing']:
        ctx.box('Piel_Lateral_Der', (u1-sk/2, yc, (V_FACADE_IN+V_BACK)/2), (sk, hwall, V_BACK-V_FACADE_IN), color=COL_WALL, material='Plaster', parent=m)
    # baseboards (zócalo rojo) 0.8 tall x 0.08 thick
    zh, zt = 0.8, 0.08
    yz = Y_FLOOR + zh/2
    vin, vback = V_FACADE_IN + sk, V_BACK - sk
    ctx.box('Zocalo_Fachada_Izq', ((u0+dl)/2, yz, vin+zt/2), (dl-u0, zh, zt), color=COL_ZOC, material='SmoothPlastic', parent=m)
    ctx.box('Zocalo_Fachada_Der', ((dr+u1)/2, yz, vin+zt/2), (u1-dr, zh, zt), color=COL_ZOC, material='SmoothPlastic', parent=m)
    ctx.box('Zocalo_Trasero', ((u0+u1)/2, yz, vback-zt/2), (u1-u0, zh, zt), color=COL_ZOC, material='SmoothPlastic', parent=m)
    ul = u0 + (sk if room['left_existing'] else 0.0); ur = u1 - (sk if room['right_existing'] else 0.0)
    ctx.box('Zocalo_Izquierdo', (ul+zt/2, yz, (vin+vback)/2), (zt, zh, vback-vin), color=COL_ZOC, material='SmoothPlastic', parent=m)
    ctx.box('Zocalo_Derecho', (ur-zt/2, yz, (vin+vback)/2), (zt, zh, vback-vin), color=COL_ZOC, material='SmoothPlastic', parent=m)
    return m

# ---------------- original building: load, find parts to remove, merge ----------------
def load_src():
    return read_rbxm(SRC_PATH)

def _name(I, r):
    return I[r]['props'].get('Name', (0, b''))[1].decode()

def parts_to_remove(src):
    """Return refs of original instances that the new facade replaces: MuroFrontal x2, ZocaloFrontal x2, and the 3 window models in the door bays."""
    I = src['insts']
    out = []
    for r, inst in I.items():
        n = _name(I, r)
        if inst['cls'] == 'Part' and n in ('MuroFrontal', 'ZocaloFrontal') and 'CFrame' in inst['props']:
            u, y, v = world_to_local(inst['props']['CFrame'][1][0])
            if y < 13.5 and -1.0 < v < 2.0:
                out.append(r)
        if inst['cls'] == 'Model' and n.startswith('Aula_'):
            # window model: use the Vidrio child position
            for c in inst['children']:
                if _name(I, c) == 'Vidrio':
                    u, y, v = world_to_local(I[c]['props']['CFrame'][1][0])
                    for room in ROOMS:
                        dl, dr = room['door']
                        if dl - 2.5 < u < dr + 2.5 and y < 13:
                            out.append(r)
    return out

def existing_parts_local(src):
    """AABBs (local) of all original parts, for overlap checks."""
    I = src['insts']
    out = []
    def walk(r, path):
        inst = I[r]
        nm = _name(I, r)
        if 'CFrame' in inst['props'] and 'size' in inst['props']:
            lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
            out.append((r, path + '/' + nm, lo, hi))
        for c in inst['children']:
            walk(c, path + '/' + nm)
    for r in src['roots']:
        walk(r, '')
    return out

def merge_original(ctx, src, remove_refs):
    """Append all original instances (except remove_refs subtrees) to ctx, keeping every property. Returns {old_ref: new_idx} and the root idx."""
    I = src['insts']
    skip = set()
    def mark(r):
        skip.add(r)
        for c in I[r]['children']: mark(c)
    for r in remove_refs: mark(r)
    refs = [r for r in sorted(I) if r not in skip]
    base = len(ctx.insts)
    idx = {r: base + i for i, r in enumerate(refs)}
    for r in refs:
        inst = I[r]
        props = {}
        for pn, (tid, val) in inst['props'].items():
            if tid == 0x13:
                val = idx.get(val, -1) if val != -1 else -1
            props[pn] = (tid, val)
        par = inst['parent']
        ctx.insts.append({'cls': inst['cls'], 'props': props, 'parent': idx[par] if par not in (None, -1) and par in idx else -1})
    ctx.sstr = list(src['sstr'])
    return idx, idx[src['roots'][0]]

def baseline_overlap_refs(src, removed_refs, existing, tol=0.15):
    """Existing parts that the removed original facade parts already intersected (columns, sidewalk, red stripes...)."""
    I = src['insts']
    out = set()
    for r in removed_refs:
        inst = I[r]
        if 'CFrame' not in inst['props']: continue
        lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
        for (r2, p2, lo2, hi2) in existing:
            pen = np.minimum(hi, hi2) - np.maximum(lo, lo2)
            if (pen > tol).all(): out.add(r2)
    return out

def overlaps(ctx, new_root, existing, ignore_refs=(), tol=0.15, facade_ignore=()):
    """List (new_part_name, existing_path, penetration) for new parts whose AABB penetrates an existing part by > tol in all three axes.
    facade_ignore: existing refs to ignore for the replacement facade parts only."""
    ign = set(ignore_refs)
    out = []
    ex = [(r, p, lo, hi) for (r, p, lo, hi) in existing if r not in ign]
    fac = set(facade_ignore)
    exlo = np.array([e[2] for e in ex]); exhi = np.array([e[3] for e in ex])
    for i in ctx.descendants(new_root):
        inst = ctx.insts[i]
        if 'CFrame' not in inst['props'] or 'size' not in inst['props']:
            continue
        lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
        pen = np.minimum(hi, exhi) - np.maximum(lo, exlo)   # per-axis overlap
        mask = (pen > tol).all(axis=1)
        nm = inst['props']['Name'][1].decode()
        for j in np.where(mask)[0]:
            if (nm.startswith('MuroFrontal_') or nm == 'ZocaloFrontal') and ex[j][0] in fac:
                continue
            out.append((nm, ex[j][1], tuple(float(x) for x in np.round(pen[j], 2))))
    return out

if __name__ == '__main__':
    from preview import render_ctx
    ctx = Ctx()
    root = ctx.model('Salones_Planta_Baja')
    build_fachada_reemplazo(ctx, root)
    for room in ROOMS:
        rm = ctx.model(room['nombre'], root)
        build_cascaron(ctx, rm, room)
    print('shell parts', ctx.count_parts(root))
    src = load_src()
    rem = parts_to_remove(src)
    I = src['insts']
    print('to remove:', [(r, _name(I, r), [round(x,1) for x in world_to_local(I[r]['props']['CFrame'][1][0])] if 'CFrame' in I[r]['props'] else '') for r in rem])
    ex = existing_parts_local(src)
    for r in rem:
        if I[r]['cls'] == 'Model':
            for c in I[r]['children']:
                if _name(I, c) == 'Vidrio': print('   window to remove', r, _name(I, r), [round(x,2) for x in world_to_local(I[c]['props']['CFrame'][1][0])])
    base = baseline_overlap_refs(src, rem, ex)
    ov = overlaps(ctx, root, ex, ignore_refs=set(rem) | {c for r in rem for c in I[r]['children']}, facade_ignore=base)
    print('overlaps:', len(ov))
    for o in ov[:40]: print('  ', o)
    render_ctx(ctx, '../out/shell_preview.png', idx=root, scale=8)
