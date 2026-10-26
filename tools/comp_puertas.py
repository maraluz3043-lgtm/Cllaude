"""comp_puertas.py — Puertas de los salones nuevos, calado, media ventana y afiches de ventana
(fachada de la planta baja; marco local u,y,v, ver API.md / ROOMS.md).

Convenciones comunes
--------------------
* Muro de fachada v 0.40..1.40 (cara exterior v=0.40, interior v=1.40). Hueco de puerta 4.2 x 8.6
  (y 0.42..9.02). (u,y,v) de build_puerta = centro del hueco en el piso: u = centro, y = cota del piso
  (0.42), v = centro del muro (0.90).
* yaw (grados, opcional, por defecto 0) gira el componente completo sobre el eje vertical con el convenio
  de la API (yaw=90 → el eje local +lu pasa a apuntar hacia +v). Con yaw=0 la cara "exterior" mira a -v
  (corredor / patio).
* Hoja: 3.8 x 8.32 x 0.12 (de y 0.50, sobre el umbral de 0.06, a 8.82 bajo el dintel) con el plano de la hoja en v = 0.70
  (0.20 por dentro de la cara exterior, como en las fotos). La bisagra ('izq' | 'der', vistas desde el
  corredor) está en la cara interior de la jamba; hoja_abierta_grados > 0 gira la hoja hacia el interior
  (+v). Hoja cerrada (0°) → CanCollide=False (el avatar la atraviesa); abierta → colisión normal.
* Las pegatinas (mariposas, luna, estrellas, relieves) son parts delgadas sin colisión pegadas a la cara
  exterior de la hoja y giran con ella. El rótulo va en la cara de la hoja que mira al corredor
  (NormalId = face_toward(0,(0,0,-1)) = 'Back', que es una propiedad LOCAL del part y por eso vale también
  para la hoja girada; usar face_toward con el yaw de la hoja elegiría el canto de la hoja en una puerta
  abierta 75°).
* Todo anclado, nombres en español, sin meshes/texturas/unions.
"""
import math
from build import Ctx, FACE, face_toward, cframe, FONT_GOTHAM, FONT_FREDOKA, FONT_BANGERS, FONT_PERMANENT, FONT_SOURCE
from preview import render_ctx

SRC_PATH = '/root/.claude/uploads/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/159d5810-Donde_pondras_los_salones_faltantes.rbxm'
_SRC = None

# ---------------------------------------------------------------- medidas del hueco / marco / hoja
HUECO_W, HUECO_H = 4.2, 8.6          # hueco en el muro
MURO_T = 1.0                         # espesor del muro (v 0.40..1.40)
JAMBA_W, DINTEL_H = 0.2, 0.2
UMBRAL_H = 0.06
HOJA_W, HOJA_T = 3.8, 0.12
HOJA_Y0 = UMBRAL_H + 0.02            # borde inferior de la hoja sobre el piso (0.08)
HOJA_H = HUECO_H - DINTEL_H - HOJA_Y0   # 8.32
V_HOJA = -0.06                       # plano de la hoja respecto al centro del muro (0.90 - 0.06 = 0.84): pomo y mariposas quedan dentro del rebaje

# ---------------------------------------------------------------- colores
MARCO = (228, 226, 216)
UMBRAL = (166, 164, 158)
BISAGRA = (152, 151, 142)
MORADO = (126, 72, 166)
AZUL = (22, 48, 158)
BLANCO_HOJA = (235, 232, 222)
RELIEVE = (243, 241, 230)
HUNDIDO = (222, 220, 210)
POMO = (190, 188, 182)
OSCURO = (47, 44, 39)
NARANJA_MARCO = (201, 112, 60)
VIDRIO = (233, 235, 237)
AMARILLO = (250, 208, 52)
LUNA = (247, 236, 180)

TEXTO_DEFECTO = {'morada': 'GRADO 5°', 'azul': 'CUARTO', 'blanca_6C': '6C'}


def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del componente → coordenadas (u,y,v) del edificio, girado yaw grados."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def _src():
    global _SRC
    if _SRC is None:
        from rbxm import read_rbxm
        _SRC = read_rbxm(SRC_PATH)
    return _SRC


