"""comp_misc.py — Objetos pequeños para los salones nuevos (marco local u,y,v; ver API.md).

Convenciones comunes
--------------------
* (u, y, v) = centro de la BASE del objeto sobre el piso (y = cota del piso terminado, 0.42), salvo:
    - build_ventana_interior: (u,y,v) = centro de la ventana; v = cara interior del muro (1.40). El conjunto
      ocupa v..v+0.30 hacia el interior (vidrio v..v+0.10 pegado al muro, marco v..v+0.30, repisa v..v+0.50).
    - build_bandera_colombia: (u,y,v) = punto de anclaje del soporte EN la pared; yaw=0 → la pared está en +v
      (detrás) y el asta sale hacia -v (hacia el interior del salón) subiendo en diagonal.
    - build_libros: (u,y,v) = centro de la base de la pila sobre la mesa (y = cara superior del tablero).
* yaw (grados) gira el objeto sobre el eje vertical con el mismo convenio de la API (yaw=90 → +lu pasa a +v).
  yaw=0 = "frente hacia -v" (hacia el corredor/fachada). Para los objetos que van contra una pared (armario,
  escoba) la pared queda DETRÁS, en +v: armario → su espalda en v+0.90; escoba → el palo se apoya en v≈+0.55
  (coloca el ancla a ≈0.6 de la pared).
* Todo anclado; nombres en español; sin MeshId/Texturas/Decals/Unions. Las hojas de la palma usan SpecialMesh
  de tipo esfera (sin MeshId, igual que la 'Palma_y_maceta' original) para verse como elipsoides planos.
* SurfaceGui: el índice de cara es intrínseco del part, así que se pide SIEMPRE con face_toward(0, dir_LOCAL,
  pitch=...) (dirección en el marco local del componente, sin el yaw); el part ya lleva yaw=yaw+... y la cara
  gira con él. Comprobado numéricamente para yaw 0/90/180 (tools/check_misc.py).
* Maceta: por defecto blanca como el modelo del piso superior; en la foto 2 la real es de barro → MACETA_TERRACOTA.
"""
import math
import numpy as np
from build import Ctx, FACE, face_toward, FONT_GOTHAM, FONT_SOURCE, FONT_FREDOKA, FONT_PERMANENT
from preview import render_ctx

SRC_RBXM = '/root/.claude/uploads/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/159d5810-Donde_pondras_los_salones_faltantes.rbxm'
_SRC_CACHE = {}

# ---------------------------------------------------------------- colores (de referencias y fotos)
BLANCO_PLASTICO = (230, 229, 217)      # PapeleraBlanca
BORDE_PAPELERA = (213, 212, 199)       # Aro_Papelera
NEGRO_BOLSA = (24, 24, 27)
VERDE_ETIQUETA = (48, 124, 83)         # Etiqueta_Papelera 'LIMPIO'
GRIS_ARMARIO = (150, 152, 156)
GRIS_ARMARIO_PUERTA = (160, 162, 166)
GRIS_ARMARIO_OSCURO = (70, 72, 76)
METAL_OSCURO = (40, 42, 44)
LATON = (196, 160, 72)
CARTON = (186, 152, 108)
MADERA_PALO = (214, 164, 80)
CERDAS = (206, 176, 98)
AZUL_PLASTICO = (30, 80, 180)
MACETA_BLANCA = (240, 241, 232)        # Faceta_maceta_blanca (modelo del piso superior)
MACETA_TERRACOTA = (150, 78, 52)       # maceta de barro real de la foto 2 (acera del salón 'CUARTO')
TIERRA = (72, 60, 40)
TRONCO_BAJO = (89, 88, 46)
TRONCO_ALTO = (104, 112, 47)
VERDES = [(39, 70, 31), (65, 101, 43), (49, 82, 39)]
NARANJA_MARCO = (201, 112, 60)
VIDRIO = (233, 235, 237)
CEMENTO_CLARO = (200, 200, 196)
BLANCO_DISPENSADOR = (236, 236, 230)
AZUL_BOTELLON = (120, 175, 225)
AMARILLO_COL = (252, 209, 22)
AZUL_COL = (16, 60, 170)
ROJO_COL = (206, 17, 38)


# ---------------------------------------------------------------- helpers geométricos
def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del componente → coordenadas (u,y,v) del edificio, girado yaw grados."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def _caja(ctx, parent, nombre, u, y, v, yaw, lc, size, yaw_local=0.0, **kw):
    """Box en coordenadas locales del componente (lc = centro local)."""
    return ctx.box(nombre, place(u, y, v, yaw, *lc), size, yaw=yaw + yaw_local, parent=parent, **kw)


def _cil_y(ctx, parent, nombre, u, y, v, yaw, lc, length, diam, **kw):
    """Cilindro vertical centrado en el punto local lc."""
    return ctx.cylinder(nombre, place(u, y, v, yaw, *lc), length, diam, axis='y', yaw=yaw, parent=parent, **kw)


