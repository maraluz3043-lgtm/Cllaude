--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.AnnouncementService
	Tipo: ModuleScript
	Avisos oficiales (docs/ARQUITECTURA.md §6): Anunciar(player|nil, texto, alcance, roomId) filtra el texto
	con TextService, lo limita a Config.Limites.MaxAvisoCaracteres y lo emite por EventoCliente "Aviso"
	{ Texto, Autor, Cargo, T, Alcance } a todo el servidor (Global) o a la zona del aula (Aula). Atiende
	AnnouncementBroadcast (Aula: docente de la sesión abierta) y crea el TextChatCommand /anuncio (alias /h),
	validado en el servidor con anuncios.global y limitado a 1 uso cada 15 s. Guarda los 10 últimos avisos
	globales (Ultimos / Historial) para el snapshot de los clientes que entran después.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Format = require(Util:WaitForChild("Format"))

local AnnouncementService = {}
AnnouncementService.Nombre = "AnnouncementService"

local PREFIJO = "[ColegioRP][AnnouncementService]"
local CHAT = Config.Chat or {}

-- Longitud máxima de un aviso (caracteres).
AnnouncementService.MaxCaracteres = math.max(10, tonumber(Config.Limites and Config.Limites.MaxAvisoCaracteres) or 160)
-- Avisos globales conservados para el snapshot (Ultimos / Historial).
AnnouncementService.MaxHistorial = math.max(1, tonumber(CHAT.HistorialAnuncios) or 10)
-- Avisos de aula conservados por aula (solo se devuelven al pedir Ultimos(roomId)).
AnnouncementService.MaxHistorialAula = 5
-- Segundos mínimos entre usos del comando de chat por el mismo jugador.
AnnouncementService.CooldownComandoSeg = 15
-- Nombre de la instancia TextChatCommand y alias.
AnnouncementService.NombreComando = "ColegioRP_Anuncio"
AnnouncementService.AliasPrincipal = CHAT.ComandoAnuncio or "/anuncio"
AnnouncementService.AliasSecundario = CHAT.AliasAnuncio or "/h"
-- Prefijo de los mensajes de sistema del chat.
AnnouncementService.PrefijoSistema = "[Colegio] "
-- Autor mostrado en los avisos del sistema (Anunciar sin jugador).
AnnouncementService.AutorSistema = Config.NombreCorto or "Colegio"

local ALCANCES = { Global = true, Aula = true }

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

-- Texto de una línea: UTF-8 válido, sin caracteres de control, sin espacios repetidos. nil si no es válido.
local function limpiar(texto)
	if typeof(texto) ~= "string" or utf8.len(texto) == nil then
		return nil
	end
	local limpio = string.gsub(texto, "%c", " ")
	limpio = string.gsub(limpio, "%s%s+", " ")
	return Format.Recortar(limpio)
end

local function copiaAviso(aviso)
	return {
		Id = aviso.Id, Texto = aviso.Texto, Autor = aviso.Autor, Cargo = aviso.Cargo, T = aviso.T,
		Alcance = aviso.Alcance, RoomId = aviso.RoomId, Oficial = aviso.Oficial,
	}
end

-- Quita el alias del comando al principio del mensaje ("/anuncio Hola" -> "Hola").
local function sinAlias(texto, alias)
	local resultado = texto
	for _, a in ipairs(alias) do
		if typeof(a) == "string" and a ~= "" then
			local n = #a
			if string.lower(string.sub(resultado, 1, n)) == string.lower(a) then
				local siguiente = string.sub(resultado, n + 1, n + 1)
				if siguiente == "" or string.match(siguiente, "%s") then
					return string.sub(resultado, n + 1)
				end
			end
		end
	end
	return resultado
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function AnnouncementService:Init(registro)
	self.registro = registro
	self.Historial = {} -- avisos globales (el más reciente al final)
	self.HistorialAula = {} -- roomId -> avisos de aula
	self.UltimoComando = {} -- userId -> os.clock() del último /anuncio aceptado
	self.Contador = 0
	self.Conexiones = {}
	self.Comando = nil
	self.Anunciado = Signal.new() -- (aviso)
