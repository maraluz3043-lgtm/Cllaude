--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.ModerationService
	Tipo: ModuleScript
	Moderación del servidor (docs/ARQUITECTURA.md §6): atiende ModerationAction (Silenciar, QuitarSilencio,
	Advertir, VerRegistro, Expulsar, BloquearTemporal, AsignarCargo, RevocarCargo, ConfirmarAccion).
	Las acciones críticas (Expulsar, BloquearTemporal, RevocarCargo) van en DOS PASOS: la primera petición
	devuelve un Token de un solo uso (caduca a los Config.Moderacion.TokenConfirmacionSeg) y la segunda, con
	ese Token, la ejecuta con los parámetros guardados en el servidor. Nunca se actúa sobre uno mismo ni sobre
	un cargo superior (Director > Subdirector > Coordinadores > resto). Silencio: TextSource.CanSend = false en
	los TextChannel no privados de TextChatService + atributo Silenciado con caducidad; bloqueo temporal en
	Perfil.Moderacion.BloqueoHasta (se expulsa al entrar mientras siga vigente); advertencias en el perfil.
	Integración opcional de solo lectura con Adonis (_G.Adonis.CheckAdmin -> moderacion.basica). Todo se audita.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))
local Format = require(Util:WaitForChild("Format"))

local ModerationService = {}
ModerationService.Nombre = "ModerationService"

local PREFIJO = "[ColegioRP][ModerationService]"
local CFG = Config.Moderacion or {}
local AUT = Config.Autorizaciones or {}
local LIMITES = Config.Limites or {}

-- Duración por defecto de un silencio y de un bloqueo temporal (s).
ModerationService.DuracionMuteSeg = tonumber(CFG.DuracionMuteSeg) or 300
ModerationService.DuracionBloqueoSeg = tonumber(CFG.DuracionBloqueoTemporalSeg) or 1800
-- Límites de duración aceptados (coinciden con el esquema DuracionSeg de ModerationAction).
ModerationService.DuracionMinSeg = 10
ModerationService.DuracionMaxSeg = 86400
-- Validez del token de confirmación de las acciones críticas (s).
ModerationService.TokenSeg = math.max(5, tonumber(CFG.TokenConfirmacionSeg) or 30)
-- Tokens pendientes por administrador (el más antiguo se descarta al superar el máximo).
ModerationService.MaxTokensPorAdmin = 5
-- Tiempo (s) que un token vencido sigue guardado solo para informar de su caducidad.
ModerationService.GraciaTokenSeg = 120
-- Advertencias conservadas en el perfil.
ModerationService.MaxAdvertencias = math.max(1, tonumber(CFG.MaxAdvertencias) or 20)
-- Motivo: longitud mínima (acciones sancionadoras) y máxima.
ModerationService.MinMotivo = 3
ModerationService.MaxMotivo = tonumber(LIMITES.MaxMotivoCaracteres) or 120
-- Acciones de moderación conservadas en memoria (Registro).
ModerationService.MaxRegistro = 200
-- Segundos en los que se ignora la repetición exacta (mismo admin, acción y objetivo): evita dobles clics.
ModerationService.AntiRepeticionSeg = 2
-- Espera máxima del perfil al entrar para comprobar un bloqueo temporal.
ModerationService.EsperaPerfilSeg = 30
-- Espera máxima del perfil del objetivo al bloquear o advertir.
ModerationService.EsperaPerfilAccionSeg = 5
-- Intervalo del barrido de silencios y tokens caducados.
ModerationService.BarridoSeg = 15
-- Vigencia de la caché de la consulta a Adonis.
ModerationService.CacheAdonisSeg = 30
-- Texto usado cuando el filtro de Roblox no está disponible.
ModerationService.TextoNoDisponible = "[motivo no disponible]"

-- Permiso necesario por acción (RemoteService ya aplica el de RemoteContracts; aquí se vuelve a comprobar,
-- sobre todo para ConfirmarAccion, que en el contrato solo exige moderacion.basica).
ModerationService.Permisos = {
	Silenciar = "moderacion.basica",
	QuitarSilencio = "moderacion.basica",
	Advertir = "moderacion.basica",
	VerRegistro = "moderacion.basica",
	Expulsar = "moderacion.avanzada",
	BloquearTemporal = "moderacion.avanzada",
	AsignarCargo = "cargos.asignar",
	RevocarCargo = "cargos.revocar",
}
-- Acciones que requieren confirmación en dos pasos.
ModerationService.Criticas = { Expulsar = true, BloquearTemporal = true, RevocarCargo = true }
-- Acciones con motivo obligatorio (mín. MinMotivo caracteres).
ModerationService.MotivoObligatorio = { Silenciar = true, Expulsar = true, BloquearTemporal = true, Advertir = true }
-- Motivo por defecto de las acciones donde es opcional.
ModerationService.MotivoPorDefecto = {
	QuitarSilencio = "Fin del silencio",
	AsignarCargo = "Asignación de cargo",
	RevocarCargo = "Revocación de cargo",
}
-- Nombres legibles de las acciones.
ModerationService.Etiquetas = {
	Silenciar = "Silenciar",
	QuitarSilencio = "Quitar el silencio",
	Advertir = "Advertir",
	VerRegistro = "Ver registro",
	Expulsar = "Expulsar del servidor",
	BloquearTemporal = "Bloquear temporalmente",
	AsignarCargo = "Asignar cargo",
	RevocarCargo = "Revocar el cargo",
}

-- Jerarquía de moderación: nadie actúa sobre un cargo superior al suyo.
local RANGO_CARGO = { Director = 4, Subdirector = 3, CoordinadorAcademico = 2, CoordinadorConvivencia = 2 }
local RANGO_RESTO = 1

