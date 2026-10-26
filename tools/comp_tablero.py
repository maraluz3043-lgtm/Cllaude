"""comp_tablero.py — Objetos de PARED para los salones nuevos: tablero acrílico, cartelera, afiches,
reloj de pared y placa de grado (marco local u,y,v; ver API.md).

CONVENCIÓN DE COLOCACIÓN (todas las funciones de este módulo)
--------------------------------------------------------------
* (u, y) = centro del panel/objeto sobre la pared.
* v = PLANO DE LA PARED donde se cuelga el objeto (la cara de la pared). El objeto queda PEGADO a la
  pared: su dorso está exactamente en v y el cuerpo sobresale hacia la cara visible. Con yaw=0 ocupa
  v-espesor .. v (espesores: tablero 0.45 con la bandeja, cartelera 0.16, afiche 0.08, reloj 0.26, placa 0.08).
* yaw = 0   → la cara visible mira hacia -v (hacia el corredor/fachada); la pared queda detrás, hacia +v.
              Es la orientación para la pared del FONDO del salón (cara interior en v = 21.40).
  yaw = 90  → la cara visible mira hacia +u → pared que mira hacia +u (muro izquierdo del salón, cara en u = 0.2 / 35.49 / 62.0).
  yaw = 180 → la cara visible mira hacia +v → cara interior del muro de fachada (v = 1.40).
  yaw = -90 → la cara visible mira hacia -u → muro derecho del salón (cara en u = 34.89 / 58.2 / 96.68).
  Regla general: con yaw = t el vector "hacia el espectador" es (sin t, 0, -cos t); un desplazamiento
  local +lu (ancho) gira a +v con yaw = 90, igual que el convenio de la API (place()).
* Texto y dibujos = SurfaceGui + Frames/TextLabels (0 parts) en la cara visible. Todo anclado, nombres en
  español, sin meshes/texturas/unions. Los objetos delgados se crean con cancollide=False (no estorban).
* Cada build_* devuelve el índice del Model; cuenta las parts con ctx.count_parts(idx).

Presupuestos: tablero ≤ 12 (usa 11), cartelera ≤ 7 (usa 7), afiche ≤ 2 (usa 2), reloj ≤ 3 (usa 3), placa = 1.
"""
import math
from build import Ctx, FACE, face_toward, FONT_GOTHAM, FONT_SOURCE, FONT_FREDOKA, FONT_BANGERS, FONT_PERMANENT
from preview import render_ctx

# ---------------------------------------------------------------- colores (referencias del piso superior y fotos)
ALUMINIO = (152, 151, 142)          # Marco_Aluminio / Canal_Marcadores de 'Tablero_y_Decoracion'
BLANCO_ACRILICO = (242, 242, 242)
MARCADOR_ROJO = (160, 38, 36)
MARCADOR_NEGRO = (25, 27, 26)
MARCADOR_AZUL = (35, 57, 135)
BORRADOR = (70, 68, 78)
CIRCULOS = [(210, 50, 108), (215, 159, 28), (108, 154, 92), (53, 139, 177)]   # Borde_Circulos de la referencia
MADERA_ROJA = (151, 0, 0)           # marco del cuadro 'Model' del piso superior
MADERA_CLARA = (211, 190, 150)
CORCHO = (196, 158, 108)
CINTA_AMARILLA = (183, 169, 84)
HOJA_BLANCA = (250, 250, 247)
HOJA_AMARILLA = (250, 228, 120)
HOJA_ROSA = (245, 185, 205)
HOJA_CELESTE = (200, 225, 245)
MARCO_AFICHE = (118, 40, 36)        # marcos rojizos de los afiches de las fotos
MORADO = (110, 45, 140)
ROSA_FUERTE = (205, 60, 120)
NEGRO_RELOJ = (35, 35, 38)


# ---------------------------------------------------------------- helpers geométricos
def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del objeto → coordenadas (u,y,v) del edificio, girado yaw grados (convenio API)."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def dir_frente(yaw):
    """Vector local del edificio (du,dy,dv) hacia donde mira la cara visible de un objeto con ese yaw."""
    t = math.radians(yaw)
    return (math.sin(t), 0.0, -math.cos(t))


def _caja(ctx, parent, nombre, u, y, v, yaw, lc, size, roll=0.0, **kw):
    """Box en coordenadas locales del objeto (lc = centro local; lv negativo = hacia el espectador)."""
    kw.setdefault('cancollide', False)
    return ctx.box(nombre, place(u, y, v, yaw, *lc), size, yaw=yaw, roll=roll, parent=parent, **kw)


def _gui_frente(ctx, part_idx, yaw, pps, roll=0.0, yaw_extra=0.0, light=0.0):
    """SurfaceGui en la cara visible (la que mira hacia dir_frente(yaw)) de una part creada con yaw(+yaw_extra), roll."""
    return ctx.surface_gui(part_idx, face_toward(yaw + yaw_extra, dir_frente(yaw), roll=roll),
                           pixels_per_stud=pps, light_influence=light)


# ---------------------------------------------------------------- helpers de GUI (fracciones de la cara, origen arriba-izq.)
def _z(ctx, idx, z):
    ctx.insts[idx]['props']['ZIndex'] = (0x03, int(z))
    return idx


def _corner(ctx, idx, scale, offset=0):
    ctx._add('UICorner', {'Name': (0x01, b'UICorner'), 'CornerRadius': (0x06, (float(scale), int(offset)))}, idx)
    return idx


