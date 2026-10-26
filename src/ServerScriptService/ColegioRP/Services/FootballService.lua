--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.FootballService
	Tipo: ModuleScript
	Cancha y fútbol (docs/ARQUITECTURA.md §6, prueba P11). Usa el balón, los arcos y el marcador que crea
	MapService en Workspace.ColegioRP_Mapa.Futbol (si faltan, los crea desde MapaLogico.Zonas.CANCHA.Futbol).
	El balón es una esfera física con autoridad del servidor (SetNetworkOwner(nil)) que solo se simula cuando hay
	al menos un jugador en la zona CANCHA (bucle de presencia de 1 s); con la cancha vacía queda anclado en el
	centro y no corre el bucle de goles. FootballKick valida personaje vivo, distancia, cooldown, dirección y
	fuerza antes de aplicar AssemblyLinearVelocity. Goles por volumen de arco (muestreo cada 0.1 s con barrido
	del segmento recorrido), rescate por límites o velocidad anómala, equipos A/B por atributo EquipoFutbol del
	Player, partido con reloj, marcador físico (SurfaceGui) y recompensa Economia.Recompensas.Partido.
	Convención: el equipo A defiende ArcoA y el B defiende ArcoB; un balón dentro de ArcoA es gol del equipo B.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local UITheme = require(Shared:WaitForChild("UITheme"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))
local Format = require(Util:WaitForChild("Format"))

local FootballService = {}
FootballService.Nombre = "FootballService"

local PREFIJO = "[ColegioRP][FootballService]"
local CFG = Config.Futbol or {}
local ECO = Config.Economia or {}
local EQUIPOS = { "A", "B" }
local EJES = { "X", "Y", "Z" }
local ATRIBUTO_EQUIPO = "EquipoFutbol"
local PERMISO_ARBITRO = "futbol.arbitro"
local REMOTO_PATADA = "FootballKick"
local REMOTO_ACCION = "FootballAction"

---------------------------------------------------------------------------------------------------
-- Parámetros (Config.Futbol con respaldo; el resto son ajustes propios del servicio)
---------------------------------------------------------------------------------------------------
FootballService.ZonaPorDefecto = "CANCHA" -- Zona de MapaLogico con la definición Futbol.
FootballService.DistanciaPatada = tonumber(CFG.DistanciaPatada) or 9 -- Studs HumanoidRootPart-balón.
FootballService.FuerzaMax = tonumber(CFG.FuerzaMax) or 60 -- Velocidad (studs/s) con Fuerza = 1.
FootballService.CooldownPatada = tonumber(CFG.CooldownPatada) or 0.6 -- Segundos entre patadas del mismo jugador.
FootballService.DuracionPartidoSeg = tonumber(CFG.DuracionPartidoSeg) or 300 -- Duración del partido.
FootballService.ResetTrasGolSeg = tonumber(CFG.ResetTrasGolSeg) or 3 -- Espera antes de recolocar el balón tras un gol.
FootballService.JugadoresPorEquipoMax = tonumber(CFG.JugadoresPorEquipoMax) or 7 -- Máximo por equipo.

FootballService.ToleranciaCooldownSeg = 0.08 -- Margen por variación de latencia entre dos patadas legítimas.
FootballService.ToleranciaDistanciaBase = 0.5 -- Studs extra de tolerancia en la distancia de patada.
FootballService.LatenciaAsumidaSeg = 0.12 -- Tolerancia extra = velocidad del balón × esta latencia...
FootballService.ToleranciaDistanciaMax = 3 -- ...con este máximo (studs).
FootballService.FraccionVerticalMax = 0.35 -- Componente vertical máxima de la patada (fracción de la fuerza).
FootballService.ProductoSentidoMin = -0.25 -- Producto escalar mínimo dirección·(jugador->balón): impide "atraer" el balón.
FootballService.VelocidadAnomala = 150 -- |AssemblyLinearVelocity| por encima de la cual se rescata el balón.
FootballService.PeriodoFisicaSeg = 0.1 -- Muestreo de goles y rescate (Heartbeat con acumulador).
FootballService.PeriodoPresenciaSeg = 1 -- Bucle de presencia, reloj del partido y marcador.
FootballService.EnfriamientoGolSeg = 3 -- No se cuenta otro gol durante estos segundos.
FootballService.GraciaCanchaVaciaSeg = 3 -- Segundos sin jugadores en la cancha antes de anclar el balón.
FootballService.VentanaAutorGolSeg = 8 -- Una patada dentro de esta ventana se atribuye como autora del gol.
FootballService.BalanceEquipos = true -- true = impide unirse si los equipos quedarían muy desequilibrados.
FootballService.DiferenciaEquiposMax = 2 -- Diferencia máxima de jugadores entre equipos con BalanceEquipos.
FootballService.MinJugadoresPorEquipo = 1 -- Jugadores mínimos por equipo para iniciar un partido.
FootballService.MargenZonaUnirse = 6 -- Studs fuera de la caja de la cancha en los que aún se puede unir a un equipo.
FootballService.SalidaAutomaticaSeg = 90 -- Fuera de la cancha más de esto -> se sale del equipo automáticamente.
FootballService.AutoInicio = true -- Sin árbitro conectado y con deporte permitido, el partido arranca solo.
FootballService.AutoInicioSeg = 15 -- Cuenta atrás del inicio automático.
FootballService.PausaTrasPartidoSeg = 20 -- Pausa tras un partido antes de una nueva cuenta atrás automática.
FootballService.FraccionParticipacionMin = 0.5 -- Fracción mínima (del partido y de presencia) para la recompensa.
FootballService.AuditoriaRepeticionSeg = 5 -- Un mismo rechazo (jugador+motivo) se audita como máximo cada N s.
FootballService.AvisoRechazoSeg = 2 -- Aviso al jugador de una patada rechazada como máximo cada N s.
FootballService.TamanoBalon = 2 -- Diámetro del balón (studs).
FootballService.DensidadBalon = 0.5
FootballService.FriccionBalon = 0.6
FootballService.ElasticidadBalon = 0.5

