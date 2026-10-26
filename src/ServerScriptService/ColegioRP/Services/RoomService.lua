--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.RoomService
	Tipo: ModuleScript
	Ocupación de las aulas (docs/ARQUITECTURA.md §6, prueba P5): escucha Seat.Occupant de todos los asientos
	reales de cada aula (MapService:Aulas(), incluidos los duplicados), resuelve el Player desde el Humanoid,
	valida la pertenencia (docente de esa aula o atributo Salon == roomId; si no, avisa sin expulsar) y mantiene
	quién está sentado y quién de pie en cada aula. Cada jugador pertenece como máximo a UN aula a la vez
	(asiento > zona más pequeña que contiene su HumanoidRootPart), de modo que los envíos por aula nunca llegan
	a jugadores de otra aula (P4). Señal OcupacionCambiada(roomId) en cada cambio de asientos o de presencia.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))

local RoomService = {}
RoomService.Nombre = "RoomService"

local PREFIJO = "[ColegioRP][RoomService]"

---------------------------------------------------------------------------------------------------
-- Parámetros
---------------------------------------------------------------------------------------------------
RoomService.IntervaloPresenciaSeg = 2 -- Cada cuánto se recalcula quién está de pie en cada aula.
RoomService.CooldownAvisoAsientoSeg = 12 -- Segundos entre avisos de "asiento de otra aula" al mismo jugador.

local TAG_ASIENTO = (Config.Tags and Config.Tags.Asiento) or "ColegioRP_Asiento"

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

local function esAsiento(valor)
	return typeof(valor) == "Instance" and (valor:IsA("Seat") or valor:IsA("VehicleSeat"))
end

local function raizDe(player)
	local personaje = player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz
	end
	return nil
end

local function nombreAula(roomId)
	local zona = MapaLogico.Zonas[roomId]
	if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= "" then
		return zona.Nombre .. " (" .. tostring(roomId) .. ")"
	end
	return tostring(roomId)
end

local function copiarConjunto(conjunto)
	local copia = {}
	for clave, valor in pairs(conjunto) do
		copia[clave] = valor
	end
	return copia
end

local function conjuntosIguales(a, b)
	for clave in pairs(a) do
		if not b[clave] then
			return false
		end
	end
	for clave in pairs(b) do
		if not a[clave] then
			return false
		end
	end
	return true
end

local function ordenarIds(lista)
	table.sort(lista, function(x, y)
		return x < y
	end)
	return lista
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function RoomService:Init(registro)
	self.registro = registro
	self.OcupacionCambiada = Signal.new() -- (roomId)
	self.AsientoCambiado = Signal.new() -- (player, seat|nil, roomId|nil)
	self._infoSeat = {} -- Seat -> { RoomId, Canonico }
	self._ocupante = {} -- Seat -> userId sentado en ese Seat
	self._asientoDe = {} -- userId -> Seat que ocupa
	self._sentados = {} -- roomId -> { [userId] = Seat }
	self._presencia = {} -- roomId -> { [userId] = true } (último cálculo, incluye sentados)
	self._capacidad = {} -- roomId -> n
	self._ultimoAviso = {} -- userId -> os.clock() del último aviso de asiento ajeno
	self._maidAsientos = Maid.new()
	self._maidsJugador = {} -- userId -> Maid
	self.maid = Maid.new()
	self.activo = true
	for _, roomId in ipairs(MapaLogico.Aulas or {}) do
		self._sentados[roomId] = {}
		self._presencia[roomId] = {}
		self._capacidad[roomId] = 0
	end
end

