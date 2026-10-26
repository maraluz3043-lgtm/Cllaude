"""Final preview renders: facade elevation (orig + new), per-room interiors and plans."""
import re, sys, os
import assemble
from build import Ctx, part_aabb_local
from render3d import render_oblique
from render import load, render_elevation, render_plan
from shell import load_src, parts_to_remove
OUT = sys.argv[1] if len(sys.argv) > 1 else assemble.OUT
os.makedirs(OUT, exist_ok=True)
ctx = Ctx(); root, stats = assemble.build_all(ctx)
ps = []
for i in ctx.descendants(root):
    inst = ctx.insts[i]
    if 'CFrame' in inst['props'] and 'size' in inst['props']:
        lo, hi = part_aabb_local(inst['props']['CFrame'][1], inst['props']['size'][1])
        col = inst['props'].get('Color3uint8', (0,(163,162,165)))[1]
        ps.append({'lo': lo, 'hi': hi, 'col': tuple(int(c) for c in col), 'tr': inst['props'].get('Transparency',(0,0.0))[1],
                   'name': inst['props']['Name'][1].decode(), 'path': '', 'ref': -1})
src = load_src(); rem = set(parts_to_remove(src)); I = src['insts']
d, parts = load(assemble.__dict__.get('SRC_PATH', '/root/.claude/uploads/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/159d5810-Donde_pondras_los_salones_faltantes.rbxm'))
def under_removed(ref):
    r = ref
    while r is not None and r != -1:
        if r in rem: return True
        r = I[r]['parent']
    return False
orig = [p for p in parts if not under_removed(p['ref'])]
allp = orig + ps
# 1) facade elevation, ground floor, from the courtyard
render_elevation(allp, OUT + '/01_alzado_fachada_planta_baja.png', -26, 134, -0.5, 14.5, vmax=2.0, vmin=-20, scale=10)
# 2) per-room: plan (no ceiling) + interior oblique (no walls/ceiling)
interior = [p for p in ps if not re.match(r'(Piel_|Tabique|MuroFrontal|ZocaloFrontal|Zocalo_|Tablilla|Moldura_(Frente|Fondo|Izquierda|Derecha))', p['name'])]
for k, (name, (u0, u1)) in enumerate({'Salon_1_Grado5': (-1, 36), 'Salon_2_Cuarto': (34.5, 59.5), 'Salon_3_6C': (61, 98)}.items()):
    render_plan(ps, OUT + f'/{2+k}a_planta_{name}.png', u0, u1, -5, 23, 0.5, 12.5, scale=14)
    render_oblique(interior, OUT + f'/{2+k}b_interior_{name}.png', scale=16, ymax=12.7, umin=u0, umax=u1, vmin=-5, vmax=23, look='back', ang_deg=30, k=0.55)
# 3) facade close-ups of the three door bays (ground floor only)
for k, (name, (u0, u1)) in enumerate({'puerta_morada_grado5': (9, 26), 'puerta_azul_cuarto': (33, 50), 'puerta_blanca_6C': (71, 88)}.items()):
    render_oblique(allp, OUT + f'/{5+k}_fachada_{name}.png', scale=28, ymax=13.0, umin=u0, umax=u1, vmin=-5, vmax=1.5, look='front', ang_deg=30, k=0.35)
print('STATS', stats, 'TOTAL', ctx.count_parts(root))
