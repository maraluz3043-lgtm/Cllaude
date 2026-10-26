# Colegio RP — Instituto Educativo Jean Piaget (Roblox Studio)

Producción: **Horizon Studios by Adrian**. Versión 2.0.0 (2026-10-26).

Transforma el colegio ya construido (`COLEGIO_JEAN_PIAGET.rbxl`) en una experiencia de simulación escolar y roleplay: carga e intro, menú, cargos con permisos reales, jornada sincronizada, aulas con asientos y tablero, cuadernos, comedor gratuito, cafetería con vendedor, cocina, baños, PCs, puertas, cancha de fútbol, funciones del personal, soporte y moderación, dos modos gráficos y seguridad de servidor. **Nada del mapa original se modifica**: todo se instala en carpetas propias y se puede desinstalar.

## Empezar en 3 pasos

1. Abre el lugar en Roblox Studio y haz una copia de seguridad (publicar versión + `herramientas/Respaldo_Scripts.lua` en la Command Bar).
2. Explorer → **Workspace** → *Insert from File…* → `dist/ColegioRP.rbxmx`, y en la Command Bar:
   ```lua
   require(workspace.ColegioRP_Paquete.Instalador)()
   ```
   (alternativa: pegar `dist/Instalador_ColegioRP.lua` entero en la Command Bar).
3. Play. Verás la carga, la intro y el menú; elige un cargo en JUGAR. Después configura `ReplicatedStorage/ColegioRP/Shared/Config` (id del logo, autorizaciones de cargos, sonidos).

Guía completa: [`docs/D_Instalacion.md`](docs/D_Instalacion.md).

## Entregables (formato del prompt maestro)

| Entregable | Archivo |
|---|---|
| A. Diagnóstico del mapa (zonas reales, evidencia, problemas, spawns) | [`docs/A_Diagnostico_Mapa.md`](docs/A_Diagnostico_Mapa.md) · datos: [`mapa/zonas.json`](mapa/zonas.json) · planos: `mapa/plano_cenital*.png` |
| B. Plan de modificación no destructiva | [`docs/B_Plan_Modificacion.md`](docs/B_Plan_Modificacion.md) |
| C. Código Luau por archivo (ruta en el Explorer, tipo, código) | [`docs/C_Codigo.md`](docs/C_Codigo.md) · fuentes: [`src/`](src/) · contrato: [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) |
| D. Instalación | [`docs/D_Instalacion.md`](docs/D_Instalacion.md) · paquete: [`dist/`](dist/) · herramientas: [`herramientas/`](herramientas/) |
| E. Contenido de UI | [`docs/E_UI.md`](docs/E_UI.md) |
| F. Recursos audiovisuales | [`docs/F_Recursos.md`](docs/F_Recursos.md) · logo: `assets/logo_instituto_jean_piaget.png` |
| G. Pruebas | [`docs/G_Pruebas.md`](docs/G_Pruebas.md) |
| H. Informe final | [`docs/H_Informe_Final.md`](docs/H_Informe_Final.md) · [`CHANGELOG.md`](CHANGELOG.md) |

## Estructura del repositorio

```
src/                      código Luau (estilo Rojo: .lua = ModuleScript, .server.lua = Script, .client.lua = LocalScript)
  ReplicatedFirst/        ColegioRP_Carga (pantalla de carga + intro)
  ReplicatedStorage/      ColegioRP/Shared (Config, roles, horario, contratos, tema, catálogos, MapaLogico, Util)
  ServerScriptService/    ColegioRP/Main + Services (23 servicios)
  StarterPlayer/          StarterPlayerScripts/ColegioRP/Main + Controllers + UI/UIBuilder
dist/                     ColegioRP.rbxmx, Instalador_ColegioRP.lua, manifest.json (generados por tools/build.py)
herramientas/             scripts de Command Bar: Auditoria_Mapa, Respaldo_Scripts, Desinstalar, Instalador
mapa/                     zonas.json (mapa lógico auditado) y planos cenitales
docs/                     ARQUITECTURA + entregables A–H
tools/                    gen_mapa_logico.py (zonas.json → MapaLogico.lua), build.py (empaquetado), check_lua.js (sintaxis)
assets/                   logo del colegio
Salones_Realistas.lua     (entrega anterior) recreación de los salones 6B/7B por Command Bar
default.project.json      proyecto Rojo
```

## Desarrollo

- Regenerar el mapa lógico tras editar `mapa/zonas.json`: `python3 tools/gen_mapa_logico.py`
- Verificar sintaxis: `cd tools && npm install && cd .. && node tools/check_lua.js src`
- Empaquetar: `python3 tools/build.py` → `dist/`
- Sincronizar en vivo con Rojo 7: `rojo serve default.project.json`

Convenciones de código: Luau en sintaxis compatible con el verificador (sin `continue`, sin `+=`, sin anotaciones de tipo), español en UI y comentarios, autoridad total del servidor. Ver [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md).

---

## Salones 6B y 7B — recreación realista (entrega anterior)

Script único en Luau (`Salones_Realistas.lua`) que reconstruye, en un solo pegado en la **Command Bar** de Roblox Studio (modo edición), los dos salones de las fotografías de referencia: la fachada del corredor con las puertas **6B** (verde) y **7B** (metálica blanca), y los dos interiores completos. Es independiente del sistema Colegio RP (construye un módulo aparte en `workspace.Salones_Realistas`; no toca las aulas 6B/7B reales del mapa).

### Cómo usarlo

1. Abrir el lugar en Roblox Studio (modo edición) y mostrar la Command Bar (`Vista > Command Bar`).
2. Copiar **todo** el contenido de `Salones_Realistas.lua`, pegarlo en la Command Bar y pulsar Enter.
3. Aparece `workspace.Salones_Realistas` con `Estructura`, `Corredor`, `Salon_1_6B` y `Salon_2_7B`. En **Output** se imprime el resumen.
4. Para mover la construcción cambiar `ORIGEN` (studs) al principio del script; para cambiar la escala, `ESCALA` (studs por metro).
5. Volver a ejecutar el script reemplaza únicamente el modelo generado por él (atributo `GeneradoPorScriptSalones`); nunca toca otros objetos. `Ctrl+Z` deshace la generación completa.

Interpretación de las fotos, valores por defecto, presupuesto de Parts (803 / 1000) y escala: ver [`docs/Salones_6B_7B.md`](docs/Salones_6B_7B.md) (`preview/` contiene las vistas previas).
