--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.SpawnService
	Tipo: ModuleScript
	Aparición por cargo (docs/ARQUITECTURA.md §6): coloca el personaje en el punto de spawn de la zona del cargo
	(o de la zona indicada) con un CFrame seguro sobre el piso y mirando al centro de la zona; reaparece en la
	zona del cargo tras cada muerte y avisa si el punto es provisional. No modifica la geometría del mapa.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))
local Zones = require(Util:WaitForChild("Zones"))

local SpawnService = {}
SpawnService.Nombre = "SpawnService"

local PREFIJO = "[ColegioRP][SpawnService]"
local CFG = Config.Spawns or {}
local CARGO_DEFECTO = CFG.CargoPorDefecto or "Estudiante"
local ZONA_RESPALDO = CFG.ZonaRespaldo or "AUDITORIO"
local ALTURA_SOBRE_PISO = tonumber(CFG.AlturaSobrePiso) or 3.5
local NOMBRE_CARPETA_MAPA = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"

-- Espera máxima (s) del personaje cuando aún no existe.
SpawnService.EsperaPersonajeSeg = 10
-- Espera máxima (s) del HumanoidRootPart.
SpawnService.EsperaRaizSeg = 5
-- Desplazamiento máximo (studs) en X/Z, determinista por UserId, para no apilar jugadores.
SpawnService.DesplazamientoMax = 2
-- Segundos mínimos entre avisos de "punto provisional" para el mismo jugador y zona.
SpawnService.IntervaloAvisoProvisionalSeg = 60
-- Distancia (studs) del rayo hacia abajo para encontrar el piso real bajo el punto.
SpawnService.AlcanceRayoPiso = 10

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

-- Desplazamiento determinista por UserId (mismo jugador -> mismo desplazamiento).
local function desplazamientoDe(userId, maximo)
	local semilla = math.floor(math.abs(tonumber(userId) or 0)) % 2147483647
	local rng = Random.new(semilla + 7919)
	return Vector3.new(rng:NextNumber(-maximo, maximo), 0, rng:NextNumber(-maximo, maximo))
end

-- Convierte lo que devuelva MapService:PuntoSpawn en Vector3 (Vector3, CFrame, BasePart, Attachment o tabla).
local function aVector3(valor)
	local tipo = typeof(valor)
	if tipo == "Vector3" then
		return valor
	elseif tipo == "CFrame" then
		return valor.Position
	elseif tipo == "Instance" then
		if valor:IsA("BasePart") then
			return valor.Position
		elseif valor:IsA("Attachment") then
			return valor.WorldPosition
		end
	elseif tipo == "table" then
		if typeof(valor.Punto) == "Vector3" then
			return valor.Punto
		elseif typeof(valor.Posicion) == "Vector3" then
			return valor.Posicion
		end
	end
	return nil
end

local function zonaConSpawn(zonaId)
	local zona = MapaLogico.Zonas[zonaId]
	if zona and typeof(zona.Spawn) == "table" and typeof(zona.Spawn.Punto) == "Vector3" then
		return zona
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function SpawnService:Init(registro)
	self.registro = registro
	self.Maids = {} -- userId -> Maid (conexiones del jugador)
	self.Turnos = {} -- userId -> número de la última petición de aparición (la más nueva gana)
	self.UltimoPersonaje = {} -- userId -> personaje colocado por última vez
	self.AvisosProvisional = {} -- userId -> zonaId -> os.clock()
	self.Conexiones = {}
	self.Aparecido = Signal.new() -- (player, zonaId, posicion, estado)
	self.Estadisticas = { Apariciones = 0, Respaldos = 0, Fallos = 0, Provisionales = 0 }
end

