--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.BathroomService
	Tipo: ModuleScript
	Interacciones de baño (docs/ARQUITECTURA.md §6): para cada zona de tipo "banos" de MapaLogico y sus Objetos
	(Inodoros, Urinarios, Lavamanos: puntos) busca la BasePart real más cercana (<= 3 studs, sin Seats ni piezas de
	Workspace.ColegioRP_Mapa) y añade un ProximityPrompt (RPTipo = "Bano", RPId = ObjetoId, RPAccion = "LavarManos"
	| "Usar", HoldDuration 0.5) en un Attachment propio situado en el punto lógico. Acciones con cooldown de 20 s
	por objeto y 10 s por jugador; "Usar" reproduce el Sound original de "Workspace/Bathroom Toilet/Handle/Sound"
	más cercano (<= 6 studs) sin modificarlo; mensajes neutros ("Te lavas las manos", "Listo"); recompensa 0.
	Remoto BathroomAction { ObjetoId, Accion } (distancia <= 10; "Limpiar" requiere limpieza.tareas).
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))

local BathroomService = {}
BathroomService.Nombre = "BathroomService"

local PREFIJO = "[ColegioRP][BathroomService]"
local DISTANCIA_MAX = (Config.Distancias and tonumber(Config.Distancias.Bano)) or 10
local TAG_BANO = (Config.Tags and Config.Tags.Bano) or "ColegioRP_Bano"
local NOMBRE_CARPETA_MAPA = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"

---------------------------------------------------------------------------------------------------
-- Parámetros
---------------------------------------------------------------------------------------------------
BathroomService.RadioBusqueda = 3 -- Distancia máxima punto lógico -> BasePart real.
BathroomService.CooldownObjetoSeg = 20 -- Un mismo objeto no se puede volver a usar antes de esto.
BathroomService.CooldownJugadorSeg = 10 -- Un jugador no puede usar otro objeto antes de esto.
BathroomService.CooldownLimpiezaSeg = 15 -- Entre dos limpiezas del mismo objeto.
BathroomService.DistanciaSonido = 6 -- Sonido de cisterna más cercano admitido.
BathroomService.DistanciaPrompt = 6 -- MaxActivationDistance de los prompts.
BathroomService.HoldDuration = 0.5
BathroomService.ToleranciaDistancia = 2
BathroomService.TamanoMaxPieza = 12 -- Piezas con alguna dimensión mayor (suelos, muros) no se toman como objeto.
BathroomService.BonusNombre = 1.5 -- Studs de ventaja para piezas cuyo nombre coincide con el tipo de objeto.
BathroomService.IntervaloAuditoriaSeg = 10

-- Tipos de objeto: clave en Zona.Objetos -> definición.
local TIPOS = {
	{ Clave = "Inodoros", Tipo = "Inodoro", Accion = "Usar", ActionText = "Usar", ObjectText = "Inodoro",
		Palabras = { "toilet", "inodoro", "sanitario", "bowl", "tank", "taza" } },
	{ Clave = "Urinarios", Tipo = "Urinario", Accion = "Usar", ActionText = "Usar", ObjectText = "Urinario",
		Palabras = { "urinario", "urinal", "orinal" } },
	{ Clave = "Lavamanos", Tipo = "Lavamanos", Accion = "LavarManos", ActionText = "Lavar manos", ObjectText = "Lavamanos",
		Palabras = { "lavamanos", "lavabo", "sink", "grifo", "llave", "faucet", "lavaman" } },
}

local MENSAJES = {
	LavarManos = "Te lavas las manos",
	Usar = "Listo",
	Limpiar = "Dejas el lugar limpio",
}

local MOTIVOS_AUDITADOS = { objeto_inexistente = true, accion_invalida = true, distancia = true, permiso = true }

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

