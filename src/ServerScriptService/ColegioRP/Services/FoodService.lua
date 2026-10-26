--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.FoodService
	Tipo: ModuleScript
	Comedor gratuito y cocina por pasos (docs/ARQUITECTURA.md §6, prueba P9). Lotes de raciones por jornada
	(Config.Comedor.RacionesPorLote x LotesPorJornada); reclamo gratuito (coste 0) con cooldown por jugador y solo
	en periodos ComidaGratis (o Config.Comedor.PermitirFueraDeHorario); cocina: receta activa de Catalogs.Recetas
	con sus Pasos en orden en las estaciones (Preparacion, Coccion, Emplatado), cada paso dura SegPorPaso y la
	receta terminada se entrega en la estación Entrega (añade sus raciones); Reposicion (comedor.reponer) añade un
	lote si quedan; NPC de servicio que repone al inicio de cada periodo ComidaGratis si no hay cocinero.
	Los ProximityPrompt (los de MapService o, si faltan, unos propios) se manejan aquí, en el servidor. Bandeja
	visual soldada a la mano durante 20 s. Handler del remoto FoodAction. Emite "Comida"
	{ Sub = "Estado" | "Paso" | "Reclamado" | "Lote" | "AbrirPanel" }.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Catalogs = require(Shared:WaitForChild("Catalogs"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))
local Zones = require(Util:WaitForChild("Zones"))
local Format = require(Util:WaitForChild("Format"))

local FoodService = {}
FoodService.Nombre = "FoodService"

local PREFIJO = "[ColegioRP][FoodService]"
local CFG = Config.Comedor or {}

FoodService.RacionesPorLote = math.max(1, math.floor(tonumber(CFG.RacionesPorLote) or 40))
FoodService.LotesPorJornada = math.max(1, math.floor(tonumber(CFG.LotesPorJornada) or 3))
FoodService.CooldownReclamo = math.max(0, tonumber(CFG.CooldownReclamo) or 120)
FoodService.DistanciaMax = 12 -- studs hasta la estación / ventana de servicio (FoodAction y prompts)
FoodService.Tolerancia = 2 -- latencia y tamaño del personaje
FoodService.DuracionBandeja = 20 -- segundos que el jugador sostiene la bandeja
FoodService.InactividadRecetaSeg = 180 -- una receta sin actividad durante este tiempo se cancela
FoodService.CooldownReponerSeg = 5 -- entre reposiciones manuales del mismo jugador
FoodService.IntervaloPromptSeg = 0.4 -- antirrebote de ProximityPrompt por jugador
FoodService.ZonaCocina = "COCINA"
FoodService.MaxHistorial = 60

-- Estaciones de cocina en orden y acción RP de su prompt (atributo RPAccion).
local ORDEN_ESTACIONES = { "Preparacion", "Coccion", "Emplatado", "Entrega", "Reposicion" }
local ACCION_RP = { Preparacion = "Paso", Coccion = "Paso", Emplatado = "Paso", Entrega = "Entregar", Reposicion = "Reponer" }
local TEXTO_ACCION = { Preparacion = "Preparar", Coccion = "Cocinar", Emplatado = "Emplatar", Entrega = "Entregar", Reposicion = "Reponer" }