function SpawnService:Start()
	self.AuditLog = self:Servicio("AuditLogService")

	if CFG.DesactivarSpawnOriginal == true then
		local ok, err = pcall(function()
			self:DesactivarSpawnOriginal()
		end)
		if not ok then
			warn(PREFIJO .. " No se pudo desactivar el SpawnLocation original: " .. tostring(err))
		end
	end

	table.insert(self.Conexiones, Players.PlayerAdded:Connect(function(player)
		self:ConectarJugador(player)
	end))
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self:DesconectarJugador(player)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		self:ConectarJugador(player)
	end
end

function SpawnService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		return registro.Get(nombre)
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- SpawnLocation original (solo si Config.Spawns.DesactivarSpawnOriginal = true)
---------------------------------------------------------------------------------------------------
function SpawnService:DesactivarSpawnOriginal()
	local original = Workspace:FindFirstChild("SpawnLocation")
	if not (original and original:IsA("SpawnLocation")) then
		original = nil
		for _, hijo in ipairs(Workspace:GetChildren()) do
			if hijo:IsA("SpawnLocation") then
				original = hijo
				break
			end
		end
	end
	if not original then
		warn(PREFIJO .. " DesactivarSpawnOriginal: no se encontró ningún SpawnLocation en Workspace.")
		return false
	end
	-- Se guardan los valores originales como atributos para que el desinstalador los restaure.
	if original:GetAttribute("ColegioRP_EnabledOriginal") == nil then
		original:SetAttribute("ColegioRP_EnabledOriginal", original.Enabled)
		original:SetAttribute("ColegioRP_TeamChangeOriginal", original.AllowTeamChangeOnTouch)
	end
	original.Enabled = false
	original.AllowTeamChangeOnTouch = false
	if self.AuditLog then
		self.AuditLog:Registrar("Sistema", nil, "SpawnOriginal", "SpawnLocation original desactivado: " .. original:GetFullName())
	end
	return true
end

---------------------------------------------------------------------------------------------------
-- Jugadores
---------------------------------------------------------------------------------------------------
function SpawnService:ConectarJugador(player)
	if not esJugador(player) then
		return
	end
	local userId = player.UserId
	if self.Maids[userId] then
		self.Maids[userId]:DoCleaning()
	end
	local maid = Maid.new()
	self.Maids[userId] = maid

	-- Cada reaparición (también tras morir) vuelve a la zona del cargo, que se conserva.
	maid:GiveTask(player.CharacterAdded:Connect(function(personaje)
		task.spawn(function()
			self:AlAparecerPersonaje(player, personaje)
		end)
	end))
	if player.Character and player.Character.Parent then
		local personaje = player.Character
		task.spawn(function()
			self:AlAparecerPersonaje(player, personaje)
		end)
	end
end

function SpawnService:DesconectarJugador(player)
	local userId = player.UserId
	local maid = self.Maids[userId]
	if maid then
		self.Maids[userId] = nil
		maid:DoCleaning()
	end
	self.Turnos[userId] = nil
	self.UltimoPersonaje[userId] = nil
	self.AvisosProvisional[userId] = nil
end

function SpawnService:AlAparecerPersonaje(player, personaje)
	local raiz = personaje:WaitForChild("HumanoidRootPart", self.EsperaRaizSeg)
	if not raiz or player.Character ~= personaje then
		return
	end
	-- Un fotograma para que el motor termine de colocar el personaje en el SpawnLocation.
	task.wait()
	if player.Parent == nil or player.Character ~= personaje then
		return
	end
	local ok, err = pcall(function()
		self:Aparecer(player)
	end)
	if not ok then
		warn(PREFIJO .. " Error al reaparecer a " .. player.Name .. ": " .. tostring(err))
	end
end

-- Espera al personaje (máx. EsperaPersonajeSeg) sin bucles: CharacterAdded o tiempo agotado.
function SpawnService:EsperarPersonaje(player)
	local personaje = player.Character
	if personaje and personaje.Parent then
		return personaje
	end
	local hilo = coroutine.running()
	local resuelto = false
	local conexion
	local function resolver(valor)
		if resuelto then
			return
		end
		resuelto = true
		if conexion then
			conexion:Disconnect()
		end
		task.spawn(hilo, valor)
	end
	conexion = player.CharacterAdded:Connect(function(nuevo)
		resolver(nuevo)
	end)
	task.delay(self.EsperaPersonajeSeg, function()
		resolver(nil)
	end)
	return coroutine.yield()
