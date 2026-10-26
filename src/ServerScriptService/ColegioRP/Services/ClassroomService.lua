--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.ClassroomService
	Tipo: ModuleScript
	Sesiones de clase por aula (docs/ARQUITECTURA.md §6, pruebas P4 y P7). Modelo ClassSession / Activity en el
	servidor, handler de RequestClassAction con todas las acciones del contrato (abrir/cerrar sesión, tema, aviso,
	asistencia, actividades de texto u opciones con tiempo, respuestas únicas con corrección automática,
	calificación privada, resultados anónimos, manos levantadas, invitación y turno de tablero, consulta de estado).
	Todo el estado vive aquí; el cliente solo pide y renderiza. Los envíos "Aula" van exclusivamente a jugadores
	presentes en esa aula (RoomService) y al docente de la sesión: nunca a otra aula. La sesión se cancela si el
	docente sale del servidor, cambia de cargo, termina el periodo de clase o termina la jornada.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local Util = Shared:WaitForChild("Util")
local Zones = require(Util:WaitForChild("Zones"))
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))

local ClassroomService = {}
ClassroomService.Nombre = "ClassroomService"

local PREFIJO = "[ColegioRP][ClassroomService]"

---------------------------------------------------------------------------------------------------
-- Parámetros
---------------------------------------------------------------------------------------------------
local LIMITES = Config.Limites or {}
local RECOMPENSAS = (Config.Economia and Config.Economia.Recompensas) or {}

ClassroomService.MaxActividadesPorSesion = 30 -- Actividades que admite una misma sesión.
ClassroomService.SegundosMin = 30 -- Duración mínima de una actividad.
ClassroomService.SegundosMax = 600 -- Duración máxima de una actividad.
ClassroomService.SegundosPorDefecto = 120
ClassroomService.MinOpciones = 2
ClassroomService.MaxOpciones = 4
ClassroomService.MaxPreguntaCaracteres = 200
ClassroomService.MaxOpcionCaracteres = 60
ClassroomService.MaxComentarioCaracteres = 120
ClassroomService.MaxTemaCaracteres = LIMITES.MaxTemaCaracteres or 80
ClassroomService.MaxAvisoCaracteres = LIMITES.MaxAvisoCaracteres or 160
ClassroomService.MaxRespuestaCaracteres = LIMITES.MaxRespuestaCaracteres or 300
ClassroomService.InvitacionSeg = 20 -- Caducidad de una invitación al tablero.
ClassroomService.TurnoTableroSeg = (Config.Tablero and Config.Tablero.TurnoSeg) or 90
ClassroomService.DistanciaAperturaMax = 12 -- Studs fuera de la caja del aula para abrir sesión.
ClassroomService.SoloEnPeriodoClase = true -- Abrir sesión, actividades, respuestas, manos y tablero solo en CLASE_n.
ClassroomService.CerrarAlTerminarPeriodo = true -- Al pasar a un periodo que no es de clase se cierran las sesiones.
ClassroomService.IntervaloEstadoDocenteSeg = 1 -- Agrupa las actualizaciones de ocupación enviadas al docente.
ClassroomService.LimpiarTableroAlCerrar = true -- Al cerrar la sesión se limpia el tablero del aula (BoardService:Limpiar).

-- Segundos mínimos entre dos acciones iguales y aceptadas del mismo jugador.
ClassroomService.Cooldowns = {
	AbrirSesion = 3, FijarTema = 2, EnviarAviso = 5, TomarAsistencia = 3, CrearActividad = 3,
	InvitarTablero = 2, PublicarResultados = 3, LevantarMano = 2,
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

local function ahora()
	local ok, valor = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(valor) == "number" then
		return valor
	end
	return os.time()
end

local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function entero(valor, minimo, maximo)
	local n = tonumber(valor)
	if not esFinito(n) or math.floor(n) ~= n then
		return nil
	end
	if (minimo and n < minimo) or (maximo and n > maximo) then
		return nil
	end
	return n
end

local function contar(tabla)
	local n = 0
	for _ in pairs(tabla or {}) do
		n = n + 1
	end
	return n
end

-- Limpia un texto del jugador: quita caracteres de control (conserva saltos si se permiten), recorta espacios
-- y comprueba UTF-8 y longitud. Devuelve texto | nil, motivo.
local function limpiarTexto(texto, maximo, permitirSaltos)
	if typeof(texto) ~= "string" or utf8.len(texto) == nil then
		return nil, "invalido"
	end
	local limpio = string.gsub(texto, "%c", function(c)
		if c == "\n" and permitirSaltos then
			return "\n"
		end
		if c == "\n" or c == "\t" then
			return " "
		end
		return ""
	end)
	limpio = string.gsub(limpio, "^%s+", "")
	limpio = string.gsub(limpio, "%s+$", "")
	if limpio == "" then
		return nil, "vacio"
	end
	local n = utf8.len(limpio)
	if n == nil then
		return nil, "invalido"
	end
	if n > maximo then
		return nil, "largo"
	end
	return limpio
end

-- Filtra con TextService. paraUserId = nil -> texto apto para todos (broadcast). Devuelve texto | nil.
local function filtrar(texto, deUserId, paraUserId)
	local okFiltro, resultado = pcall(function()
		return TextService:FilterStringAsync(texto, deUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFiltro or resultado == nil then
		return nil
	end
	local okTexto, filtrado = pcall(function()
		if paraUserId then
			return resultado:GetNonChatStringForUserAsync(paraUserId)
		end
		return resultado:GetNonChatStringForBroadcastAsync()
	end)
	if not okTexto or typeof(filtrado) ~= "string" then
		return nil
	end
	return filtrado
end

local function nombreAula(roomId)
	local zona = MapaLogico.Zonas[roomId]
	if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= "" then
		return zona.Nombre
	end
	return tostring(roomId)
end

local function nombreDe(userId, respaldo)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.DisplayName
	end
	return respaldo or ("Usuario " .. tostring(userId))
end

local function raizDe(player)
	local personaje = player and player.Character
	local raiz = personaje and personaje:FindFirstChild("HumanoidRootPart")
	if raiz and raiz:IsA("BasePart") then
		return raiz
	end
	return nil
end

local function conectar(senal, fn)
	if senal == nil then
		return nil
	end
	local ok, conexion = pcall(function()
		return senal:Connect(fn)
	end)
	if ok then
		return conexion
	end
	return nil
end

-- Normaliza la asistencia de SchoolDayService (array de registros o mapa userId -> estado) a un array seguro
-- para enviar por red: { {UserId, Nombre, Estado} }.
local function normalizarAsistencia(valor)
	local lista = {}
	if typeof(valor) ~= "table" then
		return lista
	end
	local fuente = valor
	if typeof(valor.Registros) == "table" then
		fuente = valor.Registros
	elseif typeof(valor.Lista) == "table" then
		fuente = valor.Lista
	elseif typeof(valor.Alumnos) == "table" then
		fuente = valor.Alumnos
	end
	for clave, registro in pairs(fuente) do
		if #lista >= 60 then
			break
		end
		local userId, estado = nil, nil
		if typeof(registro) == "table" then
			userId = tonumber(registro.UserId) or tonumber(clave)
			estado = registro.Estado
		elseif typeof(registro) == "string" then
			userId = tonumber(clave)
			estado = registro
		end
		if userId and typeof(estado) == "string" then
			table.insert(lista, { UserId = userId, Nombre = nombreDe(userId), Estado = string.sub(estado, 1, 24) })
		end
	end
	table.sort(lista, function(a, b)
		return a.Nombre < b.Nombre
	end)
	return lista
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function ClassroomService:Init(registro)
	self.registro = registro
	self.Sesiones = {} -- roomId -> sesion
	self.SesionPorDocente = {} -- userId del docente -> roomId
	self.Invitaciones = {} -- roomId -> { UserId, Nombre, Expira, SessionId }
	self.UltimaAccion = {} -- userId -> { accion -> os.clock() }
	self.Contador = 0
	self._estadoPendiente = {} -- roomId -> true mientras hay un envío de Estado programado
	self.SesionAbierta = Signal.new() -- (sesion)
	self.SesionCerrada = Signal.new() -- (sesion, motivo)
	self.ActividadCreada = Signal.new() -- (sesion, actividad)
	self.ActividadCerrada = Signal.new() -- (sesion, actividad)
	self.maid = Maid.new()
	self.Acciones = {
		AbrirSesion = ClassroomService.AccionAbrirSesion,
		CerrarSesion = ClassroomService.AccionCerrarSesion,
		FijarTema = ClassroomService.AccionFijarTema,
		EnviarAviso = ClassroomService.AccionEnviarAviso,
		TomarAsistencia = ClassroomService.AccionTomarAsistencia,
		CrearActividad = ClassroomService.AccionCrearActividad,
		CerrarActividad = ClassroomService.AccionCerrarActividad,
		InvitarTablero = ClassroomService.AccionInvitarTablero,
		RevocarTablero = ClassroomService.AccionRevocarTablero,
		Calificar = ClassroomService.AccionCalificar,
		Responder = ClassroomService.AccionResponder,
		LevantarMano = ClassroomService.AccionLevantarMano,
		AceptarInvitacion = ClassroomService.AccionAceptarInvitacion,
		ConsultarEstado = ClassroomService.AccionConsultarEstado,
		PublicarResultados = ClassroomService.AccionPublicarResultados,
	}
end

function ClassroomService:Start()
	local RemoteService = self.registro.Get("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("RequestClassAction", function(player, datos)
			return self:Manejar(player, datos)
		end)
	else
		warn(PREFIJO .. " RemoteService no disponible: RequestClassAction no tendrá handler.")
	end

	self.maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:AlSalirJugador(player)
	end))

	local RoleService = self.registro.Get("RoleService")
	if RoleService and RoleService.CargoCambiado then
		local conexion = conectar(RoleService.CargoCambiado, function(player, cargo, anterior)
			self:AlCambiarCargo(player, cargo, anterior)
		end)
		if conexion then
			self.maid:GiveTask(conexion)
		end
	end

	local SchoolDayService = self.registro.Get("SchoolDayService")
	if SchoolDayService then
		local fin = conectar(SchoolDayService.JornadaTerminada, function()
			self:CerrarTodas("Terminó la jornada escolar.")
		end)
		if fin then
			self.maid:GiveTask(fin)
		end
		local cambio = conectar(SchoolDayService.EstadoCambiado, function(estado, snapshot)
			self:AlCambiarPeriodo(estado, snapshot)
		end)
		if cambio then
			self.maid:GiveTask(cambio)
		end
	end

	local RoomService = self.registro.Get("RoomService")
	if RoomService and RoomService.OcupacionCambiada then
		local conexion = conectar(RoomService.OcupacionCambiada, function(roomId)
			self:ProgramarEstadoDocente(roomId)
		end)
		if conexion then
			self.maid:GiveTask(conexion)
		end
	end

	-- BoardService puede terminar el turno por su cuenta (vence, limpieza, otra aula, sesión cerrada):
	-- la sesión se sincroniza para no bloquear nuevas invitaciones con un turno que ya no existe.
	local BoardService = self.registro.Get("BoardService")
	if BoardService and BoardService.TurnoCambiado then
		local conexion = conectar(BoardService.TurnoCambiado, function(roomId, turno, motivo)
			self:AlCambiarTurnoTablero(roomId, turno, motivo)
		end)
		if conexion then
			self.maid:GiveTask(conexion)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Acceso a otros servicios (tolerante a ausencia)
---------------------------------------------------------------------------------------------------
function ClassroomService:Servicio(nombre)
	return self.registro and self.registro.Get(nombre) or nil
end

-- Llama servicio:metodo(...) en pcall. Devuelve ok, r1, r2 (ok = false si no existe o falla).
function ClassroomService:Llamar(nombre, metodo, ...)
	local servicio = self:Servicio(nombre)
	if not servicio or typeof(servicio[metodo]) ~= "function" then
		return false
	end
	local resultado = table.pack(pcall(servicio[metodo], servicio, ...))
	if not resultado[1] then
		warn(PREFIJO .. " " .. nombre .. ":" .. metodo .. " falló: " .. tostring(resultado[2]))
		return false
	end
	return true, resultado[2], resultado[3]
end

function ClassroomService:Auditar(player, accion, detalle)
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, "Clase", player, accion, detalle)
	end
