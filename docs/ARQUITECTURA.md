# Arquitectura y contrato de implementación — Colegio RP (Instituto Educativo Jean Piaget)

Producción: **Horizon Studios by Adrian**. Lugar base: `COLEGIO_JEAN_PIAGET.rbxl` (auditado en binario el 26/10/2026; ver `mapa/zonas.json` y `docs/A_Diagnostico_Mapa.md`).

Este documento es el **contrato** que siguen todos los módulos. Si un módulo necesita algo que no está aquí, lo añade a su propio archivo sin romper lo definido.

---

## 0. Reglas no negociables

1. **No se modifica la geometría existente.** Nada borra, mueve ni re-parenta objetos del mapa. Solo se crean instancias nuevas bajo carpetas propias (`Workspace/ColegioRP_Mapa`, `ReplicatedStorage/ColegioRP`, etc.) y se añaden `ProximityPrompt`, `SurfaceGui`, atributos y tags a objetos existentes (reversible; el desinstalador los retira).
2. **Autoridad del servidor.** Todo estado sensible (cargo, aula, sesión de clase, notas, monedas, inventarios, balón, puertas, jornada) vive en el servidor. El cliente solo envía peticiones y renderiza. Nunca se confía en precios, roles, ids de aula, texto sin filtrar ni "autorizaciones" enviadas por el cliente.
3. **Validación total de remotos.** Cada `RemoteEvent`/`RemoteFunction` pasa por `RemoteService` que: comprueba tipos con `Validate` y el esquema de `RemoteContracts`, aplica límite de frecuencia por jugador y por remoto, comprueba permisos del cargo, distancia cuando aplica, y registra rechazos en `AuditLogService` (prueba P14).
4. **Filtrado de texto.** Todo texto escrito por un jugador que otros puedan ver (tablero, cuaderno compartido, avisos, nombres editables, reportes, productos) pasa por `TextService:FilterStringAsync` en el servidor; para mostrar a un jugador concreto se usa `GetChatForUserAsync`/`GetNonChatStringForUserAsync` sobre el `TextFilterResult`. Si el filtrado falla, el texto **no** se muestra a terceros.
5. **Sin secretos.** Nada de tokens, webhooks ni claves en `ReplicatedStorage` ni en cliente. No hay integración externa activa.
6. **Español en toda la UI**, responsive (PC, móvil, tableta, mando), respetando `ScreenGui.IgnoreGuiInset`, `GuiService` safe areas y navegación por foco (`GuiService.SelectedObject`).
7. **Sintaxis Luau restringida** (para poder verificarla fuera de Studio con `luaparse`): no usar `continue`, operadores compuestos (`+=`, `..=`), anotaciones de tipo (`: string`, `::`), ni interpolación con acentos graves. Sí se usan `task.*`, `typeof`, `table.create`, `string.format`, etc. Tabulaciones para indentar.
8. **Sin bucles con `wait()`** en código nuevo; usar `task.wait`, eventos y `RunService` solo donde haga falta; desconectar conexiones al destruir estado.
9. **Cada módulo es un `ModuleScript` que devuelve una tabla** con `Init(registro)` y `Start()` (ver ciclo de vida). Ningún servicio hace `require` de otro servicio: se obtiene por el registro para evitar ciclos.
10. **Idempotencia en Studio.** El instalador puede ejecutarse varias veces; respalda la versión anterior en `ServerStorage/ColegioRP_Respaldos/<fecha>` y nunca toca otros scripts.

---

## 1. Árbol de instancias (rutas exactas en el Explorer)

```
ReplicatedFirst
└─ ColegioRP_Carga (LocalScript)          -- pantalla de carga + intro; se ejecuta antes que todo
ReplicatedStorage
└─ ColegioRP (Folder)
   ├─ Shared (Folder)
   │  ├─ Config (ModuleScript)
   │  ├─ RoleDefinitions (ModuleScript)
   │  ├─ TimetableDefinitions (ModuleScript)
   │  ├─ RemoteContracts (ModuleScript)
   │  ├─ UITheme (ModuleScript)
   │  ├─ Catalogs (ModuleScript)
   │  ├─ MapaLogico (ModuleScript)        -- generado desde mapa/zonas.json
   │  └─ Util (Folder)
   │     ├─ Signal, Validate, Zones, Net, Format, Maid (ModuleScripts)
   ├─ Remotes (Folder)                     -- creado en tiempo de ejecución por RemoteService
   └─ Version (StringValue)                -- "2.0.0"
ServerScriptService
└─ ColegioRP (Folder)
   ├─ Main (Script)
   └─ Services (Folder)                    -- un ModuleScript por servicio (ver §6)
ServerStorage
└─ ColegioRP_Respaldos (Folder)            -- copias de versiones anteriores (lo crea el instalador)
StarterPlayer/StarterPlayerScripts
└─ ColegioRP (Folder)
   ├─ Main (LocalScript)
   ├─ Controllers (Folder)                 -- un ModuleScript por controlador (ver §7)
   └─ UI (Folder)
      └─ UIBuilder (ModuleScript)
StarterGui                                 -- vacío: todas las ScreenGui se construyen por código
Workspace
└─ ColegioRP_Mapa (Folder)                 -- creado en tiempo de ejecución por MapService
   ├─ Zonas (Folder)      -- Part invisible por zona (Name = ZoneId, atributos ZoneId, Tipo, Piso)
   ├─ Spawns (Folder)     -- Part invisible por punto de spawn (atributos ZoneId, Cargos, Estado)
   ├─ Aulas (Folder)      -- un Model por aula: RoomId, Seats (ObjectValues), PuestoDocente (Part), Tablero (Part con SurfaceGui)
   ├─ Futbol (Folder)     -- Balon (Part), ArcoA/ArcoB (Part trigger), Marcador (SurfaceGui)
   ├─ Cocina (Folder)     -- estaciones con ProximityPrompt
   ├─ Cafeteria (Folder)  -- mostrador con ProximityPrompt
   └─ PCs (Folder)        -- un Model por PC: Pantalla (SurfaceGui sobre el monitor real), Seat (ObjectValue)
Teams
└─ Estudiantes, Equipo Directivo, Docentes, Bienestar, Administración, Servicios (creados por RoleService)
```

Localización desde código (siempre con `WaitForChild` en cliente):
- `local RP = ReplicatedStorage:WaitForChild("ColegioRP")`, `local Shared = RP:WaitForChild("Shared")`, `local Remotes = RP:WaitForChild("Remotes")`.
- Servidor: `local Services = script.Parent.Services` desde `Main`.