end

-- ¿El personaje actual del jugador ya fue colocado por SpawnService?
function SpawnService:YaColocado(player)
	if not esJugador(player) then
		return false
	end
	local personaje = player.Character
	return personaje ~= nil and self.UltimoPersonaje[player.UserId] == personaje
end

---------------------------------------------------------------------------------------------------
-- Resolución de zona y punto
---------------------------------------------------------------------------------------------------
function SpawnService:CargoDe(player)
	local RoleService = self:Servicio("RoleService")
	if RoleService and typeof(RoleService.Cargo) == "function" then
		local ok, cargo = pcall(RoleService.Cargo, RoleService, player)
		if ok and RoleDefinitions.Existe(cargo) then
			return cargo
		end
	end
	local atributo = player:GetAttribute("Cargo")
	if RoleDefinitions.Existe(atributo) then
		return atributo
	end
	return CARGO_DEFECTO
end

-- Zona por defecto del jugador según su cargo y su aula (atributo Salon).
function SpawnService:ZonaPorCargo(player)
	local cargo = self:CargoDe(player)
	local salon = player:GetAttribute("Salon")
	if typeof(salon) ~= "string" or MapaLogico.Zonas[salon] == nil then
		salon = nil
	end
	local zona = nil
	if cargo == "Estudiante" and typeof(CFG.ZonaEstudiantes) == "string" and CFG.ZonaEstudiantes ~= "" then
		zona = CFG.ZonaEstudiantes
	else
		zona = RoleDefinitions.ZonaSpawnDe(cargo, salon)
	end
	return zona, cargo, salon
end

-- Zona efectiva (con aula de respaldo y zona de respaldo aplicadas). Devuelve zonaId, usoRespaldo.
function SpawnService:ResolverZona(player, zonaId)
	local salon = player:GetAttribute("Salon")
	if typeof(salon) ~= "string" or MapaLogico.Zonas[salon] == nil then
		salon = nil
	end
	local zona = zonaId
	local pideAula = false
	if typeof(zona) ~= "string" or zona == "" then
		zona = self:ZonaPorCargo(player)
		local rol = RoleDefinitions.Obtener(self:CargoDe(player))
		pideAula = rol ~= nil and rol.ZonaSpawn == RoleDefinitions.ZonaSpawnAulaAsignada
	end
	if zona == RoleDefinitions.ZonaSpawnAulaAsignada then
		zona = salon or RoleDefinitions.AulaRespaldo
		pideAula = true
	end
	if zonaConSpawn(zona) then
		return zona, false
	end
	-- Aula inexistente o sin punto: si se pedía un aula se prueba el aula de respaldo.
	if pideAula and zona ~= RoleDefinitions.AulaRespaldo and zonaConSpawn(RoleDefinitions.AulaRespaldo) then
		return RoleDefinitions.AulaRespaldo, true
	end
	if zonaConSpawn(ZONA_RESPALDO) then
		return ZONA_RESPALDO, true
	end
	if MapaLogico.Zonas[zona] then
		return zona, true
	end
	if MapaLogico.Zonas[ZONA_RESPALDO] then
		return ZONA_RESPALDO, true
	end
	return nil, true
end

-- Zona de aparición del jugador (para respuestas a cliente: RequestJoinRole).
function SpawnService:ZonaPara(player, zonaId)
	if not esJugador(player) then
		return nil
	end
	local zona = self:ResolverZona(player, zonaId)
	return zona
end

