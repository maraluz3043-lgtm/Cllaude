--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.ReportService
	Tipo: ModuleScript
	Reportes de soporte y convivencia (docs/ARQUITECTURA.md §6): atiende ReportSubmit (categoría válida,
	ubicación y descripción saneadas y filtradas con TextService, límite propio Config.Reportes.MaxPorMinuto
	además del de RemoteService), genera el id "R_<unix>_<userId>", guarda el reporte con
	DataService:GuardarReporte, conserva los últimos 100 en memoria para moderación (Listar) y avisa a quien
	tenga reportes.ver. Crear(player, ...) permite a otros servicios (StaffService) abrir reportes internos.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Zones = require(Util:WaitForChild("Zones"))
local Format = require(Util:WaitForChild("Format"))

local ReportService = {}
ReportService.Nombre = "ReportService"

local PREFIJO = "[ColegioRP][ReportService]"
local CFG = Config.Reportes or {}

-- Reportes conservados en memoria (los más recientes) para el panel de moderación.
ReportService.MaxEnMemoria = 100
-- Reportes por jugador dentro de la ventana (contador propio, además del límite de RemoteService).
ReportService.MaxPorMinuto = math.max(1, tonumber(CFG.MaxPorMinuto) or 2)
-- Ventana (s) del contador anterior.
ReportService.VentanaSeg = 60
-- Longitudes máximas de los campos de texto.
ReportService.MaxDescripcion = math.max(10, tonumber(CFG.MaxCaracteres) or 300)
ReportService.MaxUbicacion = math.max(10, tonumber(CFG.MaxUbicacionCaracteres) or 60)
-- Caracteres mínimos de la descripción (tras recortar espacios).
ReportService.MinDescripcion = 3
-- Texto guardado cuando el filtro de Roblox no está disponible (el original nunca se muestra a terceros).
ReportService.TextoNoDisponible = "[texto no disponible]"
-- Escrituras de reportes en DataStore por minuto en todo el servidor (protección ante un servicio
-- que cree reportes en bucle); por encima del tope el reporte se conserva solo en memoria.
ReportService.MaxEscriturasPorMinuto = 30
-- Mensaje devuelto al jugador al aceptar su reporte.
ReportService.MensajeRecibido = "Reporte recibido"

-- Nombre legible de cada categoría (avisos a moderación).
ReportService.NombresCategoria = {
	Bug = "Error del juego",
	Abuso = "Conducta / abuso",
	Duda = "Duda",
	Sugerencia = "Sugerencia",
}

local setCategorias = {}
for _, categoria in ipairs(RemoteContracts.CategoriasReporte or { "Bug", "Abuso", "Duda", "Sugerencia" }) do
	setCategorias[categoria] = true
end

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
	local raiz = personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Normaliza un texto escrito por un jugador: UTF-8 válido, sin caracteres de control (salvo salto de
-- línea y tabulador), sin espacios sobrantes y recortado a max caracteres. Devuelve texto | nil si no es válido.
local function sanear(texto, max, permitirSaltos)
	if typeof(texto) ~= "string" then
		return nil
	end
	if utf8.len(texto) == nil then
		return nil
	end
	local limpio = string.gsub(texto, "\r\n", "\n")
	limpio = string.gsub(limpio, "%c", function(c)
		if c == "\t" then
			return " "
		end
		if c == "\n" and permitirSaltos then
			return c
		end
		if c == "\n" then
			return " "
		end
		return ""
	end)
	limpio = string.gsub(limpio, "\n\n\n+", "\n\n")
	limpio = Format.Recortar(limpio)
	if max and Format.Longitud(limpio) > max then
		limpio = Format.Truncar(limpio, max)
	end
	return limpio
end

