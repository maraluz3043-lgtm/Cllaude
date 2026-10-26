"""Internal consistency checks of the assembled rooms: furniture-vs-furniture bbox intersections, items outside room bounds."""
import numpy as np, re
import assemble
from build import Ctx, part_aabb_local
from shell import ROOMS, V_FACADE_IN, V_BACK, Y_FLOOR, Y_CEIL
ctx = Ctx(); root, stats = assemble.build_all(ctx)
I = ctx.insts
def name(i): return I[i]['props']['Name'][1].decode()
# furniture models = children of the group models inside each room (depth 3: root/room/group/item)
problems = 0
for room_idx in ctx.children(root):
    rn = name(room_idx)
    if not rn.startswith('Salon'): continue
    room = [r for r in ROOMS if r['nombre'] == rn][0]
    items = []
    for g in ctx.children(room_idx):
        gn = name(g)
        if gn in ('Estructura',): continue
        for it in ctx.children(g):
            lo, hi = ctx.bbox(it)
            if lo is None: continue
            items.append((gn + '/' + name(it), lo, hi))
    # pairwise intersections
    for a in range(len(items)):
        for b in range(a+1, len(items)):
            na, la, ha = items[a]; nb, lb, hb = items[b]
            pen = np.minimum(ha, hb) - np.maximum(la, lb)
            if (pen > 0.25).all():
                # ignore ceiling planks vs lights/fans (lights hang from planks), calado vs window dressings
                print(f'  {rn}: {na} x {nb} pen={np.round(pen,2)}'); problems += 1
    # bounds: furniture inside the room (except facade group and exterior stuff)
    for n, lo, hi in items:
        if n.startswith('Fachada/'): continue
        if lo[0] < room['u0'] - 0.01 or hi[0] > room['u1'] + 0.01 or lo[2] < V_FACADE_IN - 0.01 or hi[2] > V_BACK + 0.01 or lo[1] < Y_FLOOR - 0.01 or hi[1] > Y_CEIL + 0.01:
            print(f'  {rn}: OUT OF BOUNDS {n} lo={np.round(lo,2)} hi={np.round(hi,2)}'); problems += 1
print('problems:', problems)