end

function ClassroomService:EnviarA(player, tipo, datos)
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and esJugador(player) then
		return RemoteService:Enviar(player, tipo, datos)
	end
	return false
end

-- Evento "Aula" a un jugador concreto (Sub = subtipo).
function ClassroomService:Enviar(player, sub, datos)
	datos = datos or {}
	datos.Sub = sub
	return self:EnviarA(player, "Aula", datos)
end

function ClassroomService:Notificar(player, texto, nivel, duracion)
	return self:EnviarA(player, "Notificacion", { Texto = texto, Nivel = nivel or "info", Duracion = duracion })
end

-- Respuesta de rechazo de lógica: { ok=false, error="rechazado:<codigo>", mensaje }. auditar = true la registra.
function ClassroomService:Rechazo(player, accion, codigo, mensaje, auditar)
	if auditar then
		self:Auditar(player, "Rechazo:" .. tostring(accion), tostring(codigo) .. " · " .. tostring(mensaje))
		self:Llamar("MetricsService", "IncrementarRechazo", "RequestClassAction", "clase_" .. tostring(codigo))
	end
	return { ok = false, error = "rechazado:" .. tostring(codigo), mensaje = mensaje }
end

local function exito(datos)
	return { ok = true, datos = datos or {} }
end

function ClassroomService:EsAulaValida(roomId)
	if typeof(roomId) ~= "string" or roomId == "" then
		return false
	end
	local MapService = self:Servicio("MapService")
	if MapService and typeof(MapService.EsAula) == "function" then
		local ok, es = pcall(MapService.EsAula, MapService, roomId)
		if ok and es == true then
			return true
		end
	end
	return Zones.EsAula(roomId)
end

function ClassroomService:CargoDe(player)
	local ok, cargo = self:Llamar("RoleService", "Cargo", player)
	if ok and typeof(cargo) == "string" then
		return cargo
	end
	return player:GetAttribute("Cargo")
end

function ClassroomService:Tiene(player, permiso)
	local ok, tiene = self:Llamar("RoleService", "Tiene", player, permiso)
	if ok then
		return tiene == true
	end
	local cargo = player:GetAttribute("Cargo")
	return typeof(cargo) == "string" and RoleDefinitions.Tiene(cargo, permiso)
end

function ClassroomService:SalonDe(player)
	local ok, salon = self:Llamar("RoleService", "Salon", player)
	if ok and typeof(salon) == "string" and salon ~= "" then
		return salon
	end
	local atributo = player:GetAttribute("Salon")
	if typeof(atributo) == "string" and atributo ~= "" then
		return atributo
	end
	return nil
end

-- ¿Puede el jugador dirigir clases en esa aula? aula.docente y (su Salon o horario.editar).
function ClassroomService:PuedeDirigir(player, roomId)
	if not self:Tiene(player, "aula.docente") then
		return false
	end
	if self:Tiene(player, "horario.editar") then
		return true
	end
	return self:SalonDe(player) == roomId
end

-- Jugadores presentes en el aula (RoomService; respaldo por zona).
function ClassroomService:JugadoresEnAula(roomId)
	local ok, lista = self:Llamar("RoomService", "JugadoresEn", roomId)
	if ok and typeof(lista) == "table" then
		return lista
	end
	local resultado = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local raiz = raizDe(player)
		if raiz and Zones.Contiene(roomId, raiz.Position) then
			table.insert(resultado, player)
		end
	end
	return resultado
end

function ClassroomService:EstaEnAula(player, roomId)
	if not esJugador(player) then
		return false
	end
	local ok, esta = self:Llamar("RoomService", "EstaEn", player, roomId)
	if ok then
		return esta == true
	end
	local raiz = raizDe(player)
	return raiz ~= nil and Zones.Contiene(roomId, raiz.Position)
end

function ClassroomService:CercaDelAula(player, roomId)
	if self:EstaEnAula(player, roomId) then
		return true
	end
	local raiz = raizDe(player)
	if not raiz then
		return false
	end
	return Zones.DistanciaA(roomId, raiz.Position) <= self.DistanciaAperturaMax
end

-- ¿Estamos en un periodo de clase? Devuelve true | false, nombreDelPeriodo. Sin SchoolDayService: true.
function ClassroomService:EnClase()
	if not self.SoloEnPeriodoClase then
		return true
	end
	local ok, enClase = self:Llamar("SchoolDayService", "EnPeriodoClase")
	if not ok or enClase == true then
		return true
	end
	local nombre = "fuera de clase"
	local okSnap, snapshot = self:Llamar("SchoolDayService", "Snapshot")
	if okSnap and typeof(snapshot) == "table" and typeof(snapshot.Nombre) == "string" then
		nombre = snapshot.Nombre
	end
	return false, nombre
end

function ClassroomService:MateriaActual()
	local ok, snapshot = self:Llamar("SchoolDayService", "Snapshot")
	if ok and typeof(snapshot) == "table" and TimetableDefinitions.ExisteMateria(snapshot.Materia) then
		return snapshot.Materia
	end
	return nil
end

function ClassroomService:Acreditar(player, monto, tipo, detalle)
	monto = tonumber(monto) or 0
	if monto <= 0 then
		return false
	end
	local ok, resultado = self:Llamar("EconomyService", "Acreditar", player, monto, tipo, detalle)
	return ok and resultado ~= false
end

function ClassroomService:SumarProgreso(player, clave, cantidad)
	local ok, perfil = self:Llamar("DataService", "Obtener", player)
	if not ok or typeof(perfil) ~= "table" then
		return
	end
	if typeof(perfil.Progreso) ~= "table" then
		perfil.Progreso = {}
	end
	perfil.Progreso[clave] = (tonumber(perfil.Progreso[clave]) or 0) + (cantidad or 1)
	self:Llamar("DataService", "Marcar", player)
end

---------------------------------------------------------------------------------------------------
-- Cooldowns por acción
---------------------------------------------------------------------------------------------------
function ClassroomService:EsperaRestante(player, accion)
	local segundos = self.Cooldowns[accion]
	if not segundos then
		return 0
	end
	local porJugador = self.UltimaAccion[player.UserId]
	local ultimo = porJugador and porJugador[accion]
	if not ultimo then
		return 0
	end
	local restante = segundos - (os.clock() - ultimo)
	if restante > 0 then
		return restante
	end
	return 0
end

function ClassroomService:MarcarAccion(player, accion)
	if not self.Cooldowns[accion] then
		return
	end
	local porJugador = self.UltimaAccion[player.UserId]
	if not porJugador then
		porJugador = {}
		self.UltimaAccion[player.UserId] = porJugador
	end
	porJugador[accion] = os.clock()
end