def _dir_ab(a, b):
    """Longitud, yaw local (psi) y elevación (roll) para que el eje de ancho vaya de a hacia b."""
    L = math.dist(a, b)
    d = ((b[0] - a[0]) / L, (b[1] - a[1]) / L, (b[2] - a[2]) / L)
    psi = math.degrees(math.atan2(d[2], d[0]))
    r = math.degrees(math.asin(max(-1.0, min(1.0, d[1]))))
    return L, psi, r


def _tubo(ctx, parent, nombre, u, y, v, yaw, a, b, diam, **kw):
    """Cilindro entre dos puntos locales a y b (palos, nervios, astas)."""
    L, psi, r = _dir_ab(a, b)
    c = place(u, y, v, yaw, *(((a[i] + b[i]) / 2) for i in range(3)))
    return ctx.part(nombre, c, (L, diam, diam), yaw=yaw + psi, roll=r, shape='Cylinder', parent=parent, **kw)


def _tabla(ctx, parent, nombre, u, y, v, yaw, a, b, grosor, ancho, plano='horizontal', **kw):
    """Tabla plana cuyo largo va de a a b. plano='horizontal': el ancho queda horizontal (hoja de palma);
    plano='vertical': el ancho queda en el plano vertical que contiene a-b (tela de una bandera)."""
    L, psi, r = _dir_ab(a, b)
    c = place(u, y, v, yaw, *(((a[i] + b[i]) / 2) for i in range(3)))
    size = (L, grosor, ancho) if plano == 'horizontal' else (L, ancho, grosor)
    return ctx.part(nombre, c, size, yaw=yaw + psi, roll=r, parent=parent, **kw)


def _malla_elipsoide(ctx, idx):
    """SpecialMesh tipo esfera (MeshType=3, sin MeshId): el bloque se ve como un elipsoide (0 parts)."""
    return ctx._add('SpecialMesh', {'Name': (0x01, b'Malla'), 'MeshType': (0x12, 3),
                                    'Offset': (0x0E, (0.0, 0.0, 0.0)), 'Scale': (0x0E, (1.0, 1.0, 1.0)),
                                    'VertexColor': (0x0E, (1.0, 1.0, 1.0))}, idx)


def _oscuro(col, f=0.78):
    return tuple(int(c * f) for c in col)


# ---------------------------------------------------------------- 1) PAPELERA
def build_papelera(ctx, parent, u, y, v, color=BLANCO_PLASTICO, con_bolsa=True):
    """Papelera plástica blanca (cilindro 1.5 de diámetro x 1.5 de alto con aro superior), bolsa negra asomando
    por el borde y etiqueta verde 'LIMPIO' al frente (-v). (u,y,v) = centro de la base en el piso. ≤ 6 parts (5).
    Referencias 'Papelera' (1.59 x 1.53) y 'PapeleraBlanca' (1.31 x 1.49)."""
    m = ctx.model('Papelera', parent=parent)
    D, H = 1.5, 1.5
    ctx.cylinder('Cuerpo_Papelera', (u, y + (H - 0.02) / 2, v), H - 0.02, D, axis='y', color=color,
                 material='SmoothPlastic', parent=m)
    ctx.cylinder('Aro_Papelera', (u, y + H - 0.05, v), 0.10, D + 0.12, axis='y', color=BORDE_PAPELERA,
                 material='SmoothPlastic', parent=m)
    if con_bolsa:
        ctx.cylinder('Bolsa_Interior', (u, y + H, v), 0.16, D - 0.14, axis='y', color=NEGRO_BOLSA,
                     material='SmoothPlastic', parent=m)
        # pliegue corto (0.30) de la bolsa que cuelga por fuera del aro: arriba sale fuera del aro (r 0.81) y
        # abajo toca el cuerpo (r 0.75) -> placa inclinada 17° (pitch>0 = borde superior hacia -v)
        ctx.box('Bolsa_Colgante', (u, y + H - 0.13, v - D / 2 - 0.077), (0.85, 0.30, 0.07), pitch=17,
                color=NEGRO_BOLSA, material='SmoothPlastic', cancollide=False, parent=m)
    et = ctx.box('Etiqueta_Papelera', (u, y + 0.85, v - D / 2 + 0.03), (0.70, 0.38, 0.10), color=VERDE_ETIQUETA,
                 material='SmoothPlastic', cancollide=False, parent=m)
    ctx.label_on(et, 'LIMPIO', direction=(0, 0, -1), color=(245, 245, 240), font=FONT_GOTHAM,
                 pos=(0.06, 0, 0.18, 0), size=(0.88, 0, 0.64, 0))
    return m


