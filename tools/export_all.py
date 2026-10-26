"""Final export: rooms-only model, white gate model, and the full building with rooms merged in."""
import sys, os, importlib
import numpy as np
from build import Ctx, cframe
from rbxm import read_rbxm
from preview import render_ctx
from render3d import render_ctx3d
from shell import load_src, parts_to_remove, existing_parts_local, merge_original, overlaps, baseline_overlap_refs, _name
import assemble

OUT = assemble.OUT
DELIV = sys.argv[1] if len(sys.argv) > 1 else OUT

def add_pivot(ctx, idx, u, y, v):
    ctx.insts[idx]['props']['WorldPivotData'] = (0x1E, cframe(u, y, v))

def main():
    os.makedirs(DELIV, exist_ok=True)
    # 1) rooms-only model
    ctx = Ctx()
    root, stats = assemble.build_all(ctx)
    add_pivot(ctx, root, 0.0, 0.42, 0.0)
    total = ctx.count_parts(root)
    print('ROOMS STATS', stats, 'TOTAL', total)
    assert total <= 4000, total
    n = ctx.export(os.path.join(DELIV, 'Salones_Planta_Baja.rbxm'))
    print('Salones_Planta_Baja.rbxm', n, 'bytes')
    # 2) gate model
    try:
        porton = importlib.import_module('comp_porton')
        g = Ctx()
        pidx = porton.build_porton(g, -1, 0.0, 0.42, -40.0, yaw=0)
        add_pivot(g, pidx, 0.0, 0.42, -40.0)
        print('PORTON parts', g.count_parts(pidx))
        g.export(os.path.join(DELIV, 'Porton_Blanco.rbxm'))
        render_ctx(g, os.path.join(OUT, 'porton_views.png'), idx=pidx, scale=30)
        render_ctx3d(g, os.path.join(OUT, 'porton_3d.png'), idx=pidx, scale=30)
    except Exception as e:
        print('WARN porton:', e)
    # 3) full building
    src = load_src()
    rem = parts_to_remove(src)
    full = Ctx()
    idx, orig_root = merge_original(full, src, rem)
    # append the rooms under the original root model
    base = len(full.insts)
    for inst in ctx.insts:
        props = dict(inst['props'])
        for pn, (tid, val) in list(props.items()):
            if tid == 0x13 and val != -1:
                props[pn] = (tid, val + base)
        full.insts.append({'cls': inst['cls'], 'props': props, 'parent': (inst['parent'] + base) if inst['parent'] != -1 else orig_root})
    n = full.export(os.path.join(DELIV, 'Edificio_Completo_con_Salones.rbxm'), also_xml=False)
    print('Edificio_Completo_con_Salones.rbxm', n, 'bytes; instances', len(full.insts), 'parts', full.count_parts())
    # validate read-back
    for f in ('Salones_Planta_Baja.rbxm', 'Edificio_Completo_con_Salones.rbxm'):
        d = read_rbxm(os.path.join(DELIV, f))
        from collections import Counter
        print('  readback', f, Counter(i['cls'] for i in d['insts'].values()).most_common(6))
    # renders
    render_ctx(ctx, os.path.join(OUT, 'salones_front.png'), idx=root, scale=10, views=('front',))
    render_ctx(ctx, os.path.join(OUT, 'salones_top.png'), idx=root, scale=10, views=('top',))
    render_ctx3d(ctx, os.path.join(OUT, 'salones_3d_cutaway.png'), idx=root, scale=10, ymax=12.7)
    render_ctx3d(ctx, os.path.join(OUT, 'salones_3d_facade.png'), idx=root, scale=10)
    return stats, total

if __name__ == '__main__':
    main()