-- Textos para el jugador según el motivo de rechazo de una patada.
local TEXTOS_PATADA = {
	sin_personaje = "Necesitas tu personaje para patear.",
	sin_balon = "El balón no está disponible.",
	reinicio_tras_gol = "Espera: el balón vuelve al centro.",
	cooldown = "Espera un momento antes de volver a patear.",
	direccion_nula = "Dirección de patada no válida.",
	fuerza = "Fuerza de patada no válida.",
	distancia = "Estás demasiado lejos del balón.",
	sentido = "Patea el balón hacia delante.",
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function valida(instancia)
	return typeof(instancia) == "Instance" and instancia.Parent ~= nil
end

local function esVector(v)
	return typeof(v) == "Vector3"
end

local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function vectorFinito(v)
	return esVector(v) and esFinito(v.X) and esFinito(v.Y) and esFinito(v.Z)
end

local function contar(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function copiarTabla(t)
	if typeof(t) ~= "table" then
		return t
	end
	local copia = {}
	for clave, valor in pairs(t) do
		copia[clave] = copiarTabla(valor)
	end
	return copia
end

local function otroEquipo(letra)
	if letra == "A" then
		return "B"
	end
	return "A"
end

local function servidorAhora()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and esFinito(t) then
		return t
	end
	return os.time()
end

-- HumanoidRootPart y Humanoid si el personaje existe y está vivo; nil si no.
local function personajeVivo(player)
	local personaje = player.Character
	if not personaje or personaje.Parent == nil then
		return nil
	end
	local humanoide = personaje:FindFirstChildOfClass("Humanoid")
	if not humanoide or humanoide.Health <= 0 then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if not raiz or not raiz:IsA("BasePart") then
		return nil
	end
	return raiz, humanoide
end

local function posicionDe(player)
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- ¿El segmento p0 -> p1 toca la caja de la parte? (método de las franjas en el espacio local de la parte).
-- Con p0 == p1 equivale a comprobar si el punto está dentro de la caja.
local function segmentoCruzaCaja(parte, p0, p1)
	local a = parte.CFrame:PointToObjectSpace(p0)
	local b = parte.CFrame:PointToObjectSpace(p1)
	local d = b - a
	local medio = parte.Size / 2
	local tmin, tmax = 0, 1
	for _, eje in ipairs(EJES) do
		local origen, delta, h = a[eje], d[eje], medio[eje]
		if math.abs(delta) < 1e-6 then
			if math.abs(origen) > h then
				return false
			end
		else
			local t1 = (-h - origen) / delta
			local t2 = (h - origen) / delta
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			if t1 > tmin then
				tmin = t1
			end
			if t2 < tmax then
				tmax = t2
			end
			if tmin > tmax then
				return false
			end
		end
	end
	return true
end

-- Primera zona de MapaLogico con definición Futbol (prioridad a CANCHA). Devuelve zonaId, def.
local function buscarZonaFutbol(preferida)
	local zona = MapaLogico.Zonas[preferida]
	if zona and typeof(zona.Futbol) == "table" then
		return preferida, zona.Futbol
	end
	for _, id in ipairs(MapaLogico.OrdenZonas or {}) do
		local z = MapaLogico.Zonas[id]
		if z and typeof(z.Futbol) == "table" then
			return id, z.Futbol
		end
	end
	return preferida, nil
end

-- Part invisible, anclada y sin colisiones (volumen lógico de arco).
local function nuevaParteInvisible(nombre, tamano, cframe, padre)
	local parte = Instance.new("Part")
	parte.Name = nombre
	parte.Anchored = true
	parte.CanCollide = false
	parte.CanQuery = false
	parte.CanTouch = false
	parte.CastShadow = false
	parte.Transparency = 1
	parte.Locked = true
	parte.Size = tamano
	parte.CFrame = cframe
	parte.Parent = padre
	return parte
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function FootballService:Init(registro)
	self.registro = registro
	self.zonaId = self.ZonaPorDefecto
	self.equipos = { A = {}, B = {} } -- letra -> { [userId] = true }
	self.equipoDe = {} -- userId -> "A" | "B"
	self.ingreso = {} -- userId -> os.clock() de entrada al equipo
	self.fueraDesde = {} -- userId -> os.clock() desde que está fuera de la cancha
	self.ultimaPatada = {} -- userId -> os.clock() de la última patada aceptada
	self.ultimaAuditoria = {} -- "userId|accion|motivo" -> { T, Omitidos }
	self.ultimoAviso = {} -- userId -> os.clock() del último aviso de patada rechazada
	self.erroresAvisados = {} -- clave -> os.clock() (evita repetir warn)
	self.enCancha = {} -- Player -> true (último muestreo de presencia)
	self.ultimoPateador = nil -- { UserId, Equipo, T }
	self.activo = false -- ¿el balón se está simulando?
	self.reinicioPendiente = false
	self.tokenReinicio = 0
	self.ultimoGolClock = -math.huge
	self.ultimoConJugadores = -math.huge
	self.finPartidoClock = -math.huge
	self.autoInicioClock = nil
	self.autoInicioServidor = nil
	self.posAnterior = nil
	self.acumPresencia = 0
	self.acumFisica = 0
	self.contadorPartidos = 0
	self.partido = self:_PartidoVacio()
	self.ultimoResultado = nil
	self.conexiones = {}
	self.conexionFisica = nil
	self.emisionPendiente = false
	self.inicioLibreContrato = false
	self.estadisticas = {
		Patadas = 0, Rechazos = 0, Goles = 0, GolesAmistosos = 0, Partidos = 0, Rescates = 0, PorMotivo = {},
	}
	self.instancias = { Carpeta = nil, Balon = nil, ArcoA = nil, ArcoB = nil, Marcador = nil, MarcadorGui = nil }
	self.limites = nil
	self.inicio = nil
	self.marcadorUI = nil
	self.GolMarcado = Signal.new() -- (equipoAnotador, playerAutorOrNil, marcador)
	self.PartidoIniciado = Signal.new() -- (estado)
	self.PartidoTerminado = Signal.new() -- (resultado)
	self.EquiposCambiados = Signal.new() -- (player, equipoNuevoOrNil, equipoAnterior)
end

function FootballService:Start()
	self.AuditLog = self:_Servicio("AuditLogService")

	-- ¿El contrato permite que cualquier jugador pida "Iniciar"? (si no, el inicio libre es automático).
	local okPermiso, permisoIniciar = pcall(RemoteContracts.PermisoPara, REMOTO_ACCION, { Accion = "Iniciar" })
	self.inicioLibreContrato = okPermiso and permisoIniciar == nil

	local okInst, errInst = pcall(self._ResolverInstancias, self)
	if not okInst then
		warn(PREFIJO .. " No se pudieron preparar el balón, los arcos o el marcador: " .. tostring(errInst))
	end

	local RemoteService = self:_Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar(REMOTO_PATADA, function(player, datos)
			return self:_ManejarPatada(player, datos)
		end)
		RemoteService:Registrar(REMOTO_ACCION, function(player, datos)
			return self:_ManejarAccion(player, datos)
		end)
		if typeof(RemoteService.AportarSnapshot) == "function" then
			pcall(RemoteService.AportarSnapshot, RemoteService, "Futbol", function(player)
				return self:Snapshot(player)
			end)
		end
	else
		warn(PREFIJO .. " RemoteService no disponible: FootballKick y FootballAction no tendrán handler.")
	end

	self:_ConectarJornada()

	table.insert(self.conexiones, Players.PlayerRemoving:Connect(function(player)
		local ok, err = pcall(self._AlSalirJugador, self, player)
		if not ok then
			warn(PREFIJO .. " Error al limpiar al jugador " .. player.Name .. ": " .. tostring(err))
		end
	end))

	-- Bucle de presencia (1 s): activa/desactiva la física, reloj del partido, marcador y auto-inicio.
	table.insert(self.conexiones, RunService.Heartbeat:Connect(function(dt)
		self.acumPresencia = self.acumPresencia + dt
		if self.acumPresencia < self.PeriodoPresenciaSeg then
			return
		end
		self.acumPresencia = 0
		local ok, err = pcall(self._Tick, self)
		if not ok then
			self:_AvisarError("tick", err)
		end
	end))

	self:_ActualizarMarcador()
	self:_Registrar("Sistema", nil, "Futbol", string.format(
		"Cancha %s lista · balón %s · arcos %s/%s · marcador %s · inicio libre por contrato: %s",
		tostring(self.zonaId),
		valida(self.instancias.Balon) and "sí" or "no",
		valida(self.instancias.ArcoA) and "sí" or "no",
		valida(self.instancias.ArcoB) and "sí" or "no",
		valida(self.instancias.MarcadorGui) and "sí" or "no",
		self.inicioLibreContrato and "sí" or "no (inicio automático)"))
end

-- Desconecta los bucles y deja el balón anclado (uso en pruebas o al recargar el sistema).
function FootballService:Detener()
	self:_DetenerFisica()
	for _, conexion in ipairs(self.conexiones) do
		pcall(function()
			conexion:Disconnect()
		end)
	end
	self.conexiones = {}
	self.activo = false
	self:_CancelarReinicio()
	pcall(self._RecolocarBalon, self, "detener")
end

---------------------------------------------------------------------------------------------------
-- Acceso a otros servicios (tolerante a ausencia)
---------------------------------------------------------------------------------------------------
function FootballService:_Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		return registro.Get(nombre)
	end
	return nil
end

function FootballService:_Registrar(categoria, player, accion, detalle)
	local AuditLog = self.AuditLog or self:_Servicio("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, categoria, player, accion, detalle)
	end
end

-- Auditoría de un rechazo con supresión de repeticiones (jugador + acción + motivo). categoria por defecto
-- "Remoto" (cuenta también en MetricsService); otra categoría solo se registra en AuditLogService.
function FootballService:_AuditarRechazo(player, accion, motivo, detalle, categoria)
	local uid = esJugador(player) and player.UserId or 0
	local clave = tostring(uid) .. "|" .. tostring(accion) .. "|" .. tostring(motivo)
	local ahora = os.clock()
	local previo = self.ultimaAuditoria[clave]
	if previo and ahora - previo.T < self.AuditoriaRepeticionSeg then
		previo.Omitidos = previo.Omitidos + 1
		return
	end
	local texto = tostring(motivo)
	if detalle ~= nil and detalle ~= "" then
		texto = texto .. ": " .. tostring(detalle)
	end
	if previo and previo.Omitidos > 0 then
		texto = texto .. string.format(" (+%d repetidos)", previo.Omitidos)
	end
	self.ultimaAuditoria[clave] = { T = ahora, Omitidos = 0 }
	self:_Registrar(categoria or "Remoto", player, accion, texto)
	if categoria ~= nil and categoria ~= "Remoto" then
		return
	end
	local Metrics = self:_Servicio("MetricsService")
	if Metrics and typeof(Metrics.IncrementarRechazo) == "function" then
		pcall(Metrics.IncrementarRechazo, Metrics, accion, motivo)
	end
end

-- warn como máximo una vez cada 30 s por clave.
function FootballService:_AvisarError(clave, err)
	local ahora = os.clock()
	local previo = self.erroresAvisados[clave]
	if previo and ahora - previo < 30 then
		return
	end
	self.erroresAvisados[clave] = ahora
	warn(PREFIJO .. " Error en " .. tostring(clave) .. ": " .. tostring(err))
end

function FootballService:_Notificar(player, texto, nivel)
	local RemoteService = self:_Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" and esJugador(player) then
		pcall(RemoteService.Enviar, RemoteService, player, "Notificacion", {
			Titulo = "Fútbol", Texto = texto, Nivel = nivel or "info", Tipo = nivel or "info",
		})
	end
end

function FootballService:_EsArbitro(player)
	local RoleService = self:_Servicio("RoleService")
	if RoleService and typeof(RoleService.Tiene) == "function" then
		local ok, tiene = pcall(RoleService.Tiene, RoleService, player, PERMISO_ARBITRO)
		return ok and tiene == true
	end
	return false
end

-- ¿Hay algún jugador conectado con futbol.arbitro?
function FootballService:_HayArbitroConectado()
	local RoleService = self:_Servicio("RoleService")
	if not RoleService then
		return false
	end
	if typeof(RoleService.ConPermiso) == "function" then
		local ok, lista = pcall(RoleService.ConPermiso, RoleService, PERMISO_ARBITRO)
		if ok and typeof(lista) == "table" then
			return #lista > 0
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if self:_EsArbitro(player) then
			return true
		end
	end
	return false
end

-- SchoolDayService:PermiteDeporte(); sin el servicio no se restringe el deporte.
function FootballService:_PermiteDeporte()
	local SchoolDay = self:_Servicio("SchoolDayService")
	if SchoolDay and typeof(SchoolDay.PermiteDeporte) == "function" then
		local ok, permite = pcall(SchoolDay.PermiteDeporte, SchoolDay)
		if ok then
			return permite == true
		end
	end
	return true
end

function FootballService:_ConectarSenal(senal, fn)
	if typeof(senal) ~= "table" or typeof(senal.Connect) ~= "function" then
		return false
	end
	local ok, conexion = pcall(function()
		return senal:Connect(fn)
	end)
	if ok and conexion ~= nil then
		table.insert(self.conexiones, conexion)
		return true
	end
	return false
end

function FootballService:_ConectarJornada()
	local SchoolDay = self:_Servicio("SchoolDayService")
	if not SchoolDay then
		return
	end
	self:_ConectarSenal(SchoolDay.EstadoCambiado, function()
		task.defer(function()
			local ok, err = pcall(self._AlCambiarJornada, self)
			if not ok then
				self:_AvisarError("jornada", err)
			end
		end)
	end)
	self:_ConectarSenal(SchoolDay.JornadaTerminada, function()
		task.defer(function()
			if self.partido.Estado == "EnJuego" then
				pcall(self._TerminarPartido, self, "Fin de la jornada escolar", false)
			end
		end)
	end)
end

-- Un partido iniciado sin árbitro termina si la jornada deja de permitir deporte.
function FootballService:_AlCambiarJornada()
	if self.partido.Estado == "EnJuego" and self.partido.Libre and not self:_PermiteDeporte() then
		self:_TerminarPartido("La jornada pasó a otra actividad", false)
		return
	end
	self:_EmitirEstado()
end

---------------------------------------------------------------------------------------------------
-- Instancias del mapa (balón, arcos, marcador)
---------------------------------------------------------------------------------------------------
function FootballService:_CarpetaPropia(MapService)
	if MapService and typeof(MapService.Carpeta) == "function" then
		local ok, carpeta = pcall(MapService.Carpeta, MapService, "Futbol")
		if ok and valida(carpeta) then
			return carpeta
		end
	end
	local nombreRaiz = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"
	local raiz = workspace:FindFirstChild(nombreRaiz)
	if not raiz then
		raiz = Instance.new("Folder")
		raiz.Name = nombreRaiz
		raiz.Parent = workspace
	end
	local carpeta = raiz:FindFirstChild("Futbol")
	if not carpeta then
		carpeta = Instance.new("Folder")
		carpeta.Name = "Futbol"
		carpeta.Parent = raiz
	end
	return carpeta
end

function FootballService:_ResolverInstancias()
	self:_DetenerFisica()
	self.activo = false
	self.posAnterior = nil

	local MapService = self:_Servicio("MapService")
	local info = nil
	if MapService and typeof(MapService.Futbol) == "function" then
		local ok, resultado = pcall(MapService.Futbol, MapService)
		if ok and typeof(resultado) == "table" then
			info = resultado
		end
	end
	info = info or {}

	local zonaId, def = nil, nil
	if typeof(info.ZonaId) == "string" then
		zonaId, def = buscarZonaFutbol(info.ZonaId)
	else
		zonaId, def = buscarZonaFutbol(self.ZonaPorDefecto)
	end
	self.zonaId = zonaId or self.ZonaPorDefecto
	def = def or {}
	local zona = Zones.Zona(self.zonaId)

	local carpeta = info.Carpeta
	if not valida(carpeta) then
		carpeta = self:_CarpetaPropia(MapService)
	end
	self.instancias.Carpeta = carpeta

	-- Límites de rescate.
	local limites = info.Limites
	if not (typeof(limites) == "table" and esVector(limites.Min) and esVector(limites.Max)) then
		limites = def.Limites
	end
	if not (typeof(limites) == "table" and esVector(limites.Min) and esVector(limites.Max)) then
		limites = nil
		local minZona, maxZona = Zones.Limites(self.zonaId)
		if minZona and maxZona then
			limites = { Min = minZona - Vector3.new(6, 6, 6), Max = maxZona + Vector3.new(6, 30, 6) }
		end
	end
	if limites then
		self.limites = { Min = limites.Min, Max = limites.Max }
	else
		self.limites = nil
	end

	-- Punto de saque (centro).
	local inicio = info.Inicio
	if not esVector(inicio) then
		inicio = def.Balon
	end
	if not esVector(inicio) and zona then
		local _, spawnY = Zones.AlturasDe(zona)
		inicio = Vector3.new(zona.Centro.X, spawnY + 1, zona.Centro.Z)
	end
	if not esVector(inicio) then
		inicio = Vector3.new(0, 5, 0)
	end
	self.inicio = inicio

	-- Balón.
	local balon = info.Balon
	if not (valida(balon) and balon:IsA("BasePart")) then
		balon = carpeta:FindFirstChild("Balon")
	end
	if not (valida(balon) and balon:IsA("BasePart")) then
		balon = Instance.new("Part")
		balon.Name = "Balon"
		balon.Color = Color3.fromRGB(245, 245, 245)
		balon.Material = Enum.Material.SmoothPlastic
		balon.TopSurface = Enum.SurfaceType.Smooth
		balon.BottomSurface = Enum.SurfaceType.Smooth
		balon.Anchored = true
		balon.CFrame = CFrame.new(inicio)
		balon:SetAttribute("Inicio", inicio)
		balon.Parent = carpeta
		warn(PREFIJO .. " MapService no aportó el balón; se creó uno propio en " .. carpeta:GetFullName())
	end
	self:_PrepararBalon(balon)

	-- Arcos (volúmenes de gol).
	for _, letra in ipairs(EQUIPOS) do
		local nombre = "Arco" .. letra
		local arco = info[nombre]
		if not (valida(arco) and arco:IsA("BasePart")) then
			arco = carpeta:FindFirstChild(nombre)
		end
		if not (valida(arco) and arco:IsA("BasePart")) then
			arco = self:_CrearArco(carpeta, letra, def[nombre], zona)
		end
		if arco then
			pcall(function()
				arco:SetAttribute("Equipo", letra)
			end)
		end
		self.instancias[nombre] = arco
	end

	-- Marcador físico.
	local marcador = info.Marcador
	if not (valida(marcador) and marcador:IsA("BasePart")) then
		marcador = carpeta:FindFirstChild("Marcador")
	end
	if not (valida(marcador) and marcador:IsA("BasePart")) then
		marcador = self:_CrearMarcador(carpeta, def, zona)
	end
	self.instancias.Marcador = marcador
	local gui = info.MarcadorGui
	if not (valida(gui) and gui:IsA("SurfaceGui")) and marcador then
		gui = marcador:FindFirstChildOfClass("SurfaceGui")
	end
	if not (valida(gui) and gui:IsA("SurfaceGui")) and marcador then
		gui = Instance.new("SurfaceGui")
		gui.Name = "MarcadorGui"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 50
		gui.LightInfluence = 0
		gui.ClipsDescendants = true
		gui.Parent = marcador
	end
	self.instancias.MarcadorGui = gui
	self:_ConstruirMarcadorGui()

	pcall(function()
		carpeta:SetAttribute("ZoneId", self.zonaId)
		carpeta:SetAttribute("Activo", false)
		carpeta:SetAttribute("DistanciaPatada", self.DistanciaPatada)
		carpeta:SetAttribute("CooldownPatada", self.CooldownPatada)
	end)
end

function FootballService:_PropiedadesBalon()
	local ok, propiedades = pcall(PhysicalProperties.new, self.DensidadBalon, self.FriccionBalon, self.ElasticidadBalon, 1, 1)
	if ok then
		return propiedades
	end
	return nil
end

-- Propiedades físicas estables y estado anclado en el centro.
function FootballService:_PrepararBalon(balon)
	self.instancias.Balon = balon
	local tamano = self.TamanoBalon
	pcall(function()
		if balon:IsA("Part") then
			balon.Shape = Enum.PartType.Ball
		end
		balon.Size = Vector3.new(tamano, tamano, tamano)
		balon.CanCollide = true
		balon.CanTouch = true
		balon.CanQuery = true
		balon.Massless = false
		balon.Locked = true
		local propiedades = self:_PropiedadesBalon()
		if propiedades then
			balon.CustomPhysicalProperties = propiedades
		end
		balon:SetAttribute("ColegioRP_Balon", true)
	end)
	pcall(function()
		balon.Anchored = true
		balon.CFrame = CFrame.new(self.inicio)
		balon.AssemblyLinearVelocity = Vector3.zero
		balon.AssemblyAngularVelocity = Vector3.zero
	end)
end

function FootballService:_CrearArco(carpeta, letra, arcoDef, zona)
	local centro, tamano = nil, nil
	if typeof(arcoDef) == "table" and esVector(arcoDef.Centro) and esVector(arcoDef.Tamano) then
		centro, tamano = arcoDef.Centro, arcoDef.Tamano
	elseif zona then
		local sueloY = Zones.AlturasDe(zona)
		local signo = -1
		if letra == "B" then
			signo = 1
		end
		centro = Vector3.new(zona.Centro.X + signo * (zona.Tamano.X / 2 - 3), sueloY + 3.5, zona.Centro.Z)
		tamano = Vector3.new(3, 7, 12)
	end
	if not centro then
		warn(PREFIJO .. " Sin datos para crear Arco" .. letra .. "; no habrá goles en ese arco.")
		return nil
	end
	local arco = nuevaParteInvisible("Arco" .. letra, tamano, CFrame.new(centro), carpeta)
	warn(PREFIJO .. " MapService no aportó Arco" .. letra .. "; se creó un volumen propio.")
	return arco
end

function FootballService:_CrearMarcador(carpeta, def, zona)
	local posicion, normal = nil, Vector3.new(0, 0, -1)
	if typeof(def.Marcador) == "table" and esVector(def.Marcador.Centro) then
		posicion = def.Marcador.Centro
		if esVector(def.Marcador.Normal) and def.Marcador.Normal.Magnitude > 1e-3 then
			normal = def.Marcador.Normal.Unit
		end
	elseif esVector(def.Marcador) then
		posicion = def.Marcador
	elseif zona then
		local sueloY = Zones.AlturasDe(zona)
		posicion = Vector3.new(zona.Centro.X, sueloY + 12, zona.Centro.Z + zona.Tamano.Z / 2)
	end
	if not posicion then
		return nil
	end
	local marcador = Instance.new("Part")
	marcador.Name = "Marcador"
	marcador.Anchored = true
	marcador.CanCollide = false
	marcador.CanQuery = false
	marcador.CanTouch = false
	marcador.CastShadow = false
	marcador.Locked = true
	marcador.Material = Enum.Material.SmoothPlastic
	marcador.Color = Color3.fromRGB(20, 20, 24)
	marcador.Size = Vector3.new(12, 4, 0.4)
	marcador.CFrame = CFrame.lookAt(posicion, posicion + normal * 2)
	marcador.Parent = carpeta
	warn(PREFIJO .. " MapService no aportó el marcador; se creó uno propio.")
	return marcador
end

-- Construye el contenido de la SurfaceGui del marcador (equipos, goles, tiempo y estado).
function FootballService:_ConstruirMarcadorGui()
	local gui = self.instancias.MarcadorGui
	self.marcadorUI = nil
	if not valida(gui) then
		return
	end
	local previo = gui:FindFirstChild("ColegioRP_Marcador")
	if previo then
		previo:Destroy()
	end
	local Colores = UITheme.Colores
	local fondo = Instance.new("Frame")
	fondo.Name = "ColegioRP_Marcador"
	fondo.Size = UDim2.fromScale(1, 1)
	fondo.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
	fondo.BorderSizePixel = 0

	local function etiqueta(nombre, x, y, ancho, alto, color, fuente, texto, alineacion)
		local label = Instance.new("TextLabel")
		label.Name = nombre
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromScale(x, y)
		label.Size = UDim2.fromScale(ancho, alto)
		label.Font = fuente or UITheme.Fuente("Titulo")
		label.TextColor3 = color or Colores.Blanco
		label.TextScaled = true
		label.TextXAlignment = alineacion or Enum.TextXAlignment.Center
		label.Text = texto or ""
		label.Parent = fondo
		return label
	end

	local franja = Instance.new("Frame")
	franja.Name = "Franja"
	franja.BackgroundColor3 = Colores.Rojo
	franja.BorderSizePixel = 0
	franja.Position = UDim2.fromScale(0, 0)
	franja.Size = UDim2.fromScale(1, 0.03)
	franja.Parent = fondo

	local azulClaro = UITheme.Aclarar(Colores.Azul, 0.35)
	local nombreCorto = string.upper(tostring(Config.NombreCorto or "Colegio"))
	local ui = { Fondo = fondo }
	ui.Titulo = etiqueta("Titulo", 0.05, 0.05, 0.9, 0.14, Colores.TextoSecundario, UITheme.Fuente("Subtitulo"), "CANCHA · " .. nombreCorto)
	ui.EquipoA = etiqueta("EquipoA", 0.03, 0.22, 0.34, 0.16, Colores.Rojo, nil, "EQUIPO A")
	ui.EquipoB = etiqueta("EquipoB", 0.63, 0.22, 0.34, 0.16, azulClaro, nil, "EQUIPO B")
	ui.GolesA = etiqueta("GolesA", 0.05, 0.38, 0.3, 0.42, Colores.Blanco, nil, "0")
	ui.Separador = etiqueta("Separador", 0.4, 0.42, 0.2, 0.34, Colores.TextoSecundario, nil, "-")
	ui.GolesB = etiqueta("GolesB", 0.65, 0.38, 0.3, 0.42, Colores.Blanco, nil, "0")
	ui.Estado = etiqueta("Estado", 0.04, 0.82, 0.58, 0.14, Colores.TextoSecundario, UITheme.Fuente("Subtitulo"), "CANCHA LIBRE", Enum.TextXAlignment.Left)
	ui.Tiempo = etiqueta("Tiempo", 0.64, 0.8, 0.32, 0.17, Colores.Amarillo, nil, Format.Tiempo(self.DuracionPartidoSeg), Enum.TextXAlignment.Right)
	fondo.Parent = gui
	self.marcadorUI = ui
end

-- Refresca los textos del marcador físico (1 vez/s durante el partido y en cada evento).
function FootballService:_ActualizarMarcador()
	local ui = self.marcadorUI
	if not ui or not valida(ui.Fondo) then
		return
	end
	local p = self.partido
	local goles = p.Goles
	ui.GolesA.Text = tostring(goles.A)
	ui.GolesB.Text = tostring(goles.B)
	ui.EquipoA.Text = string.format("EQUIPO A (%d)", contar(self.equipos.A))
	ui.EquipoB.Text = string.format("EQUIPO B (%d)", contar(self.equipos.B))
	if p.Estado == "EnJuego" then
		ui.Tiempo.Text = Format.Tiempo(self:_Restante())
		ui.Estado.Text = "EN JUEGO"
	elseif p.Estado == "Terminado" then
		ui.Tiempo.Text = "FINAL"
		local resultado = self.ultimoResultado
		if resultado and resultado.Ganador == "A" then
			ui.Estado.Text = "GANA EL EQUIPO A"
		elseif resultado and resultado.Ganador == "B" then
			ui.Estado.Text = "GANA EL EQUIPO B"
		else
			ui.Estado.Text = "EMPATE"
		end
	else
		ui.Tiempo.Text = Format.Tiempo(self.DuracionPartidoSeg)
		if self.autoInicioClock then
			ui.Estado.Text = string.format("INICIO EN %d s", math.max(0, math.ceil(self.autoInicioClock - os.clock())))
		else
			ui.Estado.Text = "CANCHA LIBRE"
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Simulación del balón
---------------------------------------------------------------------------------------------------
function FootballService:_AsegurarPropietario(forzar)
	local balon = self.instancias.Balon
	if not valida(balon) or balon.Anchored then
		return
	end
	pcall(function()
		if forzar or balon:GetNetworkOwner() ~= nil or balon:GetNetworkOwnershipAuto() then
			balon:SetNetworkOwner(nil)
		end
	end)
end

function FootballService:_Activar()
	local balon = self.instancias.Balon
	if not valida(balon) then
		return false
	end
	self.activo = true
	self.posAnterior = nil
	pcall(function()
		balon.Anchored = false
	end)
	self:_AsegurarPropietario(true)
	if not self.conexionFisica then
		self.acumFisica = 0
		self.conexionFisica = RunService.Heartbeat:Connect(function(dt)
			self.acumFisica = self.acumFisica + dt
			if self.acumFisica < self.PeriodoFisicaSeg then
				return
			end
			self.acumFisica = 0
			local ok, err = pcall(self._PasoFisica, self)
			if not ok then
				self:_AvisarError("fisica", err)
			end
		end)
	end
	pcall(function()
		self.instancias.Carpeta:SetAttribute("Activo", true)
	end)
	return true
end

function FootballService:_DetenerFisica()
	if self.conexionFisica then
		pcall(function()
			self.conexionFisica:Disconnect()
		end)
		self.conexionFisica = nil
	end
end

-- Cancha vacía: sin bucle de goles y balón anclado en el centro.
function FootballService:_Desactivar()
	self:_DetenerFisica()
	self.activo = false
	self:_CancelarReinicio()
	self:_RecolocarBalon("cancha_vacia")
	pcall(function()
		self.instancias.Carpeta:SetAttribute("Activo", false)
	end)
end

-- Coloca el balón en el centro con velocidad 0 (anclado si la cancha está vacía).
function FootballService:_RecolocarBalon(_motivo)
	local balon = self.instancias.Balon
	if not valida(balon) then
		return
	end
	self.posAnterior = nil
	local destino = CFrame.new(self.inicio or balon.Position)
	pcall(function()
		balon.Anchored = not self.activo
		balon.CFrame = destino
		balon.AssemblyLinearVelocity = Vector3.zero
		balon.AssemblyAngularVelocity = Vector3.zero
	end)
	if self.activo then
		self:_AsegurarPropietario(true)
	end
end

function FootballService:_ProgramarReinicio(segundos)
	self.reinicioPendiente = true
	self.tokenReinicio = self.tokenReinicio + 1
	local token = self.tokenReinicio
	task.delay(math.max(0, segundos), function()
		if self.tokenReinicio ~= token then
			return
		end
		self.reinicioPendiente = false
		local ok, err = pcall(self._RecolocarBalon, self, "saque")
		if not ok then
			self:_AvisarError("saque", err)
		end
		self:_EnviarCancha({ Sub = "Saque" })
	end)
end

function FootballService:_CancelarReinicio()
	self.tokenReinicio = self.tokenReinicio + 1
	self.reinicioPendiente = false
end

-- Muestreo cada 0.1 s: rescate (límites, caída, velocidad anómala) y detección de goles.
function FootballService:_PasoFisica()
	local balon = self.instancias.Balon
	if not valida(balon) or balon.Anchored then
		return
	end
	local posicion = balon.Position
	local velocidad = balon.AssemblyLinearVelocity
	local motivo = nil
	if not vectorFinito(posicion) or not vectorFinito(velocidad) then
		motivo = "valores_invalidos"
	elseif velocidad.Magnitude > self.VelocidadAnomala then
		motivo = "velocidad_anomala"
	elseif self.limites then
		local minimo, maximo = self.limites.Min, self.limites.Max
		if posicion.Y < minimo.Y then
			motivo = "caida"
		elseif posicion.X < minimo.X or posicion.X > maximo.X or posicion.Z < minimo.Z or posicion.Z > maximo.Z or posicion.Y > maximo.Y then
			motivo = "fuera_de_limites"
		end
	end
	if motivo then
		self:_Rescatar(motivo, velocidad)
		return
	end

	local anterior = self.posAnterior or posicion
	self.posAnterior = posicion
	if self.reinicioPendiente or os.clock() - self.ultimoGolClock < self.EnfriamientoGolSeg then
		return
	end
	for _, letra in ipairs(EQUIPOS) do
		local arco = self.instancias["Arco" .. letra]
		if valida(arco) and segmentoCruzaCaja(arco, anterior, posicion) then
			self:_Gol(letra)
			return
		end
	end
end

function FootballService:_Rescatar(motivo, velocidad)
	self.estadisticas.Rescates = self.estadisticas.Rescates + 1
	if motivo == "velocidad_anomala" or motivo == "valores_invalidos" then
		local detalle = motivo
		if vectorFinito(velocidad) then
			detalle = string.format("%s (%.0f studs/s)", motivo, velocidad.Magnitude)
		end
		local up = self.ultimoPateador
		local sospechoso = nil
		if up and os.clock() - up.T < 2 then
			sospechoso = Players:GetPlayerByUserId(up.UserId)
		end
		self:_AuditarRechazo(sospechoso, "FutbolRescate", motivo, detalle, "Sistema")
	end
	self:_CancelarReinicio()
	self:_RecolocarBalon(motivo)
	self:_EnviarCancha({ Sub = "Rescate", Motivo = motivo })
end

-- Gol en el arco 'arcoLetra' (lo marca el equipo contrario).
function FootballService:_Gol(arcoLetra)
	local anotador = otroEquipo(arcoLetra)
	local ahora = os.clock()
	self.ultimoGolClock = ahora
	local p = self.partido
	local autor, autorNombre, equipoAutor = nil, nil, nil
	local up = self.ultimoPateador
	if up and ahora - up.T <= self.VentanaAutorGolSeg then
		local jugador = Players:GetPlayerByUserId(up.UserId)
		if jugador then
			autor = jugador
			autorNombre = jugador.DisplayName
			equipoAutor = up.Equipo
		end
	end
	if p.Estado == "EnJuego" then
		p.Goles[anotador] = p.Goles[anotador] + 1
		self.estadisticas.Goles = self.estadisticas.Goles + 1
		local autogol = autor ~= nil and equipoAutor ~= nil and equipoAutor ~= anotador
		if autor and equipoAutor == anotador then
			self:_SumarGolPerfil(autor)
		end
		self:_EnviarCancha({
			Sub = "Gol", Equipo = anotador, Marcador = { A = p.Goles.A, B = p.Goles.B },
			Autor = autorNombre, Autogol = autogol, Arco = arcoLetra, Amistoso = false,
		})
		self:_ActualizarMarcador()
		self:_EmitirEstado()
		self.GolMarcado:Fire(anotador, autor, { A = p.Goles.A, B = p.Goles.B })
	else
		self.estadisticas.GolesAmistosos = self.estadisticas.GolesAmistosos + 1
		self:_EnviarCancha({
			Sub = "Gol", Equipo = anotador, Marcador = { A = p.Goles.A, B = p.Goles.B },
			Autor = autorNombre, Arco = arcoLetra, Amistoso = true,
		})
	end
	self:_ProgramarReinicio(self.ResetTrasGolSeg)
end

function FootballService:_SumarGolPerfil(player)
	local DataService = self:_Servicio("DataService")
	if not DataService or typeof(DataService.Obtener) ~= "function" then
		return
	end
	local ok, perfil = pcall(DataService.Obtener, DataService, player)
	if ok and typeof(perfil) == "table" and typeof(perfil.Progreso) == "table" then
		perfil.Progreso.Goles = (tonumber(perfil.Progreso.Goles) or 0) + 1
		if typeof(DataService.Marcar) == "function" then
			pcall(DataService.Marcar, DataService, player)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Bucle de presencia (1 s)
---------------------------------------------------------------------------------------------------

-- Jugadores cuyo HumanoidRootPart está dentro de la zona de la cancha.
function FootballService:JugadoresEnCancha()
	local lista = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local posicion = posicionDe(player)
		if posicion and Zones.Contiene(self.zonaId, posicion) then
			table.insert(lista, player)
		end
	end
	return lista
end

function FootballService:_Tick()
	local ahora = os.clock()
	if not valida(self.instancias.Balon) or not valida(self.instancias.Carpeta) then
		self:_ResolverInstancias()
	elseif not (self.marcadorUI and valida(self.marcadorUI.Fondo)) then
		self:_ConstruirMarcadorGui()
	end

	-- Presencia: activa la física con >= 1 jugador; la detiene tras la gracia con la cancha vacía.
	local presentes = self:JugadoresEnCancha()
	local conjunto = {}
	local entrantes = {}
	for _, player in ipairs(presentes) do
		conjunto[player] = true
		if not self.enCancha[player] then
			table.insert(entrantes, player)
		end
	end
	self.enCancha = conjunto
	if #presentes > 0 then
		self.ultimoConJugadores = ahora
		if not self.activo then
			self:_Activar()
		else
			self:_AsegurarPropietario(false)
		end
	elseif self.activo and ahora - self.ultimoConJugadores >= self.GraciaCanchaVaciaSeg then
		self:_Desactivar()
	end

	local cambios = self:_RevisarAusentes(ahora)
	if self.partido.Estado == "EnJuego" then
		self:_AvanzarPartido(ahora)
	end
	if self:_RevisarAutoInicio(ahora) then
		cambios = true
	end
	if self.partido.Estado == "EnJuego" or self.autoInicioClock then
		self:_ActualizarMarcador()
	end
	if cambios then
		self:_ActualizarMarcador()
		self:_EmitirEstado()
	end
	-- Quien acaba de entrar en la cancha recibe el estado completo.
	for _, player in ipairs(entrantes) do
		self:_EnviarEstadoA(player)
	end
end

-- Saca de su equipo a quien lleva demasiado tiempo fuera de la cancha. Devuelve true si hubo cambios.
function FootballService:_RevisarAusentes(ahora)
	local salientes = {}
	for uid in pairs(self.equipoDe) do
		local player = Players:GetPlayerByUserId(uid)
		if not player then
			table.insert(salientes, uid)
		elseif self.enCancha[player] then
			self.fueraDesde[uid] = nil
		else
			local desde = self.fueraDesde[uid]
			if not desde then
				self.fueraDesde[uid] = ahora
			elseif ahora - desde >= self.SalidaAutomaticaSeg then
				table.insert(salientes, player)
			end
		end
	end
	for _, objetivo in ipairs(salientes) do
		self:_QuitarDeEquipo(objetivo, "ausencia", true)
		if esJugador(objetivo) then
			self:_Notificar(objetivo, "Saliste de tu equipo de fútbol por estar fuera de la cancha.", "aviso")
		end
	end
	return #salientes > 0
end

---------------------------------------------------------------------------------------------------
-- Equipos
---------------------------------------------------------------------------------------------------
function FootballService:_ListaEquipo(letra)
	local lista = {}
	for uid in pairs(self.equipos[letra]) do
		local player = Players:GetPlayerByUserId(uid)
		table.insert(lista, { UserId = uid, Nombre = player and player.DisplayName or tostring(uid) })
	end
	table.sort(lista, function(a, b)
		return string.lower(a.Nombre) < string.lower(b.Nombre)
	end)
	return lista
end

function FootballService:EquipoDe(player)
	if not esJugador(player) then
		return nil
	end
	return self.equipoDe[player.UserId]
end

function FootballService:_EquipoSugerido(actual)
	if actual then
		return actual
	end
	if contar(self.equipos.B) < contar(self.equipos.A) then
		return "B"
	end
	return "A"
end

function FootballService:_AsignarEquipo(player, equipo)
	local uid = player.UserId
	local anterior = self.equipoDe[uid]
	if anterior then
		self.equipos[anterior][uid] = nil
	end
	self.equipos[equipo][uid] = true
	self.equipoDe[uid] = equipo
	self.ingreso[uid] = os.clock()
	self.fueraDesde[uid] = nil
	pcall(function()
		player:SetAttribute(ATRIBUTO_EQUIPO, equipo)
	end)
	self.EquiposCambiados:Fire(player, equipo, anterior)
	self:_ActualizarMarcador()
	self:_EmitirEstado()
end

-- objetivo: Player o userId. sinEmitir = true cuando el llamador emite el estado al final.
function FootballService:_QuitarDeEquipo(objetivo, _motivo, sinEmitir)
	local uid = objetivo
	local player = nil
	if esJugador(objetivo) then
		uid = objetivo.UserId
		player = objetivo
	end
	local anterior = self.equipoDe[uid]
	if not anterior then
		return false
	end
	self.equipos[anterior][uid] = nil
	self.equipoDe[uid] = nil
	self.ingreso[uid] = nil
	self.fueraDesde[uid] = nil
	if player then
		pcall(function()
			player:SetAttribute(ATRIBUTO_EQUIPO, nil)
		end)
	end
	self.EquiposCambiados:Fire(player, nil, anterior)
	if self.partido.Estado == "EnJuego" and contar(self.equipos.A) == 0 and contar(self.equipos.B) == 0 then
		self:_TerminarPartido("Ambos equipos quedaron vacíos", true)
		return true
	end
	self:_ActualizarMarcador()
	if not sinEmitir then
		self:_EmitirEstado()
	end
	return true
end

function FootballService:Unirse(player, equipo)
	if not esJugador(player) then
		return { ok = false, error = "Jugador no válido." }
	end
	local raiz = personajeVivo(player)
	if not raiz then
		return self:_Rechazar(player, REMOTO_ACCION, "sin_personaje", "Unirse", "Necesitas estar en la cancha con tu personaje.")
	end
	local distanciaZona = Zones.DistanciaA(self.zonaId, raiz.Position)
	if distanciaZona > self.MargenZonaUnirse then
		return self:_Rechazar(player, REMOTO_ACCION, "fuera_de_zona", string.format("Unirse a %.0f studs de la cancha", distanciaZona),
			"Ve a la cancha para unirte a un equipo.")
	end
	local uid = player.UserId
	local actual = self.equipoDe[uid]
	if equipo == nil then
		equipo = self:_EquipoSugerido(actual)
	end
	if equipo ~= "A" and equipo ~= "B" then
		return self:_Rechazar(player, REMOTO_ACCION, "equipo", tostring(equipo), "Equipo no válido.")
	end
	if actual == equipo then
		return { ok = true, datos = self:Snapshot(player) }
	end
	local cantidad = contar(self.equipos[equipo])
	if cantidad >= self.JugadoresPorEquipoMax then
		return { ok = false, error = string.format("El equipo %s está completo (%d/%d).", equipo, cantidad, self.JugadoresPorEquipoMax), Codigo = "equipo_completo" }
	end
	if self.BalanceEquipos then
		local otro = otroEquipo(equipo)
		local cantidadOtro = contar(self.equipos[otro])
		if actual == otro then
			cantidadOtro = cantidadOtro - 1
		end
		if (cantidad + 1) - cantidadOtro > self.DiferenciaEquiposMax then
			return { ok = false, error = string.format("Los equipos quedarían desequilibrados; únete al equipo %s.", otro), Codigo = "desbalance" }
		end
	end
	self:_AsignarEquipo(player, equipo)
	return { ok = true, datos = self:Snapshot(player) }
end

function FootballService:Salir(player)
	if not esJugador(player) then
		return { ok = false, error = "Jugador no válido." }
	end
	if not self.equipoDe[player.UserId] then
		return { ok = false, error = "No estás en ningún equipo.", Codigo = "sin_equipo" }
	end
	self:_QuitarDeEquipo(player, "salir", false)
	return { ok = true, datos = self:Snapshot(player) }
end

---------------------------------------------------------------------------------------------------
-- Partido
---------------------------------------------------------------------------------------------------
function FootballService:_PartidoVacio()
	return {
		Id = 0, Estado = "Libre", Goles = { A = 0, B = 0 }, InicioClock = nil, InicioServidor = nil,
		Duracion = self.DuracionPartidoSeg, Origen = nil, IniciadoPor = nil, IniciadoPorNombre = nil,
		Libre = false, Participacion = {}, UltimoTick = nil,
	}
end

-- Segundos restantes del partido en curso (Duracion si no hay partido).
function FootballService:_Restante()
	local p = self.partido
	if p.Estado ~= "EnJuego" or not p.InicioClock then
		return p.Duracion or self.DuracionPartidoSeg
	end
	return math.max(0, p.Duracion - (os.clock() - p.InicioClock))
end

-- ¿Puede este jugador pedir "Iniciar"? (árbitro, o inicio libre si el contrato lo permite).
function FootballService:_PuedeIniciar(player, arbitroConectado, permiteDeporte)
	if self.partido.Estado == "EnJuego" then
		return false
	end
	if self:_EsArbitro(player) then
		return true
	end
	if not self.inicioLibreContrato then
		return false
	end
	return not arbitroConectado and permiteDeporte
end

function FootballService:Iniciar(player)
	if not esJugador(player) then
		return { ok = false, error = "Jugador no válido." }
	end
	if self.partido.Estado == "EnJuego" then
		return { ok = false, error = "Ya hay un partido en curso.", Codigo = "en_curso" }
	end
	local esArbitro = self:_EsArbitro(player)
	if not esArbitro then
		if self:_HayArbitroConectado() then
			return self:_Rechazar(player, REMOTO_ACCION, "arbitro_conectado", "Iniciar", "Hay un árbitro conectado: pídele que inicie el partido.")
		end
		if not self:_PermiteDeporte() then
			return self:_Rechazar(player, REMOTO_ACCION, "sin_deporte", "Iniciar", "Ahora no es momento de deporte (solo en descanso o almuerzo).")
		end
	end
	local minimo = self.MinJugadoresPorEquipo
	if contar(self.equipos.A) < minimo or contar(self.equipos.B) < minimo then
		return { ok = false, error = string.format("Cada equipo necesita al menos %d jugador(es).", minimo), Codigo = "faltan_jugadores" }
	end
	local origen = "Libre"
	if esArbitro then
		origen = "Arbitro"
	end
	self:_IniciarPartido(origen, player)
	return { ok = true, datos = self:Snapshot(player) }
end

function FootballService:_IniciarPartido(origen, player)
	self.contadorPartidos = self.contadorPartidos + 1
	local ahora = os.clock()
	self.partido = {
		Id = self.contadorPartidos, Estado = "EnJuego", Goles = { A = 0, B = 0 },
		InicioClock = ahora, InicioServidor = servidorAhora(), Duracion = self.DuracionPartidoSeg,
		Origen = origen, IniciadoPor = player and player.UserId or nil,
		IniciadoPorNombre = player and player.DisplayName or nil,
		Libre = origen ~= "Arbitro", Participacion = {}, UltimoTick = ahora,
	}
	self.ultimoResultado = nil
	self.ultimoGolClock = -math.huge
	self.autoInicioClock = nil
	self.autoInicioServidor = nil
	self:_CancelarReinicio()
	if not self.activo then
		self:_Activar()
	end
	self:_RecolocarBalon("inicio")
	self.estadisticas.Partidos = self.estadisticas.Partidos + 1
	self:_Registrar("Sistema", player, "PartidoIniciado", string.format("Partido %d (%s) · A %d vs B %d jugadores · %d s",
		self.partido.Id, tostring(origen), contar(self.equipos.A), contar(self.equipos.B), self.partido.Duracion))
	self:_EnviarCancha({
		Sub = "Inicio", Origen = origen, Duracion = self.partido.Duracion, InicioServidor = self.partido.InicioServidor,
		IniciadoPor = self.partido.IniciadoPorNombre,
	})
	self:_ActualizarMarcador()
	self:_EmitirEstado()
	self.PartidoIniciado:Fire(self:Estado())
end

function FootballService:Reiniciar(player)
	if esJugador(player) and not self:_EsArbitro(player) then
		return self:_Rechazar(player, REMOTO_ACCION, "permiso", "Reiniciar", "Solo un árbitro puede reiniciar el partido.")
	end
	local p = self.partido
	if p.Estado == "EnJuego" then
		local ahora = os.clock()
		p.Goles = { A = 0, B = 0 }
		p.InicioClock = ahora
		p.InicioServidor = servidorAhora()
		p.Participacion = {}
		p.UltimoTick = ahora
		self.ultimoGolClock = -math.huge
		self:_CancelarReinicio()
		self:_RecolocarBalon("reinicio")
		self:_EnviarCancha({ Sub = "Reinicio", Duracion = p.Duracion, InicioServidor = p.InicioServidor })
	else
		self.partido = self:_PartidoVacio()
		self.ultimoResultado = nil
		self:_CancelarReinicio()
		self:_RecolocarBalon("reinicio")
	end
	self:_Registrar("Sistema", player, "PartidoReiniciado", "Marcador y reloj a cero")
	self:_ActualizarMarcador()
	self:_EmitirEstado()
	return { ok = true, datos = self:Snapshot(player) }
end

function FootballService:Finalizar(player)
	if esJugador(player) and not self:_EsArbitro(player) then
		return self:_Rechazar(player, REMOTO_ACCION, "permiso", "Finalizar", "Solo un árbitro puede finalizar el partido.")
	end
	if self.partido.Estado ~= "EnJuego" then
		return { ok = false, error = "No hay ningún partido en curso.", Codigo = "sin_partido" }
	end
	local nombre = esJugador(player) and player.DisplayName or "el sistema"
	self:_TerminarPartido("Finalizado por " .. nombre, false)
	return { ok = true, datos = self:Snapshot(player) }
end

-- Suma el tiempo transcurrido desde el último tick a cada miembro de equipo que está en la cancha.
function FootballService:_SumarParticipacion(ahora)
	local p = self.partido
	local dt = math.clamp(ahora - (p.UltimoTick or ahora), 0, 2)
	p.UltimoTick = ahora
	if dt <= 0 then
		return
	end
	for uid in pairs(self.equipoDe) do
		local player = Players:GetPlayerByUserId(uid)
		if player and self.enCancha[player] then
			p.Participacion[uid] = (p.Participacion[uid] or 0) + dt
		end
	end
end

function FootballService:_AvanzarPartido(ahora)
	self:_SumarParticipacion(ahora)
	if self:_Restante() <= 0 then
		self:_TerminarPartido("Tiempo cumplido", false)
	end
end

-- Cierra el partido en curso: resultado, recompensas, marcador y aviso. Devuelve true si había partido.
function FootballService:_TerminarPartido(motivo, sinRecompensa)
	local p = self.partido
	if p.Estado ~= "EnJuego" then
		return false
	end
	local ahora = os.clock()
	self:_SumarParticipacion(ahora)
	local transcurrido = math.min(ahora - (p.InicioClock or ahora), p.Duracion)
	local golesA, golesB = p.Goles.A, p.Goles.B
	local ganador = "Empate"
	if golesA > golesB then
		ganador = "A"
	elseif golesB > golesA then
		ganador = "B"
	end
	local recompensa = tonumber(ECO.Recompensas and ECO.Recompensas.Partido) or 0
	local fraccion = self.FraccionParticipacionMin
	local merece = sinRecompensa ~= true and recompensa > 0 and transcurrido >= p.Duracion * fraccion
	local premiados = {}
	if merece then
		for uid in pairs(self.equipoDe) do
			local jugador = Players:GetPlayerByUserId(uid)
			if jugador and (p.Participacion[uid] or 0) >= transcurrido * fraccion then
				table.insert(premiados, jugador)
			end
		end
	end
	local montoPremio = 0
	if merece then
		montoPremio = recompensa
	end
	local resultado = {
		Id = p.Id, Goles = { A = golesA, B = golesB }, Ganador = ganador, Motivo = tostring(motivo or ""),
		Duracion = math.floor(transcurrido + 0.5), Premiados = #premiados, Recompensa = montoPremio, T = os.time(),
	}
	self.ultimoResultado = resultado
	p.Estado = "Terminado"
	p.FinClock = ahora
	self.finPartidoClock = ahora
	self.autoInicioClock = nil
	self.autoInicioServidor = nil

	self:_Acreditar(premiados, recompensa, resultado)
	self:_Registrar("Sistema", nil, "PartidoTerminado", string.format("Partido %d: A %d - %d B (%s) · %s · %d s · %d premiados",
		p.Id, golesA, golesB, ganador, resultado.Motivo, resultado.Duracion, #premiados))
	self:_EnviarCancha({
		Sub = "Fin", Ganador = ganador, Marcador = { A = golesA, B = golesB }, Motivo = resultado.Motivo,
		Recompensa = montoPremio, Premiados = #premiados,
	})
	self:_ActualizarMarcador()
	self:_EmitirEstado()
	self.PartidoTerminado:Fire(copiarTabla(resultado))
	return true
end

function FootballService:_Acreditar(premiados, monto, resultado)
	if #premiados == 0 or monto <= 0 then
		return
	end
	local Economy = self:_Servicio("EconomyService")
	if not Economy or typeof(Economy.Acreditar) ~= "function" then
		self:_AvisarError("economia", "EconomyService no disponible; no se acreditó la recompensa del partido.")
		return
	end
	local detalle = string.format("Partido de fútbol A %d - %d B", resultado.Goles.A, resultado.Goles.B)
	for _, jugador in ipairs(premiados) do
		task.spawn(function()
			local ok, exito, saldo = pcall(Economy.Acreditar, Economy, jugador, monto, "Partido", detalle)
			if not ok then
				self:_AvisarError("acreditar", exito)
			elseif exito then
				self:_Notificar(jugador, string.format("+%s por jugar el partido.", Format.Moneda(monto)), "exito")
			elseif typeof(saldo) == "string" then
				self:_Notificar(jugador, "No se acreditó la recompensa del partido: " .. saldo, "aviso")
			end
		end)
	end
end

-- Cuenta atrás de inicio automático (sin árbitro conectado y con deporte permitido). true si hubo cambios.
function FootballService:_RevisarAutoInicio(ahora)
	if not self.AutoInicio or self.partido.Estado == "EnJuego" then
		if self.autoInicioClock then
			self.autoInicioClock = nil
			self.autoInicioServidor = nil
			return true
		end
		return false
	end
	local minimo = self.MinJugadoresPorEquipo
	local condiciones = contar(self.equipos.A) >= minimo and contar(self.equipos.B) >= minimo
		and ahora - self.finPartidoClock >= self.PausaTrasPartidoSeg
		and not self:_HayArbitroConectado() and self:_PermiteDeporte()
	if condiciones then
		if not self.autoInicioClock then
			self.autoInicioClock = ahora + self.AutoInicioSeg
			self.autoInicioServidor = servidorAhora() + self.AutoInicioSeg
			return true
		end
		if ahora >= self.autoInicioClock then
			self.autoInicioClock = nil
			self.autoInicioServidor = nil
			self:_IniciarPartido("Automatico", nil)
		end
		return false
	end
	if self.autoInicioClock then
		self.autoInicioClock = nil
		self.autoInicioServidor = nil
		return true
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Estado y envío a clientes
---------------------------------------------------------------------------------------------------

-- Estado público de la cancha (sin datos del jugador).
function FootballService:Estado()
	local p = self.partido
	local listaA = self:_ListaEquipo("A")
	local listaB = self:_ListaEquipo("B")
	return {
		Estado = p.Estado, -- "Libre" | "EnJuego" | "Terminado"
		PartidoId = p.Id,
		Marcador = { A = p.Goles.A, B = p.Goles.B },
		InicioServidor = p.InicioServidor,
		Duracion = p.Duracion,
		Restante = self:_Restante(),
		Origen = p.Origen,
		IniciadoPor = p.IniciadoPorNombre,
		Equipos = { A = listaA, B = listaB },
		Conteo = { A = #listaA, B = #listaB },
		MaxPorEquipo = self.JugadoresPorEquipoMax,
		ArbitroConectado = self:_HayArbitroConectado(),
		PermiteDeporte = self:_PermiteDeporte(),
		InicioLibrePermitido = self.inicioLibreContrato,
		AutoInicio = self.AutoInicio,
		AutoInicioServidor = self.autoInicioServidor,
		UltimoResultado = copiarTabla(self.ultimoResultado),
		Activo = self.activo,
		ReinicioPendiente = self.reinicioPendiente,
		ZonaId = self.zonaId,
		DistanciaPatada = self.DistanciaPatada,
		CooldownPatada = self.CooldownPatada,
		HoraServidor = servidorAhora(),
	}
end

-- Estado para un jugador concreto: añade MiEquipo, EsArbitro y PuedeIniciar.
function FootballService:Snapshot(player)
	local estado = self:Estado()
	if esJugador(player) then
		estado.MiEquipo = self.equipoDe[player.UserId]
		estado.EsArbitro = self:_EsArbitro(player)
		estado.PuedeIniciar = self:_PuedeIniciar(player, estado.ArbitroConectado, estado.PermiteDeporte)
	end
	return estado
end

-- Jugadores en la cancha más los miembros de equipo (aunque estén fuera).
function FootballService:_Destinatarios()
	local lista = {}
	local vistos = {}
	local RemoteService = self:_Servicio("RemoteService")
	local enZona = nil
	if RemoteService and typeof(RemoteService.JugadoresEnZona) == "function" then
		local ok, resultado = pcall(RemoteService.JugadoresEnZona, RemoteService, self.zonaId)
		if ok and typeof(resultado) == "table" then
			enZona = resultado
		end
	end
	if not enZona then
		enZona = self:JugadoresEnCancha()
	end
	for _, player in ipairs(enZona) do
		if not vistos[player] then
			vistos[player] = true
			table.insert(lista, player)
		end
	end
	for uid in pairs(self.equipoDe) do
		local player = Players:GetPlayerByUserId(uid)
		if player and not vistos[player] then
			vistos[player] = true
			table.insert(lista, player)
		end
	end
	return lista
end

-- Agrupa varios cambios del mismo frame en un único envío de "Estado".
function FootballService:_EmitirEstado()
	if self.emisionPendiente then
		return
	end
	self.emisionPendiente = true
	task.defer(function()
		self.emisionPendiente = false
		local ok, err = pcall(function()
			local RemoteService = self:_Servicio("RemoteService")
			if not RemoteService or typeof(RemoteService.Enviar) ~= "function" then
				return
			end
			for _, player in ipairs(self:_Destinatarios()) do
				RemoteService:Enviar(player, "Futbol", { Sub = "Estado", Estado = self:Snapshot(player) })
			end
		end)
		if not ok then
			self:_AvisarError("estado", err)
		end
	end)
end

function FootballService:_EnviarEstadoA(player)
	local RemoteService = self:_Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" then
		pcall(RemoteService.Enviar, RemoteService, player, "Futbol", { Sub = "Estado", Estado = self:Snapshot(player) })
	end
end

-- Evento "Futbol" a los jugadores que están en la cancha.
function FootballService:_EnviarCancha(datos)
	local RemoteService = self:_Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.EnviarAZona) == "function" then
		pcall(RemoteService.EnviarAZona, RemoteService, self.zonaId, "Futbol", datos)
	end
end

---------------------------------------------------------------------------------------------------
-- Handlers de remotos
---------------------------------------------------------------------------------------------------

-- Rechazo lógico: estadísticas, auditoría (sin repeticiones) y respuesta { ok = false }.
function FootballService:_Rechazar(player, remoto, motivo, detalle, textoJugador)
	self.estadisticas.Rechazos = self.estadisticas.Rechazos + 1
	self.estadisticas.PorMotivo[motivo] = (self.estadisticas.PorMotivo[motivo] or 0) + 1
	self:_AuditarRechazo(player, remoto, motivo, detalle)
	return { ok = false, error = textoJugador or motivo, Codigo = motivo }
end

-- Aviso al jugador de una patada rechazada (como máximo cada AvisoRechazoSeg).
function FootballService:_AvisarPatada(player, motivo)
	local ahora = os.clock()
	local previo = self.ultimoAviso[player.UserId]
	if previo and ahora - previo < self.AvisoRechazoSeg then
		return
	end
	self.ultimoAviso[player.UserId] = ahora
	local RemoteService = self:_Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" then
		pcall(RemoteService.Enviar, RemoteService, player, "Futbol", {
			Sub = "PatadaRechazada", Motivo = motivo, Texto = TEXTOS_PATADA[motivo] or "Patada no válida.",
		})
	end
end

function FootballService:_RechazarPatada(player, motivo, detalle, sinAuditoria)
	if sinAuditoria then
		self.estadisticas.Rechazos = self.estadisticas.Rechazos + 1
		self.estadisticas.PorMotivo[motivo] = (self.estadisticas.PorMotivo[motivo] or 0) + 1
	else
		self:_Rechazar(player, REMOTO_PATADA, motivo, detalle)
	end
	self:_AvisarPatada(player, motivo)
	return { ok = false, error = motivo, Codigo = motivo }
end

-- Velocidad resultante: |v| = Fuerza × FuerzaMax con 0 <= v.Y <= FraccionVerticalMax × |v|.
function FootballService:_CalcularImpulso(direccion, fuerza, respaldoHorizontal)
	local magnitud = fuerza * self.FuerzaMax
	if magnitud <= 0 then
		return Vector3.zero
	end
	local v = direccion * magnitud
	local y = math.clamp(v.Y, 0, magnitud * self.FraccionVerticalMax)
	local horizontal = Vector3.new(v.X, 0, v.Z)
	local magnitudHorizontal = math.sqrt(math.max(magnitud * magnitud - y * y, 0))
	local sentido = nil
	if horizontal.Magnitude > 1e-3 then
		sentido = horizontal.Unit
	elseif respaldoHorizontal and respaldoHorizontal.Magnitude > 1e-3 then
		sentido = respaldoHorizontal.Unit
	else
		sentido = Vector3.new(1, 0, 0)
	end
	return sentido * magnitudHorizontal + Vector3.new(0, y, 0)
end

-- FootballKick { Direccion = Vector3 (unitario), Fuerza = 0..1 }.
function FootballService:_ManejarPatada(player, datos)
	local ahora = os.clock()
	local uid = player.UserId

	-- 1. Personaje vivo.
	local raiz = personajeVivo(player)
	if not raiz then
		return self:_RechazarPatada(player, "sin_personaje", nil, false)
	end

	-- 2. Balón disponible y sin saque pendiente.
	local balon = self.instancias.Balon
	if not valida(balon) then
		return self:_RechazarPatada(player, "sin_balon", nil, true)
	end
	if self.reinicioPendiente then
		return self:_RechazarPatada(player, "reinicio_tras_gol", nil, true)
	end

	-- 3. Cooldown por jugador.
	local ultima = self.ultimaPatada[uid]
	if ultima and ahora - ultima < self.CooldownPatada - self.ToleranciaCooldownSeg then
		return self:_RechazarPatada(player, "cooldown", string.format("%.2f s", ahora - ultima), false)
	end

	-- 4. Dirección (se normaliza; magnitud 0 o valores no finitos se rechazan).
	local direccion = datos.Direccion
	if not vectorFinito(direccion) or direccion.Magnitude < 1e-3 then
		return self:_RechazarPatada(player, "direccion_nula", nil, false)
	end
	direccion = direccion.Unit

	-- 5. Fuerza 0..1.
	local fuerza = datos.Fuerza
	if not esFinito(fuerza) or fuerza < 0 or fuerza > 1 then
		return self:_RechazarPatada(player, "fuerza", tostring(fuerza), false)
	end

	-- 6. Distancia HumanoidRootPart-balón (tolerancia por el movimiento del balón durante la latencia).
	local posicionBalon = balon.Position
	local posicionJugador = raiz.Position
	local distancia = (posicionJugador - posicionBalon).Magnitude
	local velocidadBalon = 0
	if not balon.Anchored then
		velocidadBalon = balon.AssemblyLinearVelocity.Magnitude
	end
	local tolerancia = self.ToleranciaDistanciaBase + math.min(velocidadBalon * self.LatenciaAsumidaSeg, self.ToleranciaDistanciaMax)
	if distancia > self.DistanciaPatada + tolerancia then
		return self:_RechazarPatada(player, "distancia", string.format("%.1f > %.1f", distancia, self.DistanciaPatada + tolerancia), false)
	end

	-- 7. Sentido: la patada no puede llevar el balón hacia el propio jugador.
	local haciaBalon = Vector3.new(posicionBalon.X - posicionJugador.X, 0, posicionBalon.Z - posicionJugador.Z)
	local direccionPlana = Vector3.new(direccion.X, 0, direccion.Z)
	if haciaBalon.Magnitude > 1 and direccionPlana.Magnitude > 1e-3 then
		if direccionPlana.Unit:Dot(haciaBalon.Unit) < self.ProductoSentidoMin then
			return self:_RechazarPatada(player, "sentido", nil, false)
		end
	end

	-- 8. Impulso.
	self.ultimaPatada[uid] = ahora
	if not self.activo then
		self:_Activar()
	end
	local velocidad = self:_CalcularImpulso(direccion, fuerza, haciaBalon)
	local okAplicar, errAplicar = pcall(function()
		if balon.Anchored then
			balon.Anchored = false
		end
		balon.AssemblyLinearVelocity = velocidad
	end)
	if not okAplicar then
		self:_AvisarError("patada", errAplicar)
		return { ok = false, error = "error_interno" }
	end
	self:_AsegurarPropietario(false)
	self.ultimoPateador = { UserId = uid, Equipo = self.equipoDe[uid], T = ahora }
	self.estadisticas.Patadas = self.estadisticas.Patadas + 1
	return { ok = true }
end

-- FootballAction { Accion, Equipo opc }.
function FootballService:_ManejarAccion(player, datos)
	local accion = datos.Accion
	if accion == "Estado" then
		return { ok = true, datos = self:Snapshot(player) }
	elseif accion == "Unirse" then
		return self:Unirse(player, datos.Equipo)
	elseif accion == "Salir" then
		return self:Salir(player)
	elseif accion == "Iniciar" then
		return self:Iniciar(player)
	elseif accion == "Reiniciar" then
		return self:Reiniciar(player)
	elseif accion == "Finalizar" then
		return self:Finalizar(player)
	end
	return self:_Rechazar(player, REMOTO_ACCION, "accion_desconocida", tostring(accion), "Acción no reconocida.")
end

---------------------------------------------------------------------------------------------------
-- Limpieza por jugador
---------------------------------------------------------------------------------------------------
function FootballService:_AlSalirJugador(player)
	local uid = player.UserId
	self.ultimaPatada[uid] = nil
	self.ultimoAviso[uid] = nil
	self.enCancha[player] = nil
	local prefijo = tostring(uid) .. "|"
	for clave in pairs(self.ultimaAuditoria) do
		if string.sub(clave, 1, #prefijo) == prefijo then
			self.ultimaAuditoria[clave] = nil
		end
	end
	if self.equipoDe[uid] then
		self:_QuitarDeEquipo(player, "desconexion", false)
	end
	self.fueraDesde[uid] = nil
	self.ingreso[uid] = nil
	if self.partido.Participacion then
		self.partido.Participacion[uid] = nil
	end
end

---------------------------------------------------------------------------------------------------
-- Consultas para otros servicios / paneles
---------------------------------------------------------------------------------------------------
function FootballService:Balon()
	return self.instancias.Balon
end

function FootballService:EnPartido()
	return self.partido.Estado == "EnJuego"
end

function FootballService:UltimoResultado()
	return copiarTabla(self.ultimoResultado)
end

function FootballService:ObtenerEstadisticas()
	local copia = copiarTabla(self.estadisticas)
	copia.Activo = self.activo
	copia.EnCancha = contar(self.enCancha)
	copia.EquipoA = contar(self.equipos.A)
	copia.EquipoB = contar(self.equipos.B)
	copia.Estado = self.partido.Estado
	return copia
end

return FootballService