function RoomService:Start()
	self:ConectarAsientos()

	-- Si MapService reconstruye el mapa, se vuelven a conectar los asientos.
	local MapService = self.registro.Get("MapService")
	if MapService and MapService.Construido and typeof(MapService.Construido.Connect) == "function" then
		self.maid:GiveTask(MapService.Construido:Connect(function()
			self:ConectarAsientos()
		end))
	end

	self.maid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:AlEntrar(player)
	end))
	self.maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:AlSalir(player)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		self:AlEntrar(player)
	end

	-- Presencia de pie: recálculo periódico de baja frecuencia (sin RenderStepped).
	self.maid:GiveTask(task.spawn(function()
		while self.activo do
			task.wait(self.IntervaloPresenciaSeg)
			local ok, err = pcall(self.RecalcularPresencia, self)
			if not ok then
				warn(PREFIJO .. " Error al recalcular la presencia: " .. tostring(err))
			end
		end
	end))

	local AuditLog = self.registro.Get("AuditLogService")
	if AuditLog then
		local total = 0
		for _ in pairs(self._infoSeat) do
			total = total + 1
		end
		AuditLog:Registrar("Sistema", nil, "Aulas", total .. " asientos de aula vigilados por RoomService")
	end
end

---------------------------------------------------------------------------------------------------
-- Asientos
---------------------------------------------------------------------------------------------------

-- Conecta Occupant en todos los asientos de aula (re-ejecutable: limpia las conexiones anteriores).
function RoomService:ConectarAsientos()
	self._maidAsientos:DoCleaning()
	self._infoSeat = {}
	self._ocupante = {}
	self._asientoDe = {}
	for roomId in pairs(self._sentados) do
		self._sentados[roomId] = {}
		self._capacidad[roomId] = 0
	end

	local MapService = self.registro.Get("MapService")
	local aulas = nil
	if MapService and typeof(MapService.Aulas) == "function" then
		local ok, resultado = pcall(MapService.Aulas, MapService)
		if ok and typeof(resultado) == "table" then
			aulas = resultado
		end
	end

	if aulas then
		for roomId, info in pairs(aulas) do
			if typeof(info) == "table" then
				if not self._sentados[roomId] then
					self._sentados[roomId] = {}
					self._presencia[roomId] = {}
				end
				local seats = info.Seats or {}
				self._capacidad[roomId] = #seats
				for _, seat in ipairs(seats) do
					self:RegistrarAsiento(seat, roomId, seat)
				end
				for _, par in ipairs(info.Duplicados or {}) do
					if typeof(par) == "table" then
						self:RegistrarAsiento(par.Seat, roomId, par.Canonico or par.Seat)
					end
				end
			end
		end
	else
		-- Respaldo sin MapService: Seats etiquetados con atributo RoomId.
		warn(PREFIJO .. " MapService no disponible; se usan los Seats con tag " .. TAG_ASIENTO .. ".")
		local ok, etiquetados = pcall(CollectionService.GetTagged, CollectionService, TAG_ASIENTO)
		if ok and typeof(etiquetados) == "table" then
			for _, seat in ipairs(etiquetados) do
				local roomId = esAsiento(seat) and seat:GetAttribute("RoomId") or nil
				if typeof(roomId) == "string" and Zones.EsAula(roomId) then
					self._capacidad[roomId] = (self._capacidad[roomId] or 0) + 1
					self:RegistrarAsiento(seat, roomId, seat)
				end
			end
		end
	end

	for roomId in pairs(self._sentados) do
		self.OcupacionCambiada:Fire(roomId)
	end
end

function RoomService:RegistrarAsiento(seat, roomId, canonico)
	if not esAsiento(seat) or self._infoSeat[seat] then
		return
	end
	self._infoSeat[seat] = { RoomId = roomId, Canonico = canonico or seat }
	local ok, conexion = pcall(function()
		return seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			self:AlCambiarOcupante(seat)
		end)
	end)
	if ok and conexion then
		self._maidAsientos:GiveTask(conexion)
	end
	-- Asiento ya ocupado al conectar (p. ej. tras reconstruir el mapa).
	if seat.Occupant ~= nil then
		self:AlCambiarOcupante(seat)
	end
end