def _fr(ctx, g, fx, fy, fw, fh, color, z=1, corner=None, rot=0.0, transp=0.0, name='Frame'):
    """Frame por fracciones (fx,fy = esquina sup-izq; fw,fh = tamaño)."""
    return _z(ctx, ctx.frame(g, pos=(fx, 0, fy, 0), size=(fw, 0, fh, 0), color=color, transparency=transp,
                             corner=corner, rotation=rot, name=name), z)


def _circ(ctx, g, cx, cy, d, color, ar, z=1, name='Circulo'):
    """Círculo de diámetro d (fracción del ANCHO de la cara) centrado en (cx,cy); ar = ancho/alto de la cara."""
    return _fr(ctx, g, cx - d / 2, cy - d * ar / 2, d, d * ar, color, z=z, corner=(0.5, 0), name=name)


def _tx(ctx, g, fx, fy, fw, fh, texto, color, font=FONT_GOTHAM, z=2, stroke=None, xalign=2, yalign=1,
        rot=0.0, bg=None, name='TextLabel'):
    """TextLabel por fracciones; xalign 0=izq 1=der 2=centro (Enum.TextXAlignment); yalign 0=arriba 1=centro 2=abajo."""
    kw = {}
    if bg is not None:
        kw = {'bg_transparency': 0.0, 'bg_color': bg}
    return _z(ctx, ctx.text(g, texto, pos=(fx, 0, fy, 0), size=(fw, 0, fh, 0), color=color, font=font,
                            stroke=stroke, rotation=rot, xalign=xalign, yalign=yalign, name=name, **kw), z)


def _chinchetas(ctx, g, fx, fy, fw, fh, ar, color=(200, 40, 40), d=0.07, z=5, rot=0.0):
    """4 chinchetas (círculos) en las esquinas de un rectángulo (fracciones), girado rot grados sobre su centro."""
    t = math.radians(rot)
    mx, my = fx + fw / 2, fy + fh / 2
    for sx in (-1, 1):
        for sy in (-1, 1):
            dx, dy = sx * (fw / 2 - d * 0.9), sy * (fh / 2 - d * ar * 0.9) / ar     # en unidades de ancho
            rx, ry = dx * math.cos(t) - dy * math.sin(t), dx * math.sin(t) + dy * math.cos(t)
            _circ(ctx, g, mx + rx, my + ry * ar, d, color, ar, z=z, name='Chincheta')


# ================================================================ 1) TABLERO ACRÍLICO
def build_tablero(ctx, parent, u, y, v, yaw=0, ancho=9.6, alto=5.7, texto='Bienvenidos', circulos=True):
    """Tablero acrílico blanco con marco de aluminio y porta-marcadores. 11 parts (≤ 12).

    (u,y) = centro del tablero; v = plano de la pared; yaw=0 → cara visible hacia -v (ver cabecera).
    Ocupa (ancho x alto) sobre la pared y sobresale 0.15 (marco) / 0.45 (bandeja) hacia el espectador.
    Según 'Tablero_y_Decoracion' del piso superior: 4 perfiles de aluminio (152,151,142), bandeja inferior
    con 3 marcadores (rojo, negro, azul) y borrador, hilera de círculos de colores en el borde izquierdo
    (aquí como Frames, 0 parts). `texto` (o None) se escribe en azul "a marcador" arriba a la izquierda.
    """
    m = ctx.model('Tablero_Acrilico', parent=parent)
    P, DP = 0.12, 0.15                      # ancho y fondo de los perfiles del marco
    FW, FH = ancho - 0.10, alto - 0.10      # cara del panel (los perfiles tapan 0.07 por lado)
    panel = _caja(ctx, m, 'Tablero_Blanco', u, y, v, yaw, (0, 0, -0.05), (FW, FH, 0.10),
                  color=BLANCO_ACRILICO, material='SmoothPlastic', reflectance=0.04)
    _caja(ctx, m, 'Marco_Superior', u, y, v, yaw, (0, alto / 2 - P / 2, -DP / 2), (ancho, P, DP), color=ALUMINIO, material='Metal')
    _caja(ctx, m, 'Marco_Inferior', u, y, v, yaw, (0, -alto / 2 + P / 2, -DP / 2), (ancho, P, DP), color=ALUMINIO, material='Metal')
    _caja(ctx, m, 'Marco_Izquierdo', u, y, v, yaw, (-ancho / 2 + P / 2, 0, -DP / 2), (P, alto - 2 * P, DP), color=ALUMINIO, material='Metal')
    _caja(ctx, m, 'Marco_Derecho', u, y, v, yaw, (ancho / 2 - P / 2, 0, -DP / 2), (P, alto - 2 * P, DP), color=ALUMINIO, material='Metal')
    # bandeja porta-marcadores pegada al frente del perfil inferior: repisa + labio
    AB = ancho - 1.0
    yb = -alto / 2
    _caja(ctx, m, 'Bandeja_Marcadores', u, y, v, yaw, (0, yb + 0.03, -DP - 0.15), (AB, 0.06, 0.30), color=ALUMINIO, material='Metal')
    _caja(ctx, m, 'Bandeja_Labio', u, y, v, yaw, (0, yb + 0.09, -DP - 0.28), (AB, 0.18, 0.04), color=ALUMINIO, material='Metal')
    for k, (col, du_) in enumerate(((MARCADOR_AZUL, 2.3), (MARCADOR_ROJO, 1.7), (MARCADOR_NEGRO, 1.1))):
        ctx.cylinder(f'Marcador_{("Azul", "Rojo", "Negro")[k]}', place(u, y, v, yaw, ancho / 2 - du_, yb + 0.06 + 0.05, -DP - 0.14),
                     0.52, 0.10, axis='u', yaw=yaw, color=col, material='SmoothPlastic', parent=m, cancollide=False)
    _caja(ctx, m, 'Borrador', u, y, v, yaw, (-ancho / 2 + 1.5, yb + 0.06 + 0.07, -DP - 0.14), (0.56, 0.14, 0.26),
          color=BORRADOR, material='Fabric')
    # decoración plana (0 parts): círculos de colores en el borde izquierdo + texto a marcador
    g = _gui_frente(ctx, panel, yaw, 60, light=0.3)
    ar = FW / FH
    if circulos:
        n = max(6, int((FH - 0.8) / 0.33))
        d = 0.17 / FW
        for i in range(n):
            fy = (0.45 + (FH - 0.9) * i / (n - 1)) / FH
            _circ(ctx, g, 0.30 / FW, fy, d, CIRCULOS[i % 4], ar, name='Circulo_Decorativo')
    if texto:
        _tx(ctx, g, 0.6 / FW, 0.35 / FH, 4.6 / FW, 1.0 / FH, texto, MARCADOR_AZUL, font=FONT_PERMANENT, xalign=0, name='Texto_Marcador')
    return m