---

## 2. Ciclo de vida y registro

### Servidor (`ServerScriptService/ColegioRP/Main`)
```lua
-- Carga todos los ModuleScripts de Services, en el orden de Config.OrdenServicios.
-- registro = { Get = function(nombre) ... end, Config = Config, Shared = Shared }
-- Para cada servicio: servicio:Init(registro)  (sin esperar, sin tocar otros servicios)
-- Después, para cada servicio: servicio:Start() (ya puede usar registro.Get("Otro"))
-- Errores: pcall por servicio; se imprime warn("[ColegioRP] ...") y se continúa.
```
Orden de arranque (`Config.OrdenServicios`): `AuditLogService, DataService, RemoteService, MapService, RoleService, SpawnService, SchoolDayService, RoomService, ClassroomService, BoardService, NotebookService, EconomyService, FoodService, CafeteriaService, FootballService, DoorService, BathroomService, PCService, ReportService, ModerationService, AnnouncementService, StaffService, MetricsService`.

### Cliente (`StarterPlayerScripts/ColegioRP/Main`)
Mismo patrón con `Controllers`. Orden: `NotificationController, HUDController, MenuController, SettingsController, HelpController, SupportController, NametagController, InteractionController, ClassroomController, BoardController, PCController, FoodController, CafeteriaController, FootballController, StaffController`.
El cliente espera a que `ReplicatedFirst/ColegioRP_Carga` haya señalado `_G` **no**: usa un `BindableEvent` en `ReplicatedFirst` llamado `ColegioRP_CargaLista` (lo crea la pantalla de carga; Main del cliente espera a `ColegioRP_CargaLista.Event` o a que el atributo `Listo == true` en ese BindableEvent).

### Patrón de módulo
```lua
local Servicio = {}
Servicio.Nombre = "RoleService"
function Servicio:Init(registro) self.registro = registro end
function Servicio:Start() end
return Servicio
```

---

## 3. Módulos Shared (API exacta)

### `Config`
```lua
return {
	NombreColegio = "Instituto Educativo Jean Piaget",
	NombreCorto = "Colegio Jean Piaget",
	Lema = "Educación integral · Camino a la excelencia",
	Productora = "Horizon Studios", Autor = "by Adrian",
	Version = "2.0.0", FechaVersion = "2026-10-26",
	LogoAssetId = 0,   -- DEPENDENCIA: subir assets/logo_instituto_jean_piaget.png como Decal y pegar el id. 0 = usar logo vectorial de respaldo (texto + círculo).
	Sonidos = { Timbre = 0, ClickUI = 0, Puerta = 0, Gol = 0, Notificacion = 0 }, -- 0 = silencio (ids reales solo si están verificados)
	OrdenServicios = {...}, OrdenControladores = {...},
	Autorizaciones = {
		PorUserId = { },                  -- [userId] = { "Director", "ProfesorTitular" } ; {"*"} = todos los cargos
		GrupoRoblox = { GroupId = 0, RangosMinimos = { Director = 255, CoordinadorAcademico = 200, ProfesorTitular = 100 } },
		UsarAdonis = true,                -- si _G.Adonis.CheckAdmin existe, los admins de Adonis pueden tomar cualquier cargo
		ModoPruebasEnStudio = true,       -- en Studio (RunService:IsStudio()) todos los cargos están disponibles
		CargosLibres = { "Estudiante" },  -- sin autorización
	},
	Spawns = { CargoPorDefecto = "Estudiante", ZonaEstudiantes = "PATIO_CENTRAL", ZonaRespaldo = "AUDITORIO" },
	Jornada = { Modo = "Automatica" | "Manual", ... ver TimetableDefinitions },
	Economia = { MonedaNombre = "Monedas escolares", MonedaSimbolo = "◎", SaldoInicial = 50, Recompensas = { Asistencia = 10, Respuesta = 5, Participacion = 3, TareaLimpieza = 8, Partido = 6 }, LimiteDiario = 300 },
	Comedor = { RacionesPorLote = 40, CooldownReclamo = 120, LotesPorJornada = 3, NPCServicioSiNoHayCocinero = true },
	Cafeteria = { PrecioMin = 1, PrecioMax = 200, NPCVendedorSiNoHayVendedor = true, CooldownCompra = 3 },
	Cuaderno = { MaxPaginas = 20, MaxCaracteresPagina = 1200, AutoguardadoSeg = 45 },
	Tablero = { MaxCaracteres = 400, MaxTrazos = 300, MaxTrazoPuntos = 60, TurnoSeg = 90 },
	Futbol = { DistanciaPatada = 9, FuerzaMax = 60, CooldownPatada = 0.6, DuracionPartidoSeg = 300, ResetTrasGolSeg = 3 },
	Puertas = { CooldownSeg = 1.0, AutoCierreSeg = 8 },
	Reportes = { MaxPorMinuto = 2, MaxCaracteres = 300 },
	Datos = { NombreDataStore = "ColegioRP_Perfiles", NombreDataStoreReportes = "ColegioRP_Reportes", EsquemaVersion = 1, AutoguardadoSeg = 120, ReintentosMax = 3 },
	Moderacion = { DuracionMuteSeg = 300, DuracionBloqueoTemporalSeg = 1800 },
	Graficos = { ModoPorDefecto = "Automatico", DistanciaDecoracionLejana = 350 },
	Limites = { MaxAvisoCaracteres = 160, MaxNombreCaracteres = 24 },
}
```