# ================================================================ PUERTA
def build_puerta(ctx, parent, u, y, v, variante, hoja_abierta_grados=None, bisagra=None, texto=None, yaw=0):
    """Puerta metálica de salón dentro del hueco 4.2 x 8.6 del muro de fachada.

    (u,y,v) = centro del hueco en el piso (u centro, y = 0.42, v = 0.90 centro del muro).
    variante: 'morada' (foto1, mariposas), 'azul' (foto2, luna y estrellas), 'blanca_6C' (foto3, paneles).
    hoja_abierta_grados: giro de la hoja hacia el interior (+v); None → 0 (morada/azul) o 75 (blanca_6C).
    bisagra: 'izq' | 'der' vistas desde el corredor; None → 'izq' (morada/azul) o 'der' (blanca_6C).
    texto: rótulo de la cara exterior; None → 'GRADO 5°' / 'CUARTO' / '6C'.
    yaw: giro del conjunto (0 = hueco a lo largo de u, exterior hacia -v). ≤ 55 parts por variante
    (morada 29, azul 24, blanca_6C 32). Devuelve el índice del Model.
    """
    if variante not in TEXTO_DEFECTO:
        raise ValueError(f'variante desconocida: {variante}')
    es_6c = variante == 'blanca_6C'
    if hoja_abierta_grados is None:
        hoja_abierta_grados = 75 if es_6c else 0
    if bisagra is None:
        bisagra = 'der' if es_6c else 'izq'
    if texto is None:
        texto = TEXTO_DEFECTO[variante]
    s = 1 if bisagra == 'izq' else -1          # la hoja se extiende hacia +u (izq) o -u (der) desde la bisagra
    yaw_h = s * hoja_abierta_grados            # giro de la hoja sobre su bisagra (positivo = hacia +v)
    abierta = abs(hoja_abierta_grados) > 0.5
    nombre = {'morada': 'Puerta_Morada', 'azul': 'Puerta_Azul', 'blanca_6C': 'Puerta_Blanca_6C'}[variante]
    m = ctx.model(nombre, parent=parent)

    def loc(lu, ly, lv):                       # coordenadas locales de la puerta → edificio
        return place(u, y, v, yaw, lu, ly, lv)

    # ---------------- marco (rellena todo el espesor del muro) + umbral
    for sg, lado in ((-1, 'Izq'), (1, 'Der')):
        ctx.box(f'Jamba_{lado}', loc(sg * (HUECO_W / 2 - JAMBA_W / 2), HUECO_H / 2, 0), (JAMBA_W, HUECO_H, MURO_T),
                yaw=yaw, color=MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Dintel', loc(0, HUECO_H - DINTEL_H / 2, 0), (HUECO_W - 2 * JAMBA_W, DINTEL_H, MURO_T),
            yaw=yaw, color=MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Umbral_Cemento', loc(0, UMBRAL_H / 2, 0), (HUECO_W - 2 * JAMBA_W, UMBRAL_H, MURO_T),
            yaw=yaw, color=UMBRAL, material='Concrete', parent=m)

    # ---------------- hoja (coordenadas de hoja: hu desde la bisagra hacia el borde libre, hv: -=exterior)
    lu_h, lv_h = -s * (HUECO_W / 2 - JAMBA_W), V_HOJA
    yaw_t = yaw + yaw_h                        # yaw total de las parts de la hoja

    def hoja(hu, hy, hv):
        lu, ly, lv = place(lu_h, 0, lv_h, yaw_h, hu, hy, hv)
        return loc(lu, ly, lv)

    def gui_ext(hu, hy):                       # (hu,hy) de hoja → (x,y) en escala de la cara exterior
        xl = hu - s * HOJA_W / 2               # x local del part (-1.9..1.9)
        return (xl + HOJA_W / 2) / HOJA_W, (HOJA_Y0 + HOJA_H - hy) / HOJA_H

    color_hoja = {'morada': MORADO, 'azul': AZUL, 'blanca_6C': BLANCO_HOJA}[variante]
    nombre_hoja = {'morada': 'Hoja_Morada', 'azul': 'Hoja_Azul', 'blanca_6C': 'Hoja_Blanca'}[variante]
    h = ctx.box(nombre_hoja, hoja(s * HOJA_W / 2, HOJA_Y0 + HOJA_H / 2, 0), (HOJA_W, HOJA_H, HOJA_T),
                yaw=yaw_t, color=color_hoja, material='SmoothPlastic', parent=m, cancollide=abierta)
    CARA_EXT = face_toward(0, (0, 0, -1))      # cara local 'Back' = la que mira al corredor con la hoja cerrada
    CARA_INT = face_toward(0, (0, 0, 1))
    g_ext = ctx.surface_gui(h, CARA_EXT, pixels_per_stud=60, name='Gui_Exterior')
    peg = dict(cancollide=False, castshadow=False, parent=m)   # pegatinas: sin colisión ni sombra

    # bisagras (3 cilindros verticales sobre el eje de giro, pegados a la jamba)
    for k, hy in enumerate((1.4, HOJA_Y0 + HOJA_H / 2, 7.9)):
        ctx.cylinder(f'Bisagra_{k + 1}', loc(lu_h, hy, lv_h), 0.5, 0.14, axis='y', yaw=yaw,
                     color=BISAGRA, material='Metal', parent=m, castshadow=False)

    hv_ext = -HOJA_T / 2                       # cara exterior de la hoja (coordenada hv)
    hv_int = HOJA_T / 2
    if variante in ('morada', 'azul'):
        # ---- pomo redondo (exterior + interior) con eje que atraviesa la hoja
        hu_p, hy_p = s * (HOJA_W - 0.42), 3.95
        ctx.cylinder('Eje_Pomo', hoja(hu_p, hy_p, 0), 0.42, 0.09, axis='v', yaw=yaw_t,
                     color=POMO, material='Metal', parent=m, cancollide=abierta, castshadow=False)
        ctx.ball('Pomo_Exterior', hoja(hu_p, hy_p, hv_ext - 0.13), 0.28, yaw=yaw_t,
                 color=POMO, material='Metal', parent=m, cancollide=abierta, castshadow=False)
        ctx.ball('Pomo_Interior', hoja(hu_p, hy_p, hv_int + 0.13), 0.28, yaw=yaw_t,
                 color=POMO, material='Metal', parent=m, cancollide=abierta, castshadow=False)
        # bocallave (0 parts) bajo el pomo
        xs, ys = gui_ext(hu_p, hy_p - 0.45)
        ctx.frame(g_ext, pos=(xs - 0.012, 0, ys - 0.008, 0), size=(0.024, 0, 0.016, 0), color=OSCURO, name='Bocallave')

    if variante == 'morada':
        # ---- rótulo (fondo claro redondeado + letras moradas) en la parte superior
        ctx.frame(g_ext, pos=(0.16, 0, 0.055, 0), size=(0.68, 0, 0.105, 0), color=(244, 238, 228), corner=(0.3, 0), name='Rotulo_Fondo')
        ctx.text(g_ext, texto, pos=(0.19, 0, 0.065, 0), size=(0.62, 0, 0.085, 0), color=(104, 36, 150),
                 font=FONT_FREDOKA, xalign=2, yalign=1, name='Rotulo_Texto')
        # ---- mariposas 3D: 2 alas (cilindros elípticos delgados) despegadas de la hoja + cuerpo (Frame)
        mariposas = [  # (fracción del ancho desde la bisagra, fracción de la altura, color, escala)
            (0.14, 0.80, (242, 122, 32), 1.05), (0.80, 0.76, (250, 216, 64), 1.0), (0.50, 0.70, (246, 246, 240), 0.95),
            (0.15, 0.60, (204, 154, 232), 0.9), (0.86, 0.57, (242, 134, 184), 0.85), (0.46, 0.50, (246, 246, 240), 0.7),
            (0.88, 0.26, (242, 122, 32), 0.95), (0.44, 0.13, (250, 216, 64), 1.0), (0.12, 0.37, (204, 154, 232), 0.75),
        ]
        for k, (fx, fy, col, esc) in enumerate(mariposas):
            hu_b, hy_b = s * (0.35 + fx * (HOJA_W - 0.7)), HOJA_Y0 + fy * HOJA_H
            alto, ancho, a, tilt = 0.62 * esc, 0.44 * esc, 32.0, 24.0     # ala: alto, ancho, despegue, inclinación
            for sa, lado in ((-1, 'Izq'), (1, 'Der')):
                hu_a = hu_b + sa * (ancho / 2) * math.cos(math.radians(a)) + sa * 0.02
                hv_a = hv_ext - (ancho / 2) * math.sin(math.radians(a)) - 0.005
                ctx.cylinder(f'Mariposa_{k + 1}_Ala_{lado}', hoja(hu_a, hy_b, hv_a), 0.03, alto, diameter2=ancho,
                             axis='v', yaw=yaw_t - sa * a, pitch=-sa * tilt, color=col, material='SmoothPlastic', **peg)
            xs, ys = gui_ext(hu_b, hy_b)
            ctx.frame(g_ext, pos=(xs - 0.009, 0, ys - 0.026, 0), size=(0.018, 0, 0.052, 0), color=(40, 30, 40),
                      corner=(1.0, 0), name=f'Mariposa_{k + 1}_Cuerpo')
            ctx.frame(g_ext, pos=(xs - 0.004, 0, ys - 0.048, 0), size=(0.008, 0, 0.024, 0), color=(40, 30, 40),
                      rotation=-25 * s, name=f'Mariposa_{k + 1}_Antena')

    elif variante == 'azul':
        # ---- rótulo: banda blanca con letras amarillas/borde azul oscuro
        ctx.frame(g_ext, pos=(0.14, 0, 0.055, 0), size=(0.72, 0, 0.08, 0), color=(242, 242, 240), name='Rotulo_Fondo')
        ctx.text(g_ext, texto, pos=(0.16, 0, 0.06, 0), size=(0.68, 0, 0.07, 0), color=(250, 214, 70),
                 font=FONT_FREDOKA, stroke=(18, 36, 120), xalign=2, yalign=1, name='Rotulo_Texto')
        # ---- luna creciente: disco amarillo + disco "recorte" del color de la hoja delante (2 parts)
        hu_l, hy_l = s * (0.46 * HOJA_W), HOJA_Y0 + 0.62 * HOJA_H
        ctx.cylinder('Luna_Disco', hoja(hu_l, hy_l, hv_ext - 0.02), 0.04, 1.18, axis='v', yaw=yaw_t,
                     color=LUNA, material='SmoothPlastic', **peg)
        ctx.cylinder('Luna_Recorte', hoja(hu_l + s * 0.36, hy_l + 0.12, hv_ext - 0.065), 0.04, 0.92, axis='v', yaw=yaw_t,
                     color=AZUL, material='SmoothPlastic', **peg)
        # ---- estrellas: 2 cuadrados delgados girados 45° (estrella de 8 puntas), columna a la izquierda + 1 suelta
        estrellas = [(0.19, 0.81, 0.36), (0.19, 0.745, 0.34), (0.19, 0.68, 0.36), (0.19, 0.615, 0.34),
                     (0.21, 0.55, 0.38), (0.72, 0.77, 0.30)]
        for k, (fx, fy, lado) in enumerate(estrellas):
            hu_e, hy_e = s * (fx * HOJA_W), HOJA_Y0 + fy * HOJA_H
            for roll, suf in ((0.0, 'A'), (45.0, 'B')):
                ctx.box(f'Estrella_{k + 1}_{suf}', hoja(hu_e, hy_e, hv_ext - 0.015), (lado, lado, 0.03),
                        yaw=yaw_t, roll=roll, color=AMARILLO, material='SmoothPlastic', **peg)

    else:  # blanca_6C
        # ---- 21 paneles cuadrados en relieve (3 columnas x 7 filas) en la cara exterior, centro hundido (Frame)
        pu, ph = HOJA_W / 3, HOJA_H / 7
        lado = 0.9
        for c in range(3):
            for r in range(7):
                hu_r, hy_r = s * (pu * (c + 0.5)), HOJA_Y0 + ph * (r + 0.5)
                p = ctx.box(f'Panel_Relieve_{r + 1}_{c + 1}', hoja(hu_r, hy_r, hv_ext - 0.015), (lado, lado, 0.03),
                            yaw=yaw_t, color=RELIEVE, material='SmoothPlastic', **peg)
                gp = ctx.surface_gui(p, CARA_EXT, pixels_per_stud=40, name='Gui_Panel')
                ctx.frame(gp, pos=(0.22, 0, 0.22, 0), size=(0.56, 0, 0.56, 0), color=HUNDIDO, name='Centro_Hundido')
                ctx.frame(gp, pos=(0.34, 0, 0.34, 0), size=(0.32, 0, 0.32, 0), color=RELIEVE, rotation=45, name='Rombo')
        # cara interior: mismo estampado dibujado con Frames (0 parts)
        g_int = ctx.surface_gui(h, CARA_INT, pixels_per_stud=40, name='Gui_Interior')
        for c in range(3):
            for r in range(7):
                xs, ys = (pu * (c + 0.5) - lado / 2) / HOJA_W, (ph * (r + 0.5) - lado / 2) / HOJA_H
                ctx.frame(g_int, pos=(xs, 0, ys, 0), size=(lado / HOJA_W, 0, lado / HOJA_H, 0), color=RELIEVE, name=f'Panel_Int_{r + 1}_{c + 1}')
                ctx.frame(g_int, pos=(xs + 0.22 * lado / HOJA_W, 0, ys + 0.22 * lado / HOJA_H, 0),
                          size=(0.56 * lado / HOJA_W, 0, 0.56 * lado / HOJA_H, 0), color=HUNDIDO, name=f'Hundido_Int_{r + 1}_{c + 1}')
        # ---- rótulo 'grado' + texto con marcador negro, encima de los paneles (SurfaceGui con ZOffset > relieve)
        g_rot = ctx.surface_gui(h, CARA_EXT, pixels_per_stud=60, name='Gui_Rotulo')
        ctx.insts[g_rot]['props']['ZOffset'] = (0x04, 0.06)
        ctx.text(g_rot, 'grado', pos=(0.22, 0, 0.035, 0), size=(0.56, 0, 0.055, 0), color=(132, 28, 40),
                 font=FONT_PERMANENT, stroke=(40, 20, 24), xalign=2, yalign=1, name='Rotulo_Grado')
        ctx.text(g_rot, texto, pos=(0.18, 0, 0.09, 0), size=(0.64, 0, 0.10, 0), color=(28, 28, 30),
                 font=FONT_PERMANENT, xalign=2, yalign=1, name='Rotulo_Texto')
        # ---- cerradura oscura + manija de palanca (exterior e interior)
        hu_c, hy_c = s * (HOJA_W - 0.40), 3.95
        ctx.box('Cerradura', hoja(hu_c, hy_c, hv_ext - 0.025), (0.24, 0.72, 0.05), yaw=yaw_t,
                color=(96, 85, 61), material='Metal', parent=m, cancollide=False, castshadow=False)
        ctx.cylinder('Eje_Manija', hoja(hu_c - s * 0.26, hy_c + 0.1, 0), 0.40, 0.07, axis='v', yaw=yaw_t,
                     color=OSCURO, material='Metal', parent=m, cancollide=abierta, castshadow=False)
        for hv_m, lado_m in ((hv_ext - 0.12, 'Exterior'), (hv_int + 0.10, 'Interior')):
            ctx.cylinder(f'Manija_{lado_m}', hoja(hu_c - s * 0.26, hy_c + 0.1, hv_m), 0.5, 0.09, axis='u', yaw=yaw_t,
                         color=OSCURO, material='Metal', parent=m, cancollide=abierta, castshadow=False)
    return m