# ================================================================ 2) CARTELERA
def _hoja_horario(ctx, g, ar):
    """Diseño de hoja 'HORARIO': título + cuadrícula de 5 días x 4 bloques (0 parts)."""
    _tx(ctx, g, 0.05, 0.03, 0.9, 0.14, 'HORARIO', (30, 50, 110), font=FONT_FREDOKA, z=3)
    x0, y0, x1, y1 = 0.04, 0.19, 0.96, 0.96
    cols, rows = 6, 5
    cw, rh = (x1 - x0) / cols, (y1 - y0) / rows
    _fr(ctx, g, x0, y0, x1 - x0, rh, (190, 215, 245), z=2)                    # cabecera
    _fr(ctx, g, x0, y0, cw, y1 - y0, (235, 240, 230), z=2)                    # columna horas
    for c in range(cols + 1):
        _fr(ctx, g, x0 + c * cw - 0.004, y0, 0.008, y1 - y0, (90, 100, 130), z=3, name='Linea_V')
    for r in range(rows + 1):
        _fr(ctx, g, x0, y0 + r * rh - 0.004 * ar, x1 - x0, 0.008 * ar, (90, 100, 130), z=3, name='Linea_H')
    dias = ['', 'LUN', 'MAR', 'MIÉ', 'JUE', 'VIE']
    for c, d in enumerate(dias):
        if d:
            _tx(ctx, g, x0 + c * cw, y0, cw, rh, d, (30, 50, 110), z=4)
    horas = ['7:00', '8:30', '10:00', '11:30']
    mat = [['MAT', 'ESP', 'CIE', 'SOC', 'ING'], ['ESP', 'MAT', 'ART', 'MAT', 'CIE'],
           ['REL', 'E.F.', 'ESP', 'ING', 'MAT'], ['SOC', 'CIE', 'MAT', 'ESP', 'ÉTI']]
    for r in range(4):
        _tx(ctx, g, x0, y0 + (r + 1) * rh, cw, rh, horas[r], (60, 60, 70), z=4)
        for c in range(5):
            _tx(ctx, g, x0 + (c + 1) * cw + cw * 0.08, y0 + (r + 1) * rh + rh * 0.15, cw * 0.84, rh * 0.7,
                mat[r][c], (40, 40, 50), font=FONT_SOURCE, z=4)


def _hoja_lista(ctx, g, ar, titulo, color_titulo, lineas, colores):
    """Diseño de hoja con título y lista de renglones con viñetas de colores (0 parts)."""
    _tx(ctx, g, 0.05, 0.03, 0.9, 0.14, titulo, color_titulo, font=FONT_FREDOKA, z=3)
    _fr(ctx, g, 0.1, 0.175, 0.8, 0.012 * ar, color_titulo, z=3, name='Subrayado')
    n = len(lineas)
    y0, h = 0.22, 0.74 / max(n, 1)
    for i, l in enumerate(lineas):
        cy = y0 + h * (i + 0.5)
        _circ(ctx, g, 0.11, cy, 0.09, colores[i % len(colores)], ar, z=3, name='Vineta')
        _tx(ctx, g, 0.20, cy - h * 0.38, 0.76, h * 0.76, l, (45, 40, 50), font=FONT_GOTHAM, z=4, xalign=0)


_PALETA_VINETAS = [(230, 70, 70), (245, 150, 40), (90, 180, 90), (60, 130, 220), (150, 80, 190), (230, 190, 40)]
_LISTAS = {
    'VALORES': (['Respeto', 'Honestidad', 'Responsabilidad', 'Solidaridad', 'Tolerancia', 'Amor'], (180, 30, 40)),
    'CUMPLEAÑOS': (['Ana 12 mar', 'Luis 3 abr', 'Sofía 21 may', 'Juan 8 jun', 'Mía 30 jul'], MORADO),
    'NORMAS': (['Escuchar', 'Levantar la mano', 'Respetar turnos', 'Cuidar el salón'], (30, 90, 170)),
}


