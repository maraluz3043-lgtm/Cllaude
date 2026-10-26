"""Assemble the three ground-floor classrooms + replacement facade; export rbxm/rbxmx; merge into the full building."""
import os, sys, math, importlib, traceback
import numpy as np
from build import Ctx, cframe, world_to_local, FACE
from preview import render_ctx
from shell import (ROOMS, HALLS, Y_FLOOR, Y_CEIL, V_FACADE_IN, V_FACADE_OUT, V_BACK, WALL_T, WIN_U, DOOR_H,
                   build_fachada_reemplazo, build_cascaron, load_src, parts_to_remove, existing_parts_local,
                   merge_original, overlaps, baseline_overlap_refs, _name)

OUT = os.environ.get('SALONES_OUT', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'modelos', '_vistas'))

def imp(name):
    try:
        return importlib.import_module(name)
    except Exception as e:
        print('WARN cannot import', name, e); return None

P = imp('comp_pupitres'); DOC = imp('comp_docente'); TAB = imp('comp_tablero'); TEC = imp('comp_techo')
PUE = imp('comp_puertas'); MISC = imp('comp_misc')

SRC = load_src()

def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception:
        traceback.print_exc(); return None

# yaw conventions (see API.md): object "front" faces -v for yaw=0; faces +u for yaw=+90; faces -u for yaw=-90; faces +v for yaw=180.
FACING = {'-v': 0.0, '+u': 90.0, '-u': -90.0, '+v': 180.0}
# wall-mounted objects: with yaw=0 the wall is behind (+v); wall at -u -> yaw=90; wall at +u -> yaw=-90; wall at -v (facade) -> yaw=180
WALL_AT = {'+v': 0.0, '-u': 90.0, '+u': -90.0, '-v': 180.0}