-- Punto de spawn de la zona: MapService:PuntoSpawn(zona) o MapaLogico.Zonas[zona].Spawn.Punto.
-- Devuelve Vector3, estado ("confirmado" | "provisional" | "derivado").
function SpawnService:PuntoDe(zonaId)
	local zona = MapaLogico.Zonas[zonaId]
	local estadoLogico = nil
	if zona and typeof(zona.Spawn) == "table" then
		estadoLogico = zona.Spawn.Estado
	end
	local MapService = self:Servicio("MapService")
	if MapService and typeof(MapService.PuntoSpawn) == "function" then
		local ok, valor, estado = pcall(MapService.PuntoSpawn, MapService, zonaId)
		if ok then
			local punto = aVector3(valor)
			if punto then
				if typeof(estado) ~= "string" then
					estado = estadoLogico
					if estado == nil and typeof(valor) == "table" then
						estado = valor.Estado
					end
				end
				return punto, estado or "confirmado"
			end
		else
			warn(PREFIJO .. " MapService:PuntoSpawn(" .. tostring(zonaId) .. ") falló: " .. tostring(valor))
		end
	end
	if zona and typeof(zona.Spawn) == "table" and typeof(zona.Spawn.Punto) == "Vector3" then
		return zona.Spawn.Punto, estadoLogico or "confirmado"
	end
	local punto, estado = Zones.PuntoSpawn(zonaId)
	return punto, estado
end

-- Altura extra sobre el punto para dejar el HumanoidRootPart a AlturaSobrePiso del piso real.
function SpawnService:AlturaExtra(punto, zona)
	local piso = (zona and MapaLogico.Pisos[zona.Piso]) or MapaLogico.Pisos[0] or { SueloY = 0 }
	local sueloY = piso.SueloY or 0
	local encontrado = false

	local excluir = {}
	local carpetaMapa = Workspace:FindFirstChild(NOMBRE_CARPETA_MAPA)
	if carpetaMapa then
		table.insert(excluir, carpetaMapa)
	end
	for _, otro in ipairs(Players:GetPlayers()) do
		if otro.Character then
			table.insert(excluir, otro.Character)
		end
	end
	local okRayo, resultado = pcall(function()
		local parametros = RaycastParams.new()
		parametros.FilterType = Enum.RaycastFilterType.Exclude
		parametros.FilterDescendantsInstances = excluir
		pcall(function()
			parametros.RespectCanCollide = true
		end)
		local origen = punto + Vector3.new(0, 2, 0)
		return Workspace:Raycast(origen, Vector3.new(0, -self.AlcanceRayoPiso, 0), parametros)
	end)
	if okRayo and resultado and resultado.Position.Y >= sueloY - 2 then
		sueloY = resultado.Position.Y
		encontrado = true
	end

	local extra = (sueloY + ALTURA_SOBRE_PISO) - punto.Y
	if not encontrado and extra < 0 then
		extra = 0
	end
	return extra
end

---------------------------------------------------------------------------------------------------
-- Aparición
---------------------------------------------------------------------------------------------------
function SpawnService:AvisarProvisional(player, zonaId)
	local userId = player.UserId
	local avisos = self.AvisosProvisional[userId]
	if not avisos then
		avisos = {}
		self.AvisosProvisional[userId] = avisos
	end
	local ultimo = avisos[zonaId]
	if ultimo and os.clock() - ultimo < self.IntervaloAvisoProvisionalSeg then
		return
	end
	avisos[zonaId] = os.clock()
	local zona = MapaLogico.Zonas[zonaId]
	local nombre = (zona and zona.Nombre) or tostring(zonaId)
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" then
		pcall(RemoteService.Enviar, RemoteService, player, "Notificacion", {
			Texto = "Punto de aparición provisional: " .. nombre,
			Nivel = "aviso",
			Tipo = "aviso",
			Zona = zonaId,
		})
	end
end

