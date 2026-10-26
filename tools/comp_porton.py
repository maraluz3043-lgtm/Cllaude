"""comp_porton.py — Portón metálico blanco de entrada (foto4_porton_blanco.png), marco local u,y,v (ver API.md).

build_porton(ctx, parent, u, y, v, yaw=0) -> idx del Model 'Porton_Blanco'   (≤ 260 parts)

Convenciones
------------
* (u, y, v) = centro de la BASE del portón sobre el piso (y = cota del piso terminado, p.ej. 0.42).
* yaw = 0: el portón está en el plano u-y, su espesor va a lo largo de v y la cara EXTERIOR (la de la foto:
  relieves físicos, cadena, candado y cerrojo) mira hacia -v. La cara interior (+v) lleva el mismo troquelado
  pintado con Frames de SurfaceGui (0 parts). El bastidor (tubos de 0.3) sobresale 0.11 por ambas caras, así que el
  travesaño, los largueros y la puerta peatonal se ven desde dentro y desde fuera.
* yaw gira todo sobre el eje vertical con el convenio de la API (yaw=90 → el eje local +u pasa a apuntar a +v).
  Las SurfaceGui usan índices de cara INTRÍNSECOS (face_toward(0, ...)) porque los parts se crean con el mismo yaw;
  selftest() comprueba numéricamente la normal de cada SurfaceGui para yaw 0 / 90 / 180.
* Todo anclado; nombres en español; sin meshes, texturas ni unions.

Composición (coordenadas locales, u creciendo hacia la derecha visto desde fuera), según la foto 4:
  hoja izquierda u -11.0..1.25 (≈ 12.3, con la puerta peatonal y un parante intermedio a 6 studs del poste),
  hoja derecha u 1.35..11.0 (≈ 9.7); tapajuntas central sobre la junta con cerradura, cadena y candado;
  puerta peatonal de 3.0 x 5.85 que arranca 1.8 studs a la derecha del poste izquierdo y cuyo riel superior
  es el propio travesaño (y = 5.7, ≈ media altura); láminas troqueladas de ≈1.2 de ancho con 8 filas físicas de
  cuadros (parts 0.5x0.5x0.04) y 7 filas intermedias pintadas (reloj de arena = dos triángulos hechos con un
  cuadro oscuro y dos tapas giradas 45° del color de la lámina), nervios verticales pintados; postes = tubos de
  acero de 0.55 (el izquierdo con el tramo bajo rojo); 26 puntas de lanza (varilla + rombo) sobre los rieles
  superiores; 3 manchas de óxido sobre los tubos.
"""
import math
from build import Ctx, FACE, face_toward
from preview import render_ctx

# ---------------------------------------------------------------- colores / materiales
BLANCO = (238, 240, 240)          # lámina
BLANCO_2 = (232, 234, 235)        # lámina alterna (tono ligeramente distinto para marcar los empalmes)
BLANCO_TUBO = (241, 242, 242)     # bastidor pintado
RELIEVE = (225, 227, 228)         # cuadros troquelados físicos
RELIEVE_INT = (211, 213, 215)     # reloj de arena pintado (cara exterior)
RELIEVE_DENTRO = (218, 220, 222)  # reloj de arena pintado (cara interior, hundido)
NERVIO = (206, 208, 210)          # nervios verticales (Frame)
HERRAJE = (90, 92, 95)
HERRAJE_OSC = (58, 60, 63)
DORADO = (198, 160, 70)
ROJO_POSTE = (178, 28, 34)
OXIDO = (128, 84, 52)

# ---------------------------------------------------------------- dimensiones (studs; 1 m ≈ 4 studs)
ANCHO_TOTAL = 22.0
ANCHO_IZQ = 12.3                  # hoja con la puerta peatonal (foto 4)
ANCHO_DER = ANCHO_TOTAL - ANCHO_IZQ
SEPARACION = 0.10                 # luz entre hojas (la cubre el tapajuntas)
ALTO = 11.5                       # borde superior de las hojas sobre el piso
HOLGURA = 0.10                    # luz bajo las hojas
TUBO = 0.30                       # tubo cuadrado del bastidor
LAMINA_ANCHO = 1.2
LAMINA_ESP = 0.08
FILAS = 8                         # filas físicas de relieves
PASO_FILAS = 1.45                 # entre filas físicas; las pintadas van en medio (paso visual 0.725)
RELIEVE_W, RELIEVE_H, RELIEVE_D = 0.5, 0.5, 0.04
Y_TRAVESANO = 5.7
PUERTA_DESDE_POSTE = 1.8
PUERTA_ANCHO = 3.0
PUERTA_ALTO = Y_TRAVESANO + TUBO / 2      # el riel superior de la puerta ES el travesaño
PUERTA_TUBO = 0.25
PUERTA_LAMINA_ANCHO = 0.9
PARANTE_DESDE_POSTE = 6.0
POSTE_DIAM = 0.55
POSTE_ALTO = 12.3
POSTE_ROJO_ALTO = 8.6
PASO_PUNTAS = 0.8