def layout_room(ctx, rm, room, style):
    """style: dict with keys board_wall ('+u','-u','+v'), desk ('azul'|'madera'), ...
    rm = room model idx."""
    u0, u1 = room['u0'], room['u1']
    dl, dr = room['door']
    sk = 0.04
    vin, vback = V_FACADE_IN + sk, V_BACK - sk     # interior faces after paint skins
    ul = u0 + (sk if room['left_existing'] else 0.0)
    ur = u1 - (sk if room['right_existing'] else 0.0)
    uc, vc = (ul+ur)/2, (vin+vback)/2
    counts = {}
    def grp(name):
        return ctx.model(name, rm)
    # ---------------- facade: door, calado, half window, posters ----------------
    g = grp('Fachada')
    if PUE:
        safe(PUE.build_puerta, ctx, g, (dl+dr)/2, Y_FLOOR, (V_FACADE_OUT+V_FACADE_IN)/2, room['door_variant'],
             hoja_abierta_grados=room['open_deg'], bisagra=room['hinge'], texto=room['texto'])
        hl, hr = room['half']
        hc = (hl+hr)/2
        safe(PUE.build_calado, ctx, g, hc, 3.6, 0.34, ancho=hr-hl, alto=4.2)
        hh = room['halfwin_h']
        safe(PUE.build_media_ventana, ctx, g, hc, 6.2 + hh/2, 0.25, ancho=hr-hl, alto=hh)
        for (bay, tema, dx) in style['afiches_ventana']:
            if isinstance(bay, int):
                safe(PUE.build_afiche_ventana, ctx, g, WIN_U[bay] + dx, 9.0, 0.28, tema=tema)
            else:   # paño izquierdo de la media ventana: afiche pequeño
                ah = min(1.8, hh - 1.1)
                safe(PUE.build_afiche_ventana, ctx, g, hc + dx, 6.2 + hh / 2, 0.28, tema=tema, ancho=1.4, alto=ah)
    if TEC and style.get('condensador'):
        # exterior AC condenser above the half window (as in photo 1)
        hl, hr = room['half']; hh = room['halfwin_h']
        safe(TEC.build_condensador_exterior, ctx, g, (hl+hr)/2, 6.2 + hh + 2.62, V_FACADE_OUT, yaw=0)   # pared (fachada) hacia +v; ménsulas justo sobre la ventana
    if MISC and style.get('maceta'):
        safe(MISC.build_maceta_palma, ctx, g, style['maceta'][0], Y_FLOOR, style['maceta'][1], color_maceta=(150, 78, 52))
    # ---------------- interior windows (dressing on the inner face) ----------------
    g = grp('Ventanas_Interior')
    if MISC:
        for bay in room['bays']:
            safe(MISC.build_ventana_interior, ctx, g, WIN_U[bay], 6.2 + 5.7/2, vin, ancho=8.3, alto=5.7, panos=3)
        hl, hr = room['half']; hh = room['halfwin_h']
        safe(MISC.build_ventana_interior, ctx, g, (hl+hr)/2, 6.2 + hh/2, vin, ancho=hr-hl, alto=hh, panos=2)
    if PUE:
        # calado seen from inside (dots facing the room)
        for bay in room['bays']:
            idx = safe(PUE.build_calado, ctx, g, WIN_U[bay], 3.6, vin + 0.06, ancho=6.0, alto=4.2)
            flip_gui_faces(ctx, idx, (0, 0, 1))
        hl, hr = room['half']
        idx = safe(PUE.build_calado, ctx, g, (hl+hr)/2, 3.6, vin + 0.06, ancho=hr-hl, alto=4.2)
        flip_gui_faces(ctx, idx, (0, 0, 1))
    # ---------------- ceiling, lights, fans, AC ----------------
    g = grp('Techo_e_Instalaciones')
    if TEC:
        safe(TEC.build_cielo_raso, ctx, g, ul, ur, vin, vback, Y_CEIL)
        y_l = Y_CEIL - 0.12
        nu = 3 if (ur-ul) > 28 else 2
        for i in range(nu):
            for j in range(2):
                safe(TEC.build_luminaria, ctx, g, ul + (ur-ul)*(i+0.5)/nu, y_l, vin + (vback-vin)*(j+0.5)/2, yaw=0)
        safe(TEC.build_ventilador_techo, ctx, g, uc, y_l, vc)
        for (fu, fv, wall) in style['vent_pared']:
            safe(TEC.build_ventilador_pared, ctx, g, fu, 10.6, fv, yaw=WALL_AT[wall])
        swall, salong = style['split']
        su, sv = wall_point(swall, ul, ur, vin, vback, salong)
        safe(TEC.build_split_interior, ctx, g, su, 11.4, sv, yaw=WALL_AT[swall])
        # switch next to the door (inside), outlets, conduit along the back wall
        u_sw = dl - 0.6 if room['half'][0] > dr else dr + 0.6     # lado del hueco sin calado
        safe(TEC.build_interruptor, ctx, g, u_sw, 4.6, vin, yaw=WALL_AT['-v'])
        safe(TEC.build_toma, ctx, g, uc - 6, 1.6, vback, yaw=WALL_AT['+v'])
        safe(TEC.build_toma, ctx, g, uc + 6, 1.6, vback, yaw=WALL_AT['+v'])
        safe(TEC.build_canaleta, ctx, g, ul + 0.3, ur - 0.3, 11.9, vback, yaw=WALL_AT['+v'])
    # ---------------- board, bulletin boards, posters, clock, flag ----------------
    g = grp('Tablero_y_Carteleras')
    bw = style['board_wall']
    if TAB:
        bu, bv = wall_point(bw, ul, ur, vin, vback, style.get('board_along', 0.5))
        safe(TAB.build_tablero, ctx, g, bu, 6.4, bv, yaw=WALL_AT[bw], ancho=style.get('board_w', 9.6), alto=5.7)
        safe(TAB.build_reloj, ctx, g, *wall_point(bw, ul, ur, vin, vback, style.get('board_along', 0.5) + style.get('clock_off', 0.3)), yaw=WALL_AT[bw]) if False else None
        cu, cv = wall_point(bw, ul, ur, vin, vback, style.get('board_along', 0.5) + style.get('clock_off', 0.32))
        safe(TAB.build_reloj, ctx, g, cu, 10.6, cv, yaw=WALL_AT[bw])
        safe(TAB.build_letrero_grado, ctx, g, cu, 9.2, cv, yaw=WALL_AT[bw], texto=room['texto'])
        for (wall, along, ancho, titulo) in style['carteleras']:
            cu, cv = wall_point(wall, ul, ur, vin, vback, along)
            safe(TAB.build_cartelera, ctx, g, cu, 7.4, cv, yaw=WALL_AT[wall], ancho=ancho, alto=4.0, titulo=titulo)
        for (wall, along, tema) in style['afiches']:
            cu, cv = wall_point(wall, ul, ur, vin, vback, along)
            safe(TAB.build_afiche, ctx, g, cu, 7.0, cv, yaw=WALL_AT[wall], tema=tema)
    if MISC and style.get('bandera'):
        wall, along = style['bandera']
        cu, cv = wall_point(wall, ul, ur, vin, vback, along)
        safe(MISC.build_bandera_colombia, ctx, g, cu, 8.6, cv, yaw=WALL_AT[wall])
    # ---------------- teacher ----------------
    g = grp('Docente')
    if DOC:
        tu, tv, tyaw = style['mesa']
        safe(DOC.build_mesa_docente, ctx, g, tu, Y_FLOOR, tv, yaw=tyaw, estilo=style.get('mesa_estilo', 'madera'))
        cu_, cv_, cyaw = style['silla']
        safe(DOC.build_silla_docente, ctx, g, cu_, Y_FLOOR, cv_, yaw=cyaw, color=style.get('silla_color', 'azul'))
    if MISC:
        tu, tv, tyaw = style['mesa']
        safe(MISC.build_libros, ctx, g, tu + style.get('libros_off', (1.8, 0.3))[0], Y_FLOOR + 3.0, tv + style.get('libros_off', (1.8, 0.3))[1], yaw=tyaw)
    # ---------------- desks ----------------
    g = grp('Pupitres')
    n = 0
    if P:
        fn = P.build_pupitre_azul if style['desk'] == 'azul' else P.build_pupitre_madera
        for (du_, dv_) in style['desks']:
            idx = safe(fn, ctx, g, du_, Y_FLOOR, dv_, yaw=FACING[style['desk_facing']])
            if idx is not None: n += 1
    counts['pupitres'] = n
    # ---------------- misc ----------------
    g = grp('Varios')
    if MISC:
        for (ou, ov, kind, yaw) in style['misc']:
            fn = {'papelera': MISC.build_papelera, 'armario': MISC.build_armario, 'escoba': MISC.build_escoba,
                  'botellon': MISC.build_botellon_agua, 'mochila': MISC.build_mochila}[kind]
            if kind in ('papelera', 'botellon'):
                safe(fn, ctx, g, ou, Y_FLOOR, ov)
            elif kind == 'mochila':
                safe(fn, ctx, g, ou, Y_FLOOR, ov, yaw=yaw, color=style.get('mochila_color', (200, 40, 40)))
            else:
                safe(fn, ctx, g, ou, Y_FLOOR, ov, yaw=yaw)
    return counts