-- Coloca al jugador en el spawn de su cargo (o de zonaId). Devuelve true, zonaId, estado | false, motivo.
function SpawnService:Aparecer(player, zonaId)
	if not esJugador(player) or player.Parent == nil then
		return false, "jugador_invalido"
	end
	local userId = player.UserId
	local turno = (self.Turnos[userId] or 0) + 1
	self.Turnos[userId] = turno

	local personaje = self:EsperarPersonaje(player)
	if not personaje or self.Turnos[userId] ~= turno or player.Parent == nil then
		if not personaje then
			self.Estadisticas.Fallos = self.Estadisticas.Fallos + 1
			return false, "sin_personaje"
		end
		return false, "reemplazado"
	end
	local raiz = personaje:WaitForChild("HumanoidRootPart", self.EsperaRaizSeg)
	if not raiz or self.Turnos[userId] ~= turno or player.Character ~= personaje then
		if not raiz then
			self.Estadisticas.Fallos = self.Estadisticas.Fallos + 1
			return false, "sin_raiz"
		end
		return false, "reemplazado"
	end

	local zonaEfectiva, usoRespaldo = self:ResolverZona(player, zonaId)
	if not zonaEfectiva then
		self.Estadisticas.Fallos = self.Estadisticas.Fallos + 1
		warn(PREFIJO .. " No hay zona de aparición para " .. player.Name .. " (zona pedida: " .. tostring(zonaId) .. ").")
		return false, "sin_zona"
	end
	if usoRespaldo then
		self.Estadisticas.Respaldos = self.Estadisticas.Respaldos + 1
	end
	local zona = MapaLogico.Zonas[zonaEfectiva]
	local punto, estado = self:PuntoDe(zonaEfectiva)
	if typeof(punto) ~= "Vector3" then
		self.Estadisticas.Fallos = self.Estadisticas.Fallos + 1
		return false, "sin_punto"
	end

	local base = punto + desplazamientoDe(userId, self.DesplazamientoMax)
	local alturaExtra = self:AlturaExtra(base, zona)
	local posicion = base + Vector3.new(0, alturaExtra, 0)
	local cf = CFrame.new(posicion)
	if zona and typeof(zona.Centro) == "Vector3" then
		local mirar = Vector3.new(zona.Centro.X, posicion.Y, zona.Centro.Z)
		if (mirar - posicion).Magnitude > 0.5 then
			cf = CFrame.lookAt(posicion, mirar)
		end
	end

	local ok, err = pcall(function()
		-- Si está sentado, se suelta del asiento antes de moverlo (si no, el asiento lo retiene).
		local humanoide = personaje:FindFirstChildOfClass("Humanoid")
		if humanoide and humanoide.SeatPart then
			local soldadura = humanoide.SeatPart:FindFirstChild("SeatWeld")
			if soldadura then
				soldadura:Destroy()
			end
			humanoide.Sit = false
		end
		personaje:PivotTo(cf)
		raiz.AssemblyLinearVelocity = Vector3.zero
		raiz.AssemblyAngularVelocity = Vector3.zero
	end)
	if not ok then
		self.Estadisticas.Fallos = self.Estadisticas.Fallos + 1
		warn(PREFIJO .. " No se pudo colocar a " .. player.Name .. " en " .. zonaEfectiva .. ": " .. tostring(err))
		return false, "error_colocar"
	end

	self.UltimoPersonaje[userId] = personaje
	self.Estadisticas.Apariciones = self.Estadisticas.Apariciones + 1
	if estado == "provisional" then
		self.Estadisticas.Provisionales = self.Estadisticas.Provisionales + 1
		self:AvisarProvisional(player, zonaEfectiva)
	end
	self.Aparecido:Fire(player, zonaEfectiva, posicion, estado)
	return true, zonaEfectiva, estado
end

-- Resumen para MetricsService / panel de dirección.
function SpawnService:ObtenerEstadisticas()
	return {
		Apariciones = self.Estadisticas.Apariciones,
		Respaldos = self.Estadisticas.Respaldos,
		Fallos = self.Estadisticas.Fallos,
		Provisionales = self.Estadisticas.Provisionales,
	}
end

return SpawnService
