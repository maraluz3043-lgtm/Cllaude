"""comp_docente.py — Mesa y silla del docente para los salones nuevos (marco local u,y,v; ver API.md).

Convenciones comunes
--------------------
* (u, y, v) = centro de la BASE del mueble sobre el piso (y = cota del piso terminado, p.ej. 0.42).
* yaw (grados) gira el mueble sobre el eje vertical con el mismo convenio de la API (yaw=90 → el eje
  local +lu pasa a apuntar hacia +v).
* Todo anclado; nombres en español; sin meshes/texturas/unions.

build_mesa_docente  (yaw=0): el tablero es largo a lo largo de u (7.0 en 'madera').
    LADO DEL DOCENTE = +v (lv > 0). El docente se sienta en +v mirando hacia -v (hacia el corredor/fachada),
    igual que una silla con el mismo yaw colocada en v + ~2.3. Los alumnos ven el lado -v, donde está el canto
    claro ('madera') o el faldón metálico ('metal'); el cajón ('metal') abre hacia +v (hacia el docente).
build_silla_docente (yaw=0): la persona sentada mira hacia -v; el respaldo queda en +v.
    El part 'Asiento' es de clase Seat y se crea con yaw+180 para que su LookVector apunte a -v (en este
    marco un Seat con yaw=0 haría mirar al avatar hacia +v).
"""
import math
from build import Ctx, FACE, face_toward, FONT_GOTHAM, FONT_SOURCE, FONT_FREDOKA
from preview import render_ctx

# ---------------------------------------------------------------- colores
MADERA = (168, 118, 66)
CANTO = (187, 161, 119)
METAL_NEGRO = (26, 29, 28)
CREMA_MELAMINA = (205, 195, 169)
CREMA_METAL = (187, 181, 155)
CREMA_METAL_CLARO = (198, 191, 165)
AZUL_SILLA = (28, 60, 215)
NEGRO_SILLA = (38, 38, 42)
TUBO = (29, 31, 31)


def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del componente → coordenadas (u,y,v) del edificio, girado yaw grados."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def _caja(ctx, parent, nombre, u, y, v, yaw, lc, size, yaw_local=0.0, **kw):
    """Box en coordenadas locales del componente (lc = centro local)."""
    return ctx.box(nombre, place(u, y, v, yaw, *lc), size, yaw=yaw + yaw_local, parent=parent, **kw)