### `RoleDefinitions`
```lua
Roles = {
	Estudiante = { Nombre = "Estudiante", Abrev = "EST", Equipo = "Estudiantes", Color = Color3, Permisos = {...}, ZonaSpawn = "PATIO_CENTRAL", RequiereAutorizacion = false, Uniforme = { Camisa = 0, Pantalon = 0 } },
	Director, Subdirector, CoordinadorAcademico, CoordinadorConvivencia, ProfesorTitular, Tutor, ProfesorApoyo, Orientador, Enfermero, Secretario, AdministradorFinanciero, Recepcionista, Limpieza, Seguridad, Cocinero, VendedorCafeteria
}
Equipos = { Estudiantes = {Color=BrickColor}, ["Equipo Directivo"], Docentes, Bienestar, ["Administración"], Servicios }
Permisos (claves): "aula.docente", "aula.estudiante", "jornada.control", "horario.editar", "anuncios.global", "anuncios.aula",
  "moderacion.basica", "moderacion.avanzada", "cargos.asignar", "cargos.revocar", "auditoria.ver", "reportes.ver", "convivencia.gestionar",
  "cafeteria.vender", "cafeteria.precios", "cocina.operar", "comedor.reponer", "economia.auditar", "finanzas.presupuesto",
  "enfermeria.atender", "secretaria.matricular", "orientacion.agenda", "limpieza.tareas", "seguridad.acceso", "puertas.oficinas", "puertas.aulas",
  "pc.bloquear", "futbol.arbitro", "eventos.activar", "tablero.escribir"
Funciones: RoleDefinitions.Tiene(cargoId, permiso) -> bool ; RoleDefinitions.Lista() -> array ordenado ; RoleDefinitions.Equipo(cargoId)
```
Matriz mínima de permisos (resumen): Estudiante → aula.estudiante. Director → todo excepto cafeteria.vender/cocina.operar. Subdirector → igual que Director menos cargos.asignar de Director. CoordinadorAcademico → horario.editar, aula.docente, anuncios.global, puertas.aulas, reportes.ver. CoordinadorConvivencia → convivencia.gestionar, moderacion.basica, reportes.ver, anuncios.global. ProfesorTitular/Tutor/ProfesorApoyo → aula.docente, anuncios.aula, puertas.aulas, tablero.escribir, pc.bloquear, futbol.arbitro. Orientador → orientacion.agenda. Enfermero → enfermeria.atender. Secretario → secretaria.matricular, reportes.ver. AdministradorFinanciero → finanzas.presupuesto, economia.auditar, cafeteria.precios. Recepcionista → seguridad.acceso (visitas). Limpieza → limpieza.tareas. Seguridad → seguridad.acceso, puertas.oficinas. Cocinero → cocina.operar, comedor.reponer. VendedorCafeteria → cafeteria.vender.

### `TimetableDefinitions`
```lua
Estados = { "ESPERA", "ENTRADA", "CLASE_1", "TRANSICION", "DESCANSO", "CLASE_2", "ALMUERZO", "CLASE_3", "SALIDA", "REINICIO" }
Periodos = { -- duración en segundos reales por defecto (jornada ~22 min); nombre visible; acciones permitidas
	{ Estado="ESPERA",  Duracion=60,  Nombre="Esperando inicio", HoraEscolar="06:45" },
	{ Estado="ENTRADA", Duracion=90,  Nombre="Entrada",          HoraEscolar="07:00" },
	{ Estado="CLASE_1", Duracion=300, Nombre="1ª clase",         HoraEscolar="07:15", EsClase=true, Materia="MAT" },
	{ Estado="TRANSICION", Duracion=45, Nombre="Cambio de clase", HoraEscolar="08:15" },
	{ Estado="DESCANSO", Duracion=150, Nombre="Descanso",        HoraEscolar="08:30", ComidaGratis=true, Deporte=true },
	{ Estado="CLASE_2", Duracion=300, Nombre="2ª clase",         HoraEscolar="09:00", EsClase=true, Materia="ESP" },
	{ Estado="ALMUERZO", Duracion=180, Nombre="Almuerzo",        HoraEscolar="10:30", ComidaGratis=true, Deporte=true },
	{ Estado="CLASE_3", Duracion=300, Nombre="3ª clase",         HoraEscolar="11:15", EsClase=true, Materia="CIE" },
	{ Estado="SALIDA",  Duracion=90,  Nombre="Salida",           HoraEscolar="12:30" },
	{ Estado="REINICIO", Duracion=20, Nombre="Reinicio de jornada", HoraEscolar="12:45" },
}
Materias = { MAT="Matemáticas", ESP="Español", CIE="Ciencias", SOC="Sociales", ING="Inglés", TEC="Tecnología", EDF="Educación física", ART="Artes" }
ToleranciaTardanzaSeg = 60 ; MarcarAusenciaSeg = 180
HoraEscolar: el reloj escolar avanza desde HoraEscolar del periodo hasta la del siguiente de forma lineal con el tiempo real del periodo.
```

### `RemoteContracts`
Tabla `Remotos[nombre] = { Tipo = "RemoteEvent"|"RemoteFunction", Direccion = "C2S"|"S2C", Limite = { Max = n, VentanaSeg = s }, Esquema = esquemaValidate, Permiso = "clave" | nil }`. Lista completa en §5. Expone `RemoteContracts.Nombres` (array) y `RemoteContracts.Obtener(nombre)`.

### `UITheme`
Colores institucionales (del logo): `Rojo = Color3.fromRGB(196, 30, 36)`, `RojoOscuro = (150, 22, 28)`, `Blanco = (245,245,245)`, `Gris = (34,36,40)`, `GrisPanel = (24,25,28)`, `Amarillo = (246,196,34)`, `Azul = (31,78,160)`, `Verde = (44,160,90)`, `TextoPrincipal = (245,245,245)`, `TextoSecundario = (190,190,195)`. Fuentes: `Titulo = Enum.Font.GothamBold`, `Texto = Enum.Font.Gotham`. `EscalaTexto` por dispositivo (`UITheme.Escala()` devuelve 1 en PC, 0.9 en tableta, 0.8 en móvil usando `GuiService` + `UserInputService`). `Radio = 8`, `Espaciado = 8`, `Animacion = { Rapida = 0.15, Normal = 0.25 }`.

### `Catalogs`
- `Productos` (cafetería): `{ Id="EMPANADA", Nombre="Empanada", Precio=8, Stock=30, Categoria="Comida" }`, jugo, gaseosa, galletas, chocolatina, sándwich, agua, fruta.
- `Recetas` (comedor): `{ Id="ALMUERZO_1", Nombre="Arroz con pollo y jugo", Pasos={"Preparacion","Coccion","Emplatado"}, SegPorPaso=6, Raciones=40 }` y otra 2–3 recetas.
- `Plantillas` del tablero: `{ "Tema del día:", "Tarea para casa:", "Pregunta:", "Objetivo de la clase:" }`.
- `ActividadesPC`: `{ "Procesador", "Cuestionario", "Simulador", "Programacion" }` con textos de ayuda.
- `Ayuda`: secciones (Navegación, Horarios, Equipos y cargos, Controles PC/móvil, Cómo asistir a clase, Tablero y cuaderno, Comida y cafetería, Fútbol, Reportes, Gráficos, Preguntas frecuentes).
- `Changelog`: array `{ Version="2.0.0", Fecha="2026-10-26", Resumen={...} }`.
- `Equipo`: `{ {Nombre="Adrian", Rol="Director del proyecto"}, {Nombre="(editar)", Rol="Scripter"}, ... }` editable.
- `Uniformes`: ids de camisa/pantalón = 0 (dependencia: subir ropa).
- `TareasLimpieza`: lista de zonas y nombres de tarea.
- `Simulador`: definición de un mini-simulador educativo (péndulo/caída libre: entrada masa/altura → tiempo).

