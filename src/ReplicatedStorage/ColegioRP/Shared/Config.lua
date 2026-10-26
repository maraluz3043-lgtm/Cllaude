--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Config
	Tipo: ModuleScript
	Configuración central de Colegio RP (Instituto Educativo Jean Piaget). Solo contiene datos:
	cada clave está documentada y puede ajustarse sin tocar la lógica de servicios ni controladores.
	Los ids de assets en 0 son DEPENDENCIAS del usuario (ver comentarios "DEPENDENCIA").
]]

local Config = {}

---------------------------------------------------------------------------------------------------
-- Identidad del juego
---------------------------------------------------------------------------------------------------
Config.NombreColegio = "Instituto Educativo Jean Piaget" -- Nombre completo mostrado en carga, menú y letreros.
Config.NombreCorto = "Colegio Jean Piaget" -- Nombre corto para el HUD y títulos de paneles.
Config.Lema = "Educación integral · Camino a la excelencia" -- Lema institucional (pantalla de carga y menú).
Config.Productora = "Horizon Studios" -- Productora mostrada en la intro.
Config.Autor = "by Adrian" -- Firma de la intro ("Horizon Studios by Adrian").
Config.Version = "2.0.0" -- Versión del sistema RP; debe coincidir con ReplicatedStorage.ColegioRP.Version y con Catalogs.Changelog[1].
Config.FechaVersion = "2026-10-26" -- Fecha de la versión (AAAA-MM-DD).

