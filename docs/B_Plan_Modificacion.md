# B. Plan de modificación no destructiva

Objetivo: convertir el colegio existente en una experiencia de simulación escolar sin reconstruirlo ni borrar nada. Todo lo que añade Colegio RP es **separable** (carpetas propias) y **reversible** (`herramientas/Desinstalar.lua`).

## B.1 Dependencias

| Dependencia | Estado | Quién la resuelve |
|---|---|---|
| Archivo `COLEGIO_JEAN_PIAGET.rbxl` | Recibido y auditado (ver A) | — |
| Logo oficial (`assets/logo_instituto_jean_piaget.png`, 308×307) | Recibido; **falta subirlo a Roblox** como Decal/Imagen y pegar el id en `Config.LogoAssetId` | Usuario (Creator Hub → Development Items → Decals) |
| Sonidos (timbre, clic de UI, puerta, gol, notificación) | Ids = 0 (silencio) hasta que se verifiquen sonidos con licencia | Usuario; el sistema funciona sin ellos |
| Uniformes por cargo (camisa/pantalón) | Ids = 0 (no se cambia la ropa del avatar) | Usuario (opcional) |
| Lista de UserIds autorizados a cargos profesionales | `Config.Autorizaciones.PorUserId` vacío; en Studio todos los cargos están disponibles (`ModoPruebasEnStudio`) | Usuario |
| Grupo de Roblox (opcional) | `Config.Autorizaciones.GrupoRoblox.GroupId = 0` | Usuario |
| Integración con Adonis (opcional) | Detectada automáticamente por `_G.Adonis` si `UsarAdonis = true` | Nada que hacer |
| Lista de integrantes de Horizon Studios | `Catalogs.Equipo` con "Adrian · Director del proyecto" y filas editables | Usuario |
| Contenido inicial de "Actualizaciones" | `Catalogs.Changelog` v2.0.0 (esta entrega) | Editable |
| API de DataStore activa en el lugar publicado | Necesaria para guardar perfiles; en Studio sin API el sistema usa memoria y avisa | Usuario (Game Settings → Security → Enable Studio Access to API Services) |

## B.2 Qué se conserva (sin tocar)

- Toda la geometría, materiales, texturas, luces, sonidos, `SurfaceGui` decorativas, árboles y terreno.
- Todos los scripts existentes (Adonis, ventiladores, espejo, cortinas, inodoros, aires).
- El `SpawnLocation` original (sigue siendo neutral; sirve de respaldo).
- `Lighting` (Future, sombras, SunRays, Atmosphere, ColorCorrection). El modo bajos recursos cambia efectos **solo localmente** en el cliente.
- `Players.MaxPlayers = 60`, `RespawnTime = 3`, `CharacterWalkSpeed = 16`.

## B.3 Qué se añade (todo nuevo y separable)

| Ubicación | Contenido | Reversión |
|---|---|---|
| `ReplicatedFirst/ColegioRP_Carga` | Pantalla de carga e intro | Borrar la carpeta |
| `ReplicatedStorage/ColegioRP` | `Shared` (configuración, roles, horario, contratos, tema, catálogos, mapa lógico, utilidades), `Remotes` (creados al arrancar), `Version` | Borrar la carpeta |
| `ServerScriptService/ColegioRP` | `Main` + 23 servicios | Borrar la carpeta |
| `StarterPlayer/StarterPlayerScripts/ColegioRP` | `Main` + 15 controladores + `UIBuilder` | Borrar la carpeta |
| `Workspace/ColegioRP_Mapa` | Marcadores invisibles generados **en cada arranque** desde `MapaLogico`: zonas, spawns, aulas (referencias a los Seats reales), tableros (Part fina con `SurfaceGui` sobre la pizarra real), PCs (pantalla `SurfaceGui` sobre el monitor real), estaciones de cocina, mostrador de cafetería, balón/arcos/marcador | Se borra solo al cerrar; puede eliminarse en Studio sin pérdida |
| `Teams` | 6 equipos creados por `RoleService` al arrancar | Se recrean; se pueden borrar |
| `ServerStorage/ColegioRP_Respaldos` | Copias de versiones anteriores (instalador) | Conservar |
| Atributos/tags en objetos existentes | `RoomId` + tag `ColegioRP_Asiento` en Seats de aula; `PcId` + tag en monitores; `PuertaId` + tag en hojas; `ObjetoId` + tag en lavamanos/inodoros; tag `ColegioRP_Decoracion` en modelos pesados; `ProximityPrompt` hijos en puertas, estaciones y objetos de baño | `herramientas/Desinstalar.lua` los retira |