### `MapaLogico` (generado)
```lua
return {
	Version = 1, Pisos = { [0] = { SueloY = 0, SpawnY = 3 }, [1] = { SueloY = 14, SpawnY = 17 } },
	Zonas = { [id] = { Id, Nombre, Tipo, Piso, Centro = Vector3, Tamano = Vector3, Spawn = { Punto = Vector3, Estado, Cargos = {...} } | nil, Asientos = n, Tablero = { Centro = Vector3, Normal = Vector3 } | nil, PuestoDocente = Vector3|nil, PCs = { Vector3... }|nil, Estaciones = { Nombre = Vector3 }|nil, Mostrador = {Centro, Frente}|nil, Futbol = {...}|nil, Objetos = {...}|nil, Puertas = {...}|nil, Evidencia = {...}, Notas = "" } },
	OrdenZonas = { "ENTRADA", ... },
	Puertas = { [id] = { Id, Ruta = "Workspace/Puerta_6B", Hoja = "Hoja_transitable"|nil, Centro = Vector3, Zona, Modo = "estado"|"privacidad"|"giro", CargosBloqueo = {...} } },
	Aulas = { "A01", ..., "7A", "8B", ... } -- ids de zonas con Tipo aula / aula_especial / aula_pc
}
```
`Zones` (Util) ofrece `Zones.Contiene(zona, posicion)`, `Zones.ZonaDe(posicion)`, `Zones.ZonasTipo(tipo)`.

### `Util`
- `Signal.new()` → `:Connect(fn)`, `:Fire(...)`, `:Once(fn)`, `:Destroy()`.
- `Maid.new()` → `:GiveTask(conn|instance|fn)`, `:DoCleaning()`.
- `Validate`: esquemas declarativos: `Validate.Esquema({ campo = { tipo = "string", max = 300, min = 1, opcional = true, enum = {...} }, ... })`, `Validate.Comprobar(esquema, valor) -> ok, error`. Tipos: string, number (con min/max, entero), boolean, table (con campos), Vector3 (con magnitud máxima), enum, array (de tipo, maxItems).
- `Net` (cliente y servidor): `Net.Evento(nombre)` / `Net.Funcion(nombre)` devuelven la instancia esperando a que exista; en cliente `Net.Invocar(nombre, datos)` hace `pcall` y devuelve `ok, respuesta`.
- `Format`: `HoraHHMM(segundosDelDia)`, `Moneda(n)`, `Tiempo(seg)`, `Truncar(texto, n)`.

---

## 4. Modelo de datos (DataStore, esquema v1)
```lua
Perfil = {
	Version = 1,
	Ajustes = { ModoGraficos = "Automatico", Particulas = true, DecoracionLejana = true, Postprocesado = true, SonidosAmbiente = true, AnimacionesCosmeticas = true, LimiteEfectos = 2, EscalaTexto = 1, MovimientoReducido = false, Subtitulos = true, FormatoHora = 24, OcultarEtiquetas = false, IntroVista = false },
	Economia = { Saldo = 50, GanadoHoy = 0, DiaUltimo = "" , Historial = { {T=..., Tipo="", Monto=n, Detalle=""} (máx 30) } },
	Cuaderno = { Titulo = "Mi cuaderno", Paginas = { {Materia="MAT", Texto="", Actualizado=0} } },
	Progreso = { Asistencias = 0, Tardanzas = 0, Ausencias = 0, RespuestasCorrectas = 0, ClasesCompletadas = 0, Goles = 0, TareasLimpieza = 0, UltimoCargo = "Estudiante" },
	Moderacion = { Advertencias = { {T=..., Motivo=""} }, BloqueoHasta = 0 },
}
```
`DataService`: `Cargar(player)` al entrar (reintentos con backoff 1/2/4 s, comprueba `GetRequestBudgetForRequestType`), caché en memoria `Perfiles[userId]`, `Obtener(player) -> perfil|nil`, `Marcar(player)` (sucio), autoguardado cada `Config.Datos.AutoguardadoSeg`, guardado en `PlayerRemoving` y `BindToClose`. Migraciones por `Version`. Saneamiento (truncar cuadernos, tipos). En Studio sin acceso a API → modo memoria con `warn`. Reportes: `GuardarReporte(reporte)` en DataStore de reportes con clave `R_<unix>_<userId>`.

---

## 5. Remotos (todos bajo `ReplicatedStorage/ColegioRP/Remotes`)

Esquemas: `string(max)`, `int(min,max)`, `num(min,max)`, `bool`, `enum{...}`, `V3(mag)`, `tabla{...}`, `array<tipo>(max)`. Toda `RemoteFunction` devuelve `{ ok = bool, error = string|nil, datos = tabla|nil }`. Toda petición lleva `datos` como **una tabla** (único argumento) y se rechaza si no es tabla.