def _tubo(ctx, parent, nombre, u, y, v, yaw, a, b, diam, **kw):
    """Cilindro entre dos puntos locales a y b (sirve para patas inclinadas, lápices, etc.)."""
    ax, ay, az = a
    bx, by, bz = b
    L = math.dist(a, b)
    d = ((bx - ax) / L, (by - ay) / L, (bz - az) / L)
    psi = math.degrees(math.atan2(d[2], d[0]))          # giro sobre vertical
    r = math.degrees(math.asin(max(-1.0, min(1.0, d[1]))))  # elevación
    c = place(u, y, v, yaw, (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2)
    return ctx.part(nombre, c, (L, diam, diam), yaw=yaw + psi, roll=r, shape='Cylinder', parent=parent, **kw)


def _cil_y(ctx, parent, nombre, u, y, v, yaw, lc, length, diam, **kw):
    """Cilindro vertical centrado en el punto local lc."""
    return ctx.cylinder(nombre, place(u, y, v, yaw, *lc), length, diam, axis='y', yaw=yaw, parent=parent, **kw)


# ---------------------------------------------------------------- objetos de escritorio (compartidos)
def _portalapices(ctx, parent, u, y, v, yaw, lc, n_lapices=2):
    """Vaso portalápices + lápices inclinados. Devuelve nº de parts (1 + n_lapices)."""
    lu, ly, lv = lc
    _cil_y(ctx, parent, 'Portalapices', u, y, v, yaw, (lu, ly + 0.36, lv), 0.72, 0.52,
           color=(42, 42, 48), material='SmoothPlastic')
    cols = [(236, 196, 52), (30, 90, 200), (200, 60, 60)]
    desv = [(-0.16, -0.10), (0.15, 0.08), (0.02, 0.17)]
    for i in range(n_lapices):
        du, dv = desv[i]
        _tubo(ctx, parent, f'Lapiz_{i + 1}', u, y, v, yaw,
              (lu - du * 0.5, ly + 0.10, lv - dv * 0.5), (lu + du * 1.1, ly + 1.12, lv + dv * 1.1), 0.075,
              color=cols[i], material='SmoothPlastic')
    return 1 + n_lapices


def _cuaderno(ctx, parent, u, y, v, yaw, lc, yaw_local=-6.0, con_boligrafo=True, titulo='PLANEADOR'):
    """Cuaderno cerrado con una hoja encima y bolígrafo. Devuelve nº de parts (2 o 3)."""
    lu, ly, lv = lc
    c = _caja(ctx, parent, 'Cuaderno_Docente', u, y, v, yaw, (lu, ly + 0.035, lv), (1.2, 0.07, 0.88),
              yaw_local=yaw_local, color=(53, 80, 97), material='SmoothPlastic')
    p = _caja(ctx, parent, 'Hoja_Sobre_Cuaderno', u, y, v, yaw, (lu + 0.04, ly + 0.075, lv - 0.02), (1.02, 0.01, 0.74),
              yaw_local=yaw_local + 4, color=(232, 229, 218), material='SmoothPlastic')
    g = ctx.surface_gui(p, face_toward(yaw + yaw_local + 4, (0, 1, 0)), pixels_per_stud=80)
    ctx.text(g, titulo, pos=(0.08, 0, 0.03, 0), size=(0.84, 0, 0.13, 0), color=(60, 70, 90), font=FONT_GOTHAM)
    for k in range(6):   # renglones (0 parts)
        ctx.frame(g, pos=(0.08, 0, 0.18 + 0.12 * k, 0), size=(0.84, 0, 0.012, 0), color=(150, 170, 200))
    n = 2
    if con_boligrafo:
        _tubo(ctx, parent, 'Boligrafo', u, y, v, yaw,
              (lu - 0.35, ly + 0.105, lv + 0.12), (lu + 0.42, ly + 0.105, lv - 0.10), 0.05,
              color=(25, 44, 66), material='Metal')
        n = 3
    return n


def _botella(ctx, parent, u, y, v, yaw, lc):
    """Botella de agua (cuerpo, cuello, tapa) = 3 parts."""
    lu, ly, lv = lc
    _cil_y(ctx, parent, 'Botella_Cuerpo', u, y, v, yaw, (lu, ly + 0.48, lv), 0.96, 0.44,
           color=(205, 228, 240), material='Glass', transparency=0.35)
    _cil_y(ctx, parent, 'Botella_Cuello', u, y, v, yaw, (lu, ly + 1.07, lv), 0.22, 0.22,
           color=(205, 228, 240), material='Glass', transparency=0.3)
    _cil_y(ctx, parent, 'Botella_Tapa', u, y, v, yaw, (lu, ly + 1.26, lv), 0.16, 0.27,
           color=(30, 100, 200), material='SmoothPlastic')
    return 3


def _taza(ctx, parent, u, y, v, yaw, lc):
    """Taza blanca con asa = 2 parts."""
    lu, ly, lv = lc
    t = _cil_y(ctx, parent, 'Taza', u, y, v, yaw, (lu, ly + 0.26, lv), 0.52, 0.46,
               color=(242, 240, 236), material='SmoothPlastic')
    g = ctx.surface_gui(t, face_toward(yaw, (0, 1, 0), roll=90), pixels_per_stud=80)  # cilindro vertical: roll=90
    ctx.frame(g, pos=(0.17, 0, 0.17, 0), size=(0.66, 0, 0.66, 0), color=(92, 60, 36), corner=(1.0, 0))  # café
    _caja(ctx, parent, 'Taza_Asa', u, y, v, yaw, (lu + 0.27, ly + 0.27, lv), (0.1, 0.3, 0.14),
          color=(242, 240, 236), material='SmoothPlastic')
    return 2


# ---------------------------------------------------------------- MESA DOCENTE
def build_mesa_docente(ctx, parent, u, y, v, yaw=0, estilo='madera'):
    """Mesa del docente. (u,y,v) = centro de la base en el piso. ≤ 20 parts.

    Orientación (yaw=0): el tablero es largo a lo largo de u. LADO DEL DOCENTE = +v (lv > 0): el docente se
    sienta en +v y mira hacia -v. El lado -v es el que ven los alumnos (canto claro / faldón).

    estilo='madera': tablero de madera 7.0 x 2.6, cara superior a 3.0 del piso, sobre dos patas en T de
        metal negro con travesaño; encima cuaderno con hoja y bolígrafo, portalápices con 2 lápices, botella
        de agua y un libro (según referencia 'MesaDocente' del piso superior). 19 parts.
    estilo='metal': escritorio metálico crema 5.0 x 2.4 x 3.0 (según 'MesaDocenteMetalCrema') con 4 patas
        cuadradas, entrepaño bajo con libros, faldón hacia los alumnos y cajón con tirador hacia el docente;
        encima libreta, portalápices con 2 lápices y taza. 19 parts.
    Devuelve el índice del Model.
    """
    if estilo not in ('madera', 'metal'):
        raise ValueError('estilo debe ser madera o metal: %r' % (estilo,))
    m = ctx.model('Mesa_Docente_' + ('Madera' if estilo == 'madera' else 'Metal'), parent=parent)
    if estilo == 'madera':
        W, Dp, HT, ESP = 7.0, 2.6, 3.0, 0.16                 # ancho, fondo, altura cara superior, espesor
        # --- tablero + canto claro hacia los alumnos (-v)
        tab = _caja(ctx, m, 'Tablero_Madera', u, y, v, yaw, (0, HT - ESP / 2, 0), (W, ESP, Dp),
                    color=MADERA, material='Wood')
        g = ctx.surface_gui(tab, face_toward(yaw, (0, 1, 0)), pixels_per_stud=40)
        for k, (px, py, w, rot) in enumerate([(0.12, 0.2, 0.05, 20), (0.3, 0.7, 0.04, -35), (0.55, 0.3, 0.06, 60),
                                              (0.72, 0.8, 0.03, 10), (0.88, 0.5, 0.05, -70), (0.42, 0.55, 0.03, 85)]):
            ctx.frame(g, pos=(px, 0, py, 0), size=(w, 0, 0.006, 0), color=(110, 78, 44), rotation=rot,
                      name=f'Desgaste_{k + 1}')  # rayones de uso (0 parts)
        _caja(ctx, m, 'Canto_Claro', u, y, v, yaw, (0, HT - ESP / 2, -Dp / 2 - 0.025), (W, ESP, 0.05),
              color=CANTO, material='SmoothPlastic')
        # --- estructura metálica negra: 2 patas en T (pie + columna + traviesa superior) + travesaño
        for s, lado in ((-1, 'Izq'), (1, 'Der')):
            lu = s * (W / 2 - 0.8)
            _caja(ctx, m, f'Pie_T_{lado}', u, y, v, yaw, (lu, 0.07, 0), (0.28, 0.14, 2.3),
                  color=METAL_NEGRO, material='Metal')
            _caja(ctx, m, f'Pata_Vertical_{lado}', u, y, v, yaw, (lu, 0.14 + (HT - ESP - 0.14) / 2, 0),
                  (0.16, HT - ESP - 0.14, 0.16), color=METAL_NEGRO, material='Metal')
            _caja(ctx, m, f'Traviesa_Superior_{lado}', u, y, v, yaw, (lu, HT - ESP - 0.06, 0), (0.16, 0.12, 2.1),
                  color=METAL_NEGRO, material='Metal')
        _caja(ctx, m, 'Travesano_Mesa', u, y, v, yaw, (0, 2.42, 0), (W - 1.6 - 0.16, 0.13, 0.13),
              color=METAL_NEGRO, material='Metal')
        # --- objetos encima (cara superior en HT)
        _cuaderno(ctx, m, u, y, v, yaw, (-1.5, HT, 0.45))
        _portalapices(ctx, m, u, y, v, yaw, (2.55, HT, 0.55))
        _botella(ctx, m, u, y, v, yaw, (-2.75, HT, -0.55))
        lib = _caja(ctx, m, 'Libro_Guia', u, y, v, yaw, (1.0, HT + 0.085, -0.65), (1.35, 0.17, 1.0),
                    yaw_local=8, color=(150, 42, 40), material='SmoothPlastic')
        ctx.label_on(lib, 'GUÍA DOCENTE', direction=(0, 1, 0), yaw=yaw + 8, color=(240, 225, 200),
                     font=FONT_FREDOKA, pos=(0.08, 0, 0.3, 0), size=(0.84, 0, 0.3, 0))
    else:
        W, Dp, HT, ESP = 5.0, 2.4, 3.0, 0.13
        tab = _caja(ctx, m, 'Tablero_Melamina', u, y, v, yaw, (0, HT - ESP / 2, 0), (W, ESP, Dp),
                    color=CREMA_MELAMINA, material='Wood')
        for su, lado in ((-1, 'Izq'), (1, 'Der')):
            for sv, pos in ((-1, 'Frente'), (1, 'Atras')):
                _caja(ctx, m, f'Pata_{pos}_{lado}', u, y, v, yaw, (su * (W / 2 - 0.12), (HT - ESP) / 2, sv * (Dp / 2 - 0.12)),
                      (0.12, HT - ESP, 0.12), color=CREMA_METAL, material='Metal')
        _caja(ctx, m, 'Entrepano', u, y, v, yaw, (0, 0.40, 0.05), (W - 0.24, 0.08, Dp - 0.4),
              color=(187, 180, 152), material='Metal')
        _caja(ctx, m, 'Faldon_Frontal', u, y, v, yaw, (0, 2.08, -(Dp / 2 - 0.03)), (W - 0.24, 1.55, 0.06),
              color=CREMA_METAL_CLARO, material='Metal')
        # cajón bajo el tablero, abre hacia el docente (+v); a la derecha del docente (= -u)
        cu = -1.3
        _caja(ctx, m, 'Cajon_Cuerpo', u, y, v, yaw, (cu, HT - ESP - 0.32, 0.205), (1.9, 0.62, 1.87),
              color=(190, 183, 156), material='Metal')
        fr = _caja(ctx, m, 'Cajon_Frente', u, y, v, yaw, (cu, HT - ESP - 0.33, Dp / 2 - 0.03), (2.0, 0.66, 0.06),
                   color=CREMA_METAL_CLARO, material='Metal')
        ctx.cylinder('Cajon_Tirador', place(u, y, v, yaw, cu, HT - ESP - 0.36, Dp / 2 + 0.05), 0.6, 0.09,
                     axis='u', yaw=yaw, color=(62, 62, 66), material='Metal', parent=m)
        # libros en el entrepaño
        for k, (col, w, d) in enumerate([((122, 48, 48), 1.55, 1.15), ((48, 78, 130), 1.45, 1.1), ((206, 190, 150), 1.5, 1.05)]):
            _caja(ctx, m, f'Libro_Entrepano_{k + 1}', u, y, v, yaw, (1.2, 0.44 + 0.1 + 0.2 * k, 0.1), (w, 0.2, d),
                  yaw_local=(-4, 3, -2)[k], color=col, material='SmoothPlastic')
        # objetos encima
        lb = _caja(ctx, m, 'Libreta', u, y, v, yaw, (0.75, HT + 0.045, 0.35), (0.95, 0.09, 1.25),
                   yaw_local=-7, color=(217, 208, 178), material='SmoothPlastic')
        g = ctx.surface_gui(lb, face_toward(yaw - 7, (0, 1, 0)), pixels_per_stud=80)
        ctx.frame(g, pos=(0.0, 0, 0.0, 0), size=(1.0, 0, 0.08, 0), color=(90, 90, 95))   # espiral
        for k in range(7):
            ctx.frame(g, pos=(0.1, 0, 0.16 + 0.11 * k, 0), size=(0.8, 0, 0.012, 0), color=(150, 170, 200))
        _portalapices(ctx, m, u, y, v, yaw, (-0.3, HT, 0.75))
        _taza(ctx, m, u, y, v, yaw, (1.95, HT, -0.55))
    return m


# ---------------------------------------------------------------- SILLA DOCENTE
def build_silla_docente(ctx, parent, u, y, v, yaw=0, color='azul'):
    """Silla escolar del docente: concha de plástico (azul (28,60,215) o negra) sobre patas tubulares
    de acero negro. (u,y,v) = centro de la base en el piso. ≤ 14 parts (14).

    Orientación (yaw=0): la persona sentada mira hacia -v; el respaldo queda en +v. El 'Asiento' es un
    Seat (creado con yaw+180 para que el avatar mire a -v). Asiento a 1.85 del piso, respaldo hasta 3.6,
    ancho 1.9, fondo ≈ 2.0 (referencias 'SillaDocenteAzul' y 'Silla_Profesor').
    Devuelve el índice del Model.
    """
    if color not in ('azul', 'negra'):
        raise ValueError('color debe ser azul o negra: %r' % (color,))
    col = AZUL_SILLA if color == 'azul' else NEGRO_SILLA
    m = ctx.model('Silla_Docente_' + ('Azul' if color == 'azul' else 'Negra'), parent=parent)
    H_AS = 1.85                      # cara superior del asiento
    AW, AD, AE = 1.8, 1.55, 0.16     # ancho, fondo, espesor del asiento
    # --- asiento (Seat) + labio delantero inclinado hacia abajo
    ctx.part('Asiento', place(u, y, v, yaw, 0, H_AS - AE / 2, 0.05), (AW, AE, AD), cls='Seat',
             yaw=yaw + 180, color=col, material='SmoothPlastic', parent=m)
    _caja(ctx, m, 'Asiento_Labio', u, y, v, yaw, (0, H_AS - AE / 2 - 0.05, 0.05 - AD / 2 - 0.16), (AW, AE, 0.42),
          pitch=14, color=col, material='SmoothPlastic')
    # --- respaldo: dos tablas curvas (inclinadas hacia atrás) sobre montantes tubulares
    inc = math.radians(10)
    vb = 0.05 + AD / 2 - 0.08        # línea de los montantes a la altura del asiento
    def v_en(yy):                    # v del montante a la altura yy
        return vb + (yy - H_AS) * math.tan(inc)
    _caja(ctx, m, 'Respaldo_Bajo', u, y, v, yaw, (0, 2.48, v_en(2.48) - 0.09), (AW + 0.06, 0.82, 0.16),
          pitch=-8, color=col, material='SmoothPlastic')
    _caja(ctx, m, 'Respaldo_Alto', u, y, v, yaw, (0, 3.22, v_en(3.22) - 0.07), (AW + 0.06, 0.78, 0.16),
          pitch=-15, color=col, material='SmoothPlastic')
    for s, lado in ((-1, 'Izq'), (1, 'Der')):
        _tubo(ctx, m, f'Montante_Respaldo_{lado}', u, y, v, yaw,
              (s * 0.76, H_AS - 0.30, v_en(H_AS - 0.30)), (s * 0.76, 3.58, v_en(3.58)), 0.10,
              color=TUBO, material='Metal')
        # patas ligeramente abiertas hacia afuera (arriba bajo el asiento, abajo en el piso)
        for sv, pos in ((-1, 'Delantera'), (1, 'Trasera')):
            _tubo(ctx, m, f'Pata_{pos}_{lado}', u, y, v, yaw,
                  (s * 0.72, H_AS - AE - 0.02, 0.05 + sv * 0.58), (s * 0.86, 0.01, 0.05 + sv * 0.76), 0.10,
                  color=TUBO, material='Metal')
        # riel bajo el asiento (une patas) y travesaño bajo
        _tubo(ctx, m, f'Riel_Asiento_{lado}', u, y, v, yaw,
              (s * 0.74, H_AS - AE - 0.06, 0.05 - 0.66), (s * 0.74, H_AS - AE - 0.06, 0.05 + 0.66), 0.09,
              color=TUBO, material='Metal')
        _tubo(ctx, m, f'Travesano_Bajo_{lado}', u, y, v, yaw,
              (s * 0.80, 0.72, 0.05 - 0.70), (s * 0.80, 0.72, 0.05 + 0.70), 0.08,
              color=TUBO, material='Metal')
    return m


# ---------------------------------------------------------------- selftest
def selftest():
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Docente')
    out = []
    casos = [
        ('mesa_madera_0', lambda: build_mesa_docente(ctx, raiz, 0, 0.42, 0, yaw=0, estilo='madera')),
        ('mesa_metal_0', lambda: build_mesa_docente(ctx, raiz, 10, 0.42, 0, yaw=0, estilo='metal')),
        ('silla_azul_0', lambda: build_silla_docente(ctx, raiz, 18, 0.42, 0, yaw=0, color='azul')),
        ('silla_negra_0', lambda: build_silla_docente(ctx, raiz, 22, 0.42, 0, yaw=0, color='negra')),
        ('mesa_madera_90', lambda: build_mesa_docente(ctx, raiz, 28, 0.42, 0, yaw=90, estilo='madera')),
        ('mesa_metal_90', lambda: build_mesa_docente(ctx, raiz, 33, 0.42, 0, yaw=90, estilo='metal')),
        ('silla_azul_90', lambda: build_silla_docente(ctx, raiz, 38, 0.42, 0, yaw=90, color='azul')),
    ]
    for nombre, fn in casos:
        idx = fn()
        n = ctx.count_parts(idx)
        lo, hi = ctx.bbox(idx)
        print(f'{nombre:16s} parts={n:2d} bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) '
              f'ext=({hi[0]-lo[0]:.2f},{hi[1]-lo[1]:.2f},{hi[2]-lo[2]:.2f})')
        out.append((nombre, idx, n, lo, hi))
        render_ctx(ctx, f'../out/comp_docente_{nombre}.png', idx=idx, scale=60)
    render_ctx(ctx, '../out/comp_docente_preview.png', idx=raiz, scale=24)
    ctx.export('../out/comp_docente_selftest.rbxm')
    lim = {'mesa': 20, 'silla': 14}
    for nombre, idx, n, lo, hi in out:
        assert n <= lim[nombre.split('_')[0]], (nombre, n)
    return out


if __name__ == '__main__':
    selftest()
