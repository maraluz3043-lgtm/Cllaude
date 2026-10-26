--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.RemoteService
	Tipo: ModuleScript
	Puerta de entrada de todos los remotos (docs/ARQUITECTURA.md §5): crea ReplicatedStorage.ColegioRP.Remotes
	desde RemoteContracts, y para cada petición comprueba tabla, esquema (Validate), límite por jugador (ventana
	deslizante), permiso del cargo y distancia opcional antes de llamar al handler registrado en pcall. Los
	rechazos se auditan y alimentan el contador de sospecha. Canal servidor->cliente: Enviar / EnviarATodos /
	EnviarAZona / EnviarAAula sobre el RemoteEvent EventoCliente.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))

local RemoteService = {}
RemoteService.Nombre = "RemoteService"

local PREFIJO = "[ColegioRP][RemoteService]"
local NOMBRE_CARPETA = (Config.Nombres and Config.Nombres.CarpetaRemotos) or "Remotes"
local NOMBRE_EVENTO_CLIENTE = "EventoCliente"
local RECHAZOS_SOSPECHOSO = (Config.Red and Config.Red.RechazosParaSospechoso) or 20
local VENTANA_SOSPECHOSO = (Config.Red and Config.Red.VentanaSospechosoSeg) or 60

-- Tolerancia (studs) añadida a las comprobaciones de distancia (latencia y tamaño del personaje).
RemoteService.ToleranciaDistancia = 2
-- Motivos de rechazo que no se atribuyen al jugador (no cuentan para la sospecha).
RemoteService.MotivosSinCulpa = { sin_servicio = true, error_interno = true }

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
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

-- Elimina de la lista los instantes anteriores a (ahora - ventana). La lista está ordenada ascendente.
local function podar(lista, ahora, ventana)
	while lista[1] ~= nil and lista[1] <= ahora - ventana do
		table.remove(lista, 1)
	end
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function RemoteService:Init(registro)
	self.registro = registro
	self.Handlers = {} -- nombre -> { Handler = fn(player, datos), Posicion = fn(datos, player) -> Vector3|nil }
	self.Instancias = {} -- nombre -> RemoteEvent | RemoteFunction
	self.Conexiones = {}
	self.Ventanas = {} -- userId -> nombre -> { os.clock ... }
	self.Rechazos = {} -- userId -> { os.clock ... } (ventana de sospecha)
	self.Estadisticas = {
		Peticiones = 0, Aceptadas = 0, Rechazos = 0, Errores = 0,
		PorMotivo = {}, PorRemoto = {}, Tiempos = {}, Sospechosos = 0,
	}
	self.Sospechoso = Signal.new() -- (player, rechazosEnVentana)
	self.Carpeta = self:CrearCarpeta()
	self:CrearRemotos()
end