def _diseno_hoja(ctx, g, ar, titulo):
    """Elige el diseño de una hoja según su título (HORARIO → cuadrícula; otro → lista)."""
    t = titulo.upper()
    if 'HORARIO' in t:
        _hoja_horario(ctx, g, ar)
    else:
        lineas, col = _LISTAS.get(t, (['Lectura', 'Juego', 'Tarea', 'Aseo'], (30, 90, 170)))
        _hoja_lista(ctx, g, ar, titulo, col, lineas, _PALETA_VINETAS)


def build_cartelera(ctx, parent, u, y, v, yaw=0, ancho=6, alto=4, titulo='CARTELERA',
                    hojas=('HORARIO', 'VALORES', 'CUMPLEAÑOS'), color_marco=MADERA_ROJA):
    """Cartelera de corcho con marco de madera (rojo como el cuadro 'Model' del piso superior) y hojas de
    colores con chinchetas. 7 parts (≤ 7): fondo de corcho + 4 perfiles + 2 hojas (parts de 0.02).

    (u,y) = centro; v = plano de la pared; yaw=0 → cara visible hacia -v. Sobresale 0.16 (marco), 0.10 (hojas).
    `titulo` va en una franja azul arriba (TextLabel). `hojas` = 2 o 3 títulos: las dos primeras son parts
    delgadas (blanca 'HORARIO' con cuadrícula, amarilla con lista); la tercera es un papel rosa dibujado con
    Frames sobre el corcho (0 parts). Diseño según el título: 'HORARIO' → cuadrícula; 'VALORES', 'CUMPLEAÑOS',
    'NORMAS' → listas predefinidas; otro título → lista genérica.
    """
    m = ctx.model('Cartelera', parent=parent)
    P, DP = 0.22, 0.16
    FW, FH = ancho - 0.10, alto - 0.10
    fondo = _caja(ctx, m, 'Fondo_Corcho', u, y, v, yaw, (0, 0, -0.04), (FW, FH, 0.08), color=CORCHO, material='Sand')
    _caja(ctx, m, 'Marco_Superior', u, y, v, yaw, (0, alto / 2 - P / 2, -DP / 2), (ancho, P, DP), color=color_marco, material='Wood')
    _caja(ctx, m, 'Marco_Inferior', u, y, v, yaw, (0, -alto / 2 + P / 2, -DP / 2), (ancho, P, DP), color=color_marco, material='Wood')
    _caja(ctx, m, 'Marco_Izquierdo', u, y, v, yaw, (-ancho / 2 + P / 2, 0, -DP / 2), (P, alto - 2 * P, DP), color=color_marco, material='Wood')
    _caja(ctx, m, 'Marco_Derecho', u, y, v, yaw, (ancho / 2 - P / 2, 0, -DP / 2), (P, alto - 2 * P, DP), color=color_marco, material='Wood')
    # zona interior útil (dentro del marco y de un filete claro de 0.12 dibujado sobre el corcho)
    IW, IH = ancho - 2 * P - 0.24, alto - 2 * P - 0.24
    g = _gui_frente(ctx, fondo, yaw, 100, light=0.3)
    ar = FW / FH
    bw, bh = 0.12 / FW, 0.12 / FH            # filete de madera clara (Frames)
    mx, my = (P - 0.05) / FW, (P - 0.05) / FH
    _fr(ctx, g, mx, my, 1 - 2 * mx, bh, MADERA_CLARA, name='Filete')
    _fr(ctx, g, mx, 1 - my - bh, 1 - 2 * mx, bh, MADERA_CLARA, name='Filete')
    _fr(ctx, g, mx, my, bw, 1 - 2 * my, MADERA_CLARA, name='Filete')
    _fr(ctx, g, 1 - mx - bw, my, bw, 1 - 2 * my, MADERA_CLARA, name='Filete')

    def F(fx, fy):   # fracción del área interior → fracción de la cara del corcho
        return ((P + 0.12 - 0.05 + fx * IW) / FW, (P + 0.12 - 0.05 + fy * IH) / FH)

    def L(fx, fy):   # fracción del área interior → coordenadas locales (lu, ly)
        return (-IW / 2 + fx * IW, IH / 2 - fy * IH)

    # franja de título (azul) con cintas amarillas en las esquinas
    (tx0, ty0), (tx1, ty1) = F(0.03, 0.03), F(0.97, 0.19)
    _fr(ctx, g, tx0, ty0, tx1 - tx0, ty1 - ty0, (40, 70, 150), z=2, name='Franja_Titulo')
    _tx(ctx, g, tx0, ty0, tx1 - tx0, ty1 - ty0, titulo, (255, 225, 90), font=FONT_FREDOKA, z=3, stroke=(20, 30, 70))
    for cx, cy in ((tx0, ty0), (tx1, ty0), (tx0, ty1), (tx1, ty1)):
        _fr(ctx, g, cx - 0.012, cy - 0.03, 0.024, 0.06, CINTA_AMARILLA, z=4, rot=40, name='Cinta_Amarilla')
    # hojas: 2 parts (HORARIO blanca, lista amarilla) + 1 papel rosa dibujado sobre el corcho
    hojas = list(hojas)[:3] + [None] * (3 - min(3, len(hojas)))
    especif = [((0.255, 0.60), (0.43, 0.68), -2.0, HOJA_BLANCA), ((0.615, 0.59), (0.25, 0.62), 2.5, HOJA_AMARILLA)]
    for k, (titulo_h, ((cx, cy), (sw, sh), roll, col)) in enumerate(zip(hojas[:2], especif)):
        if not titulo_h:
            continue
        lu, ly = L(cx, cy)
        w, h = sw * IW, sh * IH
        p = _caja(ctx, m, f'Hoja_{titulo_h.title()}', u, y, v, yaw, (lu, ly, -DP + 0.05), (w, h, 0.02), roll=roll,
                  color=col, material='SmoothPlastic')
        gh = _gui_frente(ctx, p, yaw, 150, roll=roll, light=0.3)
        _diseno_hoja(ctx, gh, w / h, titulo_h)
        _chinchetas(ctx, gh, 0, 0, 1, 1, w / h, color=(200, 40, 40) if k == 0 else (40, 90, 200))
    if hojas[2]:
        (px0, py0), (px1, py1) = F(0.76, 0.30), F(0.97, 0.86)
        _fr(ctx, g, px0, py0, px1 - px0, py1 - py0, HOJA_ROSA, z=2, rot=3, name='Papel_Rosa')
        lineas, col = _LISTAS.get(hojas[2].upper(), (['Lectura', 'Juego', 'Tarea'], MORADO))
        _tx(ctx, g, px0 + 0.01, py0 + 0.02, px1 - px0 - 0.02, (py1 - py0) * 0.16, hojas[2], col, font=FONT_FREDOKA, z=3, rot=3)
        n = min(4, len(lineas))
        lh = (py1 - py0) * 0.70 / n
        for i, l in enumerate(lineas[:n]):          # un TextLabel por renglón (sin saltos raros)
            _tx(ctx, g, px0 + 0.02, py0 + (py1 - py0) * 0.24 + lh * i, px1 - px0 - 0.04, lh * 0.8, l,
                (60, 40, 70), font=FONT_SOURCE, z=3, rot=3, xalign=0)
        _chinchetas(ctx, g, px0, py0, px1 - px0, py1 - py0, ar, color=(60, 160, 80), d=0.018, rot=3)
    return m