# ================================================================ CALADO (clon de la 'Rejilla' original)
def build_calado(ctx, parent, u, y, v, ancho=4.4, alto=4.2, yaw=0):
    """Panel de bloques calados igual a la 'Rejilla' existente (clon con su SurfaceGui de 16 puntos oscuros).

    (u,y,v) = centro del panel (0.12 de espesor). Los puntos miran hacia -v (corredor) con yaw=0.
    1 part. Devuelve el índice del Model que contiene la part 'Calado'.
    """
    src = _src()
    I = src['insts']
    refs = [r for r, i in I.items() if i['props'].get('Name', (0, b''))[1] == b'Rejilla' and i['cls'] == 'Part']
    m = ctx.model('Calado', parent=parent)
    idx = ctx.clone(src, refs[0], parent=m, rename='Calado')
    p = ctx.insts[idx]['props']
    p['size'] = (0x0E, (float(ancho), float(alto), 0.12))
    p['CFrame'] = (0x10, cframe(u, y, v, yaw))          # sin la rotación yaw=180 del original
    p['PivotOffset'] = (0x10, ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)))
    for c in ctx.descendants(idx):
        if ctx.insts[c]['cls'] == 'SurfaceGui':
            ctx.insts[c]['props']['Face'] = (0x12, face_toward(0, (0, 0, -1)))   # cara local que mira a -v
    return m


