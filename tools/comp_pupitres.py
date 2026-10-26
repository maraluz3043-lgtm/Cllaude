"""comp_pupitres.py — Sillas-pupitre para los salones nuevos (marco local u,y,v; ver API.md).

Dos funciones de componente con la misma convención:

    build_pupitre_azul(ctx, parent, u, y, v, yaw=0)   -> idx del Model   (26 parts, tope 26)
    build_pupitre_madera(ctx, parent, u, y, v, yaw=0) -> idx del Model   (26 parts, tope 26)

Convención de anclaje y orientación
-----------------------------------
* (u, y, v) = centro de la BASE del pupitre en el piso: punto medio entre las cuatro patas, con y = cota del
  piso terminado (0.42 en los salones). La tableta sobresale de esa base hacia un lado y hacia el frente, por
  lo que el bbox NO queda centrado en (u, v): huella ≈ 2.25 x 2.4 (azul) y 2.45 x 2.4 (madera).
* yaw = 0: el alumno sentado mira hacia -v (hacia la fachada / el corredor); el respaldo queda en +v.
  yaw gira el pupitre sobre el eje vertical con el convenio de la API (yaw=90 → el eje local +lu pasa a +v):
  con yaw=90 el alumno mira hacia +u, el respaldo queda en -u y la tableta en -v; con yaw=180 mira a +v.
* LATERALIDAD: el marco (u, y, v) es ZURDO (u crece hacia la derecha de quien mira la fachada desde el patio,
  v crece hacia dentro del edificio, y hacia arriba). Un alumno que mira hacia -v tiene por tanto su mano
  DERECHA hacia -u. Como la tableta de escritura va siempre a la DERECHA del alumno, con yaw=0 la tableta
  queda hacia -u (y no hacia +u como decía el encargo original). Esto es coherente con la referencia
  Pupitre_16 del piso superior, donde el alumno mira hacia +v y la tableta está en +u (= su derecha).
  La rotación por yaw conserva la lateralidad (la tableta siempre queda a la derecha del alumno).
* El part 'Asiento' es de clase Seat y se crea con yaw+180 para que su LookVector apunte hacia -v (en este
  marco un Seat con yaw=0 haría mirar al avatar hacia +v), igual que en comp_docente.py.
* Todo anclado; nombres en español; sin meshes, texturas ni unions. Las barras de la rejilla, las juntas
  entre tablones, las marcas de uso y la calcomanía son SurfaceGui + Frames (0 parts).

Referencias: Pupitre_16 (85 parts → 26), Pupitre_06 (43 parts → 26, escalado x0.87 para caber en 2.4 x 2.4)
y Pupitre_02 del piso superior. Alturas: azul asiento 1.71 / tableta 2.51 / respaldo 3.24; madera asiento
1.76 / tableta 2.53 / respaldo 3.60.
"""
import math
from build import Ctx, FACE, face_toward, world_to_local
from preview import render_ctx

# ---------------------------------------------------------------- colores (de las referencias y del encargo)
AZUL = (16, 58, 140)          # plástico del asiento, respaldo y tableta (Pupitre_16)
AZUL_OSCURO = (10, 39, 91)    # canto de la tableta
TUBO_OSCURO = (26, 29, 28)    # estructura tubular del pupitre azul
MADERA = (120, 66, 30)        # tablones de asiento y respaldo (encargo)
MADERA_CLARA = (150, 90, 45)  # tableta de madera (encargo)
MADERA_MEDIA = (135, 78, 38)  # cantos redondeados del respaldo
TUBO_NEGRO = (29, 31, 30)     # estructura metálica negra (Pupitre_02)
JUNTA = (58, 30, 12)          # junta oscura entre tablones (Frame)
MARCA_CLARA = (220, 216, 202) # rayones claros de uso (Frame)


def place(u, y, v, yaw, lu, ly, lv):
    """Punto local (lu,ly,lv) del componente → coordenadas (u,y,v) del edificio, girado yaw grados."""
    t = math.radians(yaw)
    return (u + lu * math.cos(t) - lv * math.sin(t), y + ly, v + lu * math.sin(t) + lv * math.cos(t))