# ---------------------------------------------------------------- 2) ARMARIO METÁLICO
def build_armario(ctx, parent, u, y, v, yaw=0, con_cajas=True):
    """Armario metálico escolar gris 3.5 (u) x 7.0 (y) x 1.8 (v) con zócalo, 2 puertas con rejillas de
    ventilación (Frames), manijas, candado de latón y (opcional) caja de cartón + 2 libros encima.
    (u,y,v) = centro de la base en el piso; yaw=0 → puertas hacia -v, espalda en v+0.90 (contra la pared).
    ≤ 12 parts (11 con cajas, 8 sin)."""
    m = ctx.model('Armario_Metalico', parent=parent)
    W, H, Dp = 3.5, 7.0, 1.8
    _caja(ctx, m, 'Zocalo_Armario', u, y, v, yaw, (0, 0.15, 0.03), (W - 0.2, 0.30, Dp - 0.2),
          color=GRIS_ARMARIO_OSCURO, material='Metal')
    _caja(ctx, m, 'Cuerpo_Armario', u, y, v, yaw, (0, 0.30 + (H - 0.30) / 2, 0.03), (W, H - 0.30, Dp - 0.06),
          color=GRIS_ARMARIO, material='Metal')
    vf = 0.03 - (Dp - 0.06) / 2          # cara frontal del cuerpo (-0.84)
    hp = H - 0.30 - 0.28                 # alto de las puertas (6.42)
    yp = 0.30 + 0.12 + hp / 2            # centro vertical de las puertas
    for s, lado in ((-1, 'Izq'), (1, 'Der')):
        p = _caja(ctx, m, f'Puerta_{lado}', u, y, v, yaw, (s * 0.85, yp, vf - 0.03), (1.66, hp, 0.06),
                  color=GRIS_ARMARIO_PUERTA, material='Metal')
        # cara intrínseca del part (creado con yaw=yaw): se pide con yaw=0 y la dirección LOCAL del componente
        g = ctx.surface_gui(p, face_toward(0, (0, 0, -1)), pixels_per_stud=50)
        for k in range(3):   # rejillas de ventilación arriba y abajo (0 parts)
            ctx.frame(g, pos=(0.22, 0, 0.06 + 0.035 * k, 0), size=(0.56, 0, 0.012, 0), color=(92, 94, 98), name='Rejilla_Sup')
            ctx.frame(g, pos=(0.22, 0, 0.86 + 0.035 * k, 0), size=(0.56, 0, 0.012, 0), color=(92, 94, 98), name='Rejilla_Inf')
        ctx.frame(g, pos=(0.0, 0, 0.0, 0), size=(1.0, 0, 1.0, 0), color=(120, 122, 126), transparency=1.0, name='Marco')
        _caja(ctx, m, f'Manija_{lado}', u, y, v, yaw, (s * 0.22, 3.40, vf - 0.06 - 0.05), (0.10, 0.70, 0.10),
              color=METAL_OSCURO, material='Metal', cancollide=False)
    # candado colgado entre las dos manijas
    _caja(ctx, m, 'Candado_Arco', u, y, v, yaw, (0, 3.62, vf - 0.06 - 0.07), (0.26, 0.24, 0.07),
          color=(170, 172, 175), material='Metal', cancollide=False)
    _caja(ctx, m, 'Candado_Cuerpo', u, y, v, yaw, (0, 3.34, vf - 0.06 - 0.10), (0.34, 0.34, 0.16),
          color=LATON, material='Metal', cancollide=False)
    if con_cajas:
        cj = _caja(ctx, m, 'Caja_Carton', u, y, v, yaw, (-0.72, H + 0.50, 0.05), (1.5, 1.0, 1.3),
                   yaw_local=-5, color=CARTON, material='Cardboard')
        g = ctx.surface_gui(cj, face_toward(0, (0, 1, 0)), pixels_per_stud=50)
        ctx.frame(g, pos=(0.0, 0, 0.44, 0), size=(1.0, 0, 0.12, 0), color=(160, 128, 88), name='Cinta')      # cinta
        ctx.frame(g, pos=(0.0, 0, 0.495, 0), size=(1.0, 0, 0.01, 0), color=(120, 92, 60), name='Ranura')
        _caja(ctx, m, 'Libro_Encima_1', u, y, v, yaw, (0.95, H + 0.10, 0.08), (1.3, 0.20, 1.0),
              yaw_local=6, color=(128, 40, 40), material='SmoothPlastic')
        _caja(ctx, m, 'Libro_Encima_2', u, y, v, yaw, (0.98, H + 0.30, 0.04), (1.2, 0.20, 0.95),
              yaw_local=-4, color=(40, 70, 140), material='SmoothPlastic')
    return m