# ================================================================ MEDIA VENTANA (2 paños)
def build_media_ventana(ctx, parent, u, y, v, ancho=4.4, alto=5.7, yaw=0):
    """Ventana de marco naranja (201,112,60) de 2 paños con parteluz y vidrio (233,235,237), como las
    ventanas existentes (marcos 0.45 x 0.30, parteluz 0.35 x 0.22, vidrio 0.10 al fondo, v +0.05..+0.15).

    (u,y,v) = centro de la ventana (v = 0.25 → marcos en v 0.10..0.40). 6 parts. Devuelve el Model.
    """
    m = ctx.model('Media_Ventana', parent=parent)
    MW, MD, PW, PD, VD = 0.45, 0.30, 0.35, 0.22, 0.10

    def loc(lu, ly, lv):
        return place(u, y, v, yaw, lu, ly, lv)
    for sg, lado in ((-1, 'Izq'), (1, 'Der')):
        ctx.box(f'Marco_{lado}', loc(sg * (ancho / 2 - MW / 2), 0, 0), (MW, alto, MD), yaw=yaw,
                color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    for sg, lado in ((-1, 'Inf'), (1, 'Sup')):
        ctx.box(f'Marco_{lado}', loc(0, sg * (alto / 2 - MW / 2), 0), (ancho - 2 * MW, MW, MD), yaw=yaw,
                color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Parteluz', loc(0, 0, (MD - PD) / 2), (PW, alto - 2 * MW, PD), yaw=yaw,
            color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Vidrio', loc(0, 0, (MD - VD) / 2), (ancho - 2 * MW, alto - 2 * MW, VD), yaw=yaw,
            color=VIDRIO, material='SmoothPlastic', reflectance=0.05, parent=m)
    return m


# ================================================================ AFICHE pegado por fuera del vidrio
def build_afiche_ventana(ctx, parent, u, y, v, tema='dios', yaw=0):
    """Afiche de 2.0 x 2.6 x 0.03 con diseño en SurfaceGui (texto + Frames) mirando a -v.

    (u,y,v) = centro del afiche (v ≈ 0.28 → pegado al vidrio exterior v=0.30 de las ventanas).
    tema: 'dios' | 'todo_lo_puedo' | 'guitarra'. 1 part. Devuelve el Model.
    """
    temas = {
        'dios': ('Afiche_Hoy_Dios', (248, 240, 236)),
        'todo_lo_puedo': ('Afiche_Todo_Lo_Puedo', (236, 228, 246)),
        'guitarra': ('Afiche_Guitarra', (246, 243, 232)),
    }
    if tema not in temas:
        raise ValueError(f'tema desconocido: {tema}')
    nombre, fondo = temas[tema]
    m = ctx.model(nombre, parent=parent)
    p = ctx.box(nombre, place(u, y, v, yaw, 0, 0, 0), (2.0, 2.6, 0.03), yaw=yaw, color=fondo,
                material='SmoothPlastic', parent=m, cancollide=False, castshadow=False)
    g = ctx.surface_gui(p, face_toward(0, (0, 0, -1)), pixels_per_stud=100)
    if tema == 'dios':
        # borde rojo (marco), cielo rosado, prado verde, flores, texto en 4 renglones
        ctx.frame(g, pos=(0, 0, 0, 0), size=(1, 0, 1, 0), color=(168, 36, 44), name='Borde')
        ctx.frame(g, pos=(0.05, 0, 0.04, 0), size=(0.9, 0, 0.92, 0), color=(250, 242, 238), corner=(0.06, 0), name='Fondo')
        ctx.frame(g, pos=(0.05, 0, 0.62, 0), size=(0.9, 0, 0.34, 0), color=(132, 178, 92), corner=(0.08, 0), name='Prado')
        ctx.frame(g, pos=(0.10, 0, 0.09, 0), size=(0.12, 0, 0.09, 0), color=(238, 160, 178), corner=(1.0, 0), name='Corazon')
        ctx.frame(g, pos=(0.80, 0, 0.08, 0), size=(0.1, 0, 0.075, 0), color=(246, 206, 90), corner=(1.0, 0), name='Sol')
        for k, (fx, col) in enumerate([(0.12, (246, 206, 90)), (0.22, (238, 160, 178)), (0.78, (240, 240, 240)), (0.88, (238, 160, 178))]):
            ctx.frame(g, pos=(fx, 0, 0.76, 0), size=(0.06, 0, 0.045, 0), color=col, corner=(1.0, 0), name=f'Flor_{k + 1}')
            ctx.frame(g, pos=(fx + 0.025, 0, 0.80, 0), size=(0.012, 0, 0.14, 0), color=(70, 120, 60), name=f'Tallo_{k + 1}')
        ctx.text(g, 'Hoy', pos=(0.3, 0, 0.07, 0), size=(0.4, 0, 0.1, 0), color=(60, 58, 62), font=FONT_FREDOKA, xalign=2, yalign=1, name='T1')
        ctx.text(g, 'Dios', pos=(0.15, 0, 0.17, 0), size=(0.7, 0, 0.2, 0), color=(232, 120, 150), font=FONT_BANGERS, xalign=2, yalign=1, name='T2')
        ctx.text(g, 'te dice:', pos=(0.3, 0, 0.37, 0), size=(0.4, 0, 0.08, 0), color=(60, 58, 62), font=FONT_FREDOKA, xalign=2, yalign=1, name='T3')
        ctx.text(g, 'Todo va a estar\nBIEN,', pos=(0.1, 0, 0.47, 0), size=(0.8, 0, 0.18, 0), color=(50, 48, 60), font=FONT_FREDOKA, xalign=2, yalign=1, name='T4')
        ctx.text(g, 'confía en mí', pos=(0.08, 0, 0.66, 0), size=(0.84, 0, 0.11, 0), color=(255, 255, 255), font=FONT_FREDOKA, stroke=(60, 90, 50), xalign=2, yalign=1, name='T5')
    elif tema == 'todo_lo_puedo':
        ctx.frame(g, pos=(0, 0, 0, 0), size=(1, 0, 1, 0), color=(168, 36, 44), name='Borde')
        ctx.frame(g, pos=(0.05, 0, 0.04, 0), size=(0.9, 0, 0.92, 0), color=(240, 232, 248), corner=(0.06, 0), name='Fondo')
        ctx.frame(g, pos=(0.12, 0, 0.60, 0), size=(0.76, 0, 0.3, 0), color=(120, 60, 150), corner=(0.1, 0), name='Franja')
        for k, (fx, fy) in enumerate([(0.1, 0.08), (0.84, 0.1), (0.08, 0.5), (0.86, 0.48)]):
            ctx.frame(g, pos=(fx, 0, fy, 0), size=(0.07, 0, 0.055, 0), color=(246, 206, 90), corner=(1.0, 0), name=f'Flor_{k + 1}')
        ctx.text(g, 'Ni antes ni después...', pos=(0.08, 0, 0.08, 0), size=(0.84, 0, 0.08, 0), color=(70, 50, 90), font=FONT_FREDOKA, xalign=2, yalign=1, name='T1')
        ctx.text(g, 'TODO', pos=(0.1, 0, 0.17, 0), size=(0.8, 0, 0.22, 0), color=(120, 60, 150), font=FONT_BANGERS, stroke=(60, 20, 80), xalign=2, yalign=1, name='T2')
        ctx.text(g, 'en el tiempo de', pos=(0.1, 0, 0.41, 0), size=(0.8, 0, 0.1, 0), color=(70, 50, 90), font=FONT_FREDOKA, xalign=2, yalign=1, name='T3')
        ctx.text(g, 'DIOS', pos=(0.15, 0, 0.63, 0), size=(0.7, 0, 0.24, 0), color=(255, 245, 200), font=FONT_BANGERS, stroke=(60, 20, 80), xalign=2, yalign=1, name='T4')
        ctx.text(g, 'Eclesiastés 3:11', pos=(0.3, 0, 0.9, 0), size=(0.4, 0, 0.05, 0), color=(100, 80, 120), font=FONT_SOURCE, xalign=2, yalign=1, name='T5')
    else:  # guitarra
        ctx.frame(g, pos=(0, 0, 0, 0), size=(1, 0, 1, 0), color=(120, 90, 60), name='Borde')
        ctx.frame(g, pos=(0.04, 0, 0.03, 0), size=(0.92, 0, 0.94, 0), color=(248, 244, 232), corner=(0.04, 0), name='Fondo')
        # guitarra dibujada con Frames: caja (dos óvalos), boca, mástil, clavijero, cuerdas
        ctx.frame(g, pos=(0.08, 0, 0.56, 0), size=(0.34, 0, 0.30, 0), color=(150, 96, 44), corner=(1.0, 0), name='Caja_Inferior')
        ctx.frame(g, pos=(0.11, 0, 0.40, 0), size=(0.28, 0, 0.24, 0), color=(150, 96, 44), corner=(1.0, 0), name='Caja_Superior')
        ctx.frame(g, pos=(0.195, 0, 0.56, 0), size=(0.11, 0, 0.085, 0), color=(40, 28, 20), corner=(1.0, 0), name='Boca')
        ctx.frame(g, pos=(0.22, 0, 0.10, 0), size=(0.06, 0, 0.34, 0), color=(70, 48, 30), name='Mastil')
        ctx.frame(g, pos=(0.20, 0, 0.05, 0), size=(0.10, 0, 0.08, 0), color=(40, 28, 20), corner=(0.3, 0), name='Clavijero')
        for k in range(3):
            ctx.frame(g, pos=(0.235 + 0.012 * k, 0, 0.12, 0), size=(0.004, 0, 0.62, 0), color=(230, 220, 200), name=f'Cuerda_{k + 1}')
        ctx.frame(g, pos=(0.17, 0, 0.72, 0), size=(0.16, 0, 0.03, 0), color=(40, 28, 20), name='Puente')
        ctx.text(g, 'Cuando entro\nen tu presencia', pos=(0.42, 0, 0.08, 0), size=(0.52, 0, 0.26, 0), color=(60, 50, 40), font=FONT_PERMANENT, xalign=2, yalign=1, name='T1')
        ctx.text(g, 'tus atrios se\nllenan de\nalabanza', pos=(0.44, 0, 0.36, 0), size=(0.5, 0, 0.34, 0), color=(60, 50, 40), font=FONT_PERMANENT, xalign=2, yalign=1, name='T2')
        ctx.text(g, '¡HAY PODER!', pos=(0.42, 0, 0.74, 0), size=(0.54, 0, 0.14, 0), color=(150, 40, 40), font=FONT_BANGERS, xalign=2, yalign=1, name='T3')
    return m


# ================================================================ selftest
def _info(ctx, nombre, idx):
    n = ctx.count_parts(idx)
    lo, hi = ctx.bbox(idx)
    print(f'{nombre:22s} parts={n:2d} bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) '
          f'ext=({hi[0] - lo[0]:.2f},{hi[1] - lo[1]:.2f},{hi[2] - lo[2]:.2f})')
    return n, lo, hi


def selftest():
    import numpy as np
    from build import B, world_to_local
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Puertas')
    out = []
    YP, VM = 0.42, 0.90                       # piso y centro del muro
    # tres puertas en fila (huecos separados 6 studs) + calado / media ventana / afiches a la derecha
    casos = [
        ('puerta_morada', 55, lambda: build_puerta(ctx, raiz, 0.0, YP, VM, 'morada')),
        ('puerta_azul', 55, lambda: build_puerta(ctx, raiz, 10.2, YP, VM, 'azul')),
        ('puerta_blanca_6C', 55, lambda: build_puerta(ctx, raiz, 20.4, YP, VM, 'blanca_6C')),
        ('calado', 2, lambda: build_calado(ctx, raiz, 27.8, 3.6, 0.25, ancho=4.4, alto=4.2)),
        ('media_ventana', 7, lambda: build_media_ventana(ctx, raiz, 27.8, 6.2 + 5.7 / 2, 0.25, ancho=4.4, alto=5.7)),
        ('afiche_dios', 1, lambda: build_afiche_ventana(ctx, raiz, 27.8, 9.0, 0.28, tema='dios')),
        ('afiche_todo_lo_puedo', 1, lambda: build_afiche_ventana(ctx, raiz, 33.0, 9.0, 0.28, tema='todo_lo_puedo')),
        ('afiche_guitarra', 1, lambda: build_afiche_ventana(ctx, raiz, 35.5, 9.0, 0.28, tema='guitarra')),
        # instancias giradas yaw=90 (el hueco queda a lo largo de v; exterior hacia +u)
        ('puerta_morada_yaw90', 55, lambda: build_puerta(ctx, raiz, 42.0, YP, 6.0, 'morada', hoja_abierta_grados=40, yaw=90)),
        ('calado_yaw90', 2, lambda: build_calado(ctx, raiz, 42.65, 3.6, 13.0, ancho=4.4, alto=4.2, yaw=90)),
        ('media_ventana_yaw90', 7, lambda: build_media_ventana(ctx, raiz, 42.65, 6.2 + 5.7 / 2, 13.0, ancho=4.4, alto=5.7, yaw=90)),
        ('afiche_yaw90', 1, lambda: build_afiche_ventana(ctx, raiz, 42.62, 9.0, 13.0, tema='guitarra', yaw=90)),
    ]
    for nombre, lim, fn in casos:
        idx = fn()
        n, lo, hi = _info(ctx, nombre, idx)
        assert n <= lim, (nombre, n, lim)
        out.append((nombre, idx, n, lo, hi))
        if not nombre.endswith('yaw90'):
            render_ctx(ctx, f'../out/comp_puertas_{nombre}.png', idx=idx, scale=60)
    # comprobación de orientación: normal de la cara del rótulo de cada hoja (debe tener componente -v o -u para yaw=90)
    for i, inst in enumerate(ctx.insts):
        if inst['cls'] == 'SurfaceGui' and inst['props']['Name'][1] in (b'Gui_Exterior', b'Gui_Rotulo'):
            par = ctx.insts[inst['parent']]
            R = np.array(par['props']['CFrame'][1][1]).reshape(3, 3)
            face = inst['props']['Face'][1]
            nrm = {0: R[:, 0], 3: -R[:, 0], 1: R[:, 1], 4: -R[:, 1], 2: R[:, 2], 5: -R[:, 2]}[face]
            u_, _, v_ = world_to_local(nrm + np.array([36.71701431274414, 0.0, -1485.35107421875]))
            print(f'  {par["props"]["Name"][1].decode():14s} {inst["props"]["Name"][1].decode():13s} normal local (u,v)=({u_:+.2f},{v_:+.2f})')
    render_ctx(ctx, '../out/comp_puertas_preview.png', idx=raiz, scale=22)
    ctx.export('../out/comp_puertas_selftest.rbxm')
    return out


if __name__ == '__main__':
    selftest()