def _caja(ctx, parent, nombre, u, y, v, yaw, lc, size, yaw_local=0.0, **kw):
    """Box en coordenadas locales del componente (lc = centro local)."""
    return ctx.box(nombre, place(u, y, v, yaw, *lc), size, yaw=yaw + yaw_local, parent=parent, **kw)


def _tubo(ctx, parent, nombre, u, y, v, yaw, a, b, diam, **kw):
    """Cilindro entre dos puntos locales a y b (patas inclinadas, montantes, soportes...)."""
    ax, ay, az = a
    bx, by, bz = b
    L = math.dist(a, b)
    d = ((bx - ax) / L, (by - ay) / L, (bz - az) / L)
    psi = math.degrees(math.atan2(d[2], d[0]))               # giro sobre la vertical
    r = math.degrees(math.asin(max(-1.0, min(1.0, d[1]))))   # elevación
    c = place(u, y, v, yaw, (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2)
    return ctx.part(nombre, c, (L, diam, diam), yaw=yaw + psi, roll=r, shape='Cylinder', parent=parent, **kw)


def _cil(ctx, parent, nombre, u, y, v, yaw, lc, length, diam, axis, **kw):
    """Cilindro con eje a lo largo de u, y o v LOCALES, centrado en el punto local lc."""
    return ctx.cylinder(nombre, place(u, y, v, yaw, *lc), length, diam, axis=axis, yaw=yaw, parent=parent, **kw)


def _marcas_uso(ctx, gui, marcas):
    """Rayones/manchas de uso (0 parts): lista de (x, y, w, h, color, transparencia, rotación) en escala UDim2."""
    for k, (px, py, w, h, col, tr, rot) in enumerate(marcas):
        ctx.frame(gui, pos=(px, 0, py, 0), size=(w, 0, h, 0), color=col, transparency=tr, rotation=rot,
                  name=f'Marca_Uso_{k + 1}', corner=(1.0, 0))


def _asiento_seat(ctx, parent, nombre, u, y, v, yaw, lc, size, **kw):
    """Part de clase Seat; yaw+180 para que el LookVector apunte hacia -v (el alumno mira hacia -v con yaw=0)."""
    return ctx.part(nombre, place(u, y, v, yaw, *lc), size, cls='Seat', yaw=yaw + 180, parent=parent, **kw)


# ---------------------------------------------------------------- PUPITRE AZUL (ref. Pupitre_16)
def build_pupitre_azul(ctx, parent, u, y, v, yaw=0):
    """Silla-pupitre universitaria de plástico azul (16,58,140) con estructura tubular metálica oscura
    (26,29,28), tableta ovalada a la DERECHA del alumno, rejilla porta-libros bajo el asiento y respaldo
    curvo. 26 parts (tope 26). (u,y,v) = centro de la base en el piso; yaw=0 → el alumno mira hacia -v,
    respaldo en +v y tableta hacia -u (su derecha; ver docstring del módulo).

    Medidas (de Pupitre_16): asiento 1.65 x 1.65 con cara superior en 1.71; respaldo 2.09..3.24 inclinado
    12° hacia atrás y curvado (3 tablas); tableta elíptica 1.36 x 1.54 con cara superior en 2.51; patas
    ligeramente abiertas; huella 2.25 (u) x 2.40 (v). Devuelve el índice del Model.
    """
    m = ctx.model('Pupitre_Azul', parent=parent)
    H_MARCO = 1.50                       # eje del marco tubular que sostiene el asiento
    V_FRENTE, V_ATRAS, U_MARCO = -0.60, 0.66, 0.66
    # --- 4 patas tubulares (de los pies, algo más abiertos, hasta las esquinas del marco)
    for su, lado in ((-1, 'Der'), (1, 'Izq')):
        for sv, pos in ((-1, 'Delantera'), (1, 'Trasera')):
            _tubo(ctx, m, f'Pata_{pos}_{lado}', u, y, v, yaw,
                  (su * 0.77, 0.012, sv * 0.93), (su * U_MARCO, H_MARCO, V_FRENTE if sv < 0 else V_ATRAS), 0.10,
                  color=TUBO_OSCURO, material='Metal')
        _cil(ctx, m, f'Marco_Asiento_{lado}', u, y, v, yaw, (su * U_MARCO, H_MARCO, (V_FRENTE + V_ATRAS) / 2),
             V_ATRAS - V_FRENTE + 0.10, 0.10, axis='v', color=TUBO_OSCURO, material='Metal')
    # --- marco del asiento (frente / atrás) y travesaños bajos entre patas
    _cil(ctx, m, 'Marco_Asiento_Frente', u, y, v, yaw, (0, H_MARCO, V_FRENTE), 2 * U_MARCO + 0.10, 0.10, axis='u',
         color=TUBO_OSCURO, material='Metal')
    _cil(ctx, m, 'Marco_Asiento_Atras', u, y, v, yaw, (0, H_MARCO, V_ATRAS), 2 * U_MARCO + 0.10, 0.10, axis='u',
         color=TUBO_OSCURO, material='Metal')
    _cil(ctx, m, 'Travesano_Bajo_Frente', u, y, v, yaw, (0, 0.76, -0.77), 1.44, 0.07, axis='u',
         color=TUBO_OSCURO, material='Metal')
    _cil(ctx, m, 'Travesano_Bajo_Atras', u, y, v, yaw, (0, 0.76, 0.80), 1.44, 0.07, axis='u',
         color=TUBO_OSCURO, material='Metal')
    # --- asiento: tabla central (Seat) + dos tablas laterales levantadas 9° (concha curva)
    seat = _asiento_seat(ctx, m, 'Asiento', u, y, v, yaw, (0, 1.65, 0.0), (0.98, 0.12, 1.65),
                         color=AZUL, material='SmoothPlastic')
    g = ctx.surface_gui(seat, face_toward(yaw + 180, (0, 1, 0)), pixels_per_stud=60, light_influence=1.0)
    _marcas_uso(ctx, g, [(0.22, 0.30, 0.012, 0.34, MARCA_CLARA, 0.86, 0), (0.70, 0.55, 0.010, 0.22, MARCA_CLARA, 0.90, 0)])
    for s, lado in ((-1, 'Der'), (1, 'Izq')):
        _caja(ctx, m, f'Asiento_Lado_{lado}', u, y, v, yaw, (s * 0.68, 1.69, 0.0), (0.42, 0.12, 1.50),
              roll=s * 9, color=AZUL, material='SmoothPlastic')
    # --- respaldo curvo: tabla central + dos laterales giradas 16° hacia el alumno, todas inclinadas 12°
    _caja(ctx, m, 'Respaldo_Centro', u, y, v, yaw, (0, 2.67, 0.91), (0.98, 1.17, 0.12), pitch=-12,
          color=AZUL, material='SmoothPlastic')
    for s, lado in ((-1, 'Der'), (1, 'Izq')):
        _caja(ctx, m, f'Respaldo_Lado_{lado}', u, y, v, yaw, (s * 0.69, 2.67, 0.85), (0.42, 1.10, 0.12),
              yaw_local=-s * 16, pitch=-12, color=AZUL, material='SmoothPlastic')
        _tubo(ctx, m, f'Montante_Respaldo_{lado}', u, y, v, yaw, (s * 0.68, H_MARCO, V_ATRAS + 0.06), (s * 0.68, 3.06, 1.08),
              0.09, color=TUBO_OSCURO, material='Metal')
    _cil(ctx, m, 'Travesano_Respaldo', u, y, v, yaw, (0, 2.28, 0.92), 1.42, 0.07, axis='u',
         color=TUBO_OSCURO, material='Metal')
    # --- rejilla porta-libros (1 part delgada semitransparente + barras dibujadas con Frames)
    rj = _caja(ctx, m, 'Rejilla_Portalibros', u, y, v, yaw, (0, 0.815, 0.015), (1.42, 0.05, 1.64),
               color=TUBO_OSCURO, material='Metal', transparency=0.30)
    for cara in ((0, 1, 0), (0, -1, 0)):   # enrejado dibujado arriba y abajo de la placa (0 parts)
        g = ctx.surface_gui(rj, face_toward(yaw, cara), pixels_per_stud=60, light_influence=1.0)
        for px, py, w, h in ((0, 0, 1, 0.04), (0, 0.96, 1, 0.04), (0, 0, 0.04, 1), (0.96, 0, 0.04, 1)):
            ctx.frame(g, pos=(px, 0, py, 0), size=(w, 0, h, 0), color=TUBO_OSCURO, name='Rejilla_Marco')
        for k in range(5):
            ctx.frame(g, pos=((k + 1) / 6 - 0.015, 0, 0, 0), size=(0.03, 0, 1, 0), color=TUBO_OSCURO, name=f'Rejilla_Barra_{k + 1}')
        for k in range(2):
            ctx.frame(g, pos=(0, 0, (k + 1) / 3 - 0.017, 0), size=(1, 0, 0.035, 0), color=TUBO_OSCURO, name=f'Rejilla_Cruce_{k + 1}')
    # --- tableta elíptica (canto oscuro + superficie) a la derecha del alumno (-u)
    TU, TV = -0.63, -0.53
    ctx.cylinder('Tableta_Canto', place(u, y, v, yaw, TU, 2.42, TV), 0.09, 1.42, axis='y', diameter2=1.60, yaw=yaw,
                 color=AZUL_OSCURO, material='SmoothPlastic', parent=m)
    tb = ctx.cylinder('Tableta_Superficie', place(u, y, v, yaw, TU, 2.48, TV), 0.06, 1.36, axis='y', diameter2=1.54,
                      yaw=yaw, color=AZUL, material='SmoothPlastic', parent=m)
    g = ctx.surface_gui(tb, face_toward(yaw, (0, 1, 0), roll=90), pixels_per_stud=60, light_influence=1.0)
    _marcas_uso(ctx, g, [(0.30, 0.42, 0.22, 0.010, MARCA_CLARA, 0.78, -12), (0.48, 0.58, 0.14, 0.010, MARCA_CLARA, 0.86, 25),
                         (0.40, 0.36, 0.10, 0.012, AZUL_OSCURO, 0.55, 70)])
    ctx.frame(g, pos=(0.56, 0, 0.30, 0), size=(0.15, 0, 0.15, 0), color=(220, 216, 202), name='Calcomania', corner=(0.15, 0))
    ctx.frame(g, pos=(0.575, 0, 0.32, 0), size=(0.06, 0, 0.11, 0), color=(182, 58, 37), name='Calcomania_Rojo')
    ctx.frame(g, pos=(0.645, 0, 0.35, 0), size=(0.04, 0, 0.07, 0), color=(230, 179, 60), name='Calcomania_Amarillo')
    # --- brazo tubular de la tableta: sube desde el marco, corre bajo la tableta y se apoya en 2 soportes
    _tubo(ctx, m, 'Brazo_Tableta_Subida', u, y, v, yaw, (-0.70, H_MARCO, 0.60), (-0.95, 2.38, 0.16), 0.11,
          color=TUBO_OSCURO, material='Metal')
    _cil(ctx, m, 'Brazo_Tableta_Horizontal', u, y, v, yaw, (-0.95, 2.38, -0.36), 1.06, 0.11, axis='v',
         color=TUBO_OSCURO, material='Metal')
    _cil(ctx, m, 'Soporte_Tableta_Transversal', u, y, v, yaw, (-0.60, 2.38, -0.66), 0.95, 0.08, axis='u',
         color=TUBO_OSCURO, material='Metal')
    _tubo(ctx, m, 'Soporte_Tableta_Frontal', u, y, v, yaw, (-0.68, H_MARCO, -0.56), (-0.93, 2.36, -0.72), 0.08,
          color=TUBO_OSCURO, material='Metal')
    return m


# ---------------------------------------------------------------- PUPITRE DE MADERA (ref. Pupitre_06 / Pupitre_02)
def build_pupitre_madera(ctx, parent, u, y, v, yaw=0):
    """Silla-pupitre de madera: tablones (120,66,30) de asiento (3) y respaldo (2 tablas inclinadas 10° con
    hombros redondeados y cantos laterales), tableta de madera clara (150,90,45) con borde frontal
    redondeado, estructura tubular de acero negro con patas abiertas. 26 parts (tope 26).
    (u,y,v) = centro de la base en el piso; yaw=0 → el alumno mira hacia -v, respaldo en +v y tableta hacia
    -u (su derecha; ver docstring del módulo).

    Medidas (Pupitre_06 escalado x0.87): asiento 1.79 x 1.84 con cara superior en 1.76; respaldo 2.43..3.60;
    tableta 0.96 x 1.64 con cara superior en 2.53; huella 2.45 (u) x 2.40 (v). Devuelve el índice del Model.
    """
    m = ctx.model('Pupitre_Madera', parent=parent)
    H_RIEL = 1.60                        # rieles tubulares bajo el asiento
    U_RIEL, V_PATA = 0.79, 0.77
    # --- estructura: patas abiertas, rieles laterales, travesaños bajos y travesaño delantero
    for su, lado in ((-1, 'Der'), (1, 'Izq')):
        for sv, pos in ((-1, 'Delantera'), (1, 'Trasera')):
            _tubo(ctx, m, f'Pata_{pos}_{lado}', u, y, v, yaw,
                  (su * 0.91, 0.005, sv * 0.89), (su * U_RIEL, H_RIEL, sv * V_PATA), 0.09,
                  color=TUBO_NEGRO, material='Metal')
        _cil(ctx, m, f'Riel_Asiento_{lado}', u, y, v, yaw, (su * U_RIEL, H_RIEL, 0.0), 2 * V_PATA + 0.09, 0.09, axis='v',
             color=TUBO_NEGRO, material='Metal')
        _cil(ctx, m, f'Travesano_Bajo_{lado}', u, y, v, yaw, (su * 0.855, 0.70, 0.0), 1.62, 0.07, axis='v',
             color=TUBO_NEGRO, material='Metal')
    _cil(ctx, m, 'Travesano_Asiento_Frente', u, y, v, yaw, (0, 1.58, -0.67), 2 * U_RIEL + 0.09, 0.08, axis='u',
         color=TUBO_NEGRO, material='Metal')
    # --- asiento contorneado: tablón doble central (Seat, con junta dibujada) + tablones delantero y trasero
    seat = _asiento_seat(ctx, m, 'Asiento', u, y, v, yaw, (0, 1.69, -0.01), (1.79, 0.15, 0.92),
                         color=MADERA, material='Wood')
    g = ctx.surface_gui(seat, face_toward(yaw + 180, (0, 1, 0)), pixels_per_stud=60, light_influence=1.0)
    ctx.frame(g, pos=(0, 0, 0.49, 0), size=(1, 0, 0.02, 0), color=JUNTA, name='Junta_Tablones')
    _marcas_uso(ctx, g, [(0.30, 0.25, 0.16, 0.014, MARCA_CLARA, 0.72, 8), (0.62, 0.70, 0.10, 0.014, MARCA_CLARA, 0.80, -15)])
    _caja(ctx, m, 'Tablon_Asiento_Delantero', u, y, v, yaw, (0, 1.72, -0.67), (1.62, 0.15, 0.46), pitch=-6,
          color=MADERA, material='Wood')
    _caja(ctx, m, 'Tablon_Asiento_Trasero', u, y, v, yaw, (0, 1.71, 0.65), (1.62, 0.15, 0.46), pitch=6,
          color=MADERA, material='Wood')
    # --- respaldo: dos tablas dobles inclinadas 10° hacia atrás, cantos redondeados y hombros
    for nombre, ly, lv, w in (('Respaldo_Bajo', 2.72, 0.80, 1.66), ('Respaldo_Alto', 3.27, 0.89, 1.60)):
        r = _caja(ctx, m, nombre, u, y, v, yaw, (0, ly, lv), (w, 0.58, 0.15), pitch=-10, color=MADERA, material='Wood')
        g = ctx.surface_gui(r, face_toward(0, (0, 0, -1), pitch=-10), pixels_per_stud=60, light_influence=1.0)
        ctx.frame(g, pos=(0, 0, 0.49, 0), size=(1, 0, 0.025, 0), color=JUNTA, name='Junta_Tablones')
        if nombre == 'Respaldo_Alto':
            _marcas_uso(ctx, g, [(0.12, 0.30, 0.08, 0.03, (90, 48, 20), 0.35, 0), (0.55, 0.62, 0.12, 0.03, (70, 36, 14), 0.3, 0),
                                 (0.78, 0.20, 0.06, 0.04, (90, 48, 20), 0.4, 0)])
    for s, lado in ((-1, 'Der'), (1, 'Izq')):
        _tubo(ctx, m, f'Canto_Respaldo_{lado}', u, y, v, yaw, (s * 0.81, 2.57, 0.78), (s * 0.81, 3.30, 0.91), 0.11,
              color=MADERA_MEDIA, material='Wood')
        ctx.ball(f'Hombro_Respaldo_{lado}', place(u, y, v, yaw, s * 0.70, 3.49, 0.95), 0.26, color=MADERA, material='Wood', parent=m)
        _tubo(ctx, m, f'Montante_Respaldo_{lado}', u, y, v, yaw, (s * 0.72, H_RIEL - 0.02, 0.78), (s * 0.72, 3.45, 1.03), 0.09,
              color=TUBO_NEGRO, material='Metal')
    _cil(ctx, m, 'Travesano_Respaldo', u, y, v, yaw, (0, 2.50, 0.86), 1.52, 0.07, axis='u',
         color=TUBO_NEGRO, material='Metal')
    # --- tableta de madera clara (3 tablones dibujados) con borde frontal redondeado, a la derecha (-u)
    TU = -0.99
    tb = _caja(ctx, m, 'Tableta_Madera', u, y, v, yaw, (TU, 2.47, -0.44), (0.96, 0.12, 1.64),
               color=MADERA_CLARA, material='Wood')
    g = ctx.surface_gui(tb, face_toward(yaw, (0, 1, 0)), pixels_per_stud=60, light_influence=1.0)
    for k in (1, 2):
        ctx.frame(g, pos=(0, 0, k / 3 - 0.008, 0), size=(1, 0, 0.016, 0), color=JUNTA, name=f'Junta_Tableta_{k}')
    _marcas_uso(ctx, g, [(0.25, 0.20, 0.30, 0.008, MARCA_CLARA, 0.70, 0), (0.55, 0.75, 0.20, 0.008, MARCA_CLARA, 0.78, 0),
                         (0.40, 0.48, 0.12, 0.010, (60, 36, 18), 0.5, 0)])
    _cil(ctx, m, 'Tableta_Borde_Redondeado', u, y, v, yaw, (TU, 2.47, -1.26), 0.82, 0.13, axis='u',
         color=MADERA_CLARA, material='Wood')
    # --- soportes de la tableta: riel bajo la tableta + 2 postes inclinados desde el riel del asiento
    _cil(ctx, m, 'Riel_Tableta', u, y, v, yaw, (-1.02, 2.39, -0.46), 1.60, 0.08, axis='v',
         color=TUBO_NEGRO, material='Metal')
    _tubo(ctx, m, 'Soporte_Tableta_Trasero', u, y, v, yaw, (-0.80, H_RIEL, 0.45), (-1.02, 2.40, 0.30), 0.08,
          color=TUBO_NEGRO, material='Metal')
    _tubo(ctx, m, 'Soporte_Tableta_Delantero', u, y, v, yaw, (-0.80, H_RIEL, -0.72), (-1.02, 2.40, -0.84), 0.08,
          color=TUBO_NEGRO, material='Metal')
    return m


# ---------------------------------------------------------------- selftest
def _centro_local(ctx, idx):
    return world_to_local(ctx.insts[idx]['props']['CFrame'][1][0])


def _hijo(ctx, idx, nombre):
    for i in ctx.descendants(idx):
        if ctx.insts[i]['props'].get('Name', (0, b''))[1] == nombre.encode():
            return i
    return None


def selftest():
    ctx = Ctx()
    raiz = ctx.folder('Prueba_Comp_Pupitres')
    casos = [
        ('azul_0', lambda: build_pupitre_azul(ctx, raiz, 0.0, 0.42, 0.0, yaw=0)),
        ('madera_0', lambda: build_pupitre_madera(ctx, raiz, 5.0, 0.42, 0.0, yaw=0)),
        ('azul_90', lambda: build_pupitre_azul(ctx, raiz, 10.0, 0.42, 0.0, yaw=90)),
        ('madera_90', lambda: build_pupitre_madera(ctx, raiz, 15.0, 0.42, 0.0, yaw=90)),
    ]
    out = []
    for nombre, fn in casos:
        idx = fn()
        n = ctx.count_parts(idx)
        lo, hi = ctx.bbox(idx)
        print(f'{nombre:10s} parts={n:2d} bbox lo=({lo[0]:.2f},{lo[1]:.2f},{lo[2]:.2f}) hi=({hi[0]:.2f},{hi[1]:.2f},{hi[2]:.2f}) '
              f'ext=({hi[0]-lo[0]:.2f},{hi[1]-lo[1]:.2f},{hi[2]-lo[2]:.2f})')
        seats = [i for i in ctx.descendants(idx) if ctx.insts[i]['cls'] == 'Seat']
        assert len(seats) == 1 and n <= 26, (nombre, n, len(seats))
        # comprobación de lateralidad: la tableta queda a la derecha del alumno (yaw=0 → -u; yaw=90 → -v)
        tab = _hijo(ctx, idx, 'Tableta_Superficie' if nombre.startswith('azul') else 'Tableta_Madera')
        res = _hijo(ctx, idx, 'Respaldo_Centro' if nombre.startswith('azul') else 'Respaldo_Bajo')
        ct, cr, cs = _centro_local(ctx, tab), _centro_local(ctx, res), _centro_local(ctx, seats[0])
        du_t, dv_t = ct[0] - cs[0], ct[2] - cs[2]
        du_r, dv_r = cr[0] - cs[0], cr[2] - cs[2]
        print(f'           tableta respecto al asiento: du={du_t:+.2f} dv={dv_t:+.2f} | respaldo: du={du_r:+.2f} dv={dv_r:+.2f} '
              f'| asiento y={cs[1]:.2f}')
        if nombre.endswith('_0'):
            assert du_t < -0.5 and abs(dv_t) < 0.6 and dv_r > 0.5, 'yaw=0: tableta debe estar en -u y respaldo en +v'
        else:
            assert dv_t < -0.5 and abs(du_t) < 0.6 and du_r < -0.5, 'yaw=90: tableta debe estar en -v y respaldo en -u'
        render_ctx(ctx, f'../out/comp_pupitres_{nombre}.png', idx=idx, scale=60)
        out.append((nombre, idx, n, lo, hi))
    render_ctx(ctx, '../out/comp_pupitres_preview.png', idx=raiz, scale=30)
    try:
        from render3d import render_ctx3d
        render_ctx3d(ctx, '../out/comp_pupitres_3d.png', idx=raiz, scale=40)
    except Exception as e:  # el render oblicuo es opcional
        print('render3d no disponible:', e)
    ctx.export('../out/comp_pupitres_selftest.rbxm')
    return out


if __name__ == '__main__':
    selftest()