# ---------------------------------------------------------------- 3) ESCOBA + RECOGEDOR
def build_escoba(ctx, parent, u, y, v, yaw=0):
    """Escoba apoyada en una pared (palo de madera inclinado + cerdas de paja con banda roja en Frames) y un
    recogedor plástico azul de mango largo a su derecha (+u). (u,y,v) = centro de la base de las cerdas en el
    piso; yaw=0 → la pared está DETRÁS (+v): el palo se apoya en v≈+0.55, así que el ancla va a ≈0.6 de la
    pared. ≤ 4 parts (4)."""
    m = ctx.model('Escoba_y_Recogedor', parent=parent)
    # cerdas: bloque vertical ligeramente inclinado siguiendo el palo
    c = _caja(ctx, m, 'Cerdas_Escoba', u, y, v, yaw, (0, 0.50, -0.22), (1.15, 0.95, 0.30), pitch=-8,
              color=CERDAS, material='Fabric', cancollide=False)
    for dirn in ((0, 0, -1), (0, 0, 1)):
        g = ctx.surface_gui(c, face_toward(0, dirn, pitch=-8), pixels_per_stud=60)   # cara intrínseca (dir. local)
        ctx.frame(g, pos=(0, 0, 0.0, 0), size=(1, 0, 0.22, 0), color=(176, 36, 36), name='Banda_Roja')
        for k in range(11):   # hebras (0 parts)
            ctx.frame(g, pos=(0.03 + 0.088 * k, 0, 0.22, 0), size=(0.012, 0, 0.78, 0), color=(168, 140, 70), name='Hebra')
    _tubo(ctx, m, 'Palo_Escoba', u, y, v, yaw, (0, 0.92, -0.26), (0, 5.40, 0.52), 0.12,
          color=MADERA_PALO, material='Wood', cancollide=False)
    # recogedor: pala (cuña con el labio hacia -v) + mango apoyado en la pared
    # recogedor a +u de las cerdas (cerdas hasta lu=0.575; pala desde lu=0.65) sin penetrarlas
    ctx.wedge('Pala_Recogedor', place(u, y, v, yaw, 1.20, 0.175, -0.20), (1.1, 0.35, 0.9), yaw=yaw,
              color=AZUL_PLASTICO, material='SmoothPlastic', cancollide=False, parent=m)
    _tubo(ctx, m, 'Mango_Recogedor', u, y, v, yaw, (1.20, 0.32, 0.18), (1.20, 2.95, 0.52), 0.10,
          color=AZUL_PLASTICO, material='SmoothPlastic', cancollide=False)
    return m


# ---------------------------------------------------------------- 4) MACETA CON PALMA
def _src():
    if 'dom' not in _SRC_CACHE:
        from rbxm import read_rbxm
        _SRC_CACHE['dom'] = read_rbxm(SRC_RBXM)
    return _SRC_CACHE['dom']