# ================================================================ 3) AFICHE
def _afiche_dios(ctx, g, ar):
    """'Hoy Dios te dice: Todo va a estar BIEN, confía en mí' — fondo crema, niña de vestido rosa, flores (foto1)."""
    _fr(ctx, g, 0, 0, 1, 1, (250, 240, 205), z=1, name='Fondo')
    _fr(ctx, g, 0, 0.86, 1, 0.14, (150, 190, 90), z=2, name='Pasto')
    _circ(ctx, g, 0.86, 0.12, 0.26, (255, 225, 140), ar, z=2, name='Sol')
    _tx(ctx, g, 0.06, 0.04, 0.30, 0.07, 'Hoy', (80, 70, 80), font=FONT_PERMANENT, z=4)
    _tx(ctx, g, 0.03, 0.10, 0.60, 0.18, 'DIOS', ROSA_FUERTE, font=FONT_BANGERS, z=4, stroke=(120, 30, 70))
    _tx(ctx, g, 0.08, 0.28, 0.44, 0.07, 'te dice:', (80, 70, 80), font=FONT_PERMANENT, z=4)
    _tx(ctx, g, 0.02, 0.39, 0.56, 0.08, 'Todo va a estar', (60, 80, 90), font=FONT_PERMANENT, z=4)
    _tx(ctx, g, 0.04, 0.47, 0.50, 0.15, 'BIEN', (40, 90, 100), font=FONT_BANGERS, z=4, stroke=(20, 50, 60))
    _tx(ctx, g, 0.00, 0.63, 0.60, 0.10, 'confía en mí', (70, 60, 90), font=FONT_PERMANENT, z=4)
    # niña (frames): pelo, cara, vestido rosa, brazos, piernas, zapatos
    _circ(ctx, g, 0.78, 0.36, 0.30, (70, 40, 28), ar, z=3, name='Nina_Pelo')
    _fr(ctx, g, 0.63, 0.36, 0.08, 0.22, (70, 40, 28), z=3, corner=(0.3, 0), name='Nina_Pelo_Izq')
    _fr(ctx, g, 0.85, 0.36, 0.08, 0.22, (70, 40, 28), z=3, corner=(0.3, 0), name='Nina_Pelo_Der')
    _circ(ctx, g, 0.78, 0.38, 0.22, (248, 210, 180), ar, z=4, name='Nina_Cara')
    _circ(ctx, g, 0.745, 0.385, 0.03, (40, 30, 30), ar, z=5, name='Nina_Ojo')
    _circ(ctx, g, 0.815, 0.385, 0.03, (40, 30, 30), ar, z=5, name='Nina_Ojo')
    _fr(ctx, g, 0.655, 0.49, 0.25, 0.25, (240, 120, 160), z=4, corner=(0.25, 0), name='Nina_Vestido')
    _fr(ctx, g, 0.61, 0.70, 0.34, 0.05, (235, 100, 150), z=4, corner=(0.5, 0), name='Nina_Vestido_Borde')
    _fr(ctx, g, 0.705, 0.745, 0.06, 0.11, (248, 210, 180), z=3, name='Nina_Pierna')
    _fr(ctx, g, 0.80, 0.745, 0.06, 0.11, (248, 210, 180), z=3, name='Nina_Pierna')
    _fr(ctx, g, 0.69, 0.845, 0.09, 0.035, (60, 40, 40), z=4, corner=(0.5, 0), name='Nina_Zapato')
    _fr(ctx, g, 0.785, 0.845, 0.09, 0.035, (60, 40, 40), z=4, corner=(0.5, 0), name='Nina_Zapato')
    # flores (pétalos blancos + centro amarillo) y corazón
    for cx, cy, d in ((0.10, 0.80, 0.11), (0.26, 0.84, 0.09), (0.46, 0.81, 0.10), (0.93, 0.80, 0.08)):
        _circ(ctx, g, cx, cy, d, (255, 255, 255), ar, z=3, name='Flor')
        _circ(ctx, g, cx, cy, d * 0.42, (250, 200, 40), ar, z=4, name='Flor_Centro')
    _fr(ctx, g, 0.52, 0.72, 0.07, 0.07 * ar, (235, 100, 150), z=3, rot=45, name='Corazon')