-- Copia superficial de un reporte apta para enviar al cliente o a otro servicio.
local function copiaReporte(reporte)
	return {
		Id = reporte.Id,
		UserId = reporte.UserId,
		Jugador = reporte.Jugador,
		Nombre = reporte.Nombre,
		Categoria = reporte.Categoria,
		CategoriaNombre = reporte.CategoriaNombre,
		Ubicacion = reporte.Ubicacion,
		Descripcion = reporte.Descripcion,
		Zona = reporte.Zona,
		T = reporte.T,
		Origen = reporte.Origen,
		Persistido = reporte.Persistido,
		Filtrado = reporte.Filtrado,
	}
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function ReportService:Init(registro)
	self.registro = registro
	self.Reportes = {} -- array; el más reciente al final (máx. MaxEnMemoria)
	self.Envios = {} -- userId -> { os.clock() ... } de los reportes enviados por remoto en la ventana
	self.EscriturasGlobales = {} -- { os.clock() ... } escrituras en DataStore en el último minuto
	self.Conexiones = {}
	self.Estadisticas = { Recibidos = 0, Rechazados = 0, Persistidos = 0, SoloMemoria = 0, FiltroFallido = 0 }
	self.ReporteCreado = Signal.new() -- (reporte)
end

function ReportService:Start()
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("ReportSubmit", function(player, datos)
			return self:ManejarEnvio(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: ReportSubmit no tendrá handler.")
	end
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.Envios[player.UserId] = nil
	end))
end

-- Servicio por nombre a través del registro (nil si no existe).
function ReportService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		return registro.Get(nombre)
	end
	return nil
end

-- Llama servicio:metodo(...) en pcall si existe. Devuelve ok, r1, r2.
function ReportService:Llamar(nombreServicio, metodo, ...)
	local servicio = self:Servicio(nombreServicio)
	if not servicio or typeof(servicio[metodo]) ~= "function" then
		return false, nil, nil
	end
	local resultado = table.pack(pcall(servicio[metodo], servicio, ...))
	if not resultado[1] then
		warn(PREFIJO .. " " .. nombreServicio .. ":" .. metodo .. "() falló: " .. tostring(resultado[2]))
		return false, nil, nil
	end
	return true, resultado[2], resultado[3]
end

function ReportService:Auditar(player, accion, detalle)
	self:Llamar("AuditLogService", "Registrar", "Moderacion", player, accion, detalle)
end

---------------------------------------------------------------------------------------------------
-- Filtrado y límites
---------------------------------------------------------------------------------------------------