-- Motivos de RoleService:AsignarPorAdmin / Revocar traducidos para el panel.
local TEXTOS_ROLES = {
	jugador_invalido = "El jugador no está conectado.",
	cargo_invalido = "Cargo desconocido.",
	sin_permiso = "No tienes permiso para gestionar cargos.",
	cargo_no_asignable = "Tu cargo no puede asignar ese cargo.",
	auto_superior = "No puedes asignarte un cargo superior al tuyo.",
	objetivo_superior = "No puedes actuar sobre alguien con un cargo superior al tuyo.",
	sin_cargo = "Esa persona no tiene ningún cargo que revocar.",
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function resolverJugador(valor)
	if esJugador(valor) then
		return valor
	end
	if typeof(valor) == "number" then
		return Players:GetPlayerByUserId(valor)
	end
	return nil
end

local function userIdDe(valor)
	if esJugador(valor) then
		return valor.UserId
	end
	if typeof(valor) == "number" then
		return valor
	end
	return nil
end

-- "Nombre mostrado (@usuario)".
local function nombreDe(player)
	if not esJugador(player) then
		return "Sistema"
	end
	if player.DisplayName ~= "" and player.DisplayName ~= player.Name then
		return player.DisplayName .. " (@" .. player.Name .. ")"
	end
	return player.Name
end

-- Texto de una línea, UTF-8 válido, sin caracteres de control y recortado. nil si no es texto válido.
local function limpiarLinea(texto, max)
	if typeof(texto) ~= "string" or utf8.len(texto) == nil then
		return nil
	end
	local limpio = string.gsub(texto, "%c", " ")
	limpio = string.gsub(limpio, "%s%s+", " ")
	limpio = Format.Recortar(limpio)
	if max and Format.Longitud(limpio) > max then
		limpio = Format.Truncar(limpio, max)
	end
	return limpio
end

local function copiaPlana(tabla)
	local copia = {}
	for clave, valor in pairs(tabla) do
		local tipo = typeof(valor)
		if tipo == "string" or tipo == "number" or tipo == "boolean" then
			copia[clave] = valor
		end
	end
	return copia
end

-- Token aleatorio de un solo uso (GUID; respaldo con Random si HttpService fallara).
local generador = Random.new()
local function generarToken()
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and typeof(guid) == "string" and #guid >= 16 then
		return guid
	end
	local partes = {}
	for i = 1, 32 do
		partes[i] = string.format("%x", generador:NextInteger(0, 15))
	end
	return table.concat(partes)
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function ModerationService:Init(registro)
	self.registro = registro
	self.Silencios = {} -- userId -> { Id, Hasta, Desde, Motivo, PorUserId, PorNombre }
	self.FuentesSilenciadas = {} -- userId -> { [TextSource] = CanSend original }
	self.Bloqueos = {} -- userId -> { Hasta, Motivo } (respaldo en memoria del bloqueo temporal)
	self.AdvertenciasMemoria = {} -- userId -> número de advertencias si el perfil no estaba disponible
	self.Tokens = {} -- token -> { Accion, AdminUserId, ObjetivoUserId, Motivo, DuracionSeg, Cargo, Expira, Creado }
	self.Registros = {} -- acciones de moderación (la más reciente al final)
	self.UltimaAccion = {} -- "admin:accion:objetivo" -> os.clock()
	self.CacheAdonis = {} -- userId -> { Valor, T }
	self.Maids = {} -- userId -> Maid
	self.Conexiones = {}
	self.ContadorSilencios = 0
	self.ContadorRegistro = 0
	self.Activo = true
	self.ChatModerno = false
	self.TextChatService = nil
	self.AccionAplicada = Signal.new() -- (accion, admin|nil, objetivoUserId, info)
end

function ModerationService:Start()
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("ModerationAction", function(player, datos)
			return self:ManejarAccion(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: ModerationAction no tendrá handler.")
	end

	local okChat, errChat = pcall(function()
		self:PrepararChat()
	end)
	if not okChat then
		warn(PREFIJO .. " No se pudo preparar TextChatService: " .. tostring(errChat))
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

	task.spawn(function()
		while self.Activo do
			task.wait(self.BarridoSeg)
			local ok, err = pcall(function()
				self:Barrido()
			end)
			if not ok then
				warn(PREFIJO .. " Error en el barrido: " .. tostring(err))
			end
		end
	end)
end

-- Servicio por nombre a través del registro (nil si no existe).
function ModerationService:Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		return registro.Get(nombre)
	end
	return nil
end

-- Llama servicio:metodo(...) en pcall si existe. Devuelve ok, r1, r2 (ok = false si no existe o falló).
function ModerationService:Llamar(nombreServicio, metodo, ...)
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

function ModerationService:Auditar(admin, accion, detalle)
	self:Llamar("AuditLogService", "Registrar", "Moderacion", admin, accion, detalle)
end

function ModerationService:Enviar(player, tipo, datos)
	if not esJugador(player) or player.Parent == nil then
		return false
	end
	local ok, enviado = self:Llamar("RemoteService", "Enviar", player, tipo, datos)
	return ok and enviado == true
end

function ModerationService:Notificar(player, titulo, texto, nivel, duracion)
	return self:Enviar(player, "Notificacion", {
		Titulo = titulo, Texto = texto, Nivel = nivel or "info", Tipo = nivel or "info", Duracion = duracion,
	})
end

---------------------------------------------------------------------------------------------------
-- Entrada y salida de jugadores
---------------------------------------------------------------------------------------------------
function ModerationService:AlEntrar(player)
	if not esJugador(player) then
		return
	end
	local userId = player.UserId
	if self.Maids[userId] then
		self.Maids[userId]:DoCleaning()
	end
	local maid = Maid.new()
	self.Maids[userId] = maid

	-- Bloqueo en memoria de este servidor (inmediato, sin esperar al perfil).
	local bloqueo = self.Bloqueos[userId]
	if bloqueo and bloqueo.Hasta > os.time() then
		self:ExpulsarPorBloqueo(player, bloqueo.Hasta)
		return
	end

	-- Silencio vigente al reconectar en el mismo servidor.
	local silencio = self:SilencioActivo(userId)
	if silencio then
		pcall(function()
			player:SetAttribute("Silenciado", true)
			player:SetAttribute("SilenciadoHasta", silencio.Hasta)
		end)
		self:AplicarSilencioChat(userId, true)
	end

	-- Bloqueo temporal guardado en el perfil.
	maid:GiveTask(task.spawn(function()
		local ok, perfil = self:Llamar("DataService", "EsperarPerfil", player, self.EsperaPerfilSeg)
		if not ok or typeof(perfil) ~= "table" or player.Parent == nil or self.Maids[userId] ~= maid then
			return
		end
		local moderacion = perfil.Moderacion
		local hasta = typeof(moderacion) == "table" and tonumber(moderacion.BloqueoHasta) or 0
		if hasta and hasta > os.time() then
			self:ExpulsarPorBloqueo(player, hasta)
		end
	end))
end

function ModerationService:AlSalir(player)
	local userId = player.UserId
	local maid = self.Maids[userId]
	if maid then
		self.Maids[userId] = nil
		maid:DoCleaning()
	end
	-- Las TextSource del jugador desaparecen con él; el silencio se conserva por si vuelve a entrar.
	self.FuentesSilenciadas[userId] = nil
	self.CacheAdonis[userId] = nil
	for token, entrada in pairs(self.Tokens) do
		if entrada.AdminUserId == userId then
			self.Tokens[token] = nil
		end
	end
end

function ModerationService:ExpulsarPorBloqueo(player, hasta)
	local restante = math.max(1, hasta - os.time())
	self:Auditar(player, "BloqueoVigente", "expulsado al entrar; quedan " .. Format.Duracion(restante))
	local mensaje = "Tienes un bloqueo temporal de moderación en Colegio RP. Podrás volver a entrar en "
		.. Format.Duracion(restante) .. "."
	task.defer(function()
		if player.Parent ~= nil then
			pcall(player.Kick, player, mensaje)
		end
	end)
end

-- Barrido periódico: silencios caducados, tokens vencidos, bloqueos en memoria y anti-repetición.
function ModerationService:Barrido()
	local ahora = os.time()
	for userId, silencio in pairs(self.Silencios) do
		if silencio.Hasta <= ahora then
			self:FinalizarSilencio(userId, nil, "caducado")
		end
	end
	self:PurgarTokens()
	for userId, bloqueo in pairs(self.Bloqueos) do
		if bloqueo.Hasta <= ahora then
			self.Bloqueos[userId] = nil
		end
	end
	local reloj = os.clock()
	for clave, t in pairs(self.UltimaAccion) do
		if reloj - t > 60 then
			self.UltimaAccion[clave] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Permisos, jerarquía y Adonis
---------------------------------------------------------------------------------------------------

-- ¿Es administrador de Adonis? Solo lectura, nunca lanza, con caché corta. Requiere Config.Autorizaciones.UsarAdonis.
function ModerationService:EsAdminAdonis(player)
	if AUT.UsarAdonis ~= true or not esJugador(player) then
		return false
	end
	local cache = self.CacheAdonis[player.UserId]
	if cache and os.clock() - cache.T < self.CacheAdonisSeg then
		return cache.Valor
	end
	local ok, resultado = pcall(function()
		local adonis = _G.Adonis
		return type(adonis) == "table" and type(adonis.CheckAdmin) == "function" and adonis.CheckAdmin(player) == true
	end)
	local valor = ok and resultado == true
	self.CacheAdonis[player.UserId] = { Valor = valor, T = os.clock() }
	return valor
end

-- Permiso adicional que concede la moderación (admins de Adonis -> moderacion.basica).
-- Pensado para que RoleService:Tiene lo consulte (ver pendientes); no concede nada más.
function ModerationService:PermisoExtra(player, permiso)
	return permiso == "moderacion.basica" and self:EsAdminAdonis(player)
end

-- ¿El jugador tiene el permiso? (cargo vía RoleService o permiso extra de Adonis).
function ModerationService:TienePermiso(player, permiso)
	if not esJugador(player) or typeof(permiso) ~= "string" then
		return false
	end
	local ok, tiene = self:Llamar("RoleService", "Tiene", player, permiso)
	if ok and tiene == true then
		return true
	end
	return self:PermisoExtra(player, permiso)
end

-- Cargo del jugador (RoleService o atributo replicado).
function ModerationService:CargoDe(player)
	local ok, cargo = self:Llamar("RoleService", "Cargo", player)
	if ok and typeof(cargo) == "string" then
		return cargo
	end
	local atributo = esJugador(player) and player:GetAttribute("Cargo") or nil
	if typeof(atributo) == "string" then
		return atributo
	end
	return "Estudiante"
end

-- Rango de moderación: Director 4 > Subdirector 3 > Coordinadores 2 > resto 1.
function ModerationService:Rango(player)
	return RANGO_CARGO[self:CargoDe(player)] or RANGO_RESTO
end

-- ¿Puede admin actuar sobre objetivo? admin nil = sistema (siempre). Devuelve ok, mensaje, codigo.
function ModerationService:PuedeActuar(admin, objetivo)
	if admin == nil then
		return true
	end
	if not esJugador(admin) or not esJugador(objetivo) then
		return false, "Jugador no válido.", "jugador_invalido"
	end
	if admin == objetivo then
		return false, "No puedes aplicarte esta acción a ti mismo/a.", "propio"
	end
	-- Ni superiores ni iguales (dos Directores o dos Coordinadores no se moderan entre sí).
	if self:Rango(objetivo) >= self:Rango(admin) then
		return false, "No puedes actuar sobre alguien con un cargo igual o superior al tuyo.", "objetivo_superior"
	end
	return true
end

-- Comprobaciones comunes de la API interna cuando la llama un jugador. Devuelve objetivo | nil, mensaje.
function ModerationService:Comprobar(admin, objetivo, accion, permisos)
	objetivo = resolverJugador(objetivo)
	if not objetivo or objetivo.Parent == nil then
		return nil, "El jugador no está conectado."
	end
	if admin ~= nil then
		if not esJugador(admin) then
			return nil, "Administrador no válido."
		end
		local autorizado = false
		for _, permiso in ipairs(permisos) do
			if self:TienePermiso(admin, permiso) then
				autorizado = true
			end
		end
		if not autorizado then
			self:Auditar(admin, "Rechazo:" .. accion, "sin permiso · objetivo " .. objetivo.Name .. "(" .. objetivo.UserId .. ")")
			return nil, "No tienes permiso para esta acción."
		end
		local puede, mensaje, codigo = self:PuedeActuar(admin, objetivo)
		if not puede then
			self:Auditar(admin, "Rechazo:" .. accion, tostring(codigo) .. " · objetivo " .. objetivo.Name .. "(" .. objetivo.UserId .. ")")
			return nil, mensaje
		end
	end
	return objetivo
end

---------------------------------------------------------------------------------------------------
-- Texto y duraciones
---------------------------------------------------------------------------------------------------

-- Motivo saneado y filtrado (lo verá el objetivo). Devuelve motivo, okFiltro.
function ModerationService:FiltrarMotivo(texto, autor)
	local limpio = limpiarLinea(texto, self.MaxMotivo)
	if limpio == nil then
		return self.TextoNoDisponible, false
	end
	if limpio == "" or not esJugador(autor) then
		return limpio, true
	end
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(limpio, autor.UserId, Enum.TextFilterContext.PublicChat)
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

-- Motivo de una petición de remoto: obligatorio en sanciones, por defecto en el resto. Devuelve motivo | nil, error.
function ModerationService:PrepararMotivo(admin, motivo, accion)
	local limpio = limpiarLinea(motivo or "", self.MaxMotivo)
	if limpio == nil then
		return nil, "El motivo no es un texto válido."
	end
	if limpio == "" or Format.Longitud(limpio) < self.MinMotivo then
		if self.MotivoObligatorio[accion] then
			return nil, "Escribe un motivo de al menos " .. self.MinMotivo .. " caracteres."
		end
		if limpio == "" then
			return self.MotivoPorDefecto[accion] or "Sin motivo indicado"
		end
	end
	local filtrado = self:FiltrarMotivo(limpio, admin)
	return filtrado
end

function ModerationService:Duracion(accion, valor)
	local defecto = self.DuracionMuteSeg
	if accion == "BloquearTemporal" then
		defecto = self.DuracionBloqueoSeg
	end
	local n = tonumber(valor)
	if n == nil or n ~= n then
		n = defecto
	end
	return math.clamp(math.floor(n), self.DuracionMinSeg, self.DuracionMaxSeg)
end

---------------------------------------------------------------------------------------------------
-- Registro en memoria y auditoría de acciones aplicadas
---------------------------------------------------------------------------------------------------
function ModerationService:Anotar(admin, objetivo, accion, motivo, extra)
	self.ContadorRegistro = self.ContadorRegistro + 1
	local entrada = {
		Id = self.ContadorRegistro,
		T = os.time(),
		Accion = accion,
		Tipo = self.Etiquetas[accion] or accion,
		AdminUserId = userIdDe(admin) or 0,
		Autor = nombreDe(admin),
		ObjetivoUserId = userIdDe(objetivo) or 0,
		Jugador = esJugador(objetivo) and objetivo.Name or tostring(userIdDe(objetivo) or "?"),
		Nombre = esJugador(objetivo) and objetivo.DisplayName or nil,
		Motivo = motivo or "",
	}
	if typeof(extra) == "table" then
		for clave, valor in pairs(extra) do
			local tipo = typeof(valor)
			if tipo == "string" or tipo == "number" or tipo == "boolean" then
				entrada[clave] = valor
			end
		end
	end
	table.insert(self.Registros, entrada)
	while #self.Registros > self.MaxRegistro do
		table.remove(self.Registros, 1)
	end
	local detalle = string.format("objetivo=%s(%s) · motivo=%s", entrada.Jugador, tostring(entrada.ObjetivoUserId), entrada.Motivo)
	if entrada.DuracionSeg then
		detalle = detalle .. " · duración=" .. Format.Duracion(entrada.DuracionSeg)
	end
	if entrada.Cargo then
		detalle = detalle .. " · cargo=" .. tostring(entrada.Cargo)
	end
	if admin == nil then
		detalle = detalle .. " · por=Sistema"
	end
	self:Auditar(admin, accion, detalle)
	local ok, err = pcall(function()
		self.AccionAplicada:Fire(accion, admin, entrada.ObjetivoUserId, copiaPlana(entrada))
	end)
	if not ok then
		warn(PREFIJO .. " Error en un oyente de AccionAplicada: " .. tostring(err))
	end
	return entrada
end

-- Últimas n acciones de moderación (la más reciente primero). filtroUserId opcional (objetivo o autor).
function ModerationService:Registro(n, filtroUserId)
	n = math.clamp(math.floor(tonumber(n) or 50), 1, self.MaxRegistro)
	local lista = {}
	for i = #self.Registros, 1, -1 do
		if #lista >= n then
			break
		end
		local entrada = self.Registros[i]
		if filtroUserId == nil or entrada.ObjetivoUserId == filtroUserId or entrada.AdminUserId == filtroUserId then
			table.insert(lista, copiaPlana(entrada))
		end
	end
	return lista
end

---------------------------------------------------------------------------------------------------
-- Silencio (TextChatService + atributo)
---------------------------------------------------------------------------------------------------
function ModerationService:PrepararChat()
	local okServicio, tcs = pcall(game.GetService, game, "TextChatService")
	if not okServicio or not tcs then
		warn(PREFIJO .. " TextChatService no disponible: el silencio se aplica solo con el atributo Silenciado.")
		return
	end
	self.TextChatService = tcs
	local okVersion, version = pcall(function()
		return tcs.ChatVersion
	end)
	self.ChatModerno = okVersion and version == Enum.ChatVersion.TextChatService
	if not self.ChatModerno then
		warn(PREFIJO .. " El lugar usa el chat heredado (ChatVersion ~= TextChatService): el silencio se aplica solo con el atributo Silenciado.")
		return
	end
	-- Fuentes nuevas (canales creados o usuarios añadidos después del silencio).
	table.insert(self.Conexiones, tcs.DescendantAdded:Connect(function(descendiente)
		if descendiente:IsA("TextSource") then
			task.defer(function()
				self:AplicarFuente(descendiente)
			end)
		end
	end))
end

-- Canales afectados por el silencio: todos los TextChannel salvo los susurros (RBXWhisper...).
local function esCanalSilenciable(canal)
	if typeof(canal) ~= "Instance" or not canal:IsA("TextChannel") then
		return false
	end
	return string.sub(canal.Name, 1, 10) ~= "RBXWhisper"
end

-- TextSource del usuario en canales silenciables.
function ModerationService:FuentesDe(userId)
	local fuentes = {}
	local tcs = self.TextChatService
	if not tcs or not self.ChatModerno then
		return fuentes
	end
	local ok, descendientes = pcall(tcs.GetDescendants, tcs)
	if not ok then
		return fuentes
	end
	for _, d in ipairs(descendientes) do
		if d:IsA("TextSource") and d.UserId == userId and esCanalSilenciable(d.Parent) then
			table.insert(fuentes, d)
		end
	end
	return fuentes
end

function ModerationService:SilenciarFuente(userId, fuente)
	local registro = self.FuentesSilenciadas[userId]
	if not registro then
		registro = {}
		self.FuentesSilenciadas[userId] = registro
	end
	if registro[fuente] ~= nil then
		return
	end
	local okLeer, original = pcall(function()
		return fuente.CanSend
	end)
	local ok = pcall(function()
		fuente.CanSend = false
	end)
	if ok then
		registro[fuente] = not (okLeer and original == false)
	end
end

-- Aplica el silencio a una TextSource recién creada si su usuario está silenciado.
function ModerationService:AplicarFuente(fuente)
	if not self.ChatModerno or fuente.Parent == nil or not esCanalSilenciable(fuente.Parent) then
		return
	end
	local okId, userId = pcall(function()
		return fuente.UserId
	end)
	if okId and typeof(userId) == "number" and self:SilencioActivo(userId) then
		self:SilenciarFuente(userId, fuente)
	end
end

-- silenciar = true fija CanSend=false en las fuentes del usuario; false restaura su valor original.
-- Devuelve el número de fuentes tocadas.
function ModerationService:AplicarSilencioChat(userId, silenciar)
	if not self.ChatModerno then
		return 0
	end
	local cantidad = 0
	if silenciar then
		for _, fuente in ipairs(self:FuentesDe(userId)) do
			self:SilenciarFuente(userId, fuente)
			cantidad = cantidad + 1
		end
		return cantidad
	end
	local registro = self.FuentesSilenciadas[userId]
	self.FuentesSilenciadas[userId] = nil
	if registro then
		for fuente, original in pairs(registro) do
			if fuente.Parent ~= nil then
				pcall(function()
					fuente.CanSend = original
				end)
				cantidad = cantidad + 1
			end
		end
	end
	return cantidad
end

-- Silencio vigente del usuario (tabla) o nil; los caducados se levantan aquí mismo.
function ModerationService:SilencioActivo(userId)
	local silencio = self.Silencios[userId]
	if not silencio then
		return nil
	end
	if silencio.Hasta <= os.time() then
		self:FinalizarSilencio(userId, nil, "caducado")
		return nil
	end
	return silencio
end

-- ¿Está silenciado? (Player o userId)
function ModerationService:EstaSilenciado(player)
	local userId = userIdDe(player)
	if not userId then
		return false
	end
	return self:SilencioActivo(userId) ~= nil
end

-- Levanta el silencio (admin nil = sistema). origen: "caducado" | "manual".
function ModerationService:FinalizarSilencio(userId, admin, origen)
	local silencio = self.Silencios[userId]
	if not silencio then
		return false
	end
	self.Silencios[userId] = nil
	self:AplicarSilencioChat(userId, false)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		pcall(function()
			player:SetAttribute("Silenciado", nil)
			player:SetAttribute("SilenciadoHasta", nil)
		end)
		self:Enviar(player, "Moderacion", { Sub = "Silenciado", Activo = false, Origen = origen })
		local texto = "Tu silencio ha terminado. Ya puedes volver a escribir en el chat."
		if origen == "manual" then
			texto = "Moderación ha retirado tu silencio. Ya puedes volver a escribir en el chat."
		end
		self:Notificar(player, "Moderación", texto, "info")
	end
	if origen == "caducado" then
		self:Auditar(player or userId, "SilencioCaducado", "fin del silencio de " .. Format.Duracion(os.time() - (silencio.Desde or os.time())))
	end
	return true
end

-- Silencia a objetivo durante seg segundos. Devuelve true, info | false, mensaje.
-- opciones.YaFiltrado = true evita volver a filtrar el motivo.
function ModerationService:Silenciar(admin, objetivo, seg, motivo, opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	local jugador, err = self:Comprobar(admin, objetivo, "Silenciar", { "moderacion.basica" })
	if not jugador then
		return false, err
	end
	local duracion = self:Duracion("Silenciar", seg)
	local texto = motivo
	if not opciones.YaFiltrado then
		texto = self:FiltrarMotivo(motivo or "", admin)
	end
	if typeof(texto) ~= "string" or texto == "" then
		texto = "Sin motivo indicado"
	end
	local userId = jugador.UserId
	self.ContadorSilencios = self.ContadorSilencios + 1
	local id = self.ContadorSilencios
	local ahora = os.time()
	local hasta = ahora + duracion
	local anterior = self.Silencios[userId]
	self.Silencios[userId] = {
		Id = id, Hasta = hasta, Desde = anterior and anterior.Desde or ahora, Motivo = texto,
		PorUserId = userIdDe(admin) or 0, PorNombre = nombreDe(admin),
	}
	pcall(function()
		jugador:SetAttribute("Silenciado", true)
		jugador:SetAttribute("SilenciadoHasta", hasta)
	end)
	local fuentes = self:AplicarSilencioChat(userId, true)
	task.delay(duracion, function()
		local actual = self.Silencios[userId]
		if actual and actual.Id == id then
			self:FinalizarSilencio(userId, nil, "caducado")
		end
	end)

	self:Enviar(jugador, "Moderacion", {
		Sub = "Silenciado", Activo = true, Hasta = hasta, DuracionSeg = duracion, Motivo = texto, Autor = nombreDe(admin),
	})
	self:Notificar(jugador, "Moderación", "Has sido silenciado/a durante " .. Format.Duracion(duracion) .. ". Motivo: " .. texto, "aviso", 10)
	self:Anotar(admin, jugador, "Silenciar", texto, { DuracionSeg = duracion, Hasta = hasta, FuentesChat = fuentes })
	return true, {
		UserId = userId, Nombre = nombreDe(jugador), Hasta = hasta, DuracionSeg = duracion,
		Chat = self.ChatModerno, FuentesChat = fuentes,
	}
end

-- Quita el silencio a objetivo. Devuelve true, info | false, mensaje.
function ModerationService:QuitarSilencio(admin, objetivo, motivo, opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	local jugador, err = self:Comprobar(admin, objetivo, "QuitarSilencio", { "moderacion.basica" })
	if not jugador then
		return false, err
	end
	if not self:SilencioActivo(jugador.UserId) then
		return false, nombreDe(jugador) .. " no está silenciado/a."
	end
	local texto = motivo
	if typeof(texto) ~= "string" or texto == "" then
		texto = self.MotivoPorDefecto.QuitarSilencio
	elseif not opciones.YaFiltrado then
		texto = self:FiltrarMotivo(texto, admin)
	end
	self:FinalizarSilencio(jugador.UserId, admin, "manual")
	self:Anotar(admin, jugador, "QuitarSilencio", texto)
	return true, { UserId = jugador.UserId, Nombre = nombreDe(jugador) }
end

-- Usuarios silenciados (lista para paneles).
function ModerationService:Silenciados()
	local lista = {}
	local ahora = os.time()
	for userId, silencio in pairs(self.Silencios) do
		if silencio.Hasta > ahora then
			local player = Players:GetPlayerByUserId(userId)
			table.insert(lista, {
				UserId = userId, Jugador = player and player.Name or tostring(userId), Nombre = player and player.DisplayName or nil,
				Hasta = silencio.Hasta, RestanteSeg = silencio.Hasta - ahora, Motivo = silencio.Motivo, Autor = silencio.PorNombre,
				Conectado = player ~= nil, Tipo = "Silenciado", T = silencio.Desde,
			})
		end
	end
	table.sort(lista, function(a, b)
		return a.Hasta < b.Hasta
	end)
	return lista
end

---------------------------------------------------------------------------------------------------
-- Expulsión, bloqueo temporal y advertencias
---------------------------------------------------------------------------------------------------

-- Expulsa a objetivo del servidor. Devuelve true, info | false, mensaje.
function ModerationService:Expulsar(admin, objetivo, motivo, opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	local jugador, err = self:Comprobar(admin, objetivo, "Expulsar", { "moderacion.avanzada" })
	if not jugador then
		return false, err
	end
	local texto = motivo
	if not opciones.YaFiltrado then
		texto = self:FiltrarMotivo(motivo or "", admin)
	end
	if typeof(texto) ~= "string" or texto == "" then
		texto = "Sin motivo indicado"
	end
	local info = { UserId = jugador.UserId, Nombre = nombreDe(jugador) }
	self:Anotar(admin, jugador, "Expulsar", texto)
	local okKick, errKick = pcall(jugador.Kick, jugador, "Expulsado por moderación: " .. texto)
	if not okKick then
		warn(PREFIJO .. " No se pudo expulsar a " .. jugador.Name .. ": " .. tostring(errKick))
		return false, "No se pudo expulsar al jugador."
	end
	return true, info
end

-- Bloquea temporalmente a objetivo (perfil Moderacion.BloqueoHasta + respaldo en memoria) y lo expulsa.
-- Devuelve true, info | false, mensaje.
function ModerationService:BloquearTemporal(admin, objetivo, seg, motivo, opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	local jugador, err = self:Comprobar(admin, objetivo, "BloquearTemporal", { "moderacion.avanzada" })
	if not jugador then
		return false, err
	end
	local duracion = self:Duracion("BloquearTemporal", seg)
	local texto = motivo
	if not opciones.YaFiltrado then
		texto = self:FiltrarMotivo(motivo or "", admin)
	end
	if typeof(texto) ~= "string" or texto == "" then
		texto = "Sin motivo indicado"
	end
	local userId = jugador.UserId
	local hasta = os.time() + duracion
	local previo = self.Bloqueos[userId]
	if previo and previo.Hasta > hasta then
		hasta = previo.Hasta
	end
	self.Bloqueos[userId] = { Hasta = hasta, Motivo = texto }

	-- Perfil: BloqueoHasta (nunca se acorta un bloqueo más largo ya vigente) y guardado inmediato.
	local persistido = false
	local okPerfil, perfil = self:Llamar("DataService", "Obtener", jugador)
	if not okPerfil or typeof(perfil) ~= "table" then
		okPerfil, perfil = self:Llamar("DataService", "EsperarPerfil", jugador, self.EsperaPerfilAccionSeg)
	end
	if okPerfil and typeof(perfil) == "table" then
		if typeof(perfil.Moderacion) ~= "table" then
			perfil.Moderacion = { Advertencias = {}, BloqueoHasta = 0 }
		end
		local actual = tonumber(perfil.Moderacion.BloqueoHasta) or 0
		if actual < hasta then
			perfil.Moderacion.BloqueoHasta = hasta
		end
		self:Llamar("DataService", "Marcar", jugador)
		local DataService = self:Servicio("DataService")
		if DataService and typeof(DataService.Guardar) == "function" then
			local okGuardar, guardado = pcall(DataService.Guardar, DataService, jugador, "bloqueo")
			persistido = okGuardar and guardado == true
		end
	end

	self:Anotar(admin, jugador, "BloquearTemporal", texto, { DuracionSeg = duracion, Hasta = hasta, Persistido = persistido })
	local mensaje = "Bloqueado temporalmente por moderación durante " .. Format.Duracion(duracion) .. ". Motivo: " .. texto
	local okKick, errKick = pcall(jugador.Kick, jugador, mensaje)
	if not okKick then
		warn(PREFIJO .. " No se pudo expulsar a " .. jugador.Name .. " tras el bloqueo: " .. tostring(errKick))
	end
	return true, { UserId = userId, Nombre = nombreDe(jugador), Hasta = hasta, DuracionSeg = duracion, Persistido = persistido }
end

-- Añade una advertencia al perfil del objetivo y se la notifica. Devuelve true, info | false, mensaje.
-- La aceptan moderacion.basica y convivencia.gestionar (StaffService la usa para los casos de convivencia).
function ModerationService:Advertir(admin, objetivo, motivo, opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	local jugador, err = self:Comprobar(admin, objetivo, "Advertir", { "moderacion.basica", "convivencia.gestionar" })
	if not jugador then
		return false, err
	end
	local texto = motivo
	if not opciones.YaFiltrado then
		texto = self:FiltrarMotivo(motivo or "", admin)
	end
	if typeof(texto) ~= "string" or texto == "" then
		return false, "Escribe el motivo de la advertencia."
	end
	local autor = esJugador(admin) and admin.Name or "Sistema"
	local userId = jugador.UserId
	local total = nil
	local enPerfil = false
	local okPerfil, perfil = self:Llamar("DataService", "Obtener", jugador)
	if not okPerfil or typeof(perfil) ~= "table" then
		okPerfil, perfil = self:Llamar("DataService", "EsperarPerfil", jugador, self.EsperaPerfilAccionSeg)
	end
	if okPerfil and typeof(perfil) == "table" then
		if typeof(perfil.Moderacion) ~= "table" then
			perfil.Moderacion = { Advertencias = {}, BloqueoHasta = 0 }
		end
		if typeof(perfil.Moderacion.Advertencias) ~= "table" then
			perfil.Moderacion.Advertencias = {}
		end
		local lista = perfil.Moderacion.Advertencias
		table.insert(lista, { T = os.time(), Motivo = texto, Autor = autor })
		while #lista > self.MaxAdvertencias do
			table.remove(lista, 1)
		end
		total = #lista
		enPerfil = true
		self:Llamar("DataService", "Marcar", jugador)
	else
		total = (self.AdvertenciasMemoria[userId] or 0) + 1
		self.AdvertenciasMemoria[userId] = total
	end

	self:Enviar(jugador, "Moderacion", {
		Sub = "Advertencia", Motivo = texto, Autor = nombreDe(admin), Total = total, T = os.time(),
	})
	self:Notificar(jugador, "Advertencia de moderación", texto, "aviso", 10)
	self:Anotar(admin, jugador, "Advertir", texto, { Total = total, EnPerfil = enPerfil })
	return true, { UserId = userId, Nombre = nombreDe(jugador), Total = total, EnPerfil = enPerfil }
end

-- Advertencias del perfil de un jugador conectado (copia) o lista vacía.
function ModerationService:AdvertenciasDe(player)
	player = resolverJugador(player)
	if not player then
		return {}
	end
	local ok, perfil = self:Llamar("DataService", "Obtener", player)
	local lista = {}
	if ok and typeof(perfil) == "table" and typeof(perfil.Moderacion) == "table" and typeof(perfil.Moderacion.Advertencias) == "table" then
		for i = #perfil.Moderacion.Advertencias, 1, -1 do
			local adv = perfil.Moderacion.Advertencias[i]
			if typeof(adv) == "table" then
				table.insert(lista, {
					T = adv.T, Motivo = adv.Motivo, Autor = adv.Autor, Tipo = "Advertencia",
					Jugador = player.Name, ObjetivoUserId = player.UserId,
				})
			end
		end
	end
	return lista
end

-- Estado de moderación de un jugador (paneles / StaffService).
function ModerationService:Snapshot(player)
	local userId = userIdDe(player)
	if not userId then
		return nil
	end
	local silencio = self:SilencioActivo(userId)
	return {
		Silenciado = silencio ~= nil,
		SilenciadoHasta = silencio and silencio.Hasta or nil,
		Advertencias = #self:AdvertenciasDe(player),
	}
end

---------------------------------------------------------------------------------------------------
-- Confirmación en dos pasos
---------------------------------------------------------------------------------------------------
-- Los tokens vencidos se conservan GraciaTokenSeg más para poder responder "caducó" en lugar de "no válido".
function ModerationService:PurgarTokens()
	local limite = os.clock() - self.GraciaTokenSeg
	for token, entrada in pairs(self.Tokens) do
		if entrada.Expira <= limite then
			self.Tokens[token] = nil
		end
	end
end

-- Resumen legible de una acción pendiente de confirmar.
function ModerationService:Resumen(accion, objetivo, motivo, duracion, cargo)
	local nombre = nombreDe(objetivo)
	local texto = (self.Etiquetas[accion] or accion) .. " a " .. nombre
	if accion == "BloquearTemporal" then
		texto = texto .. " durante " .. Format.Duracion(duracion)
	elseif accion == "RevocarCargo" then
		texto = "Revocar el cargo de " .. RoleDefinitions.Nombre(self:CargoDe(objetivo)) .. " a " .. nombre
	elseif accion == "AsignarCargo" and cargo then
		texto = "Asignar el cargo " .. RoleDefinitions.Nombre(cargo) .. " a " .. nombre
	end
	return texto .. ". Motivo: " .. tostring(motivo)
end

function ModerationService:EmitirToken(admin, objetivo, accion, motivo, duracion, cargo)
	-- Máximo de tokens pendientes por administrador: se descarta el más antiguo.
	local propios = {}
	local ahora = os.clock()
	for token, entrada in pairs(self.Tokens) do
		if entrada.AdminUserId == admin.UserId then
			if entrada.Expira <= ahora then
				self.Tokens[token] = nil
			else
				table.insert(propios, { Token = token, Creado = entrada.Creado })
			end
		end
	end
	if #propios >= self.MaxTokensPorAdmin then
		table.sort(propios, function(a, b)
			return a.Creado < b.Creado
		end)
		for i = 1, #propios - self.MaxTokensPorAdmin + 1 do
			self.Tokens[propios[i].Token] = nil
		end
	end
	local token = generarToken()
	while self.Tokens[token] ~= nil do
		token = generarToken()
	end
	self.Tokens[token] = {
		Accion = accion,
		AdminUserId = admin.UserId,
		ObjetivoUserId = objetivo.UserId,
		Motivo = motivo,
		DuracionSeg = duracion,
		Cargo = cargo,
		Creado = os.clock(),
		Expira = os.clock() + self.TokenSeg,
	}
	local resumen = self:Resumen(accion, objetivo, motivo, duracion, cargo)
	self:Auditar(admin, "Confirmacion:" .. accion, "pendiente · objetivo=" .. objetivo.Name .. "(" .. objetivo.UserId .. ")")
	return RemoteContracts.Ok({
		RequiereConfirmacion = true,
		Token = token,
		Accion = accion,
		ObjetivoUserId = objetivo.UserId,
		Resumen = resumen,
		Mensaje = "Paso 2 de 2 · Confirma definitivamente: " .. resumen .. " (la confirmación caduca en " .. self.TokenSeg .. " s).",
		ExpiraSeg = self.TokenSeg,
	})
end

-- Segunda llamada: valida el Token (propio, vigente, de un solo uso) y ejecuta con los datos guardados.
function ModerationService:Confirmar(admin, datos)
	local token = datos.Token
	if typeof(token) ~= "string" or token == "" then
		return RemoteContracts.Error("Falta la confirmación. Repite la acción desde el panel.")
	end
	local entrada = self.Tokens[token]
	if not entrada then
		self:Auditar(admin, "Rechazo:ConfirmarAccion", "token inexistente o ya usado")
		return RemoteContracts.Error("La confirmación no es válida o ya se usó. Repite la acción.")
	end
	if entrada.AdminUserId ~= admin.UserId then
		self:Auditar(admin, "Rechazo:ConfirmarAccion", "token de otro administrador")
		return RemoteContracts.Error("La confirmación no es válida o ya se usó. Repite la acción.")
	end
	if entrada.Expira <= os.clock() then
		self.Tokens[token] = nil
		self:Auditar(admin, "Rechazo:ConfirmarAccion", "token caducado (" .. entrada.Accion .. ")")
		return RemoteContracts.Error("La confirmación caducó (" .. self.TokenSeg .. " s). Repite la acción.")
	end
	if datos.Accion ~= "ConfirmarAccion" and datos.Accion ~= entrada.Accion then
		self:Auditar(admin, "Rechazo:ConfirmarAccion", "acción distinta: " .. tostring(datos.Accion) .. " ~= " .. entrada.Accion)
		return RemoteContracts.Error("La confirmación no corresponde a esta acción.")
	end
	if datos.ObjetivoUserId ~= nil and datos.ObjetivoUserId ~= entrada.ObjetivoUserId then
		self:Auditar(admin, "Rechazo:ConfirmarAccion", "objetivo distinto del confirmado")
		return RemoteContracts.Error("La confirmación no corresponde a este jugador.")
	end
	-- Un solo uso: se consume antes de ejecutar.
	self.Tokens[token] = nil
	local permiso = self.Permisos[entrada.Accion]
	if not permiso or not self:TienePermiso(admin, permiso) then
		self:Auditar(admin, "Rechazo:ConfirmarAccion", "sin permiso " .. tostring(permiso) .. " al confirmar " .. entrada.Accion)
		return RemoteContracts.Error("Ya no tienes permiso para esta acción.")
	end
	local objetivo = Players:GetPlayerByUserId(entrada.ObjetivoUserId)
	if not objetivo then
		return RemoteContracts.Error("El jugador ya no está conectado.")
	end
	return self:Ejecutar(admin, objetivo, entrada.Accion, entrada.Motivo, entrada.DuracionSeg, entrada.Cargo)
end

---------------------------------------------------------------------------------------------------
-- Ejecución de acciones (desde el handler)
---------------------------------------------------------------------------------------------------
local function textoRoles(motivo)
	if typeof(motivo) ~= "string" then
		return "No se pudo completar la gestión del cargo."
	end
	local espera = string.match(motivo, "^cooldown:(%d+)$")
	if espera then
		return "Espera " .. espera .. " s antes de otra gestión de cargos."
	end
	return TEXTOS_ROLES[motivo] or motivo
end

function ModerationService:Ejecutar(admin, objetivo, accion, motivo, duracion, cargo)
	local opciones = { YaFiltrado = true }
	local ok, resultado
	if accion == "Silenciar" then
		ok, resultado = self:Silenciar(admin, objetivo, duracion, motivo, opciones)
	elseif accion == "QuitarSilencio" then
		ok, resultado = self:QuitarSilencio(admin, objetivo, motivo, opciones)
	elseif accion == "Advertir" then
		ok, resultado = self:Advertir(admin, objetivo, motivo, opciones)
	elseif accion == "Expulsar" then
		ok, resultado = self:Expulsar(admin, objetivo, motivo, opciones)
	elseif accion == "BloquearTemporal" then
		ok, resultado = self:BloquearTemporal(admin, objetivo, duracion, motivo, opciones)
	elseif accion == "AsignarCargo" or accion == "RevocarCargo" then
		return self:GestionarCargo(admin, objetivo, accion, motivo, cargo)
	else
		return RemoteContracts.Error("Acción de moderación desconocida.")
	end
	if not ok then
		return RemoteContracts.Error(resultado)
	end
	local datos = typeof(resultado) == "table" and resultado or {}
	datos.Accion = accion
	datos.Mensaje = (self.Etiquetas[accion] or accion) .. " aplicado: " .. nombreDe(objetivo) .. "."
	return RemoteContracts.Ok(datos)
end

-- AsignarCargo / RevocarCargo: delega en RoleService (que aplica su propia jerarquía y cooldown).
function ModerationService:GestionarCargo(admin, objetivo, accion, motivo, cargo)
	local RoleService = self:Servicio("RoleService")
	local metodo = accion == "AsignarCargo" and "AsignarPorAdmin" or "Revocar"
	if not RoleService or typeof(RoleService[metodo]) ~= "function" then
		return RemoteContracts.Error("La gestión de cargos no está disponible.")
	end
	local anterior = self:CargoDe(objetivo)
	local okLlamada, ok, info
	if accion == "AsignarCargo" then
		if not RoleDefinitions.Existe(cargo) then
			return RemoteContracts.Error("Selecciona un cargo válido.")
		end
		okLlamada, ok, info = pcall(RoleService.AsignarPorAdmin, RoleService, admin, objetivo, cargo)
	else
		okLlamada, ok, info = pcall(RoleService.Revocar, RoleService, admin, objetivo)
	end
	if not okLlamada then
		warn(PREFIJO .. " RoleService:" .. metodo .. " falló: " .. tostring(ok))
		return RemoteContracts.Error("No se pudo completar la gestión del cargo.")
	end
	if ok ~= true then
		self:Auditar(admin, "Rechazo:" .. accion, tostring(info) .. " · objetivo=" .. objetivo.Name .. "(" .. objetivo.UserId .. ")")
		return RemoteContracts.Error(textoRoles(info))
	end
	local nuevo = typeof(info) == "table" and info.Cargo or self:CargoDe(objetivo)
	self:Anotar(admin, objetivo, accion, motivo, { Cargo = nuevo, Anterior = anterior })
	local datos = {
		Accion = accion,
		UserId = objetivo.UserId,
		Nombre = nombreDe(objetivo),
		Cargo = nuevo,
		Anterior = anterior,
		Mensaje = (self.Etiquetas[accion] or accion) .. " aplicado: " .. nombreDe(objetivo) .. " (" .. RoleDefinitions.Nombre(nuevo) .. ").",
	}
	if typeof(info) == "table" then
		datos.Equipo = info.Equipo
		datos.Salon = info.Salon
	end
	return RemoteContracts.Ok(datos)
end

---------------------------------------------------------------------------------------------------
-- VerRegistro
---------------------------------------------------------------------------------------------------
function ModerationService:AccionVerRegistro(admin, datos)
	local objetivoId = datos.ObjetivoUserId
	local auditoria = {}
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog and typeof(AuditLog.Listar) == "function" then
		local cantidad = 50
		if objetivoId ~= nil then
			cantidad = 500
		end
		local ok, lista = pcall(AuditLog.Listar, AuditLog, cantidad)
		if ok and typeof(lista) == "table" then
			local clave = objetivoId and tostring(objetivoId) or nil
			for _, entrada in ipairs(lista) do
				if #auditoria >= 50 then
					break
				end
				local pasa = clave == nil or entrada.UserId == objetivoId
					or (typeof(entrada.Detalle) == "string" and string.find(entrada.Detalle, clave, 1, true) ~= nil)
				if pasa then
					table.insert(auditoria, {
						Id = entrada.Id, T = entrada.T, Categoria = entrada.Categoria, UserId = entrada.UserId,
						Jugador = entrada.Jugador, Tipo = entrada.Accion, Accion = entrada.Accion, Detalle = entrada.Detalle,
						Fuente = "Auditoria",
					})
				end
			end
		end
	end

	local reportes = {}
	local okR, listaR = self:Llamar("ReportService", "Listar", 30)
	if okR and typeof(listaR) == "table" then
		for _, reporte in ipairs(listaR) do
			local fila = copiaPlana(reporte)
			fila.Fuente = "Reporte"
			fila.Tipo = "Reporte"
			table.insert(reportes, fila)
		end
	end

	local moderacion = self:Registro(30, objetivoId)
	local advertencias = {}
	local objetivo = nil
	if objetivoId ~= nil then
		objetivo = Players:GetPlayerByUserId(objetivoId)
		if objetivo then
			advertencias = self:AdvertenciasDe(objetivo)
		end
	end

	-- Vista combinada (la más reciente primero) para el panel.
	local combinada = {}
	for _, fila in ipairs(moderacion) do
		local copia = copiaPlana(fila)
		copia.Fuente = "Moderacion"
		copia.Categoria = "Moderacion"
		table.insert(combinada, copia)
	end
	for _, fila in ipairs(advertencias) do
		local copia = copiaPlana(fila)
		copia.Fuente = "Advertencia"
		table.insert(combinada, copia)
	end
	for _, fila in ipairs(auditoria) do
		table.insert(combinada, fila)
	end
	for _, fila in ipairs(reportes) do
		table.insert(combinada, fila)
	end
	table.sort(combinada, function(a, b)
		local ta, tb = tonumber(a.T) or 0, tonumber(b.T) or 0
		if ta ~= tb then
			return ta > tb
		end
		return tostring(a.Fuente) < tostring(b.Fuente)
	end)
	while #combinada > 100 do
		table.remove(combinada)
	end

	local respuesta = {
		Registro = combinada,
		Auditoria = auditoria,
		Reportes = reportes,
		Moderacion = moderacion,
		Advertencias = advertencias,
		Silenciados = self:Silenciados(),
		ObjetivoUserId = objetivoId,
		Objetivo = objetivo and nombreDe(objetivo) or nil,
	}
	self:Auditar(admin, "VerRegistro", objetivoId and ("objetivo=" .. tostring(objetivoId)) or "general")
	self:Enviar(admin, "Moderacion", { Sub = "Registro", ObjetivoUserId = objetivoId, Cantidad = #combinada, Registro = combinada })
	return RemoteContracts.Ok(respuesta)
end

---------------------------------------------------------------------------------------------------
-- Handler de ModerationAction (RemoteService ya validó tabla, esquema, límite y permiso del contrato)
---------------------------------------------------------------------------------------------------
function ModerationService:ManejarAccion(player, datos)
	self:PurgarTokens()
	local accion = datos.Accion

	-- Segundo paso de una acción crítica (ConfirmarAccion, o la propia acción con su Token).
	if accion == "ConfirmarAccion" then
		return self:Confirmar(player, datos)
	end
	if self.Criticas[accion] and typeof(datos.Token) == "string" and datos.Token ~= "" then
		return self:Confirmar(player, datos)
	end

	local permiso = self.Permisos[accion]
	if not permiso then
		return RemoteContracts.Error("Acción de moderación desconocida.")
	end
	if not self:TienePermiso(player, permiso) then
		self:Auditar(player, "Rechazo:" .. tostring(accion), "sin permiso " .. permiso)
		return RemoteContracts.Error("No tienes permiso para esta acción.")
	end
	if accion == "VerRegistro" then
		return self:AccionVerRegistro(player, datos)
	end

	-- Objetivo conectado, distinto de uno mismo y sin cargo superior.
	if typeof(datos.ObjetivoUserId) ~= "number" then
		return RemoteContracts.Error("Selecciona a un jugador.")
	end
	local objetivo = Players:GetPlayerByUserId(datos.ObjetivoUserId)
	if not objetivo then
		return RemoteContracts.Error("El jugador no está conectado.")
	end
	local puede, mensaje, codigo = self:PuedeActuar(player, objetivo)
	if not puede then
		self:Auditar(player, "Rechazo:" .. accion, tostring(codigo) .. " · objetivo=" .. objetivo.Name .. "(" .. objetivo.UserId .. ")")
		return RemoteContracts.Error(mensaje)
	end
	if accion == "AsignarCargo" and not RoleDefinitions.Existe(datos.Cargo) then
		return RemoteContracts.Error("Selecciona un cargo válido.")
	end
	if accion == "QuitarSilencio" and not self:SilencioActivo(objetivo.UserId) then
		return RemoteContracts.Error(nombreDe(objetivo) .. " no está silenciado/a.")
	end

	-- Evita la misma acción repetida por un doble clic.
	local clave = player.UserId .. ":" .. accion .. ":" .. objetivo.UserId
	local ultima = self.UltimaAccion[clave]
	if ultima and os.clock() - ultima < self.AntiRepeticionSeg then
		return RemoteContracts.Error("Acción repetida; espera un momento.")
	end
	self.UltimaAccion[clave] = os.clock()

	local motivo, errMotivo = self:PrepararMotivo(player, datos.Motivo, accion)
	if not motivo then
		return RemoteContracts.Error(errMotivo)
	end
	if objetivo.Parent == nil then
		return RemoteContracts.Error("El jugador ya no está conectado.")
	end
	local duracion = nil
	if accion == "Silenciar" or accion == "BloquearTemporal" then
		duracion = self:Duracion(accion, datos.DuracionSeg)
	end

	if self.Criticas[accion] then
		if accion == "RevocarCargo" and self:CargoDe(objetivo) == ((Config.Spawns and Config.Spawns.CargoPorDefecto) or "Estudiante") then
			return RemoteContracts.Error(TEXTOS_ROLES.sin_cargo)
		end
		return self:EmitirToken(player, objetivo, accion, motivo, duracion, datos.Cargo)
	end
	return self:Ejecutar(player, objetivo, accion, motivo, duracion, datos.Cargo)
end

return ModerationService