**Nada se reemplaza.** Si en el futuro se desea una versión estética de alto detalle de un objeto (pupitre, computador, lámpara), se añade como variante nueva con tag `ColegioRP_Calidad_Alta` junto al original (tag `ColegioRP_Calidad_Baja`); el cliente muestra una u otra según el modo gráfico. En esta entrega no se incluyen variantes de malla (requiere activos propios subidos por el usuario).

## B.4 Decisiones de materiales y gráficos

- **Modo CALIDAD**: el mapa tal cual (Future lighting, sombras, SunRays, PBR de árboles, espejo, ventiladores animados).
- **Modo BAJOS RECURSOS** (local): `GlobalShadows` off, efectos de `Lighting` desactivados, `Atmosphere.Density` reducida, partículas/Beams off, `LocalTransparencyModifier = 1` sobre modelos etiquetados como decoración pesada a más de `Config.Graficos.DistanciaDecoracionLejana` (350 studs) o siempre si se desactiva "decoración lejana", espejo desactivado, sonidos ambientales en silencio, animaciones cosméticas (ventiladores) ocultas. No se cambia `Lighting.Technology` ni `QualityLevel` (no modificables por scripts en ejecución).
- **Automático**: Bajos en móvil/tableta (`UserInputService.TouchEnabled` sin teclado) y Calidad en PC/consola; el jugador puede cambiarlo y se guarda.
- Texturas: no se añaden texturas nuevas (sin activos). Las `SurfaceGui` nuevas usan texto y vectores (coste bajo).

## B.5 Rollback

1. `herramientas/Desinstalar.lua` en la Command Bar (mueve las carpetas a `ServerStorage/ColegioRP_Respaldos`, borra `Workspace/ColegioRP_Mapa`, retira tags/atributos y prompts añadidos).
2. O bien `Ctrl+Z` inmediatamente después de instalar (la instalación es un único punto de deshacer).
3. O bien restaurar la versión publicada anterior desde "Version History" del lugar (recomendado publicar una versión antes de instalar).
4. Antes de instalar por primera vez: ejecutar `herramientas/Respaldo_Scripts.lua` para copiar todos los scripts originales con su ruta.

## B.6 Orden de integración (fases del prompt maestro)

| Fase | Entregable | Estado en esta entrega |
|---|---|---|
| 0 Descubrimiento | Auditoría binaria + `mapa/zonas.json` + planos | Hecho (A) |
| 1 Fundaciones | Carpetas, Config, módulos, remotos, permisos, spawns, estado de servidor | Código (C) |
| 2 UI e ingreso | Carga, intro, menú, ayuda/soporte, HUD/relojes | Código (C, E) |
| 3 Jornada y clases | Horarios, aulas, asientos, profesor, tablero, cuadernos, respuestas | Código (C) |
| 4 Interacciones | Puertas, baños, PC, comedor, cocina, cafetería, cancha | Código (C) |
| 5 Roles avanzados | Funciones del personal, anuncios, moderación | Código (C) |
| 6 Gráficos y perfilado | Modos Calidad/Bajos, ajustes, métricas | Código (C) + guía de medición (G) |
| 7 Cierre y QA | Pruebas, changelog, versión | G, H, CHANGELOG |

Cada fase se puede desactivar por servicio quitándolo de `Config.OrdenServicios` (el resto sigue funcionando).