-- Quita al jugador del asiento que tuviera registrado (sin disparar señales).
function RoomService:_Liberar(userId)
	local seat = self._asientoDe[userId]
	if not seat then
		return nil
	end
	self._asientoDe[userId] = nil
	if self._ocupante[seat] == userId then
		self._ocupante[seat] = nil
	end
	local info = self._infoSeat[seat]
	local roomId = info and info.RoomId or nil
	if roomId and self._sentados[roomId] and self._sentados[roomId][userId] == seat then
		self._sentados[roomId][userId] = nil
	end
	return roomId
end

function RoomService:AlCambiarOcupante(seat)
	local info = self._infoSeat[seat]
	if not info then
		return
	end
	local roomId = info.RoomId
	local afectadas = {}

	-- Ocupante anterior de este Seat.
	local anterior = self._ocupante[seat]
	if anterior then
		self._ocupante[seat] = nil
		if self._asientoDe[anterior] == seat then
			self._asientoDe[anterior] = nil
		end
		if self._sentados[roomId] then
			self._sentados[roomId][anterior] = nil
		end
		afectadas[roomId] = true
		local playerAnterior = Players:GetPlayerByUserId(anterior)
		if playerAnterior then
			self.AsientoCambiado:Fire(playerAnterior, nil, nil)
		end
	end

	-- Nuevo ocupante.
	local humanoid = seat.Occupant
	local player = nil
	if humanoid and humanoid.Parent then
		player = Players:GetPlayerFromCharacter(humanoid.Parent)
	end
	if player then
		local userId = player.UserId
		local previa = self:_Liberar(userId)
		if previa then
			afectadas[previa] = true
		end
		self._ocupante[seat] = userId
		self._asientoDe[userId] = seat
		if not self._sentados[roomId] then
			self._sentados[roomId] = {}
		end
		self._sentados[roomId][userId] = seat
		afectadas[roomId] = true
		self:ValidarPertenencia(player, roomId)
		self.AsientoCambiado:Fire(player, seat, roomId)
	end

	for id in pairs(afectadas) do
		self:_ActualizarPresenciaAula(id)
		self.OcupacionCambiada:Fire(id)
	end
end

-- ¿El jugador pertenece al aula del asiento? (docente de esa aula o Salon == roomId). Si no, solo se avisa.
function RoomService:Pertenece(player, roomId)
	local RoleService = self.registro.Get("RoleService")
	local salon = player:GetAttribute("Salon")
	if RoleService and typeof(RoleService.Salon) == "function" then
		local ok, valor = pcall(RoleService.Salon, RoleService, player)
		if ok and typeof(valor) == "string" then
			salon = valor
		end
	end
	if salon == roomId then
		return true
	end
	local ClassroomService = self.registro.Get("ClassroomService")
	if ClassroomService and typeof(ClassroomService.EsDocenteDe) == "function" then
		local ok, esDocente = pcall(ClassroomService.EsDocenteDe, ClassroomService, player, roomId)
		if ok and esDocente == true then
			return true
		end
	end
	-- Coordinación académica (horario.editar) puede dirigir cualquier aula.
	local cargo = player:GetAttribute("Cargo")
	if RoleService and typeof(RoleService.Cargo) == "function" then
		local ok, valor = pcall(RoleService.Cargo, RoleService, player)
		if ok and typeof(valor) == "string" then
			cargo = valor
		end
	end
	if typeof(cargo) == "string" and RoleDefinitions.Tiene(cargo, "aula.docente") and RoleDefinitions.Tiene(cargo, "horario.editar") then
		return true
	end
	return false, salon
end

