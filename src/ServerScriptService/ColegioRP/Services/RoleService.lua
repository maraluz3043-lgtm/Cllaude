--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.RoleService
	Tipo: ModuleScript
	Autoridad de cargos (docs/ARQUITECTURA.md §6): crea los Teams, guarda el cargo de cada jugador (atributos
	Cargo, Equipo y Salon en el Player), resuelve autorizaciones (lista, grupo, Adonis, Studio, cargos libres),
	aplica uniformes, atiende RequestRoleList / RequestJoinRole y la gestión de cargos por administradores.
]]

local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))

local RoleService = {}
RoleService.Nombre = "RoleService"

local PREFIJO = "[ColegioRP][RoleService]"
local AUT = Config.Autorizaciones or {}
local CARGO_DEFECTO = (Config.Spawns and Config.Spawns.CargoPorDefecto) or "Estudiante"
if not RoleDefinitions.Existe(CARGO_DEFECTO) then
	CARGO_DEFECTO = "Estudiante"
end

-- Segundos entre cambios de cargo pedidos por el mismo jugador (RequestJoinRole).
RoleService.CooldownCambioSeg = 5
-- Segundos entre acciones de gestión (asignar/revocar) del mismo administrador.
RoleService.CooldownAdminSeg = 5
-- Espera máxima del perfil al entrar antes de fijar el cargo inicial (no bloquea si falla).
RoleService.EsperaPerfilSeg = 15
-- Vigencia (s) de la caché del rango de grupo de cada jugador.
RoleService.CacheRangoSeg = 60

-- Textos legibles de los motivos de Autorizado (para la lista de cargos del menú).
RoleService.TextosMotivo = {
	libre = "Cargo libre",
	lista = "Autorizado por la dirección",
	grupo = "Rango suficiente en el grupo",
	adonis = "Administrador del servidor",
	studio = "Modo pruebas (Studio)",
	no_autorizado = "Requiere autorización de la dirección",
	cargo_invalido = "Cargo desconocido",
	jugador_invalido = "Jugador no válido",
}