| Nombre | Tipo | Dir. | Límite | Permiso | Esquema de `datos` | Respuesta / efecto |
|---|---|---|---|---|---|---|
| `StateSnapshot` | RF | C2S | 2/5s | — | `{}` | snapshot completo: `{ Jornada, Rol, Economia, Ajustes, Aula (sesión si aplica), Anuncios, Version, HoraServidor }` |
| `RequestRoleList` | RF | C2S | 3/5s | — | `{}` | `{ Cargos = { {Id, Nombre, Equipo, Disponible, Motivo} }, Actual }` |
| `RequestJoinRole` | RF | C2S | 3/10s | — | `{ Cargo = enum(RoleIds) }` | asigna cargo y hace spawn; `{ Cargo, Equipo, Zona, Salon }` |
| `RequestClassAction` | RF | C2S | 10/5s | — (por acción) | `{ Accion = enum{"AbrirSesion","CerrarSesion","FijarTema","EnviarAviso","TomarAsistencia","CrearActividad","CerrarActividad","InvitarTablero","RevocarTablero","Calificar","Responder","LevantarMano","AceptarInvitacion","ConsultarEstado","PublicarResultados"}, Salon = string(16), Datos = tabla }` | ver ClassroomService |
| `BoardAction` | RF | C2S | 8/5s | tablero.escribir o invitado | `{ Accion = enum{"Escribir","Limpiar","Plantilla","Trazo","Imagen"}, Salon = string(16), Texto = string(400) opc, Trazo = array<V3(1)>(60) opc, Plantilla = int opc, ImagenId = int opc }` | actualiza BoardState y replica a la sala |
| `NotebookUpdate` | RF | C2S | 6/10s | — | `{ Accion = enum{"Guardar","Cargar","Compartir","Vaciar","Ver"}, Pagina = int(1,20) opc, Materia = string(8) opc, Texto = string(1200) opc, ObjetivoUserId = int opc }` | guarda/carga; "Ver" solo docente de la sesión sobre alumno presente que haya compartido |
| `CafeteriaPurchase` | RF | C2S | 4/5s | — | `{ ProductoId = string(24), Cantidad = int(1,5) }` | transacción atómica; recibo `{ Recibo = {Id, Total, Saldo, Items} }` |
| `CafeteriaManage` | RF | C2S | 6/5s | cafeteria.vender | `{ Accion = enum{"Abrir","Cerrar","Precio","Reponer","Inventario","Cierre"}, ProductoId opc, Valor = num opc }` | precios dentro de [PrecioMin, PrecioMax]; cafeteria.precios para "Precio" |
| `FoodAction` | RF | C2S | 6/5s | — / cocina.operar | `{ Accion = enum{"Reclamar","IniciarReceta","Paso","Reponer","Estado","Entregar"}, RecetaId opc, Estacion opc }` | comida gratis (coste 0), cooldown por jugador, solo en periodos ComidaGratis |
| `SettingsUpdate` | RE | C2S | 2/5s | — | `{ Ajustes = tabla (claves de Perfil.Ajustes) }` | guarda ajustes saneados |
| `ReportSubmit` | RF | C2S | 2/60s | — | `{ Categoria = enum{"Bug","Abuso","Duda","Sugerencia"}, Ubicacion = string(60), Descripcion = string(300) }` | `{ Id }` |
| `DoorAction` | RF | C2S | 4/2s | — / puertas.* | `{ PuertaId = string(40), Accion = enum{"Abrir","Cerrar","Bloquear","Desbloquear","Privacidad"} }` | distancia ≤ 14 studs |
| `PCAction` | RF | C2S | 8/5s | — | `{ PcId = string(24), Accion = enum{"Usar","Salir","Encender","Apagar","Aplicacion","Resultado","Bloquear","Desbloquear","Proyectar"}, Datos = tabla opc }` | ocupación única por PC; resultados validados en servidor |
| `FootballKick` | RE | C2S | 5/2s | — | `{ Direccion = V3(1), Fuerza = num(0,1) }` | servidor valida distancia ≤ Config.Futbol.DistanciaPatada, cooldown, aplica impulso |
| `FootballAction` | RF | C2S | 4/5s | — / futbol.arbitro | `{ Accion = enum{"Unirse","Salir","Iniciar","Reiniciar","Finalizar","Estado"}, Equipo = enum{"A","B"} opc }` | — |
| `AnnouncementBroadcast` | RF | C2S | 2/30s | anuncios.global | `{ Texto = string(160), Alcance = enum{"Global","Aula"} }` | filtrado; HUD de todos / del aula |
| `ModerationAction` | RF | C2S | 6/10s | moderacion.* / cargos.* | `{ Accion = enum{"Silenciar","QuitarSilencio","Expulsar","BloquearTemporal","Advertir","VerRegistro","AsignarCargo","RevocarCargo","ConfirmarAccion"}, ObjetivoUserId = int, Motivo = string(120), Cargo opc, DuracionSeg opc, Token opc }` | acciones críticas requieren Token de confirmación emitido por el servidor (dos pasos) |
| `StaffAction` | RF | C2S | 6/5s | según acción | `{ Accion = string(32), Datos = tabla }` | funciones de cargo (ver StaffService) |
| `BathroomAction` | RF | C2S | 4/5s | — | `{ ObjetoId = string(40), Accion = enum{"LavarManos","Usar","Limpiar"} }` | distancia ≤ 10 |
| `JornadaControl` | RF | C2S | 4/10s | jornada.control | `{ Accion = enum{"Iniciar","Pausar","Reanudar","Saltar","Reiniciar","Configurar"}, Datos opc }` | — |
| `EventoCliente` | RE | S2C | — | — | `{ Tipo = string, Datos = tabla }` | canal multiplexado servidor→cliente. Tipos: `Jornada`, `Rol`, `Aviso`, `Notificacion`, `Aula`, `Tablero`, `Economia`, `Comida`, `Cafeteria`, `Futbol`, `Puerta`, `PC`, `Moderacion`, `Metricas`, `Personal` |

`EventoCliente` es la **única** vía servidor→cliente. Cada controlador se suscribe con `Net.Evento("EventoCliente").OnClientEvent` y filtra por `Tipo`.

Rechazos: `RemoteService` responde `{ ok=false, error="rechazado:<motivo>" }` y llama `AuditLogService:Registrar("Remoto", player, nombre, motivo)`. Tras 20 rechazos en 60 s se marca al jugador (`Sospechoso`) y se avisa a moderación (sin expulsar automáticamente).

---

## 6. Servicios de servidor (responsabilidades y API interna)

Cada servicio expone métodos para otros servicios vía `registro.Get("Nombre")`. Emite al cliente con `RemoteService:Enviar(player, tipo, datos)` y `RemoteService:EnviarATodos(tipo, datos)` / `EnviarAZona(zonaId, tipo, datos)`.