def _afiche_todo_lo_puedo(ctx, g, ar):
    """Afiche de la foto2: 'Ni antes ni después... TODO en el tiempo de DIOS' — morado y blanco."""
    _fr(ctx, g, 0, 0, 1, 1, MORADO, z=1, name='Borde')
    _fr(ctx, g, 0.04, 0.03, 0.92, 0.94, (252, 250, 255), z=2, name='Fondo')
    _tx(ctx, g, 0.08, 0.06, 0.84, 0.08, 'Ni antes ni después...', (70, 60, 80), font=FONT_PERMANENT, z=4)
    _tx(ctx, g, 0.06, 0.16, 0.88, 0.22, 'TODO', MORADO, font=FONT_BANGERS, z=4, stroke=(60, 20, 80))
    _tx(ctx, g, 0.08, 0.40, 0.84, 0.09, 'en el tiempo de', (70, 60, 80), font=FONT_PERMANENT, z=4)
    _tx(ctx, g, 0.06, 0.50, 0.88, 0.17, 'DIOS', MORADO, font=FONT_BANGERS, z=4, stroke=(60, 20, 80))
    _tx(ctx, g, 0.15, 0.905, 0.70, 0.05, 'Eclesiastés 3:11', (120, 90, 140), font=FONT_GOTHAM, z=4)
    # reloj morado (como en la foto) y margarita
    _circ(ctx, g, 0.27, 0.77, 0.30, (120, 50, 150), ar, z=3, name='Reloj_Morado')
    _circ(ctx, g, 0.27, 0.77, 0.22, (245, 235, 255), ar, z=4, name='Reloj_Esfera')
    _fr(ctx, g, 0.262, 0.70, 0.016, 0.07, (90, 40, 110), z=5, name='Manecilla')
    _fr(ctx, g, 0.27, 0.765, 0.07, 0.012, (90, 40, 110), z=5, name='Manecilla')
    for k in range(6):
        a = math.radians(k * 60)
        _circ(ctx, g, 0.70 + 0.11 * math.sin(a), 0.77 - 0.11 * math.cos(a) * ar, 0.11, (225, 205, 240), ar, z=3, name='Petalo')
    _circ(ctx, g, 0.70, 0.77, 0.10, (250, 200, 40), ar, z=4, name='Flor_Centro')


def _afiche_valores(ctx, g, ar):
    """Lista de valores con viñetas de colores."""
    _fr(ctx, g, 0, 0, 1, 1, (235, 245, 250), z=1, name='Fondo')
    _fr(ctx, g, 0, 0, 1, 0.17, (30, 90, 170), z=2, name='Banda')
    _tx(ctx, g, 0.05, 0.01, 0.9, 0.15, 'VALORES', (255, 255, 255), font=FONT_FREDOKA, z=4)
    vals = ['Respeto', 'Honestidad', 'Responsabilidad', 'Solidaridad', 'Tolerancia', 'Amor', 'Gratitud']
    y0, h = 0.21, 0.76 / len(vals)
    for i, vtxt in enumerate(vals):
        cy = y0 + h * (i + 0.5)
        _circ(ctx, g, 0.12, cy, 0.12, _PALETA_VINETAS[i % 6], ar, z=3, name='Vineta')
        _tx(ctx, g, 0.24, cy - h * 0.36, 0.74, h * 0.72, vtxt, (40, 50, 80), font=FONT_GOTHAM, z=4, xalign=0)


def _afiche_abc(ctx, g, ar):
    """Abecedario (A..Z + Ñ) en cuadritos de colores, 4 columnas x 7 filas."""
    _fr(ctx, g, 0, 0, 1, 1, (255, 255, 255), z=1, name='Fondo')
    letras = list('ABCDEFGHIJKLMN') + ['Ñ'] + list('OPQRSTUVWXYZ') + ['abc']
    cols, rows = 4, 7
    cw, rh = 1.0 / cols, 1.0 / rows
    for i, l in enumerate(letras):
        c, r = i % cols, i // cols
        col = _PALETA_VINETAS[(i * 5 + r) % 6]
        t = _tx(ctx, g, c * cw + 0.012, r * rh + 0.009, cw - 0.024, rh - 0.018, l, (255, 255, 255),
                font=FONT_FREDOKA, z=3, stroke=(40, 40, 50), bg=col, name='Letra')
        _corner(ctx, t, 0.2, 0)


_AFICHES = {'dios': _afiche_dios, 'todo_lo_puedo': _afiche_todo_lo_puedo, 'valores': _afiche_valores, 'abc': _afiche_abc}