function RemoteService:Start()
	self.AuditLog = self.registro.Get("AuditLogService")
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.Ventanas[player.UserId] = nil
		self.Rechazos[player.UserId] = nil
	end))
	if self.AuditLog then
		self.AuditLog:Registrar("Sistema", nil, "Remotos", #RemoteContracts.Nombres .. " remotos publicados en ReplicatedStorage.ColegioRP." .. NOMBRE_CARPETA)
	end
end

---------------------------------------------------------------------------------------------------
-- Creación de instancias
---------------------------------------------------------------------------------------------------
function RemoteService:CrearCarpeta()
	local carpeta = RP:FindFirstChild(NOMBRE_CARPETA)
	if carpeta and not carpeta:IsA("Folder") then
		warn(PREFIJO .. " " .. NOMBRE_CARPETA .. " existe pero no es Folder; se reemplaza.")
		carpeta:Destroy()
		carpeta = nil
	end
	if not carpeta then
		carpeta = Instance.new("Folder")
		carpeta.Name = NOMBRE_CARPETA
		carpeta.Parent = RP
	end
	return carpeta
end

function RemoteService:CrearRemotos()
	for _, nombre in ipairs(RemoteContracts.Nombres) do
		local def = RemoteContracts.Remotos[nombre]
		local ok, err = pcall(function()
			self:CrearRemoto(nombre, def)
		end)
		if not ok then
			warn(PREFIJO .. " No se pudo crear el remoto " .. nombre .. ": " .. tostring(err))
		end
	end
	-- Instancias huérfanas (no están en el contrato) se avisan pero no se tocan.
	for _, hijo in ipairs(self.Carpeta:GetChildren()) do
		if not RemoteContracts.Existe(hijo.Name) then
			warn(PREFIJO .. " Instancia fuera del contrato en Remotes: " .. hijo.Name)
		end
	end
end

function RemoteService:CrearRemoto(nombre, def)
	local clase = def.Tipo
	if clase ~= "RemoteEvent" and clase ~= "RemoteFunction" then
		warn(PREFIJO .. " Tipo desconocido para " .. nombre .. ": " .. tostring(clase))
		return
	end
	local instancia = self.Carpeta:FindFirstChild(nombre)
	if instancia and not instancia:IsA(clase) then
		instancia:Destroy()
		instancia = nil
	end
	if not instancia then
		instancia = Instance.new(clase)
		instancia.Name = nombre
		instancia.Parent = self.Carpeta
	end
	instancia:SetAttribute("Direccion", def.Direccion)
	self.Instancias[nombre] = instancia
	self.Estadisticas.PorRemoto[nombre] = { Peticiones = 0, Rechazos = 0, Errores = 0 }

	if def.Direccion ~= "C2S" then
		return
	end
	if clase == "RemoteFunction" then
		instancia.OnServerInvoke = function(player, datos)
			return self:Procesar(nombre, player, datos)
		end
	else
		table.insert(self.Conexiones, instancia.OnServerEvent:Connect(function(player, datos)
			self:Procesar(nombre, player, datos)
		end))
	end
end

-- Instancia de un remoto por nombre (o nil).
function RemoteService:Instancia(nombre)
	return self.Instancias[nombre]
end

---------------------------------------------------------------------------------------------------
-- Registro de handlers
---------------------------------------------------------------------------------------------------

-- Registra el handler de un remoto C2S: handler(player, datos) -> { ok, error, datos } | tabla de datos | nil.
-- opciones.Posicion = function(datos, player) -> Vector3|nil permite a RemoteService comprobar la distancia
-- (def.Distancia) antes de llamar al handler. Devuelve true si se registró.
function RemoteService:Registrar(nombre, handler, opciones)
	if typeof(handler) ~= "function" then
		warn(PREFIJO .. " Registrar(" .. tostring(nombre) .. "): el handler debe ser una función.")
		return false
	end
	local def = RemoteContracts.Obtener(nombre)
	if not def then
		warn(PREFIJO .. " Registrar: el remoto '" .. tostring(nombre) .. "' no está en RemoteContracts.")
		return false
	end
	if def.Direccion ~= "C2S" then
		warn(PREFIJO .. " Registrar: '" .. nombre .. "' es S2C y no admite handler.")
		return false
	end
	if self.Handlers[nombre] then
		warn(PREFIJO .. " El handler de '" .. nombre .. "' ya estaba registrado; se reemplaza.")
	end
	local posicion = nil
	if typeof(opciones) == "table" and typeof(opciones.Posicion) == "function" then
		posicion = opciones.Posicion
	end
	self.Handlers[nombre] = { Handler = handler, Posicion = posicion }
	return true
end

-- Quita el handler de un remoto (las peticiones pasan a responder rechazado:sin_servicio).
function RemoteService:Desregistrar(nombre)
	self.Handlers[nombre] = nil
end

-- ¿Tiene handler registrado?
function RemoteService:TieneHandler(nombre)
	return self.Handlers[nombre] ~= nil
end

---------------------------------------------------------------------------------------------------
-- Límites y sospecha
---------------------------------------------------------------------------------------------------

-- Ventana deslizante por jugador y remoto. Devuelve true si la petición entra en el límite.
function RemoteService:DentroDelLimite(player, nombre)
	local max, ventana = RemoteContracts.LimiteDe(nombre)
	if not max or not ventana then
		return true
	end
	local ahora = os.clock()
	local porJugador = self.Ventanas[player.UserId]
	if not porJugador then
		porJugador = {}
		self.Ventanas[player.UserId] = porJugador
	end
	local lista = porJugador[nombre]
	if not lista then
		lista = {}
		porJugador[nombre] = lista
	end
	podar(lista, ahora, ventana)
	if #lista >= max then
		return false
	end
	table.insert(lista, ahora)
	return true
end

-- Cuenta un rechazo atribuible al jugador; marca Sospechoso al superar el umbral en la ventana.
function RemoteService:ContarSospecha(player)
	local userId = player.UserId
	local ahora = os.clock()
	local lista = self.Rechazos[userId]
	if not lista then
		lista = {}
		self.Rechazos[userId] = lista
	end
	podar(lista, ahora, VENTANA_SOSPECHOSO)
	table.insert(lista, ahora)
	if #lista < RECHAZOS_SOSPECHOSO then
		return
	end
	local cantidad = #lista
	table.clear(lista)
	self.Estadisticas.Sospechosos = self.Estadisticas.Sospechosos + 1
	pcall(function()
		player:SetAttribute("Sospechoso", true)
		player:SetAttribute("SospechosoDesde", os.time())
	end)
	if self.AuditLog then
		self.AuditLog:Registrar("Moderacion", player, "Sospechoso",
			string.format("%d rechazos de remotos en %d s (sin expulsión automática)", cantidad, VENTANA_SOSPECHOSO))
	end
	self.Sospechoso:Fire(player, cantidad)
	-- Aviso a quien tenga moderación básica (sin acciones automáticas).
	local RoleService = self.registro.Get("RoleService")
	if RoleService and typeof(RoleService.ConPermiso) == "function" then
		local okLista, moderadores = pcall(RoleService.ConPermiso, RoleService, "moderacion.basica")
		if okLista and typeof(moderadores) == "table" then
			for _, moderador in ipairs(moderadores) do
				if esJugador(moderador) and moderador ~= player then
					self:Enviar(moderador, "Moderacion", {
						Tipo = "Sospechoso", UserId = userId, Nombre = player.Name, Rechazos = cantidad, VentanaSeg = VENTANA_SOSPECHOSO,
					})
				end
			end
		end
	end
end

-- Registra un rechazo (estadísticas, auditoría, sospecha) y devuelve la respuesta estándar.
function RemoteService:Rechazar(player, nombre, motivo, detalle)
	self.Estadisticas.Rechazos = self.Estadisticas.Rechazos + 1
	self.Estadisticas.PorMotivo[motivo] = (self.Estadisticas.PorMotivo[motivo] or 0) + 1
	local porRemoto = self.Estadisticas.PorRemoto[nombre]
	if porRemoto then
		porRemoto.Rechazos = porRemoto.Rechazos + 1
	end
	local texto = motivo
	if detalle ~= nil and detalle ~= "" then
		texto = motivo .. ": " .. tostring(detalle)
	end
	if self.AuditLog then
		self.AuditLog:Registrar("Remoto", player, nombre, texto)
	end
	-- Métricas de rechazos (MetricsService es opcional y arranca después).
	local MetricsService = self.registro.Get("MetricsService")
	if MetricsService and typeof(MetricsService.IncrementarRechazo) == "function" then
		local okMetricas, errMetricas = pcall(MetricsService.IncrementarRechazo, MetricsService, nombre, motivo)
		if not okMetricas then
			warn(PREFIJO .. " MetricsService:IncrementarRechazo falló: " .. tostring(errMetricas))
		end
	end
	if esJugador(player) and not self.MotivosSinCulpa[motivo] then
		self:ContarSospecha(player)
	end
	return RemoteContracts.Rechazo(motivo)
end

---------------------------------------------------------------------------------------------------
-- Procesamiento de peticiones
---------------------------------------------------------------------------------------------------
function RemoteService:Procesar(nombre, player, datos)
	self.Estadisticas.Peticiones = self.Estadisticas.Peticiones + 1
	local porRemoto = self.Estadisticas.PorRemoto[nombre]
	if porRemoto then
		porRemoto.Peticiones = porRemoto.Peticiones + 1
	end
	if not esJugador(player) then
		return RemoteContracts.Rechazo("jugador_invalido")
	end
	local def = RemoteContracts.Obtener(nombre)
	if not def or def.Direccion ~= "C2S" then
		return self:Rechazar(player, nombre, "remoto_desconocido")
	end

	-- 1. Los datos deben ser una tabla (único argumento).
	if typeof(datos) ~= "table" then
		return self:Rechazar(player, nombre, "datos_no_tabla", typeof(datos))
	end

	-- 2. Esquema declarado en RemoteContracts.
	local okEsquema, errEsquema = RemoteContracts.Validar(nombre, datos)
	if not okEsquema then
		return self:Rechazar(player, nombre, "esquema", errEsquema)
	end

	-- 3. Límite de frecuencia por jugador (ventana deslizante).
	if not self:DentroDelLimite(player, nombre) then
		return self:Rechazar(player, nombre, "limite")
	end

	-- 4. Permiso del cargo (fijo o según la acción).
	local permiso = RemoteContracts.PermisoPara(nombre, datos)
	if permiso == RemoteContracts.DENEGADO then
		return self:Rechazar(player, nombre, "permiso", "acción no permitida")
	end
	if permiso ~= nil then
		local RoleService = self.registro.Get("RoleService")
		local tiene = false
		if RoleService and typeof(RoleService.Tiene) == "function" then
			local okTiene, resultado = pcall(RoleService.Tiene, RoleService, player, permiso)
			tiene = okTiene and resultado == true
		end
		if not tiene then
			return self:Rechazar(player, nombre, "permiso", permiso)
		end
	end

	-- 5. Handler registrado.
	local registro = self.Handlers[nombre]
	if not registro then
		return self:Rechazar(player, nombre, "sin_servicio")
	end

	-- 6. Distancia (solo si el servicio aportó un resolutor de posición y el contrato fija distancia).
	local distanciaMax = def.Distancia
	if distanciaMax and registro.Posicion then
		local okPos, objetivo = pcall(registro.Posicion, datos, player)
		if okPos and typeof(objetivo) == "Vector3" then
			local posicion = posicionDe(player)
			if not posicion then
				return self:Rechazar(player, nombre, "sin_personaje")
			end
			local distancia = (posicion - objetivo).Magnitude
			if distancia > distanciaMax + self.ToleranciaDistancia then
				return self:Rechazar(player, nombre, "distancia", string.format("%.1f > %.1f", distancia, distanciaMax))
			end
		end
	end

	-- 7. Handler en pcall.
	local t0 = os.clock()
	local okHandler, respuesta = pcall(registro.Handler, player, datos)
	self:RegistrarTiempo(nombre, os.clock() - t0)
	if not okHandler then
		self.Estadisticas.Errores = self.Estadisticas.Errores + 1
		if porRemoto then
			porRemoto.Errores = porRemoto.Errores + 1
		end
		warn(PREFIJO .. " Error en el handler de " .. nombre .. " (" .. player.Name .. "): " .. tostring(respuesta))
		if self.AuditLog then
			self.AuditLog:Registrar("Remoto", player, nombre, "error_interno: " .. tostring(respuesta))
		end
		return RemoteContracts.Error("error_interno")
	end
	self.Estadisticas.Aceptadas = self.Estadisticas.Aceptadas + 1

	-- Normalización de la respuesta a { ok, error, datos }.
	if respuesta == nil then
		return RemoteContracts.Ok()
	end
	if typeof(respuesta) ~= "table" then
		return RemoteContracts.Ok({ Valor = respuesta })
	end
	if respuesta.ok == nil then
		return RemoteContracts.Ok(respuesta)
	end
	if respuesta.ok ~= true then
		respuesta.ok = false
		if respuesta.error == nil then
			respuesta.error = "error"
		end
	end
	return respuesta
end

function RemoteService:RegistrarTiempo(nombre, duracion)
	local t = self.Estadisticas.Tiempos[nombre]
	if not t then
		t = { Suma = 0, N = 0, Max = 0 }
		self.Estadisticas.Tiempos[nombre] = t
	end
	t.Suma = t.Suma + duracion
	t.N = t.N + 1
	if duracion > t.Max then
		t.Max = duracion
	end
end

---------------------------------------------------------------------------------------------------
-- Servidor -> cliente (canal EventoCliente)
---------------------------------------------------------------------------------------------------
function RemoteService:EventoCliente()
	local remoto = self.Instancias[NOMBRE_EVENTO_CLIENTE]
	if remoto and remoto.Parent then
		return remoto
	end
	local def = RemoteContracts.Obtener(NOMBRE_EVENTO_CLIENTE)
	if def then
		pcall(function()
			self:CrearRemoto(NOMBRE_EVENTO_CLIENTE, def)
		end)
	end
	return self.Instancias[NOMBRE_EVENTO_CLIENTE]
end

local function comprobarTipo(tipo)
	if not RemoteContracts.EsTipoEvento(tipo) then
		warn(PREFIJO .. " Tipo de EventoCliente desconocido: " .. tostring(tipo))
		return false
	end
	return true
end

-- Envía { Tipo, Datos } a un jugador. Devuelve true si se envió.
function RemoteService:Enviar(player, tipo, datos)
	if not esJugador(player) or player.Parent == nil then
		return false
	end
	if not comprobarTipo(tipo) then
		return false
	end
	local remoto = self:EventoCliente()
	if not remoto then
		return false
	end
	local ok, err = pcall(remoto.FireClient, remoto, player, { Tipo = tipo, Datos = datos or {} })
	if not ok then
		warn(PREFIJO .. " Error al enviar '" .. tostring(tipo) .. "' a " .. player.Name .. ": " .. tostring(err))
		return false
	end
	return true
end

-- Envía a todos los jugadores.
function RemoteService:EnviarATodos(tipo, datos)
	if not comprobarTipo(tipo) then
		return false
	end
	local remoto = self:EventoCliente()
	if not remoto then
		return false
	end
	local ok, err = pcall(remoto.FireAllClients, remoto, { Tipo = tipo, Datos = datos or {} })
	if not ok then
		warn(PREFIJO .. " Error al enviar a todos '" .. tostring(tipo) .. "': " .. tostring(err))
		return false
	end
	return true
end

-- Envía a una lista de jugadores (Players o userIds). Devuelve cuántos recibieron.
function RemoteService:EnviarALista(lista, tipo, datos)
	if typeof(lista) ~= "table" or not comprobarTipo(tipo) then
		return 0
	end
	local enviados = 0
	local carga = { Tipo = tipo, Datos = datos or {} }
	local remoto = self:EventoCliente()
	if not remoto then
		return 0
	end
	for _, elemento in ipairs(lista) do
		local player = elemento
		if typeof(elemento) == "number" then
			player = Players:GetPlayerByUserId(elemento)
		end
		if esJugador(player) and player.Parent ~= nil then
			local ok = pcall(remoto.FireClient, remoto, player, carga)
			if ok then
				enviados = enviados + 1
			end
		end
	end
	return enviados
end

-- Jugadores cuyo HumanoidRootPart está dentro de la zona (Util/Zones).
function RemoteService:JugadoresEnZona(zonaId)
	local lista = {}
	local zona = Zones.Zona(zonaId)
	if not zona then
		return lista
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local posicion = posicionDe(player)
		if posicion and Zones.Contiene(zona, posicion) then
			table.insert(lista, player)
		end
	end
	return lista
end

-- Envía a los jugadores que están físicamente dentro de la zona. Devuelve cuántos recibieron.
function RemoteService:EnviarAZona(zonaId, tipo, datos)
	return self:EnviarALista(self:JugadoresEnZona(zonaId), tipo, datos)
end

-- Envía a los jugadores de un aula. La zona del aula tiene la misma id que el aula (MapaLogico), así que se
-- envía por zona; solo si el aula no existe como zona se delega en RoomService:JugadoresEn(roomId).
function RemoteService:EnviarAAula(roomId, tipo, datos)
	if Zones.Zona(roomId) then
		return self:EnviarAZona(roomId, tipo, datos)
	end
	local RoomService = self.registro.Get("RoomService")
	if RoomService and typeof(RoomService.JugadoresEn) == "function" then
		local ok, lista = pcall(RoomService.JugadoresEn, RoomService, roomId)
		if ok and typeof(lista) == "table" then
			return self:EnviarALista(lista, tipo, datos)
		end
	end
	return 0
end

---------------------------------------------------------------------------------------------------
-- Métricas
---------------------------------------------------------------------------------------------------

-- Copia de las estadísticas (peticiones, rechazos por motivo y remoto, tiempos medios).
function RemoteService:ObtenerEstadisticas()
	local tiempos = {}
	for nombre, t in pairs(self.Estadisticas.Tiempos) do
		if t.N > 0 then
			tiempos[nombre] = { Media = t.Suma / t.N, Max = t.Max, N = t.N }
		end
	end
	local porMotivo = {}
	for motivo, n in pairs(self.Estadisticas.PorMotivo) do
		porMotivo[motivo] = n
	end
	local porRemoto = {}
	for nombre, r in pairs(self.Estadisticas.PorRemoto) do
		porRemoto[nombre] = { Peticiones = r.Peticiones, Rechazos = r.Rechazos, Errores = r.Errores }
	end
	return {
		Peticiones = self.Estadisticas.Peticiones,
		Aceptadas = self.Estadisticas.Aceptadas,
		Rechazos = self.Estadisticas.Rechazos,
		Errores = self.Estadisticas.Errores,
		Sospechosos = self.Estadisticas.Sospechosos,
		PorMotivo = porMotivo,
		PorRemoto = porRemoto,
		Tiempos = tiempos,
		HandlersRegistrados = (function()
			local n = 0
			for _ in pairs(self.Handlers) do
				n = n + 1
			end
			return n
		end)(),
	}
end

-- Jugadores marcados como sospechosos actualmente conectados.
function RemoteService:Sospechosos()
	local lista = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("Sospechoso") == true then
			table.insert(lista, player)
		end
	end
	return lista
end

-- Quita la marca de sospechoso (uso de moderación).
function RemoteService:LimpiarSospecha(player)
	if not esJugador(player) then
		return false
	end
	self.Rechazos[player.UserId] = nil
	pcall(function()
		player:SetAttribute("Sospechoso", nil)
		player:SetAttribute("SospechosoDesde", nil)
	end)
	return true
end

return RemoteService