- **AuditLogService**: `Registrar(categoria, player|nil, accion, detalle)`; buffer circular de 500; `Listar(n)`; categorías: Remoto, Cargo, Moderacion, Economia, Clase, Sistema.
- **DataService**: §4.
- **RemoteService**: crea `Remotes` desde `RemoteContracts`; `Registrar(nombre, handler)` donde `handler(player, datos) -> respuesta`; aplica límites, esquema, permiso (consultando `RoleService:Tiene(player, permiso)`); `Enviar*`.
- **MapService**: construye `Workspace/ColegioRP_Mapa` desde `MapaLogico`: zonas (Part invisible, CanCollide=false, CanQuery=false, CanTouch=false, atributos), spawns, aulas (`Model` por aula con Seats encontrados dentro del volumen: `ObjectValue` por Seat; los Seats reciben atributos `RoomId` y tag `ColegioRP_Asiento`; `PuestoDocente` Part; `Tablero` Part fina pegada a la pared con `SurfaceGui`), PCs (busca modelos llamados `Computer` dentro de la zona INFORMATICA y usa la MeshPart `Computer Monitor 1` como pantalla; empareja Seat más cercano), estaciones de cocina y mostradores con `ProximityPrompt`, cancha (balón, arcos, marcador). API: `Zona(id)`, `ZonaDe(pos)`, `Aula(roomId) -> { Model, Seats = {Seat...}, Tablero = Part, PuestoDocente = Part, Zona }`, `Aulas()`, `PCs()`, `Puerta(id) -> { Config, Instancia, Hoja }`, `Inventario()` (informe para Output). Si una referencia del mapa no existe, lo registra como advertencia (nunca error) y continúa.
- **RoleService**: cargo por jugador (`Cargo`, `Equipo` como atributos del Player, replicados), `Asignar(player, cargo, origen)`, `Cargo(player)`, `Tiene(player, permiso)`, `Autorizado(player, cargo) -> bool, motivo` (PorUserId, grupo, Adonis, Studio, libres), `Disponibles(player)`, `AsignarPorAdmin(admin, objetivo, cargo)` con cooldown y auditoría, `Revocar`. Crea Teams. Uniforme: aplica `Shirt`/`Pants` del cargo si ids > 0 (sin tocar accesorios). Etiqueta sobre avatar: la hace NametagController (cliente) leyendo atributos.
- **SpawnService**: `Aparecer(player, zonaId?)` coloca el personaje en el spawn del cargo (o de la zona dada) con `CFrame` seguro (Y de piso + 3.5, mirando hacia el centro de la zona); si el spawn es provisional, notifica "Punto provisional". Mantiene cargo al morir (`CharacterAdded` → re-spawn en zona del cargo). Desactiva `AllowTeamChangeOnTouch` y `Neutral` del `SpawnLocation` original solo si `Config.Spawns.DesactivarSpawnOriginal` (por defecto **false**: se conserva).
- **SchoolDayService**: máquina de estados §3; `Estado()`, `Snapshot()`, `Iniciar/Pausar/Reanudar/Saltar/Reiniciar`, `Configurar(tabla)`; cada cambio → `EnviarATodos("Jornada", snapshot)`; timbres (sonido opcional + subtítulo); asignación de aula por estudiante (`AsignarAula(player)` balanceada entre `MapaLogico.Aulas` con `Config.Jornada.AulasActivas` como subconjunto editable); asistencia por aula al inicio de cada CLASE_n (+tolerancia): marca Presente/Tardanza/Ausente comprobando `Zones.Contiene(zonaAula, pos)`; mensajes "Dirígete a tu salón" vía Notificación; al finalizar jornada: cierra sesiones, guarda progreso, limpia estado temporal.
- **RoomService**: ocupación de asientos por aula: escucha `Seat:GetPropertyChangedSignal("Occupant")`; valida que el jugador pertenece a esa aula (cargo docente o aula asignada) y si no, lo informa (no lo expulsa del asiento); `Ocupacion(roomId) -> { Sentados = {userId...}, DePie = {userId...}, Capacidad }`; `JugadoresEn(roomId)`; limpia al respawn.
- **ClassroomService**: sesiones de clase por aula: `ClassSession = { SessionId, RoomId, TeacherUserId, StartedAt, State = "Abierta"|"Cerrada", Tema, PresentUserIds, ActiveActivityId, Actividades = { [id] = { Type = "Texto"|"Opciones", Prompt, Options, DueAt, Submissions = { [userId] = { Respuesta, T } }, Grades = { [userId] = { Puntos, Comentario } } } }, ManosLevantadas, InvitadoTablero }`. Reglas: un docente autorizado y con `aula.docente`; una sesión por aula; solo alumnos presentes en la zona reciben actividades; una respuesta por actividad; resultados privados; cancelación si el docente abandona el servidor o cambia de cargo; al cerrar jornada se cierran todas. Emite `Aula` eventos: `SesionAbierta`, `SesionCerrada`, `Actividad`, `ActividadCerrada`, `Resultado`, `Aviso`, `Asistencia`, `Mano`, `Invitacion`.
- **BoardService**: `BoardState[roomId] = { Texto, Trazos = {...}, Plantilla, ImagenId, Autor, Actualizado }`; solo docente de la sesión o invitado activo (turno con tiempo); filtra texto; replica solo a jugadores en la zona (`EnviarAZona`) y a los que entran después (snapshot al pedir `ConsultarEstado`); dibuja además en la `SurfaceGui` del tablero físico (servidor crea Frames/TextLabel; límites de trazos).
- **NotebookService**: §4 cuaderno; autosave desde cliente cada 45 s (acepta máximo 1 guardado/10 s); `Compartir` marca página compartida con filtrado; docente puede `Ver` páginas compartidas de alumnos presentes en su sesión.
- **EconomyService**: `Saldo(player)`, `Acreditar(player, monto, tipo, detalle)` (respeta LimiteDiario), `Debitar(player, monto, tipo, detalle) -> ok` (atómico por jugador con bloqueo en memoria), `Historial`; emite `Economia`.
- **FoodService**: lotes de raciones por jornada; `Reclamar(player)` gratis, cooldown, solo en periodos ComidaGratis o si `Config.Comedor.PermitirFueraDeHorario`; cocina: `IniciarReceta`, `Paso(estacion)` con tiempos y validación de orden y distancia a la estación; NPC de servicio si no hay cocinero (repone automáticamente); bandeja visual = `Tool` simple o accesorio ("Bandeja" Model soldado a la mano por 20 s, sin físicas) con animación de consumo opcional; emite `Comida`.
- **CafeteriaService**: inventario y precios en servidor desde `Catalogs.Productos`; vendedor abre/cierra el puesto; compra atómica con `EconomyService:Debitar` y doble verificación de stock; NPC vendedor si no hay vendedor y `Config.Cafeteria.NPCVendedorSiNoHayVendedor`; recibos; emite `Cafeteria`.
- **FootballService**: balón `Part` esfera (servidor con `SetNetworkOwner(nil)`), `FootballKick` valida distancia/cooldown y aplica `AssemblyLinearVelocity`; goles por volumen de arco (`GetPartBoundsInBox`) con enfriamiento; marcador; equipos A/B; partido con reloj; reset si sale de límites o si `AssemblyLinearVelocity` es anómala; no simula si nadie está en la zona CANCHA (balón anclado).
- **DoorService**: por puerta de `MapaLogico.Puertas`: `ProximityPrompt` en la hoja (o en la parte más grande del modelo); estados `Abierta/Cerrada/Bloqueada/Privada`; modo `estado`: abrir = hoja `Transparency` 0.7 y `CanCollide=false`, cerrar = restaurar valores originales guardados; modo `giro`: tween de CFrame alrededor de la arista (solo si `Config.Puertas.PermitirGiro` y la hoja existe); `privacidad`: cualquier jugador dentro puede bloquear 60 s; cooldown anti-spam; autocierre; permisos `cargosBloqueo`; emite `Puerta`.
- **BathroomService**: `ProximityPrompt` en lavamanos e inodoros listados en `Zona.Objetos` (busca el BasePart más cercano a cada punto); acciones con cooldown, sonido opcional y recompensa 0; nunca escenas explícitas (solo textos "Te lavas las manos").
- **PCService**: estado por PC `{ Encendido, OcupanteUserId, Bloqueado, Aplicacion, Proyeccion }`; `Usar` requiere estar sentado en el Seat emparejado o a ≤ 6 studs; resultados de cuestionario/programación se validan en servidor (la respuesta correcta y el intérprete determinista viven en servidor: `Catalogs.Simulador` y `Catalogs.Programacion` con un mini-intérprete de comandos `AVANZAR/GIRAR_IZQ/GIRAR_DER/REPETIR n ... FIN` sobre una cuadrícula 8×8); docente de tecnología puede bloquear/desbloquear y proyectar instrucciones; pantallas: `SurfaceGui` con estado y texto (actualización solo al cambiar).
- **ReportService**: categorías, filtrado, límite por minuto, id, guardado; `Listar()` para moderación.
- **ModerationService**: silenciar (`TextChatService` → `TextSource.CanSend=false` en canal general; fallback atributo `Silenciado` que el cliente respeta), expulsar (`player:Kick`), bloqueo temporal (perfil `Moderacion.BloqueoHasta`; al entrar se expulsa con mensaje si vigente), advertir; acciones críticas en dos pasos (Token). Integra con Adonis opcionalmente (solo lectura). Auditoría de todo.
- **AnnouncementService**: `Anunciar(player, texto, alcance)`; crea `TextChatCommand` `/anuncio` (alias `/h`) en `TextChatService` que valida permiso `anuncios.global` por servidor (`Triggered`); historial de 10 últimos; emite `Aviso`.
- **StaffService**: funciones de cargos: enfermería (`Atender(objetivo)`: estado "Atendido" en HUD del objetivo, registro, aforo máx 4), secretaría (matrícula RP: asigna aula y "certificado" en HUD; sin datos personales), finanzas (presupuesto virtual, auditoría de cafetería/comedor), orientación (agenda de citas RP: lista en memoria), limpieza (tareas por zonas generadas por `SchoolDayService` en DESCANSO/ALMUERZO: marcadores `ProximityPrompt` temporales "Limpiar", máximo 6 simultáneos, recompensa), seguridad (abrir/cerrar portón, registrar visita, aviso a moderación), recepción (registro de visitas), convivencia (reportes RP con advertencias proporcionadas: 1ª aviso, 2ª nota, 3ª citación; nunca castigos automáticos permanentes).
- **MetricsService**: contadores: jugadores, FPS reportado por cliente (opcional, enviado cada 60 s por `SettingsUpdate`? **no**: usa `StaffAction{Accion="Metrica"}` con límite 1/30s), instancias creadas por ColegioRP, rechazos de remotos, tiempos de respuesta; `Informe()` imprimible y visible para Director en panel.