def build_maceta_palma(ctx, parent, u, y, v, clonar=False, color_maceta=MACETA_BLANCA, n_frondas=9, semilla=3):
    """Maceta (cilindro 2.2 de diámetro x 1.9 de alto con borde) con tierra, tronco en dos tramos y palma de
    n_frondas frondas (cada una = nervio + hoja interior ascendente + hoja exterior que cae; hojas = tablas
    delgadas con SpecialMesh esfera → elipsoides) más 2 brotes verticales y el cogollo; copa baja y tupida
    (≈ 5.5 de alto total, como la 'Palma_y_maceta' del piso superior). (u,y,v) = centro de la base de la maceta
    en el piso. ≤ 45 parts (3·n_frondas + 8: 35 con 9 frondas, 32 con 8).
    color_maceta: por defecto blanco (240,241,232) como la 'Palma_y_maceta' del piso superior; en la foto 2 la
    maceta real de la acera es de barro/terracota → usa color_maceta=MACETA_TERRACOTA = (150,78,52) (material
    Concrete en ambos casos). La tierra queda a ras del borde (sobresale 0.01 para que se vea sin z-fighting).
    clonar=True: en vez de construirla, clona la 'Palma_y_maceta' original del piso superior (75 parts, con sus
    SpecialMesh y SurfaceGui) trasladada para que la base de su maceta quede en (u,y,v)."""
    if clonar:
        src = _src()
        I = src['insts']
        ref = [r for r, i in I.items() if i['cls'] == 'Model' and i['props'].get('Name', (0, b''))[1] == b'Palma_y_maceta'][0]
        from build import part_aabb_local, world_to_local
        los, piv = [], None
        for k in I[ref]['children']:
            p = I[k]['props']
            if 'CFrame' in p and 'size' in p:
                lo, hi = part_aabb_local(p['CFrame'][1], p['size'][1])
                los.append(lo)
                if p['Name'][1] == b'Tierra_maceta':
                    piv = world_to_local(p['CFrame'][1][0])
        ymin = float(np.min(los, axis=0)[1])
        return ctx.clone(src, ref, parent=parent, du=u - piv[0], dy=y - ymin, dv=v - piv[2], rename='Maceta_Palma_Clon')

    m = ctx.model('Maceta_Palma', parent=parent)
    D, H = 2.2, 1.9
    ctx.cylinder('Maceta_Cuerpo', (u, y + H / 2, v), H, D, axis='y', color=color_maceta, material='Concrete', parent=m)
    ctx.cylinder('Maceta_Borde', (u, y + H - 0.10, v), 0.20, D + 0.20, axis='y', color=_oscuro(color_maceta, 0.97),
                 material='Concrete', parent=m)
    # tierra a ras del borde: y+H-0.09..y+H+0.01 (si quedara del todo bajo el borde no se vería: la maceta es maciza)
    ctx.cylinder('Tierra_Maceta', (u, y + H - 0.04, v), 0.10, D - 0.25, axis='y', color=TIERRA, material='Ground', parent=m)
    # tronco en dos tramos, ligeramente inclinado
    c0 = (0.00, H - 0.05, 0.00)
    c1 = (0.10, 3.30, 0.04)
    cc = (0.20, 4.45, 0.10)        # cogollo / nacimiento de las frondas (copa baja)
    _tubo(ctx, m, 'Tronco_Inferior', u, y, v, 0, c0, c1, 0.30, color=TRONCO_BAJO, material='Wood')
    _tubo(ctx, m, 'Tronco_Superior', u, y, v, 0, (c1[0], c1[1] - 0.10, c1[2]), cc, 0.22, color=TRONCO_ALTO, material='Wood')
    ctx.ball('Cogollo', place(u, y, v, 0, *cc), 0.48, color=VERDES[2], material='SmoothPlastic', cancollide=False, parent=m)
    # frondas
    rng = np.random.RandomState(semilla)
    for i in range(n_frondas):
        th = math.radians(i * 360.0 / n_frondas + 20 + rng.uniform(-10, 10))
        e1 = math.radians(rng.uniform(22, 36))
        e2 = math.radians(rng.uniform(-28, -12))
        L1 = rng.uniform(1.30, 1.55)
        L2 = rng.uniform(1.15, 1.40)
        h = (math.cos(th), math.sin(th))
        d1 = (h[0] * math.cos(e1), math.sin(e1), h[1] * math.cos(e1))
        d2 = (h[0] * math.cos(e2), math.sin(e2), h[1] * math.cos(e2))
        p1 = tuple(cc[k] + d1[k] * L1 for k in range(3))
        p2 = tuple(p1[k] + d2[k] * L2 for k in range(3))
        col_a = VERDES[i % 3]
        col_b = VERDES[(i + 1) % 3]
        _tubo(ctx, m, f'Nervio_Fronda_{i + 1}', u, y, v, 0, cc, tuple(p1[k] + d1[k] * 0.15 for k in range(3)), 0.07,
              color=col_b, material='SmoothPlastic', cancollide=False)
        a = tuple(cc[k] + d1[k] * 0.25 for k in range(3))
        b = tuple(p1[k] + d1[k] * 0.15 for k in range(3))
        hi = _tabla(ctx, m, f'Hoja_Interior_{i + 1}', u, y, v, 0, a, b, 0.05, 0.85,
                    color=col_a, material='SmoothPlastic', cancollide=False)
        _malla_elipsoide(ctx, hi)
        a2 = tuple(p1[k] - d2[k] * 0.25 for k in range(3))
        he = _tabla(ctx, m, f'Hoja_Exterior_{i + 1}', u, y, v, 0, a2, p2, 0.04, 0.60,
                    color=col_b, material='SmoothPlastic', cancollide=False)
        _malla_elipsoide(ctx, he)
    # brotes nuevos, casi verticales
    for j, (ang, el) in enumerate(((35, 72), (200, 66))):
        th, e = math.radians(ang), math.radians(el)
        b = (cc[0] + math.cos(th) * math.cos(e) * 1.15, cc[1] + math.sin(e) * 1.15, cc[2] + math.sin(th) * math.cos(e) * 1.15)
        hb = _tabla(ctx, m, f'Brote_{j + 1}', u, y, v, 0, cc, b, 0.05, 0.42, color=VERDES[1], material='SmoothPlastic', cancollide=False)
        _malla_elipsoide(ctx, hb)
    return m