def wall_point(wall, ul, ur, vin, vback, along):
    """Point on a wall face: along in [0,1] measured from the wall's left end as seen from inside the room."""
    if wall == '+v':   # back wall, seen from inside: left = ur side? Standing inside facing +v, right hand = -u... keep simple: along measured from ul
        return ul + (ur-ul)*along, vback
    if wall == '-v':
        return ul + (ur-ul)*along, vin
    if wall == '+u':
        return ur, vin + (vback-vin)*along
    if wall == '-u':
        return ul, vin + (vback-vin)*along
    raise ValueError(wall)

def flip_gui_faces(ctx, idx, direction):
    """Make every SurfaceGui under idx face the given local direction (e.g. (0,0,1) = into the room)."""
    if idx is None: return
    from build import face_toward, B
    for i in ctx.descendants(idx):
        inst = ctx.insts[i]
        if inst['cls'] == 'SurfaceGui':
            par = ctx.insts[inst['parent']]
            rot = np.array(par['props']['CFrame'][1][1]).reshape(3, 3)
            # compute face whose normal points along direction in world space
            du, dy, dv = direction
            from build import F, Yv, D
            dworld = du*F + dy*Yv + dv*D
            best = None
            for fidx, vec in ((0, rot[:,0]), (3, -rot[:,0]), (1, rot[:,1]), (4, -rot[:,1]), (2, rot[:,2]), (5, -rot[:,2])):
                s = float(vec @ dworld)
                if best is None or s > best[0]: best = (s, fidx)
            inst['props']['Face'] = (0x12, best[1])

def grid(u_list, v_list):
    return [(u, v) for u in u_list for v in v_list]

