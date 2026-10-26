# API de construcción (build.py / preview.py)

Directorio de trabajo: `/tmp/claude-0/-home-user-Cllaude/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/scratchpad/tools`
Ejecutar SIEMPRE desde ese directorio con `python3 -s <script>.py` (numpy, PIL y lz4 están instalados).
Referencias (texto + PNG con vistas frente/lado/planta) y fotos del usuario en `../ref/`.

## Marco local (u, y, v) — estudiado del edificio real del usuario
- **u**: a lo largo de la fachada, crece hacia la DERECHA para alguien parado en el patio mirando la fachada.
- **y**: vertical (= Y del mundo). Acera / piso terminado en **y = 0.42**. Losa de techo de la planta baja desde y = 13.03.
- **v**: profundidad HACIA DENTRO del edificio. v = 0 en el eje de las columnas de fachada; muro de fachada ocupa v 0.40..1.40;
  el interior del salón empieza en v = 1.40. El corredor/patio está en v < 0.
- Escala aproximada: **1 m ≈ 4 studs** (puertas 8.4-8.9 studs de alto, pupitres 3.2 de alto, techo interior a 12.6 studs del piso).
- Las posiciones que recibe la API son CENTROS de part (como en Roblox). `size=(w,h,d)`: w a lo largo de u, h a lo largo de y, d a lo largo de v (con yaw=0).
- `yaw` (grados) gira el part sobre el eje vertical: con yaw=90 el ancho w queda a lo largo de +v. `pitch` gira sobre el propio eje de ancho (inclinar hacia arriba/abajo), `roll` sobre el eje de profundidad.
- Cilindros de Roblox: su eje es el eje X (ancho) del part; usa el helper `ctx.cylinder(..., axis='y'|'u'|'v')` y no te preocupes.