---------------------------------------------------------------------------------------------------
-- Entrada del remoto
---------------------------------------------------------------------------------------------------
function ClassroomService:Manejar(player, datos)
	if not esJugador(player) or typeof(datos) ~= "table" then
		return { ok = false, error = "rechazado:datos" }
	end
	local accion = datos.Accion
	local roomId = datos.Salon
	local d = datos.Datos
	if typeof(d) ~= "table" then
		d = {}
	end
	local metodo = self.Acciones[accion]
	if not metodo then
		return self:Rechazo(player, accion, "accion_desconocida", "Acción de clase desconocida.", true)
	end
	if not self:EsAulaValida(roomId) then
		return self:Rechazo(player, accion, "aula_desconocida", "Esa aula no existe.", true)
	end
	local espera = self:EsperaRestante(player, accion)
	if espera > 0 then
		return {
			ok = false, error = "rechazado:cooldown",
			mensaje = string.format("Espera %d s antes de repetir esta acción.", math.ceil(espera)),
		}
	end
	local respuesta = metodo(self, player, roomId, d)
	if typeof(respuesta) == "table" and respuesta.ok == true then
		self:MarcarAccion(player, accion)
	end
	return respuesta
end

---------------------------------------------------------------------------------------------------
-- Sesiones: consultas
---------------------------------------------------------------------------------------------------

-- Sesión abierta del aula (tabla interna; solo lectura para otros servicios) o nil.
function ClassroomService:SesionDe(roomId)
	return self.Sesiones[roomId]
end

-- ¿El jugador es el docente de la sesión abierta en el aula?
function ClassroomService:EsDocenteDe(player, roomId)
	local sesion = self.Sesiones[roomId]
	return sesion ~= nil and esJugador(player) and sesion.TeacherUserId == player.UserId
end

-- Sesión relevante para el jugador: la que dirige o, si no, la del aula donde está presente.
function ClassroomService:SesionDeJugador(player)
	if not esJugador(player) then
		return nil
	end
	local propia = self.SesionPorDocente[player.UserId]
	if propia and self.Sesiones[propia] then
		return self.Sesiones[propia]
	end
	local ok, aula = self:Llamar("RoomService", "AulaActualDe", player)
	if ok and typeof(aula) == "string" and self.Sesiones[aula] then
		return self.Sesiones[aula]
	end
	if not ok then
		for roomId, sesion in pairs(self.Sesiones) do
			if self:EstaEnAula(player, roomId) then
				return sesion
			end
		end
	end
	return nil
end

-- Sesión que dirige el jugador en esa aula o nil, rechazo.
function ClassroomService:SesionDelDocente(player, roomId, accion)
	local sesion = self.Sesiones[roomId]
	if not sesion then
		return nil, self:Rechazo(player, accion, "sin_sesion", "No hay una sesión abierta en esta aula.")
	end
	if sesion.TeacherUserId ~= player.UserId then
		return nil, self:Rechazo(player, accion, "no_es_tu_sesion", "Esta sesión la dirige " .. tostring(sesion.TeacherName) .. ".", true)
	end
	return sesion
end

-- Actividad por id (o la activa, o la última) de una sesión.
local function actividadDe(sesion, id)
	if typeof(id) == "string" and sesion.Actividades[id] then
		return sesion.Actividades[id]
	end
	if id == nil then
		local activa = sesion.ActiveActivityId and sesion.Actividades[sesion.ActiveActivityId]
		if activa then
			return activa
		end
		return sesion.UltimaActividadId and sesion.Actividades[sesion.UltimaActividadId] or nil
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Envíos a la sala (P4: solo presentes en el aula + docente de la sesión)
---------------------------------------------------------------------------------------------------

-- opciones: { SinDocente = bool, SoloEstudiantes = bool (excluye al docente) }
function ClassroomService:EnviarAula(sesion, sub, datos, opciones)
	opciones = opciones or {}
	datos = datos or {}
	datos.Sub = sub
	datos.RoomId = sesion.RoomId
	datos.SessionId = sesion.SessionId
	local enviados = {}
	local total = 0
	for _, player in ipairs(self:JugadoresEnAula(sesion.RoomId)) do
		local esDocente = player.UserId == sesion.TeacherUserId
		if not (esDocente and (opciones.SoloEstudiantes or opciones.SinDocente)) then
			if not enviados[player.UserId] then
				enviados[player.UserId] = true
				if self:EnviarA(player, "Aula", datos) then
					total = total + 1
				end
			end
		end
	end
	if not opciones.SinDocente and not opciones.SoloEstudiantes and not enviados[sesion.TeacherUserId] then
		local docente = Players:GetPlayerByUserId(sesion.TeacherUserId)
		if docente and self:EnviarA(docente, "Aula", datos) then
			total = total + 1
		end
	end
	return total
end

function ClassroomService:EnviarDocente(sesion, sub, datos)
	local docente = Players:GetPlayerByUserId(sesion.TeacherUserId)
	if not docente then
		return false
	end
	datos = datos or {}
	datos.RoomId = sesion.RoomId
	datos.SessionId = sesion.SessionId
	return self:Enviar(docente, sub, datos)
end

---------------------------------------------------------------------------------------------------
-- Representaciones para el cliente (solo arrays y diccionarios con claves de texto)
---------------------------------------------------------------------------------------------------
local function copiarOpciones(opciones)
	if typeof(opciones) ~= "table" then
		return nil
	end
	local copia = {}
	for i, texto in ipairs(opciones) do
		copia[i] = texto
	end
	return copia
end

function ClassroomService:ActividadPublica(act, paraDocente)
	local datos = {
		Id = act.Id,
		Type = act.Type,
		Prompt = act.Prompt,
		Options = copiarOpciones(act.Options),
		CreatedAt = act.CreatedAt,
		DueAt = act.DueAt,
		Segundos = act.Segundos,
		Estado = act.Estado,
		Respuestas = contar(act.Submissions),
	}
	if paraDocente then
		datos.Correcta = act.Correcta
		datos.Calificadas = contar(act.Grades)
	end
	return datos
end

function ClassroomService:ListaRespuestas(act)
	local lista = {}
	for userId, envio in pairs(act.Submissions) do
		local nota = act.Grades[userId]
		table.insert(lista, {
			UserId = userId,
			Nombre = nombreDe(userId, envio.Nombre),
			Respuesta = envio.Respuesta,
			Indice = envio.Indice,
			Correcta = envio.Correcta,
			T = envio.T,
			Puntos = nota and nota.Puntos or nil,
			Comentario = nota and nota.Comentario or nil,
		})
	end
	table.sort(lista, function(a, b)
		return (a.T or 0) < (b.T or 0)
	end)
	return lista
end

function ClassroomService:ListaManos(sesion)
	local lista = {}
	for userId, t in pairs(sesion.ManosLevantadas) do
		table.insert(lista, { UserId = userId, Nombre = nombreDe(userId), T = t })
	end
	table.sort(lista, function(a, b)
		return a.T < b.T
	end)
	return lista
end