function RoomService:ValidarPertenencia(player, roomId)
	local pertenece, salon = self:Pertenece(player, roomId)
	if pertenece then
		return true
	end
	local ahora = os.clock()
	local ultimo = self._ultimoAviso[player.UserId]
	if ultimo and ahora - ultimo < self.CooldownAvisoAsientoSeg then
		return false
	end
	self._ultimoAviso[player.UserId] = ahora
	local texto = "Este asiento pertenece al aula " .. nombreAula(roomId) .. "."
	if typeof(salon) == "string" and salon ~= "" then
		texto = texto .. " Tu salón es " .. nombreAula(salon) .. "."
	end
	local RemoteService = self.registro.Get("RemoteService")
	if RemoteService then
		RemoteService:Enviar(player, "Notificacion", { Texto = texto, Nivel = "aviso", Duracion = 6 })
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Jugadores
---------------------------------------------------------------------------------------------------
function RoomService:AlEntrar(player)
	if not esJugador(player) then
		return
	end
	local userId = player.UserId
	if self._maidsJugador[userId] then
		self._maidsJugador[userId]:DoCleaning()
	end
	local maid = Maid.new()
	self._maidsJugador[userId] = maid
	local function limpiar()
		local roomId = self:_Liberar(userId)
		if roomId then
			self:_ActualizarPresenciaAula(roomId)
			self.OcupacionCambiada:Fire(roomId)
		end
	end
	maid:GiveTask(player.CharacterRemoving:Connect(limpiar))
	maid:GiveTask(player.CharacterAdded:Connect(limpiar))
end

function RoomService:AlSalir(player)
	local userId = player.UserId
	local maid = self._maidsJugador[userId]
	if maid then
		self._maidsJugador[userId] = nil
		maid:DoCleaning()
	end
	self._ultimoAviso[userId] = nil
	local afectadas = {}
	local roomId = self:_Liberar(userId)
	if roomId then
		afectadas[roomId] = true
	end
	for id, presentes in pairs(self._presencia) do
		if presentes[userId] then
			presentes[userId] = nil
			afectadas[id] = true
		end
	end
	for id in pairs(afectadas) do
		self.OcupacionCambiada:Fire(id)
	end
end

---------------------------------------------------------------------------------------------------
-- Presencia
---------------------------------------------------------------------------------------------------

-- Aula en la que está el jugador ahora: la del asiento que ocupa o, si no está sentado en un aula, la zona
-- de aula más pequeña que contiene su HumanoidRootPart (Zones.Contiene). Un jugador = como máximo un aula.
function RoomService:AulaActualDe(player)
	if not esJugador(player) then
		return nil
	end
	local seat = self._asientoDe[player.UserId]
	if seat then
		local info = self._infoSeat[seat]
		if info and seat.Occupant ~= nil then
			return info.RoomId
		end
	end
	local raiz = raizDe(player)
	if not raiz then
		return nil
	end
	local posicion = raiz.Position
	for _, zona in ipairs(Zones.ZonasEn(posicion)) do
		if Zones.EsAula(zona.Id) and Zones.Contiene(zona, posicion) then
			return zona.Id
		end
	end
	return nil
end

-- ¿El jugador está ahora en el aula (sentado en uno de sus asientos o de pie dentro de su zona)?
function RoomService:EstaEn(player, roomId)
	if typeof(roomId) ~= "string" then
		return false
	end
	return self:AulaActualDe(player) == roomId
end

-- Jugadores presentes en el aula ahora mismo (array de Player).
function RoomService:JugadoresEn(roomId)
	local lista = {}
	if typeof(roomId) ~= "string" then
		return lista
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if self:AulaActualDe(player) == roomId then
			table.insert(lista, player)
		end
	end
	return lista
end

-- UserIds presentes (array ordenado).
function RoomService:Presentes(roomId)
	local lista = {}
	for _, player in ipairs(self:JugadoresEn(roomId)) do
		table.insert(lista, player.UserId)
	end
	return ordenarIds(lista)
end

-- { Sentados = {userId...}, DePie = {userId...}, Capacidad = n, RoomId }. En aulas sin Seats, Sentados queda
-- vacío y DePie lista a todos los presentes.
function RoomService:Ocupacion(roomId)
	local resultado = { RoomId = roomId, Sentados = {}, DePie = {}, Capacidad = self._capacidad[roomId] or 0 }
	if typeof(roomId) ~= "string" then
		return resultado
	end
	local sentados = self._sentados[roomId] or {}
	for _, player in ipairs(self:JugadoresEn(roomId)) do
		local seat = sentados[player.UserId]
		if seat and seat.Occupant ~= nil then
			table.insert(resultado.Sentados, player.UserId)
		else
			table.insert(resultado.DePie, player.UserId)
		end
	end
	ordenarIds(resultado.Sentados)
	ordenarIds(resultado.DePie)
	return resultado