CARA_EXT = face_toward(0, (0, 0, -1))     # cara intrínseca que mira a -v con yaw=0 (Back)
CARA_INT = face_toward(0, (0, 0, 1))      # cara intrínseca que mira a +v con yaw=0 (Front)


def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del componente → coordenadas (u,y,v) del edificio, girado yaw grados."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def _caja(ctx, parent, nombre, u, y, v, yaw, lc, size, yaw_local=0.0, **kw):
    return ctx.box(nombre, place(u, y, v, yaw, *lc), size, yaw=yaw + yaw_local, parent=parent, **kw)


def _cil(ctx, parent, nombre, u, y, v, yaw, lc, length, diam, axis='y', **kw):
    return ctx.cylinder(nombre, place(u, y, v, yaw, *lc), length, diam, axis=axis, yaw=yaw, parent=parent, **kw)


def _tubo(ctx, parent, nombre, u, y, v, yaw, a, b, diam, **kw):
    """Cilindro entre dos puntos locales a y b (eslabones de cadena inclinados, etc.)."""
    ax, ay, az = a
    bx, by, bz = b
    L = math.dist(a, b)
    d = ((bx - ax) / L, (by - ay) / L, (bz - az) / L)
    psi = math.degrees(math.atan2(d[2], d[0]))
    r = math.degrees(math.asin(max(-1.0, min(1.0, d[1]))))
    c = place(u, y, v, yaw, (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2)
    return ctx.part(nombre, c, (L, diam, diam), yaw=yaw + psi, roll=r, shape='Cylinder', parent=parent, **kw)


# ---------------------------------------------------------------- dibujo plano (0 parts)
def _frame(ctx, gui, pos, size, color, z=1, rotation=0.0, transparency=0.0, name='Frame'):
    i = ctx.frame(gui, pos=pos, size=size, color=color, transparency=transparency, rotation=rotation, name=name)
    ctx.insts[i]['props']['ZIndex'] = (0x03, int(z))
    return i


def _reloj_arena(ctx, gui, w, h, xc, yc, lado, color, fondo):
    """Reloj de arena (dos triángulos opuestos por el vértice) de `lado` studs centrado en (xc, yc) studs medidos
    desde la esquina superior izquierda de la cara de w x h studs: un cuadro oscuro y dos tapas cuadradas giradas
    45° del color de la lámina que ocultan los triángulos izquierdo y derecho. 3 Frames."""
    _frame(ctx, gui, ((xc - lado / 2) / w, 0, (yc - lado / 2) / h, 0), (lado / w, 0, lado / h, 0), color, z=1, name='Cuadro')
    t = lado / math.sqrt(2)
    for sx in (-1, 1):
        cx = xc + sx * lado / 2
        _frame(ctx, gui, ((cx - t / 2) / w, 0, (yc - t / 2) / h, 0), (t / w, 0, t / h, 0), fondo, z=2, rotation=45.0, name='Tapa')


def _nervios(ctx, gui, w):
    """Nervios verticales a 0.10 y 0.23 studs de cada borde de la lámina (solo los que no tocan la columna de cuadros)."""
    for x in (0.10, 0.23):
        if x + 0.03 < (w - RELIEVE_W) / 2 - 0.02:
            for xx in (x, w - x):
                _frame(ctx, gui, ((xx - 0.015) / w, 0, 0, 0), (0.03 / w, 0, 1, 0), NERVIO, z=3, transparency=0.2, name='Nervio')


def _filas(ly0, ly1, n, paso):
    c = (ly0 + ly1) / 2
    return [c + (k - (n - 1) / 2) * paso for k in range(n)]


def _cabe(fy, ly0, ly1):
    return fy - RELIEVE_H / 2 >= ly0 + 0.04 and fy + RELIEVE_H / 2 <= ly1 - 0.04


def _lamina(ctx, parent, i, u, y, v, yaw, lu, ly0, ly1, w, color, filas_fis, filas_pin, lv=0.0, lv_relieve=None):
    """Lámina vertical (1 part) + relieves físicos en la cara exterior (1 part por fila física que quepa) +
    troquelado pintado (0 parts): filas intermedias fuera, todas las filas dentro, nervios en ambas caras.
    Devuelve el número de parts creados."""
    h = ly1 - ly0
    lam = _caja(ctx, parent, f'Lamina_{i}', u, y, v, yaw, (lu, (ly0 + ly1) / 2, lv), (w, h, LAMINA_ESP),
                color=color, material='SmoothPlastic')
    fis = [(k, fy) for k, fy in enumerate(filas_fis) if _cabe(fy, ly0, ly1)]
    pin = [fy for fy in filas_pin if _cabe(fy, ly0, ly1)]
    g = ctx.surface_gui(lam, CARA_EXT, pixels_per_stud=80, name='Troquel_Exterior', light_influence=1.0)
    _nervios(ctx, g, w)
    for fy in pin:
        _reloj_arena(ctx, g, w, h, w / 2, ly1 - fy, RELIEVE_W, RELIEVE_INT, color)
    gi = ctx.surface_gui(lam, CARA_INT, pixels_per_stud=80, name='Troquel_Interior', light_influence=1.0)
    _nervios(ctx, gi, w)
    for fy in sorted(pin + [fy for _, fy in fis]):
        _reloj_arena(ctx, gi, w, h, w / 2, ly1 - fy, RELIEVE_W, RELIEVE_DENTRO, color)
    if lv_relieve is None:
        lv_relieve = lv - LAMINA_ESP / 2 - RELIEVE_D / 2 + 0.01     # 0.01 embebido en la lámina
    n = 1
    for k, fy in fis:
        _caja(ctx, parent, f'Relieve_L{i}_{k + 1}', u, y, v, yaw, (lu, fy, lv_relieve), (RELIEVE_W, RELIEVE_H, RELIEVE_D),
              color=RELIEVE, material='SmoothPlastic', castshadow=False)
        n += 1
    return n


def _laminas_en(ctx, parent, u, y, v, yaw, a, b, ly0, ly1, filas_fis, filas_pin, i0, ancho=LAMINA_ANCHO):
    """Rellena el vano [a,b] x [ly0,ly1] con láminas de ≈`ancho`. Devuelve (nparts, siguiente índice)."""
    nl = max(1, round((b - a) / ancho))
    w = (b - a) / nl
    n = 0
    for j in range(nl):
        i = i0 + j
        n += _lamina(ctx, parent, i, u, y, v, yaw, a + (j + 0.5) * w, ly0, ly1, w,
                     BLANCO if i % 2 == 1 else BLANCO_2, filas_fis, filas_pin)
    return n, i0 + nl


def _filas_globales():
    ly0, ly1 = HOLGURA + TUBO, ALTO - TUBO
    fis = _filas(ly0, ly1, FILAS, PASO_FILAS)
    banda = (Y_TRAVESANO - TUBO / 2 - 0.05, Y_TRAVESANO + TUBO / 2 + 0.05)
    pin = [(fis[k] + fis[k + 1]) / 2 for k in range(FILAS - 1)]
    pin = [fy for fy in pin if fy + RELIEVE_H / 2 < banda[0] or fy - RELIEVE_H / 2 > banda[1]]   # no bajo el travesaño
    return fis, pin


# ---------------------------------------------------------------- hoja
def _hoja(ctx, parent, nombre, u, y, v, yaw, u0, u1, puerta=False, parante=None):
    """Hoja del portón entre u0 y u1 (locales): largueros, rieles, travesaño (partido donde hay puerta o parante),
    parante intermedio opcional (u local absoluto), láminas por vano y puerta peatonal. Devuelve (idx, nparts)."""
    m = ctx.model(nombre, parent=parent)
    n = 0
    yc = (HOLGURA + ALTO) / 2
    hh = ALTO - HOLGURA
    ua, ub = u0 + TUBO, u1 - TUBO                   # luz interior entre largueros
    _caja(ctx, m, 'Larguero_Izq', u, y, v, yaw, (u0 + TUBO / 2, yc, 0.0), (TUBO, hh, TUBO), color=BLANCO_TUBO)
    _caja(ctx, m, 'Larguero_Der', u, y, v, yaw, (u1 - TUBO / 2, yc, 0.0), (TUBO, hh, TUBO), color=BLANCO_TUBO)
    _caja(ctx, m, 'Riel_Superior', u, y, v, yaw, ((ua + ub) / 2, ALTO - TUBO / 2, 0.0), (ub - ua, TUBO, TUBO), color=BLANCO_TUBO)
    n += 3
    ly0, ly1 = HOLGURA + TUBO, ALTO - TUBO
    fis, pin = _filas_globales()
    # vanos de lámina: lista de (a, b, ya, yb); cortes por la puerta y el parante
    pu0 = pu1 = None
    if puerta:
        pu0 = u0 + PUERTA_DESDE_POSTE
        pu1 = pu0 + PUERTA_ANCHO
    cortes = []                                      # tramos ocupados en u (para rieles / travesaño)
    if puerta:
        cortes.append((pu0, pu1, 'puerta'))
    if parante is not None:
        cortes.append((parante - TUBO / 2, parante + TUBO / 2, 'parante'))
    cortes.sort()
    # riel inferior y travesaño: tramos libres entre cortes
    def tramos(saltar):
        libres, x = [], ua
        for c0, c1, tipo in cortes:
            if tipo in saltar:
                if c0 - x > 0.05:
                    libres.append((x, c0))
                x = c1
        if ub - x > 0.05:
            libres.append((x, ub))
        return libres
    for k, (a, b) in enumerate(tramos(('puerta',))):
        _caja(ctx, m, f'Riel_Inferior_{k + 1}' if puerta else 'Riel_Inferior', u, y, v, yaw,
              ((a + b) / 2, HOLGURA + TUBO / 2, 0.0), (b - a, TUBO, TUBO), color=BLANCO_TUBO)
        n += 1
    for k, (a, b) in enumerate(tramos(('puerta', 'parante'))):
        _caja(ctx, m, f'Travesano_{k + 1}' if len(cortes) else 'Travesano', u, y, v, yaw,
              ((a + b) / 2, Y_TRAVESANO, 0.0), (b - a, TUBO, TUBO), color=BLANCO_TUBO)
        n += 1
    if parante is not None:
        _caja(ctx, m, 'Parante_Intermedio', u, y, v, yaw, (parante, (ly0 + ly1) / 2, 0.0), (TUBO, ly1 - ly0, TUBO), color=BLANCO_TUBO)
        n += 1
    # láminas por vano (sobre la puerta solo desde su riel superior)
    i = 1
    x = ua
    for c0, c1, tipo in cortes:
        if c0 - x > 0.05:
            dn, i = _laminas_en(ctx, m, u, y, v, yaw, x, c0, ly0, ly1, fis, pin, i)
            n += dn
        if tipo == 'puerta':
            dn, i = _laminas_en(ctx, m, u, y, v, yaw, c0, c1, PUERTA_ALTO, ly1, fis, pin, i)
            n += dn
        x = c1
    if ub - x > 0.05:
        dn, i = _laminas_en(ctx, m, u, y, v, yaw, x, ub, ly0, ly1, fis, pin, i)
        n += dn
    if puerta:
        n += _puerta_peatonal(ctx, m, u, y, v, yaw, pu0, pu1, fis, pin)
    return m, n


def _puerta_peatonal(ctx, parent, u, y, v, yaw, pu0, pu1, fis, pin):
    """Puerta peatonal inserta: largueros de 0.25, riel superior = travesaño (tubo 0.3), riel inferior propio,
    3 láminas con relieves, 2 bisagras y cerrojo (placa + pasador) con candado pequeño."""
    m = ctx.model('Puerta_Peatonal', parent=parent)
    n = 0
    py0, py1 = HOLGURA + 0.05, PUERTA_ALTO
    yc = (py0 + py1) / 2
    hh = py1 - py0
    wi = pu1 - pu0 - 2 * PUERTA_TUBO
    _caja(ctx, m, 'Larguero_Izq', u, y, v, yaw, (pu0 + PUERTA_TUBO / 2, yc, 0.0), (PUERTA_TUBO, hh, TUBO), color=BLANCO_TUBO)
    _caja(ctx, m, 'Larguero_Der', u, y, v, yaw, (pu1 - PUERTA_TUBO / 2, yc, 0.0), (PUERTA_TUBO, hh, TUBO), color=BLANCO_TUBO)
    _caja(ctx, m, 'Riel_Superior', u, y, v, yaw, ((pu0 + pu1) / 2, Y_TRAVESANO, 0.0), (wi, TUBO, TUBO), color=BLANCO_TUBO)
    _caja(ctx, m, 'Riel_Inferior', u, y, v, yaw, ((pu0 + pu1) / 2, py0 + PUERTA_TUBO / 2, 0.0), (wi, PUERTA_TUBO, TUBO), color=BLANCO_TUBO)
    n += 4
    ly0, ly1 = py0 + PUERTA_TUBO, py1 - TUBO
    dn, _ = _laminas_en(ctx, m, u, y, v, yaw, pu0 + PUERTA_TUBO, pu1 - PUERTA_TUBO, ly0, ly1, fis, pin, 1, ancho=PUERTA_LAMINA_ANCHO)
    n += dn
    for k, by in enumerate((py0 + 1.0, py1 - 1.0)):
        _cil(ctx, m, f'Bisagra_{k + 1}', u, y, v, yaw, (pu0, by, -0.27), 0.5, 0.22, axis='y', color=HERRAJE, material='Metal')
        n += 1
    cy = yc + 0.1
    _caja(ctx, m, 'Cerrojo_Placa', u, y, v, yaw, (pu1 - 0.42, cy, -0.19), (0.46, 0.72, 0.06), color=HERRAJE, material='Metal')
    _cil(ctx, m, 'Cerrojo_Pasador', u, y, v, yaw, (pu1 - 0.25, cy + 0.12, -0.28), 0.9, 0.12, axis='u', color=HERRAJE_OSC, material='Metal')
    _caja(ctx, m, 'Candado_Puerta', u, y, v, yaw, (pu1 - 0.42, cy - 0.40, -0.29), (0.26, 0.30, 0.12), color=DORADO, material='Metal')
    n += 3
    return n


# ---------------------------------------------------------------- portón completo
def build_porton(ctx, parent, u, y, v, yaw=0.0):
    """Portón 'Porton_Blanco' (dos hojas + puerta peatonal, tapajuntas con cadena y candado, postes tubulares y
    puntas de lanza). (u,y,v) = centro de la base sobre el piso; cara exterior hacia -v con yaw=0. ≤ 260 parts."""
    raiz = ctx.model('Porton_Blanco', parent=parent)
    n = 0
    uL0 = -ANCHO_TOTAL / 2
    uL1 = uL0 + ANCHO_IZQ - SEPARACION / 2
    uR0 = uL1 + SEPARACION
    uR1 = ANCHO_TOTAL / 2
    _, nL = _hoja(ctx, raiz, 'Hoja_Izquierda', u, y, v, yaw, uL0, uL1, puerta=True, parante=uL0 + PARANTE_DESDE_POSTE)
    _, nR = _hoja(ctx, raiz, 'Hoja_Derecha', u, y, v, yaw, uR0, uR1)
    n += nL + nR

    # ---- junta central: tapajuntas por delante (no solapa los largueros), cerradura, cadena y candado
    mc = ctx.model('Cierre_Central', parent=raiz)
    um = (uL1 + uR0) / 2
    _caja(ctx, mc, 'Tapajuntas_Central', u, y, v, yaw, (um, (HOLGURA + ALTO) / 2, -TUBO / 2 - 0.06), (0.42, ALTO - HOLGURA, 0.12), color=BLANCO_TUBO)
    _caja(ctx, mc, 'Cerradura', u, y, v, yaw, (um, Y_TRAVESANO - 0.55, -0.30), (0.5, 0.95, 0.06), color=HERRAJE, material='Metal')
    a = (um - 0.75, Y_TRAVESANO + 0.15, -0.40)
    b = (um + 0.75, Y_TRAVESANO + 0.15, -0.40)
    c = (um, Y_TRAVESANO - 0.65, -0.43)
    _tubo(ctx, mc, 'Cadena_Superior', u, y, v, yaw, a, b, 0.13, color=HERRAJE_OSC, material='Metal')
    _tubo(ctx, mc, 'Cadena_Izq', u, y, v, yaw, a, c, 0.13, color=HERRAJE_OSC, material='Metal')
    _tubo(ctx, mc, 'Cadena_Der', u, y, v, yaw, b, c, 0.13, color=HERRAJE_OSC, material='Metal')
    cy = Y_TRAVESANO - 1.25
    _caja(ctx, mc, 'Candado_Cuerpo', u, y, v, yaw, (um, cy, -0.43), (0.5, 0.6, 0.22), color=DORADO, material='Metal')
    _cil(ctx, mc, 'Candado_Arco', u, y, v, yaw, (um, cy + 0.46, -0.43), 0.36, 0.09, axis='u', color=HERRAJE, material='Metal')
    _cil(ctx, mc, 'Candado_Arco_Izq', u, y, v, yaw, (um - 0.16, cy + 0.38, -0.43), 0.22, 0.09, axis='y', color=HERRAJE, material='Metal')
    _cil(ctx, mc, 'Candado_Arco_Der', u, y, v, yaw, (um + 0.16, cy + 0.38, -0.43), 0.22, 0.09, axis='y', color=HERRAJE, material='Metal')
    n += 9

    # ---- postes: tubos de acero de 0.55 (el izquierdo con el tramo bajo rojo) y bisagras de las hojas
    mp = ctx.model('Postes', parent=raiz)
    ux = uL0 - POSTE_DIAM / 2
    _cil(ctx, mp, 'Poste_Izq_Tramo_Rojo', u, y, v, yaw, (ux, POSTE_ROJO_ALTO / 2, 0.0), POSTE_ROJO_ALTO, POSTE_DIAM, axis='y',
         color=ROJO_POSTE, material='Metal')
    _cil(ctx, mp, 'Poste_Izq', u, y, v, yaw, (ux, (POSTE_ROJO_ALTO + POSTE_ALTO) / 2, 0.0), POSTE_ALTO - POSTE_ROJO_ALTO, POSTE_DIAM, axis='y',
         color=BLANCO, material='Metal')
    _cil(ctx, mp, 'Poste_Der', u, y, v, yaw, (uR1 + POSTE_DIAM / 2, POSTE_ALTO / 2, 0.0), POSTE_ALTO, POSTE_DIAM, axis='y',
         color=BLANCO, material='Metal')
    n += 3
    for lado, ux in (('Izq', uL0), ('Der', uR1)):
        for k, by in enumerate((1.5, Y_TRAVESANO, ALTO - 1.5)):
            _cil(ctx, mp, f'Bisagra_{lado}_{k + 1}', u, y, v, yaw, (ux, by, -0.34), 0.7, 0.32, axis='y',
                 color=HERRAJE, material='Metal')
            n += 1

    # ---- puntas de lanza sobre los rieles superiores (varilla + rombo)
    ml = ctx.model('Puntas_Lanza', parent=raiz)
    k = 0
    for (a0, a1) in ((uL0 + TUBO, uL1 - TUBO), (uR0 + TUBO, uR1 - TUBO)):
        np_ = max(2, round((a1 - a0) / PASO_PUNTAS))
        paso = (a1 - a0) / np_
        for i in range(np_):
            k += 1
            lu = a0 + (i + 0.5) * paso
            _caja(ctx, ml, f'Varilla_{k}', u, y, v, yaw, (lu, ALTO + 0.34, 0.0), (0.1, 0.68, 0.1), color=BLANCO_TUBO, castshadow=False)
            _caja(ctx, ml, f'Pico_{k}', u, y, v, yaw, (lu, ALTO + 0.68 + 0.12, 0.0), (0.27, 0.27, 0.12), roll=45.0,
                  color=BLANCO_TUBO, castshadow=False)
            n += 2

    # ---- óxido / suciedad (opcional, 3 parts sobre las caras frontales de los tubos)
    mo = ctx.model('Oxido', parent=raiz)
    _caja(ctx, mo, 'Oxido_Parante', u, y, v, yaw, (uL0 + PARANTE_DESDE_POSTE, HOLGURA + TUBO + 0.5, -TUBO / 2 - 0.006), (0.26, 0.9, 0.012),
          color=OXIDO, material='CorrodedMetal', transparency=0.3, castshadow=False, cancollide=False)
    _caja(ctx, mo, 'Oxido_Larguero_Der', u, y, v, yaw, (uR1 - TUBO / 2, HOLGURA + TUBO + 0.35, -TUBO / 2 - 0.006), (0.26, 0.6, 0.012),
          color=OXIDO, material='CorrodedMetal', transparency=0.35, castshadow=False, cancollide=False)
    _caja(ctx, mo, 'Oxido_Tapajuntas', u, y, v, yaw, (um + 0.03, Y_TRAVESANO - 2.6, -TUBO / 2 - 0.12 - 0.006), (0.3, 0.9, 0.012),
          color=OXIDO, material='CorrodedMetal', transparency=0.4, castshadow=False, cancollide=False)
    n += 3
    assert n == ctx.count_parts(raiz), (n, ctx.count_parts(raiz))
    assert n <= 260, n
    return raiz


# ---------------------------------------------------------------- comprobaciones
def comprobar_caras(ctx, idx, yaw):
    """Comprueba numéricamente que cada SurfaceGui 'Troquel_Exterior' está en la cara cuya normal apunta hacia la
    dirección exterior (-v girada yaw) y cada 'Troquel_Interior' en la opuesta. Devuelve el nº de SurfaceGui revisadas."""
    import numpy as np
    from build import F, Yv, D
    t = math.radians(yaw)
    ext = np.array([math.sin(t), 0.0, -math.cos(t)])
    normales = {0: (0, 1), 1: (1, 1), 2: (2, 1), 3: (0, -1), 4: (1, -1), 5: (2, -1)}   # Right, Top, Back, Left, Bottom, Front
    n = 0
    for i in ctx.descendants(idx):
        inst = ctx.insts[i]
        if inst['cls'] != 'SurfaceGui':
            continue
        padre = ctx.insts[inst['parent']]
        R = np.array(padre['props']['CFrame'][1][1]).reshape(3, 3)
        col, sgn = normales[inst['props']['Face'][1]]
        nw = sgn * R[:, col]
        nl = np.array([nw @ F, nw @ Yv, nw @ D])
        nombre = inst['props']['Name'][1]
        esperado = ext if nombre == b'Troquel_Exterior' else -ext
        assert np.allclose(nl, esperado, atol=1e-4), (yaw, nombre, nl, esperado)
        n += 1
    return n


def selftest():
    from render3d import render_ctx3d
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Porton')
    out = []
    casos = [
        ('porton_0', 0, lambda: build_porton(ctx, raiz, 0.0, 0.42, 0.0, yaw=0)),
        ('porton_90', 90, lambda: build_porton(ctx, raiz, 22.0, 0.42, 8.0, yaw=90)),
    ]
    for nombre, yaw, fn in casos:
        idx = fn()
        n = ctx.count_parts(idx)
        lo, hi = ctx.bbox(idx)
        print(f'{nombre:10s} parts={n:3d} bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) '
              f'ext=({hi[0]-lo[0]:.2f},{hi[1]-lo[1]:.2f},{hi[2]-lo[2]:.2f})')
        out.append((nombre, idx, n, lo, hi))
        render_ctx(ctx, f'../out/comp_porton_{nombre}.png', idx=idx, scale=36)
    render_ctx(ctx, '../out/comp_porton_preview.png', idx=raiz, scale=24)
    render_ctx3d(ctx, '../out/comp_porton_3d.png', idx=out[0][1], scale=36)
    render_ctx(ctx, '../out/comp_porton_interior.png', idx=out[0][1], scale=36, views=('back',))   # cara interior (+v)
    ctx.export('../out/comp_porton_selftest.rbxm')
    # normales de las SurfaceGui para yaw 0 / 90 / 180
    for yaw in (0, 90, 180):
        c2 = Ctx()
        i2 = build_porton(c2, -1, 3.0, 0.42, -5.0, yaw=yaw)
        ng = comprobar_caras(c2, i2, yaw)
        print(f'caras SurfaceGui OK para yaw={yaw:3d}: {ng} revisadas')
    for nombre, idx, n, lo, hi in out:
        assert n <= 260, (nombre, n)
    return out


if __name__ == '__main__':
    selftest()