def build_afiche(ctx, parent, u, y, v, yaw=0, ancho=2.4, alto=3.2, tema='dios'):
    """Afiche plano con marco fino. 2 parts (≤ 2): marco (ancho x alto x 0.05) + lámina con el diseño
    (Frames/TextLabels, 0 parts). (u,y) = centro; v = plano de la pared; yaw=0 → cara visible hacia -v.
    Sobresale 0.08. tema: 'dios' (foto1: "Hoy Dios te dice: Todo va a estar BIEN, confía en mí", crema con
    flores y niña), 'todo_lo_puedo' (foto2: "TODO lo puedo en Cristo", morado/blanco), 'valores' (lista),
    'abc' (letras de colores). Diseño en proporción (fracciones), así que admite otros tamaños.
    """
    if tema not in _AFICHES:
        raise ValueError(f'tema desconocido: {tema!r} (usa {sorted(_AFICHES)})')
    m = ctx.model(f'Afiche_{tema}', parent=parent)
    _caja(ctx, m, 'Marco_Afiche', u, y, v, yaw, (0, 0, -0.025), (ancho, alto, 0.05), color=MARCO_AFICHE, material='Wood')
    lam = _caja(ctx, m, 'Lamina_Afiche', u, y, v, yaw, (0, 0, -0.065), (ancho - 0.14, alto - 0.14, 0.03),
                color=(245, 245, 240), material='SmoothPlastic')
    g = _gui_frente(ctx, lam, yaw, 200, light=0.35)
    _AFICHES[tema](ctx, g, (ancho - 0.14) / (alto - 0.14))
    return m


# ================================================================ 4) RELOJ
def build_reloj(ctx, parent, u, y, v, yaw=0, diametro=1.6, hora=(10, 10)):
    """Reloj de pared redondo. 3 parts (≤ 3): aro negro (cilindro), carátula blanca con SurfaceGui
    (números 1-12, marcas, manecillas de hora/minuto/segundero con Frames) y cristal translúcido.
    (u,y) = centro del reloj; v = plano de la pared; yaw=0 → carátula hacia -v. Sobresale 0.17 (aro atrás, carátula delante, cristal al frente).
    hora = (h, m) marca la posición de las manecillas (por defecto 10:10).
    """
    m = ctx.model('Reloj_Pared', parent=parent)
    D = diametro
    ctx.cylinder('Aro_Reloj', place(u, y, v, yaw, 0, 0, -0.05), 0.10, D, axis='v', yaw=yaw,
                 color=NEGRO_RELOJ, material='SmoothPlastic', parent=m, cancollide=False)
    car = ctx.cylinder('Caratula', place(u, y, v, yaw, 0, 0, -0.12), 0.04, D - 0.18, axis='v', yaw=yaw,
                       color=(250, 250, 248), material='SmoothPlastic', parent=m, cancollide=False)
    ctx.cylinder('Cristal_Reloj', place(u, y, v, yaw, 0, 0, -0.155), 0.03, D - 0.10, axis='v', yaw=yaw,
                 color=(220, 230, 240), material='SmoothPlastic', transparency=0.75, reflectance=0.2, parent=m,
                 cancollide=False, castshadow=False)
    g = _gui_frente(ctx, car, yaw, 300, yaw_extra=90, light=0.2)      # cilindro axis='v' → part con yaw+90
    for k in range(60):                                                 # marcas
        a = math.radians(k * 6)
        largo, ancho_m, col = (0.06, 0.016, (40, 40, 45)) if k % 5 == 0 else (0.03, 0.007, (120, 120, 125))
        r = 0.455 - largo / 2
        _fr(ctx, g, 0.5 + r * math.sin(a) - ancho_m / 2, 0.5 - r * math.cos(a) - largo / 2, ancho_m, largo, col,
            z=2, rot=k * 6, name='Marca')
    for n in range(1, 13):                                              # números
        a = math.radians(n * 30)
        _tx(ctx, g, 0.5 + 0.36 * math.sin(a) - 0.07, 0.5 - 0.36 * math.cos(a) - 0.06, 0.14, 0.12, str(n),
            (30, 30, 35), font=FONT_GOTHAM, z=3)
    _tx(ctx, g, 0.3, 0.63, 0.4, 0.06, 'QUARTZ', (120, 120, 130), font=FONT_GOTHAM, z=3)
    h, mi = hora
    for ang, L, w, col, z in ((((h % 12) + mi / 60.0) * 30, 0.26, 0.04, (30, 30, 35), 4),
                              (mi * 6, 0.38, 0.03, (30, 30, 35), 5), ((mi * 6 + 140) % 360, 0.42, 0.012, (200, 30, 30), 6)):
        a = math.radians(ang)
        _fr(ctx, g, 0.5 + (L / 2) * math.sin(a) - w / 2, 0.5 - (L / 2) * math.cos(a) - L / 2, w, L, col,
            z=z, rot=ang, corner=(0.5, 0), name='Manecilla')
    _circ(ctx, g, 0.5, 0.5, 0.06, (200, 30, 30), 1.0, z=7, name='Eje')
    return m