local function posicionJugador(player)
	local personaje = player and player.Character
	if not personaje then
		return nil
	end
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Distancia de un punto a la caja orientada de una BasePart (0 si está dentro).
local function distanciaAParte(parte, punto)
	local rel = parte.CFrame:PointToObjectSpace(punto)
	local s = parte.Size
	local dx = math.max(math.abs(rel.X) - s.X / 2, 0)
	local dy = math.max(math.abs(rel.Y) - s.Y / 2, 0)
	local dz = math.max(math.abs(rel.Z) - s.Z / 2, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ¿El nombre de la pieza o de sus dos primeros ancestros contiene alguna palabra clave?
local function coincideNombre(parte, palabras)
	local actual = parte
	for _ = 1, 3 do
		if not actual or actual == workspace then
			return false
		end
		local nombre = string.lower(actual.Name)
		for _, palabra in ipairs(palabras) do
			if string.find(nombre, palabra, 1, true) then
				return true
			end
		end
		actual = actual.Parent
	end
	return false
end

local function esPersonaje(parte)
	local modelo = parte:FindFirstAncestorOfClass("Model")
	while modelo do
		if modelo:FindFirstChildOfClass("Humanoid") and Players:GetPlayerFromCharacter(modelo) then
			return true
		end
		modelo = modelo:FindFirstAncestorOfClass("Model")
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function BathroomService:Init(registro)
	self.registro = registro
	self.Objetos = {} -- objetoId -> registro
	self.Orden = {} -- ids en orden de creación
	self.Sonidos = {} -- { { Sonido = Sound, Posicion = Vector3 } }
	self.UltimoUsoJugador = {} -- userId -> os.clock()
	self.UltimaAuditoria = {} -- userId -> { ["id|motivo"] = os.clock() }
	self.Conexiones = {}
	self.Advertencias = {}
	self.UsosTotales = 0
	self.Activo = false
	self.Usado = Signal.new() -- (player, objetoId, accion)
end

function BathroomService:Start()
	self.Activo = true
	local okSonidos, errSonidos = pcall(self.BuscarSonidos, self)
	if not okSonidos then
		self:Advertir("No se pudieron localizar los sonidos de cisterna: " .. tostring(errSonidos))
	end
	local okObjetos, errObjetos = pcall(self.ConstruirObjetos, self)
	if not okObjetos then
		warn(PREFIJO .. " Error al preparar los objetos de baño: " .. tostring(errObjetos))
	end

	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("BathroomAction", function(player, datos)
			return self:ManejarBathroomAction(player, datos)
		end, {
			Posicion = function(datos)
				local objeto = typeof(datos) == "table" and typeof(datos.ObjetoId) == "string" and self.Objetos[datos.ObjetoId] or nil
				if objeto then
					return objeto.Punto
				end
				return nil
			end,
		})
	else
		warn(PREFIJO .. " RemoteService no disponible: BathroomAction no tendrá handler (los prompts siguen funcionando).")
	end

	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.UltimoUsoJugador[player.UserId] = nil
		self.UltimaAuditoria[player.UserId] = nil
	end))

	local conParte = 0
	for _, id in ipairs(self.Orden) do
		if self.Objetos[id].Parte then
			conParte = conParte + 1
		end
	end
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog then
		pcall(AuditLog.Registrar, AuditLog, "Sistema", nil, "Banos", string.format(
			"%d objetos de baño (%d con prompt), %d sonidos de cisterna", #self.Orden, conParte, #self.Sonidos))
	end
	for _, aviso in ipairs(self.Advertencias) do
		warn(PREFIJO .. " " .. aviso)
	end
end

function BathroomService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		local ok, servicio = pcall(registro.Get, nombre)
		if ok then
			return servicio
		end
	end
	return nil
end

function BathroomService:Advertir(texto)
	table.insert(self.Advertencias, tostring(texto))
end

---------------------------------------------------------------------------------------------------
-- Construcción
---------------------------------------------------------------------------------------------------

-- Sonidos existentes Workspace/Bathroom Toilet/Handle/Sound (no se modifican; solo se reproducen).
function BathroomService:BuscarSonidos()
	for _, hijo in ipairs(workspace:GetChildren()) do
		if hijo.Name == "Bathroom Toilet" then
			local asa = hijo:FindFirstChild("Handle")
			local sonido = asa and asa:FindFirstChild("Sound")
			if sonido and sonido:IsA("Sound") then
				local posicion = nil
				if asa:IsA("BasePart") then
					posicion = asa.Position
				elseif hijo:IsA("Model") then
					local ok, cf = pcall(function()
						local caja = hijo:GetBoundingBox()
						return caja
					end)
					if ok and typeof(cf) == "CFrame" then
						posicion = cf.Position
					end
				end
				if posicion then
					table.insert(self.Sonidos, { Sonido = sonido, Posicion = posicion })
				end
			end
		end
	end
end

-- Parámetros de consulta: se excluye la carpeta propia del mapa.
function BathroomService:ParametrosConsulta()
	local params = OverlapParams.new()
	local excluir = {}
	local carpeta = workspace:FindFirstChild(NOMBRE_CARPETA_MAPA)
	if carpeta then
		table.insert(excluir, carpeta)
	end
	params.FilterDescendantsInstances = excluir
	pcall(function()
		params.FilterType = Enum.RaycastFilterType.Exclude
	end)
	return params, carpeta
end

-- BasePart real más cercana al punto (<= RadioBusqueda), sin Seats, piezas propias, personajes ni muros/suelos.
function BathroomService:ParteCercana(punto, palabras, params, carpeta)
	local okConsulta, partes = pcall(function()
		return workspace:GetPartBoundsInRadius(punto, self.RadioBusqueda, params)
	end)
	if not okConsulta or typeof(partes) ~= "table" then
		return nil
	end
	local mejor, mejorPuntaje, mejorDist = nil, math.huge, math.huge
	for _, parte in ipairs(partes) do
		if parte:IsA("BasePart") and not parte:IsA("Seat") and not parte:IsA("VehicleSeat") and not parte:IsA("Terrain")
			and not (carpeta and parte:IsDescendantOf(carpeta)) and not esPersonaje(parte) then
			local s = parte.Size
			if math.max(s.X, s.Y, s.Z) <= self.TamanoMaxPieza then
				local d = distanciaAParte(parte, punto)
				if d <= self.RadioBusqueda then
					local puntaje = d
					if coincideNombre(parte, palabras) then
						puntaje = puntaje - self.BonusNombre
					end
					if puntaje < mejorPuntaje then
						mejor, mejorPuntaje, mejorDist = parte, puntaje, d
					end
				end
			end
		end
	end
	return mejor, mejorDist
end

function BathroomService:ConstruirObjetos()
	local zonas = Zones.ZonasTipo("banos")
	if #zonas == 0 and typeof(MapaLogico.ZonasPorTipo) == "function" then
		zonas = MapaLogico.ZonasPorTipo("banos")
	end
	local params, carpeta = self:ParametrosConsulta()
	local MapService = self:Servicio("MapService")
	for _, zona in ipairs(zonas) do
		local objetos = zona.Objetos
		if typeof(objetos) == "table" then
			for _, def in ipairs(TIPOS) do
				local puntos = objetos[def.Clave]
				if typeof(puntos) == "table" then
					for i, punto in ipairs(puntos) do
						if typeof(punto) == "Vector3" then
							local id = zona.Id .. "_" .. def.Tipo .. "_" .. tostring(i)
							local ok, err = pcall(self.CrearObjeto, self, id, zona, def, punto, params, carpeta, MapService)
							if not ok then
								self:Advertir("Objeto " .. id .. " con error: " .. tostring(err))
							end
						end
					end
				end
			end
		end
	end
end

function BathroomService:CrearObjeto(id, zona, def, punto, params, carpeta, MapService)
	local parte, distancia = self:ParteCercana(punto, def.Palabras, params, carpeta)
	local objeto = {
		Id = id,
		Zona = zona.Id,
		Tipo = def.Tipo,
		Accion = def.Accion,
		Punto = punto,
		Parte = parte,
		Distancia = distancia,
		UltimoUso = -math.huge,
		UltimaLimpieza = -math.huge,
		Usos = 0,
		Token = 0,
	}
	self.Objetos[id] = objeto
	table.insert(self.Orden, id)
	if not parte then
		self:Advertir("Objeto " .. id .. ": no hay pieza real a <= " .. self.RadioBusqueda .. " studs de " .. tostring(punto) .. " (sin prompt; el remoto sigue disponible).")
		return
	end

	-- Attachment propio en el punto lógico (varios objetos pueden compartir pieza, p. ej. un mueble doble).
	local ancla = Instance.new("Attachment")
	ancla.Name = "ColegioRP_Bano_" .. id
	ancla.Position = parte.CFrame:PointToObjectSpace(punto)
	ancla.Parent = parte
	objeto.Ancla = ancla

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ColegioRP_PromptBano"
	prompt.ActionText = def.ActionText
	prompt.ObjectText = def.ObjectText
	prompt.HoldDuration = self.HoldDuration
	prompt.MaxActivationDistance = self.DistanciaPrompt
	prompt.RequiresLineOfSight = false
	prompt.ClickablePrompt = true
	prompt.Enabled = true
	prompt:SetAttribute("RPTipo", "Bano")
	prompt:SetAttribute("RPId", id)
	prompt:SetAttribute("RPAccion", def.Accion)
	prompt:SetAttribute("RPZona", zona.Id)
	prompt.Parent = ancla
	objeto.Prompt = prompt
	table.insert(self.Conexiones, prompt.Triggered:Connect(function(player)
		self:AlActivarPrompt(objeto, player)
	end))

	-- Tag y atributo ObjetoId en la pieza real (§8); vía MapService para que su Limpiar los retire.
	local marcarTag = MapService and typeof(MapService.MarcarTag) == "function"
	local marcarAtributo = MapService and typeof(MapService.MarcarAtributo) == "function"
	if marcarTag then
		pcall(MapService.MarcarTag, MapService, parte, TAG_BANO)
	else
		pcall(CollectionService.AddTag, CollectionService, parte, TAG_BANO)
	end
	if parte:GetAttribute("ObjetoId") == nil then
		if marcarAtributo then
			pcall(MapService.MarcarAtributo, MapService, parte, "ObjetoId", id)
		else
			pcall(parte.SetAttribute, parte, "ObjetoId", id)
		end
		objeto.MarcoAtributo = true
	end
end

---------------------------------------------------------------------------------------------------
-- Acciones
---------------------------------------------------------------------------------------------------

-- Sonido de cisterna más cercano (<= DistanciaSonido) al punto; se reproduce sin cambiar sus propiedades.
function BathroomService:ReproducirCisterna(punto)
	local mejor, mejorDist = nil, self.DistanciaSonido
	for _, entrada in ipairs(self.Sonidos) do
		local d = (entrada.Posicion - punto).Magnitude
		if d <= mejorDist and entrada.Sonido.Parent ~= nil then
			mejor, mejorDist = entrada.Sonido, d
		end
	end
	if mejor then
		local ok = pcall(function()
			mejor:Play()
		end)
		return ok
	end
	return false
end

-- Deshabilita el prompt mientras dura el cooldown del objeto (todos ven que está en uso).
function BathroomService:BloquearTemporal(objeto, segundos)
	objeto.Token = objeto.Token + 1
	local token = objeto.Token
	local prompt = objeto.Prompt
	if not prompt then
		return
	end
	pcall(function()
		prompt.Enabled = false
	end)
	task.delay(segundos, function()
		if objeto.Token == token and prompt.Parent ~= nil and self.Activo then
			pcall(function()
				prompt.Enabled = true
			end)
		end
	end)
end

function BathroomService:Desbloquear(objeto)
	objeto.Token = objeto.Token + 1
	if objeto.Prompt then
		pcall(function()
			objeto.Prompt.Enabled = true
		end)
	end
end

-- Ejecuta una acción. Devuelve ok, mensaje, codigo.
function BathroomService:Usar(player, objetoId, accion, origen)
	local objeto = typeof(objetoId) == "string" and self.Objetos[objetoId] or nil
	if not objeto then
		return false, "Ese objeto no está disponible.", "objeto_inexistente"
	end
	if accion ~= "LavarManos" and accion ~= "Usar" and accion ~= "Limpiar" then
		return false, "Acción no válida.", "accion_invalida"
	end
	if accion ~= "Limpiar" and accion ~= objeto.Accion then
		return false, "Esa acción no está disponible aquí.", "accion_invalida"
	end
	if not esJugador(player) then
		return false, "Jugador no válido.", "accion_invalida"
	end
	local pos = posicionJugador(player)
	if not pos then
		return false, "Necesitas tu personaje para hacerlo.", "sin_personaje"
	end
	if (pos - objeto.Punto).Magnitude > DISTANCIA_MAX + self.ToleranciaDistancia then
		return false, "Acércate más.", "distancia"
	end
	local ahora = os.clock()

	if accion == "Limpiar" then
		-- El remoto ya exige limpieza.tareas; otros servicios que llamen aquí pasan por la misma comprobación.
		if origen ~= "Remoto" then
			local RoleService = self:Servicio("RoleService")
			local tiene = false
			if RoleService and typeof(RoleService.Tiene) == "function" then
				local okTiene, resultado = pcall(RoleService.Tiene, RoleService, player, "limpieza.tareas")
				tiene = okTiene and resultado == true
			end
			if not tiene then
				return false, "Solo el personal de limpieza puede hacerlo.", "permiso"
			end
		end
		if ahora - objeto.UltimaLimpieza < self.CooldownLimpiezaSeg then
			return false, "Este lugar ya está limpio.", "cooldown_objeto"
		end
		objeto.UltimaLimpieza = ahora
		objeto.UltimoUso = -math.huge
		self:Desbloquear(objeto)
	else
		local ultimoJugador = self.UltimoUsoJugador[player.UserId]
		if ultimoJugador and ahora - ultimoJugador < self.CooldownJugadorSeg then
			return false, "Espera unos segundos antes de volver a hacerlo.", "cooldown_jugador"
		end
		if ahora - objeto.UltimoUso < self.CooldownObjetoSeg then
			return false, "Está en uso. Prueba con otro.", "cooldown_objeto"
		end
		self.UltimoUsoJugador[player.UserId] = ahora
		objeto.UltimoUso = ahora
		self:BloquearTemporal(objeto, self.CooldownObjetoSeg)
		if accion == "Usar" then
			self:ReproducirCisterna(objeto.Punto)
		end
	end

	objeto.Usos = objeto.Usos + 1
	self.UsosTotales = self.UsosTotales + 1
	pcall(function()
		self.Usado:Fire(player, objeto.Id, accion)
	end)
	return true, MENSAJES[accion], "ok"
end

function BathroomService:Notificar(player, texto, nivel)
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" and esJugador(player) then
		pcall(RemoteService.Enviar, RemoteService, player, "Notificacion", { Texto = texto, Nivel = nivel or "info", Duracion = 3 })
	end
end

function BathroomService:AlActivarPrompt(objeto, player)
	if not self.Activo or not esJugador(player) then
		return
	end
	local ok, mensaje, codigo = self:Usar(player, objeto.Id, objeto.Accion, "Prompt")
	if not ok then
		self:RegistrarRechazo(player, codigo, objeto.Id, objeto.Accion, "Prompt")
		self:Notificar(player, mensaje, "aviso")
	else
		self:Notificar(player, mensaje, "info")
	end
end

-- Handler del remoto BathroomAction { ObjetoId, Accion }.
function BathroomService:ManejarBathroomAction(player, datos)
	local ok, mensaje, codigo = self:Usar(player, datos.ObjetoId, datos.Accion, "Remoto")
	if not ok then
		self:RegistrarRechazo(player, codigo, datos.ObjetoId, datos.Accion, "Remoto")
		return { ok = false, error = mensaje, datos = { ObjetoId = datos.ObjetoId, Codigo = codigo } }
	end
	return { ok = true, datos = { ObjetoId = datos.ObjetoId, Accion = datos.Accion, Mensaje = mensaje } }
end

function BathroomService:RegistrarRechazo(player, codigo, objetoId, accion, origen)
	if not MOTIVOS_AUDITADOS[codigo] then
		return
	end
	if esJugador(player) then
		local porJugador = self.UltimaAuditoria[player.UserId]
		if not porJugador then
			porJugador = {}
			self.UltimaAuditoria[player.UserId] = porJugador
		end
		local clave = tostring(objetoId) .. "|" .. tostring(codigo)
		local ahora = os.clock()
		if porJugador[clave] and ahora - porJugador[clave] < self.IntervaloAuditoriaSeg then
			return
		end
		porJugador[clave] = ahora
	end
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog then
		pcall(AuditLog.Registrar, AuditLog, "Remoto", player, "BathroomAction",
			string.format("logica:%s objeto=%s accion=%s origen=%s", tostring(codigo), tostring(objetoId), tostring(accion), tostring(origen)))
	end
	if codigo ~= "permiso" then
		local Metrics = self:Servicio("MetricsService")
		if Metrics and typeof(Metrics.IncrementarRechazo) == "function" then
			pcall(Metrics.IncrementarRechazo, Metrics, "BathroomAction", tostring(codigo))
		end
	end
end

---------------------------------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------------------------------

-- Estado de los baños: totales y lista por objeto { Id, Zona, Tipo, Accion, Disponible, EnUsoSeg, Usos, ConPrompt }.
function BathroomService:Estado()
	local ahora = os.clock()
	local lista, porZona = {}, {}
	local conParte = 0
	for _, id in ipairs(self.Orden) do
		local objeto = self.Objetos[id]
		local restante = math.max(0, self.CooldownObjetoSeg - (ahora - objeto.UltimoUso))
		if objeto.Parte then
			conParte = conParte + 1
		end
		porZona[objeto.Zona] = (porZona[objeto.Zona] or 0) + 1
		table.insert(lista, {
			Id = id,
			Zona = objeto.Zona,
			Tipo = objeto.Tipo,
			Accion = objeto.Accion,
			Disponible = restante <= 0,
			EnUsoSeg = math.floor(restante + 0.5),
			Usos = objeto.Usos,
			ConPrompt = objeto.Prompt ~= nil,
		})
	end
	return {
		Total = #self.Orden,
		ConPrompt = conParte,
		Sonidos = #self.Sonidos,
		UsosTotales = self.UsosTotales,
		PorZona = porZona,
		Objetos = lista,
	}
end

BathroomService.Snapshot = BathroomService.Estado

-- Registro interno de un objeto (sin instancias en la copia) o nil.
function BathroomService:Objeto(objetoId)
	local objeto = self.Objetos[objetoId]
	if not objeto then
		return nil
	end
	return { Id = objeto.Id, Zona = objeto.Zona, Tipo = objeto.Tipo, Accion = objeto.Accion, Punto = objeto.Punto, Usos = objeto.Usos }
end

-- Retira prompts y attachments propios y los atributos/tags puestos (desinstalación).
function BathroomService:Restaurar()
	self.Activo = false
	for _, conexion in ipairs(self.Conexiones) do
		pcall(function()
			conexion:Disconnect()
		end)
	end
	self.Conexiones = {}
	for _, id in ipairs(self.Orden) do
		local objeto = self.Objetos[id]
		if objeto.Ancla then
			pcall(function()
				objeto.Ancla:Destroy()
			end)
		end
		if objeto.Parte then
			pcall(CollectionService.RemoveTag, CollectionService, objeto.Parte, TAG_BANO)
			if objeto.MarcoAtributo then
				pcall(objeto.Parte.SetAttribute, objeto.Parte, "ObjetoId", nil)
			end
		end
	end
	self.Objetos = {}
	self.Orden = {}
end

return BathroomService