end

-- Seat que ocupa el jugador (o nil).
function RoomService:AsientoDe(player)
	if not esJugador(player) then
		return nil
	end
	local seat = self._asientoDe[player.UserId]
	if seat and seat.Occupant ~= nil then
		return seat
	end
	return nil
end

-- RoomId del aula de un Seat (incluidos los duplicados) o nil.
function RoomService:AulaDeAsiento(seat)
	local info = self._infoSeat[seat]
	if info then
		return info.RoomId
	end
	local MapService = self.registro.Get("MapService")
	if MapService and typeof(MapService.AulaDeAsiento) == "function" then
		local ok, roomId = pcall(MapService.AulaDeAsiento, MapService, seat)
		if ok and typeof(roomId) == "string" then
			return roomId
		end
	end
	return nil
end

-- Capacidad (asientos reales) del aula.
function RoomService:Capacidad(roomId)
	return self._capacidad[roomId] or 0
end

-- Recalcula la presencia de un aula y devuelve true si cambió (no dispara la señal).
function RoomService:_ActualizarPresenciaAula(roomId)
	local nueva = {}
	for _, player in ipairs(self:JugadoresEn(roomId)) do
		nueva[player.UserId] = true
	end
	local anterior = self._presencia[roomId] or {}
	self._presencia[roomId] = nueva
	return not conjuntosIguales(anterior, nueva)
end

-- Recalcula la presencia de todas las aulas en una sola pasada y dispara OcupacionCambiada donde cambió.
function RoomService:RecalcularPresencia()
	local nuevas = {}
	for roomId in pairs(self._presencia) do
		nuevas[roomId] = {}
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local roomId = self:AulaActualDe(player)
		if roomId then
			if not nuevas[roomId] then
				nuevas[roomId] = {}
			end
			nuevas[roomId][player.UserId] = true
		end
	end
	for roomId, nueva in pairs(nuevas) do
		local anterior = self._presencia[roomId] or {}
		self._presencia[roomId] = nueva
		if not conjuntosIguales(anterior, nueva) then
			self.OcupacionCambiada:Fire(roomId)
		end
	end
end

-- Resumen legible para paneles: { RoomId, Nombre, Capacidad, Sentados = { {UserId, Nombre} }, DePie = {...} }.
function RoomService:Resumen(roomId)
	local ocupacion = self:Ocupacion(roomId)
	local function conNombres(ids)
		local lista = {}
		for _, userId in ipairs(ids) do
			local player = Players:GetPlayerByUserId(userId)
			table.insert(lista, {
				UserId = userId,
				Nombre = player and player.DisplayName or tostring(userId),
				Usuario = player and player.Name or "",
			})
		end
		return lista
	end
	return {
		RoomId = roomId,
		Nombre = nombreAula(roomId),
		Capacidad = ocupacion.Capacidad,
		Sentados = conNombres(ocupacion.Sentados),
		DePie = conNombres(ocupacion.DePie),
	}
end

-- Copia de la presencia calculada (diagnóstico): { roomId = { userId = true } }.
function RoomService:PresenciaCalculada()
	local copia = {}
	for roomId, presentes in pairs(self._presencia) do
		copia[roomId] = copiarConjunto(presentes)
	end
	return copia
end

-- Detiene el bucle y libera conexiones (uso en pruebas / reinstalación).
function RoomService:Detener()
	self.activo = false
	self._maidAsientos:DoCleaning()
	self.maid:DoCleaning()
	for userId, maid in pairs(self._maidsJugador) do
		maid:DoCleaning()
		self._maidsJugador[userId] = nil
	end
end

return RoomService