def styles():
    R1, R2, R3 = ROOMS
    sk = 0.04
    # ---- Salón 1 (u 0.2..34.89): board on the right partition (+u); desks face +u ----
    s1 = dict(board_wall='+u', board_along=0.5, board_w=9.6, clock_off=0.36, desk='azul', desk_facing='+u',
              desks=grid([6.0, 10.6, 15.2, 19.8, 24.4], [5.4, 9.7, 14.0, 18.3]),
              mesa=(30.6, 17.0, -90.0), silla=(32.6, 17.0, -90.0), mesa_estilo='madera', silla_color='azul', libros_off=(-0.6, -2.65),
              vent_pared=[(10.0, V_BACK-sk, '+v'), (26.0, V_BACK-sk, '+v')], split=('+u', 0.30),
              carteleras=[('+v', 0.25, 6.0, 'HORARIO'), ('+v', 0.62, 6.0, 'VALORES')], afiches=[('-u', 0.3, 'abc'), ('+v', 0.88, 'valores')],
              bandera=('+u', 0.12), afiches_ventana=[(0, 'dios', -2.55), (2, 'todo_lo_puedo', 2.55), ('half', 'todo_lo_puedo', -0.96)], condensador=True, maceta=None,
              misc=[(18.2, 3.0, 'papelera', 0), (2.4, 20.4, 'armario', 0.0), (0.86, 3.2, 'escoba', 90.0), (31.5, 3.2, 'botellon', 0), (10.6, 7.55, 'mochila', 20.0)])
    # ---- Salón 2 (u 35.49..58.2): board on the back wall (+v); desks face +v ----
    s2 = dict(board_wall='+v', board_along=0.55, board_w=9.6, clock_off=0.33, desk='madera', desk_facing='+v',
              desks=grid([38.0, 42.5, 47.0, 51.5, 56.0], [5.2, 9.6, 14.0]),
              mesa=(39.8, 18.2, 0.0), silla=(39.8, 20.0, 0.0), mesa_estilo='metal', silla_color='negra', libros_off=(-1.6, -0.3),
              vent_pared=[(ROOMS[1]['u0'], 8.0, '-u'), (58.2-sk, 8.0, '+u')], split=('-u', 0.7),
              carteleras=[('+u', 0.5, 6.0, 'CARTELERA'), ('-u', 0.6, 5.0, 'CUMPLEAÑOS')], afiches=[('-v', 0.52, 'valores'), ('+u', 0.2, 'abc')],
              bandera=('+v', 0.12), afiches_ventana=[('half', 'todo_lo_puedo', -0.96), (4, 'guitarra', -2.55)], condensador=False, maceta=(33.0, -2.2),
              misc=[(42.6, 3.0, 'papelera', 0), (56.2, 20.4, 'armario', 0.0), (57.54, 3.2, 'escoba', -90.0), (57.3, 16.6, 'botellon', 0), (51.5, 11.8, 'mochila', -30.0)])
    # ---- Salón 3 (u 62.0..96.68): board on the left wall (-u); desks face -u ----
    s3 = dict(board_wall='-u', board_along=0.5, board_w=9.6, clock_off=0.36, desk='azul', desk_facing='-u',
              desks=grid([71.8, 76.4, 81.0, 85.6, 90.2], [5.8, 10.0, 14.2, 18.4]),
              mesa=(66.3, 17.0, 90.0), silla=(64.3, 17.0, 90.0), mesa_estilo='madera', silla_color='azul', libros_off=(0.6, 2.65),
              vent_pared=[(70.0, V_BACK-sk, '+v'), (88.0, V_BACK-sk, '+v')], split=('-u', 0.30),
              carteleras=[('+v', 0.35, 6.0, 'HORARIO'), ('+v', 0.72, 6.0, 'VALORES')], afiches=[('+u', 0.7, 'abc'), ('+v', 0.12, 'valores')],
              bandera=('-u', 0.12), afiches_ventana=[(7, 'dios', -2.55), (5, 'todo_lo_puedo', 2.55)], condensador=False, maceta=None,
              misc=[(85.4, 3.0, 'papelera', 0), (94.6, 20.4, 'armario', 0.0), (96.06, 3.2, 'escoba', -90.0), (65.0, 3.2, 'botellon', 0), (85.6, 7.9, 'mochila', 200.0)])
    return [s1, s2, s3]

def build_all(ctx):
    root = ctx.model('Salones_Planta_Baja')
    build_fachada_reemplazo(ctx, root)
    stats = {}
    for room, st in zip(ROOMS, styles()):
        rm = ctx.model(room['nombre'], root)
        build_cascaron(ctx, rm, room)
        c = layout_room(ctx, rm, room, st)
        stats[room['nombre']] = dict(parts=ctx.count_parts(rm), **c)
    return root, stats

if __name__ == '__main__':
    ctx = Ctx()
    root, stats = build_all(ctx)
    total = ctx.count_parts(root)
    print('STATS', stats, 'TOTAL PARTS', total)
    # overlap check against the original building
    rem = parts_to_remove(SRC)
    ex = existing_parts_local(SRC)
    I = SRC['insts']
    base = baseline_overlap_refs(SRC, rem, ex)
    ov = overlaps(ctx, root, ex, ignore_refs=set(rem) | {c for r in rem for c in I[r]['children']}, facade_ignore=base)
    print('OVERLAPS with existing building:', len(ov))
    for o in ov[:60]: print('  ', o)
    render_ctx(ctx, OUT + '/salones_front.png', idx=root, scale=10, views=('front',))
    render_ctx(ctx, OUT + '/salones_top.png', idx=root, scale=10, views=('top',))
    render_ctx(ctx, OUT + '/salones_side.png', idx=root, scale=10, views=('side',))
    if '--export' in sys.argv:
        n = ctx.export(OUT + '/Salones_Planta_Baja.rbxm')
        print('exported', n, 'bytes')