# ================================================================ 5) PLACA DE GRADO
def build_letrero_grado(ctx, parent, u, y, v, yaw=0, texto='GRADO 5°', ancho=2.6, alto=0.9,
                        color_texto=MORADO, color_fondo=(248, 246, 240)):
    """Placa pequeña con texto (1 part): fondo claro con borde de color, 4 tornillos (Frames) y el texto en
    letra redondeada. (u,y) = centro; v = plano de la pared; yaw=0 → cara visible hacia -v. Sobresale 0.08.
    """
    m = ctx.model('Letrero_Grado', parent=parent)
    p = _caja(ctx, m, 'Placa', u, y, v, yaw, (0, 0, -0.04), (ancho, alto, 0.08), color=color_fondo, material='SmoothPlastic')
    g = _gui_frente(ctx, p, yaw, 200, light=0.3)
    ar = ancho / alto
    b = 0.05 / ancho
    _fr(ctx, g, b, b * ar, 1 - 2 * b, 1 - 2 * b * ar, color_texto, z=1, name='Borde')
    _fr(ctx, g, 2.2 * b, 2.2 * b * ar, 1 - 4.4 * b, 1 - 4.4 * b * ar, color_fondo, z=2, name='Fondo')
    for cx in (0.04, 0.96):
        for cy in (0.12, 0.88):
            _circ(ctx, g, cx, cy, 0.022, (150, 150, 155), ar, z=3, name='Tornillo')
    _tx(ctx, g, 0.08, 0.12, 0.84, 0.76, texto, color_texto, font=FONT_FREDOKA, z=4)
    return m


# ================================================================ selftest
def selftest():
    """Construye cada objeto con yaw=0 (pared en v=0, cara visible hacia -v) y con yaw=90 (pared en u=30 que
    mira hacia +u), imprime parts y bbox, renderiza ../out/comp_tablero_preview.png (+ una imagen por objeto
    y mosaicos de las SurfaceGui) y exporta ../out/comp_tablero_selftest.rbxm."""
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Tablero')
    casos = [
        ('tablero_0', 12, lambda: build_tablero(ctx, raiz, 0, 6.5, 0, yaw=0)),
        ('cartelera_0', 7, lambda: build_cartelera(ctx, raiz, 9.0, 6.5, 0, yaw=0)),
        ('afiche_dios_0', 2, lambda: build_afiche(ctx, raiz, 14.2, 6.5, 0, yaw=0, tema='dios')),
        ('afiche_todo_0', 2, lambda: build_afiche(ctx, raiz, 17.0, 6.5, 0, yaw=0, tema='todo_lo_puedo')),
        ('afiche_valores_0', 2, lambda: build_afiche(ctx, raiz, 19.8, 6.5, 0, yaw=0, tema='valores')),
        ('afiche_abc_0', 2, lambda: build_afiche(ctx, raiz, 22.6, 6.5, 0, yaw=0, tema='abc')),
        ('reloj_0', 3, lambda: build_reloj(ctx, raiz, 25.5, 10.0, 0, yaw=0)),
        ('letrero_0', 1, lambda: build_letrero_grado(ctx, raiz, 25.5, 7.5, 0, yaw=0)),
        ('tablero_90', 12, lambda: build_tablero(ctx, raiz, 30, 6.5, 6.0, yaw=90)),
        ('cartelera_90', 7, lambda: build_cartelera(ctx, raiz, 30, 6.5, 15.0, yaw=90, titulo='GRADO 5°', hojas=('HORARIO', 'NORMAS'))),
        ('afiche_dios_90', 2, lambda: build_afiche(ctx, raiz, 30, 6.5, 20.5, yaw=90, tema='dios')),
        ('reloj_90', 3, lambda: build_reloj(ctx, raiz, 30, 10.0, 23.5, yaw=90)),
        ('letrero_90', 1, lambda: build_letrero_grado(ctx, raiz, 30, 7.5, 23.5, yaw=90, texto='CUARTO', color_texto=(20, 50, 160))),
    ]
    out = []
    for nombre, lim, fn in casos:
        idx = fn()
        n = ctx.count_parts(idx)
        lo, hi = ctx.bbox(idx)
        print(f'{nombre:18s} parts={n:2d} (max {lim:2d}) bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) '
              f'hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) ext=({hi[0]-lo[0]:.2f},{hi[1]-lo[1]:.2f},{hi[2]-lo[2]:.2f})')
        assert n <= lim, (nombre, n, lim)
        out.append((nombre, idx, n, lo, hi))
        render_ctx(ctx, f'../out/comp_tablero_{nombre}.png', idx=idx, scale=60)
    render_ctx(ctx, '../out/comp_tablero_preview.png', idx=raiz, scale=20)
    ctx.export('../out/comp_tablero_selftest.rbxm')
    # mosaicos de las SurfaceGui (diseños planos) para revisarlos
    try:
        from gui_preview import render_guis_grid
        guis = [i for i, inst in enumerate(ctx.insts) if inst['cls'] == 'SurfaceGui']
        por_modelo = {}
        for gi in guis:
            k = gi
            while ctx.insts[k]['parent'] != raiz:
                k = ctx.insts[k]['parent']
            por_modelo.setdefault(k, []).append(gi)
        nombres = {idx: nombre for nombre, idx, *_ in out}
        for midx, gl in por_modelo.items():
            nm = nombres.get(midx, str(midx))
            if nm.endswith('_0'):
                render_guis_grid(ctx, gl, f'../out/comp_tablero_gui_{nm}.png', scale=1.0, cols=3)
    except Exception as e:    # la vista previa de GUI es opcional
        print('gui_preview no disponible:', e)
    return out


if __name__ == '__main__':
    selftest()