---

## 7. Controladores de cliente

Cada controlador crea **una** `ScreenGui` llamada `ColegioRP_<Nombre>` (en `PlayerGui`), con `ResetOnSpawn=false`, `IgnoreGuiInset=true`, `ZIndexBehavior=Sibling`, `DisplayOrder` fijo (Carga 100, Menú 90, Modales 80, Paneles 50, HUD 10). Comprueba que no exista ya (evita duplicados al reconectar). Usa `UIBuilder` para widgets.

- **UIBuilder** (`StarterPlayerScripts/ColegioRP/UI/UIBuilder`): `Pantalla(nombre, displayOrder)`, `Panel(parent, props)`, `Titulo(parent, texto)`, `Texto(parent, texto, props)`, `Boton(parent, texto, onClick, props)` (hover, foco de mando, sonido opcional, tamaño mínimo táctil 44 px), `Entrada(parent, placeholder, props)` (TextBox con límite), `Lista(parent)` (ScrollingFrame + UIListLayout), `Interruptor(parent, texto, valor, onChange)`, `Selector(parent, texto, opciones, valor, onChange)`, `Modal(titulo, contenido, botones)`, `Toast`, `Barra(parent, progreso)`, `Logo(parent, tamaño)` (usa `Config.LogoAssetId` o logo de respaldo: círculo rojo con "JEAN PIAGET" / "INSTITUTO EDUCATIVO"), `Escalar(gui)` (UIScale por dispositivo), `Tween(obj, props, t)` respetando `MovimientoReducido`.
- **NotificationController**: toasts, subtítulos de timbre, cola máx 4, no solapa controles móviles; escucha `Notificacion`, `Aviso`, `Jornada` (timbre).
- **HUDController**: esquinas: hora real (reloj del dispositivo, "aprox.", 12/24 h), hora escolar + estado (sincronizados con `Jornada` snapshot y `workspace:GetServerTimeNow()`), cargo, aula asignada, próxima actividad, avisos oficiales, botón Cuaderno, botón Menú (☰), acciones contextuales, minimizable; etiqueta "Atendido" de enfermería.
- **MenuController**: menú principal tras la carga/intro: JUGAR (lista de cargos con disponibilidad; al elegir → `RequestJoinRole` → cierra), ACTUALIZACIONES (Catalogs.Changelog), EQUIPO (Catalogs.Equipo), AJUSTES (delegado a SettingsController), AYUDA, SOPORTE; logo central; navegación por foco; reabrible desde el HUD; **no** repite intro.
- **SettingsController**: panel de gráficos/accesibilidad; aplica localmente: modo Calidad/Bajos/Automático (Automático = Bajos en móvil o si `UserSettings().GameSettings.SavedQualityLevel` ≤ 3 cuando es legible, si no Calidad), partículas (`ParticleEmitter.Enabled` local), decoración lejana (`LocalTransparencyModifier` a objetos con tag `ColegioRP_Decoracion` o modelos de alto coste listados en `Catalogs.DecoracionPesada`: ventiladores con scripts, espejo, árboles), postprocesado (`Lighting` efectos `.Enabled` local), sombras (`Lighting.GlobalShadows` local), sonidos ambiente, animaciones cosméticas (p.ej. desactivar giro de ventiladores locales ocultándolos), límite de efectos; guarda vía `SettingsUpdate` (throttle 2 s); "Restaurar". Aviso de rendimiento (si FPS medio < 25 durante 10 s en modo Calidad: sugerir Bajos).
- **HelpController**: secciones de `Catalogs.Ayuda`, búsqueda simple, controles por plataforma detectada.
- **SupportController**: formulario de reporte; estado de envío; confirmación con id; no muestra datos de otros jugadores.
- **NametagController**: `BillboardGui` sobre cabeza: nombre mostrado, icono del colegio (logo), etiqueta de cargo abreviada; ocultar por distancia (> 60 studs) y por ajuste; usa atributos `Cargo` del Player.
- **InteractionController**: `ProximityPromptService` eventos → envía `DoorAction`, `BathroomAction`, `FoodAction`, `CafeteriaPurchase` (abre panel), `PCAction` (Usar); muestra feedback; respeta cooldowns.
- **ClassroomController**: panel docente (abrir sesión, tema, aviso, asistencia, lista sentados/de pie, crear actividad texto/opciones, cerrar, invitar al tablero, calificar, publicar resultados) y panel estudiante al sentarse o estar en el aula (Cuaderno / Actividad / Responder / Levantar mano / Ver tablero), cerrable/minimizable; recibe eventos `Aula`.
- **BoardController**: vista del tablero del aula (texto, trazos) en panel; modo de escritura/dibujo cuando se tiene turno; limita puntos de trazo y envía `BoardAction`.
- **PCController**: "Escritorio escolar" al usar un PC: apps Procesador (texto local → guarda en cuaderno), Cuestionario (de la actividad activa), Simulador educativo (local, resultado validado en servidor), Programación básica (editor de comandos → servidor ejecuta y devuelve traza), Pantalla de clase (texto proyectado por el docente); botón Salir; encendido/apagado; ventana responsive.
- **FoodController** / **CafeteriaController**: panel de reclamo (botón "Reclamar almuerzo" + estado del lote), panel de cocina (receta, pasos, progreso) y panel de venta (catálogo, carrito, recibo, administración del vendedor).
- **FootballController**: al entrar en CANCHA muestra marcador/reloj y botón/tecla "Patear" (E / botón táctil / mando) que envía `FootballKick` con dirección de cámara; unirse a equipo; no predice físicas.
- **StaffController**: paneles por cargo (Director: jornada, anuncios, personal, eventos, auditoría, métricas; Coordinación: horario/materias/aulas; Convivencia: reportes; Enfermería; Secretaría; Finanzas; Limpieza (lista de tareas); Seguridad; Orientación; Moderación básica).
- **IntroController**: implementado dentro de `ReplicatedFirst/ColegioRP_Carga` (no es un controlador aparte): carga → intro Horizon Studios (omitible; no se repite por respawn; se recuerda en ajustes `IntroVista`) → señal `ColegioRP_CargaLista` → MenuController abre el menú.