## Uso
```python
from build import Ctx, FACE, face_toward, FONT_GOTHAM, FONT_FREDOKA, FONT_BANGERS, FONT_PERMANENT, FONT_SOURCE
from preview import render_ctx

ctx = Ctx()
m = ctx.model('Pupitre', parent=-1)                      # Model (parent=-1 → raíz). Devuelve índice.
ctx.box('Asiento', (u, y, v), (w, h, d), color=(16,58,140), material='SmoothPlastic', parent=m)
ctx.cylinder('Pata', (u, y, v), length=2.0, diameter=0.12, axis='y', color=(26,29,28), material='Metal', parent=m)
ctx.cylinder('Barra', (u, y, v), 1.2, 0.1, axis='u', parent=m)          # eje a lo largo de u
ctx.cylinder('Barra2', (u, y, v), 1.2, 0.1, axis='v', parent=m)         # eje a lo largo de v
ctx.cylinder('Inclinada', (u,y,v), 1.0, 0.1, axis='y', pitch=30, parent=m)  # también acepta yaw/pitch/roll
ctx.ball('Pomo', (u, y, v), diameter=0.3, color=(200,200,200), material='Metal', parent=m)
ctx.wedge('Cuna', (u,y,v), (w,h,d), parent=m)            # WedgePart (cara vertical hacia +v, pendiente baja hacia -v con yaw=0)
ctx.part('Asiento', (u,y,v), (w,h,d), cls='Seat', ...)   # Seat = part donde un avatar se puede sentar (cuenta como part)
ctx.box(..., transparency=0.4, reflectance=0.1, cancollide=False, castshadow=False)   # opciones extra
# Materiales válidos (string): Plastic, SmoothPlastic, Neon, Wood, WoodPlanks, Marble, Slate, Concrete, Granite, Brick,
#   Pebble, Cobblestone, Metal, CorrodedMetal, DiamondPlate, Foil, Fabric, Glass, Ice, Grass, Sand, Ground, Cardboard,
#   Carpet, CeramicTiles, Leather, Plaster, Rubber, Asphalt, ForceField

# Texto sobre una cara (0 parts): SurfaceGui + TextLabel. direction = vector LOCAL (du,dy,dv) hacia donde mira la cara:
# (0,0,-1) = hacia el corredor/patio (fachada), (0,0,1) = hacia el interior, (1,0,0) = hacia +u, (0,1,0) = hacia arriba.
p = ctx.box('Letrero', (u,y,v), (3,1,0.1), color=(240,240,240), parent=m)
ctx.label_on(p, 'GRADO 5°', direction=(0,0,-1), color=(255,255,255), font=FONT_FREDOKA, stroke=(0,0,0),
             pos=(0.05,0,0.1,0), size=(0.9,0,0.8,0))     # pos/size = UDim2 (scaleX, offX, scaleY, offY) dentro de la cara
# Decoración plana con Frames (0 parts), p.ej. una rejilla de puntos o una luna:
g = ctx.surface_gui(p, face_toward(0, (0,0,-1)), pixels_per_stud=50)
ctx.frame(g, pos=(0.1,0,0.1,0), size=(0.2,0,0.2,0), color=(40,40,45), corner=(1.0,0))   # corner=(scale,offset) redondea
# Luz (0 parts): ctx.light(part_idx, 'SurfaceLight', face=FACE['Bottom'], brightness=1.2, range_=18)  o 'PointLight'

print(ctx.count_parts(m), ctx.bbox(m))                    # bbox → (lo, hi) en (u,y,v)
render_ctx(ctx, '../out/mi_componente.png', idx=m, scale=40)   # frente | lado | planta — luego míralo con la herramienta Read
ctx.export('../out/mi_componente.rbxm')                   # opcional
```
Convención para funciones de componente: `build_xxx(ctx, parent, u, y, v, yaw=0, **opciones) -> idx_model` donde (u, y, v)
es el punto de APOYO del objeto (centro de su base en el piso para muebles; centro de la base de la hoja para puertas;
centro del panel para objetos de pared) y `yaw` orienta el objeto (yaw=0 = "mirando hacia -v", es decir hacia el corredor/fachada;
para un pupitre, yaw=0 significa que el alumno sentado mira hacia -v). Dentro de la función, calcula las posiciones de las
piezas en un sistema local centrado en (0,0,0) y aplica la rotación con el helper `place(u,y,v,yaw, lu,ly,lv)` que puedes
copiar de abajo (gira (lu,lv) alrededor del eje vertical con el mismo convenio de yaw que la API) y pasa `yaw=yaw+yaw_local` a cada part:
```python
import math
def place(u, y, v, yaw, lu, ly, lv):
    t = math.radians(yaw)
    return (u + lu*math.cos(t) - lv*math.sin(t), y + ly, v + lu*math.sin(t) + lv*math.cos(t))
```
(verifica: con yaw=90, un desplazamiento local +lu se convierte en +v, igual que el ancho del part.)

Para clonar algo del modelo original (p.ej. la `Rejilla` con su SurfaceGui de puntos):
```python
from rbxm import read_rbxm
SRC = read_rbxm('/root/.claude/uploads/89bfe5c6-d7de-5dd7-bcc5-21526445fdb5/159d5810-Donde_pondras_los_salones_faltantes.rbxm')
# encontrar ref por nombre: [r for r,i in SRC['insts'].items() if i['props'].get('Name',(0,b''))[1]==b'Rejilla']
ctx.clone(SRC, ref, parent=m, du=.., dy=.., dv=.., yaw=0, pivot=(u_piv, v_piv))   # traslada en coordenadas locales
```
Para ver dónde queda un ref del original en coordenadas locales: `from build import world_to_local; world_to_local(SRC['insts'][ref]['props']['CFrame'][1][0])`.

## Reglas
- Todo anclado (por defecto). Nombres de parts en español, descriptivos (ej. `Pata_Delantera_Izq`).
- Presupuesto de parts: respeta el máximo indicado para tu componente; cuenta con `ctx.count_parts(idx)`.
- "Detallado y optimizado": pocas parts pero bien proporcionadas, colores/materiales creíbles; usa SurfaceGui/Frames/TextLabel (0 parts) para texto, rejillas, dibujos planos.
- No uses MeshId/TextureId/Decals (no hay assets). No uses Unions.
- Antes de terminar: ejecuta tu módulo, renderiza las vistas y MÍRALAS con Read; corrige proporciones. Vistas: frente = visto desde el corredor (u→derecha, y→arriba), lado = visto desde -u (v→derecha), planta (u→derecha, v→abajo).