-- Filtra un texto para mostrarlo a terceros. Devuelve texto filtrado, ok (false si el filtro falló y se
-- sustituyó por TextoNoDisponible). Un texto vacío no se filtra.
function ReportService:Filtrar(texto, userId)
	if texto == "" then
		return "", true
	end
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(texto, userId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFiltro or resultado == nil then
		return self.TextoNoDisponible, false
	end
	local okTexto, filtrado = pcall(function()
		return resultado:GetNonChatStringForBroadcastAsync()
	end)
	if not okTexto or typeof(filtrado) ~= "string" then
		return self.TextoNoDisponible, false
	end
	return filtrado, true
end

-- Contador propio por jugador (Config.Reportes.MaxPorMinuto en VentanaSeg). Devuelve permitido, restanteSeg.
function ReportService:DentroDelLimite(player)
	local userId = player.UserId
	local ahora = os.clock()
	local lista = self.Envios[userId]
	if not lista then
		lista = {}
		self.Envios[userId] = lista
	end
	while lista[1] ~= nil and lista[1] <= ahora - self.VentanaSeg do
		table.remove(lista, 1)
	end
	if #lista >= self.MaxPorMinuto then
		return false, math.max(1, math.ceil(self.VentanaSeg - (ahora - lista[1])))
	end
	return true, 0
end

function ReportService:AnotarEnvio(player)
	local lista = self.Envios[player.UserId]
	if not lista then
		lista = {}
		self.Envios[player.UserId] = lista
	end
	table.insert(lista, os.clock())
end

-- ¿Queda cupo global de escrituras en DataStore este minuto? (lo consume si lo hay)
function ReportService:CupoEscritura()
	local ahora = os.clock()
	local lista = self.EscriturasGlobales
	while lista[1] ~= nil and lista[1] <= ahora - 60 do
		table.remove(lista, 1)
	end
	if #lista >= self.MaxEscriturasPorMinuto then
		return false
	end
	table.insert(lista, ahora)
	return true
end

-- Id de zona en la que está el jugador (MapService:ZonaDe o, si no existe, Util.Zones).
function ReportService:ZonaDe(player)
	local posicion = posicionDe(player)
	if not posicion then
		return nil
	end
	local zona = nil
	local okMapa, resultado = self:Llamar("MapService", "ZonaDe", posicion)
	if okMapa then
		zona = resultado
	else
		local okZona, z = pcall(Zones.ZonaDe, posicion)
		if okZona then
			zona = z
		end
	end
	if typeof(zona) == "table" and typeof(zona.Id) == "string" then
		return zona.Id
	end
	if typeof(zona) == "string" then
		return zona
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Núcleo
---------------------------------------------------------------------------------------------------

-- Crea, guarda y difunde un reporte. player puede ser nil (reporte del sistema).
-- Devuelve true, reporte | false, mensaje.
function ReportService:Procesar(player, categoria, ubicacion, descripcion, origen)
	if not setCategorias[categoria] then
		return false, "Categoría de reporte no válida."
	end
	local ubicacionLimpia = sanear(ubicacion or "", self.MaxUbicacion, false)
	local descripcionLimpia = sanear(descripcion, self.MaxDescripcion, true)
	if ubicacionLimpia == nil or descripcionLimpia == nil then
		return false, "El texto del reporte no es válido."
	end
	if Format.Longitud(descripcionLimpia) < self.MinDescripcion then
		return false, "Describe el problema con al menos " .. self.MinDescripcion .. " caracteres."
	end

	local jugador = esJugador(player) and player or nil
	local userId = jugador and jugador.UserId or 0

	-- Filtrado con TextService (si falla se guarda TextoNoDisponible; nunca el original).
	local filtradoOk = true
	local descripcionFinal, okD = descripcionLimpia, true
	local ubicacionFinal, okU = ubicacionLimpia, true
	if jugador then
		descripcionFinal, okD = self:Filtrar(descripcionLimpia, userId)
		ubicacionFinal, okU = self:Filtrar(ubicacionLimpia, userId)
		filtradoOk = okD and okU
		if not filtradoOk then
			self.Estadisticas.FiltroFallido = self.Estadisticas.FiltroFallido + 1
		end
		-- Si el jugador salió mientras se filtraba, el reporte se conserva igualmente.
	end

	local ahora = os.time()
	local reporte = {
		Id = string.format("R_%d_%d", ahora, userId),
		UserId = userId,
		Jugador = jugador and jugador.Name or "Sistema",
		Nombre = jugador and jugador.DisplayName or "Sistema",
		Categoria = categoria,
		CategoriaNombre = self.NombresCategoria[categoria] or categoria,
		Ubicacion = ubicacionFinal,
		Descripcion = descripcionFinal,
		Zona = jugador and self:ZonaDe(jugador) or nil,
		T = ahora,
		Origen = tostring(origen or "Interno"),
		Filtrado = filtradoOk,
		Persistido = false,
	}
	if jugador then
		local okCargo, cargo = self:Llamar("RoleService", "Cargo", jugador)
		if okCargo and typeof(cargo) == "string" then
			reporte.Cargo = cargo
		end
	end

	-- Persistencia (DataService:GuardarReporte). El id definitivo es la clave que devuelve DataService
	-- (añade un sufijo si coinciden dos reportes del mismo jugador en el mismo segundo).
	local DataService = self:Servicio("DataService")
	if DataService and typeof(DataService.GuardarReporte) == "function" then
		if self:CupoEscritura() then
			local okGuardar, guardado, clave = pcall(DataService.GuardarReporte, DataService, {
				Id = reporte.Id,
				UserId = reporte.UserId,
				Categoria = reporte.Categoria,
				Ubicacion = reporte.Ubicacion,
				Descripcion = reporte.Descripcion,
				Zona = reporte.Zona,
				T = reporte.T,
				Cargo = reporte.Cargo,
				Origen = reporte.Origen,
				Filtrado = reporte.Filtrado,
			})
			if okGuardar and guardado == true then
				reporte.Persistido = true
				if typeof(clave) == "string" and clave ~= "" then
					reporte.Id = clave
				end
				self.Estadisticas.Persistidos = self.Estadisticas.Persistidos + 1
			else
				self.Estadisticas.SoloMemoria = self.Estadisticas.SoloMemoria + 1
				if not okGuardar then
					warn(PREFIJO .. " GuardarReporte falló: " .. tostring(guardado))
				elseif typeof(clave) == "string" then
					warn(PREFIJO .. " El reporte " .. reporte.Id .. " no se pudo persistir: " .. clave)
				end
			end
		else
			self.Estadisticas.SoloMemoria = self.Estadisticas.SoloMemoria + 1
			warn(PREFIJO .. " Tope de escrituras de reportes por minuto alcanzado; " .. reporte.Id .. " queda solo en memoria.")
		end
	else
		self.Estadisticas.SoloMemoria = self.Estadisticas.SoloMemoria + 1
	end

	-- Id único también en memoria (reporte no persistido en el mismo segundo que otro del mismo autor).
	if self:Obtener(reporte.Id) ~= nil then
		local base = reporte.Id
		local sufijo = 1
		while self:Obtener(base .. "_m" .. sufijo) ~= nil do
			sufijo = sufijo + 1
		end
		reporte.Id = base .. "_m" .. sufijo
	end

	-- Memoria (últimos MaxEnMemoria).
	table.insert(self.Reportes, reporte)
	while #self.Reportes > self.MaxEnMemoria do
		table.remove(self.Reportes, 1)
	end
	self.Estadisticas.Recibidos = self.Estadisticas.Recibidos + 1

	self:Auditar(jugador, "Reporte", string.format("%s · %s · %s%s · %s", reporte.Id, categoria,
		reporte.Ubicacion ~= "" and reporte.Ubicacion or "(sin ubicación)",
		reporte.Zona and (" [" .. reporte.Zona .. "]") or "", Format.Truncar(reporte.Descripcion, 160)))

	self:AvisarModeracion(reporte, jugador)

	local okSenal, errSenal = pcall(function()
		self.ReporteCreado:Fire(copiaReporte(reporte))
	end)
	if not okSenal then
		warn(PREFIJO .. " Error en un oyente de ReporteCreado: " .. tostring(errSenal))
	end
	return true, reporte
end

-- Aviso a quien tenga reportes.ver (canal Moderacion, Sub = "Reporte"); el autor no se avisa a sí mismo.
function ReportService:AvisarModeracion(reporte, autor)
	local RemoteService = self:Servicio("RemoteService")
	if not RemoteService or typeof(RemoteService.Enviar) ~= "function" then
		return 0
	end
	local okLista, lista = self:Llamar("RoleService", "ConPermiso", "reportes.ver")
	if not okLista or typeof(lista) ~= "table" then
		return 0
	end
	local avisados = 0
	local resumen = copiaReporte(reporte)
	for _, moderador in ipairs(lista) do
		if esJugador(moderador) and moderador ~= autor and moderador.Parent ~= nil then
			local ok = pcall(RemoteService.Enviar, RemoteService, moderador, "Moderacion", { Sub = "Reporte", Reporte = resumen })
			if ok then
				avisados = avisados + 1
			end
		end
	end
	return avisados
end

---------------------------------------------------------------------------------------------------
-- Handler de ReportSubmit (RemoteService ya validó tabla, esquema y límite 2/60 s)
---------------------------------------------------------------------------------------------------
function ReportService:ManejarEnvio(player, datos)
	local permitido, restante = self:DentroDelLimite(player)
	if not permitido then
		self.Estadisticas.Rechazados = self.Estadisticas.Rechazados + 1
		self:Auditar(player, "ReporteRechazado", "límite de " .. self.MaxPorMinuto .. " reportes por minuto")
		local respuesta = RemoteContracts.Error("Has enviado " .. self.MaxPorMinuto .. " reportes en el último minuto. Espera " .. restante .. " s.")
		respuesta.datos = { RestanteSeg = restante }
		return respuesta
	end
	if not setCategorias[datos.Categoria] then
		self.Estadisticas.Rechazados = self.Estadisticas.Rechazados + 1
		return RemoteContracts.Error("Categoría de reporte no válida.")
	end
	-- El envío cuenta para el límite aunque el contenido resulte inválido (evita sondeos en bucle).
	self:AnotarEnvio(player)
	local ok, resultado = self:Procesar(player, datos.Categoria, datos.Ubicacion, datos.Descripcion, "Formulario")
	if not ok then
		self.Estadisticas.Rechazados = self.Estadisticas.Rechazados + 1
		return RemoteContracts.Error(resultado)
	end
	return RemoteContracts.Ok({
		Id = resultado.Id,
		Mensaje = self.MensajeRecibido,
		Categoria = resultado.Categoria,
		Persistido = resultado.Persistido,
	})
end

---------------------------------------------------------------------------------------------------
-- API para otros servicios
---------------------------------------------------------------------------------------------------

-- Crea un reporte interno (sin el contador por jugador del formulario). player puede ser nil.
-- Devuelve true, id | false, mensaje.
function ReportService:Crear(player, categoria, ubicacion, descripcion)
	if player ~= nil and not esJugador(player) then
		return false, "Jugador no válido."
	end
	local ok, resultado = self:Procesar(player, categoria, ubicacion, descripcion, "Interno")
	if not ok then
		return false, resultado
	end
	return true, resultado.Id
end

-- Últimos n reportes en memoria (el más reciente primero). filtro opcional: { Categoria, UserId }.
function ReportService:Listar(n, filtro)
	n = math.clamp(math.floor(tonumber(n) or 30), 1, self.MaxEnMemoria)
	local lista = {}
	for i = #self.Reportes, 1, -1 do
		if #lista >= n then
			break
		end
		local reporte = self.Reportes[i]
		local pasa = true
		if typeof(filtro) == "table" then
			if filtro.Categoria ~= nil and reporte.Categoria ~= filtro.Categoria then
				pasa = false
			end
			if filtro.UserId ~= nil and reporte.UserId ~= filtro.UserId then
				pasa = false
			end
		end
		if pasa then
			table.insert(lista, copiaReporte(reporte))
		end
	end
	return lista
end

-- Reporte en memoria por id (copia) o nil.
function ReportService:Obtener(id)
	if typeof(id) ~= "string" then
		return nil
	end
	for i = #self.Reportes, 1, -1 do
		if self.Reportes[i].Id == id then
			return copiaReporte(self.Reportes[i])
		end
	end
	return nil
end

-- Resumen para paneles y métricas.
function ReportService:Snapshot()
	local porCategoria = {}
	for categoria in pairs(setCategorias) do
		porCategoria[categoria] = 0
	end
	for _, reporte in ipairs(self.Reportes) do
		porCategoria[reporte.Categoria] = (porCategoria[reporte.Categoria] or 0) + 1
	end
	return {
		EnMemoria = #self.Reportes,
		PorCategoria = porCategoria,
		Recibidos = self.Estadisticas.Recibidos,
		Rechazados = self.Estadisticas.Rechazados,
		Persistidos = self.Estadisticas.Persistidos,
		SoloMemoria = self.Estadisticas.SoloMemoria,
		FiltroFallido = self.Estadisticas.FiltroFallido,
		Ultimos = self:Listar(5),
	}
end

ReportService.ObtenerEstadisticas = ReportService.Snapshot

return ReportService
