# D. Instrucciones de instalación

Requisitos: Roblox Studio actualizado, el lugar `COLEGIO_JEAN_PIAGET.rbxl` abierto en **modo edición**, y (para guardar datos en pruebas) *Game Settings → Security → Enable Studio Access to API Services*.

## D.1 Antes de instalar (copia de seguridad)

1. **Publicar o guardar una versión** del lugar (Archivo → Publicar / Guardar como…) para poder volver atrás desde *Version History*.
2. Pegar `herramientas/Respaldo_Scripts.lua` en la **Command Bar** (Ver → Command Bar) y pulsar Enter: copia todos los scripts originales (Adonis, ventiladores, espejo…) en `ServerStorage/ColegioRP_Respaldos/<fecha>_scripts_originales`, desactivados.
3. (Opcional) Pegar `herramientas/Auditoria_Mapa.lua`: imprime el inventario del mapa en Output para compararlo con `docs/A_Diagnostico_Mapa.md`.

## D.2 Instalar (opción recomendada: modelo .rbxmx)

1. En el Explorer, clic derecho sobre **Workspace** → *Insert from File…* → elegir `dist/ColegioRP.rbxmx`. Aparece `Workspace/ColegioRP_Paquete` con las carpetas `ReplicatedFirst`, `ReplicatedStorage`, `ServerScriptService`, `StarterPlayer`, `Instalador` y `LEEME`.
2. En la Command Bar: 
   ```lua
   require(workspace.ColegioRP_Paquete.Instalador)()
   ```
3. El instalador: verifica el paquete, respalda cualquier versión anterior en `ServerStorage/ColegioRP_Respaldos/<fecha>`, mueve cada carpeta a su servicio y elimina el paquete. Todo queda en **un solo paso de deshacer**. Output muestra el resumen.

Alternativa (sin insertar archivos): pegar **todo** el contenido de `dist/Instalador_ColegioRP.lua` en la Command Bar y pulsar Enter (hace lo mismo; el archivo es grande, así que el pegado puede tardar unos segundos).

Alternativa para desarrolladores: `default.project.json` del repositorio sirve con **Rojo 7** (`rojo serve`) para sincronizar `src/` en vivo.

## D.3 Orden de creación y conexión con el mapa (lo hace el sistema solo)

Al ejecutar (Play o servidor publicado), `ServerScriptService/ColegioRP/Main` arranca los servicios en `Config.OrdenServicios`:

1. `AuditLogService`, `DataService` (perfiles), `RemoteService` (crea `ReplicatedStorage/ColegioRP/Remotes` con todos los remotos de `RemoteContracts`).
2. `MapService` construye `Workspace/ColegioRP_Mapa` desde `Shared/MapaLogico` (las coordenadas auditadas):
   - **Zonas**: una `Part` invisible por zona (`ZoneId`, `Tipo`, `Piso`).
   - **Spawns**: una `Part` por punto (`Cargos`, `Estado` confirmado/provisional).
   - **Aulas**: un `Model` por aula con `ObjectValue` hacia cada `Seat` real que cae dentro del volumen (des-duplicando los Seats dobles de `School Chair`), `PuestoDocente` (Part) y `Tablero` (Part fina con `SurfaceGui` pegada a la pizarra real). Los Seats reciben atributo `RoomId` y tag `ColegioRP_Asiento`.
   - **PCs**: por cada `Workspace/Model/Computer` dentro de INFORMATICA, pantalla `SurfaceGui` sobre `Computer Monitor 1` y `ObjectValue` al Seat más cercano; estaciones de ROBOTICA con `Portatil_pantalla`.
   - **Cocina / Cafetería**: `ProximityPrompt` en las estaciones (Preparación, Cocción, Emplatado, Entrega, Reposición) y en el mostrador de la tienda.
   - **Cancha**: balón, volúmenes de arco y marcador.
   - **Puertas**: `ProximityPrompt` en cada puerta listada en `MapaLogico.Puertas` (hoja `Hoja_transitable`, `Hoja_Morada`, `Hoja_Blanca`, o el modelo completo).
   - Si algo del mapa no se encuentra (por ejemplo, el usuario movió o renombró una puerta), se registra una **advertencia** en Output y el resto continúa.
3. `RoleService` crea los 6 equipos y escucha `RequestJoinRole`; `SpawnService` coloca a cada jugador en su zona.
4. El resto de servicios (jornada, aulas, tablero, cuaderno, economía, comida, cafetería, fútbol, puertas, baños, PCs, reportes, moderación, anuncios, personal, métricas).