local MENSAJES = {
	cerrado = "El comedor solo sirve almuerzo gratis en el descanso y el almuerzo (ahora: %s).",
	cooldown = "Ya recibiste tu almuerzo. Podrás reclamar otro en %s.",
	sin_raciones = "No quedan raciones. Espera a que la cocina prepare o reponga un lote.",
	lejos_reclamo = "Acércate a la ventana de servicio del comedor para reclamar tu almuerzo.",
	lejos_estacion = "Acércate a la estación: %s.",
	lejos_cocina = "Debes estar dentro de la cocina.",
	sin_personaje = "Tu personaje no está disponible en este momento.",
	permiso_cocina = "Solo el personal de cocina puede usar esta estación.",
	permiso_reponer = "Solo el personal autorizado puede reponer raciones.",
	sin_receta = "No hay ninguna receta en preparación. Elige una en el panel de cocina.",
	receta_en_curso = "Ya hay una receta en preparación: %s.",
	sin_lotes = "La cocina ya usó los %d lotes de esta jornada.",
	paso_incorrecto = "Paso incorrecto: ahora toca «%s».",
	paso_en_curso = "Espera a que termine el paso actual (%s).",
	receta_lista = "La receta ya está lista: llévala al mostrador de entrega.",
	receta_no_lista = "La receta aún no está lista para entregar.",
	receta_invalida = "Receta desconocida.",
	estacion_invalida = "Estación desconocida.",
	accion_invalida = "Acción no válida.",
	reponer_espera = "Espera unos segundos antes de volver a reponer.",
	reponer_lleno = "Todavía quedan %d raciones; repón cuando bajen de %d.",
	error_interno = "No se pudo completar la acción. Inténtalo de nuevo.",
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function posicionDe(player)
	if not esJugador(player) then
		return nil
	end
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart") or personaje.PrimaryPart
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Posición mundial de una instancia (BasePart, Attachment o Model) o nil.
local function posicionInstancia(instancia)
	if typeof(instancia) ~= "Instance" or instancia.Parent == nil then
		return nil
	end
	if instancia:IsA("BasePart") then
		return instancia.Position
	end
	if instancia:IsA("Attachment") then
		return instancia.WorldPosition
	end
	if instancia:IsA("Model") then
		local ok, pivote = pcall(function()
			return instancia:GetPivot()
		end)
		if ok then
			return pivote.Position
		end
	end
	return nil
end

local function ahoraServidor()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(t) == "number" then
		return t
	end
	return os.time()
end

local function nombreEstacion(nombre)
	return (Catalogs.Estaciones and Catalogs.Estaciones[nombre]) or tostring(nombre)
end

local function copiarArray(t)
	local copia = {}
	for i, v in ipairs(t or {}) do
		copia[i] = v
	end
	return copia
end

-- Devuelve false, codigo, mensaje formateado.
local function fallo(codigo, ...)
	local plantilla = MENSAJES[codigo] or MENSAJES.error_interno
	local ok, mensaje = pcall(string.format, plantilla, ...)
	if not ok then
		mensaje = plantilla
	end
	return false, codigo, mensaje
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function FoodService:Init(registro)
	self.registro = registro
	self.Raciones = 0
	self.LotesUsados = 0
	self.Receta = nil -- receta activa (ver IniciarReceta)
	self.TokenReceta = 0
	self.Menu = nil -- nombre del menú que se sirve
	self.IndiceMenu = 0
	self.Abierto = false
	self.EstadoJornada = nil
	self.UltimaNuevaJornada = -math.huge
	self.InicioJornadaLocal = os.clock()
	self.UltimoReclamo = {} -- userId -> os.clock() (se conserva aunque el jugador salga: evita reclamar al reconectar)
	self._ultimaPoda = os.clock() -- última limpieza de reclamos ya vencidos (evita que la tabla crezca sin límite)
	self.UltimoPrompt = {} -- userId -> os.clock()
	self.UltimaReposicion = {} -- userId -> os.clock()
	self.Bandejas = {} -- userId -> Model
	self.Puntos = { Estaciones = {}, Reclamo = nil }
	self.Historial = {}
	self.Estadisticas = { Reclamos = 0, LotesCocina = 0, LotesReposicion = 0, LotesNPC = 0, RacionesProducidas = 0, RecetasCanceladas = 0 }
	self.Cambiado = Signal.new() -- (snapshot)
	self.maidPrompts = Maid.new()
	self.Conexiones = {}
	self.Activo = true
	self._difusionPendiente = false
end

function FoodService:Start()
	local RemoteService = self:_S("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("FoodAction", function(player, datos)
			return self:ManejarAccion(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: FoodAction no tendrá handler.")
	end

	local okPrompts, errPrompts = pcall(self.EnlazarPrompts, self)
	if not okPrompts then
		warn(PREFIJO .. " No se pudieron enlazar los prompts de la cocina: " .. tostring(errPrompts))
	end
	local MapService = self:_S("MapService")
	if MapService and typeof(MapService.Construido) == "table" and typeof(MapService.Construido.Connect) == "function" then
		table.insert(self.Conexiones, MapService.Construido:Connect(function()
			task.defer(function()
				local ok, err = pcall(self.EnlazarPrompts, self)
				if not ok then
					warn(PREFIJO .. " Error al reenlazar los prompts: " .. tostring(err))
				end
			end)
		end))
	end

	local SchoolDay = self:_S("SchoolDayService")
	if SchoolDay then
		if typeof(SchoolDay.EstadoCambiado) == "table" and typeof(SchoolDay.EstadoCambiado.Connect) == "function" then
			table.insert(self.Conexiones, SchoolDay.EstadoCambiado:Connect(function()
				pcall(self._RevisarPeriodo, self)
			end))
		end
		if typeof(SchoolDay.JornadaTerminada) == "table" and typeof(SchoolDay.JornadaTerminada.Connect) == "function" then
			table.insert(self.Conexiones, SchoolDay.JornadaTerminada:Connect(function()
				pcall(self.NuevaJornada, self, "Fin de jornada")
			end))
		end
	end

	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		self.UltimoPrompt[userId] = nil
		self.UltimaReposicion[userId] = nil
		local bandeja = self.Bandejas[userId]
		self.Bandejas[userId] = nil
		if bandeja then
			pcall(function()
				bandeja:Destroy()
			end)
		end
	end))

	pcall(self._RevisarPeriodo, self)
	self:_ProgramarDifusion()

	task.spawn(function()
		while self.Activo do
			task.wait(1)
			local ok, err = pcall(self._Tick, self)
			if not ok then
				warn(PREFIJO .. " Error en el ciclo del comedor: " .. tostring(err))
			end
		end
	end)
end

function FoodService:_S(nombre)
	local registro = self.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, servicio = pcall(registro.Get, nombre)
	if ok and typeof(servicio) == "table" then
		return servicio
	end
	return nil
end

function FoodService:_Auditar(player, accion, detalle)
	local AuditLog = self:_S("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, "Economia", player, accion, detalle)
	end
end

function FoodService:_Enviar(player, tipo, datos)
	local RemoteService = self:_S("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" and esJugador(player) then
		pcall(RemoteService.Enviar, RemoteService, player, tipo, datos)
	end
end

function FoodService:_Notificar(player, texto, nivel, duracion)
	self:_Enviar(player, "Notificacion", { Texto = texto, Nivel = nivel or "info", Duracion = duracion or 5 })
end

function FoodService:_EnviarATodos(tipo, datos)
	local RemoteService = self:_S("RemoteService")
	if RemoteService and typeof(RemoteService.EnviarATodos) == "function" then
		pcall(RemoteService.EnviarATodos, RemoteService, tipo, datos)
	end
end

-- Envía a los jugadores dentro de la cocina y además a los indicados en 'extra' (array de Players).
function FoodService:_EnviarCocina(tipo, datos, extra)
	local RemoteService = self:_S("RemoteService")
	if not RemoteService then
		return
	end
	local lista = {}
	local vistos = {}
	if typeof(RemoteService.JugadoresEnZona) == "function" then
		local ok, enZona = pcall(RemoteService.JugadoresEnZona, RemoteService, self.ZonaCocina)
		if ok and typeof(enZona) == "table" then
			for _, player in ipairs(enZona) do
				vistos[player] = true
				table.insert(lista, player)
			end
		end
	end
	for _, player in ipairs(extra or {}) do
		if esJugador(player) and not vistos[player] then
			vistos[player] = true
			table.insert(lista, player)
		end
	end
	for _, player in ipairs(lista) do
		self:_Enviar(player, tipo, datos)
	end
end

function FoodService:_RegistrarHistorial(tipo, detalle)
	table.insert(self.Historial, { T = os.time(), Tipo = tipo, Detalle = detalle })
	while #self.Historial > self.MaxHistorial do
		table.remove(self.Historial, 1)
	end
end

function FoodService:_Tiene(player, permiso)
	local RoleService = self:_S("RoleService")
	if RoleService and typeof(RoleService.Tiene) == "function" then
		local ok, tiene = pcall(RoleService.Tiene, RoleService, player, permiso)
		return ok and tiene == true
	end
	return esJugador(player) and RoleDefinitions.Tiene(player:GetAttribute("Cargo"), permiso)
end

function FoodService:_HayCocinero()
	local RoleService = self:_S("RoleService")
	if RoleService and typeof(RoleService.ConPermiso) == "function" then
		local ok, lista = pcall(RoleService.ConPermiso, RoleService, "cocina.operar")
		if ok and typeof(lista) == "table" then
			return #lista > 0
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleDefinitions.Tiene(player:GetAttribute("Cargo"), "cocina.operar") then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Jornada y periodos
---------------------------------------------------------------------------------------------------
function FoodService:_HayJornada()
	local SchoolDay = self:_S("SchoolDayService")
	return SchoolDay ~= nil and typeof(SchoolDay.Estado) == "function"
end

function FoodService:_EstadoJornada()
	local SchoolDay = self:_S("SchoolDayService")
	if SchoolDay and typeof(SchoolDay.Estado) == "function" then
		local ok, estado = pcall(SchoolDay.Estado, SchoolDay)
		if ok and typeof(estado) == "string" then
			return estado
		end
	end
	return nil
end

function FoodService:_NombrePeriodo()
	local SchoolDay = self:_S("SchoolDayService")
	if SchoolDay and typeof(SchoolDay.Snapshot) == "function" then
		local ok, snap = pcall(SchoolDay.Snapshot, SchoolDay)
		if ok and typeof(snap) == "table" and typeof(snap.Nombre) == "string" then
			return snap.Nombre
		end
	end
	if self.EstadoJornada then
		return TimetableDefinitions.Nombre(self.EstadoJornada) or self.EstadoJornada
	end
	return "sin jornada"
end

-- ¿Se puede reclamar comida gratis ahora?
function FoodService:_CalcularAbierto(estado)
	if CFG.PermitirFueraDeHorario == true then
		return true
	end
	local SchoolDay = self:_S("SchoolDayService")
	if SchoolDay and typeof(SchoolDay.PermiteComidaGratis) == "function" then
		local ok, valor = pcall(SchoolDay.PermiteComidaGratis, SchoolDay)
		if ok then
			return valor == true
		end
	end
	if estado then
		return TimetableDefinitions.EsComidaGratis(estado) == true
	end
	-- Sin servicio de jornada el comedor no se bloquea por horario.
	return true
end

function FoodService:_RevisarPeriodo()
	local estado = self:_EstadoJornada()
	local abierto = self:_CalcularAbierto(estado)
	local cambio = false
	if estado ~= self.EstadoJornada then
		local anterior = self.EstadoJornada
		self.EstadoJornada = estado
		cambio = true
		if anterior ~= nil and estado == TimetableDefinitions.EstadoFinal then
			self:NuevaJornada("Reinicio de jornada")
		end
		if estado ~= nil and TimetableDefinitions.EsComidaGratis(estado) then
			self:_ServicioNPC("Inicio de " .. (TimetableDefinitions.Nombre(estado) or estado))
		end
	end
	if abierto ~= self.Abierto then
		self.Abierto = abierto
		cambio = true
	end
	if cambio then
		self:_ProgramarDifusion()
	end
end

-- NPC de servicio: si no hay cocinero conectado repone un lote al inicio de un periodo ComidaGratis.
function FoodService:_ServicioNPC(motivo)
	if CFG.NPCServicioSiNoHayCocinero == false then
		return false
	end
	if self:_HayCocinero() then
		return false
	end
	if self.Raciones >= self.RacionesPorLote then
		return false
	end
	local ok = self:_AgregarLote(self.RacionesPorLote, "NPC", nil, nil)
	if ok then
		self:_RegistrarHistorial("NPC", motivo or "Servicio automático")
	end
	return ok
end

function FoodService:_Tick()
	self:_RevisarPeriodo()
	-- Poda periódica de cooldowns vencidos (jugadores que ya se fueron incluidos).
	local ahora = os.clock()
	if ahora - self._ultimaPoda >= 60 then
		self._ultimaPoda = ahora
		for userId, instante in pairs(self.UltimoReclamo) do
			if ahora - instante >= self.CooldownReclamo then
				self.UltimoReclamo[userId] = nil
			end
		end
	end
	local receta = self.Receta
	if receta and not receta.PasoEnCurso and os.clock() - receta.UltimaActividad > self.InactividadRecetaSeg then
		self:_CancelarReceta("Receta abandonada por inactividad")
	end
	if not self:_HayJornada() then
		-- Sin SchoolDayService: los lotes se renuevan cada jornada teórica y el NPC atiende cuando se agotan.
		local total = tonumber(TimetableDefinitions.TotalJornadaSeg) or 1320
		if os.clock() - self.InicioJornadaLocal >= math.max(60, total) then
			self:NuevaJornada("Nueva jornada (sin servicio de jornada)")
		end
		if self.Raciones <= 0 then
			self:_ServicioNPC("Raciones agotadas")
		end
	end
end

-- Reinicia los lotes y las raciones de la jornada (fin de jornada / reinicio).
function FoodService:NuevaJornada(motivo)
	if os.clock() - self.UltimaNuevaJornada < 5 then
		return
	end
	self.UltimaNuevaJornada = os.clock()
	self.InicioJornadaLocal = os.clock()
	if self.Receta then
		self:_CancelarReceta("Fin de la jornada")
	end
	self.LotesUsados = 0
	self.Raciones = 0
	self.Menu = nil
	self:_RegistrarHistorial("Jornada", motivo or "Nueva jornada")
	self:_Auditar(nil, "ComedorNuevaJornada", motivo or "Nueva jornada")
	self:_ProgramarDifusion()
end

---------------------------------------------------------------------------------------------------
-- Lotes y raciones
---------------------------------------------------------------------------------------------------
function FoodService:_LotesRestantes()
	local reservado = 0
	if self.Receta then
		reservado = 1
	end
	return math.max(0, self.LotesPorJornada - self.LotesUsados - reservado)
end

function FoodService:_MaxRaciones()
	return self.RacionesPorLote * self.LotesPorJornada
end

-- Añade un lote. origen: "Cocina" (lote ya reservado por la receta), "Reposicion", "NPC" o "Admin" (sin límite).
function FoodService:_AgregarLote(cantidad, origen, menu, player)
	cantidad = tonumber(cantidad) or self.RacionesPorLote
	-- NaN / infinito (llamadas de otros servicios) se rechazan: math.min(max, NaN) llenaría el comedor.
	if cantidad ~= cantidad or cantidad == math.huge or cantidad == -math.huge then
		return false, "cantidad_invalida"
	end
	cantidad = math.floor(cantidad)
	if cantidad <= 0 then
		return false, "cantidad_invalida"
	end
	if origen ~= "Cocina" and origen ~= "Admin" and self:_LotesRestantes() <= 0 then
		return false, "sin_lotes"
	end
	if origen ~= "Admin" then
		self.LotesUsados = math.min(self.LotesPorJornada, self.LotesUsados + 1)
	end
	if not menu then
		local recetas = Catalogs.Recetas or {}
		if #recetas > 0 then
			self.IndiceMenu = (self.IndiceMenu % #recetas) + 1
			menu = recetas[self.IndiceMenu].Nombre
		else
			menu = "Menú del día"
		end
	end
	self.Menu = menu
	local anterior = self.Raciones
	self.Raciones = math.min(self:_MaxRaciones(), anterior + cantidad)
	-- Lo que realmente se añadió (el tope de la jornada recorta cantidades grandes).
	cantidad = math.max(0, self.Raciones - anterior)
	self.Estadisticas.RacionesProducidas = self.Estadisticas.RacionesProducidas + cantidad
	if origen == "Cocina" then
		self.Estadisticas.LotesCocina = self.Estadisticas.LotesCocina + 1
	elseif origen == "Reposicion" then
		self.Estadisticas.LotesReposicion = self.Estadisticas.LotesReposicion + 1
	elseif origen == "NPC" then
		self.Estadisticas.LotesNPC = self.Estadisticas.LotesNPC + 1
	end
	self:_RegistrarHistorial("Lote", origen .. ": +" .. cantidad .. " (" .. menu .. ")")
	self:_Auditar(player, "ComedorLote", origen .. " +" .. cantidad .. " raciones (" .. menu .. ") · lote " .. self.LotesUsados .. "/" .. self.LotesPorJornada)
	self:_EnviarATodos("Comida", {
		Sub = "Lote",
		Raciones = cantidad,
		RacionesDisponibles = self.Raciones,
		LoteActual = self.LotesUsados,
		LotesPorJornada = self.LotesPorJornada,
		Origen = origen,
		Menu = menu,
	})
	self:_ProgramarDifusion()
	return true, self.Raciones
end

-- API: añade 'cantidad' raciones (por defecto un lote) desde 'origen'. Devuelve ok, racionesOError.
function FoodService:Reponer(cantidad, origen)
	origen = tostring(origen or "Reposicion")
	if origen == "Cocina" then
		-- "Cocina" solo se usa con el lote reservado por una receta; desde fuera cuenta como reposición.
		origen = "Reposicion"
	end
	return self:_AgregarLote(cantidad or self.RacionesPorLote, origen, nil, nil)
end

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
function FoodService:_DatosReceta()
	local receta = self.Receta
	if not receta then
		return nil
	end
	local enCurso = nil
	if receta.PasoEnCurso then
		enCurso = {
			Estacion = receta.PasoEnCurso.Estacion,
			NombreEstacion = nombreEstacion(receta.PasoEnCurso.Estacion),
			FinServidor = receta.PasoEnCurso.FinServidor,
			Duracion = receta.PasoEnCurso.Duracion,
		}
	end
	return {
		Id = receta.Id,
		Nombre = receta.Nombre,
		Pasos = copiarArray(receta.Pasos),
		PasoActual = receta.Indice,
		Lista = receta.Lista,
		SegPorPaso = receta.SegPorPaso,
		Raciones = receta.Raciones,
		Cocinero = receta.CocineroNombre,
		PasoEnCurso = enCurso,
	}
end

function FoodService:_PasoEsperado()
	local receta = self.Receta
	if not receta then
		return nil
	end
	if receta.Lista then
		return "Entrega"
	end
	return receta.Pasos[receta.Indice]
end

-- Estado público del comedor (también en Snapshot y en el evento "Comida" Sub = "Estado").
function FoodService:Estado()
	local receta = self.Receta
	local npc = CFG.NPCServicioSiNoHayCocinero ~= false and not self:_HayCocinero()
	return {
		RacionesDisponibles = self.Raciones,
		LoteActual = self.LotesUsados,
		LotesPorJornada = self.LotesPorJornada,
		LotesRestantes = self:_LotesRestantes(),
		RacionesPorLote = self.RacionesPorLote,
		RecetaActiva = receta and receta.Id or nil,
		Receta = self:_DatosReceta(),
		PasoActual = receta and receta.Indice or 0,
		PasoEsperado = self:_PasoEsperado(),
		Cocinero = receta and receta.CocineroNombre or nil,
		Abierto = self.Abierto,
		EstadoJornada = self.EstadoJornada,
		Periodo = self:_NombrePeriodo(),
		Menu = self.Menu,
		ModoNPC = npc,
		CooldownReclamo = self.CooldownReclamo,
		HoraServidor = ahoraServidor(),
	}
end

function FoodService:Snapshot()
	local datos = self:Estado()
	datos.Estadisticas = {
		Reclamos = self.Estadisticas.Reclamos,
		LotesCocina = self.Estadisticas.LotesCocina,
		LotesReposicion = self.Estadisticas.LotesReposicion,
		LotesNPC = self.Estadisticas.LotesNPC,
		RacionesProducidas = self.Estadisticas.RacionesProducidas,
		RecetasCanceladas = self.Estadisticas.RecetasCanceladas,
	}
	return datos
end

-- Historial de eventos del comedor (copia, el más reciente primero).
function FoodService:HistorialEventos(n)
	local lista = {}
	local limite = math.floor(tonumber(n) or #self.Historial)
	for i = #self.Historial, 1, -1 do
		if #lista >= limite then
			break
		end
		local e = self.Historial[i]
		table.insert(lista, { T = e.T, Tipo = e.Tipo, Detalle = e.Detalle })
	end
	return lista
end

-- Segundos que faltan para que el jugador pueda volver a reclamar (0 = ya puede).
function FoodService:CooldownRestante(player)
	if not esJugador(player) then
		return 0
	end
	local ultimo = self.UltimoReclamo[player.UserId]
	if not ultimo then
		return 0
	end
	return math.max(0, self.CooldownReclamo - (os.clock() - ultimo))
end

-- Estado + datos personales del jugador (respuesta de FoodAction).
function FoodService:_DatosJugador(player)
	local datos = self:Estado()
	local restante = self:CooldownRestante(player)
	local puede, codigo = self:PuedeReclamar(player)
	local proximo = 0
	if restante > 0 then
		proximo = ahoraServidor() + restante
	end
	datos.Personal = {
		CooldownRestante = math.ceil(restante),
		ProximoReclamo = proximo,
		PuedeReclamar = puede,
		Motivo = codigo,
		EsCocina = self:_Tiene(player, "cocina.operar"),
		PuedeReponer = self:_Tiene(player, "comedor.reponer"),
	}
	return datos
end

function FoodService:_ProgramarDifusion()
	if self._difusionPendiente then
		return
	end
	self._difusionPendiente = true
	task.delay(0.5, function()
		self._difusionPendiente = false
		local ok, err = pcall(self._Difundir, self)
		if not ok then
			warn(PREFIJO .. " Error al difundir el estado: " .. tostring(err))
		end
	end)
end

function FoodService:_Difundir()
	local datos = self:Estado()
	datos.Sub = "Estado"
	self:_EnviarATodos("Comida", datos)
	self:_ActualizarPrompts()
	self.Cambiado:Fire(self:Estado())
end

---------------------------------------------------------------------------------------------------
-- Distancias
---------------------------------------------------------------------------------------------------
function FoodService:_PosicionEstacion(nombre)
	local punto = self.Puntos.Estaciones[nombre]
	local enMapa = punto and posicionInstancia(punto.Parte)
	if enMapa then
		return enMapa
	end
	local zona = MapaLogico.Zonas[self.ZonaCocina]
	if zona and typeof(zona.Estaciones) == "table" and typeof(zona.Estaciones[nombre]) == "Vector3" then
		return zona.Estaciones[nombre]
	end
	return nil
end

-- ¿El jugador está a <= DistanciaMax de la estación? Si la estación no tiene posición, basta con estar en la cocina.
function FoodService:_CercaDeEstacion(player, nombre, extra)
	local pos = posicionDe(player)
	if not pos then
		return false, "sin_personaje"
	end
	local objetivo = self:_PosicionEstacion(nombre)
	if not objetivo then
		if Zones.Contiene(self.ZonaCocina, pos) then
			return true
		end
		return false, "lejos_cocina"
	end
	local limite = self.DistanciaMax + self.Tolerancia + (extra or 0)
	if (pos - objetivo).Magnitude <= limite then
		return true
	end
	return false, "lejos_estacion"
end

function FoodService:_PosicionReclamo()
	local reclamo = self.Puntos.Reclamo
	local enMapa = reclamo and posicionInstancia(reclamo.Parte)
	if enMapa then
		return enMapa
	end
	local zona = MapaLogico.Zonas[self.ZonaCocina]
	if zona then
		if typeof(zona.FilaEstudiantes) == "table" and typeof(zona.FilaEstudiantes.Centro) == "Vector3" then
			return zona.FilaEstudiantes.Centro
		end
		if typeof(zona.Mostrador) == "table" and typeof(zona.Mostrador.Centro) == "Vector3" then
			return zona.Mostrador.Centro
		end
	end
	return nil
end

-- ¿Está en la fila / ventana de servicio? (a <= DistanciaMax del punto de reclamo o dentro de la caja de la fila)
function FoodService:_CercaDeReclamo(pos)
	if typeof(pos) ~= "Vector3" then
		return false
	end
	local limite = self.DistanciaMax + self.Tolerancia
	local objetivo = self:_PosicionReclamo()
	if objetivo and (pos - objetivo).Magnitude <= limite then
		return true
	end
	local zona = MapaLogico.Zonas[self.ZonaCocina]
	local fila = zona and zona.FilaEstudiantes
	if typeof(fila) == "table" and typeof(fila.Centro) == "Vector3" and typeof(fila.Tamano) == "Vector3" then
		local d = pos - fila.Centro
		local m = self.Tolerancia
		if math.abs(d.X) <= fila.Tamano.X / 2 + m and math.abs(d.Y) <= fila.Tamano.Y / 2 + m and math.abs(d.Z) <= fila.Tamano.Z / 2 + m then
			return true
		end
	end
	local mostrador = zona and zona.Mostrador
	if typeof(mostrador) == "table" and typeof(mostrador.Centro) == "Vector3" and (pos - mostrador.Centro).Magnitude <= limite then
		return true
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Reclamo de almuerzo (gratis)
---------------------------------------------------------------------------------------------------

-- ¿Puede reclamar ahora (sin mirar la distancia)? Devuelve ok, codigo, mensaje, restante.
function FoodService:PuedeReclamar(player)
	if not self.Abierto then
		local ok, codigo, mensaje = fallo("cerrado", self:_NombrePeriodo())
		return ok, codigo, mensaje, 0
	end
	local restante = self:CooldownRestante(player)
	if restante > 0 then
		local ok, codigo, mensaje = fallo("cooldown", Format.Tiempo(restante))
		return ok, codigo, mensaje, restante
	end
	if self.Raciones <= 0 then
		local ok, codigo, mensaje = fallo("sin_raciones")
		return ok, codigo, mensaje, 0
	end
	return true, nil, nil, 0
end

-- Reclamo gratuito (coste 0). desdeRemoto = true audita los rechazos por distancia.
-- Devuelve ok, codigo, mensaje.
function FoodService:Reclamar(player, desdeRemoto)
	if not esJugador(player) then
		return fallo("sin_personaje")
	end
	local pos = posicionDe(player)
	if not pos then
		return fallo("sin_personaje")
	end
	if not self:_CercaDeReclamo(pos) then
		if desdeRemoto then
			self:_Auditar(player, "ComedorRechazo", "distancia al punto de reclamo")
		end
		return fallo("lejos_reclamo")
	end
	-- Por si el periodo acaba de cambiar y el ciclo aún no lo vio.
	self.Abierto = self:_CalcularAbierto(self:_EstadoJornada())
	local puede, codigo, mensaje = self:PuedeReclamar(player)
	if not puede then
		return false, codigo, mensaje
	end
	self.Raciones = self.Raciones - 1
	self.UltimoReclamo[player.UserId] = os.clock()
	self.Estadisticas.Reclamos = self.Estadisticas.Reclamos + 1
	local menu = self.Menu or "Menú del día"
	local okBandeja, errBandeja = pcall(self._EntregarBandeja, self, player)
	if not okBandeja then
		warn(PREFIJO .. " No se pudo crear la bandeja: " .. tostring(errBandeja))
	end
	self:_Enviar(player, "Comida", {
		Sub = "Reclamado",
		Menu = menu,
		RacionesDisponibles = self.Raciones,
		Cooldown = self.CooldownReclamo,
		ProximoReclamo = ahoraServidor() + self.CooldownReclamo,
		DuracionBandeja = self.DuracionBandeja,
	})
	self:_Notificar(player, "¡Buen provecho! Hoy hay: " .. menu .. ".", "exito", 5)
	self:_ProgramarDifusion()
	return true
end

-- Bandeja visual (Model "ColegioRP_Bandeja") soldada a la mano derecha durante DuracionBandeja s.
local function parteBandeja(nombre, tamano, color, material)
	local parte = Instance.new("Part")
	parte.Name = nombre
	parte.Size = tamano
	parte.Color = color
	parte.Material = material or Enum.Material.SmoothPlastic
	parte.Anchored = false
	parte.CanCollide = false
	parte.CanTouch = false
	parte.CanQuery = false
	parte.CastShadow = false
	parte.Massless = true
	parte.TopSurface = Enum.SurfaceType.Smooth
	parte.BottomSurface = Enum.SurfaceType.Smooth
	return parte
end

function FoodService:_EntregarBandeja(player)
	local personaje = player.Character
	if not personaje then
		return
	end
	local mano = personaje:FindFirstChild("RightHand") or personaje:FindFirstChild("Right Arm")
	if not mano or not mano:IsA("BasePart") then
		return
	end
	local userId = player.UserId
	local previa = self.Bandejas[userId]
	if previa then
		self.Bandejas[userId] = nil
		pcall(function()
			previa:Destroy()
		end)
	end

	local desplazamiento = CFrame.new(0, -0.15, -0.95)
	if mano.Name == "Right Arm" then
		desplazamiento = CFrame.new(0, -1.05, -0.9)
	end

	local modelo = Instance.new("Model")
	modelo.Name = "ColegioRP_Bandeja"
	local base = parteBandeja("Bandeja", Vector3.new(2, 0.14, 1.4), Color3.fromRGB(196, 30, 36), Enum.Material.SmoothPlastic)
	local cframeBase = mano.CFrame * desplazamiento
	base.CFrame = cframeBase
	base.Parent = modelo

	local plato = parteBandeja("Plato", Vector3.new(0.1, 1.1, 1.1), Color3.fromRGB(245, 245, 245), Enum.Material.SmoothPlastic)
	plato.Shape = Enum.PartType.Cylinder
	plato.CFrame = cframeBase * CFrame.new(-0.4, 0.12, 0) * CFrame.Angles(0, 0, math.rad(90))
	plato.Parent = modelo

	local comida = parteBandeja("Comida", Vector3.new(0.7, 0.22, 0.7), Color3.fromRGB(230, 180, 60), Enum.Material.Sand)
	comida.CFrame = cframeBase * CFrame.new(-0.4, 0.27, 0)
	comida.Parent = modelo

	local vaso = parteBandeja("Vaso", Vector3.new(0.5, 0.35, 0.35), Color3.fromRGB(246, 160, 40), Enum.Material.Glass)
	vaso.Shape = Enum.PartType.Cylinder
	vaso.Transparency = 0.2
	vaso.CFrame = cframeBase * CFrame.new(0.6, 0.32, 0.2) * CFrame.Angles(0, 0, math.rad(90))
	vaso.Parent = modelo

	for _, parte in ipairs({ plato, comida, vaso }) do
		local union = Instance.new("WeldConstraint")
		union.Part0 = base
		union.Part1 = parte
		union.Parent = base
	end
	local soldadura = Instance.new("Weld")
	soldadura.Name = "SoldaduraMano"
	soldadura.Part0 = mano
	soldadura.Part1 = base
	soldadura.C0 = desplazamiento
	soldadura.Parent = base

	modelo.PrimaryPart = base
	modelo:SetAttribute("ColegioRP", true)
	modelo.Parent = personaje
	self.Bandejas[userId] = modelo

	task.delay(self.DuracionBandeja, function()
		if self.Bandejas[userId] == modelo then
			self.Bandejas[userId] = nil
		end
		pcall(function()
			modelo:Destroy()
		end)
	end)
end

---------------------------------------------------------------------------------------------------
-- Cocina: recetas por pasos
---------------------------------------------------------------------------------------------------
function FoodService:_SiguienteReceta()
	local recetas = Catalogs.Recetas or {}
	if #recetas == 0 then
		return nil
	end
	return recetas[(self.IndiceMenu % #recetas) + 1]
end

-- Inicia una receta (cocina.operar). Devuelve ok, codigo, mensaje.
function FoodService:IniciarReceta(player, recetaId)
	if not self:_Tiene(player, "cocina.operar") then
		return fallo("permiso_cocina")
	end
	if self.Receta then
		return fallo("receta_en_curso", self.Receta.Nombre)
	end
	if self:_LotesRestantes() <= 0 then
		return fallo("sin_lotes", self.LotesPorJornada)
	end
	local receta = nil
	if recetaId ~= nil then
		receta = Catalogs.Receta(recetaId)
	else
		receta = self:_SiguienteReceta()
	end
	if not receta or typeof(receta.Pasos) ~= "table" or #receta.Pasos == 0 then
		return fallo("receta_invalida")
	end
	local pos = posicionDe(player)
	if not pos then
		return fallo("sin_personaje")
	end
	if not Zones.Contiene(self.ZonaCocina, pos) then
		local cerca = self:_CercaDeEstacion(player, receta.Pasos[1])
		if not cerca then
			return fallo("lejos_cocina")
		end
	end
	local pasos = {}
	for _, paso in ipairs(receta.Pasos) do
		if typeof(paso) == "string" and Catalogs.Estaciones and Catalogs.Estaciones[paso] then
			table.insert(pasos, paso)
		end
	end
	if #pasos == 0 then
		return fallo("receta_invalida")
	end
	self.TokenReceta = self.TokenReceta + 1
	self.Receta = {
		Token = self.TokenReceta,
		Id = receta.Id,
		Nombre = receta.Nombre or receta.Id,
		Pasos = pasos,
		Indice = 1,
		Lista = false,
		SegPorPaso = math.clamp(tonumber(receta.SegPorPaso) or 6, 1, 60),
		Raciones = math.max(1, math.floor(tonumber(receta.Raciones) or self.RacionesPorLote)),
		CocineroUserId = player.UserId,
		CocineroNombre = player.DisplayName,
		IniciadaEn = os.clock(),
		UltimaActividad = os.clock(),
		PasoEnCurso = nil,
	}
	self:_RegistrarHistorial("Receta", player.Name .. " inicia " .. self.Receta.Nombre)
	self:_Auditar(player, "RecetaIniciada", self.Receta.Nombre)
	self:_Notificar(player, "Receta iniciada: " .. self.Receta.Nombre .. ". Primer paso: " .. nombreEstacion(pasos[1]) .. ".", "info", 5)
	self:_ProgramarDifusion()
	return true
end

-- Ejecuta el paso de la estación indicada (debe ser el siguiente de la receta). Devuelve ok, codigo, mensaje.
function FoodService:Paso(player, estacion)
	if not self:_Tiene(player, "cocina.operar") then
		return fallo("permiso_cocina")
	end
	local receta = self.Receta
	if not receta then
		return fallo("sin_receta")
	end
	if receta.Lista then
		if estacion == nil or estacion == "Entrega" then
			return self:Entregar(player)
		end
		return fallo("receta_lista")
	end
	if receta.PasoEnCurso then
		return fallo("paso_en_curso", nombreEstacion(receta.PasoEnCurso.Estacion))
	end
	local esperado = receta.Pasos[receta.Indice]
	if estacion == nil then
		estacion = esperado
	end
	if typeof(estacion) ~= "string" or not (Catalogs.Estaciones and Catalogs.Estaciones[estacion]) then
		return fallo("estacion_invalida")
	end
	if estacion ~= esperado then
		return fallo("paso_incorrecto", nombreEstacion(esperado))
	end
	local cerca, codigo = self:_CercaDeEstacion(player, estacion)
	if not cerca then
		if codigo == "lejos_estacion" then
			return fallo("lejos_estacion", nombreEstacion(estacion))
		end
		return fallo(codigo or "lejos_cocina")
	end
	local duracion = receta.SegPorPaso
	receta.PasoEnCurso = {
		Estacion = estacion,
		UserId = player.UserId,
		Inicio = os.clock(),
		Duracion = duracion,
		FinServidor = ahoraServidor() + duracion,
	}
	receta.UltimaActividad = os.clock()
	self:_EnviarCocina("Comida", {
		Sub = "Paso",
		Fase = "Inicio",
		RecetaId = receta.Id,
		RecetaNombre = receta.Nombre,
		Estacion = estacion,
		NombreEstacion = nombreEstacion(estacion),
		Indice = receta.Indice,
		Total = #receta.Pasos,
		Duracion = duracion,
		FinServidor = receta.PasoEnCurso.FinServidor,
		Cocinero = player.DisplayName,
	}, { player })
	local token = receta.Token
	task.delay(duracion, function()
		local ok, err = pcall(self._TerminarPaso, self, token, estacion, player)
		if not ok then
			warn(PREFIJO .. " Error al terminar el paso: " .. tostring(err))
		end
	end)
	self:_ProgramarDifusion()
	return true
end

function FoodService:_TerminarPaso(token, estacion, player)
	local receta = self.Receta
	if not receta or receta.Token ~= token or not receta.PasoEnCurso or receta.PasoEnCurso.Estacion ~= estacion then
		return
	end
	receta.PasoEnCurso = nil
	receta.UltimaActividad = os.clock()
	local base = {
		Sub = "Paso",
		RecetaId = receta.Id,
		RecetaNombre = receta.Nombre,
		Estacion = estacion,
		NombreEstacion = nombreEstacion(estacion),
		Indice = receta.Indice,
		Total = #receta.Pasos,
	}
	-- El cocinero debe seguir junto a la estación y con su cargo para completar el paso.
	local sigue = player.Parent ~= nil and self:_Tiene(player, "cocina.operar") and self:_CercaDeEstacion(player, estacion, 4)
	if not sigue then
		base.Fase = "Cancelado"
		base.Motivo = "Te alejaste de la estación antes de terminar el paso."
		self:_EnviarCocina("Comida", base, { player })
		self:_ProgramarDifusion()
		return
	end
	base.Fase = "Completado"
	self:_EnviarCocina("Comida", base, { player })
	receta.Indice = receta.Indice + 1
	if receta.Indice > #receta.Pasos then
		if receta.Pasos[#receta.Pasos] == "Entrega" then
			self:_CompletarReceta(player)
			return
		end
		receta.Lista = true
		self:_Notificar(player, "¡" .. receta.Nombre .. " está lista! Llévala al " .. string.lower(nombreEstacion("Entrega")) .. ".", "exito", 6)
	end
	self:_ProgramarDifusion()
end

-- Entrega la receta terminada en el mostrador: añade sus raciones. Devuelve ok, codigo, mensaje.
function FoodService:Entregar(player)
	if not self:_Tiene(player, "cocina.operar") then
		return fallo("permiso_cocina")
	end
	local receta = self.Receta
	if not receta then
		return fallo("sin_receta")
	end
	if not receta.Lista then
		if receta.Pasos[receta.Indice] == "Entrega" then
			return self:Paso(player, "Entrega")
		end
		return fallo("receta_no_lista")
	end
	local cerca, codigo = self:_CercaDeEstacion(player, "Entrega")
	if not cerca then
		if codigo == "lejos_estacion" then
			return fallo("lejos_estacion", nombreEstacion("Entrega"))
		end
		return fallo(codigo or "lejos_cocina")
	end
	self:_CompletarReceta(player)
	return true
end

function FoodService:_CompletarReceta(player)
	local receta = self.Receta
	if not receta then
		return
	end
	self.Receta = nil
	local ok = self:_AgregarLote(receta.Raciones, "Cocina", receta.Nombre, player)
	if ok then
		self:_RegistrarHistorial("Receta", "Entregada: " .. receta.Nombre)
		if esJugador(player) then
			self:_Notificar(player, "Entregaste " .. receta.Nombre .. ": +" .. receta.Raciones .. " raciones en el comedor.", "exito", 5)
		end
	end
	self:_ProgramarDifusion()
end

function FoodService:_CancelarReceta(motivo)
	local receta = self.Receta
	if not receta then
		return
	end
	self.Receta = nil
	self.Estadisticas.RecetasCanceladas = self.Estadisticas.RecetasCanceladas + 1
	self:_RegistrarHistorial("Receta", "Cancelada: " .. receta.Nombre .. " (" .. tostring(motivo) .. ")")
	self:_Auditar(nil, "RecetaCancelada", receta.Nombre .. ": " .. tostring(motivo))
	local cocinero = Players:GetPlayerByUserId(receta.CocineroUserId)
	if cocinero then
		self:_Notificar(cocinero, "Se canceló la receta " .. receta.Nombre .. ": " .. tostring(motivo) .. ".", "aviso", 6)
	end
	self:_ProgramarDifusion()
end

-- Reposición manual desde los congeladores (comedor.reponer). Devuelve ok, codigo, mensaje.
function FoodService:ReponerPorJugador(player)
	if not self:_Tiene(player, "comedor.reponer") then
		return fallo("permiso_reponer")
	end
	local cerca, codigo = self:_CercaDeEstacion(player, "Reposicion")
	if not cerca then
		if codigo == "lejos_estacion" then
			return fallo("lejos_estacion", nombreEstacion("Reposicion"))
		end
		return fallo(codigo or "lejos_cocina")
	end
	local ultimo = self.UltimaReposicion[player.UserId]
	if ultimo and os.clock() - ultimo < self.CooldownReponerSeg then
		return fallo("reponer_espera")
	end
	if self.Raciones >= self.RacionesPorLote then
		return fallo("reponer_lleno", self.Raciones, self.RacionesPorLote)
	end
	if self:_LotesRestantes() <= 0 then
		return fallo("sin_lotes", self.LotesPorJornada)
	end
	self.UltimaReposicion[player.UserId] = os.clock()
	local ok = self:_AgregarLote(self.RacionesPorLote, "Reposicion", nil, player)
	if not ok then
		return fallo("sin_lotes", self.LotesPorJornada)
	end
	self:_Notificar(player, "Repusiste un lote: +" .. self.RacionesPorLote .. " raciones.", "exito", 5)
	return true
end

---------------------------------------------------------------------------------------------------
-- Remoto FoodAction
---------------------------------------------------------------------------------------------------
local CODIGOS_AUDITADOS = { lejos_estacion = true, lejos_cocina = true, lejos_reclamo = true, permiso_cocina = true, permiso_reponer = true, estacion_invalida = true, receta_invalida = true }

function FoodService:ManejarAccion(player, datos)
	local accion = datos.Accion
	if accion == "Estado" then
		return { ok = true, datos = self:_DatosJugador(player) }
	end
	local ok, codigo, mensaje = false, "accion_invalida", MENSAJES.accion_invalida
	if accion == "Reclamar" then
		ok, codigo, mensaje = self:Reclamar(player, true)
	elseif accion == "IniciarReceta" then
		ok, codigo, mensaje = self:IniciarReceta(player, datos.RecetaId)
	elseif accion == "Paso" then
		ok, codigo, mensaje = self:Paso(player, datos.Estacion)
	elseif accion == "Entregar" then
		ok, codigo, mensaje = self:Entregar(player)
	elseif accion == "Reponer" then
		ok, codigo, mensaje = self:ReponerPorJugador(player)
	end
	if ok then
		return { ok = true, datos = self:_DatosJugador(player) }
	end
	if CODIGOS_AUDITADOS[codigo] and accion ~= "Reclamar" then
		self:_Auditar(player, "FoodAction", tostring(accion) .. " rechazado: " .. tostring(codigo))
	end
	local respuesta = self:_DatosJugador(player)
	respuesta.Codigo = codigo
	return { ok = false, error = mensaje or MENSAJES.error_interno, datos = respuesta }
end

---------------------------------------------------------------------------------------------------
-- ProximityPrompts (manejados en el servidor)
---------------------------------------------------------------------------------------------------
function FoodService:_PromptPermitido(player)
	if not esJugador(player) then
		return false
	end
	local ahora = os.clock()
	local ultimo = self.UltimoPrompt[player.UserId]
	if ultimo and ahora - ultimo < self.IntervaloPromptSeg then
		return false
	end
	self.UltimoPrompt[player.UserId] = ahora
	return true
end

function FoodService:_AlActivarEstacion(player, nombre)
	if not self:_PromptPermitido(player) then
		return
	end
	local permiso = "cocina.operar"
	if nombre == "Reposicion" then
		permiso = "comedor.reponer"
	end
	if not self:_Tiene(player, permiso) then
		if nombre == "Reposicion" then
			self:_Notificar(player, MENSAJES.permiso_reponer, "aviso", 4)
		else
			self:_Notificar(player, MENSAJES.permiso_cocina, "aviso", 4)
		end
		return
	end
	local ok, codigo, mensaje = true, nil, nil
	if nombre == "Reposicion" then
		ok, codigo, mensaje = self:ReponerPorJugador(player)
	elseif not self.Receta then
		-- Sin receta activa: el cliente abre el panel de cocina para elegir una.
		self:_Enviar(player, "Comida", { Sub = "AbrirPanel", Seccion = "Cocina" })
		self:_Notificar(player, MENSAJES.sin_receta, "info", 5)
		return
	elseif nombre == "Entrega" then
		ok, codigo, mensaje = self:Entregar(player)
	else
		ok, codigo, mensaje = self:Paso(player, nombre)
		if ok then
			self:_Notificar(player, nombreEstacion(nombre) .. ": en curso…", "info", 3)
		end
	end
	if not ok and mensaje then
		self:_Notificar(player, mensaje, "aviso", 5)
	end
end

function FoodService:_AlActivarReclamo(player)
	if not self:_PromptPermitido(player) then
		return
	end
	local ok, _, mensaje = self:Reclamar(player, false)
	if not ok and mensaje then
		self:_Notificar(player, mensaje, "aviso", 5)
	end
end

-- Busca los prompts de la cocina creados por MapService. Devuelve { Estaciones = {nombre = {Parte, Prompt}}, Reclamo }.
function FoodService:_BuscarPrompts()
	local resultado = { Estaciones = {}, Reclamo = nil }
	local MapService = self:_S("MapService")
	if MapService and typeof(MapService.Cocina) == "function" then
		local ok, info = pcall(MapService.Cocina, MapService)
		if ok and typeof(info) == "table" then
			for nombre, prompt in pairs(info.Prompts or {}) do
				local parte = (info.Estaciones or {})[nombre]
				if typeof(prompt) == "Instance" and prompt.Parent ~= nil then
					resultado.Estaciones[nombre] = { Parte = parte or prompt.Parent, Prompt = prompt }
				end
			end
			if typeof(info.ReclamoPrompt) == "Instance" and info.ReclamoPrompt.Parent ~= nil then
				resultado.Reclamo = { Parte = info.Reclamo or info.ReclamoPrompt.Parent, Prompt = info.ReclamoPrompt }
			end
		end
	end
	-- Respaldo: búsqueda por atributos en Workspace.ColegioRP_Mapa.Cocina.
	if next(resultado.Estaciones) == nil or resultado.Reclamo == nil then
		local carpeta = nil
		if MapService and typeof(MapService.Carpeta) == "function" then
			local ok, valor = pcall(MapService.Carpeta, MapService, "Cocina")
			if ok and typeof(valor) == "Instance" then
				carpeta = valor
			end
		end
		if not carpeta then
			local raiz = workspace:FindFirstChild((Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa")
			carpeta = raiz and raiz:FindFirstChild("Cocina")
		end
		if carpeta then
			for _, d in ipairs(carpeta:GetDescendants()) do
				if d:IsA("ProximityPrompt") then
					local tipo = d:GetAttribute("RPTipo")
					if tipo == "Cocina" then
						local nombre = d:GetAttribute("RPId") or (d.Parent and d.Parent.Name)
						if typeof(nombre) == "string" and not resultado.Estaciones[nombre] then
							resultado.Estaciones[nombre] = { Parte = d.Parent, Prompt = d }
						end
					elseif tipo == "Comida" and d:GetAttribute("RPAccion") == "Reclamar" and not resultado.Reclamo then
						resultado.Reclamo = { Parte = d.Parent, Prompt = d }
					end
				end
			end
		end
	end
	return resultado
end

-- Carpeta donde crear prompts propios si el mapa no los tiene.
function FoodService:_CarpetaPropia()
	local MapService = self:_S("MapService")
	if MapService and typeof(MapService.Carpeta) == "function" then
		local ok, carpeta = pcall(MapService.Carpeta, MapService, "Cocina")
		if ok and typeof(carpeta) == "Instance" and carpeta.Parent ~= nil then
			return carpeta, false
		end
	end
	local carpeta = Instance.new("Folder")
	carpeta.Name = "ColegioRP_Comedor"
	carpeta.Parent = workspace
	self.maidPrompts:GiveTask(carpeta)
	return carpeta, true
end

local function nuevoMarcador(nombre, posicion, padre)
	local parte = Instance.new("Part")
	parte.Name = nombre
	parte.Size = Vector3.new(2, 2, 2)
	parte.CFrame = CFrame.new(posicion)
	parte.Anchored = true
	parte.CanCollide = false
	parte.CanQuery = false
	parte.CanTouch = false
	parte.CastShadow = false
	parte.Transparency = 1
	parte.Parent = padre
	return parte
end

local function nuevoPrompt(parte, accion, objeto, distancia, espera)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ColegioRP_Prompt"
	prompt.ActionText = accion
	prompt.ObjectText = objeto
	prompt.MaxActivationDistance = distancia
	prompt.HoldDuration = espera
	prompt.RequiresLineOfSight = false
	prompt.ClickablePrompt = true
	prompt.Parent = parte
	return prompt
end

-- Crea los prompts que falten en los puntos de MapaLogico.Zonas.COCINA.
function FoodService:_CrearFaltantes(puntos)
	local zona = MapaLogico.Zonas[self.ZonaCocina]
	if not zona then
		return
	end
	local carpeta = nil
	local function asegurarCarpeta()
		if not carpeta then
			carpeta = self:_CarpetaPropia()
		end
		return carpeta
	end
	if typeof(zona.Estaciones) == "table" then
		for _, nombre in ipairs(ORDEN_ESTACIONES) do
			local punto = zona.Estaciones[nombre]
			if typeof(punto) == "Vector3" and not puntos.Estaciones[nombre] then
				local parte = nuevoMarcador(nombre, punto, asegurarCarpeta())
				self.maidPrompts:GiveTask(parte)
				local prompt = nuevoPrompt(parte, TEXTO_ACCION[nombre] or "Usar", "Cocina", 8, 0.5)
				prompt:SetAttribute("RPTipo", "Cocina")
				prompt:SetAttribute("RPId", nombre)
				puntos.Estaciones[nombre] = { Parte = parte, Prompt = prompt }
			end
		end
	end
	if not puntos.Reclamo then
		local centro = self:_PosicionReclamo()
		if centro then
			local parte = nuevoMarcador("Reclamo", centro, asegurarCarpeta())
			self.maidPrompts:GiveTask(parte)
			local prompt = nuevoPrompt(parte, "Reclamar almuerzo", "Comedor", 12, 0.3)
			prompt:SetAttribute("RPTipo", "Comida")
			prompt:SetAttribute("RPAccion", "Reclamar")
			puntos.Reclamo = { Parte = parte, Prompt = prompt }
		end
	end
end

-- Enlaza (o reenlaza tras reconstruir el mapa) los Triggered de las estaciones y del punto de reclamo.
function FoodService:EnlazarPrompts()
	self.maidPrompts:DoCleaning()
	local puntos = self:_BuscarPrompts()
	self:_CrearFaltantes(puntos)
	self.Puntos = puntos
	for nombre, punto in pairs(puntos.Estaciones) do
		local prompt = punto.Prompt
		if prompt:GetAttribute("RPTipo") == nil then
			prompt:SetAttribute("RPTipo", "Cocina")
		end
		if prompt:GetAttribute("RPId") == nil then
			prompt:SetAttribute("RPId", nombre)
		end
		if prompt:GetAttribute("RPAccion") == nil then
			prompt:SetAttribute("RPAccion", ACCION_RP[nombre] or "Paso")
		end
		self.maidPrompts:GiveTask(prompt.Triggered:Connect(function(player)
			local ok, err = pcall(self._AlActivarEstacion, self, player, nombre)
			if not ok then
				warn(PREFIJO .. " Error en la estación " .. tostring(nombre) .. ": " .. tostring(err))
			end
		end))
	end
	if puntos.Reclamo then
		local prompt = puntos.Reclamo.Prompt
		prompt:SetAttribute("RPTipo", "Comida")
		prompt:SetAttribute("RPAccion", "Reclamar")
		if prompt:GetAttribute("RPId") == nil then
			prompt:SetAttribute("RPId", "Reclamo")
		end
		self.maidPrompts:GiveTask(prompt.Triggered:Connect(function(player)
			local ok, err = pcall(self._AlActivarReclamo, self, player)
			if not ok then
				warn(PREFIJO .. " Error en el reclamo: " .. tostring(err))
			end
		end))
	else
		warn(PREFIJO .. " Sin punto de reclamo de almuerzo (MapaLogico.Zonas.COCINA sin FilaEstudiantes ni Mostrador).")
	end
	self:_ActualizarPrompts()
end

-- Textos de los prompts según el estado (los ve todo el mundo; el cliente oculta las estaciones a quien no cocina).
function FoodService:_ActualizarPrompts()
	local reclamo = self.Puntos and self.Puntos.Reclamo
	if reclamo and reclamo.Prompt and reclamo.Prompt.Parent ~= nil then
		local texto = "Comedor · " .. Format.Plural(self.Raciones, "ración", "raciones")
		if not self.Abierto then
			texto = "Comedor cerrado"
		elseif self.Raciones <= 0 then
			texto = "Comedor · sin raciones"
		end
		pcall(function()
			reclamo.Prompt.ObjectText = texto
		end)
	end
	local esperado = self:_PasoEsperado()
	for nombre, punto in pairs((self.Puntos and self.Puntos.Estaciones) or {}) do
		if punto.Prompt and punto.Prompt.Parent ~= nil then
			local texto = "Cocina"
			if nombre == esperado then
				texto = "Cocina · siguiente paso"
			end
			pcall(function()
				punto.Prompt.ObjectText = texto
			end)
		end
	end
end

return FoodService