### Pantalla de carga (`ReplicatedFirst/ColegioRP_Carga`)
`ReplicatedFirst:RemoveDefaultLoadingScreen()`; fondo `Color3.fromRGB(10,10,12)`; logo centrado (respaldo vectorial si `LogoAssetId==0`); "Cargando…" y "Descargando paquetes…"; barra real sobre una lista finita: `ContentProvider:PreloadAsync` de (logo, sonidos con id > 0, fuentes usadas) + espera de `ReplicatedStorage.ColegioRP`, `Shared`, `Remotes`, `StarterPlayerScripts.ColegioRP` (cada hito suma al porcentaje); botón "Saltar" visible desde el inicio: si los hitos mínimos (RP + Remotes) están listos cierra, si no muestra "Preparando recursos esenciales…" y espera; tiempo máximo 25 s → continúa con aviso; manejo de errores con `pcall`; partículas moderadas (≤ 12 puntos) desactivables por `MovimientoReducido`; una sola instancia (comprueba `PlayerGui:FindFirstChild("ColegioRP_Carga")`).

---

## 8. Convenciones de atributos y tags (en instancias existentes; reversibles)
- Seats de aula: atributo `RoomId` (string), tag `ColegioRP_Asiento`.
- Monitores de PC: tag `ColegioRP_PantallaPC`, atributo `PcId`.
- Hojas de puerta: tag `ColegioRP_Puerta`, atributos `PuertaId`, `Estado`.
- Objetos de baño: tag `ColegioRP_Bano`, atributo `ObjetoId`.
- Objetos pesados decorativos (ventiladores con scripts, espejo, árboles): tag `ColegioRP_Decoracion` (puesto por MapService a partir de `Catalogs.DecoracionPesada`).
- Player: atributos `Cargo`, `Equipo`, `Salon`, `Silenciado`, `Atendido`.
- `Workspace/ColegioRP_Mapa` entero se puede borrar sin perder nada (se regenera en cada arranque).

---

## 9. Mapa de pruebas de aceptación (P1–P15) → módulo responsable
P1 Carga: ColegioRP_Carga. P2 Menús: Menu/Settings/Help/Support/UIBuilder. P3 Spawn por cargo: RoleService+SpawnService+MapaLogico. P4 Aulas paralelas: ClassroomService+BoardService (estado por RoomId, envío por zona). P5 Ocupación: RoomService. P6 Cuaderno: NotebookService. P7 Preguntas: ClassroomService. P8 Reloj/timbres: SchoolDayService+HUD. P9 Comida 0 / compra una vez: FoodService+CafeteriaService+EconomyService. P10 Puertas/sillas/PCs tras respawn: DoorService/RoomService/PCService (estado en servidor; cliente resuscribe). P11 Fútbol: FootballService. P12 Calidad local: SettingsController. P13 Sin regresiones: MapService no modifica geometría; instalador con respaldo. P14 Rechazos con logs: RemoteService+AuditLog. P15 Métricas: MetricsService + guía de medición en docs/G_Pruebas.md.