Al final, Output imprime el inventario: zonas, aulas con número de asientos detectados, PCs, puertas resueltas y advertencias.

## D.4 Configuración mínima tras instalar

Archivo `ReplicatedStorage/ColegioRP/Shared/Config`:

| Clave | Qué poner |
|---|---|
| `LogoAssetId` | Id del logo subido como Decal (ver F). 0 = logo vectorial de respaldo. |
| `Autorizaciones.PorUserId` | `{ [TU_USERID] = { "*" } }` para poder tomar cualquier cargo fuera de Studio; `{ [123] = { "ProfesorTitular", "Tutor" } }` para docentes. |
| `Autorizaciones.GrupoRoblox` | `GroupId` y rangos mínimos por cargo, si usas grupo. |
| `Autorizaciones.UsarAdonis` | `true`: los administradores de Adonis pueden tomar cualquier cargo. |
| `Autorizaciones.ModoPruebasEnStudio` | `true` (por defecto) para probar todos los cargos en Studio; **ponlo en `false` si publicas con pruebas de equipo**. |
| `Jornada.Modo` | `"Automatica"` (la jornada se repite sola) o `"Manual"` (la inicia el Director desde su panel). |
| `Jornada.AulasActivas` | Lista de aulas donde se reparten los estudiantes. |
| `Sonidos.*` | Ids de sonidos con licencia (0 = silencio). |
| `Spawns.ZonaEstudiantes` | `"PATIO_CENTRAL"` por defecto; `"ENTRADA"` si prefieres que entren por el portón. |

Nombres de aulas sin placa: edita `mapa/zonas.json` y regenera `MapaLogico` con `python3 tools/gen_mapa_logico.py`, o edita directamente `Shared/MapaLogico` (campo `Nombre`).

## D.5 Cómo enlazar aulas, Seats, tableros y spawns manualmente (si cambias el mapa)

- **Mover un aula**: cambia `Centro`/`Tamano` de la zona en `MapaLogico` (o `zonas.json`). Los Seats que queden dentro se detectan solos.
- **Añadir pupitres con asiento** (recomendado en 6B/7B): duplica `Workspace/Pupitres/Pupitre_Azul` (tiene `Asiento`), colócalos dentro del aula; al siguiente arranque se detectan.
- **Cambiar la pizarra**: edita `Tablero.Centro`/`Normal` (la normal apunta hacia el aula).
- **Cambiar un spawn**: edita `Spawn.Punto` y pon `Estado = "confirmado"` cuando lo hayas verificado en Play.
- **Puertas nuevas**: añade una entrada en `MapaLogico.Puertas` con `Ruta` exacta (`Workspace/Modelo/Hoja`), `Modo` (`estado`, `privacidad` o `giro`) y `CargosBloqueo`.
- **Sin editar código**: también puedes poner atributos directamente en Studio sobre un `Seat` (`RoomId = "6B"`) y un `Part` de spawn (en `Workspace/ColegioRP_Mapa_Manual/Spawns` con atributos `ZoneId` y `Cargos`); `MapService` respeta esos marcadores manuales si la carpeta existe.

## D.6 Verificación rápida (5 minutos)

1. Play (F5): debe verse la pantalla de carga con barra real, "Saltar", la intro de Horizon Studios y el menú.
2. JUGAR → elegir "Estudiante" → apareces en el patio central con HUD (hora real, hora escolar, estado, cargo).
3. Volver al menú (☰) → JUGAR → "Profesor/a titular" (en Studio está disponible) → apareces en el aula asignada; con el panel docente abre una sesión.
4. En *Test → Clients and Servers* (2 jugadores) comprueba P4–P7 (ver G).
5. Output del servidor: sin errores `[ColegioRP]`; advertencias solo de elementos del mapa no encontrados.

## D.7 Desinstalar / volver atrás

`herramientas/Desinstalar.lua` en la Command Bar (respalda y retira todo lo añadido) o restaurar la versión publicada anterior.

## Opción directa: lugar completo
`dist/COLEGIO_JEAN_PIAGET_ColegioRP.rbxl` es el mapa original con los 56 scripts ya colocados (ReplicatedFirst, ReplicatedStorage, ServerScriptService, StarterPlayerScripts). Ábrelo en Studio y pulsa Play; no hace falta instalador. Se regenera con:
`python3 tools/inyectar_rbxl.py <COLEGIO_JEAN_PIAGET.rbxl> dist/COLEGIO_JEAN_PIAGET_ColegioRP.rbxl` (las 123.046 instancias del mapa quedan idénticas; verificado leyendo el archivo resultante).