end

function AnnouncementService:Start()
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("AnnouncementBroadcast", function(player, datos)
			return self:ManejarRemoto(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: AnnouncementBroadcast no tendrá handler.")
	end

	local ok, err = pcall(function()
		self:CrearComando()
	end)
	if not ok then
		warn(PREFIJO .. " No se pudo crear el comando de chat " .. tostring(self.AliasPrincipal) .. ": " .. tostring(err))
	end

	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self.UltimoComando[player.UserId] = nil
	end))
end

-- Servicio por nombre a través del registro (nil si no existe).
function AnnouncementService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		return registro.Get(nombre)
	end
	return nil
end

-- Llama servicio:metodo(...) en pcall si existe. Devuelve ok, r1, r2.
function AnnouncementService:Llamar(nombreServicio, metodo, ...)
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

function AnnouncementService:Auditar(categoria, player, accion, detalle)
	self:Llamar("AuditLogService", "Registrar", categoria, player, accion, detalle)
end

---------------------------------------------------------------------------------------------------
-- Filtrado y difusión
---------------------------------------------------------------------------------------------------

-- Filtra el texto para todo el servidor. Devuelve true, filtrado | false, mensaje (nunca el original).
function AnnouncementService:Filtrar(texto, player)
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(texto, player.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFiltro or resultado == nil then
		return false, "No se pudo filtrar el texto. Inténtalo de nuevo en unos segundos."
	end
	local okTexto, filtrado = pcall(function()
		return resultado:GetNonChatStringForBroadcastAsync()
	end)
	if not okTexto or typeof(filtrado) ~= "string" then
		return false, "No se pudo filtrar el texto. Inténtalo de nuevo en unos segundos."
	end
	return true, filtrado
end

-- Id de la zona física de un aula (MapService:Aula(roomId).Zona o, si no, el propio roomId).
function AnnouncementService:ZonaDeAula(roomId)
	local ok, aula = self:Llamar("MapService", "Aula", roomId)
	if ok and typeof(aula) == "table" then
		local zona = aula.Zona
		if typeof(zona) == "table" and typeof(zona.Id) == "string" then
			return zona.Id
		end
		if typeof(zona) == "string" and zona ~= "" then
			return zona
		end
	end
	return roomId
end

-- Envía el aviso de aula a los jugadores de su zona y, además, al emisor si no está dentro.
function AnnouncementService:EnviarAula(roomId, datos, emisor)
	local RemoteService = self:Servicio("RemoteService")
	if not RemoteService then
		return 0
	end
	local zonaId = self:ZonaDeAula(roomId)
	if typeof(RemoteService.JugadoresEnZona) == "function" and typeof(RemoteService.EnviarALista) == "function" then
		local okLista, lista = pcall(RemoteService.JugadoresEnZona, RemoteService, zonaId)
		if okLista and typeof(lista) == "table" then
			local incluido = false
			for _, p in ipairs(lista) do
				if p == emisor then
					incluido = true
				end
			end
			if esJugador(emisor) and not incluido then
				table.insert(lista, emisor)
			end
			local okEnvio, enviados = pcall(RemoteService.EnviarALista, RemoteService, lista, "Aviso", datos)
			if okEnvio and typeof(enviados) == "number" then
				return enviados
			end
			return 0
		end
	end
	local okZona, enviados = self:Llamar("RemoteService", "EnviarAZona", zonaId, "Aviso", datos)
	local total = (okZona and typeof(enviados) == "number") and enviados or 0
	if esJugador(emisor) then
		self:Llamar("RemoteService", "Enviar", emisor, "Aviso", datos)
		total = total + 1
	end
	return total
end

-- Publica un aviso. player nil = aviso del sistema (texto definido por el juego, sin filtrar).
-- alcance: "Global" (por defecto) | "Aula" (requiere roomId). Devuelve true, nil, aviso | false, mensaje.
function AnnouncementService:Anunciar(player, texto, alcance, roomId)
	if player ~= nil and not esJugador(player) then
		return false, "Jugador no válido."
	end
	alcance = alcance or "Global"
	if not ALCANCES[alcance] then
		return false, "Alcance de aviso no válido."
	end
	if alcance == "Aula" and (typeof(roomId) ~= "string" or roomId == "") then
		return false, "Falta el aula del aviso."
	end
	local limpio = limpiar(texto)
	if limpio == nil then
		return false, "El texto del aviso no es válido."
	end
	if limpio == "" then
		return false, "Escribe el texto del aviso."
	end
	if Format.Longitud(limpio) > self.MaxCaracteres then
		limpio = Format.Truncar(limpio, self.MaxCaracteres)
	end

	local final = limpio
	local autor = self.AutorSistema
	local cargo = nil
	if player then
		local okFiltro, filtrado = self:Filtrar(limpio, player)
		if not okFiltro then
			self:Auditar("Sistema", player, "AnuncioRechazado", "filtro no disponible")
			return false, filtrado
		end
		final = filtrado
		if Format.Recortar(final) == "" then
			return false, "El aviso quedó vacío tras el filtrado."
		end
		autor = player.DisplayName ~= "" and player.DisplayName or player.Name
		local okCargo, c = self:Llamar("RoleService", "Cargo", player)
		if okCargo and RoleDefinitions.Existe(c) then
			cargo = c
		end
	end

	self.Contador = self.Contador + 1
	local aviso = {
		Id = self.Contador,
		Texto = final,
		Autor = autor,
		Cargo = cargo,
		T = os.time(),
		Alcance = alcance,
		RoomId = alcance == "Aula" and roomId or nil,
		Oficial = player == nil,
	}
	local datos = copiaAviso(aviso)

	local enviados = 0
	if alcance == "Global" then
		local okTodos, enviado = self:Llamar("RemoteService", "EnviarATodos", "Aviso", datos)
		if okTodos and enviado == true then
			enviados = #Players:GetPlayers()
		end
		table.insert(self.Historial, aviso)
		while #self.Historial > self.MaxHistorial do
			table.remove(self.Historial, 1)
		end
	else
		enviados = self:EnviarAula(roomId, datos, player)
		local lista = self.HistorialAula[roomId]
		if not lista then
			lista = {}
			self.HistorialAula[roomId] = lista
		end
		table.insert(lista, aviso)
		while #lista > self.MaxHistorialAula do
			table.remove(lista, 1)
		end
	end

	local detalle = alcance .. (roomId and alcance == "Aula" and (" " .. roomId) or "") .. " · " .. enviados .. " destinatarios · " .. final
	self:Auditar(alcance == "Aula" and "Clase" or "Sistema", player, "Anuncio", detalle)
	local okSenal, errSenal = pcall(function()
		self.Anunciado:Fire(copiaAviso(aviso))
	end)
	if not okSenal then
		warn(PREFIJO .. " Error en un oyente de Anunciado: " .. tostring(errSenal))
	end
	return true, nil, copiaAviso(aviso)
end

-- Últimos avisos (copias, el más antiguo primero). Sin roomId: solo los globales; con roomId: los de esa aula.
function AnnouncementService:Ultimos(roomId)
	local origen = self.Historial
	if typeof(roomId) == "string" then
		origen = self.HistorialAula[roomId] or {}
	end
	local lista = {}
	for _, aviso in ipairs(origen) do
		table.insert(lista, copiaAviso(aviso))
	end
	return lista
end

-- Alias usado por RemoteService:ConstruirSnapshot y SchoolDayService.
function AnnouncementService:Historial()
	return self:Ultimos()
end

function AnnouncementService:Snapshot()
	return self:Ultimos()
end

---------------------------------------------------------------------------------------------------
-- Comprobaciones comunes (remoto y comando)
---------------------------------------------------------------------------------------------------
function AnnouncementService:EstaSilenciado(player)
	local ok, silenciado = self:Llamar("ModerationService", "EstaSilenciado", player)
	if ok then
		return silenciado == true
	end
	return player:GetAttribute("Silenciado") == true
end

-- Aula de la sesión que dirige el jugador (ClassroomService). Devuelve roomId | nil, mensaje.
function AnnouncementService:AulaDelDocente(player)
	local ClassroomService = self:Servicio("ClassroomService")
	if not ClassroomService or typeof(ClassroomService.SesionDeJugador) ~= "function" then
		return nil, "Las sesiones de clase no están disponibles; no se puede enviar un aviso al aula."
	end
	local ok, sesion = pcall(ClassroomService.SesionDeJugador, ClassroomService, player)
	if not ok or typeof(sesion) ~= "table" or typeof(sesion.RoomId) ~= "string" then
		return nil, "Para enviar un aviso al aula debes tener una sesión de clase abierta."
	end
	local esDocente = sesion.TeacherUserId == player.UserId
	if typeof(ClassroomService.EsDocenteDe) == "function" then
		local okDocente, resultado = pcall(ClassroomService.EsDocenteDe, ClassroomService, player, sesion.RoomId)
		if okDocente then
			esDocente = resultado == true
		end
	end
	if not esDocente then
		return nil, "Solo el docente que dirige la sesión puede enviar avisos a esta aula."
	end
	return sesion.RoomId
end

---------------------------------------------------------------------------------------------------
-- Handler de AnnouncementBroadcast (RemoteService ya validó esquema, límite 2/30 s y permiso:
-- anuncios.global para Global, anuncios.aula para Aula)
---------------------------------------------------------------------------------------------------
function AnnouncementService:ManejarRemoto(player, datos)
	if self:EstaSilenciado(player) then
		self:Auditar("Moderacion", player, "AnuncioRechazado", "jugador silenciado")
		return RemoteContracts.Error("Estás silenciado/a: no puedes publicar avisos.")
	end
	local alcance = datos.Alcance
	local roomId = nil
	if alcance == "Aula" then
		local aula, err = self:AulaDelDocente(player)
		if not aula then
			self:Auditar("Clase", player, "AnuncioRechazado", "Aula: " .. tostring(err))
			return RemoteContracts.Error(err)
		end
		roomId = aula
	elseif alcance ~= "Global" then
		return RemoteContracts.Error("Alcance de aviso no válido.")
	end
	local ok, err, aviso = self:Anunciar(player, datos.Texto, alcance, roomId)
	if not ok then
		return RemoteContracts.Error(err)
	end
	return RemoteContracts.Ok({
		Anuncio = aviso,
		Texto = aviso.Texto,
		Alcance = alcance,
		RoomId = roomId,
		Mensaje = alcance == "Aula" and ("Aviso enviado al aula " .. roomId .. ".") or "Anuncio enviado a todo el colegio.",
	})
end

---------------------------------------------------------------------------------------------------
-- Comando de chat /anuncio (TextChatService)
---------------------------------------------------------------------------------------------------
function AnnouncementService:CrearComando()
	local okServicio, tcs = pcall(game.GetService, game, "TextChatService")
	if not okServicio or not tcs then
		warn(PREFIJO .. " TextChatService no disponible: se omite el comando " .. tostring(self.AliasPrincipal) .. ".")
		return
	end
	local okVersion, version = pcall(function()
		return tcs.ChatVersion
	end)
	if not okVersion or version ~= Enum.ChatVersion.TextChatService then
		warn(PREFIJO .. " El lugar no usa TextChatService (ChatVersion = " .. tostring(version)
			.. "): se omite el comando " .. tostring(self.AliasPrincipal) .. ". Usa el panel de dirección para anunciar.")
		return
	end
	self.TextChatService = tcs

	-- Idempotente: se reutiliza el comando si ya existe (reinicio de servicios o instalación repetida).
	local comando = nil
	for _, d in ipairs(tcs:GetDescendants()) do
		if d:IsA("TextChatCommand") and d.Name == self.NombreComando then
			comando = d
		end
	end
	if not comando then
		comando = Instance.new("TextChatCommand")
		comando.Name = self.NombreComando
	end
	comando.PrimaryAlias = self.AliasPrincipal
	comando.SecondaryAlias = self.AliasSecundario
	local carpeta = tcs:FindFirstChild("TextChatCommands")
	if carpeta then
		comando.Parent = carpeta
	else
		comando.Parent = tcs
	end
	self.Comando = comando
	table.insert(self.Conexiones, comando.Triggered:Connect(function(fuente, mensaje)
		task.spawn(function()
			local ok, err = pcall(function()
				self:AlComando(fuente, mensaje)
			end)
			if not ok then
				warn(PREFIJO .. " Error en el comando " .. tostring(self.AliasPrincipal) .. ": " .. tostring(err))
			end
		end)
	end))
end

-- Respuesta privada al emisor del comando: mensaje de sistema del chat o, si no es posible desde el
-- servidor, notificación del HUD.
function AnnouncementService:ResponderChat(player, fuente, texto, nivel)
	local mostrado = false
	local canal = fuente and fuente.Parent
	if typeof(canal) == "Instance" and canal:IsA("TextChannel") then
		local ok = pcall(function()
			canal:DisplaySystemMessage(self.PrefijoSistema .. texto)
		end)
		mostrado = ok
	end
	if not mostrado then
		self:Llamar("RemoteService", "Enviar", player, "Notificacion", {
			Titulo = "Anuncios", Texto = texto, Nivel = nivel or "info", Tipo = nivel or "info",
		})
	end
end

function AnnouncementService:AlComando(fuente, mensaje)
	if typeof(fuente) ~= "Instance" or not fuente:IsA("TextSource") then
		return
	end
	local player = Players:GetPlayerByUserId(fuente.UserId)
	if not player then
		return
	end
	local okTiene, tiene = self:Llamar("RoleService", "Tiene", player, "anuncios.global")
	if not okTiene or tiene ~= true then
		self:Auditar("Remoto", player, "ComandoAnuncio", "rechazado: sin permiso anuncios.global")
		self:ResponderChat(player, fuente, "No tienes permiso para enviar anuncios.", "error")
		return
	end
	if self:EstaSilenciado(player) then
		self:Auditar("Moderacion", player, "AnuncioRechazado", "jugador silenciado (comando)")
		self:ResponderChat(player, fuente, "Estás silenciado/a: no puedes publicar anuncios.", "error")
		return
	end
	local userId = player.UserId
	local ultimo = self.UltimoComando[userId]
	if ultimo and os.clock() - ultimo < self.CooldownComandoSeg then
		local espera = math.ceil(self.CooldownComandoSeg - (os.clock() - ultimo))
		self:ResponderChat(player, fuente, "Espera " .. espera .. " s antes de enviar otro anuncio.", "aviso")
		return
	end
	local texto = typeof(mensaje) == "string" and mensaje or ""
	texto = sinAlias(Format.Recortar(texto), { self.AliasPrincipal, self.AliasSecundario })
	texto = limpiar(texto)
	if texto == nil then
		self:ResponderChat(player, fuente, "El texto del anuncio no es válido.", "error")
		return
	end
	if texto == "" then
		self:ResponderChat(player, fuente, "Uso: " .. tostring(self.AliasPrincipal) .. " <mensaje>", "info")
		return
	end
	if Format.Longitud(texto) > self.MaxCaracteres then
		self:ResponderChat(player, fuente, "El anuncio admite como máximo " .. self.MaxCaracteres .. " caracteres.", "aviso")
		return
	end
	self.UltimoComando[userId] = os.clock()
	local ok, err = self:Anunciar(player, texto, "Global", nil)
	if not ok then
		self:ResponderChat(player, fuente, tostring(err), "error")
		return
	end
	self:ResponderChat(player, fuente, "Anuncio enviado a todo el colegio.", "exito")
end

return AnnouncementService