-- DEPENDENCIA: subir assets/logo_instituto_jean_piaget.png como Decal (Roblox > Crear > Decals),
-- copiar el id numérico del asset (rbxassetid://NNN -> NNN) y escribirlo aquí.
-- 0 = se usa el logo vectorial de respaldo (círculo rojo con "JEAN PIAGET" / "INSTITUTO EDUCATIVO").
Config.LogoAssetId = 0

-- DEPENDENCIA: ids numéricos de sonidos (Sound.SoundId) verificados en el Catálogo/Toolbox.
-- 0 = silencio (el sistema no reproduce nada y no genera errores). Rellenar solo con ids cuyo audio
-- se haya comprobado en Studio (los audios no públicos no suenan en el juego publicado).
Config.Sonidos = {
	Timbre = 0, -- Timbre escolar (cambios de periodo de la jornada).
	ClickUI = 0, -- Clic de botones de la interfaz.
	Puerta = 0, -- Apertura/cierre de puertas.
	Gol = 0, -- Gol en la cancha.
	Notificacion = 0, -- Aviso o notificación en el HUD.
}

---------------------------------------------------------------------------------------------------
-- Orden de arranque (ver docs/ARQUITECTURA.md §2)
---------------------------------------------------------------------------------------------------
-- Servicios de ServerScriptService.ColegioRP.Services: Init en este orden y luego Start en este orden.
Config.OrdenServicios = {
	"AuditLogService",
	"DataService",
	"RemoteService",
	"MapService",
	"RoleService",
	"SpawnService",
	"SchoolDayService",
	"RoomService",
	"ClassroomService",
	"BoardService",
	"NotebookService",
	"EconomyService",
	"FoodService",
	"CafeteriaService",
	"FootballService",
	"DoorService",
	"BathroomService",
	"PCService",
	"ReportService",
	"ModerationService",
	"AnnouncementService",
	"StaffService",
	"MetricsService",
}

-- Controladores de StarterPlayerScripts.ColegioRP.Controllers: mismo patrón Init/Start.
Config.OrdenControladores = {
	"NotificationController",
	"HUDController",
	"MenuController",
	"SettingsController",
	"HelpController",
	"SupportController",
	"NametagController",
	"InteractionController",
	"ClassroomController",
	"BoardController",
	"PCController",
	"FoodController",
	"CafeteriaController",
	"FootballController",
	"StaffController",
}

---------------------------------------------------------------------------------------------------
-- Autorizaciones de cargos (RoleService:Autorizado)
---------------------------------------------------------------------------------------------------
Config.Autorizaciones = {
	-- [userId] = { "Director", "ProfesorTitular" }  ->  cargos permitidos a ese usuario.
	-- [userId] = { "*" }  ->  todos los cargos. Ejemplo: [123456789] = { "*" },
	PorUserId = {},
	-- Grupo de Roblox: rango mínimo por cargo. GroupId = 0 desactiva la comprobación por grupo.
	GrupoRoblox = {
		GroupId = 0,
		RangosMinimos = { Director = 255, CoordinadorAcademico = 200, ProfesorTitular = 100 },
	},
	UsarAdonis = true, -- Si _G.Adonis.CheckAdmin existe, los administradores de Adonis pueden tomar cualquier cargo.
	ModoPruebasEnStudio = true, -- En Studio (RunService:IsStudio()) todos los cargos están disponibles para probar.
	CargosLibres = { "Estudiante" }, -- Cargos que no requieren ninguna autorización.
}

---------------------------------------------------------------------------------------------------
-- Aparición (SpawnService)
---------------------------------------------------------------------------------------------------
Config.Spawns = {
	CargoPorDefecto = "Estudiante", -- Cargo asignado al entrar si el jugador no elige otro.
	ZonaEstudiantes = "PATIO_CENTRAL", -- Zona de MapaLogico donde aparecen los estudiantes.
	ZonaRespaldo = "AUDITORIO", -- Zona usada si la zona del cargo no existe o no tiene punto de spawn.
	DesactivarSpawnOriginal = false, -- true = quita Neutral/AllowTeamChangeOnTouch del SpawnLocation original. Por defecto se conserva.
	AlturaSobrePiso = 3.5, -- Altura (studs) sobre el piso de la zona a la que se coloca el HumanoidRootPart.
}

---------------------------------------------------------------------------------------------------
-- Jornada escolar (SchoolDayService; periodos en TimetableDefinitions)
---------------------------------------------------------------------------------------------------
Config.Jornada = {
	Modo = "Automatica", -- "Automatica" = avanza sola con los tiempos de TimetableDefinitions; "Manual" = solo con JornadaControl.
	-- Aulas que reciben estudiantes (subconjunto editable de MapaLogico.Aulas). Las aulas especiales
	-- (ROBOTICA, LABORATORIO) se reservan para actividades dirigidas por docentes.
	AulasActivas = {
		"6C", "AULA_P2", "5", "7A", "A01", "A02", "A03", "A04", "A05", "A06", "AULA_E1", "INFORMATICA",
		"AULA_ADAPTADA", "6B", "7B", "AULA_P1", "8B", "ALTO_O1", "ALTO_O2", "ALTO_O3", "ALTO_E3",
	},
	EstudiantesPorAulaMax = 20, -- Máximo de estudiantes asignados a una misma aula (reparto balanceado).
	EscalaTiempo = 1, -- Multiplicador de las duraciones de los periodos (0.5 = jornada al doble de velocidad).
	IniciarAutomaticamente = true, -- true = la jornada arranca sola al iniciar el servidor (en modo Automatica).
	PausarSinJugadores = true, -- true = la jornada se pausa cuando no hay jugadores en el servidor.
}

---------------------------------------------------------------------------------------------------
-- Economía (EconomyService)
---------------------------------------------------------------------------------------------------
Config.Economia = {
	MonedaNombre = "Monedas escolares", -- Nombre visible de la moneda.
	MonedaSimbolo = "◎", -- Símbolo mostrado junto a los importes.
	SaldoInicial = 50, -- Saldo de un perfil nuevo.
	Recompensas = { -- Importes acreditados por cada logro.
		Asistencia = 10, -- Marcado como Presente al inicio de una clase.
		Respuesta = 5, -- Respuesta correcta en una actividad o cuestionario.
		Participacion = 3, -- Levantar la mano y ser atendido / participar en clase.
		TareaLimpieza = 8, -- Tarea de limpieza completada.
		Partido = 6, -- Participar en un partido completo.
	},
	LimiteDiario = 300, -- Máximo acreditable por jugador y día (anti-granja).
}

---------------------------------------------------------------------------------------------------
-- Comedor gratuito (FoodService)
---------------------------------------------------------------------------------------------------
Config.Comedor = {
	RacionesPorLote = 40, -- Raciones que produce una receta completa.
	CooldownReclamo = 120, -- Segundos entre reclamos de un mismo jugador.
	LotesPorJornada = 3, -- Lotes que puede preparar la cocina por jornada.
	NPCServicioSiNoHayCocinero = true, -- true = reposición automática cuando no hay Cocinero conectado.
	PermitirFueraDeHorario = false, -- false = solo se reclama en periodos con ComidaGratis (DESCANSO, ALMUERZO).
}

---------------------------------------------------------------------------------------------------
-- Cafetería / tienda escolar (CafeteriaService)
---------------------------------------------------------------------------------------------------
Config.Cafeteria = {
	PrecioMin = 1, -- Precio mínimo que puede fijar quien tiene cafeteria.precios.
	PrecioMax = 200, -- Precio máximo.
	NPCVendedorSiNoHayVendedor = true, -- true = la tienda atiende sola cuando no hay VendedorCafeteria conectado.
	CooldownCompra = 3, -- Segundos entre compras del mismo jugador.
	CantidadMaxPorCompra = 5, -- Unidades máximas por transacción.
}

---------------------------------------------------------------------------------------------------
-- Cuaderno personal (NotebookService)
---------------------------------------------------------------------------------------------------
Config.Cuaderno = {
	MaxPaginas = 20, -- Páginas por cuaderno.
	MaxCaracteresPagina = 1200, -- Caracteres por página (se truncan al guardar).
	AutoguardadoSeg = 45, -- Intervalo de autoguardado desde el cliente (el servidor acepta máx. 1 guardado / 10 s).
	MinIntervaloGuardadoSeg = 10, -- Intervalo mínimo aceptado por el servidor entre guardados.
}

---------------------------------------------------------------------------------------------------
-- Tablero de aula (BoardService)
---------------------------------------------------------------------------------------------------
Config.Tablero = {
	MaxCaracteres = 400, -- Texto máximo del tablero.
	MaxTrazos = 300, -- Trazos (líneas) almacenados por tablero.
	MaxTrazoPuntos = 60, -- Puntos por trazo.
	TurnoSeg = 90, -- Duración del turno de un estudiante invitado al tablero.
}

---------------------------------------------------------------------------------------------------
-- Fútbol (FootballService)
---------------------------------------------------------------------------------------------------
Config.Futbol = {
	DistanciaPatada = 9, -- Distancia máxima (studs) entre el jugador y el balón para patear.
	FuerzaMax = 60, -- Velocidad máxima aplicada al balón (studs/s).
	CooldownPatada = 0.6, -- Segundos entre patadas del mismo jugador.
	DuracionPartidoSeg = 300, -- Duración de un partido.
	ResetTrasGolSeg = 3, -- Segundos tras un gol antes de recolocar el balón.
	JugadoresPorEquipoMax = 7, -- Jugadores máximos por equipo (A/B).
}

---------------------------------------------------------------------------------------------------
-- Puertas (DoorService)
---------------------------------------------------------------------------------------------------
Config.Puertas = {
	CooldownSeg = 1.0, -- Segundos entre acciones sobre la misma puerta.
	AutoCierreSeg = 8, -- Segundos hasta el cierre automático de una puerta abierta.
	PermitirGiro = false, -- true = permite el modo "giro" (tween de la hoja). Por defecto solo modo "estado".
	PrivacidadSeg = 60, -- Duración del bloqueo de privacidad en baños.
}

---------------------------------------------------------------------------------------------------
-- Reportes de soporte (ReportService)
---------------------------------------------------------------------------------------------------
Config.Reportes = {
	MaxPorMinuto = 2, -- Reportes por jugador y minuto.
	MaxCaracteres = 300, -- Longitud máxima de la descripción.
	MaxUbicacionCaracteres = 60, -- Longitud máxima del campo Ubicación.
}

---------------------------------------------------------------------------------------------------
-- Persistencia (DataService)
---------------------------------------------------------------------------------------------------
Config.Datos = {
	NombreDataStore = "ColegioRP_Perfiles", -- DataStore de perfiles de jugador.
	NombreDataStoreReportes = "ColegioRP_Reportes", -- DataStore de reportes de soporte.
	EsquemaVersion = 1, -- Versión del esquema de perfil (migraciones por versión).
	AutoguardadoSeg = 120, -- Intervalo de autoguardado de perfiles sucios.
	ReintentosMax = 3, -- Reintentos de carga/guardado con backoff 1/2/4 s.
	MaxHistorialEconomia = 30, -- Entradas conservadas en Economia.Historial.
}

---------------------------------------------------------------------------------------------------
-- Moderación (ModerationService)
---------------------------------------------------------------------------------------------------
Config.Moderacion = {
	DuracionMuteSeg = 300, -- Duración por defecto de un silencio.
	DuracionBloqueoTemporalSeg = 1800, -- Duración por defecto de un bloqueo temporal.
	TokenConfirmacionSeg = 30, -- Validez del token de confirmación en acciones de dos pasos.
	MaxAdvertencias = 20, -- Advertencias conservadas por perfil.
}

---------------------------------------------------------------------------------------------------
-- Gráficos (SettingsController)
---------------------------------------------------------------------------------------------------
Config.Graficos = {
	ModoPorDefecto = "Automatico", -- "Automatico" | "Calidad" | "Bajos".
	DistanciaDecoracionLejana = 350, -- Distancia (studs) a partir de la cual se oculta la decoración pesada.
	FPSAvisoBajos = 25, -- Si el FPS medio baja de este valor durante FPSAvisoSeg en modo Calidad, se sugiere Bajos.
	FPSAvisoSeg = 10,
}

---------------------------------------------------------------------------------------------------
-- Límites de texto generales
---------------------------------------------------------------------------------------------------
Config.Limites = {
	MaxAvisoCaracteres = 160, -- Avisos y anuncios.
	MaxNombreCaracteres = 24, -- Nombres editables (título del cuaderno, productos, tareas).
	MaxMotivoCaracteres = 120, -- Motivo de acciones de moderación.
	MaxTemaCaracteres = 80, -- Tema de la clase.
	MaxRespuestaCaracteres = 300, -- Respuesta de texto de un estudiante en una actividad.
}

---------------------------------------------------------------------------------------------------
-- Chat (AnnouncementService)
---------------------------------------------------------------------------------------------------
Config.Chat = {
	ComandoAnuncio = "/anuncio", -- TextChatCommand principal (requiere anuncios.global; lo valida el servidor).
	AliasAnuncio = "/h", -- Alias corto del comando.
	HistorialAnuncios = 10, -- Últimos anuncios conservados y enviados al conectarse.
}

---------------------------------------------------------------------------------------------------
-- Red y remotos (RemoteService / Util.Net)
---------------------------------------------------------------------------------------------------
Config.Red = {
	TimeoutRemotosSeg = 30, -- Tiempo máximo de espera (WaitForChild) de carpetas y remotos en el cliente.
	RechazosParaSospechoso = 20, -- Rechazos de remotos en la ventana para marcar al jugador como Sospechoso.
	VentanaSospechosoSeg = 60, -- Ventana de tiempo de la regla anterior.
}

-- Distancias máximas (studs) comprobadas en el servidor para interacciones con el mundo.
Config.Distancias = {
	Puerta = 14, -- DoorAction.
	Bano = 10, -- BathroomAction.
	PC = 6, -- PCAction "Usar" si el jugador no está sentado en el Seat emparejado.
	Estacion = 10, -- Pasos de cocina (FoodAction "Paso").
	Mostrador = 14, -- Compras y reclamos frente al mostrador.
	Tablero = 30, -- Escritura en el tablero (debe estar dentro del aula).
}

---------------------------------------------------------------------------------------------------
-- Funciones de personal (StaffService) y otros límites de servicios
---------------------------------------------------------------------------------------------------
Config.Enfermeria = { AforoMax = 4, DuracionAtendidoSeg = 120 } -- Pacientes simultáneos y duración de la etiqueta "Atendido".
Config.Limpieza = { MaxSimultaneas = 6, DuracionTareaSeg = 5, MaxPorJugadorPorPeriodo = 3 } -- Tareas visibles a la vez, tiempo de ejecución y máximo por jugador en cada DESCANSO/ALMUERZO.
Config.Auditoria = { TamanoBuffer = 500 } -- Entradas del buffer circular de AuditLogService.
Config.Metricas = { IntervaloClienteSeg = 30 } -- Intervalo mínimo entre envíos de FPS por el cliente (StaffAction "Metrica").

---------------------------------------------------------------------------------------------------
-- Nombres de instancias, tags y atributos (ver docs/ARQUITECTURA.md §1 y §8)
---------------------------------------------------------------------------------------------------
Config.Tags = {
	Asiento = "ColegioRP_Asiento", -- Seats de aula.
	PantallaPC = "ColegioRP_PantallaPC", -- Monitores de PC.
	Puerta = "ColegioRP_Puerta", -- Hojas de puerta.
	Bano = "ColegioRP_Bano", -- Objetos de baño.
	Decoracion = "ColegioRP_Decoracion", -- Decoración pesada (modo bajos recursos).
}

Config.Nombres = {
	CarpetaMapa = "ColegioRP_Mapa", -- Workspace.ColegioRP_Mapa (se regenera en cada arranque).
	CarpetaRespaldos = "ColegioRP_Respaldos", -- ServerStorage.ColegioRP_Respaldos.
	CarpetaRemotos = "Remotes", -- ReplicatedStorage.ColegioRP.Remotes.
	SenalCargaLista = "ColegioRP_CargaLista", -- BindableEvent en ReplicatedFirst creado por la pantalla de carga.
	PrefijoPantallas = "ColegioRP_", -- Prefijo de todas las ScreenGui ("ColegioRP_HUD", ...).
}

return Config
