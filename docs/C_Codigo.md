# C. Código Luau por archivo

El código completo y listo para copiar está en [`src/`](../src) (un archivo por instancia) y empaquetado en `dist/ColegioRP.rbxmx` y `dist/Instalador_ColegioRP.lua`. Convención: `Nombre.lua` = **ModuleScript**, `Nombre.server.lua` = **Script**, `Nombre.client.lua` = **LocalScript**; cada carpeta es un **Folder**. La ruta del Explorer es la ruta del archivo bajo `src/`.

Contrato de diseño (APIs, remotos, esquemas, permisos, ciclo de vida): [`docs/ARQUITECTURA.md`](ARQUITECTURA.md). Este índice se genera con `python3 tools/gen_doc_codigo.py`.

**16 archivos · 6413 líneas de Luau.**

## Compartido (cliente y servidor) — `ReplicatedStorage`

| Ruta en el Explorer | Tipo | Líneas | Descripción | Archivo |
|---|---|---|---|---|
| `ReplicatedStorage.ColegioRP.Shared.Catalogs` | ModuleScript | 802 | Catálogos de contenido: productos de cafetería, recetas del comedor, plantillas del tablero, actividades de PC, ayuda, changelog, equipo, uniformes, tareas de limpieza, simulador, programación, cuestionarios y decoración pesada. Solo datos y funciones puras; el servidor valida todo resultado. | [`Catalogs.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Catalogs.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Config` | ModuleScript | 321 | Configuración central de Colegio RP (Instituto Educativo Jean Piaget). Solo contiene datos: cada clave está documentada y puede ajustarse sin tocar la lógica de servicios ni controladores. Los ids de assets en 0 son DEPENDENCIAS del usuario (ver comentarios "DEPENDENCIA"). | [`Config.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Config.lua) |
| `ReplicatedStorage.ColegioRP.Shared.MapaLogico` | ModuleScript | 886 | GENERADO AUTOMÁTICAMENTE por tools/gen_mapa_logico.py a partir de mapa/zonas.json. No editar a mano. Mapa lógico del lugar COLEGIO_JEAN_PIAGET.rbxl: zonas reales con coordenadas auditadas (studs). | [`MapaLogico.lua`](../src/ReplicatedStorage/ColegioRP/Shared/MapaLogico.lua) |
| `ReplicatedStorage.ColegioRP.Shared.RemoteContracts` | ModuleScript | 508 | Contrato de todos los remotos (docs/ARQUITECTURA.md §5): tipo, dirección, límite de frecuencia, permiso requerido (fijo, nil o función(datos) -> permiso) y esquema Validate de los datos. RemoteService crea las instancias a partir de Nombres y aplica estas reglas antes de cada handler. | [`RemoteContracts.lua`](../src/ReplicatedStorage/ColegioRP/Shared/RemoteContracts.lua) |
| `ReplicatedStorage.ColegioRP.Shared.RoleDefinitions` | ModuleScript | 460 | Definición de los 17 cargos del colegio, sus equipos (Teams), colores, permisos, zona de aparición y uniforme. El servidor (RoleService) es la única autoridad sobre qué cargo tiene cada jugador; este módulo solo describe los cargos y responde a consultas de permisos. | [`RoleDefinitions.lua`](../src/ReplicatedStorage/ColegioRP/Shared/RoleDefinitions.lua) |
| `ReplicatedStorage.ColegioRP.Shared.TimetableDefinitions` | ModuleScript | 277 | Periodos de la jornada escolar (máquina de estados de SchoolDayService), materias y tolerancias. El reloj escolar avanza desde la HoraEscolar de cada periodo hasta la del siguiente de forma lineal con el tiempo real del periodo (ver HoraEscolarEn). | [`TimetableDefinitions.lua`](../src/ReplicatedStorage/ColegioRP/Shared/TimetableDefinitions.lua) |
| `ReplicatedStorage.ColegioRP.Shared.UITheme` | ModuleScript | 203 | Tema visual de la interfaz: colores institucionales (del logo), fuentes, tamaños, radios, espaciados, animaciones y detección de dispositivo para escalar el texto (PC 1, tableta 0.9, móvil 0.8). Es seguro requerirlo en el servidor (Escala() devuelve 1 y Dispositivo() "PC"). | [`UITheme.lua`](../src/ReplicatedStorage/ColegioRP/Shared/UITheme.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Util.Format` | ModuleScript | 247 | Formato de textos para la interfaz en español: horas (12/24 h), moneda escolar, duraciones, truncado seguro de UTF-8, fechas y números con separador de miles. | [`Format.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Util/Format.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Util.Maid` | ModuleScript | 132 | Recolector de tareas de limpieza: acumula conexiones, instancias, funciones, hilos y objetos con Destroy/Disconnect/DoCleaning y los libera todos con :DoCleaning() (o :Destroy()). También admite claves: maid.Nombre = tarea (reemplazar una clave limpia la tarea anterior). | [`Maid.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Util/Maid.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Util.Net` | ModuleScript | 253 | Acceso seguro a los remotos de ReplicatedStorage.ColegioRP.Remotes desde cliente y servidor. Evento/Funcion esperan la instancia (WaitForChild con timeout); en cliente, Invocar hace pcall de InvokeServer y devuelve siempre (ok, tablaRespuesta), y Disparar hace FireServer con pcall. | [`Net.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Util/Net.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Util.Signal` | ModuleScript | 130 | Señal ligera (patrón BindableEvent en Lua puro) para comunicar módulos del mismo lado sin crear instancias. API: Signal.new() -> :Connect(fn), :Once(fn), :Fire(...), :Wait(), :Destroy(). | [`Signal.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Util/Signal.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Util.Validate` | ModuleScript | 434 | Validación declarativa de datos (peticiones de remotos y cualquier tabla). Un esquema describe campos y tipos; Validate.Comprobar(esquema, valor) devuelve ok y un mensaje legible en español. Por defecto los esquemas son estrictos (rechazan claves desconocidas) y acotan tamaño y anidación. Descriptores de campo… | [`Validate.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Util/Validate.lua) |
| `ReplicatedStorage.ColegioRP.Shared.Util.Zones` | ModuleScript | 287 | Consultas geométricas sobre MapaLogico (zonas como cajas alineadas a los ejes: Centro ± Tamano/2). Funciona en cliente y servidor; no crea instancias. ZonaDe(posicion) prioriza la zona más pequeña cuando varias contienen el punto (p. ej. un aula dentro de un patio amplio). | [`Zones.lua`](../src/ReplicatedStorage/ColegioRP/Shared/Util/Zones.lua) |

## Servidor — `ServerScriptService`

| Ruta en el Explorer | Tipo | Líneas | Descripción | Archivo |
|---|---|---|---|---|
| `ServerScriptService.ColegioRP.Main` | Script | 279 | Arranque del servidor de Colegio RP: carga los servicios de ServerScriptService.ColegioRP.Services en el orden de Config.OrdenServicios (tolerante a servicios ausentes), construye el registro compartido { Get, Config, Shared }, ejecuta Init y luego Start de cada servicio en pcall, publica… | [`Main.server.lua`](../src/ServerScriptService/ColegioRP/Main.server.lua) |
| `ServerScriptService.ColegioRP.Services.AuditLogService` | ModuleScript | 286 | Registro de auditoría del servidor: buffer circular (Config.Auditoria.TamanoBuffer) con entradas { Id, T, Categoria, UserId, Jugador, Accion, Detalle }. Categorías: Remoto, Cargo, Moderacion, Economia, Clase, Sistema. Otros servicios lo consultan con Listar(n) y se suscriben a Registrado. | [`AuditLogService.lua`](../src/ServerScriptService/ColegioRP/Services/AuditLogService.lua) |
| `ServerScriptService.ColegioRP.Services.DataService` | ModuleScript | 908 | Persistencia de perfiles (docs/ARQUITECTURA.md §4): carga al entrar con reintentos y backoff 1/2/4 s, presupuesto de peticiones, migraciones por Version, saneamiento, caché Perfiles[userId], autoguardado, guardado en PlayerRemoving y BindToClose, modo memoria en Studio sin acceso a la API y guardado de reportes. | [`DataService.lua`](../src/ServerScriptService/ColegioRP/Services/DataService.lua) |

## Atributos y tags que el sistema añade a objetos existentes (reversibles)

| Dónde | Atributo / tag | Lo pone |
|---|---|---|
| `Seat` de aula | atributo `RoomId`, tag `ColegioRP_Asiento` | MapService |
| Monitor de PC | atributo `PcId`, tag `ColegioRP_PantallaPC` | MapService |
| Hoja de puerta | atributos `PuertaId`, `Estado`; tag `ColegioRP_Puerta`; `ProximityPrompt` hijo | DoorService |
| Lavamanos / inodoro | atributo `ObjetoId`, tag `ColegioRP_Bano`; `ProximityPrompt` hijo | BathroomService |
| Modelos pesados (ventiladores, espejo, árboles) | tag `ColegioRP_Decoracion` | MapService |
| `Player` | atributos `Cargo`, `Equipo`, `Salon`, `Silenciado`, `Atendido`, `EquipoFutbol`, `Sospechoso` | RoleService, ModerationService, StaffService, FootballService, RemoteService |