-- Jerarquía para la gestión de cargos: nadie actúa sobre un cargo superior al suyo ni se asciende a sí mismo.
local NIVEL_POR_CARGO = { Director = 100, Subdirector = 90 }
local NIVEL_POR_EQUIPO = {
	["Equipo Directivo"] = 70,
	["Docentes"] = 40,
	["Bienestar"] = 40,
	["Administración"] = 40,
	["Servicios"] = 40,
	["Estudiantes"] = 10,
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function resolverJugador(player)
	if esJugador(player) then
		return player
	end
	if typeof(player) == "number" then
		return Players:GetPlayerByUserId(player)
	end
	return nil
end

local function nivel(cargo)
	if NIVEL_POR_CARGO[cargo] then
		return NIVEL_POR_CARGO[cargo]
	end
	local equipo = RoleDefinitions.Equipo(cargo)
	return NIVEL_POR_EQUIPO[equipo] or 0
end

local function enLista(lista, valor)
	if typeof(lista) ~= "table" then
		return false
	end
	for _, v in ipairs(lista) do
		if v == valor then
			return true
		end
	end
	return false
end

-- Llama servicio:metodo(...) en pcall si existe. Devuelve ok, resultado1, resultado2.
local function invocar(servicio, metodo, ...)
	if typeof(servicio) ~= "table" or typeof(servicio[metodo]) ~= "function" then
		return false, nil, nil
	end
	local resultado = table.pack(pcall(servicio[metodo], servicio, ...))
	if not resultado[1] then
		warn(PREFIJO .. " Error en " .. tostring(servicio.Nombre) .. ":" .. metodo .. "(): " .. tostring(resultado[2]))
		return false, nil, nil
	end
	return true, resultado[2], resultado[3]
end

local function esAulaValida(salon)
	return typeof(salon) == "string" and salon ~= "" and MapaLogico.Zonas[salon] ~= nil
end

local setCargosLibres = {}
for _, cargo in ipairs(AUT.CargosLibres or { "Estudiante" }) do
	setCargosLibres[cargo] = true
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function RoleService:Init(registro)
	self.registro = registro
	self.Cargos = {} -- userId -> cargoId (solo tras una asignación completa)
	self.UltimoCambio = {} -- userId -> os.clock() del último RequestJoinRole aceptado
	self.UltimaGestion = {} -- userId del administrador -> os.clock() de su última asignación/revocación
	self.CacheRango = {} -- userId -> { Rango, T }
	self.Equipos = {} -- nombre -> Team
	self.Maids = {} -- userId -> Maid con las conexiones del jugador
	self.CambiandoEquipo = {} -- userId -> true mientras RoleService cambia el Team (evita bucles)
	self.CargoCambiado = Signal.new() -- (player, cargoNuevo, cargoAnterior)
	self.Conexiones = {}
end

function RoleService:Start()
	self.AuditLog = self:Servicio("AuditLogService")

	local okEquipos, errEquipos = pcall(function()
		self:CrearEquipos()
	end)
	if not okEquipos then
		warn(PREFIJO .. " No se pudieron crear los equipos: " .. tostring(errEquipos))
	end

	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("RequestRoleList", function(player, datos)
			return self:ManejarLista(player, datos)
		end)
		RemoteService:Registrar("RequestJoinRole", function(player, datos)
			return self:ManejarUnirse(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: RequestRoleList y RequestJoinRole no tendrán handler.")
	end

	table.insert(self.Conexiones, Players.PlayerAdded:Connect(function(player)
		self:AlEntrar(player)
	end))
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self:AlSalir(player)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		self:AlEntrar(player)
	end
end

-- Servicio por nombre a través del registro (nil si no existe).
function RoleService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		return registro.Get(nombre)
	end
	return nil
end

function RoleService:Auditar(player, accion, detalle)
	if self.AuditLog and typeof(self.AuditLog.Registrar) == "function" then
		pcall(self.AuditLog.Registrar, self.AuditLog, "Cargo", player, accion, detalle)
	end
end

---------------------------------------------------------------------------------------------------
-- Equipos (Teams)
---------------------------------------------------------------------------------------------------
function RoleService:CrearEquipos()
	for _, nombre in ipairs(RoleDefinitions.OrdenEquipos) do
		local info = RoleDefinitions.Equipos[nombre]
		local equipo = Teams:FindFirstChild(nombre)
		if equipo and not equipo:IsA("Team") then
			warn(PREFIJO .. " Teams." .. nombre .. " existe pero no es un Team; se crea uno nuevo junto a él.")
			equipo = nil
		end
		if not equipo then
			equipo = Instance.new("Team")
			equipo.Name = nombre
			if info and info.Color then
				equipo.TeamColor = info.Color
			end
			equipo.AutoAssignable = false
			equipo.Parent = Teams
		else
			-- Equipo existente con el mismo nombre: se reutiliza (solo se desactiva la autoasignación).
			equipo.AutoAssignable = false
		end
		self.Equipos[nombre] = equipo
	end
end

-- Team del cargo (o nil).
function RoleService:TeamDe(cargo)
	local nombre = RoleDefinitions.Equipo(cargo)
	if not nombre then
		return nil
	end
	local equipo = self.Equipos[nombre]
	if equipo and equipo.Parent then
		return equipo
	end
	local existente = Teams:FindFirstChild(nombre)
	if existente and existente:IsA("Team") then
		self.Equipos[nombre] = existente
		return existente
	end
	return nil
end

function RoleService:FijarTeam(player, cargo)
	local equipo = self:TeamDe(cargo)
	if not equipo then
		return
	end
	local userId = player.UserId
	self.CambiandoEquipo[userId] = true
	local ok, err = pcall(function()
		player.Neutral = false
		player.Team = equipo
	end)
	self.CambiandoEquipo[userId] = nil
	if not ok then
		warn(PREFIJO .. " No se pudo fijar el equipo de " .. player.Name .. ": " .. tostring(err))
	end
end

---------------------------------------------------------------------------------------------------
-- Entrada y salida de jugadores
---------------------------------------------------------------------------------------------------
function RoleService:AlEntrar(player)
	if not esJugador(player) then
		return
	end
	local userId = player.UserId
	if self.Maids[userId] then
		self.Maids[userId]:DoCleaning()
	end
	local maid = Maid.new()
	self.Maids[userId] = maid

	-- Estado provisional inmediato (sin auditoría ni spawn): cargo por defecto y su equipo.
	pcall(function()
		player:SetAttribute("Cargo", CARGO_DEFECTO)
		player:SetAttribute("Equipo", RoleDefinitions.Equipo(CARGO_DEFECTO))
	end)
	self:FijarTeam(player, CARGO_DEFECTO)

	-- Uniforme tras cada reaparición (el cargo se conserva al morir).
	maid:GiveTask(player.CharacterAppearanceLoaded:Connect(function()
		self:AplicarUniforme(player)
	end))

	-- Si algo externo cambia el Team (p. ej. un SpawnLocation con AllowTeamChangeOnTouch), se restaura.
	maid:GiveTask(player:GetPropertyChangedSignal("Team"):Connect(function()
		if self.CambiandoEquipo[userId] then
			return
		end
		local esperado = self:TeamDe(self:Cargo(player))
		if esperado and player.Team ~= esperado and player.Parent then
			task.defer(function()
				if player.Parent and player.Team ~= esperado then
					self:FijarTeam(player, self:Cargo(player))
				end
			end)
		end
	end))

	-- Cargo inicial tras cargar el perfil (máx. EsperaPerfilSeg; si falla se continúa igualmente).
	maid:GiveTask(task.spawn(function()
		local DataService = self:Servicio("DataService")
		if DataService and typeof(DataService.EsperarPerfil) == "function" then
			local ok, err = pcall(DataService.EsperarPerfil, DataService, player, self.EsperaPerfilSeg)
			if not ok then
				warn(PREFIJO .. " EsperarPerfil falló para " .. player.Name .. ": " .. tostring(err))
			end
		end
		if player.Parent == nil or self.Maids[userId] ~= maid then
			return
		end
		-- Si el jugador ya eligió cargo mientras esperábamos, no se sobrescribe.
		if self.Cargos[userId] == nil then
			self:Asignar(player, CARGO_DEFECTO, "Entrada")
		end
	end))
end

function RoleService:AlSalir(player)
	local userId = player.UserId
	local maid = self.Maids[userId]
	if maid then
		self.Maids[userId] = nil
		maid:DoCleaning()
	end
	self.Cargos[userId] = nil
	self.UltimoCambio[userId] = nil
	self.UltimaGestion[userId] = nil
	self.CacheRango[userId] = nil
	self.CambiandoEquipo[userId] = nil
end

---------------------------------------------------------------------------------------------------
-- Consultas
---------------------------------------------------------------------------------------------------

-- Cargo actual del jugador (Player o userId). Por defecto Config.Spawns.CargoPorDefecto; nil si no es jugador.
function RoleService:Cargo(player)
	player = resolverJugador(player)
	if not player then
		return nil
	end
	local cargo = self.Cargos[player.UserId]
	if cargo then
		return cargo
	end
	local atributo = player:GetAttribute("Cargo")
	if RoleDefinitions.Existe(atributo) then
		return atributo
	end
	return CARGO_DEFECTO
end

-- ¿El cargo del jugador tiene el permiso?
function RoleService:Tiene(player, permiso)
	local cargo = self:Cargo(player)
	if not cargo then
		return false
	end
	return RoleDefinitions.Tiene(cargo, permiso)
end

-- ¿El jugador tiene un cargo docente (aula.docente)?
function RoleService:EsDocente(player)
	local cargo = self:Cargo(player)
	if not cargo then
		return false
	end
	return RoleDefinitions.EsDocente(cargo)
end

-- Nombre del equipo del jugador.
function RoleService:Equipo(player)
	local cargo = self:Cargo(player)
	if not cargo then
		return nil
	end
	return RoleDefinitions.Equipo(cargo)
end

-- Aula asignada (atributo Salon) o nil.
function RoleService:Salon(player)
	player = resolverJugador(player)
	if not player then
		return nil
	end
	local salon = player:GetAttribute("Salon")
	if typeof(salon) == "string" and salon ~= "" then
		return salon
	end
	return nil
end

-- Jugadores conectados cuyo cargo tiene el permiso.
function RoleService:ConPermiso(permiso)
	local lista = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if self:Tiene(player, permiso) then
			table.insert(lista, player)
		end
	end
	return lista
end

-- Jugadores conectados con un cargo concreto.
function RoleService:JugadoresConCargo(cargo)
	local lista = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if self:Cargo(player) == cargo then
			table.insert(lista, player)
		end
	end
	return lista
end

-- Lista ordenada de permisos del cargo (orden de RoleDefinitions.PermisosConocidos).
function RoleService:PermisosDe(cargo)
	local lista = {}
	for _, permiso in ipairs(RoleDefinitions.PermisosConocidos) do
		if RoleDefinitions.Tiene(cargo, permiso) then
			table.insert(lista, permiso)
		end
	end
	return lista
end

-- Datos públicos del rol del jugador (evento "Rol" y snapshot del cliente).
function RoleService:DatosRol(player)
	player = resolverJugador(player)
	if not player then
		return nil
	end
	local cargo = self:Cargo(player)
	local rol = RoleDefinitions.Obtener(cargo)
	return {
		Cargo = cargo,
		Nombre = rol and rol.Nombre or tostring(cargo),
		Abrev = rol and rol.Abrev or "?",
		Equipo = rol and rol.Equipo or nil,
		Descripcion = rol and rol.Descripcion or "",
		Salon = self:Salon(player),
		Permisos = self:PermisosDe(cargo),
		EsDocente = RoleDefinitions.EsDocente(cargo),
	}
end

RoleService.Snapshot = RoleService.DatosRol

---------------------------------------------------------------------------------------------------
-- Autorizaciones
---------------------------------------------------------------------------------------------------

-- Rango del jugador en Config.Autorizaciones.GrupoRoblox (caché de CacheRangoSeg). 0 si falla.
function RoleService:RangoGrupo(player)
	local grupo = AUT.GrupoRoblox or {}
	local groupId = tonumber(grupo.GroupId) or 0
	if groupId <= 0 then
		return 0
	end
	local userId = player.UserId
	local cache = self.CacheRango[userId]
	if cache and os.clock() - cache.T < self.CacheRangoSeg then
		return cache.Rango
	end
	local ok, rango = pcall(player.GetRankInGroup, player, groupId)
	if not ok or typeof(rango) ~= "number" then
		rango = 0
	end
	self.CacheRango[userId] = { Rango = rango, T = os.clock() }
	return rango
end

-- ¿Es administrador de Adonis? (solo lectura; nunca lanza)
local function esAdminAdonis(player)
	if AUT.UsarAdonis ~= true then
		return false
	end
	local ok, resultado = pcall(function()
		local adonis = _G.Adonis
		return adonis ~= nil and type(adonis) == "table" and type(adonis.CheckAdmin) == "function" and adonis.CheckAdmin(player) == true
	end)
	return ok and resultado == true
end

local function listaPorUserId(userId)
	local mapa = AUT.PorUserId
	if typeof(mapa) ~= "table" then
		return nil
	end
	local lista = mapa[userId]
	if lista == nil then
		lista = mapa[tostring(userId)]
	end
	if typeof(lista) == "string" then
		return { lista }
	end
	return lista
end

-- Núcleo de Autorizado con caché de contexto (Adonis y grupo se consultan una vez por lista).
function RoleService:AutorizadoCtx(player, cargo, ctx)
	if not esJugador(player) then
		return false, "jugador_invalido"
	end
	local rol = RoleDefinitions.Obtener(cargo)
	if not rol then
		return false, "cargo_invalido"
	end
	if setCargosLibres[cargo] or rol.RequiereAutorizacion == false then
		return true, "libre"
	end
	local lista = listaPorUserId(player.UserId)
	if lista and (enLista(lista, cargo) or enLista(lista, "*")) then
		return true, "lista"
	end
	local grupo = AUT.GrupoRoblox or {}
	local minimos = grupo.RangosMinimos or {}
	if (tonumber(grupo.GroupId) or 0) > 0 and typeof(minimos[cargo]) == "number" then
		local rango = ctx and ctx.Rango
		if rango == nil then
			rango = self:RangoGrupo(player)
			if ctx then
				ctx.Rango = rango
			end
		end
		if rango >= minimos[cargo] then
			return true, "grupo"
		end
	end
	local adonis = ctx and ctx.Adonis
	if adonis == nil then
		adonis = esAdminAdonis(player)
		if ctx then
			ctx.Adonis = adonis
		end
	end
	if adonis then
		return true, "adonis"
	end
	if AUT.ModoPruebasEnStudio == true and RunService:IsStudio() then
		return true, "studio"
	end
	return false, "no_autorizado"
end

-- ¿Puede el jugador tomar el cargo? Devuelve bool, motivo ("libre"|"lista"|"grupo"|"adonis"|"studio"|"no_autorizado"|...).
function RoleService:Autorizado(player, cargo)
	return self:AutorizadoCtx(player, cargo, {})
end

-- Ids de los cargos que el jugador puede tomar (orden de RoleDefinitions.Lista()) y mapa id -> motivo.
function RoleService:Disponibles(player)
	local ids = {}
	local motivos = {}
	local ctx = {}
	for _, rol in ipairs(RoleDefinitions.Lista()) do
		local ok, motivo = self:AutorizadoCtx(player, rol.Id, ctx)
		motivos[rol.Id] = motivo
		if ok then
			table.insert(ids, rol.Id)
		end
	end
	return ids, motivos
end

-- Lista de cargos para el menú: { {Id, Nombre, Abrev, Equipo, Descripcion, Disponible, Motivo, MotivoTexto} }.
function RoleService:ListaCargos(player)
	local lista = {}
	local ctx = {}
	for _, rol in ipairs(RoleDefinitions.Lista()) do
		local disponible, motivo = self:AutorizadoCtx(player, rol.Id, ctx)
		table.insert(lista, {
			Id = rol.Id,
			Nombre = rol.Nombre,
			Abrev = rol.Abrev,
			Equipo = rol.Equipo,
			Descripcion = rol.Descripcion,
			Disponible = disponible,
			Motivo = motivo,
			MotivoTexto = self.TextosMotivo[motivo] or motivo,
			RequiereAutorizacion = rol.RequiereAutorizacion == true,
			Color = rol.Color,
		})
	end
	return lista
end

---------------------------------------------------------------------------------------------------
-- Uniforme
---------------------------------------------------------------------------------------------------

-- Aplica Shirt/Pants del cargo si sus ids son > 0 (con 0 no se toca la ropa ni los accesorios).
function RoleService:AplicarUniforme(player, cargo)
	if not esJugador(player) then
		return false
	end
	local rol = RoleDefinitions.Obtener(cargo or self:Cargo(player))
	if not rol or typeof(rol.Uniforme) ~= "table" then
		return false
	end
	local camisa = tonumber(rol.Uniforme.Camisa) or 0
	local pantalon = tonumber(rol.Uniforme.Pantalon) or 0
	if camisa <= 0 and pantalon <= 0 then
		return false
	end
	local personaje = player.Character
	if not personaje or not personaje.Parent then
		return false
	end
	local ok, err = pcall(function()
		if camisa > 0 then
			local shirt = personaje:FindFirstChildOfClass("Shirt")
			if not shirt then
				shirt = Instance.new("Shirt")
				shirt.Name = "Shirt"
				shirt.Parent = personaje
			end
			shirt.ShirtTemplate = string.format("rbxassetid://%d", math.floor(camisa))
		end
		if pantalon > 0 then
			local pants = personaje:FindFirstChildOfClass("Pants")
			if not pants then
				pants = Instance.new("Pants")
				pants.Name = "Pants"
				pants.Parent = personaje
			end
			pants.PantsTemplate = string.format("rbxassetid://%d", math.floor(pantalon))
		end
	end)
	if not ok then
		warn(PREFIJO .. " No se pudo aplicar el uniforme a " .. player.Name .. ": " .. tostring(err))
		return false
	end
	return true
end

---------------------------------------------------------------------------------------------------
-- Aula (Salon)
---------------------------------------------------------------------------------------------------

-- Fija (o borra con nil) el aula del jugador y le reenvía su rol. Uso de SchoolDayService/StaffService.
function RoleService:FijarSalon(player, salon, sinAviso)
	player = resolverJugador(player)
	if not player then
		return false
	end
	if salon ~= nil and not esAulaValida(salon) then
		warn(PREFIJO .. " FijarSalon: aula desconocida '" .. tostring(salon) .. "'.")
		return false
	end
	pcall(function()
		player:SetAttribute("Salon", salon)
	end)
	if not sinAviso then
		self:EnviarRol(player)
	end
	return true
end

-- Interpreta el resultado de SchoolDayService:AsignarAula (string, tabla o ok, string).
local function aulaDeResultado(r1, r2)
	if esAulaValida(r1) then
		return r1
	end
	if typeof(r1) == "table" then
		local candidato = r1.RoomId or r1.Salon or r1.Aula or r1.Id
		if esAulaValida(candidato) then
			return candidato
		end
	end
	if r1 == true and esAulaValida(r2) then
		return r2
	end
	return nil
end

-- Resuelve el aula según el cargo nuevo: docentes piden aula; estudiantes la piden si no tienen; resto sin aula.
function RoleService:ResolverAula(player, cargo, anterior)
	local SchoolDayService = self:Servicio("SchoolDayService")
	local esDocente = RoleDefinitions.EsDocente(cargo)
	local eraDocente = anterior ~= nil and RoleDefinitions.EsDocente(anterior)
	local esEstudiante = cargo == "Estudiante"
	local eraEstudiante = anterior == "Estudiante"

	-- Al dejar un cargo con aula (o cambiar de tipo de aula) se libera la anterior.
	local cambiaTipo = (eraDocente and not esDocente) or (eraEstudiante and not esEstudiante)
	if cambiaTipo then
		invocar(SchoolDayService, "LiberarAula", player)
		pcall(function()
			player:SetAttribute("Salon", nil)
		end)
	end

	if not esDocente and not esEstudiante then
		pcall(function()
			player:SetAttribute("Salon", nil)
		end)
		return nil
	end

	local actual = self:Salon(player)
	if esDocente or not esAulaValida(actual) then
		local ok, r1, r2 = invocar(SchoolDayService, "AsignarAula", player, nil)
		if ok then
			local aula = aulaDeResultado(r1, r2)
			if aula then
				pcall(function()
					player:SetAttribute("Salon", aula)
				end)
			end
		end
	end
	local salon = self:Salon(player)
	if salon and not esAulaValida(salon) then
		pcall(function()
			player:SetAttribute("Salon", nil)
		end)
		salon = nil
	end
	return salon
end

---------------------------------------------------------------------------------------------------
-- Asignación
---------------------------------------------------------------------------------------------------

function RoleService:EnviarRol(player, extra)
	local RemoteService = self:Servicio("RemoteService")
	if not RemoteService or typeof(RemoteService.Enviar) ~= "function" then
		return false
	end
	local datos = self:DatosRol(player)
	if not datos then
		return false
	end
	if typeof(extra) == "table" then
		for clave, valor in pairs(extra) do
			datos[clave] = valor
		end
	end
	local ok = invocar(RemoteService, "Enviar", player, "Rol", datos)
	return ok
end

function RoleService:Notificar(player, titulo, texto, nivelAviso)
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService then
		invocar(RemoteService, "Enviar", player, "Notificacion", {
			Titulo = titulo, Texto = texto, Nivel = nivelAviso or "info", Tipo = nivelAviso or "info",
		})
	end
end

-- Zona de aparición del jugador según su cargo y aula (SpawnService si existe).
function RoleService:ZonaDe(player)
	local SpawnService = self:Servicio("SpawnService")
	local ok, zona = invocar(SpawnService, "ZonaPara", player)
	if ok and typeof(zona) == "string" then
		return zona
	end
	return RoleDefinitions.ZonaSpawnDe(self:Cargo(player), self:Salon(player))
end

-- Asigna el cargo al jugador. origen: texto para auditoría ("Entrada", "Menu", "Admin:<nombre>", ...).
-- opciones = { SinAparecer = bool, AsignadoPor = Player }. Devuelve true, info | false, motivo.
function RoleService:Asignar(player, cargo, origen, opciones)
	player = resolverJugador(player)
	if not player or player.Parent == nil then
		return false, "jugador_invalido"
	end
	if not RoleDefinitions.Existe(cargo) then
		return false, "cargo_invalido"
	end
	opciones = typeof(opciones) == "table" and opciones or {}
	origen = tostring(origen or "Sistema")
	local userId = player.UserId
	local anterior = self.Cargos[userId]
	local rol = RoleDefinitions.Obtener(cargo)

	-- 1. Estado en servidor y atributos replicados.
	self.Cargos[userId] = cargo
	pcall(function()
		player:SetAttribute("Cargo", cargo)
		player:SetAttribute("Equipo", rol.Equipo)
	end)

	-- 2. Team.
	self:FijarTeam(player, cargo)

	-- 3. Aula (docentes antes de aparecer, para que el spawn vaya a su aula).
	local salon = self:ResolverAula(player, cargo, anterior)

	-- 4. Uniforme sobre el personaje actual.
	self:AplicarUniforme(player, cargo)

	-- 5. Perfil: último cargo elegido (el cargo por defecto de la entrada no lo sobrescribe, así el menú
	-- puede proponer el último cargo del jugador).
	local DataService = self:Servicio("DataService")
	local okPerfil, perfil = invocar(DataService, "Obtener", player)
	if okPerfil and typeof(perfil) == "table" and origen ~= "Entrada" then
		if typeof(perfil.Progreso) ~= "table" then
			perfil.Progreso = {}
		end
		if perfil.Progreso.UltimoCargo ~= cargo then
			perfil.Progreso.UltimoCargo = cargo
			invocar(DataService, "Marcar", player)
		end
	end

	-- 6. Auditoría.
	self:Auditar(player, "Asignar", string.format("%s -> %s (%s)%s", tostring(anterior or "-"), cargo, origen,
		salon and (" · aula " .. salon) or ""))

	-- 7. Señal para otros servicios (ClassroomService cancela sesiones, SchoolDayService reparte aulas...).
	self.CargoCambiado:Fire(player, cargo, anterior)

	-- 8. Rol al cliente.
	local extra = { Origen = origen, Anterior = anterior }
	if esJugador(opciones.AsignadoPor) then
		extra.AsignadoPor = opciones.AsignadoPor.Name
	end
	self:EnviarRol(player, extra)

	-- 9. Aparición en la zona del cargo (no bloquea la respuesta).
	local SpawnService = self:Servicio("SpawnService")
	local omitir = opciones.SinAparecer == true
	if not omitir and origen == "Entrada" then
		-- Al entrar, si SpawnService ya colocó el personaje actual no se vuelve a mover.
		local ok, yaColocado = invocar(SpawnService, "YaColocado", player)
		omitir = ok and yaColocado == true
	end
	if not omitir and SpawnService and typeof(SpawnService.Aparecer) == "function" then
		task.spawn(function()
			invocar(SpawnService, "Aparecer", player)
		end)
	end

	return true, {
		Cargo = cargo,
		Equipo = rol.Equipo,
		Zona = self:ZonaDe(player),
		Salon = salon,
		Nombre = rol.Nombre,
	}
end

---------------------------------------------------------------------------------------------------
-- Gestión por administradores (ModerationService / StaffService)
---------------------------------------------------------------------------------------------------
function RoleService:EnCooldownGestion(admin)
	local ultimo = self.UltimaGestion[admin.UserId]
	if ultimo and os.clock() - ultimo < self.CooldownAdminSeg then
		return true, math.ceil(self.CooldownAdminSeg - (os.clock() - ultimo))
	end
	return false, 0
end

-- Asigna un cargo a otro jugador. Devuelve true, info | false, motivo.
function RoleService:AsignarPorAdmin(admin, objetivo, cargo)
	admin = resolverJugador(admin)
	objetivo = resolverJugador(objetivo)
	if not admin or not objetivo or objetivo.Parent == nil then
		return false, "jugador_invalido"
	end
	if not RoleDefinitions.Existe(cargo) then
		return false, "cargo_invalido"
	end
	local cargoAdmin = self:Cargo(admin)
	if not self:Tiene(admin, "cargos.asignar") then
		self:Auditar(admin, "AsignarDenegado", "sin permiso cargos.asignar · objetivo " .. objetivo.Name .. " -> " .. cargo)
		return false, "sin_permiso"
	end
	if not RoleDefinitions.PuedeAsignar(cargoAdmin, cargo) then
		self:Auditar(admin, "AsignarDenegado", cargoAdmin .. " no puede asignar " .. cargo)
		return false, "cargo_no_asignable"
	end
	if admin == objetivo then
		if nivel(cargo) > nivel(cargoAdmin) then
			self:Auditar(admin, "AsignarDenegado", "auto-ascenso a " .. cargo)
			return false, "auto_superior"
		end
	elseif nivel(self:Cargo(objetivo)) > nivel(cargoAdmin) then
		self:Auditar(admin, "AsignarDenegado", "objetivo con cargo superior: " .. objetivo.Name .. " (" .. tostring(self:Cargo(objetivo)) .. ")")
		return false, "objetivo_superior"
	end
	local enCooldown, restante = self:EnCooldownGestion(admin)
	if enCooldown then
		return false, "cooldown:" .. tostring(restante)
	end
	self.UltimaGestion[admin.UserId] = os.clock()

	local anterior = self:Cargo(objetivo)
	local ok, info = self:Asignar(objetivo, cargo, "Admin:" .. admin.Name, { AsignadoPor = admin })
	if not ok then
		return false, info
	end
	self:Auditar(admin, "AsignarPorAdmin", string.format("%s(%d): %s -> %s", objetivo.Name, objetivo.UserId, tostring(anterior), cargo))
	self:Notificar(objetivo, "Nuevo cargo", admin.Name .. " te asignó el cargo " .. RoleDefinitions.Nombre(cargo) .. ".", "info")
	return true, info
end

-- Revoca el cargo de un jugador (pasa a Config.Spawns.CargoPorDefecto). Devuelve true, info | false, motivo.
function RoleService:Revocar(admin, objetivo)
	admin = resolverJugador(admin)
	objetivo = resolverJugador(objetivo)
	if not admin or not objetivo or objetivo.Parent == nil then
		return false, "jugador_invalido"
	end
	local cargoAdmin = self:Cargo(admin)
	if not self:Tiene(admin, "cargos.revocar") then
		self:Auditar(admin, "RevocarDenegado", "sin permiso cargos.revocar · objetivo " .. objetivo.Name)
		return false, "sin_permiso"
	end
	local cargoObjetivo = self:Cargo(objetivo)
	if admin ~= objetivo and nivel(cargoObjetivo) > nivel(cargoAdmin) then
		self:Auditar(admin, "RevocarDenegado", "objetivo con cargo superior: " .. objetivo.Name .. " (" .. tostring(cargoObjetivo) .. ")")
		return false, "objetivo_superior"
	end
	if cargoObjetivo == CARGO_DEFECTO then
		return false, "sin_cargo"
	end
	local enCooldown, restante = self:EnCooldownGestion(admin)
	if enCooldown then
		return false, "cooldown:" .. tostring(restante)
	end
	self.UltimaGestion[admin.UserId] = os.clock()

	local ok, info = self:Asignar(objetivo, CARGO_DEFECTO, "Revocado:" .. admin.Name, { AsignadoPor = admin })
	if not ok then
		return false, info
	end
	self:Auditar(admin, "Revocar", string.format("%s(%d): %s -> %s", objetivo.Name, objetivo.UserId, tostring(cargoObjetivo), CARGO_DEFECTO))
	self:Notificar(objetivo, "Cargo revocado", admin.Name .. " revocó tu cargo de " .. RoleDefinitions.Nombre(cargoObjetivo)
		.. ". Ahora eres " .. RoleDefinitions.Nombre(CARGO_DEFECTO) .. ".", "aviso")
	return true, info
end

---------------------------------------------------------------------------------------------------
-- Handlers de remotos (RemoteService ya validó tabla, esquema, límite y permiso)
---------------------------------------------------------------------------------------------------
-- Último cargo elegido guardado en el perfil (Progreso.UltimoCargo) o nil.
function RoleService:UltimoCargo(player)
	local DataService = self:Servicio("DataService")
	local ok, perfil = invocar(DataService, "Obtener", player)
	if ok and typeof(perfil) == "table" and typeof(perfil.Progreso) == "table" and RoleDefinitions.Existe(perfil.Progreso.UltimoCargo) then
		return perfil.Progreso.UltimoCargo
	end
	return nil
end

function RoleService:ManejarLista(player, _datos)
	return RemoteContracts.Ok({
		Cargos = self:ListaCargos(player),
		Actual = self:Cargo(player),
		Salon = self:Salon(player),
		Ultimo = self:UltimoCargo(player),
	})
end

function RoleService:ManejarUnirse(player, datos)
	local cargo = datos.Cargo
	if not RoleDefinitions.Existe(cargo) then
		return RemoteContracts.Error("cargo_invalido")
	end
	local userId = player.UserId
	local ultimo = self.UltimoCambio[userId]
	if ultimo and os.clock() - ultimo < self.CooldownCambioSeg then
		local respuesta = RemoteContracts.Error("cooldown")
		respuesta.datos = { RestanteSeg = math.ceil(self.CooldownCambioSeg - (os.clock() - ultimo)) }
		return respuesta
	end
	local autorizado, motivo = self:Autorizado(player, cargo)
	if not autorizado then
		self:Auditar(player, "IntentoNoAutorizado", cargo .. " (" .. tostring(motivo) .. ")")
		local respuesta = RemoteContracts.Error(motivo or "no_autorizado")
		respuesta.datos = { Motivo = motivo, MotivoTexto = self.TextosMotivo[motivo] or motivo }
		return respuesta
	end
	self.UltimoCambio[userId] = os.clock()
	local ok, info = self:Asignar(player, cargo, "Menu (" .. tostring(motivo) .. ")")
	if not ok then
		return RemoteContracts.Error(info or "error")
	end
	return RemoteContracts.Ok(info)
end

return RoleService