# ---------------------------------------------------------------- 5) VENTANA INTERIOR
def build_ventana_interior(ctx, parent, u, y, v, ancho=8.3, alto=5.7, panos=3):
    """'Vestido' interior de una ventana existente, pegado a la cara INTERIOR del muro de fachada.
    (u,y,v) = centro de la ventana con v = cara interior del muro (1.40). Marco naranja de 4 perfiles
    0.45 x 0.30 (v..v+0.30), parteluces 0.35 x 0.22 (v+0.05..v+0.27), vidrio claro 0.10 (v..v+0.10,
    transparencia 0.35) y repisa/alféizar de cemento (ancho+0.4 x 0.2 x 0.5) bajo el marco (v..v+0.50).
    Igual que 'Aula_1' del piso superior pero mirando al interior. panos debe ser 2 o 3 (assert): parts = 5 + panos
    → 7 u 8 (≤ 8)."""
    assert 2 <= panos <= 3, f'panos debe ser 2 o 3 (presupuesto ≤ 8 parts), recibido {panos}'
    m = ctx.model('Ventana_Interior', parent=parent)
    P, T, PL, TL = 0.45, 0.30, 0.35, 0.22
    vm = v + T / 2
    ctx.box('Marco_Izq', (u - ancho / 2 + P / 2, y, vm), (P, alto, T), color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Marco_Der', (u + ancho / 2 - P / 2, y, vm), (P, alto, T), color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Marco_Sup', (u, y + alto / 2 - P / 2, vm), (ancho, P, T), color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Marco_Inf', (u, y - alto / 2 + P / 2, vm), (ancho, P, T), color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    luz = ancho - 2 * P
    for k in range(1, panos):
        ctx.box(f'Parteluz_{k}', (u - ancho / 2 + P + luz * k / panos, y, v + 0.05 + TL / 2), (PL, alto - 2 * P, TL),
                color=NARANJA_MARCO, material='SmoothPlastic', parent=m)
    ctx.box('Vidrio_Interior', (u, y, v + 0.05), (luz, alto - 2 * P, 0.10), color=VIDRIO, material='SmoothPlastic',
            transparency=0.35, reflectance=0.08, parent=m)
    ctx.box('Repisa_Alfeizar', (u, y - alto / 2 - 0.10, v + 0.25), (ancho + 0.4, 0.20, 0.50), color=CEMENTO_CLARO,
            material='Concrete', parent=m)
    return m


# ---------------------------------------------------------------- 6) BOTELLÓN / DISPENSADOR DE AGUA
def build_botellon_agua(ctx, parent, u, y, v):
    """Dispensador de agua blanco 1.4 x 3.6 x 1.4 con bandeja de goteo, dos grifos (azul frío / rojo caliente)
    hacia -v y botellón azul translúcido (cuerpo + hombro) encima. (u,y,v) = centro de la base en el piso;
    frente hacia -v. ≤ 6 parts (6)."""
    m = ctx.model('Botellon_Agua', parent=parent)
    W, H = 1.4, 3.6
    cu = ctx.box('Cuerpo_Dispensador', (u, y + H / 2, v), (W, H, W), color=BLANCO_DISPENSADOR, material='SmoothPlastic', parent=m)
    g = ctx.surface_gui(cu, face_toward(0, (0, 0, -1)), pixels_per_stud=60)
    ctx.frame(g, pos=(0.10, 0, 0.14, 0), size=(0.80, 0, 0.26, 0), color=(222, 222, 214), name='Panel_Frontal', corner=(0.08, 0))
    ctx.frame(g, pos=(0.12, 0, 0.44, 0), size=(0.76, 0, 0.09, 0), color=(60, 62, 66), name='Fondo_Bandeja')
    ctx.text(g, 'AGUA', pos=(0.2, 0, 0.60, 0), size=(0.6, 0, 0.10, 0), color=(120, 160, 210), font=FONT_GOTHAM)
    ctx.frame(g, pos=(0.30, 0, 0.0, 0), size=(0.40, 0, 0.06, 0), color=(200, 200, 196), name='Collar')
    ctx.box('Bandeja_Goteo', (u, y + 2.05, v - W / 2 - 0.17), (1.0, 0.10, 0.36), color=(58, 60, 64), material='SmoothPlastic',
            cancollide=False, parent=m)
    ctx.box('Grifo_Frio', (u - 0.30, y + 2.62, v - W / 2 - 0.14), (0.22, 0.32, 0.30), color=(30, 90, 200),
            material='SmoothPlastic', cancollide=False, parent=m)
    ctx.box('Grifo_Caliente', (u + 0.30, y + 2.62, v - W / 2 - 0.14), (0.22, 0.32, 0.30), color=(200, 40, 40),
            material='SmoothPlastic', cancollide=False, parent=m)
    ctx.cylinder('Botellon_Hombro', (u, y + H + 0.14, v), 0.28, 0.86, axis='y', color=AZUL_BOTELLON, material='SmoothPlastic',
                 transparency=0.35, reflectance=0.05, parent=m)
    ctx.cylinder('Botellon_Cuerpo', (u, y + H + 0.28 + 0.78, v), 1.56, 1.12, axis='y', color=AZUL_BOTELLON, material='SmoothPlastic',
                 transparency=0.35, reflectance=0.05, parent=m)
    return m


# ---------------------------------------------------------------- 7) MOCHILA
def build_mochila(ctx, parent, u, y, v, yaw=0, color=(200, 40, 40)):
    """Mochila escolar de pie en el piso, ligeramente reclinada hacia atrás: cuerpo de tela, bolsillo frontal,
    tirantes (espalda) y asa superior; cremalleras en Frames. (u,y,v) = centro de la base; yaw=0 → bolsillo
    frontal hacia -v, tirantes hacia +v. ≤ 4 parts (4)."""
    m = ctx.model('Mochila', parent=parent)
    cuerpo = _caja(ctx, m, 'Cuerpo_Mochila', u, y, v, yaw, (0, 0.89, 0.05), (1.3, 1.65, 0.75), pitch=-7,
                   color=color, material='Fabric', cancollide=False)
    # caras intrínsecas de los parts (creados con yaw=yaw): face_toward con yaw=0 y la dirección LOCAL
    g = ctx.surface_gui(cuerpo, face_toward(0, (0, 0, -1), pitch=-7), pixels_per_stud=60)
    ctx.frame(g, pos=(0.08, 0, 0.16, 0), size=(0.84, 0, 0.025, 0), color=(230, 230, 230), name='Cremallera_Sup')
    ctx.frame(g, pos=(0.42, 0, 0.05, 0), size=(0.16, 0, 0.09, 0), color=_oscuro(color, 0.6), name='Logo', corner=(0.3, 0))
    bols = _caja(ctx, m, 'Bolsillo_Frontal', u, y, v, yaw, (0, 0.47, 0.05 - 0.375 - 0.13), (1.0, 0.78, 0.28), pitch=-7,
                 color=_oscuro(color, 0.8), material='Fabric', cancollide=False)
    g = ctx.surface_gui(bols, face_toward(0, (0, 0, -1), pitch=-7), pixels_per_stud=60)
    ctx.frame(g, pos=(0.08, 0, 0.10, 0), size=(0.84, 0, 0.03, 0), color=(230, 230, 230), name='Cremallera_Bolsillo')
    tir = _caja(ctx, m, 'Tirantes', u, y, v, yaw, (0, 0.95, 0.05 + 0.375 + 0.05), (1.05, 1.25, 0.12), pitch=-7,
                color=(42, 42, 46), material='Fabric', cancollide=False)
    g = ctx.surface_gui(tir, face_toward(0, (0, 0, 1), pitch=-7), pixels_per_stud=60)
    ctx.frame(g, pos=(0.40, 0, 0.0, 0), size=(0.20, 0, 1.0, 0), color=_oscuro(color, 0.85), name='Separacion_Tirantes')
    _caja(ctx, m, 'Asa_Superior', u, y, v, yaw, (0, 1.72, 0.12), (0.5, 0.14, 0.22), color=(42, 42, 46),
          material='Fabric', cancollide=False)
    return m


# ---------------------------------------------------------------- 8) PILA DE LIBROS
def build_libros(ctx, parent, u, y, v, yaw=0, n=4, titulo='MATEMÁTICAS'):
    """Pila de n (3-4) libros/cuadernos de colores, cada uno algo girado, para encima de mesas.
    (u,y,v) = centro de la base de la pila (y = cara superior de la mesa); yaw=0 → lomos hacia -u, cantos
    hacia +u (Frames claros = hojas). El libro de arriba lleva título en la tapa. ≤ 4 parts (n)."""
    m = ctx.model('Pila_Libros', parent=parent)
    libros = [((1.35, 0.20, 1.00), (150, 42, 40), -6), ((1.25, 0.16, 0.95), (40, 70, 140), 5),
              ((1.30, 0.22, 1.05), (46, 120, 70), -3), ((1.15, 0.14, 0.90), (220, 180, 60), 9)]
    n = max(3, min(4, n))
    yy = 0.0
    for k in range(n):
        size, col, yl = libros[k]
        yy += size[1] / 2
        lb = _caja(ctx, m, f'Libro_{k + 1}', u, y, v, yaw, (0.03 * k, yy, -0.02 * k), size, yaw_local=yl,
                   color=col, material='SmoothPlastic', cancollide=False)
        for dirn in ((1, 0, 0), (0, 0, -1), (0, 0, 1)):   # hojas (canto claro) en 3 caras (0 parts)
            g = ctx.surface_gui(lb, face_toward(0, dirn), pixels_per_stud=80)   # cara intrínseca del libro
            ctx.frame(g, pos=(0.0, 0, 0.12, 0), size=(1.0, 0, 0.76, 0), color=(236, 232, 220), name='Hojas')
        yy += size[1] / 2
        if k == n - 1:
            ctx.label_on(lb, titulo, direction=(0, 1, 0), yaw=0, color=(250, 250, 245), font=FONT_FREDOKA,
                         stroke=(40, 40, 40), pos=(0.08, 0, 0.30, 0), size=(0.84, 0, 0.26, 0))
    return m


# ---------------------------------------------------------------- 9) BANDERA DE COLOMBIA
def build_bandera_colombia(ctx, parent, u, y, v, yaw=0):
    """Banderín de Colombia: soporte metálico en la pared, asta de madera inclinada 35° que sale de la pared
    hacia el salón y tres franjas (amarillo 1/2, azul 1/4, rojo 1/4) colgando del tramo alto del asta, con el
    amarillo pegado al asta. (u,y,v) = punto de anclaje del soporte EN la pared; yaw=0 → pared hacia +v (el
    asta sale hacia -v). ≤ 5 parts (5)."""
    m = ctx.model('Bandera_Colombia', parent=parent)
    # soporte 0.30 x 0.55 x 0.30 pegado a la pared (v -0.30..0, y -0.355..0.195); el asta nace DENTRO del
    # soporte, casi en la pared (a), y sale por su cara frontal (v=-0.30) a y≈+0.07
    _caja(ctx, m, 'Soporte_Pared', u, y, v, yaw, (0, -0.08, -0.15), (0.30, 0.55, 0.30), color=METAL_OSCURO, material='Metal')
    e = math.radians(55)                       # elevación del asta (35° respecto a la pared)
    s = (0.0, math.sin(e), -math.cos(e))       # dirección del asta (sube y se aleja de la pared)
    f = (0.0, -math.cos(e), -math.sin(e))      # perpendicular al asta, hacia abajo-afuera (caída de la tela)
    a = (0.0, -0.30, -0.04)
    L = 3.2
    b = tuple(a[k] + s[k] * L for k in range(3))
    _tubo(ctx, m, 'Asta_Bandera', u, y, v, yaw, a, b, 0.10, color=MADERA_PALO, material='Wood', cancollide=False)
    hoist0, hoist1 = 0.45 * L, 0.98 * L        # tramo del asta que lleva la tela
    pa = tuple(a[k] + s[k] * hoist0 for k in range(3))
    pb = tuple(a[k] + s[k] * hoist1 for k in range(3))
    anchos = ((0.56, AMARILLO_COL, 'Franja_Amarilla'), (0.28, AZUL_COL, 'Franja_Azul'), (0.28, ROJO_COL, 'Franja_Roja'))
    off = 0.06
    for w, col, nombre in anchos:
        ca = tuple(pa[k] + f[k] * (off + w / 2) for k in range(3))
        cb = tuple(pb[k] + f[k] * (off + w / 2) for k in range(3))
        _tabla(ctx, m, nombre, u, y, v, yaw, ca, cb, 0.03, w, plano='vertical', color=col, material='Fabric', cancollide=False)
        off += w
    return m


# ---------------------------------------------------------------- selftest
LIMITES = {'papelera': 6, 'armario': 12, 'escoba': 4, 'maceta': 45, 'ventana': 8, 'botellon': 6, 'mochila': 4,
           'libros': 4, 'bandera': 5}


def selftest(con_clon=True):
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Misc')
    Y = 0.42
    casos = [
        ('papelera_0', lambda: build_papelera(ctx, raiz, 0, Y, 0)),
        ('armario_0', lambda: build_armario(ctx, raiz, 4, Y, 0, yaw=0)),
        ('escoba_0', lambda: build_escoba(ctx, raiz, 8.5, Y, 0, yaw=0)),
        ('maceta_0', lambda: build_maceta_palma(ctx, raiz, 14, Y, 0)),
        ('ventana_0', lambda: build_ventana_interior(ctx, raiz, 24.5, 6.2 + 5.7 / 2, 1.40, ancho=8.3, alto=5.7, panos=3)),
        ('botellon_0', lambda: build_botellon_agua(ctx, raiz, 31.5, Y, 0)),
        ('mochila_0', lambda: build_mochila(ctx, raiz, 34.5, Y, 0, yaw=0)),
        ('libros_0', lambda: build_libros(ctx, raiz, 37.5, Y, 0, yaw=0)),
        ('bandera_0', lambda: build_bandera_colombia(ctx, raiz, 40.5, Y + 8.6, 1.40, yaw=0)),
        ('armario_90', lambda: build_armario(ctx, raiz, 46, Y, 0, yaw=90)),
        ('escoba_90', lambda: build_escoba(ctx, raiz, 50, Y, 0, yaw=90)),
        ('mochila_90', lambda: build_mochila(ctx, raiz, 53, Y, 0, yaw=90, color=(30, 60, 160))),
        ('libros_90', lambda: build_libros(ctx, raiz, 56, Y, 0, yaw=90, n=3)),
        ('bandera_90', lambda: build_bandera_colombia(ctx, raiz, 59, Y + 8.6, 0, yaw=90)),
        ('ventana_2panos', lambda: build_ventana_interior(ctx, raiz, 65, 6.2 + 5.7 / 2, 1.40, ancho=4.4, alto=5.7, panos=2)),
        ('maceta_terracota', lambda: build_maceta_palma(ctx, raiz, 78, Y, 0, color_maceta=MACETA_TERRACOTA)),
    ]
    if con_clon:
        casos.append(('maceta_clon', lambda: build_maceta_palma(ctx, raiz, 72, Y, 0, clonar=True)))
    out = []
    for nombre, fn in casos:
        try:
            idx = fn()
        except Exception as e:  # el clon depende del rbxm original; el resto no debe fallar
            if nombre == 'maceta_clon':
                print('maceta_clon omitida:', e); continue
            raise
        n = ctx.count_parts(idx)
        lo, hi = ctx.bbox(idx)
        print(f'{nombre:16s} parts={n:2d} bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) '
              f'ext=({hi[0]-lo[0]:.2f},{hi[1]-lo[1]:.2f},{hi[2]-lo[2]:.2f})')
        out.append((nombre, idx, n, lo, hi))
        render_ctx(ctx, f'../out/comp_misc_{nombre}.png', idx=idx, scale=60 if nombre != 'ventana_0' else 40)
    render_ctx(ctx, '../out/comp_misc_preview.png', idx=raiz, scale=20)
    ctx.export('../out/comp_misc_selftest.rbxm')
    for nombre, idx, n, lo, hi in out:
        if nombre == 'maceta_clon':
            continue
        assert n <= LIMITES[nombre.split('_')[0]], (nombre, n)
    return out


if __name__ == '__main__':
    selftest()
