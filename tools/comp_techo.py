"""comp_techo.py — Cielo raso, luminarias, ventiladores, aire acondicionado y accesorios eléctricos
para los salones nuevos (marco local u,y,v; ver API.md).

Convenciones comunes
--------------------
* Todo anclado; nombres en español; sin meshes/texturas/decals/unions. Rejillas, led, tapas y seams se
  dibujan con SurfaceGui + Frame/UIStroke/TextLabel (0 parts).
* yaw (grados) gira el objeto sobre el eje vertical con el convenio de la API: yaw=90 → el eje local +u
  pasa a apuntar hacia +v; un objeto de pared con yaw=0 tiene la pared hacia +v y sobresale hacia -v.
    yaw = 0   → pared hacia +v (muro del fondo, v = 21.4)      yaw = 180 → pared hacia -v (cara interior de la fachada)
    yaw = 90  → pared hacia -u (muro izquierdo)                yaw = -90 → pared hacia +u (muro derecho)

build_cielo_raso(ctx, parent, u0, u1, v0, v1, y_top): tablillas PVC blancas de 2.0 a lo largo de u
    (cada tablilla = part de 2.0 x 0.12 x (v1-v0)), cara inferior en y_top-0.12 y tope en y_top; moldura
    perimetral de 4 parts (0.25 x 0.25) con tope en y_top (sobresale 0.13 bajo las tablillas, como una cornisa).
build_luminaria(ctx, parent, u, y, v, yaw=0): y = cota de la cara INFERIOR del cielo raso; la carcasa cuelga
    debajo (y-0.25..y) y los 2 tubos Neon quedan bajo la carcasa. Largo 4.0 a lo largo de u con yaw=0.
build_ventilador_techo(ctx, parent, u, y, v): y = cota del cielo raso (cara inferior); campana pegada al techo.
build_ventilador_pared(ctx, parent, u, y, v, yaw=0, inclinacion=15): (u,y,v) = punto de anclaje de la placa en
    la pared; con yaw=0 la pared está hacia +v y el ventilador sopla hacia -v, inclinado `inclinacion` grados
    hacia abajo.
build_split_interior / build_condensador_exterior: (u,y,v) = centro de la cara trasera pegada a la pared;
    yaw=0 → pared hacia +v.
build_interruptor / build_toma: (u,y,v) = centro de la placa pegada a la pared (yaw=0 → pared hacia +v).
build_canaleta(ctx, parent, u0, u1, y, v, yaw=0): canaleta horizontal que parte de (u0, y, v) y se extiende
    (u1-u0) a lo largo del eje local +u girado yaw (yaw=0: de u0 a u1 pegada a una pared hacia +v).
"""
import math
from build import Ctx, FACE, face_toward, FONT_GOTHAM, FONT_SOURCE
from preview import render_ctx

# ---------------------------------------------------------------- colores
BLANCO_PVC_A = (248, 248, 245)
BLANCO_PVC_B = (238, 238, 234)
BLANCO_MOLDURA = (250, 250, 248)
BLANCO_CARCASA = (242, 242, 238)
BLANCO_SPLIT = (238, 238, 232)
BLANCO_PLACA = (245, 245, 242)
BLANCO_CANALETA = (240, 240, 238)
TUBO_NEON = (255, 250, 235)
CREMA_VENT = (220, 219, 204)        # VentiladorBlanco / Ventilador_Pared
GRIS_ASPA = (150, 152, 150)
METAL_CLARO = (171, 175, 169)
JAULA = (200, 202, 187)
GRIS_ANILLO = (150, 152, 148)
GRIS_OSCURO = (47, 44, 39)
NEGRO_SALIDA = (24, 27, 24)
LAMA = (200, 200, 194)
CAJA_AA = (228, 228, 224)
MENSULA = (92, 94, 97)
TUBERIA = (62, 62, 64)
VERDE_LED = (120, 200, 110)


def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del componente → coordenadas (u,y,v) del edificio, girado yaw grados."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def _dir(yaw, du, dy, dv):
    """Dirección local del componente → dirección en el marco del edificio (girada yaw grados)."""
    t = math.radians(yaw)
    return (du * math.cos(t) - dv * math.sin(t), dy, du * math.sin(t) + dv * math.cos(t))