-- Ocupación con nombres, sin el docente de la sesión: { Sentados, DePie, Capacidad, Total }.
function ClassroomService:OcupacionConNombres(roomId, docenteUserId)
	local ocupacion = nil
	local ok, resultado = self:Llamar("RoomService", "Ocupacion", roomId)
	if ok and typeof(resultado) == "table" then
		ocupacion = resultado
	else
		ocupacion = { Sentados = {}, DePie = {}, Capacidad = 0 }
		for _, player in ipairs(self:JugadoresEnAula(roomId)) do
			table.insert(ocupacion.DePie, player.UserId)
		end
	end
	local function conNombres(ids)
		local lista = {}
		for _, userId in ipairs(ids or {}) do
			if userId ~= docenteUserId then
				table.insert(lista, { UserId = userId, Nombre = nombreDe(userId) })
			end
		end
		table.sort(lista, function(a, b)
			return a.Nombre < b.Nombre
		end)
		return lista
	end
	local sentados = conNombres(ocupacion.Sentados)
	local dePie = conNombres(ocupacion.DePie)
	return { Sentados = sentados, DePie = dePie, Capacidad = ocupacion.Capacidad or 0, Total = #sentados + #dePie }
end

function ClassroomService:DatosBase(sesion)
	return {
		SesionAbierta = sesion.State == "Abierta",
		SessionId = sesion.SessionId,
		RoomId = sesion.RoomId,
		NombreAula = sesion.NombreAula,
		Docente = sesion.TeacherName,
		DocenteUserId = sesion.TeacherUserId,
		Tema = sesion.Tema,
		Materia = sesion.Materia,
		NombreMateria = sesion.Materia and TimetableDefinitions.NombreMateria(sesion.Materia) or nil,
		StartedAt = sesion.StartedAt,
		HoraServidor = ahora(),
	}
end

function ClassroomService:InvitacionPublica(roomId, sesion)
	local inv = self.Invitaciones[roomId]
	if inv and inv.SessionId == sesion.SessionId and ahora() <= inv.Expira then
		return inv
	end
	return nil
end

function ClassroomService:TurnoPublico(sesion)
	if sesion.InvitadoTablero and sesion.TurnoHasta and ahora() <= sesion.TurnoHasta then
		return { UserId = sesion.InvitadoTablero, Nombre = nombreDe(sesion.InvitadoTablero), Hasta = sesion.TurnoHasta }
	end
	return nil
end

-- Vista completa del docente.
function ClassroomService:SnapshotDocente(sesion)
	local datos = self:DatosBase(sesion)
	datos.Rol = "Docente"
	local activa = sesion.ActiveActivityId and sesion.Actividades[sesion.ActiveActivityId] or nil
	if activa then
		datos.ActividadActiva = self:ActividadPublica(activa, true)
	end
	local referencia = actividadDe(sesion, nil)
	if referencia then
		datos.ActividadRespuestas = self:ActividadPublica(referencia, true)
		datos.Respuestas = self:ListaRespuestas(referencia)
	else
		datos.Respuestas = {}
	end
	datos.Actividades = {}
	for _, id in ipairs(sesion.OrdenActividades) do
		local act = sesion.Actividades[id]
		if act then
			table.insert(datos.Actividades, {
				Id = act.Id, Type = act.Type, Prompt = act.Prompt, Estado = act.Estado,
				Respuestas = contar(act.Submissions), Calificadas = contar(act.Grades), Publicada = act.Publicada == true,
			})
		end
	end
	datos.Manos = self:ListaManos(sesion)
	local inv = self:InvitacionPublica(sesion.RoomId, sesion)
	if inv then
		datos.Invitacion = { UserId = inv.UserId, Nombre = inv.Nombre, Expira = inv.Expira }
	end
	datos.TurnoTablero = self:TurnoPublico(sesion)
	datos.Ocupacion = self:OcupacionConNombres(sesion.RoomId, sesion.TeacherUserId)
	return datos
end

-- Vista del estudiante: solo lo suyo (su respuesta, sus resultados, su mano, su invitación).
function ClassroomService:SnapshotEstudiante(sesion, player)
	local userId = player.UserId
	local datos = self:DatosBase(sesion)
	datos.Rol = "Estudiante"
	local activa = sesion.ActiveActivityId and sesion.Actividades[sesion.ActiveActivityId] or nil
	if activa then
		local publica = self:ActividadPublica(activa, false)
		publica.Respuestas = nil
		local envio = activa.Submissions[userId]
		if envio then
			publica.MiRespuesta = { Respuesta = envio.Respuesta, Indice = envio.Indice, T = envio.T }
		end
		datos.ActividadActiva = publica
	end
	datos.MisResultados = {}
	for _, id in ipairs(sesion.OrdenActividades) do
		local act = sesion.Actividades[id]
		local nota = act and act.Grades[userId]
		local envio = act and act.Submissions[userId]
		if act and (nota or (envio and act.Estado == "Cerrada" and envio.Correcta ~= nil)) then
			local correcta = nil
			if act.Estado == "Cerrada" and envio and envio.Correcta ~= nil then
				correcta = envio.Correcta == true
			end
			table.insert(datos.MisResultados, {
				ActividadId = act.Id,
				Prompt = act.Prompt,
				Puntos = nota and nota.Puntos or nil,
				Comentario = nota and nota.Comentario or nil,
				Correcta = correcta,
			})
		end
	end
	datos.ManoLevantada = sesion.ManosLevantadas[userId] ~= nil
	local inv = self:InvitacionPublica(sesion.RoomId, sesion)
	if inv and inv.UserId == userId then
		datos.Invitacion = { Expira = inv.Expira, Docente = sesion.TeacherName }
	end
	local turno = self:TurnoPublico(sesion)
	if turno then
		turno.EsMio = turno.UserId == userId
		datos.TurnoTablero = turno
	end
	return datos
end

-- Snapshot para StateSnapshot: sesión que dirige el jugador o la del aula en la que está (nil si ninguna).
function ClassroomService:Snapshot(player)
	if not esJugador(player) then
		return nil
	end
	local propia = self.SesionPorDocente[player.UserId]
	if propia and self.Sesiones[propia] then
		return self:SnapshotDocente(self.Sesiones[propia])
	end
	local sesion = self:SesionDeJugador(player)
	if sesion then
		return self:SnapshotEstudiante(sesion, player)
	end
	return nil
end

-- Resumen de todas las sesiones abiertas (paneles de dirección/coordinación).
function ClassroomService:Resumen()
	local lista = {}
	for roomId, sesion in pairs(self.Sesiones) do
		local activa = sesion.ActiveActivityId and sesion.Actividades[sesion.ActiveActivityId] or nil
		table.insert(lista, {
			RoomId = roomId,
			NombreAula = sesion.NombreAula,
			Docente = sesion.TeacherName,
			Tema = sesion.Tema,
			Materia = sesion.Materia,
			StartedAt = sesion.StartedAt,
			Presentes = #self:JugadoresEnAula(roomId),
			Actividades = #sesion.OrdenActividades,
			ActividadActiva = activa and activa.Prompt or nil,
		})
	end
	table.sort(lista, function(a, b)
		return a.RoomId < b.RoomId
	end)
	return lista
end

---------------------------------------------------------------------------------------------------
-- Cierre de actividades y sesiones
---------------------------------------------------------------------------------------------------
function ClassroomService:CerrarActividadInterna(sesion, act, motivo)
	if not act or act.Estado ~= "Abierta" then
		return false
	end
	act.Estado = "Cerrada"
	act.CerradaEn = ahora()
	if sesion.ActiveActivityId == act.Id then
		sesion.ActiveActivityId = nil
	end
	sesion.UltimaActividadId = act.Id

	-- Corrección automática: resultado privado a cada alumno y bonificación por acierto.
	if act.Type == "Opciones" and act.Correcta then
		local textoCorrecta = act.Options and act.Options[act.Correcta] or nil
		for userId, envio in pairs(act.Submissions) do
			local alumno = Players:GetPlayerByUserId(userId)
			if alumno then
				if envio.Correcta then
					self:Acreditar(alumno, RECOMPENSAS.Participacion, "Participacion", "Respuesta correcta · " .. sesion.RoomId)
					self:SumarProgreso(alumno, "RespuestasCorrectas", 1)
				end
				self:Enviar(alumno, "Resultado", {
					RoomId = sesion.RoomId, SessionId = sesion.SessionId, ActividadId = act.Id, Prompt = act.Prompt,
					Automatico = true, Correcta = envio.Correcta == true, TuRespuesta = envio.Respuesta,
					RespuestaCorrecta = textoCorrecta,
				})
			end
		end
	end

	self:EnviarAula(sesion, "ActividadCerrada", {
		ActividadId = act.Id, Motivo = motivo or "El docente cerró la actividad.", Respuestas = contar(act.Submissions),
	}, { SinDocente = true })
	self:EnviarDocente(sesion, "ActividadCerrada", {
		ActividadId = act.Id, Motivo = motivo, Actividad = self:ActividadPublica(act, true),
		Respuestas = self:ListaRespuestas(act),
	})
	self.ActividadCerrada:Fire(sesion, act)
	return true
end

function ClassroomService:CerrarSesionInterna(sesion, motivo, actor)
	if not sesion or sesion.State ~= "Abierta" then
		return false
	end
	local roomId = sesion.RoomId
	local activa = sesion.ActiveActivityId and sesion.Actividades[sesion.ActiveActivityId] or nil
	if activa then
		self:CerrarActividadInterna(sesion, activa, "La sesión se cerró.")
	end
	sesion.State = "Cerrada"
	sesion.ClosedAt = os.time()
	if sesion.InvitadoTablero then
		sesion.InvitadoTablero = nil
		sesion.TurnoHasta = nil
		self:Llamar("BoardService", "RevocarTurno", roomId)
	end
	self.Invitaciones[roomId] = nil
	-- La próxima clase empieza con el tablero limpio (BoardService también limpia al terminar la jornada).
	if self.LimpiarTableroAlCerrar then
		self:Llamar("BoardService", "Limpiar", roomId, "Fin de la sesión")
	end

	-- Presentes al cierre cuentan como asistentes; clase completada para los estudiantes conectados.
	for _, player in ipairs(self:JugadoresEnAula(roomId)) do
		if player.UserId ~= sesion.TeacherUserId then
			sesion.PresentUserIds[player.UserId] = true
		end
	end
	for userId in pairs(sesion.PresentUserIds) do
		local alumno = Players:GetPlayerByUserId(userId)
		if alumno and userId ~= sesion.TeacherUserId then
			self:SumarProgreso(alumno, "ClasesCompletadas", 1)
		end
	end

	self:EnviarAula(sesion, "SesionCerrada", { Motivo = motivo or "La sesión terminó.", Docente = sesion.TeacherName })
	if self.Sesiones[roomId] == sesion then
		self.Sesiones[roomId] = nil
	end
	if self.SesionPorDocente[sesion.TeacherUserId] == roomId then
		self.SesionPorDocente[sesion.TeacherUserId] = nil
	end
	self:Auditar(actor, "CerrarSesion", string.format("%s · %s · %s · %d actividades · %d asistentes",
		roomId, tostring(sesion.TeacherName), tostring(motivo), #sesion.OrdenActividades, contar(sesion.PresentUserIds)))
	self.SesionCerrada:Fire(sesion, motivo)
	return true
end

-- Cierra todas las sesiones abiertas (fin de jornada, fin de periodo, mantenimiento).
function ClassroomService:CerrarTodas(motivo)
	local lista = {}
	for _, sesion in pairs(self.Sesiones) do
		table.insert(lista, sesion)
	end
	for _, sesion in ipairs(lista) do
		self:CerrarSesionInterna(sesion, motivo or "Se cerraron todas las sesiones.")
	end
	return #lista
end

---------------------------------------------------------------------------------------------------
-- Cancelación automática
---------------------------------------------------------------------------------------------------
function ClassroomService:QuitarAlumno(userId, motivo)
	for roomId, sesion in pairs(self.Sesiones) do
		if sesion.ManosLevantadas[userId] then
			sesion.ManosLevantadas[userId] = nil
			self:EnviarDocente(sesion, "Mano", { UserId = userId, Levantada = false, Manos = self:ListaManos(sesion) })
		end
		local inv = self.Invitaciones[roomId]
		if inv and inv.UserId == userId then
			self.Invitaciones[roomId] = nil
			self:EnviarDocente(sesion, "Invitacion", { UserId = userId, Nombre = inv.Nombre, Caducada = true, Motivo = motivo })
		end
		if sesion.InvitadoTablero == userId then
			sesion.InvitadoTablero = nil
			sesion.TurnoHasta = nil
			sesion.TurnoToken = (sesion.TurnoToken or 0) + 1
			self:Llamar("BoardService", "RevocarTurno", roomId)
			self:EnviarAula(sesion, "TurnoTablero", { Fin = true, UserId = userId, Motivo = motivo })
		end
	end
end

function ClassroomService:AlSalirJugador(player)
	local userId = player.UserId
	local roomId = self.SesionPorDocente[userId]
	if roomId and self.Sesiones[roomId] then
		self:CerrarSesionInterna(self.Sesiones[roomId], "El docente salió del servidor.", player)
	end
	self:QuitarAlumno(userId, "El estudiante salió del servidor.")
	self.UltimaAccion[userId] = nil
end

function ClassroomService:AlCambiarCargo(player, cargo, anterior)
	if not esJugador(player) or cargo == anterior then
		return
	end
	local roomId = self.SesionPorDocente[player.UserId]
	if roomId and self.Sesiones[roomId] then
		self:CerrarSesionInterna(self.Sesiones[roomId], "El docente cambió de cargo.", player)
	end
	self:QuitarAlumno(player.UserId, "Cambio de cargo.")
end

function ClassroomService:AlCambiarPeriodo(estado, snapshot)
	if typeof(estado) == "table" then
		snapshot = estado
		estado = estado.Estado
	end
	if typeof(estado) ~= "string" and typeof(snapshot) == "table" then
		estado = snapshot.Estado
	end
	if typeof(estado) ~= "string" or not self.CerrarAlTerminarPeriodo then
		return
	end
	if not TimetableDefinitions.EsClase(estado) and next(self.Sesiones) ~= nil then
		self:CerrarTodas("Terminó el periodo de clase (" .. TimetableDefinitions.Nombre(estado) .. ").")
	end
end

-- Fin de turno decidido por BoardService (turno = nil): limpia el invitado de la sesión y avisa a la sala.
function ClassroomService:AlCambiarTurnoTablero(roomId, turno, motivo)
	local sesion = typeof(roomId) == "string" and self.Sesiones[roomId] or nil
	if not sesion or sesion.State ~= "Abierta" or turno ~= nil or not sesion.InvitadoTablero then
		return
	end
	local userId = sesion.InvitadoTablero
	sesion.InvitadoTablero = nil
	sesion.TurnoHasta = nil
	sesion.TurnoToken = (sesion.TurnoToken or 0) + 1
	self:EnviarAula(sesion, "TurnoTablero", { Fin = true, UserId = userId, Motivo = "Terminó el turno." })
end

-- Agrupa los cambios de ocupación y envía al docente la lista actualizada (Sub "Estado", Parcial = true).
-- También baja las manos de quienes ya no están en el aula.
function ClassroomService:ProgramarEstadoDocente(roomId)
	if typeof(roomId) ~= "string" or not self.Sesiones[roomId] or self._estadoPendiente[roomId] then
		return
	end
	self._estadoPendiente[roomId] = true
	task.delay(self.IntervaloEstadoDocenteSeg, function()
		self._estadoPendiente[roomId] = nil
		local sesion = self.Sesiones[roomId]
		if not sesion then
			return
		end
		local presentes = {}
		for _, player in ipairs(self:JugadoresEnAula(roomId)) do
			presentes[player.UserId] = true
		end
		for userId in pairs(sesion.ManosLevantadas) do
			if not presentes[userId] then
				sesion.ManosLevantadas[userId] = nil
			end
		end
		self:EnviarDocente(sesion, "Estado", {
			Parcial = true,
			Ocupacion = self:OcupacionConNombres(roomId, sesion.TeacherUserId),
			Manos = self:ListaManos(sesion),
		})
	end)
end

---------------------------------------------------------------------------------------------------
-- Acciones del docente
---------------------------------------------------------------------------------------------------
function ClassroomService:AccionAbrirSesion(player, roomId, d)
	if not self:PuedeDirigir(player, roomId) then
		local salon = self:SalonDe(player)
		local texto = "Solo puedes abrir sesión en tu aula asignada."
		if salon then
			texto = "Solo puedes abrir sesión en tu aula asignada: " .. nombreAula(salon) .. " (" .. salon .. ")."
		end
		return self:Rechazo(player, "AbrirSesion", "no_es_tu_aula", texto, true)
	end
	local enClase, periodo = self:EnClase()
	if not enClase then
		return self:Rechazo(player, "AbrirSesion", "fuera_de_clase",
			"Solo se puede abrir sesión durante un periodo de clase (ahora: " .. tostring(periodo) .. ").")
	end
	if not self:CercaDelAula(player, roomId) then
		return self:Rechazo(player, "AbrirSesion", "lejos_del_aula", "Debes estar dentro del aula " .. nombreAula(roomId) .. " para abrir la sesión.")
	end
	local existente = self.Sesiones[roomId]
	if existente then
		if existente.TeacherUserId == player.UserId then
			return exito(self:SnapshotDocente(existente))
		end
		return self:Rechazo(player, "AbrirSesion", "aula_ocupada",
			"Ya hay una sesión abierta en esta aula (" .. tostring(existente.TeacherName) .. ").")
	end

	local tema = ""
	if d.Tema ~= nil and d.Tema ~= "" then
		local limpio, motivo = limpiarTexto(d.Tema, self.MaxTemaCaracteres, false)
		if not limpio then
			if motivo == "largo" then
				return self:Rechazo(player, "AbrirSesion", "texto", "El tema supera los " .. self.MaxTemaCaracteres .. " caracteres.")
			end
			return self:Rechazo(player, "AbrirSesion", "texto", "El tema no es válido.")
		end
		local filtrado = filtrar(limpio, player.UserId, nil)
		if not filtrado then
			return self:Rechazo(player, "AbrirSesion", "filtro", "No se pudo filtrar el tema; inténtalo de nuevo.")
		end
		tema = filtrado
	end

	-- Un docente = una sesión: si dirige otra, se cierra.
	local otra = self.SesionPorDocente[player.UserId]
	if otra and self.Sesiones[otra] then
		self:CerrarSesionInterna(self.Sesiones[otra], "El docente abrió una sesión en otra aula.", player)
	end
	-- La comprobación anterior pudo ceder (filtrado): se revisa de nuevo que el aula siga libre.
	if self.Sesiones[roomId] then
		return self:Rechazo(player, "AbrirSesion", "aula_ocupada", "Otra persona acaba de abrir sesión en esta aula.")
	end

	self.Contador = self.Contador + 1
	local sesion = {
		SessionId = string.format("S%d_%s", self.Contador, roomId),
		RoomId = roomId,
		NombreAula = nombreAula(roomId),
		TeacherUserId = player.UserId,
		TeacherName = player.DisplayName,
		StartedAt = os.time(),
		State = "Abierta",
		Tema = tema,
		Materia = self:MateriaActual(),
		PresentUserIds = {},
		ActiveActivityId = nil,
		UltimaActividadId = nil,
		Actividades = {},
		OrdenActividades = {},
		ContadorActividades = 0,
		ManosLevantadas = {},
		InvitadoTablero = nil,
		TurnoHasta = nil,
		TurnoToken = 0,
	}
	self.Sesiones[roomId] = sesion
	self.SesionPorDocente[player.UserId] = roomId

	local presentes = {}
	for _, alumno in ipairs(self:JugadoresEnAula(roomId)) do
		if alumno ~= player then
			sesion.PresentUserIds[alumno.UserId] = true
			presentes[alumno.UserId] = true
		end
	end

	local datosApertura = self:DatosBase(sesion)
	self:EnviarAula(sesion, "SesionAbierta", datosApertura)

	-- Estudiantes de esta aula que no están presentes: solo un recordatorio (sin datos de la clase).
	for _, alumno in ipairs(Players:GetPlayers()) do
		if alumno ~= player and not presentes[alumno.UserId] and self:SalonDe(alumno) == roomId
			and self:Tiene(alumno, "aula.estudiante") and not self:Tiene(alumno, "aula.docente") then
			self:Notificar(alumno, "Comenzó tu clase en " .. sesion.NombreAula .. ". Dirígete a tu salón.", "info", 6)
		end
	end

	self:Auditar(player, "AbrirSesion", string.format("%s · %s · tema: %s", roomId, sesion.SessionId, tema ~= "" and tema or "-"))
	self.SesionAbierta:Fire(sesion)
	return exito(self:SnapshotDocente(sesion))
end

function ClassroomService:AccionCerrarSesion(player, roomId, d)
	local sesion = self.Sesiones[roomId]
	if not sesion then
		return self:Rechazo(player, "CerrarSesion", "sin_sesion", "No hay una sesión abierta en esta aula.")
	end
	local esDocente = sesion.TeacherUserId == player.UserId
	if not esDocente and not self:Tiene(player, "horario.editar") then
		return self:Rechazo(player, "CerrarSesion", "no_es_tu_sesion", "Solo el docente de la sesión puede cerrarla.", true)
	end
	local motivo = "El docente cerró la sesión."
	if not esDocente then
		motivo = "Coordinación cerró la sesión."
	end
	self:CerrarSesionInterna(sesion, motivo, player)
	return exito({ Cerrada = true, RoomId = roomId })
end

function ClassroomService:AccionFijarTema(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "FijarTema")
	if not sesion then
		return rechazo
	end
	local limpio, motivo = limpiarTexto(d.Tema, self.MaxTemaCaracteres, false)
	if not limpio then
		if motivo == "largo" then
			return self:Rechazo(player, "FijarTema", "texto", "El tema supera los " .. self.MaxTemaCaracteres .. " caracteres.")
		end
		return self:Rechazo(player, "FijarTema", "texto", "Escribe un tema válido.")
	end
	local filtrado = filtrar(limpio, player.UserId, nil)
	if not filtrado then
		return self:Rechazo(player, "FijarTema", "filtro", "No se pudo filtrar el tema; inténtalo de nuevo.")
	end
	if self.Sesiones[roomId] ~= sesion then
		return self:Rechazo(player, "FijarTema", "sin_sesion", "La sesión ya no está abierta.")
	end
	sesion.Tema = filtrado
	self:EnviarAula(sesion, "Tema", { Tema = filtrado, Docente = sesion.TeacherName })
	self:Auditar(player, "FijarTema", roomId .. " · " .. filtrado)
	return exito({ Tema = filtrado })
end

function ClassroomService:AccionEnviarAviso(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "EnviarAviso")
	if not sesion then
		return rechazo
	end
	local limpio, motivo = limpiarTexto(d.Texto, self.MaxAvisoCaracteres, false)
	if not limpio then
		if motivo == "largo" then
			return self:Rechazo(player, "EnviarAviso", "texto", "El aviso supera los " .. self.MaxAvisoCaracteres .. " caracteres.")
		end
		return self:Rechazo(player, "EnviarAviso", "texto", "Escribe un aviso válido.")
	end
	local filtrado = filtrar(limpio, player.UserId, nil)
	if not filtrado then
		return self:Rechazo(player, "EnviarAviso", "filtro", "No se pudo filtrar el aviso; no se envió.")
	end
	if self.Sesiones[roomId] ~= sesion then
		return self:Rechazo(player, "EnviarAviso", "sin_sesion", "La sesión ya no está abierta.")
	end
	local enviados = self:EnviarAula(sesion, "Aviso", {
		Texto = filtrado, Docente = sesion.TeacherName, Cargo = self:CargoDe(player), T = ahora(),
	})
	self:Auditar(player, "EnviarAviso", roomId .. " · " .. filtrado)
	return exito({ Enviado = true, Destinatarios = enviados })
end

function ClassroomService:AccionTomarAsistencia(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "TomarAsistencia")
	if not sesion then
		return rechazo
	end
	local ocupacion = self:OcupacionConNombres(roomId, sesion.TeacherUserId)
	local sentados = {}
	for _, registro in ipairs(ocupacion.Sentados) do
		sesion.PresentUserIds[registro.UserId] = true
		sentados[registro.UserId] = true
	end
	for _, registro in ipairs(ocupacion.DePie) do
		sesion.PresentUserIds[registro.UserId] = true
	end
	local oficial = {}
	local ok, asistencia = self:Llamar("SchoolDayService", "Asistencia", roomId)
	if ok then
		oficial = normalizarAsistencia(asistencia)
	end
	local datos = {
		Sentados = ocupacion.Sentados,
		DePie = ocupacion.DePie,
		Capacidad = ocupacion.Capacidad,
		Total = ocupacion.Total,
		Oficial = oficial,
		T = ahora(),
	}
	self:EnviarDocente(sesion, "Asistencia", datos)
	for _, alumno in ipairs(self:JugadoresEnAula(roomId)) do
		if alumno.UserId ~= sesion.TeacherUserId then
			self:Enviar(alumno, "Asistencia", {
				RoomId = roomId, SessionId = sesion.SessionId, Propia = true, Estado = "Presente",
				Sentado = sentados[alumno.UserId] == true,
			})
		end
	end
	self:Auditar(player, "TomarAsistencia", string.format("%s · %d sentados · %d de pie", roomId, #ocupacion.Sentados, #ocupacion.DePie))
	return exito(datos)
end

function ClassroomService:AccionCrearActividad(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "CrearActividad")
	if not sesion then
		return rechazo
	end
	local enClase, periodo = self:EnClase()
	if not enClase then
		return self:Rechazo(player, "CrearActividad", "fuera_de_clase", "Las actividades solo se crean en periodo de clase (ahora: " .. tostring(periodo) .. ").")
	end
	if #sesion.OrdenActividades >= self.MaxActividadesPorSesion then
		return self:Rechazo(player, "CrearActividad", "limite", "Esta sesión alcanzó el máximo de " .. self.MaxActividadesPorSesion .. " actividades.")
	end
	local tipo = d.Type or d.Tipo
	if tipo ~= "Texto" and tipo ~= "Opciones" then
		return self:Rechazo(player, "CrearActividad", "tipo", "El tipo de actividad debe ser Texto u Opciones.", true)
	end
	local segundos = self.SegundosPorDefecto
	if d.Segundos ~= nil then
		segundos = entero(d.Segundos, self.SegundosMin, self.SegundosMax)
		if not segundos then
			return self:Rechazo(player, "CrearActividad", "tiempo",
				string.format("El tiempo debe ser un número entero entre %d y %d segundos.", self.SegundosMin, self.SegundosMax))
		end
	end
	local pregunta, motivo = limpiarTexto(d.Prompt or d.Pregunta, self.MaxPreguntaCaracteres, true)
	if not pregunta then
		if motivo == "largo" then
			return self:Rechazo(player, "CrearActividad", "texto", "La pregunta supera los " .. self.MaxPreguntaCaracteres .. " caracteres.")
		end
		return self:Rechazo(player, "CrearActividad", "texto", "Escribe la pregunta de la actividad.")
	end

	local opcionesLimpias = nil
	local correcta = nil
	if tipo == "Opciones" then
		local fuente = d.Options or d.Opciones
		if typeof(fuente) ~= "table" then
			return self:Rechazo(player, "CrearActividad", "opciones", "Añade entre 2 y 4 opciones.")
		end
		local n = #fuente
		if n < self.MinOpciones or n > self.MaxOpciones or contar(fuente) ~= n then
			return self:Rechazo(player, "CrearActividad", "opciones", "Añade entre " .. self.MinOpciones .. " y " .. self.MaxOpciones .. " opciones.")
		end
		opcionesLimpias = {}
		for i = 1, n do
			local opcion = limpiarTexto(fuente[i], self.MaxOpcionCaracteres, false)
			if not opcion then
				return self:Rechazo(player, "CrearActividad", "opciones",
					"La opción " .. i .. " está vacía o supera los " .. self.MaxOpcionCaracteres .. " caracteres.")
			end
			opcionesLimpias[i] = opcion
		end
		if d.Correcta ~= nil and d.Correcta ~= 0 then
			correcta = entero(d.Correcta, 1, n)
			if not correcta then
				return self:Rechazo(player, "CrearActividad", "correcta", "La opción correcta no es válida.")
			end
		end
	end

	-- Filtrado (cede): pregunta y opciones para toda la clase.
	local preguntaFiltrada = filtrar(pregunta, player.UserId, nil)
	if not preguntaFiltrada then
		return self:Rechazo(player, "CrearActividad", "filtro", "No se pudo filtrar la pregunta; inténtalo de nuevo.")
	end
	local opcionesFiltradas = nil
	if opcionesLimpias then
		opcionesFiltradas = {}
		for i, opcion in ipairs(opcionesLimpias) do
			local filtrada = filtrar(opcion, player.UserId, nil)
			if not filtrada then
				return self:Rechazo(player, "CrearActividad", "filtro", "No se pudo filtrar la opción " .. i .. "; inténtalo de nuevo.")
			end
			opcionesFiltradas[i] = filtrada
		end
	end
	if self.Sesiones[roomId] ~= sesion or sesion.State ~= "Abierta" then
		return self:Rechazo(player, "CrearActividad", "sin_sesion", "La sesión ya no está abierta.")
	end

	-- Una actividad activa a la vez: la anterior se cierra.
	local anterior = sesion.ActiveActivityId and sesion.Actividades[sesion.ActiveActivityId] or nil
	if anterior then
		self:CerrarActividadInterna(sesion, anterior, "El docente inició una nueva actividad.")
	end

	sesion.ContadorActividades = sesion.ContadorActividades + 1
	local creada = ahora()
	local act = {
		Id = "A" .. sesion.ContadorActividades,
		Type = tipo,
		Prompt = preguntaFiltrada,
		Options = opcionesFiltradas,
		Correcta = correcta,
		CreatedAt = creada,
		DueAt = creada + segundos,
		Segundos = segundos,
		Estado = "Abierta",
		Submissions = {},
		Grades = {},
		Pendientes = {},
		Destinatarios = {},
		Publicada = false,
	}
	sesion.Actividades[act.Id] = act
	table.insert(sesion.OrdenActividades, act.Id)
	sesion.ActiveActivityId = act.Id

	-- Solo los estudiantes presentes en la zona reciben la actividad.
	local publica = self:ActividadPublica(act, false)
	publica.Respuestas = nil
	local destinatarios = 0
	for _, alumno in ipairs(self:JugadoresEnAula(roomId)) do
		if alumno.UserId ~= sesion.TeacherUserId then
			act.Destinatarios[alumno.UserId] = true
			sesion.PresentUserIds[alumno.UserId] = true
			local datos = { RoomId = roomId, SessionId = sesion.SessionId, Actividad = publica }
			if self:Enviar(alumno, "Actividad", datos) then
				destinatarios = destinatarios + 1
			end
		end
	end
	self:EnviarDocente(sesion, "Actividad", { Docente = true, Actividad = self:ActividadPublica(act, true), Destinatarios = destinatarios })

	-- Cierre automático al vencer el tiempo.
	task.delay(segundos + 0.25, function()
		if self.Sesiones[roomId] == sesion and act.Estado == "Abierta" then
			self:CerrarActividadInterna(sesion, act, "Se acabó el tiempo.")
		end
	end)

	self:Auditar(player, "CrearActividad", string.format("%s · %s · %s · %d s · %d destinatarios", roomId, act.Id, tipo, segundos, destinatarios))
	self.ActividadCreada:Fire(sesion, act)
	return exito({ Actividad = self:ActividadPublica(act, true), Destinatarios = destinatarios })
end

function ClassroomService:AccionCerrarActividad(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "CerrarActividad")
	if not sesion then
		return rechazo
	end
	local act = actividadDe(sesion, d.ActividadId)
	if not act then
		return self:Rechazo(player, "CerrarActividad", "actividad_desconocida", "No hay una actividad activa.")
	end
	if act.Estado ~= "Abierta" then
		return self:Rechazo(player, "CerrarActividad", "actividad_cerrada", "La actividad ya está cerrada.")
	end
	self:CerrarActividadInterna(sesion, act, "El docente cerró la actividad.")
	self:Auditar(player, "CerrarActividad", roomId .. " · " .. act.Id .. " · " .. contar(act.Submissions) .. " respuestas")
	return exito({ Actividad = self:ActividadPublica(act, true), Respuestas = self:ListaRespuestas(act) })
end

function ClassroomService:AccionInvitarTablero(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "InvitarTablero")
	if not sesion then
		return rechazo
	end
	local enClase, periodo = self:EnClase()
	if not enClase then
		return self:Rechazo(player, "InvitarTablero", "fuera_de_clase", "El tablero solo se comparte en periodo de clase (ahora: " .. tostring(periodo) .. ").")
	end
	local BoardService = self:Servicio("BoardService")
	if not BoardService or typeof(BoardService.ConcederTurno) ~= "function" then
		return self:Rechazo(player, "InvitarTablero", "sin_tablero", "El tablero no está disponible en este servidor.")
	end
	local userId = entero(d.ObjetivoUserId, 1, nil)
	local objetivo = userId and Players:GetPlayerByUserId(userId) or nil
	if not objetivo or objetivo == player then
		return self:Rechazo(player, "InvitarTablero", "objetivo", "Elige a un estudiante conectado.")
	end
	if not self:Tiene(objetivo, "aula.estudiante") then
		return self:Rechazo(player, "InvitarTablero", "objetivo", objetivo.DisplayName .. " no es estudiante; solo se invita a estudiantes.")
	end
	if not self:EstaEnAula(objetivo, roomId) then
		return self:Rechazo(player, "InvitarTablero", "objetivo_ausente", objetivo.DisplayName .. " no está en el aula.", true)
	end
	local turno = self:TurnoPublico(sesion)
	if turno then
		return self:Rechazo(player, "InvitarTablero", "turno_activo", turno.Nombre .. " ya está en el tablero; revoca su turno primero.")
	end
	local invitacion = {
		UserId = objetivo.UserId, Nombre = objetivo.DisplayName, Expira = ahora() + self.InvitacionSeg, SessionId = sesion.SessionId,
	}
	self.Invitaciones[roomId] = invitacion
	if sesion.ManosLevantadas[objetivo.UserId] then
		sesion.ManosLevantadas[objetivo.UserId] = nil
	end
	self:Enviar(objetivo, "Invitacion", {
		RoomId = roomId, SessionId = sesion.SessionId, Expira = invitacion.Expira, Segundos = self.InvitacionSeg,
		Docente = sesion.TeacherName,
	})
	self:EnviarDocente(sesion, "Invitacion", {
		Pendiente = true, UserId = invitacion.UserId, Nombre = invitacion.Nombre, Expira = invitacion.Expira,
		Manos = self:ListaManos(sesion),
	})
	task.delay(self.InvitacionSeg + 0.25, function()
		if self.Invitaciones[roomId] == invitacion then
			self.Invitaciones[roomId] = nil
			local actual = self.Sesiones[roomId]
			if actual == sesion then
				self:EnviarDocente(sesion, "Invitacion", { Caducada = true, UserId = invitacion.UserId, Nombre = invitacion.Nombre })
			end
			local alumno = Players:GetPlayerByUserId(invitacion.UserId)
			if alumno then
				self:Enviar(alumno, "Invitacion", { RoomId = roomId, SessionId = sesion.SessionId, Caducada = true })
			end
		end
	end)
	self:Auditar(player, "InvitarTablero", roomId .. " · " .. objetivo.Name)
	return exito({ Invitado = invitacion.Nombre, UserId = invitacion.UserId, Expira = invitacion.Expira })
end

function ClassroomService:AccionRevocarTablero(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "RevocarTablero")
	if not sesion then
		return rechazo
	end
	local habia = sesion.InvitadoTablero
	sesion.InvitadoTablero = nil
	sesion.TurnoHasta = nil
	sesion.TurnoToken = (sesion.TurnoToken or 0) + 1
	self:Llamar("BoardService", "RevocarTurno", roomId)
	local inv = self.Invitaciones[roomId]
	self.Invitaciones[roomId] = nil
	if inv then
		local alumno = Players:GetPlayerByUserId(inv.UserId)
		if alumno then
			self:Enviar(alumno, "Invitacion", { RoomId = roomId, SessionId = sesion.SessionId, Caducada = true, Revocada = true })
		end
	end
	self:EnviarAula(sesion, "TurnoTablero", { Fin = true, Revocado = true, UserId = habia })
	self:Auditar(player, "RevocarTablero", roomId .. " · " .. tostring(habia or "-"))
	return exito({ Revocado = true })
end

function ClassroomService:AccionCalificar(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "Calificar")
	if not sesion then
		return rechazo
	end
	local act = actividadDe(sesion, d.ActividadId)
	if not act then
		return self:Rechazo(player, "Calificar", "actividad_desconocida", "Elige una actividad de esta sesión.")
	end
	local userId = entero(d.ObjetivoUserId, 1, nil)
	if not userId or userId == player.UserId then
		return self:Rechazo(player, "Calificar", "objetivo", "Elige a un estudiante.")
	end
	local alumno = Players:GetPlayerByUserId(userId)
	if not act.Submissions[userId] and not (alumno and self:EstaEnAula(alumno, roomId)) then
		return self:Rechazo(player, "Calificar", "objetivo", "Ese estudiante no respondió ni está en el aula.", true)
	end
	local puntos = tonumber(d.Puntos)
	if not esFinito(puntos) or puntos < 0 or puntos > 10 then
		return self:Rechazo(player, "Calificar", "puntos", "La nota debe estar entre 0 y 10.")
	end
	puntos = math.floor(puntos * 10 + 0.5) / 10
	local comentario = nil
	if d.Comentario ~= nil and d.Comentario ~= "" then
		local limpio, motivo = limpiarTexto(d.Comentario, self.MaxComentarioCaracteres, false)
		if not limpio then
			if motivo == "largo" then
				return self:Rechazo(player, "Calificar", "texto", "El comentario supera los " .. self.MaxComentarioCaracteres .. " caracteres.")
			end
			return self:Rechazo(player, "Calificar", "texto", "El comentario no es válido.")
		end
		comentario = filtrar(limpio, player.UserId, alumno and userId or nil)
		if not comentario then
			return self:Rechazo(player, "Calificar", "filtro", "No se pudo filtrar el comentario; inténtalo de nuevo.")
		end
	end
	act.Grades[userId] = { Puntos = puntos, Comentario = comentario, T = ahora() }
	sesion.PresentUserIds[userId] = true
	if alumno then
		local envio = act.Submissions[userId]
		self:Enviar(alumno, "Resultado", {
			RoomId = roomId, SessionId = sesion.SessionId, ActividadId = act.Id, Prompt = act.Prompt,
			Puntos = puntos, Comentario = comentario, Docente = sesion.TeacherName,
			TuRespuesta = envio and envio.Respuesta or nil,
		})
	end
	self:Auditar(player, "Calificar", string.format("%s · %s · %s · %.1f", roomId, act.Id, tostring(userId), puntos))
	return exito({ UserId = userId, Puntos = puntos, Comentario = comentario, ActividadId = act.Id })
end

-- Resumen anónimo de una actividad (sin nombres).
function ClassroomService:ResumenAnonimo(sesion, act)
	local total = contar(act.Submissions)
	local presentes = 0
	for _, alumno in ipairs(self:JugadoresEnAula(sesion.RoomId)) do
		if alumno.UserId ~= sesion.TeacherUserId then
			presentes = presentes + 1
		end
	end
	local resumen = {
		ActividadId = act.Id, Prompt = act.Prompt, Type = act.Type, Total = total, Presentes = presentes,
		Cerrada = act.Estado == "Cerrada",
	}
	if act.Type == "Opciones" and act.Options then
		local votos = {}
		for i = 1, #act.Options do
			votos[i] = 0
		end
		local correctas = 0
		for _, envio in pairs(act.Submissions) do
			if envio.Indice and votos[envio.Indice] then
				votos[envio.Indice] = votos[envio.Indice] + 1
			end
			if envio.Correcta then
				correctas = correctas + 1
			end
		end
		resumen.Opciones = {}
		for i, texto in ipairs(act.Options) do
			table.insert(resumen.Opciones, { Texto = texto, Votos = votos[i], EsCorrecta = act.Correcta == i })
		end
		if act.Correcta then
			resumen.Correctas = correctas
			if total > 0 then
				resumen.PorcentajeCorrectas = math.floor(correctas / total * 100 + 0.5)
			else
				resumen.PorcentajeCorrectas = 0
			end
		end
	end
	local suma, calificadas = 0, 0
	for _, nota in pairs(act.Grades) do
		suma = suma + nota.Puntos
		calificadas = calificadas + 1
	end
	resumen.Calificadas = calificadas
	if calificadas > 0 then
		resumen.Promedio = math.floor(suma / calificadas * 10 + 0.5) / 10
	end
	return resumen
end

function ClassroomService:AccionPublicarResultados(player, roomId, d)
	local sesion, rechazo = self:SesionDelDocente(player, roomId, "PublicarResultados")
	if not sesion then
		return rechazo
	end
	local act = actividadDe(sesion, d.ActividadId)
	if not act then
		return self:Rechazo(player, "PublicarResultados", "actividad_desconocida", "Todavía no hay actividades en esta sesión.")
	end
	-- Publicar revela la respuesta correcta: la actividad se cierra antes.
	if act.Estado == "Abierta" then
		self:CerrarActividadInterna(sesion, act, "Se publicaron los resultados.")
	end
	act.Publicada = true
	local resumen = self:ResumenAnonimo(sesion, act)
	self:EnviarAula(sesion, "Resultados", resumen)
	self:Auditar(player, "PublicarResultados", roomId .. " · " .. act.Id .. " · " .. resumen.Total .. " respuestas")
	return exito(resumen)
end

---------------------------------------------------------------------------------------------------
-- Acciones del estudiante
---------------------------------------------------------------------------------------------------

-- Comprobaciones comunes: sesión abierta, presente en el aula, no es el docente. Devuelve sesion | nil, rechazo.
function ClassroomService:SesionDelAlumno(player, roomId, accion, exigirClase)
	local sesion = self.Sesiones[roomId]
	if not sesion then
		return nil, self:Rechazo(player, accion, "sin_sesion", "No hay una clase abierta en esta aula.")
	end
	if sesion.TeacherUserId == player.UserId then
		return nil, self:Rechazo(player, accion, "docente", "El docente no puede hacer esto en su propia sesión.")
	end
	if not self:EstaEnAula(player, roomId) then
		return nil, self:Rechazo(player, accion, "fuera_del_aula", "Debes estar dentro del aula " .. sesion.NombreAula .. ".", true)
	end
	if exigirClase then
		local enClase, periodo = self:EnClase()
		if not enClase then
			return nil, self:Rechazo(player, accion, "fuera_de_clase", "No es periodo de clase (ahora: " .. tostring(periodo) .. ").")
		end
	end
	return sesion
end

function ClassroomService:AccionResponder(player, roomId, d)
	local sesion, rechazo = self:SesionDelAlumno(player, roomId, "Responder", true)
	if not sesion then
		return rechazo
	end
	local userId = player.UserId
	local act = nil
	if typeof(d.ActividadId) == "string" then
		act = sesion.Actividades[d.ActividadId]
	elseif d.ActividadId == nil and sesion.ActiveActivityId then
		act = sesion.Actividades[sesion.ActiveActivityId]
	end
	if not act then
		return self:Rechazo(player, "Responder", "actividad_desconocida", "Esa actividad no existe en esta clase.", true)
	end
	if act.Estado ~= "Abierta" or ahora() > act.DueAt then
		return self:Rechazo(player, "Responder", "actividad_cerrada", "La actividad ya está cerrada.")
	end
	if act.Submissions[userId] or act.Pendientes[userId] then
		return self:Rechazo(player, "Responder", "ya_respondido", "Ya respondiste esta actividad.", true)
	end

	local respuesta, indice, correcta = nil, nil, nil
	if act.Type == "Opciones" then
		indice = entero(d.Indice, 1, act.Options and #act.Options or 0)
		if not indice then
			return self:Rechazo(player, "Responder", "opcion", "Elige una de las opciones.")
		end
		respuesta = act.Options[indice]
		if act.Correcta then
			correcta = indice == act.Correcta
		end
	else
		local limpio, motivo = limpiarTexto(d.Respuesta, self.MaxRespuestaCaracteres, true)
		if not limpio then
			if motivo == "largo" then
				return self:Rechazo(player, "Responder", "texto", "La respuesta supera los " .. self.MaxRespuestaCaracteres .. " caracteres.")
			end
			return self:Rechazo(player, "Responder", "texto", "Escribe tu respuesta.")
		end
		-- Marca de pendiente: evita dos respuestas mientras el filtrado cede.
		act.Pendientes[userId] = true
		local filtrada = filtrar(limpio, userId, sesion.TeacherUserId)
		act.Pendientes[userId] = nil
		if not filtrada then
			return self:Rechazo(player, "Responder", "filtro", "No se pudo filtrar tu respuesta; inténtalo de nuevo.")
		end
		if act.Estado ~= "Abierta" or act.Submissions[userId] then
			return self:Rechazo(player, "Responder", "actividad_cerrada", "La actividad se cerró mientras enviabas.")
		end
		respuesta = filtrada
	end

	local t = ahora()
	act.Submissions[userId] = { Respuesta = respuesta, Indice = indice, Correcta = correcta, T = t, Nombre = player.DisplayName }
	sesion.PresentUserIds[userId] = true
	self:Acreditar(player, RECOMPENSAS.Respuesta, "Respuesta", "Actividad " .. act.Id .. " · " .. roomId)
	self:EnviarDocente(sesion, "Respuesta", {
		ActividadId = act.Id,
		Respuesta = {
			UserId = userId, Nombre = player.DisplayName, Respuesta = respuesta, Indice = indice, Correcta = correcta, T = t,
		},
		Total = contar(act.Submissions),
	})
	self:Auditar(player, "Responder", roomId .. " · " .. act.Id)
	return exito({ Recibida = true, ActividadId = act.Id, T = t, Indice = indice })
end

function ClassroomService:AccionLevantarMano(player, roomId, d)
	local sesion, rechazo = self:SesionDelAlumno(player, roomId, "LevantarMano", true)
	if not sesion then
		return rechazo
	end
	local userId = player.UserId
	local levantar = d.Levantar
	if typeof(levantar) ~= "boolean" then
		levantar = sesion.ManosLevantadas[userId] == nil
	end
	if levantar then
		sesion.ManosLevantadas[userId] = sesion.ManosLevantadas[userId] or ahora()
	else
		sesion.ManosLevantadas[userId] = nil
	end
	sesion.PresentUserIds[userId] = true
	self:EnviarDocente(sesion, "Mano", {
		UserId = userId, Nombre = player.DisplayName, Levantada = levantar, Manos = self:ListaManos(sesion),
	})
	return exito({ Levantada = levantar })
end

function ClassroomService:AccionAceptarInvitacion(player, roomId, d)
	local sesion = self.Sesiones[roomId]
	local inv = self.Invitaciones[roomId]
	if not sesion or not inv or inv.UserId ~= player.UserId or inv.SessionId ~= sesion.SessionId or ahora() > inv.Expira then
		return self:Rechazo(player, "AceptarInvitacion", "sin_invitacion", "No tienes una invitación vigente al tablero.", true)
	end
	if d.Aceptar == false then
		self.Invitaciones[roomId] = nil
		self:EnviarDocente(sesion, "Invitacion", { Rechazada = true, UserId = inv.UserId, Nombre = inv.Nombre })
		return exito({ Aceptada = false })
	end
	local sesionAlumno, rechazo = self:SesionDelAlumno(player, roomId, "AceptarInvitacion", true)
	if not sesionAlumno then
		return rechazo
	end
	local turnoSeg = self.TurnoTableroSeg
	local ok, resultado, expira = self:Llamar("BoardService", "ConcederTurno", roomId, player, turnoSeg)
	if not ok or resultado == false then
		return self:Rechazo(player, "AceptarInvitacion", "tablero", "El tablero no está disponible ahora mismo.")
	end
	self.Invitaciones[roomId] = nil
	sesion.InvitadoTablero = player.UserId
	sesion.TurnoHasta = ahora() + turnoSeg
	if esFinito(expira) and expira > ahora() then
		-- BoardService acota la duración del turno: se usa su caducidad real.
		sesion.TurnoHasta = expira
		turnoSeg = math.max(1, math.floor(expira - ahora() + 0.5))
	end
	sesion.TurnoToken = (sesion.TurnoToken or 0) + 1
	local token = sesion.TurnoToken
	self:EnviarAula(sesion, "TurnoTablero", {
		UserId = player.UserId, Nombre = player.DisplayName, Segundos = turnoSeg, Hasta = sesion.TurnoHasta,
	})
	task.delay(turnoSeg + 0.25, function()
		if self.Sesiones[roomId] == sesion and sesion.TurnoToken == token and sesion.InvitadoTablero == player.UserId then
			sesion.InvitadoTablero = nil
			sesion.TurnoHasta = nil
			self:EnviarAula(sesion, "TurnoTablero", { Fin = true, UserId = player.UserId, Motivo = "Terminó el turno." })
		end
	end)
	self:Auditar(player, "AceptarInvitacion", roomId .. " · turno " .. turnoSeg .. " s")
	return exito({ Aceptada = true, Segundos = turnoSeg, Hasta = sesion.TurnoHasta })
end

---------------------------------------------------------------------------------------------------
-- Consulta (cualquier cargo): estado para quien entra a mitad de clase
---------------------------------------------------------------------------------------------------
-- Estado del tablero del aula para quien entra a mitad de clase (BoardController lo lee de datos.Tablero).
function ClassroomService:EstadoTablero(roomId)
	local ok, estado = self:Llamar("BoardService", "Estado", roomId)
	if ok and typeof(estado) == "table" then
		return estado
	end
	return nil
end

function ClassroomService:AccionConsultarEstado(player, roomId, d)
	local sesion = self.Sesiones[roomId]
	if sesion and sesion.TeacherUserId == player.UserId then
		local datos = self:SnapshotDocente(sesion)
		datos.Tablero = self:EstadoTablero(roomId)
		return exito(datos)
	end
	local puedeDirigir = self:PuedeDirigir(player, roomId)
	local acceso = self:EstaEnAula(player, roomId) or self:SalonDe(player) == roomId or puedeDirigir
	if not acceso then
		return self:Rechazo(player, "ConsultarEstado", "fuera_del_aula", "Solo puedes consultar el aula en la que estás o tu salón.")
	end
	if not sesion then
		local enClase, periodo = self:EnClase()
		return exito({
			SesionAbierta = false, RoomId = roomId, NombreAula = nombreAula(roomId), PuedeAbrir = puedeDirigir,
			EnClase = enClase, Periodo = periodo, HoraServidor = ahora(), Tablero = self:EstadoTablero(roomId),
		})
	end
	local datos = self:SnapshotEstudiante(sesion, player)
	datos.PuedeAbrir = false
	datos.Tablero = self:EstadoTablero(roomId)
	return exito(datos)
end

return ClassroomService