def _caja(ctx, parent, nombre, u, y, v, yaw, lc, size, **kw):
    return ctx.box(nombre, place(u, y, v, yaw, *lc), size, yaw=yaw + kw.pop('yaw_local', 0.0), parent=parent, **kw)


def _tubo(ctx, parent, nombre, u, y, v, yaw, a, b, diam, **kw):
    """Cilindro entre dos puntos locales a y b (riostras, tubería inclinada...)."""
    ax, ay, az = a
    bx, by, bz = b
    L = math.dist(a, b)
    d = ((bx - ax) / L, (by - ay) / L, (bz - az) / L)
    psi = math.degrees(math.atan2(d[2], d[0]))
    r = math.degrees(math.asin(max(-1.0, min(1.0, d[1]))))
    c = place(u, y, v, yaw, (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2)
    return ctx.part(nombre, c, (L, diam, diam), yaw=yaw + psi, roll=r, shape='Cylinder', parent=parent, **kw)


def _ui_stroke(ctx, frame_idx, color, thickness=2.0, transparency=0.0):
    """Borde (UIStroke) sobre un Frame: sirve para dibujar anillos huecos (0 parts)."""
    return ctx._add('UIStroke', {'Name': (0x01, b'UIStroke'),
                                 'Color': (0x0C, (color[0] / 255.0, color[1] / 255.0, color[2] / 255.0)),
                                 'Thickness': (0x04, float(thickness)), 'Transparency': (0x04, float(transparency)),
                                 'ApplyStrokeMode': (0x12, 0), 'LineJoinMode': (0x12, 0), 'Enabled': (0x02, True)},
                    frame_idx)


def _circulo_gui(ctx, gui, diam, color, aspect=1.0, cx=0.5, cy=0.5, relleno=True, grosor=2.0, name='Circulo'):
    """Círculo (relleno o sólo borde) de diámetro `diam` = fracción de la ALTURA de la cara; `aspect` = ancho/alto
    de la cara para que salga redondo en caras no cuadradas."""
    sx = diam / aspect
    f = ctx.frame(gui, pos=(cx - sx / 2, 0, cy - diam / 2, 0), size=(sx, 0, diam, 0), color=color,
                  transparency=0.0 if relleno else 1.0, corner=(1.0, 0), name=name)
    if not relleno:
        _ui_stroke(ctx, f, color, grosor)
    return f


def _rejilla_circular(ctx, part_idx, face, aspect=1.0, diam=0.96, n_radios=6, anillos=(0.96, 0.78, 0.60, 0.42),
                      tapa=0.22, color=(205, 207, 205), fondo=None, color_tapa=None, ppstud=200.0, grosor=3.0):
    """Rejilla circular de ventilador (fondo opcional + radios + anillos concéntricos + tapa central) dibujada con
    SurfaceGui (0 parts). Diámetros en fracción de la altura de la cara; aspect = ancho/alto de la cara."""
    g = ctx.surface_gui(part_idx, face, pixels_per_stud=ppstud, name='Rejilla')
    if fondo is not None:
        _circulo_gui(ctx, g, diam, fondo, aspect, name='Fondo')
    for k in range(n_radios):
        ctx.frame(g, pos=(0.5 - diam / aspect / 2, 0, 0.5 - 0.006, 0), size=(diam / aspect, 0, 0.012, 0), color=color,
                  rotation=180.0 * k / n_radios, name=f'Radio_{k + 1}')
    for d in anillos:
        _circulo_gui(ctx, g, d, color, aspect, relleno=False, grosor=grosor, name='Anillo')
    if tapa:
        _circulo_gui(ctx, g, tapa, color_tapa or color, aspect, name='Tapa_Central')
    return g


# ================================================================ 1) cielo raso
def build_cielo_raso(ctx, parent, u0, u1, v0, v1, y_top, ancho_tablilla=2.0):
    """Cielo raso de tablillas PVC (a lo largo de v, 2.0 de ancho en u) + moldura perimetral. Parts = ceil(L/2) + 4."""
    m = ctx.model('Cielo_Raso', parent=parent)
    esp = 0.12
    L, P = u1 - u0, v1 - v0
    uc, vc = (u0 + u1) / 2, (v0 + v1) / 2
    n = int(math.ceil(L / ancho_tablilla - 1e-6))
    u = u0
    for i in range(n):
        w = min(ancho_tablilla, u1 - u)
        ctx.box(f'Tablilla_{i + 1:02d}', (u + w / 2, y_top - esp / 2, vc), (w, esp, P),
                color=BLANCO_PVC_A if i % 2 == 0 else BLANCO_PVC_B, material='SmoothPlastic', parent=m)
        u += w
    mo = 0.25
    yc = y_top - mo / 2
    kw = dict(color=BLANCO_MOLDURA, material='SmoothPlastic', parent=m)
    ctx.box('Moldura_Frente', (uc, yc, v0 + mo / 2), (L, mo, mo), **kw)
    ctx.box('Moldura_Fondo', (uc, yc, v1 - mo / 2), (L, mo, mo), **kw)
    ctx.box('Moldura_Izquierda', (u0 + mo / 2, yc, vc), (mo, mo, P - 2 * mo), **kw)
    ctx.box('Moldura_Derecha', (u1 - mo / 2, yc, vc), (mo, mo, P - 2 * mo), **kw)
    return m


# ================================================================ 2) luminaria fluorescente
def build_luminaria(ctx, parent, u, y, v, yaw=0, largo=4.0, encendida=True):
    """Luminaria de superficie 4.0 x 0.25 x 1.0 colgada bajo el cielo raso (y = cara inferior del cielo raso). 3 parts."""
    m = ctx.model('Luminaria', parent=parent)
    h = 0.25
    carcasa = _caja(ctx, m, 'Carcasa', u, y, v, yaw, (0, -h / 2, 0), (largo, h, 1.0),
                    color=BLANCO_CARCASA, material='SmoothPlastic')
    # reflector: franja central más clara y balastro oscuro dibujados en la cara inferior (0 parts)
    g = ctx.surface_gui(carcasa, FACE['Bottom'], pixels_per_stud=60)
    ctx.frame(g, pos=(0.02, 0, 0.44, 0), size=(0.96, 0, 0.12, 0), color=(226, 226, 222), name='Balastro')
    for k, lv in ((1, -0.26), (2, 0.26)):
        ctx.cylinder(f'Tubo_{k}', place(u, y, v, yaw, 0, -h - 0.03, lv), largo - 0.4, 0.14, axis='u', yaw=yaw,
                     color=TUBO_NEON, material='Neon' if encendida else 'SmoothPlastic', castshadow=False, parent=m)
    if encendida:
        ctx.light(carcasa, 'SurfaceLight', face=FACE['Bottom'], brightness=1.2, range_=18, color=TUBO_NEON, angle=150)
    return m


# ================================================================ 3) ventilador de techo
def build_ventilador_techo(ctx, parent, u, y, v, aspas=3, con_lampara=True, largo_varilla=1.2, angulo=0.0):
    """Ventilador de techo clásico: campana, varilla, motor, brazos + aspas (3-4) y lámpara opcional. ≤ 11 parts.
    y = cota del cielo raso (cara inferior); `angulo` gira el conjunto de aspas."""
    m = ctx.model('Ventilador_Techo', parent=parent)
    ctx.cylinder('Campana', (u, y - 0.11, v), 0.22, 0.9, axis='y', color=CREMA_VENT, material='SmoothPlastic', parent=m)
    L = largo_varilla
    ctx.cylinder('Varilla', (u, y - 0.22 - L / 2, v), L, 0.14, axis='y', color=METAL_CLARO, material='Metal', parent=m)
    y_mot = y - 0.22 - L                       # tope del motor
    hm = 0.55
    ctx.cylinder('Motor', (u, y_mot - hm / 2, v), hm, 1.1, axis='y', color=CREMA_VENT, material='SmoothPlastic', parent=m)
    y_asp = y_mot - hm + 0.06                  # plano de las aspas (apenas dentro de la base del motor)
    largo_aspa, ancho_aspa = 1.9, 0.5
    r_hub = 0.5
    for k in range(aspas):
        ang = angulo + 360.0 * k / aspas
        ctx.box(f'Brazo_Aspa_{k + 1}', place(u, y_asp + 0.03, v, ang, 0.25 + 0.3, 0, 0), (0.6, 0.05, 0.16),
                yaw=ang, color=METAL_CLARO, material='Metal', parent=m)
        ctx.box(f'Aspa_{k + 1}', place(u, y_asp, v, ang, r_hub + largo_aspa / 2, 0, 0), (largo_aspa, 0.03, ancho_aspa),
                yaw=ang, pitch=12, color=GRIS_ASPA, material='SmoothPlastic', parent=m)
    ctx.cylinder('Tapa_Motor', (u, y_mot - hm - 0.06, v), 0.12, 0.72, axis='y', color=CREMA_VENT,
                 material='SmoothPlastic', parent=m)
    if con_lampara:   # bola de vidrio de 0.6 colgando de la tapa (sólo se embute 0.06 en la tapa, no en el motor)
        ctx.ball('Lampara', (u, y_mot - hm - 0.36, v), 0.6, color=(236, 232, 220), material='Glass',
                 transparency=0.25, parent=m)
    return m


# ================================================================ 4) ventilador de pared
def _cabeza(P, incl, a, b, c):
    """Coordenadas de la cabeza del ventilador (a: +u, b: arriba, c: hacia delante por el eje) → locales."""
    i = math.radians(incl)
    return (P[0] + a, P[1] + b * math.cos(i) - c * math.sin(i), P[2] - b * math.sin(i) - c * math.cos(i))


def build_ventilador_pared(ctx, parent, u, y, v, yaw=0, inclinacion=15, diametro=2.2, angulo=0.0):
    """Ventilador de pared: placa, brazo, articulación, motor, cubo, 3 aspas, jaula translúcida + anillo. 10 parts.
    (u,y,v) = anclaje en la pared; yaw=0 → pared hacia +v, sopla hacia -v inclinado `inclinacion`° hacia abajo."""
    m = ctx.model('Ventilador_Pared', parent=parent)
    inc = inclinacion
    _caja(ctx, m, 'Placa_Pared', u, y, v, yaw, (0, 0, -0.04), (0.55, 0.8, 0.08), color=CREMA_VENT, material='SmoothPlastic')
    ctx.cylinder('Brazo', place(u, y, v, yaw, 0, 0, -0.44), 0.72, 0.18, axis='v', yaw=yaw, color=CREMA_VENT,
                 material='SmoothPlastic', parent=m)
    P = (0.0, 0.0, -0.80)
    ctx.ball('Articulacion', place(u, y, v, yaw, *P), 0.34, color=CREMA_VENT, material='SmoothPlastic', parent=m)

    def cil_eje(nombre, c, largo, diam, **kw):      # cilindro cuyo eje es el eje del ventilador (inclinado)
        return ctx.part(nombre, place(u, y, v, yaw, *_cabeza(P, inc, 0, 0, c)), (largo, diam, diam),
                        yaw=yaw + 90, roll=inc, shape='Cylinder', parent=m, **kw)

    cil_eje('Motor', 0.42, 0.70, 0.62, color=CREMA_VENT, material='SmoothPlastic')
    cil_eje('Cubo', 0.90, 0.26, 0.34, color=CREMA_VENT, material='SmoothPlastic')
    r_asp, largo_asp = 0.57, 0.80
    for k in range(3):
        th = angulo + 120.0 * k
        a, b = r_asp * math.cos(math.radians(th)), r_asp * math.sin(math.radians(th))
        ctx.box(f'Aspa_{k + 1}', place(u, y, v, yaw, *_cabeza(P, inc, a, b, 0.95)), (largo_asp, 0.36, 0.05),
                yaw=yaw, pitch=inc, roll=th, color=GRIS_ASPA, material='SmoothPlastic', parent=m)
    # jaula = 1 cilindro translúcido (0.7) para que las aspas se vean; el aro del borde NO es part: se dibuja como
    # anillo hueco (UIStroke) en las rejillas de ambas tapas (0 parts)
    jaula = cil_eje('Jaula', 0.98, 0.72, diametro, color=JAULA, material='SmoothPlastic', transparency=0.7,
                    cancollide=False, castshadow=False)
    fwd = _dir(yaw, 0.0, -math.sin(math.radians(inc)), -math.cos(math.radians(inc)))
    cara_del = face_toward(yaw + 90, fwd, roll=inc)
    cara_tra = face_toward(yaw + 90, tuple(-x for x in fwd), roll=inc)
    g_del = _rejilla_circular(ctx, jaula, cara_del, diam=0.96, n_radios=8, anillos=(0.96, 0.80, 0.63, 0.46, 0.30),
                              tapa=0.2, color=JAULA, color_tapa=CREMA_VENT, grosor=3.0)
    _circulo_gui(ctx, g_del, 0.985, GRIS_ANILLO, relleno=False, grosor=7.0, name='Aro_Borde')
    g_tra = _rejilla_circular(ctx, jaula, cara_tra, diam=0.96, n_radios=6, anillos=(0.96, 0.75, 0.50), tapa=0.0,
                              color=JAULA, grosor=3.0)
    _circulo_gui(ctx, g_tra, 0.985, GRIS_ANILLO, relleno=False, grosor=7.0, name='Aro_Borde')
    return m


# ================================================================ 5) split interior
def build_split_interior(ctx, parent, u, y, v, yaw=0, encendido=True):
    """Unidad interior split 5.1 x 1.0 x 0.95 (carcasa, panel frontal, salida oscura, lama). 4 parts.
    (u,y,v) = centro de la cara trasera pegada a la pared; yaw=0 → pared hacia +v."""
    m = ctx.model('Split_Interior', parent=parent)
    carc = _caja(ctx, m, 'Carcasa', u, y, v, yaw, (0, 0, -0.40), (5.1, 1.0, 0.80), color=BLANCO_SPLIT, material='SmoothPlastic')
    # rejilla de entrada de aire en la cara superior (0 parts)
    g = ctx.surface_gui(carc, FACE['Top'], pixels_per_stud=80)
    for k in range(9):
        ctx.frame(g, pos=(0.05, 0, 0.12 + 0.085 * k, 0), size=(0.90, 0, 0.018, 0), color=(196, 196, 190), name='Ranura')
    panel = _caja(ctx, m, 'Panel_Frontal', u, y, v, yaw, (0, 0.17, -0.86), (4.9, 0.62, 0.12), color=BLANCO_SPLIT,
                  material='SmoothPlastic')
    g = ctx.surface_gui(panel, face_toward(yaw, _dir(yaw, 0, 0, -1)), pixels_per_stud=120)
    ctx.frame(g, pos=(0.02, 0, 0.93, 0), size=(0.96, 0, 0.012, 0), color=(214, 214, 208), name='Junta')
    disp = ctx.frame(g, pos=(0.85, 0, 0.28, 0), size=(0.09, 0, 0.44, 0), color=GRIS_OSCURO, corner=(0.3, 0), name='Pantalla')
    if encendido:
        ctx.text(disp, '24', pos=(0.1, 0, 0.1, 0), size=(0.8, 0, 0.8, 0), color=(120, 220, 255), font=FONT_GOTHAM, xalign=2, yalign=1)
        ctx.frame(g, pos=(0.955, 0, 0.42, 0), size=(0.012, 0, 0.16, 0), color=VERDE_LED, corner=(1.0, 0), name='Led')
    ctx.frame(g, pos=(0.80, 0, 0.30, 0), size=(0.035, 0, 0.40, 0), color=(215, 195, 43), corner=(0.15, 0), name='Etiqueta_Energia')
    ctx.text(g, 'INVERTER', pos=(0.05, 0, 0.30, 0), size=(0.14, 0, 0.40, 0), color=(150, 150, 146), font=FONT_GOTHAM, xalign=0, yalign=1)
    _caja(ctx, m, 'Salida_Aire', u, y, v, yaw, (0, -0.34, -0.85), (4.6, 0.26, 0.14), color=NEGRO_SALIDA, material='SmoothPlastic')
    _caja(ctx, m, 'Lama', u, y, v, yaw, (0, -0.26, -0.84), (4.6, 0.04, 0.16), pitch=20, color=LAMA, material='SmoothPlastic')
    return m


# ================================================================ 6) condensador exterior
def build_condensador_exterior(ctx, parent, u, y, v, yaw=0, tuberia=True):
    """Unidad condensadora 3.0 x 2.6 x 1.3 (caja + panel de rejilla circular dibujada con SurfaceGui), 2 ménsulas
    metálicas y tubería. 10 parts. (u,y,v) = centro de la cara trasera pegada a la pared; yaw=0 → pared hacia +v."""
    m = ctx.model('Condensador_Exterior', parent=parent)
    W, H, D = 3.0, 2.6, 1.2
    caja = _caja(ctx, m, 'Caja', u, y, v, yaw, (0, 0, -D / 2), (W, H, D), color=CAJA_AA, material='SmoothPlastic')
    frente = face_toward(yaw, _dir(yaw, 0, 0, -1))
    gc = ctx.surface_gui(caja, frente, pixels_per_stud=120, name='Etiquetas')
    # letrero en la franja de la caja que queda visible BAJO el panel de rejilla (el panel cubre y 0.096..0.942 del canvas)
    ctx.text(gc, 'COOL AIR', pos=(0.03, 0, 0.945, 0), size=(0.25, 0, 0.05, 0), color=(150, 152, 150), font=FONT_GOTHAM,
             xalign=0, yalign=1)
    # panel frontal de la rejilla (ligeramente saliente) con anillos concéntricos + tapa central (0 parts)
    Wr, Hr = 2.4, 2.2
    rej = _caja(ctx, m, 'Panel_Rejilla', u, y, v, yaw, (0, -0.05, -D - 0.05), (Wr, Hr, 0.10), color=(214, 216, 214),
                material='SmoothPlastic')
    _rejilla_circular(ctx, rej, frente, aspect=Wr / Hr, diam=0.92, n_radios=4, anillos=(0.92, 0.78, 0.64, 0.50, 0.36),
                      tapa=0.20, color=(214, 216, 214), fondo=(54, 56, 58), color_tapa=(196, 198, 196), ppstud=120,
                      grosor=3.0)
    # lamas laterales de la cara derecha (0 parts)
    gl = ctx.surface_gui(caja, face_toward(yaw, _dir(yaw, 1, 0, 0)), pixels_per_stud=80, name='Lamas_Laterales')
    for k in range(10):
        ctx.frame(gl, pos=(0.10, 0, 0.12 + 0.078 * k, 0), size=(0.80, 0, 0.02, 0), color=(190, 192, 190), name='Lama')
    # ménsulas metálicas (ángulo + riostra) bajo la caja
    for lado, lu in (('Izq', -1.0), ('Der', 1.0)):
        _caja(ctx, m, f'Mensula_Horizontal_{lado}', u, y, v, yaw, (lu, -H / 2 - 0.06, -0.70), (0.12, 0.12, 1.4),
              color=MENSULA, material='Metal')
        _caja(ctx, m, f'Mensula_Vertical_{lado}', u, y, v, yaw, (lu, -H / 2 - 0.66, -0.06), (0.12, 1.2, 0.12),
              color=MENSULA, material='Metal')
        _tubo(ctx, m, f'Riostra_{lado}', u, y, v, yaw, (lu, -H / 2 - 1.18, -0.12), (lu, -H / 2 - 0.12, -1.3), 0.10,
              color=MENSULA, material='Metal')
    if tuberia:
        ctx.cylinder('Tuberia_Aislada', place(u, y, v, yaw, W / 2 + 0.55, 0.35, -0.16), 1.2, 0.18, axis='u', yaw=yaw,
                     color=TUBERIA, material='SmoothPlastic', parent=m)
        ctx.cylinder('Tuberia_Entrada', place(u, y, v, yaw, W / 2 + 1.15, 0.35, -0.09), 0.18, 0.18, axis='v', yaw=yaw,
                     color=TUBERIA, material='SmoothPlastic', parent=m)      # termina a ras de la pared (v = 0)
    return m


# ================================================================ 7) interruptor, toma, canaleta
def build_interruptor(ctx, parent, u, y, v, yaw=0, teclas=1):
    """Placa 0.5 x 0.5 con 1-2 teclas basculantes dibujadas (1 part + SurfaceGui)."""
    m = ctx.model('Interruptor', parent=parent)
    p = _caja(ctx, m, 'Placa_Interruptor', u, y, v, yaw, (0, 0, -0.03), (0.5, 0.5, 0.06), color=BLANCO_PLACA, material='SmoothPlastic')
    g = ctx.surface_gui(p, face_toward(yaw, _dir(yaw, 0, 0, -1)), pixels_per_stud=200)
    marco = ctx.frame(g, pos=(0.08, 0, 0.08, 0), size=(0.84, 0, 0.84, 0), color=BLANCO_PLACA, corner=(0.06, 0), name='Marco')
    _ui_stroke(ctx, marco, (205, 205, 200), 2.0)
    w = 0.56 / teclas
    for k in range(teclas):
        x0 = 0.22 + k * w
        t = ctx.frame(g, pos=(x0 + 0.03, 0, 0.22, 0), size=(w - 0.06, 0, 0.56, 0), color=(232, 232, 228), corner=(0.04, 0), name=f'Tecla_{k + 1}')
        _ui_stroke(ctx, t, (200, 200, 196), 2.0)
        ctx.frame(g, pos=(x0 + 0.03, 0, 0.48, 0), size=(w - 0.06, 0, 0.3, 0), color=(220, 220, 216), corner=(0.04, 0), name=f'Sombra_{k + 1}')
    return m


def build_toma(ctx, parent, u, y, v, yaw=0):
    """Toma doble (dos salidas con ranuras y polo a tierra dibujados). 1 part + SurfaceGui."""
    m = ctx.model('Toma', parent=parent)
    p = _caja(ctx, m, 'Placa_Toma', u, y, v, yaw, (0, 0, -0.03), (0.5, 0.5, 0.06), color=BLANCO_PLACA, material='SmoothPlastic')
    g = ctx.surface_gui(p, face_toward(yaw, _dir(yaw, 0, 0, -1)), pixels_per_stud=200)
    marco = ctx.frame(g, pos=(0.08, 0, 0.08, 0), size=(0.84, 0, 0.84, 0), color=BLANCO_PLACA, corner=(0.06, 0), name='Marco')
    _ui_stroke(ctx, marco, (205, 205, 200), 2.0)
    for k, cy in enumerate((0.30, 0.70)):
        s = ctx.frame(g, pos=(0.30, 0, cy - 0.17, 0), size=(0.40, 0, 0.34, 0), color=(236, 236, 232), corner=(0.12, 0), name=f'Salida_{k + 1}')
        _ui_stroke(ctx, s, (200, 200, 196), 2.0)
        ctx.frame(g, pos=(0.40, 0, cy - 0.11, 0), size=(0.035, 0, 0.12, 0), color=(40, 40, 42), name=f'Ranura_{k + 1}_Izq')
        ctx.frame(g, pos=(0.565, 0, cy - 0.11, 0), size=(0.035, 0, 0.12, 0), color=(40, 40, 42), name=f'Ranura_{k + 1}_Der')
        ctx.frame(g, pos=(0.475, 0, cy + 0.04, 0), size=(0.05, 0, 0.05, 0), color=(40, 40, 42), corner=(1.0, 0), name=f'Tierra_{k + 1}')
    ctx.frame(g, pos=(0.485, 0, 0.485, 0), size=(0.03, 0, 0.03, 0), color=(170, 170, 166), corner=(1.0, 0), name='Tornillo')
    return m


def build_canaleta(ctx, parent, u0, u1, y, v, yaw=0):
    """Canaleta eléctrica blanca horizontal (0.25 alto x 0.12 saliente) de u0 a u1 pegada a la pared. 1 part."""
    m = ctx.model('Canaleta', parent=parent)
    L = u1 - u0
    p = ctx.box('Canaleta_Electrica', place(u0, y, v, yaw, L / 2, 0, -0.06), (L, 0.25, 0.12), yaw=yaw,
                color=BLANCO_CANALETA, material='SmoothPlastic', parent=m)
    g = ctx.surface_gui(p, face_toward(yaw, _dir(yaw, 0, 0, -1)), pixels_per_stud=60)
    ctx.frame(g, pos=(0, 0, 0.72, 0), size=(1, 0, 0.03, 0), color=(214, 214, 210), name='Junta_Tapa')
    return m


# ================================================================ selftest
def selftest():
    import os
    from render3d import render_ctx3d
    os.makedirs('../out', exist_ok=True)
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Techo')
    yt = 13.03                      # tope del cielo raso (losa)
    yc = yt - 0.12                  # cara inferior del cielo raso
    casos = [
        ('cielo_raso',          lambda: build_cielo_raso(ctx, raiz, 0.0, 13.0, 0.0, 8.0, yt)),
        ('luminaria_0',         lambda: build_luminaria(ctx, raiz, 3.0, yc, 2.0, yaw=0)),
        ('luminaria_90',        lambda: build_luminaria(ctx, raiz, 9.5, yc, 4.0, yaw=90)),
        ('ventilador_techo',    lambda: build_ventilador_techo(ctx, raiz, 6.5, yc, 5.0)),
        ('ventilador_pared_0',  lambda: build_ventilador_pared(ctx, raiz, 17.0, 10.0, 0.0, yaw=0)),
        ('ventilador_pared_90', lambda: build_ventilador_pared(ctx, raiz, 21.0, 10.0, 3.0, yaw=90)),
        ('split_0',             lambda: build_split_interior(ctx, raiz, 28.0, 11.5, 0.0, yaw=0)),
        ('split_90',            lambda: build_split_interior(ctx, raiz, 33.0, 11.5, 3.0, yaw=90)),
        ('condensador_0',       lambda: build_condensador_exterior(ctx, raiz, 40.0, 10.5, 0.0, yaw=0)),
        ('condensador_90',      lambda: build_condensador_exterior(ctx, raiz, 47.0, 10.5, 3.0, yaw=90)),
        ('interruptor_0',       lambda: build_interruptor(ctx, raiz, 52.0, 5.0, 0.0, yaw=0, teclas=2)),
        ('interruptor_90',      lambda: build_interruptor(ctx, raiz, 54.0, 5.0, 1.0, yaw=90)),
        ('toma_0',              lambda: build_toma(ctx, raiz, 56.0, 1.6, 0.0, yaw=0)),
        ('toma_90',             lambda: build_toma(ctx, raiz, 58.0, 1.6, 1.0, yaw=90)),
        ('canaleta_0',          lambda: build_canaleta(ctx, raiz, 60.0, 66.0, 2.0, 0.0, yaw=0)),
        ('canaleta_90',         lambda: build_canaleta(ctx, raiz, 68.0, 72.0, 2.0, 0.0, yaw=90)),
    ]
    lim = {'cielo': 11, 'luminaria': 3, 'ventilador_techo': 12, 'ventilador_pared': 14, 'split': 6,
           'condensador': 10, 'interruptor': 1, 'toma': 1, 'canaleta': 2}
    out = []
    for nombre, fn in casos:
        idx = fn()
        n = ctx.count_parts(idx)
        lo, hi = ctx.bbox(idx)
        print(f'{nombre:20s} parts={n:2d} bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) '
              f'ext=({hi[0]-lo[0]:.2f},{hi[1]-lo[1]:.2f},{hi[2]-lo[2]:.2f})')
        out.append((nombre, idx, n, lo, hi))
        render_ctx(ctx, f'../out/comp_techo_{nombre}.png', idx=idx, scale=60 if 'cielo' not in nombre else 30)
        render_ctx3d(ctx, f'../out/comp_techo_{nombre}_3d.png', idx=idx, scale=60 if 'cielo' not in nombre else 30)
    render_ctx(ctx, '../out/comp_techo_preview.png', idx=raiz, scale=16)
    ctx.export('../out/comp_techo_selftest.rbxm')
    for nombre, idx, n, lo, hi in out:
        clave = next(k for k in lim if nombre.startswith(k))
        assert n <= lim[clave], (nombre, n, lim[clave])
    return out


if __name__ == '__main__':
    selftest()
