--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.SchoolDayService
	Tipo: ModuleScript
	Jornada escolar (docs/ARQUITECTURA.md §3 y §6). Máquina de estados ESPERA -> ENTRADA -> CLASE_1 -> TRANSICION ->
	DESCANSO -> CLASE_2 -> ALMUERZO -> CLASE_3 -> SALIDA -> REINICIO -> (ESPERA) con las duraciones de
	TimetableDefinitions (configurables en caliente), modo Automatica (ciclo continuo) o Manual (espera a que la
	dirección pulse Iniciar), Pausar/Reanudar/Saltar/Reiniciar y snapshot para el HUD (reloj escolar interpolable).
	Timbres con subtítulo y sonido opcional, asignación balanceada de aulas (atributo Salon del Player), asistencia
	por aula en cada clase (Presente/Tardanza/Ausente con recompensa, progreso y aviso al docente de la sesión),
	cierre de la jornada (sesiones, guardado, limpieza) y handlers de JornadaControl, StateSnapshot y SettingsUpdate
	(este último solo si DataService no lo registra).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Maid = require(Util:WaitForChild("Maid"))
local Validate = require(Util:WaitForChild("Validate"))
local Zones = require(Util:WaitForChild("Zones"))
local Format = require(Util:WaitForChild("Format"))

local SchoolDayService = {}
SchoolDayService.Nombre = "SchoolDayService"

local PREFIJO = "[ColegioRP][SchoolDayService]"
local CFG = Config.Jornada or {}
local ESTADO_INICIAL = TimetableDefinitions.EstadoInicial
local ESTADO_FINAL = TimetableDefinitions.EstadoFinal
local ESTADO_ENTRADA = TimetableDefinitions.Siguiente(ESTADO_INICIAL)
local CARGO_ESTUDIANTE = "Estudiante"

---------------------------------------------------------------------------------------------------
-- Parámetros ajustables (no forman parte de Config para no duplicar TimetableDefinitions)
---------------------------------------------------------------------------------------------------
SchoolDayService.IntervaloTickSeg = 0.25 -- Frecuencia de revisión del temporizador del periodo.
SchoolDayService.IntervaloTardanzaSeg = 2 -- Frecuencia de detección de llegadas tarde entre tolerancia y ausencia.
SchoolDayService.MargenAulaStuds = 1.5 -- Margen alrededor de la caja del aula (marcos de puerta, paredes).
SchoolDayService.EscalaMin = 0.1 -- Límites de EscalaTiempo aceptados por Configurar.
SchoolDayService.EscalaMax = 5
SchoolDayService.DuracionMinSeg = 5 -- Límites de duración (segundos, escala 1) aceptados por Configurar.
SchoolDayService.DuracionMaxSeg = 3600
SchoolDayService.EstudiantesPorAulaLimite = 60 -- Máximo admitido para EstudiantesPorAulaMax.
SchoolDayService.MaxAulasActivas = 64 -- Elementos máximos de AulasActivas en Configurar.
SchoolDayService.MaxHistorialJornadas = 5 -- Resúmenes de jornadas anteriores conservados.
SchoolDayService.EsperaPerfilSnapshotSeg = 3 -- Espera máxima del perfil al responder StateSnapshot.
SchoolDayService.RepetirSnapshotEntradaSeg = 5 -- Reenvío del snapshot de jornada tras entrar (por si el cliente tardó).
SchoolDayService.VolumenTimbre = 0.6
SchoolDayService.NombreSonidoTimbre = "ColegioRP_TimbreServidor"
SchoolDayService.SonidoTimbreEnServidor = true -- false = solo subtítulo (el cliente puede reproducir su propio sonido).
-- Periodos en cuyo inicio suena el timbre.
SchoolDayService.EstadosConTimbre = {
	ENTRADA = true, CLASE_1 = true, TRANSICION = true, DESCANSO = true, CLASE_2 = true,
	ALMUERZO = true, CLASE_3 = true, SALIDA = true,
}

-- Textos legibles de los motivos de rechazo de JornadaControl.
SchoolDayService.TextosError = {
	ya_iniciada = "La jornada ya está en curso.",
	en_espera = "La jornada aún no ha comenzado: usa Iniciar.",
	ya_pausada = "La jornada ya está en pausa.",
	no_pausada = "La jornada no está en pausa.",
	en_curso = "Se está procesando otro cambio de periodo; inténtalo de nuevo.",
	sin_cambios = "No se indicó ningún cambio.",
	datos_requeridos = "Faltan los datos de configuración.",
	datos_invalidos = "Los datos de configuración no son válidos.",
	accion_desconocida = "Acción desconocida.",
	sin_permiso = "Tu cargo no puede controlar la jornada.",
	modo_invalido = "Modo inválido: usa Automatica o Manual.",
	escala_invalida = "La escala de tiempo debe estar entre 0,1 y 5.",
	aulas_invalidas = "La lista de aulas activas no es válida.",
	maximo_invalido = "El máximo de estudiantes por aula no es válido.",
	duraciones_invalidas = "Las duraciones deben ser una tabla { ESTADO = segundos }.",
	materias_invalidas = "Las materias deben ser una tabla { CLASE_n = código }.",
	pausa_invalida = "PausarSinJugadores debe ser verdadero o falso.",
	clave_desconocida = "La configuración contiene una opción desconocida.",
	estado_invalido = "Las duraciones incluyen un periodo que no existe.",
	duracion_invalida = "Cada duración debe estar entre 5 y 3600 segundos.",
	clase_invalida = "Solo los periodos de clase tienen materia.",
	materia_invalida = "La materia indicada no existe.",
	aula_invalida = "Alguna de las aulas indicadas no existe.",
	error_interno = "Error interno del servidor.",
}

-- Textos del timbre por periodo (las clases se componen con su materia).
local TEXTOS_TIMBRE = {
	ENTRADA = "🔔 ¡Buenos días! Comienza la jornada escolar: entrada al colegio.",
	DESCANSO = "🔔 ¡Descanso! El comedor reparte comida gratis y la cancha está abierta.",
	ALMUERZO = "🔔 Hora del almuerzo: el comedor está abierto.",
	SALIDA = "🔔 Fin de las clases: salida del colegio.",
}

-- Estado de asistencia -> clave del resumen.
local CLAVE_RESUMEN = { Presente = "Presentes", Tardanza = "Tardanzas", Ausente = "Ausentes", Pendiente = "Pendientes" }

local ACCIONES_CONTROL = { Iniciar = true, Pausar = true, Reanudar = true, Saltar = true, Reiniciar = true, Configurar = true }
local CLAVES_CONFIG = {
	Modo = true, EscalaTiempo = true, Duraciones = true, Materias = true, AulasActivas = true,
	EstudiantesPorAulaMax = true, PausarSinJugadores = true,
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local function esFinito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function acotar(n, minimo, maximo)
	if n < minimo then
		return minimo
	end
	if n > maximo then
		return maximo
	end
	return n
end

-- Tiempo del servidor compartido con el cliente (workspace:GetServerTimeNow()).
local function ahora()
	local ok, valor = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and esFinito(valor) then
		return valor
	end
	return os.time()
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

local function nombreJugador(player)
	local ok, nombre = pcall(function()
		return player.DisplayName
	end)
	if ok and typeof(nombre) == "string" and nombre ~= "" then
		return nombre
	end
	return player.Name
end

local function esZona(id)
	return typeof(id) == "string" and id ~= "" and MapaLogico.Zonas[id] ~= nil
end

local function esAula(id)
	return esZona(id) and Zones.EsAula(id)
end

local function nombreAula(roomId)
	local zona = nil
	if esZona(roomId) then
		zona = MapaLogico.Zonas[roomId]
	end
	if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= "" then
		return zona.Nombre
	end
	return tostring(roomId or "—")
end

local function sanearEscala(valor)
	if not esFinito(valor) or valor <= 0 then
		return 1
	end
	return acotar(valor, SchoolDayService.EscalaMin, SchoolDayService.EscalaMax)
end

local function recompensaAsistencia()
	local economia = Config.Economia or {}
	local recompensas = economia.Recompensas or {}
	local n = tonumber(recompensas.Asistencia) or 0
	if not esFinito(n) or n < 0 then
		return 0
	end
	return math.floor(n)
end

local function resumenVacio()
	return { Presentes = 0, Tardanzas = 0, Ausentes = 0, Pendientes = 0, Total = 0 }
end

local function copiaLista(lista)
	local copia = {}
	for i, v in ipairs(lista or {}) do
		copia[i] = v
	end
	return copia
end

-- Normaliza un ajuste ya validado (redondeos) antes de guardarlo en el perfil.
local function normalizarAjuste(clave, valor)
	if clave == "EscalaTexto" and typeof(valor) == "number" then
		return math.floor(valor * 100 + 0.5) / 100
	elseif clave == "LimiteEfectos" and typeof(valor) == "number" then
		return math.floor(valor + 0.5)
	end
	return valor
end

local TIPOS_DESCARTADOS = {
	["function"] = true, thread = true, userdata = true, Instance = true,
	RBXScriptConnection = true, RBXScriptSignal = true,
}

-- Copia apta para enviar por remotos: sin funciones, instancias, señales ni números no finitos;
-- en tablas mixtas las claves numéricas pasan a texto (Roblox no replica tablas mixtas).
local function copiaSegura(valor, profundidad)
	profundidad = profundidad or 0
	local tipo = typeof(valor)
	if TIPOS_DESCARTADOS[tipo] then
		return nil
	end
	if tipo == "number" then
		if esFinito(valor) then
			return valor
		end
		return nil
	end
	if tipo ~= "table" then
		return valor
	end
	if profundidad > 8 or Signal.Es(valor) or Maid.Es(valor) then
		return nil
	end
	local hayTexto, hayNumero = false, false
	for clave in pairs(valor) do
		local tipoClave = typeof(clave)
		if tipoClave == "string" then
			hayTexto = true
		elseif tipoClave == "number" then
			hayNumero = true
		end
	end
	local mixta = hayTexto and hayNumero
	local copia = {}
	for clave, v in pairs(valor) do
		local tipoClave = typeof(clave)
		if tipoClave == "string" or tipoClave == "number" then
			local copiaValor = copiaSegura(v, profundidad + 1)
			if copiaValor ~= nil then
				if mixta and tipoClave == "number" then
					copia[tostring(clave)] = copiaValor
				else
					copia[clave] = copiaValor
				end
			end
		end
	end
	return copia
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function SchoolDayService:Init(registro)
	self.registro = registro
	self.Maid = Maid.new()

	-- Señales para otros servicios.
	self.EstadoCambiado = Signal.new() -- (estado, snapshot) al entrar en cada periodo
	self.JornadaActualizada = Signal.new() -- (snapshot) en cualquier difusión (pausa, configuración, periodo)
	self.JornadaTerminada = Signal.new() -- (resumen) al cerrar la jornada (SALIDA -> REINICIO o Reiniciar)
	self.AsistenciaMarcada = Signal.new() -- (player, roomId, estadoAsistencia, estadoClase)

	-- Configuración en caliente (copia de Config.Jornada).
	self.Modo = "Automatica"
	if CFG.Modo == "Manual" then
		self.Modo = "Manual"
	end
	self.EscalaTiempo = sanearEscala(CFG.EscalaTiempo)
	local maximo = tonumber(CFG.EstudiantesPorAulaMax) or 20
	if not esFinito(maximo) then
		maximo = 20
	end
	self.MaxPorAula = math.floor(acotar(maximo, 1, self.EstudiantesPorAulaLimite))
	self.PausarSinJugadores = CFG.PausarSinJugadores ~= false
	self.IniciarAutomaticamente = CFG.IniciarAutomaticamente ~= false
	self.Duraciones = {} -- estado -> segundos base (escala 1) que sustituyen a los de TimetableDefinitions
	self.Materias = {} -- estado de clase -> código de materia (sustituye al de TimetableDefinitions)
	self.AulasActivas = self:_FiltrarAulas(CFG.AulasActivas, true)

	-- Estado de la máquina.
	self.EstadoActual = ESTADO_INICIAL
	self.Indice = TimetableDefinitions.Indice(ESTADO_INICIAL) or 1
	self.Duracion = self:DuracionDe(ESTADO_INICIAL)
	self.InicioServidor = ahora()
	self.Pausada = false
	self.MotivoPausa = nil -- "manual" | "sin_jugadores"
	self.TranscurridoPausa = 0
	self.EnEspera = true -- ESPERA detenida hasta Iniciar (modo Manual o sin arranque automático)
	self.NumeroJornada = 0
	self.Jornada = self:_NuevaJornada(0)
	self.Jornada.Finalizada = true -- todavía no hay jornada en curso
	self.ClaseActual = nil -- registro de asistencia de la clase en curso
	self.UltimaAula = {} -- userId -> roomId (reconexión dentro de la misma jornada)
	self.Historial = {} -- resúmenes de jornadas anteriores (la más reciente primero)
	self.UltimoSnapshot = nil
	self.SonidoTimbre = nil
	self.AvisosLog = {} -- clave -> os.clock() del último warn (evita repetir avisos)
	self.Acumulador = 0
	self._Avanzando = false
	self._Procesando = false
	self.Iniciado = false
end

function SchoolDayService:Start()
	self.AuditLog = self:_Servicio("AuditLogService")
	self:_RegistrarRemotos()
	self:_PrepararSonido()

	self.Maid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:_AlEntrar(player)
	end))
	self.Maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:_AlSalir(player)
	end))

	-- Reasignación de aula al cambiar de cargo (RoleService.CargoCambiado: player, cargo, anterior).
	local RoleService = self:_Servicio("RoleService")
	local senal = RoleService and RoleService.CargoCambiado
	if typeof(senal) == "table" and typeof(senal.Connect) == "function" then
		local ok, conexion = pcall(function()
			return senal:Connect(function(player, cargo, anterior)
				local okCambio, err = pcall(self._AlCambiarCargo, self, player, cargo, anterior)
				if not okCambio then
					self:_Avisar("cargo_cambiado", err)
				end
			end)
		end)
		if ok and conexion then
			self.Maid:GiveTask(conexion)
		end
	end

	-- Estado inicial: en modo Automatica con arranque automático corre la cuenta atrás de ESPERA;
	-- en otro caso espera a Iniciar.
	local enEspera = not (self.Modo == "Automatica" and self.IniciarAutomaticamente)
	self:_EntrarEstado(ESTADO_INICIAL, "arranque", { Inicial = true, EnEspera = enEspera, SinTimbre = true })
	if self.PausarSinJugadores and not self.EnEspera and #Players:GetPlayers() == 0 then
		self:_Pausar("sin_jugadores", nil, true)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_AlEntrar(player)
		end)
	end

	self.Maid:GiveTask(RunService.Heartbeat:Connect(function(dt)
		self:_AlLatido(dt)
	end))

	self.Iniciado = true
	self:_Auditar("Sistema", nil, "Jornada", string.format("SchoolDayService activo · modo %s · escala %s · %d aulas activas · máx. %d por aula%s",
		self.Modo, tostring(self.EscalaTiempo), #self.AulasActivas, self.MaxPorAula, self.EnEspera and " · esperando Iniciar" or ""))
end

-- Desconecta todo (pruebas o recarga en caliente). El estado se conserva.
function SchoolDayService:Detener()
	self.Maid:DoCleaning()
	self.SonidoTimbre = nil
	self.Iniciado = false
end

---------------------------------------------------------------------------------------------------
-- Acceso a otros servicios (siempre tolerante a su ausencia)
---------------------------------------------------------------------------------------------------
function SchoolDayService:_Servicio(nombre)
	local registro = self.registro
	if registro and typeof(registro.Get) == "function" then
		local ok, servicio = pcall(registro.Get, nombre)
		if ok and typeof(servicio) == "table" then
			return servicio
		end
	end
	return nil
end

-- Llama servicio:metodo(...) en pcall si existe. Devuelve ok, resultado1, resultado2.
function SchoolDayService:_Llamar(nombre, metodo, ...)
	local servicio = self:_Servicio(nombre)
	if not servicio or typeof(servicio[metodo]) ~= "function" then
		return false, nil, nil
	end
	local resultado = table.pack(pcall(servicio[metodo], servicio, ...))
	if not resultado[1] then
		self:_Avisar(nombre .. ":" .. metodo, resultado[2])
		return false, nil, nil
	end
	return true, resultado[2], resultado[3]
end

-- warn con límite de una vez por minuto y clave.
function SchoolDayService:_Avisar(clave, err)
	local reloj = os.clock()
	local ultimo = self.AvisosLog[clave]
	if ultimo and reloj - ultimo < 60 then
		return
	end
	self.AvisosLog[clave] = reloj
	warn(PREFIJO .. " " .. tostring(clave) .. ": " .. tostring(err))
end

function SchoolDayService:_Auditar(categoria, player, accion, detalle)
	local AuditLog = self.AuditLog or self:_Servicio("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, categoria, player, accion, detalle)
	end
end

function SchoolDayService:_Enviar(player, tipo, datos)
	local RemoteService = self:_Servicio("RemoteService")
	if not RemoteService or typeof(RemoteService.Enviar) ~= "function" then
		return false
	end
	local ok, resultado = pcall(RemoteService.Enviar, RemoteService, player, tipo, datos)
	return ok and resultado == true
end

function SchoolDayService:_EnviarATodos(tipo, datos)
	local RemoteService = self:_Servicio("RemoteService")
	if not RemoteService or typeof(RemoteService.EnviarATodos) ~= "function" then
		return false
	end
	local ok, resultado = pcall(RemoteService.EnviarATodos, RemoteService, tipo, datos)
	if not ok then
		self:_Avisar("enviar_todos:" .. tostring(tipo), resultado)
	end
	return ok and resultado == true
end

function SchoolDayService:_Notificar(player, texto, nivel, duracion)
	return self:_Enviar(player, "Notificacion", {
		Texto = texto, Nivel = nivel or "info", Tipo = nivel or "info", Duracion = duracion,
	})
end

function SchoolDayService:_NotificarTodos(texto, nivel, duracion, extra)
	local datos = { Texto = texto, Nivel = nivel or "info", Tipo = nivel or "info", Duracion = duracion }
	if typeof(extra) == "table" then
		for clave, valor in pairs(extra) do
			datos[clave] = valor
		end
	end
	return self:_EnviarATodos("Notificacion", datos)
end

---------------------------------------------------------------------------------------------------
-- Consultas de la jornada (API pública)
---------------------------------------------------------------------------------------------------

-- Estado actual ("ESPERA", "CLASE_1", ...).
function SchoolDayService:Estado()
	return self.EstadoActual
end

-- Duración real (segundos) de un periodo con las sustituciones y la escala vigentes.
function SchoolDayService:DuracionDe(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	if not periodo then
		return self.DuracionMinSeg
	end
	local base = self.Duraciones[estado] or periodo.Duracion
	return math.max(self.DuracionMinSeg, base * self.EscalaTiempo)
end

-- Código de materia de un periodo de clase (nil si no es clase).
function SchoolDayService:MateriaDe(estado)
	if not TimetableDefinitions.EsClase(estado) then
		return nil
	end
	return self.Materias[estado] or TimetableDefinitions.MateriaDe(estado)
end

-- Segundos reales transcurridos del periodo actual (congelado en pausa; 0 en espera).
function SchoolDayService:Transcurrido()
	if self.EnEspera then
		return 0
	end
	if self.Pausada then
		return self.TranscurridoPausa or 0
	end
	return math.max(0, ahora() - (self.InicioServidor or ahora()))
end

-- Segundos reales que quedan del periodo actual.
function SchoolDayService:Restante()
	return math.max(0, self.Duracion - self:Transcurrido())
end

-- ¿La jornada está detenida esperando a Iniciar?
function SchoolDayService:EnEsperaDeInicio()
	return self.EnEspera == true
end

-- ¿La jornada está en pausa?
function SchoolDayService:EstaPausada()
	return self.Pausada == true
end

-- Tabla del periodo actual con los valores efectivos (duración real, materia sustituida).
function SchoolDayService:Periodo()
	local estado = self.EstadoActual
	local periodo = TimetableDefinitions.Periodo(estado) or {}
	return {
		Estado = estado,
		Nombre = periodo.Nombre or estado,
		Indice = self.Indice,
		Duracion = self.Duracion,
		DuracionBase = self.Duraciones[estado] or periodo.Duracion,
		HoraEscolar = periodo.HoraEscolar,
		EsClase = periodo.EsClase == true,
		ComidaGratis = periodo.ComidaGratis == true,
		Deporte = periodo.Deporte == true,
		Materia = self:MateriaDe(estado),
	}
end

-- Lista de todos los periodos con los valores vigentes (editor de horario de StaffService):
-- { {Estado, Nombre, HoraEscolar, Duracion (base, escala 1), DuracionReal, EsClase, Materia, MateriaNombre, Actual} }.
function SchoolDayService:Periodos()
	local lista = {}
	for i, periodo in ipairs(TimetableDefinitions.Periodos) do
		local materia = self:MateriaDe(periodo.Estado)
		local materiaNombre = nil
		if materia then
			materiaNombre = TimetableDefinitions.NombreMateria(materia)
		end
		lista[i] = {
			Estado = periodo.Estado,
			Nombre = periodo.Nombre,
			HoraEscolar = periodo.HoraEscolar,
			Duracion = self.Duraciones[periodo.Estado] or periodo.Duracion,
			DuracionReal = self:DuracionDe(periodo.Estado),
			EsClase = periodo.EsClase == true,
			ComidaGratis = periodo.ComidaGratis == true,
			Deporte = periodo.Deporte == true,
			Materia = materia,
			MateriaNombre = materiaNombre,
			Actual = periodo.Estado == self.EstadoActual,
		}
	end
	return lista
end

-- ¿Es un periodo de clase (con la jornada en marcha)?
function SchoolDayService:EnPeriodoClase()
	return not self.EnEspera and TimetableDefinitions.EsClase(self.EstadoActual)
end

-- ¿El comedor reparte comida gratis en el periodo actual?
function SchoolDayService:PermiteComidaGratis()
	return not self.EnEspera and TimetableDefinitions.EsComidaGratis(self.EstadoActual)
end

-- ¿La cancha está activa en el periodo actual?
function SchoolDayService:PermiteDeporte()
	return not self.EnEspera and TimetableDefinitions.EsDeporte(self.EstadoActual)
end

function SchoolDayService:_NombreProximo(siguiente)
	if self.EnEspera then
		return TimetableDefinitions.Nombre(siguiente) .. " (pendiente de inicio)"
	end
	if siguiente == ESTADO_INICIAL and self.Modo == "Manual" then
		return "Fin de la jornada"
	end
	local nombre = TimetableDefinitions.Nombre(siguiente)
	if TimetableDefinitions.EsClase(siguiente) then
		nombre = nombre .. " · " .. TimetableDefinitions.NombreMateria(self:MateriaDe(siguiente))
	end
	return nombre
end

-- Snapshot de la jornada para el cliente (formato que lee HUDController:FijarEstado):
-- { Estado, Nombre, Indice, InicioServidor, Duracion, HoraEscolarInicio, HoraEscolarFin, Materia, Pausada,
--   ProximoNombre, Modo } + Transcurrido, Restante, Progreso, HoraEscolar, EnEspera, MotivoPausa, ...
-- InicioServidor y HoraServidor usan workspace:GetServerTimeNow(); HoraEscolarInicio/Fin son segundos del día.
function SchoolDayService:Snapshot()
	local estado = self.EstadoActual
	local periodo = TimetableDefinitions.Periodo(estado) or {}
	local duracion = self.Duracion
	local transcurrido = math.min(self:Transcurrido(), duracion)
	local progreso = 0
	if duracion > 0 then
		progreso = acotar(transcurrido / duracion, 0, 1)
	end
	local inicioEscolar = TimetableDefinitions.HoraEscolarSegundos(estado) or 0
	local finEscolar = TimetableDefinitions.HoraEscolarFinSegundos(estado) or inicioEscolar
	local materia = self:MateriaDe(estado)
	local siguiente = TimetableDefinitions.Siguiente(estado)
	local congelado = self.Pausada or self.EnEspera
	local momento = ahora()
	local motivo = nil
	if self.EnEspera then
		motivo = "espera_inicio"
	elseif self.Pausada then
		motivo = self.MotivoPausa or "manual"
	end
	local inicioServidor = self.InicioServidor
	if congelado then
		inicioServidor = momento - transcurrido
	end
	local materiaNombre = nil
	if materia then
		materiaNombre = TimetableDefinitions.NombreMateria(materia)
	end
	return {
		Estado = estado,
		Nombre = periodo.Nombre or estado,
		Indice = self.Indice,
		Total = #TimetableDefinitions.Estados,
		InicioServidor = inicioServidor,
		Duracion = duracion,
		Transcurrido = transcurrido,
		Restante = math.max(0, duracion - transcurrido),
		Progreso = progreso,
		HoraEscolarInicio = inicioEscolar,
		HoraEscolarFin = finEscolar,
		HoraEscolar = math.floor(inicioEscolar + (finEscolar - inicioEscolar) * progreso),
		Materia = materia,
		MateriaNombre = materiaNombre,
		EsClase = periodo.EsClase == true,
		ComidaGratis = periodo.ComidaGratis == true,
		Deporte = periodo.Deporte == true,
		Pausada = congelado,
		MotivoPausa = motivo,
		EnEspera = self.EnEspera,
		ProximoEstado = siguiente,
		ProximoNombre = self:_NombreProximo(siguiente),
		Modo = self.Modo,
		EscalaTiempo = self.EscalaTiempo,
		Jornada = self.NumeroJornada,
		HoraServidor = momento,
		-- El timbre llega por "Notificacion" (Nivel "timbre"); así NotificationController no lo duplica.
		Timbre = false,
	}
end

-- Configuración vigente (panel de Dirección / Coordinación).
function SchoolDayService:ConfiguracionActual()
	local duraciones = {}
	for estado, seg in pairs(self.Duraciones) do
		duraciones[estado] = seg
	end
	local materias = {}
	for _, periodo in ipairs(TimetableDefinitions.Clases()) do
		materias[periodo.Estado] = self:MateriaDe(periodo.Estado)
	end
	return {
		Modo = self.Modo,
		EscalaTiempo = self.EscalaTiempo,
		Duraciones = duraciones,
		Materias = materias,
		AulasActivas = copiaLista(self.AulasActivas),
		EstudiantesPorAulaMax = self.MaxPorAula,
		PausarSinJugadores = self.PausarSinJugadores,
	}
end

-- Copia de la lista de aulas activas.
function SchoolDayService:ObtenerAulasActivas()
	return copiaLista(self.AulasActivas)
end

---------------------------------------------------------------------------------------------------
-- Difusión y timbre
---------------------------------------------------------------------------------------------------
function SchoolDayService:_Difundir()
	local snapshot = self:Snapshot()
	self.UltimoSnapshot = snapshot
	self:_EnviarATodos("Jornada", snapshot)
	self.JornadaActualizada:Fire(snapshot)
	return snapshot
end

function SchoolDayService:_EnviarSnapshotA(player)
	if esJugador(player) and player.Parent ~= nil then
		self:_Enviar(player, "Jornada", self:Snapshot())
	end
end

function SchoolDayService:_IdTimbre()
	local id = tonumber(Config.Sonidos and Config.Sonidos.Timbre) or 0
	if not esFinito(id) or id <= 0 then
		return 0
	end
	return math.floor(id)
end

-- Sound único en SoundService (solo si Config.Sonidos.Timbre > 0).
function SchoolDayService:_PrepararSonido()
	if not self.SonidoTimbreEnServidor then
		return nil
	end
	local id = self:_IdTimbre()
	if id <= 0 then
		return nil
	end
	if self.SonidoTimbre and self.SonidoTimbre.Parent ~= nil then
		return self.SonidoTimbre
	end
	local ok, sonido = pcall(function()
		local existente = SoundService:FindFirstChild(self.NombreSonidoTimbre)
		if not (existente and existente:IsA("Sound")) then
			existente = Instance.new("Sound")
			existente.Name = self.NombreSonidoTimbre
			existente.Parent = SoundService
		end
		existente.SoundId = string.format("rbxassetid://%d", id)
		existente.Volume = self.VolumenTimbre
		existente.Looped = false
		return existente
	end)
	if not ok or not sonido then
		self:_Avisar("sonido_timbre", sonido)
		return nil
	end
	self.SonidoTimbre = sonido
	self.Maid:GiveTask(sonido)
	return sonido
end

function SchoolDayService:_SonarTimbre()
	local sonido = self:_PrepararSonido()
	if not sonido then
		return false
	end
	local ok, err = pcall(function()
		sonido.TimePosition = 0
		sonido:Play()
	end)
	if not ok then
		self:_Avisar("sonido_timbre", err)
	end
	return ok
end

function SchoolDayService:_Timbre(estado)
	local texto = TEXTOS_TIMBRE[estado]
	if TimetableDefinitions.EsClase(estado) then
		texto = "🔔 Comienza la " .. TimetableDefinitions.Nombre(estado) .. " · "
			.. TimetableDefinitions.NombreMateria(self:MateriaDe(estado)) .. ". ¡Todos a clase!"
	elseif estado == "TRANSICION" then
		texto = "🔔 Cambio de clase. A continuación: " .. self:_NombreProximo(TimetableDefinitions.Siguiente(estado)) .. "."
	end
	if not texto then
		texto = "🔔 Comienza: " .. TimetableDefinitions.Nombre(estado)
	end
	-- SonidoServidor indica al cliente que el sonido ya suena desde SoundService (evita oírlo dos veces).
	local sonidoServidor = self.SonidoTimbreEnServidor == true and self:_IdTimbre() > 0
	self:_NotificarTodos(texto, "timbre", 5, { Estado = estado, SonidoServidor = sonidoServidor })
	self:_SonarTimbre()
end

---------------------------------------------------------------------------------------------------
-- Máquina de estados
---------------------------------------------------------------------------------------------------
function SchoolDayService:_AlLatido(dt)
	if esFinito(dt) and dt > 0 then
		self.Acumulador = self.Acumulador + dt
	end
	if self.Acumulador < self.IntervaloTickSeg then
		return
	end
	self.Acumulador = 0
	local ok, err = pcall(self._Tick, self)
	if not ok then
		self:_Avisar("tick", err)
	end
end

function SchoolDayService:_Tick()
	if self.EnEspera or self.Pausada or self._Avanzando then
		return
	end
	local transcurrido = self:Transcurrido()
	local clase = self.ClaseActual
	if clase and clase.Estado == self.EstadoActual then
		self:_ProcesarAsistencia(transcurrido)
	end
	if transcurrido >= self.Duracion then
		self:_Avanzar("tiempo")
	end
end

-- Pasa al periodo siguiente. Devuelve ok, estadoNuevo|motivo.
function SchoolDayService:_Avanzar(motivo, actor)
	if self._Avanzando then
		return false, "en_curso"
	end
	self._Avanzando = true
	local siguiente = TimetableDefinitions.Siguiente(self.EstadoActual)
	local ok, err = pcall(self._EntrarEstado, self, siguiente, motivo, { Actor = actor })
	self._Avanzando = false
	if not ok then
		warn(PREFIJO .. " Error al pasar a " .. tostring(siguiente) .. ": " .. tostring(err))
		return false, "error_interno"
	end
	return true, siguiente
end

-- Entra en un periodo: cierra el anterior, prepara el nuevo, toca el timbre y difunde el snapshot.
-- opciones = { Inicial, EnEspera, SinTimbre, Actor }.
function SchoolDayService:_EntrarEstado(estado, motivo, opciones)
	opciones = typeof(opciones) == "table" and opciones or {}
	local anterior = self.EstadoActual
	if not opciones.Inicial then
		self:_AlSalirDeEstado(anterior, estado, motivo)
	end

	self.EstadoActual = estado
	self.Indice = TimetableDefinitions.Indice(estado) or 1
	self.Duracion = self:DuracionDe(estado)
	self.InicioServidor = ahora()
	self.TranscurridoPausa = 0
	if estado == ESTADO_INICIAL then
		if opciones.EnEspera ~= nil then
			self.EnEspera = opciones.EnEspera == true
		else
			self.EnEspera = self.Modo == "Manual"
		end
	else
		self.EnEspera = false
	end

	if estado == ESTADO_ENTRADA and anterior ~= estado then
		self:_IniciarJornada()
	end
	if TimetableDefinitions.EsClase(estado) then
		self:_IniciarAsistencia(estado)
	end

	if not opciones.SinTimbre and self.EstadosConTimbre[estado] then
		self:_Timbre(estado)
	end

	local snapshot = self:_Difundir()

	if estado == ESTADO_FINAL then
		self:_FinalizarJornada(motivo, opciones.Actor)
	end
	if TimetableDefinitions.EsClase(estado) then
		self:_RecordatorioInicioClase()
	end

	self:_Auditar("Sistema", opciones.Actor, "Jornada", string.format("%s -> %s (%s)", tostring(anterior), tostring(estado), tostring(motivo)))
	self.EstadoCambiado:Fire(estado, snapshot)
	return snapshot
end

function SchoolDayService:_AlSalirDeEstado(anterior, _nuevo, motivo)
	local clase = self.ClaseActual
	if clase and clase.Estado == anterior then
		self:_CerrarAsistencia(motivo)
	end
end

---------------------------------------------------------------------------------------------------
-- Control (Iniciar / Pausar / Reanudar / Saltar / Reiniciar / Configurar). Devuelven ok, resultado|motivo.
---------------------------------------------------------------------------------------------------

-- Arranca la jornada desde ESPERA (pasa a ENTRADA). actor opcional para auditoría.
function SchoolDayService:Iniciar(actor)
	if self.EstadoActual ~= ESTADO_INICIAL then
		return false, "ya_iniciada"
	end
	if self._Avanzando then
		return false, "en_curso"
	end
	local enEsperaAntes, pausadaAntes, motivoAntes = self.EnEspera, self.Pausada, self.MotivoPausa
	self.EnEspera = false
	self.Pausada = false
	self.MotivoPausa = nil
	local ok, resultado = self:_Avanzar("iniciar", actor)
	if not ok then
		-- Si no se llegó a salir de ESPERA se restaura su estado (en Manual no debe empezar la cuenta atrás).
		if self.EstadoActual == ESTADO_INICIAL then
			self.EnEspera = enEsperaAntes
			self.Pausada = pausadaAntes
			self.MotivoPausa = motivoAntes
		end
		return false, resultado
	end
	self:_Auditar("Sistema", actor, "JornadaIniciar", "Jornada " .. tostring(self.NumeroJornada) .. " iniciada")
	return true, { Estado = self.EstadoActual, Jornada = self.NumeroJornada }
end

function SchoolDayService:_Pausar(motivo, actor, silencioso)
	if self.EnEspera then
		return false, "en_espera"
	end
	if self.Pausada then
		return false, "ya_pausada"
	end
	self.TranscurridoPausa = math.min(self:Transcurrido(), self.Duracion)
	self.Pausada = true
	self.MotivoPausa = motivo or "manual"
	self:_Difundir()
	if not silencioso then
		self:_NotificarTodos("⏸ La jornada escolar está en pausa.", "info", 4)
	end
	self:_Auditar("Sistema", actor, "JornadaPausar", string.format("%s · %s en %.0f s", tostring(self.MotivoPausa), self.EstadoActual, self.TranscurridoPausa))
	return true, { Estado = self.EstadoActual, Transcurrido = self.TranscurridoPausa }
end

function SchoolDayService:_Reanudar(motivo, actor, silencioso)
	if not self.Pausada then
		return false, "no_pausada"
	end
	self.InicioServidor = ahora() - (self.TranscurridoPausa or 0)
	self.Pausada = false
	self.MotivoPausa = nil
	self:_Difundir()
	if not silencioso then
		self:_NotificarTodos("▶ La jornada escolar continúa.", "info", 4)
	end
	self:_Auditar("Sistema", actor, "JornadaReanudar", tostring(motivo) .. " · " .. self.EstadoActual)
	return true, { Estado = self.EstadoActual }
end

-- Congela el periodo actual (el reloj escolar del cliente se detiene).
function SchoolDayService:Pausar(actor)
	return self:_Pausar("manual", actor, false)
end

-- Continúa el periodo desde donde se pausó.
function SchoolDayService:Reanudar(actor)
	if self.EnEspera then
		return false, "en_espera"
	end
	return self:_Reanudar("manual", actor, false)
end

-- Termina el periodo actual y pasa al siguiente (en espera equivale a Iniciar). Si estaba en pausa, el
-- periodo nuevo empieza también en pausa.
function SchoolDayService:Saltar(actor)
	if self.EnEspera then
		return self:Iniciar(actor)
	end
	local anterior = self.EstadoActual
	local ok, resultado = self:_Avanzar("saltar", actor)
	if not ok then
		return false, resultado
	end
	self:_Auditar("Sistema", actor, "JornadaSaltar", anterior .. " -> " .. self.EstadoActual)
	return true, { Anterior = anterior, Estado = self.EstadoActual }
end

-- Cierra la jornada en curso (si la hay) y vuelve a ESPERA (en Manual queda esperando a Iniciar).
function SchoolDayService:Reiniciar(actor)
	if self._Avanzando then
		return false, "en_curso"
	end
	if self.Jornada and not self.Jornada.Finalizada then
		self:_FinalizarJornada("reiniciar", actor)
	end
	self.Pausada = false
	self.MotivoPausa = nil
	self._Avanzando = true
	local ok, err = pcall(self._EntrarEstado, self, ESTADO_INICIAL, "reiniciar", { Actor = actor, SinTimbre = true })
	self._Avanzando = false
	if not ok then
		warn(PREFIJO .. " Error al reiniciar la jornada: " .. tostring(err))
		return false, "error_interno"
	end
	self:_NotificarTodos("🔄 La dirección reinició la jornada escolar.", "info", 5)
	self:_Auditar("Sistema", actor, "JornadaReiniciar", "Vuelta a " .. ESTADO_INICIAL .. (self.EnEspera and " (esperando Iniciar)" or ""))
	return true, { Estado = self.EstadoActual, EnEspera = self.EnEspera }
end

-- Valida una tabla de configuración. Devuelve cambios | nil, motivo.
function SchoolDayService:_ValidarConfiguracion(t)
	local cambios = {}
	local n = 0
	for clave in pairs(t) do
		if typeof(clave) ~= "string" or not CLAVES_CONFIG[clave] then
			return nil, "clave_desconocida:" .. tostring(clave)
		end
		n = n + 1
	end
	if n == 0 then
		return nil, "sin_cambios"
	end

	if t.Modo ~= nil then
		if t.Modo ~= "Automatica" and t.Modo ~= "Manual" then
			return nil, "modo_invalido"
		end
		cambios.Modo = t.Modo
	end

	if t.EscalaTiempo ~= nil then
		if not esFinito(t.EscalaTiempo) or t.EscalaTiempo < self.EscalaMin or t.EscalaTiempo > self.EscalaMax then
			return nil, "escala_invalida"
		end
		cambios.EscalaTiempo = t.EscalaTiempo
	end

	if t.Duraciones ~= nil then
		if typeof(t.Duraciones) ~= "table" then
			return nil, "duraciones_invalidas"
		end
		local duraciones = {}
		for estado, seg in pairs(t.Duraciones) do
			if not TimetableDefinitions.Existe(estado) then
				return nil, "estado_invalido:" .. tostring(estado)
			end
			if seg == false then
				duraciones[estado] = false -- restaura la duración de TimetableDefinitions
			elseif not esFinito(seg) or seg < self.DuracionMinSeg or seg > self.DuracionMaxSeg then
				return nil, "duracion_invalida:" .. estado
			else
				duraciones[estado] = math.floor(seg + 0.5)
			end
		end
		cambios.Duraciones = duraciones
	end

	if t.Materias ~= nil then
		if typeof(t.Materias) ~= "table" then
			return nil, "materias_invalidas"
		end
		local materias = {}
		for estado, codigo in pairs(t.Materias) do
			if not TimetableDefinitions.EsClase(estado) then
				return nil, "clase_invalida:" .. tostring(estado)
			end
			if codigo == false then
				materias[estado] = false -- restaura la materia de TimetableDefinitions
			elseif not TimetableDefinitions.ExisteMateria(codigo) then
				return nil, "materia_invalida:" .. tostring(codigo)
			else
				materias[estado] = codigo
			end
		end
		cambios.Materias = materias
	end

	if t.AulasActivas ~= nil then
		local lista = t.AulasActivas
		if typeof(lista) ~= "table" then
			return nil, "aulas_invalidas"
		end
		local total = 0
		for _ in pairs(lista) do
			total = total + 1
		end
		if total == 0 or total ~= #lista or total > self.MaxAulasActivas then
			return nil, "aulas_invalidas"
		end
		local aulas, vistos = {}, {}
		for _, id in ipairs(lista) do
			if not esAula(id) then
				return nil, "aula_invalida:" .. tostring(id)
			end
			if not vistos[id] then
				vistos[id] = true
				table.insert(aulas, id)
			end
		end
		cambios.AulasActivas = aulas
	end

	if t.EstudiantesPorAulaMax ~= nil then
		local maximo = t.EstudiantesPorAulaMax
		if not esFinito(maximo) or maximo ~= math.floor(maximo) or maximo < 1 or maximo > self.EstudiantesPorAulaLimite then
			return nil, "maximo_invalido"
		end
		cambios.EstudiantesPorAulaMax = maximo
	end

	if t.PausarSinJugadores ~= nil then
		if typeof(t.PausarSinJugadores) ~= "boolean" then
			return nil, "pausa_invalida"
		end
		cambios.PausarSinJugadores = t.PausarSinJugadores
	end

	return cambios
end

-- Aplica cambios ya validados. Devuelve la tabla de lo aplicado.
function SchoolDayService:_AplicarConfiguracion(c)
	local aplicado = {}

	-- Duraciones y escala: se recalcula el periodo en curso.
	local transcurridoAntes = self:Transcurrido()
	local duracionAntes = self.Duracion
	if c.Duraciones then
		for estado, seg in pairs(c.Duraciones) do
			if seg == false then
				self.Duraciones[estado] = nil
			else
				self.Duraciones[estado] = seg
			end
		end
		aplicado.Duraciones = c.Duraciones
	end
	if c.EscalaTiempo then
		self.EscalaTiempo = c.EscalaTiempo
		aplicado.EscalaTiempo = c.EscalaTiempo
	end
	if c.Duraciones or c.EscalaTiempo then
		local nueva = self:DuracionDe(self.EstadoActual)
		if nueva ~= duracionAntes then
			local transcurrido = transcurridoAntes
			if c.EscalaTiempo and duracionAntes > 0 then
				-- Con un cambio de escala se conserva la fracción recorrida del periodo.
				transcurrido = acotar(transcurridoAntes / duracionAntes, 0, 1) * nueva
			end
			self.Duracion = nueva
			if self.Pausada then
				self.TranscurridoPausa = math.min(transcurrido, nueva)
			elseif not self.EnEspera then
				self.InicioServidor = ahora() - transcurrido
			end
		end
		-- La clase en curso adapta su tolerancia y su límite de ausencia (si no, una clase acortada podría
		-- terminar antes de pasar lista y descartarse entera).
		local clase = self.ClaseActual
		if clase and not clase.Cerrada and clase.Estado == self.EstadoActual then
			clase.Tolerancia, clase.LimiteAusencia = self:_LimitesAsistencia(self.Duracion)
		end
	end

	if c.Materias then
		for estado, codigo in pairs(c.Materias) do
			if codigo == false then
				self.Materias[estado] = nil
			else
				self.Materias[estado] = codigo
			end
		end
		local clase = self.ClaseActual
		if clase and c.Materias[clase.Estado] ~= nil then
			clase.Materia = self:MateriaDe(clase.Estado)
			clase.MateriaNombre = TimetableDefinitions.NombreMateria(clase.Materia)
		end
		aplicado.Materias = c.Materias
	end

	if c.EstudiantesPorAulaMax then
		self.MaxPorAula = c.EstudiantesPorAulaMax
		aplicado.EstudiantesPorAulaMax = c.EstudiantesPorAulaMax
	end

	if c.PausarSinJugadores ~= nil then
		self.PausarSinJugadores = c.PausarSinJugadores
		aplicado.PausarSinJugadores = c.PausarSinJugadores
		if not c.PausarSinJugadores and self.Pausada and self.MotivoPausa == "sin_jugadores" then
			self:_Reanudar("configuracion", nil, true)
		end
	end

	if c.AulasActivas then
		self.AulasActivas = c.AulasActivas
		aplicado.AulasActivas = c.AulasActivas
		aplicado.Reubicados = self:_ReubicarFueraDeAulasActivas()
	end

	if c.Modo and c.Modo ~= self.Modo then
		self.Modo = c.Modo
		aplicado.Modo = c.Modo
		if self.EstadoActual == ESTADO_INICIAL then
			if self.Modo == "Manual" and not self.EnEspera then
				-- En Manual la espera no avanza sola.
				self.EnEspera = true
				self.TranscurridoPausa = 0
			elseif self.Modo == "Automatica" and self.EnEspera then
				-- En Automatica empieza la cuenta atrás de la espera.
				self.EnEspera = false
				self.InicioServidor = ahora()
			end
		end
	end

	return aplicado
end

-- Cambia en caliente { Modo, EscalaTiempo, Duraciones = {ESTADO = seg|false}, Materias = {CLASE_n = código|false},
-- AulasActivas = {roomId...}, EstudiantesPorAulaMax, PausarSinJugadores }. Validación atómica: o se aplica
-- todo o nada. Devuelve ok, aplicado|motivo.
function SchoolDayService:Configurar(tabla, actor)
	if typeof(tabla) ~= "table" then
		return false, "datos_invalidos"
	end
	local cambios, motivo = self:_ValidarConfiguracion(tabla)
	if not cambios then
		return false, motivo
	end
	local aplicado = self:_AplicarConfiguracion(cambios)
	self:_Difundir()
	local partes = {}
	for clave in pairs(aplicado) do
		table.insert(partes, clave)
	end
	table.sort(partes)
	self:_Auditar("Sistema", actor, "JornadaConfigurar", "Cambios: " .. table.concat(partes, ", "))
	return true, aplicado
end

---------------------------------------------------------------------------------------------------
-- Jornada (inicio, cierre, historial)
---------------------------------------------------------------------------------------------------
function SchoolDayService:_NuevaJornada(numero)
	return { Numero = numero, Inicio = os.time(), Fin = nil, Clases = {}, Orden = {}, Finalizada = false }
end

function SchoolDayService:_IniciarJornada()
	if self.Jornada and not self.Jornada.Finalizada then
		self:_FinalizarJornada("nueva_jornada")
	end
	self.NumeroJornada = self.NumeroJornada + 1
	self.Jornada = self:_NuevaJornada(self.NumeroJornada)
end

-- Resumen por clase de una jornada (datos simples).
function SchoolDayService:_ResumenJornada(jornada)
	local clases = {}
	local totales = resumenVacio()
	for _, estado in ipairs(jornada.Orden) do
		local clase = jornada.Clases[estado]
		if clase then
			local r = resumenVacio()
			local aulas = 0
			for _, registros in pairs(clase.PorAula) do
				aulas = aulas + 1
				for _, reg in pairs(registros) do
					local clave = CLAVE_RESUMEN[reg.Estado]
					if clave then
						r[clave] = r[clave] + 1
						r.Total = r.Total + 1
						totales[clave] = totales[clave] + 1
						totales.Total = totales.Total + 1
					end
				end
			end
			table.insert(clases, {
				Clase = estado, Nombre = clase.Nombre, Materia = clase.Materia, MateriaNombre = clase.MateriaNombre,
				Aulas = aulas, Presentes = r.Presentes, Tardanzas = r.Tardanzas, Ausentes = r.Ausentes, Pendientes = r.Pendientes,
			})
		end
	end
	return {
		Numero = jornada.Numero, Inicio = jornada.Inicio, Fin = jornada.Fin,
		Presentes = totales.Presentes, Tardanzas = totales.Tardanzas, Ausentes = totales.Ausentes,
		Clases = clases,
	}
end

-- Cierre de la jornada: asistencia pendiente, sesiones de clase, guardado de perfiles y limpieza temporal.
function SchoolDayService:_FinalizarJornada(motivo, actor)
	local jornada = self.Jornada
	if not jornada or jornada.Finalizada then
		return nil
	end
	if self.ClaseActual then
		self:_CerrarAsistencia(motivo)
	end
	jornada.Finalizada = true
	jornada.Fin = os.time()
	local resumen = self:_ResumenJornada(jornada)
	table.insert(self.Historial, 1, resumen)
	while #self.Historial > self.MaxHistorialJornadas do
		table.remove(self.Historial)
	end

	-- Progreso: todos los perfiles quedan marcados para el próximo guardado.
	for _, player in ipairs(Players:GetPlayers()) do
		self:_Llamar("DataService", "Marcar", player)
	end

	-- Estructuras temporales de la jornada (no hay conexiones por jornada que desconectar).
	self.UltimaAula = {}
	self.ClaseActual = nil

	self:_NotificarTodos(string.format("🏫 Fin de la jornada escolar: %d asistencias, %d tardanzas y %d ausencias. ¡Buen trabajo!",
		resumen.Presentes, resumen.Tardanzas, resumen.Ausentes), "info", 6)
	self:_Auditar("Sistema", actor, "FinJornada", string.format("Jornada %d (%s): %d presentes, %d tardanzas, %d ausentes en %d clases",
		jornada.Numero, tostring(motivo), resumen.Presentes, resumen.Tardanzas, resumen.Ausentes, #resumen.Clases))
	-- Los oyentes (ClassroomService cierra sus sesiones con un texto propio, FoodService renueva lotes...)
	-- reciben la señal primero; después se cierran las sesiones que queden (en otro hilo: no bloquea).
	self.JornadaTerminada:Fire(resumen)
	task.spawn(function()
		-- ClassroomService muestra el motivo a los alumnos (SesionCerrada.Motivo): texto en español, no un código.
		self:_Llamar("ClassroomService", "CerrarTodas", "Fin de la jornada escolar.")
	end)
	return resumen
end

---------------------------------------------------------------------------------------------------
-- Aulas: asignación balanceada (atributo Salon del Player)
---------------------------------------------------------------------------------------------------

-- Lista de aulas válidas y sin duplicados; si queda vacía usa MapaLogico.Aulas.
function SchoolDayService:_FiltrarAulas(lista, avisar)
	local resultado, vistos, invalidas = {}, {}, {}
	if typeof(lista) == "table" then
		for _, id in ipairs(lista) do
			if esAula(id) then
				if not vistos[id] then
					vistos[id] = true
					table.insert(resultado, id)
				end
			else
				table.insert(invalidas, tostring(id))
			end
		end
	end
	if avisar and #invalidas > 0 then
		warn(PREFIJO .. " Config.Jornada.AulasActivas contiene aulas que no existen en MapaLogico.Aulas (se ignoran): " .. table.concat(invalidas, ", "))
	end
	if #resultado == 0 then
		for _, id in ipairs(MapaLogico.Aulas or {}) do
			if esAula(id) and not vistos[id] then
				vistos[id] = true
				table.insert(resultado, id)
			end
		end
	end
	return resultado
end

function SchoolDayService:_CargoDe(player)
	local ok, cargo = self:_Llamar("RoleService", "Cargo", player)
	if ok and RoleDefinitions.Existe(cargo) then
		return cargo
	end
	local atributo = player:GetAttribute("Cargo")
	if RoleDefinitions.Existe(atributo) then
		return atributo
	end
	return nil
end

function SchoolDayService:_EsEstudiante(player)
	return self:_CargoDe(player) == CARGO_ESTUDIANTE
end

function SchoolDayService:_EsDocente(player)
	local cargo = self:_CargoDe(player)
	return cargo ~= nil and cargo ~= CARGO_ESTUDIANTE and RoleDefinitions.EsDocente(cargo)
end

-- Docente "de aula": cargos del equipo Docentes o que aparecen en el aula asignada. Los directivos con
-- aula.docente pueden dar clase, pero no se les reserva aula automáticamente.
function SchoolDayService:_EsDocenteDeAula(cargo)
	local rol = RoleDefinitions.Obtener(cargo)
	if not rol or not RoleDefinitions.EsDocente(cargo) then
		return false
	end
	return rol.ZonaSpawn == RoleDefinitions.ZonaSpawnAulaAsignada or rol.Equipo == "Docentes"
end

-- Aula asignada al jugador (atributo Salon) o nil.
function SchoolDayService:AulaDe(player)
	if not esJugador(player) then
		return nil
	end
	local ok, salon = pcall(function()
		return player:GetAttribute("Salon")
	end)
	if ok and esZona(salon) then
		return salon
	end
	return nil
end

-- Asientos del aula (MapService si existe; si no, el recuento del mapa lógico).
function SchoolDayService:_Asientos(roomId)
	local ok, info = self:_Llamar("MapService", "Aula", roomId)
	if ok and typeof(info) == "table" then
		if typeof(info.Seats) == "table" then
			return #info.Seats
		end
		if typeof(info.Capacidad) == "number" then
			return info.Capacidad
		end
	end
	local zona = MapaLogico.Zonas[roomId]
	if zona then
		return tonumber(zona.Asientos) or 0
	end
	return 0
end

-- roomId -> estudiantes conectados con esa aula (excluye opcionalmente a un jugador).
function SchoolDayService:_ConteoEstudiantes(excluir)
	local conteo = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= excluir then
			local salon = self:AulaDe(player)
			if salon and self:_EsEstudiante(player) then
				conteo[salon] = (conteo[salon] or 0) + 1
			end
		end
	end
	return conteo
end

-- roomId -> primer docente conectado con esa aula (excluye opcionalmente a un jugador).
function SchoolDayService:_DocentesPorAula(excluir)
	local mapa = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= excluir then
			local salon = self:AulaDe(player)
			if salon and mapa[salon] == nil and self:_EsDocente(player) then
				mapa[salon] = player
			end
		end
	end
	return mapa
end

-- Reparto: primero aulas con docente, luego aulas ya en uso, luego aulas con asientos (orden de AulasActivas).
-- Se abren solo las aulas necesarias (ceil(estudiantes / máximo), y al menos las que tienen docente) y entre
-- ellas se elige la menos ocupada, prefiriendo la que conserva un asiento libre.
function SchoolDayService:_ElegirAulaEstudiante(player)
	local maximo = self.MaxPorAula
	local conteo = self:_ConteoEstudiantes(player)
	local activas = {}
	for _, id in ipairs(self.AulasActivas) do
		activas[id] = true
	end

	-- Se conserva el aula actual o la de esta misma jornada si siguen activas y con cupo.
	local actual = self:AulaDe(player)
	if actual and activas[actual] and (conteo[actual] or 0) < maximo then
		return actual
	end
	local previa = self.UltimaAula[player.UserId]
	if previa and activas[previa] and (conteo[previa] or 0) < maximo then
		return previa
	end

	local docentes = self:_DocentesPorAula(player)
	local filas = {}
	local total, conDocente = 0, 0
	for i, id in ipairs(self.AulasActivas) do
		local n = conteo[id] or 0
		local fila = { Id = id, N = n, Orden = i, Docente = docentes[id] ~= nil, Asientos = self:_Asientos(id) }
		total = total + n
		if fila.Docente then
			conDocente = conDocente + 1
		end
		table.insert(filas, fila)
	end
	if #filas == 0 then
		if esAula(RoleDefinitions.AulaRespaldo) then
			return RoleDefinitions.AulaRespaldo
		end
		return nil
	end

	table.sort(filas, function(a, b)
		if a.Docente ~= b.Docente then
			return a.Docente
		end
		local usoA, usoB = a.N > 0, b.N > 0
		if usoA ~= usoB then
			return usoA
		end
		local sillasA, sillasB = a.Asientos > 0, b.Asientos > 0
		if sillasA ~= sillasB then
			return sillasA
		end
		return a.Orden < b.Orden
	end)

	local function mejorEntre(desde, hasta, ignorarMaximo)
		local mejor = nil
		for i = desde, hasta do
			local f = filas[i]
			if ignorarMaximo or f.N < maximo then
				if mejor == nil or f.N < mejor.N then
					mejor = f
				elseif f.N == mejor.N then
					local libreF = f.Asientos > f.N
					local libreM = mejor.Asientos > mejor.N
					if libreF and not libreM then
						mejor = f
					end
				end
			end
		end
		return mejor
	end

	local necesarias = math.max(1, math.ceil((total + 1) / maximo), conDocente)
	local limite = math.min(necesarias, #filas)
	local elegida = mejorEntre(1, limite, false)
	if not elegida and limite < #filas then
		elegida = mejorEntre(limite + 1, #filas, false)
	end
	if not elegida then
		-- Todas llenas: la menos ocupada (se informa en la auditoría).
		elegida = mejorEntre(1, #filas, true)
		if elegida then
			self:_Auditar("Clase", player, "AulasLlenas", "Todas las aulas activas alcanzaron " .. maximo .. " estudiantes; se asigna " .. elegida.Id)
		end
	end
	if elegida then
		return elegida.Id
	end
	return nil
end

-- Aula sin docente para un docente: la que más estudiantes espera, luego con asientos, luego por orden.
function SchoolDayService:_ElegirAulaDocente(player)
	local docentes = self:_DocentesPorAula(player)
	local actual = self:AulaDe(player)
	if actual and esAula(actual) and docentes[actual] == nil then
		return actual
	end
	local conteo = self:_ConteoEstudiantes(nil)
	local filas = {}
	for i, id in ipairs(self.AulasActivas) do
		if docentes[id] == nil then
			table.insert(filas, { Id = id, N = conteo[id] or 0, Orden = i, Asientos = self:_Asientos(id) })
		end
	end
	table.sort(filas, function(a, b)
		if a.N ~= b.N then
			return a.N > b.N
		end
		local sillasA, sillasB = a.Asientos > 0, b.Asientos > 0
		if sillasA ~= sillasB then
			return sillasA
		end
		return a.Orden < b.Orden
	end)
	if filas[1] then
		return filas[1].Id
	end
	-- Todas las aulas activas tienen docente: aulas especiales libres, luego el aula de respaldo.
	for _, id in ipairs(MapaLogico.Aulas or {}) do
		if esAula(id) and docentes[id] == nil then
			return id
		end
	end
	if esAula(RoleDefinitions.AulaRespaldo) then
		return RoleDefinitions.AulaRespaldo
	end
	return self.AulasActivas[1]
end

function SchoolDayService:_FijarSalon(player, roomId, recordar)
	pcall(function()
		player:SetAttribute("Salon", roomId)
	end)
	if recordar and roomId then
		self.UltimaAula[player.UserId] = roomId
	end
end

-- Asigna aula al jugador y la guarda en su atributo Salon. roomId = nil elige automáticamente (estudiante:
-- reparto balanceado; docente: aula sin docente). Devuelve roomId | nil, motivo.
function SchoolDayService:AsignarAula(player, roomId)
	if not esJugador(player) then
		return nil, "jugador_invalido"
	end
	local cargo = self:_CargoDe(player) or CARGO_ESTUDIANTE
	local esEstudiante = cargo == CARGO_ESTUDIANTE
	local esDocente = not esEstudiante and RoleDefinitions.EsDocente(cargo)

	if roomId ~= nil then
		if not esAula(roomId) then
			return nil, "aula_invalida"
		end
		if esEstudiante then
			local n = self:_ConteoEstudiantes(player)[roomId] or 0
			if n >= self.MaxPorAula and self:AulaDe(player) ~= roomId then
				return nil, "aula_llena"
			end
		elseif esDocente then
			if self:_DocentesPorAula(player)[roomId] then
				return nil, "aula_con_docente"
			end
		end
		self:_FijarSalon(player, roomId, esEstudiante)
		return roomId
	end

	local aula = nil
	if esEstudiante then
		aula = self:_ElegirAulaEstudiante(player)
	elseif esDocente then
		if self:_EsDocenteDeAula(cargo) then
			aula = self:_ElegirAulaDocente(player)
		else
			aula = self:AulaDe(player)
			if not aula then
				return nil, "cargo_sin_aula"
			end
		end
	else
		return nil, "cargo_sin_aula"
	end
	if not aula then
		return nil, "sin_aulas"
	end
	self:_FijarSalon(player, aula, esEstudiante)
	return aula
end

-- Quita el aula del jugador (RoleService la usa al cambiar a un cargo sin aula).
function SchoolDayService:LiberarAula(player)
	if not esJugador(player) then
		return false
	end
	self.UltimaAula[player.UserId] = nil
	pcall(function()
		player:SetAttribute("Salon", nil)
	end)
	return true
end

-- Aula actual del jugador; si es estudiante y no tiene, se le asigna una (con aviso).
function SchoolDayService:_AulaOAsignar(player)
	local salon = self:AulaDe(player)
	if salon then
		return salon
	end
	local aula = self:AsignarAula(player, nil)
	if aula then
		self:_Notificar(player, "Se te asignó el salón: " .. nombreAula(aula), "info", 5)
	end
	return aula
end

-- Estudiantes cuya aula dejó de estar activa: se les asigna otra. Devuelve cuántos se reubicaron.
function SchoolDayService:_ReubicarFueraDeAulasActivas()
	local activas = {}
	for _, id in ipairs(self.AulasActivas) do
		activas[id] = true
	end
	local reubicados = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if self:_EsEstudiante(player) then
			local salon = self:AulaDe(player)
			if salon and not activas[salon] then
				self:LiberarAula(player)
				local nueva = self:AsignarAula(player, nil)
				if nueva then
					reubicados = reubicados + 1
					self:_Notificar(player, "Tu salón ha cambiado: " .. nombreAula(nueva), "aviso", 6)
				end
			end
		end
	end
	return reubicados
end

-- ¿El jugador está físicamente en su aula? Caja de la zona (Zones.Contiene, con un margen pequeño)
-- o sentado en un asiento de esa aula.
function SchoolDayService:EstaEnSuAula(player, roomId)
	if not esJugador(player) then
		return false
	end
	roomId = roomId or self:AulaDe(player)
	if not roomId then
		return false
	end
	local posicion = posicionDe(player)
	if posicion then
		if Zones.Contiene(roomId, posicion) then
			return true
		end
		if Zones.DistanciaA(roomId, posicion) <= self.MargenAulaStuds then
			return true
		end
	end
	local okAsiento, asiento = self:_Llamar("RoomService", "AsientoDe", player)
	if okAsiento and typeof(asiento) == "Instance" then
		local okAula, aulaAsiento = self:_Llamar("RoomService", "AulaDeAsiento", asiento)
		if not okAula then
			okAula, aulaAsiento = self:_Llamar("MapService", "AulaDeAsiento", asiento)
		end
		if okAula and aulaAsiento == roomId then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Asistencia
---------------------------------------------------------------------------------------------------
-- Tolerancia (Presente) y límite (Ausente) en segundos reales para una clase de 'duracion' con la escala vigente.
function SchoolDayService:_LimitesAsistencia(duracion)
	local escala = self.EscalaTiempo
	local tolerancia = (tonumber(TimetableDefinitions.ToleranciaTardanzaSeg) or 60) * escala
	tolerancia = acotar(tolerancia, 3, math.max(3, duracion * 0.5))
	local limite = (tonumber(TimetableDefinitions.MarcarAusenciaSeg) or 180) * escala
	limite = acotar(limite, tolerancia + 1, math.max(tolerancia + 1, duracion * 0.9))
	return tolerancia, limite
end

function SchoolDayService:_IniciarAsistencia(estado)
	local tolerancia, limite = self:_LimitesAsistencia(self.Duracion)
	local materia = self:MateriaDe(estado)
	local clase = {
		Estado = estado,
		Nombre = TimetableDefinitions.Nombre(estado),
		Materia = materia,
		MateriaNombre = TimetableDefinitions.NombreMateria(materia),
		Jornada = self.NumeroJornada,
		Inicio = os.time(),
		Fin = nil,
		Tolerancia = tolerancia,
		LimiteAusencia = limite,
		Fase = 0, -- 0 = esperando tolerancia; 1 = presentes marcados (llegadas tarde); 2 = ausencias marcadas
		UltimaRevision = 0,
		PorAula = {}, -- roomId -> { [userId] = registro }
		PorJugador = {}, -- userId -> registro { UserId, Nombre, RoomId, Estado, T }
		Cerrada = false,
	}
	self.ClaseActual = clase
	local jornada = self.Jornada
	if jornada and not jornada.Finalizada then
		if jornada.Clases[estado] == nil then
			table.insert(jornada.Orden, estado)
		end
		jornada.Clases[estado] = clase
	end
end

-- Registro de asistencia del jugador en la clase (lo crea o lo mueve de aula mientras esté pendiente).
function SchoolDayService:_Registro(clase, player, roomId)
	local userId = player.UserId
	local reg = clase.PorJugador[userId]
	if reg then
		if reg.RoomId ~= roomId and reg.Estado == "Pendiente" then
			local anterior = clase.PorAula[reg.RoomId]
			if anterior then
				anterior[userId] = nil
			end
			reg.RoomId = roomId
			if not clase.PorAula[roomId] then
				clase.PorAula[roomId] = {}
			end
			clase.PorAula[roomId][userId] = reg
		end
		return reg
	end
	reg = { UserId = userId, Nombre = nombreJugador(player), RoomId = roomId, Estado = "Pendiente", T = 0 }
	clase.PorJugador[userId] = reg
	if not clase.PorAula[roomId] then
		clase.PorAula[roomId] = {}
	end
	clase.PorAula[roomId][userId] = reg
	return reg
end

-- Al comenzar una clase: registra a cada estudiante y recuerda su salón a quien no está en él.
function SchoolDayService:_RecordatorioInicioClase()
	local clase = self.ClaseActual
	if not clase then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if self:_EsEstudiante(player) then
			local roomId = self:_AulaOAsignar(player)
			if roomId then
				self:_Registro(clase, player, roomId)
				if not self:EstaEnSuAula(player, roomId) then
					self:_Notificar(player, "Dirígete a tu salón: " .. nombreAula(roomId), "info", 6)
				end
			end
		end
	end
end

function SchoolDayService:_SumarProgreso(player, campo, cantidad)
	local ok, perfil = self:_Llamar("DataService", "Obtener", player)
	if not ok or typeof(perfil) ~= "table" then
		return false
	end
	if typeof(perfil.Progreso) ~= "table" then
		perfil.Progreso = {}
	end
	local actual = tonumber(perfil.Progreso[campo]) or 0
	if not esFinito(actual) then
		actual = 0
	end
	perfil.Progreso[campo] = math.max(0, math.floor(actual + cantidad))
	self:_Llamar("DataService", "Marcar", player)
	return true
end

-- Marca el registro con Presente/Tardanza/Ausente: progreso, recompensa (solo Presente) y aviso al alumno.
function SchoolDayService:_Marcar(clase, player, reg, estado)
	reg.Estado = estado
	reg.T = os.time()
	local materia = clase.MateriaNombre or "la clase"
	if estado == "Presente" then
		self:_SumarProgreso(player, "Asistencias", 1)
		local texto = "✅ Asistencia registrada en " .. materia .. "."
		local monto = recompensaAsistencia()
		if monto > 0 then
			local ok, acreditado = self:_Llamar("EconomyService", "Acreditar", player, monto, "Asistencia",
				string.format("Asistencia · %s · %s", materia, tostring(reg.RoomId)))
			if ok and acreditado == true then
				texto = texto .. " +" .. Format.Moneda(monto)
			end
		end
		self:_Notificar(player, texto, "exito", 4)
	elseif estado == "Tardanza" then
		self:_SumarProgreso(player, "Tardanzas", 1)
		self:_Notificar(player, "⏰ Llegaste tarde a " .. materia .. ": se registró una tardanza.", "aviso", 5)
	elseif estado == "Ausente" then
		self:_SumarProgreso(player, "Ausencias", 1)
		self:_Notificar(player, "Se registró tu ausencia en " .. materia .. " (" .. nombreAula(reg.RoomId) .. ").", "aviso", 6)
	end
	self.AsistenciaMarcada:Fire(player, reg.RoomId, estado, clase.Estado)
end

-- Revisa a los estudiantes pendientes: quien esté en su aula recibe 'marca'. Devuelve cambios, aulasCambiadas.
function SchoolDayService:_Revisar(clase, marca, avisar)
	local cambios = 0
	local aulas = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if self:_EsEstudiante(player) then
			local roomId = self:_AulaOAsignar(player)
			if roomId then
				local reg = self:_Registro(clase, player, roomId)
				if reg.Estado == "Pendiente" then
					if self:EstaEnSuAula(player, roomId) then
						self:_Marcar(clase, player, reg, marca)
						cambios = cambios + 1
						aulas[roomId] = true
					elseif avisar then
						self:_Notificar(player, "Dirígete a tu salón: " .. nombreAula(roomId) .. " (se está pasando lista).", "aviso", 6)
					end
				end
			end
		end
	end
	return cambios, aulas
end

-- Pendientes -> Ausente (desconectados: Ausente sin progreso; ya no estudiantes: Retirado).
function SchoolDayService:_MarcarAusentes(clase)
	for userId, reg in pairs(clase.PorJugador) do
		if reg.Estado == "Pendiente" then
			local player = Players:GetPlayerByUserId(userId)
			if player and self:_EsEstudiante(player) then
				self:_Marcar(clase, player, reg, "Ausente")
			elseif player then
				reg.Estado = "Retirado"
				reg.T = os.time()
			else
				reg.Estado = "Ausente"
				reg.T = os.time()
				reg.Desconectado = true
			end
		end
	end
end

function SchoolDayService:_ProcesarAsistencia(transcurrido)
	local clase = self.ClaseActual
	if not clase or clase.Cerrada or self._Procesando then
		return
	end
	self._Procesando = true
	local ok, err = pcall(function()
		if clase.Fase == 0 then
			if transcurrido >= clase.Tolerancia then
				clase.Fase = 1
				clase.UltimaRevision = os.clock()
				self:_Revisar(clase, "Presente", true)
				self:_EnviarAsistenciaDocentes(clase, nil, false)
			end
		elseif clase.Fase == 1 then
			if transcurrido >= clase.LimiteAusencia then
				clase.Fase = 2
				self:_Revisar(clase, "Tardanza", false)
				self:_MarcarAusentes(clase)
				self:_EnviarAsistenciaDocentes(clase, nil, false)
				self:_AuditarAsistencia(clase)
			elseif os.clock() - clase.UltimaRevision >= self.IntervaloTardanzaSeg then
				clase.UltimaRevision = os.clock()
				local cambios, aulas = self:_Revisar(clase, "Tardanza", false)
				if cambios > 0 then
					self:_EnviarAsistenciaDocentes(clase, aulas, false)
				end
			end
		end
	end)
	self._Procesando = false
	if not ok then
		self:_Avisar("asistencia", err)
	end
end

-- Cierra la asistencia de la clase en curso. Si no llegó a pasarse lista (clase saltada antes de la
-- tolerancia) se descarta; si estaba en fase 1 se completan tardanzas y ausencias.
function SchoolDayService:_CerrarAsistencia(motivo)
	local clase = self.ClaseActual
	self.ClaseActual = nil
	if not clase or clase.Cerrada then
		return
	end
	clase.Cerrada = true
	clase.Fin = os.time()
	clase.MotivoCierre = motivo
	if clase.Fase == 0 then
		clase.Descartada = true
		local jornada = self.Jornada
		if jornada and jornada.Clases[clase.Estado] == clase then
			jornada.Clases[clase.Estado] = nil
			for i = #jornada.Orden, 1, -1 do
				if jornada.Orden[i] == clase.Estado then
					table.remove(jornada.Orden, i)
				end
			end
		end
		return
	end
	if clase.Fase == 1 then
		self:_Revisar(clase, "Tardanza", false)
		self:_MarcarAusentes(clase)
		clase.Fase = 2
		self:_AuditarAsistencia(clase)
	end
	-- Clase completa (terminó por tiempo): cuenta para quien asistió y sigue conectado. Si el aula tiene una
	-- sesión de ClassroomService abierta, la cuenta la hace ClassroomService al cerrarla (no se duplica).
	if motivo == "tiempo" then
		local conSesion = {}
		for roomId in pairs(clase.PorAula) do
			local okSesion, sesion = self:_Llamar("ClassroomService", "SesionDe", roomId)
			conSesion[roomId] = okSesion and typeof(sesion) == "table"
		end
		for userId, reg in pairs(clase.PorJugador) do
			if (reg.Estado == "Presente" or reg.Estado == "Tardanza") and not conSesion[reg.RoomId] then
				local player = Players:GetPlayerByUserId(userId)
				if player then
					self:_SumarProgreso(player, "ClasesCompletadas", 1)
				end
			end
		end
	end
	self:_EnviarAsistenciaDocentes(clase, nil, true)
end

function SchoolDayService:_AuditarAsistencia(clase)
	local r = resumenVacio()
	local aulas = 0
	for _, registros in pairs(clase.PorAula) do
		aulas = aulas + 1
		for _, reg in pairs(registros) do
			local clave = CLAVE_RESUMEN[reg.Estado]
			if clave then
				r[clave] = r[clave] + 1
			end
		end
	end
	self:_Auditar("Clase", nil, "Asistencia", string.format("Jornada %d · %s (%s) · %d aulas: %d presentes, %d tardanzas, %d ausentes",
		clase.Jornada, tostring(clase.Nombre), tostring(clase.MateriaNombre), aulas, r.Presentes, r.Tardanzas, r.Ausentes))
end

-- Datos de asistencia de un aula en una clase (lista ordenada por nombre y resumen).
function SchoolDayService:_DatosAsistenciaAula(clase, roomId)
	local lista = {}
	local resumen = resumenVacio()
	for _, reg in pairs(clase.PorAula[roomId] or {}) do
		local clave = CLAVE_RESUMEN[reg.Estado]
		if clave then
			table.insert(lista, {
				UserId = reg.UserId, Nombre = reg.Nombre, Estado = reg.Estado, T = reg.T,
				Desconectado = reg.Desconectado == true,
			})
			resumen[clave] = resumen[clave] + 1
			resumen.Total = resumen.Total + 1
		end
	end
	table.sort(lista, function(a, b)
		local na, nb = string.lower(a.Nombre), string.lower(b.Nombre)
		if na == nb then
			return a.UserId < b.UserId
		end
		return na < nb
	end)
	return {
		RoomId = roomId,
		NombreAula = nombreAula(roomId),
		Clase = clase.Estado,
		NombreClase = clase.Nombre,
		Materia = clase.Materia,
		MateriaNombre = clase.MateriaNombre,
		Jornada = clase.Jornada,
		Fase = clase.Fase,
		Activa = not clase.Cerrada,
		Tolerancia = clase.Tolerancia,
		LimiteAusencia = clase.LimiteAusencia,
		Lista = lista,
		Resumen = resumen,
	}
end

-- Ocupación del aula con nombres { Sentados = {{UserId, Nombre}}, DePie = {...}, Capacidad, Total } (mismo
-- formato que ClassroomService envía en "Asistencia"): el panel docente sustituye su lista de sentados/de pie
-- con cada evento "Asistencia", así que la asistencia oficial debe llevarla para no vaciarla.
function SchoolDayService:_OcupacionAula(roomId, docenteId)
	local ok, ocupacion = self:_Llamar("ClassroomService", "OcupacionConNombres", roomId, docenteId)
	if ok and typeof(ocupacion) == "table" and typeof(ocupacion.Sentados) == "table" and typeof(ocupacion.DePie) == "table" then
		return ocupacion
	end
	local resultado = { Sentados = {}, DePie = {}, Capacidad = self:_Asientos(roomId), Total = 0 }
	local okRoom, datos = self:_Llamar("RoomService", "Ocupacion", roomId)
	if okRoom and typeof(datos) == "table" then
		for _, clave in ipairs({ "Sentados", "DePie" }) do
			local ids = datos[clave]
			if typeof(ids) == "table" then
				for _, userId in ipairs(ids) do
					if typeof(userId) == "number" and userId ~= docenteId then
						local jugador = Players:GetPlayerByUserId(userId)
						local nombre = "Usuario " .. tostring(userId)
						if jugador then
							nombre = nombreJugador(jugador)
						end
						table.insert(resultado[clave], { UserId = userId, Nombre = nombre })
					end
				end
			end
		end
		if esFinito(datos.Capacidad) then
			resultado.Capacidad = datos.Capacidad
		end
	end
	resultado.Total = #resultado.Sentados + #resultado.DePie
	return resultado
end

-- Envía la asistencia al docente de la sesión de cada aula (ClassroomService:SesionDe(roomId)).
-- aulas = { [roomId] = true } o nil para todas las de la clase.
function SchoolDayService:_EnviarAsistenciaDocentes(clase, aulas, final)
	local conjunto = aulas or clase.PorAula
	for roomId in pairs(conjunto) do
		local ok, sesion = self:_Llamar("ClassroomService", "SesionDe", roomId)
		if ok and typeof(sesion) == "table" then
			local docenteId = sesion.TeacherUserId or sesion.DocenteUserId
			local docente = nil
			if typeof(docenteId) == "number" then
				docente = Players:GetPlayerByUserId(docenteId)
			end
			if docente then
				local datos = self:_DatosAsistenciaAula(clase, roomId)
				local ocupacion = self:_OcupacionAula(roomId, docenteId)
				datos.Sentados = ocupacion.Sentados
				datos.DePie = ocupacion.DePie
				datos.Capacidad = tonumber(ocupacion.Capacidad) or 0
				datos.Total = tonumber(ocupacion.Total) or (#ocupacion.Sentados + #ocupacion.DePie)
				datos.Sub = "Asistencia"
				datos.Origen = "Jornada"
				datos.Final = final == true
				datos.SessionId = sesion.SessionId
				self:_Enviar(docente, "Aula", copiaSegura(datos))
			end
		end
	end
end

-- Asistencia de un aula: la de la clase en curso o, si no hay, la de la última clase de la jornada.
function SchoolDayService:Asistencia(roomId)
	local clase = self.ClaseActual
	if not clase or not clase.PorAula[roomId] then
		local encontrada = nil
		local jornada = self.Jornada
		if jornada then
			for i = #jornada.Orden, 1, -1 do
				local candidata = jornada.Clases[jornada.Orden[i]]
				if candidata and candidata.PorAula[roomId] then
					encontrada = candidata
					break
				end
			end
		end
		clase = encontrada or self.ClaseActual
	end
	if not clase then
		return {
			RoomId = roomId, NombreAula = nombreAula(roomId), Activa = false, Lista = {}, Resumen = resumenVacio(),
		}
	end
	return self:_DatosAsistenciaAula(clase, roomId)
end

-- Estado de asistencia del jugador en la clase en curso (o nil).
function SchoolDayService:AsistenciaDe(player)
	local clase = self.ClaseActual
	if not clase or not esJugador(player) then
		return nil
	end
	local reg = clase.PorJugador[player.UserId]
	if not reg then
		return nil
	end
	return {
		Clase = clase.Estado, Materia = clase.Materia, MateriaNombre = clase.MateriaNombre,
		RoomId = reg.RoomId, NombreAula = nombreAula(reg.RoomId), Estado = reg.Estado, Fase = clase.Fase,
	}
end

-- Estadísticas de la jornada actual para el panel del Director: asistencias por aula y por clase,
-- asignados y docente actual de cada aula, y resúmenes de jornadas anteriores.
function SchoolDayService:Estadisticas()
	local jornada = self.Jornada
	local porAula = {}
	local filas = {}
	local ordenActiva = {}
	for i, id in ipairs(self.AulasActivas) do
		ordenActiva[id] = i
	end
	local function fila(roomId)
		local f = porAula[roomId]
		if not f then
			f = {
				RoomId = roomId, Nombre = nombreAula(roomId), Activa = ordenActiva[roomId] ~= nil,
				Asignados = 0, Asientos = self:_Asientos(roomId),
				Presentes = 0, Tardanzas = 0, Ausentes = 0, Pendientes = 0, Clases = {},
			}
			porAula[roomId] = f
			table.insert(filas, f)
		end
		return f
	end
	for _, id in ipairs(self.AulasActivas) do
		fila(id)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local salon = self:AulaDe(player)
		if salon then
			if self:_EsEstudiante(player) then
				local f = fila(salon)
				f.Asignados = f.Asignados + 1
			elseif self:_EsDocente(player) then
				local f = fila(salon)
				if f.Docente == nil then
					f.Docente = nombreJugador(player)
					f.DocenteUserId = player.UserId
				end
			end
		end
	end

	local clases = {}
	local totales = resumenVacio()
	if jornada then
		for _, estado in ipairs(jornada.Orden) do
			local clase = jornada.Clases[estado]
			if clase then
				local resumenClase = {
					Clase = estado, Nombre = clase.Nombre, Materia = clase.Materia, MateriaNombre = clase.MateriaNombre,
					Fase = clase.Fase, Activa = not clase.Cerrada, Presentes = 0, Tardanzas = 0, Ausentes = 0, Pendientes = 0,
				}
				for roomId, registros in pairs(clase.PorAula) do
					local f = fila(roomId)
					local r = resumenVacio()
					for _, reg in pairs(registros) do
						local clave = CLAVE_RESUMEN[reg.Estado]
						if clave then
							r[clave] = r[clave] + 1
							f[clave] = f[clave] + 1
							resumenClase[clave] = resumenClase[clave] + 1
							totales[clave] = totales[clave] + 1
						end
					end
					table.insert(f.Clases, {
						Clase = estado, Materia = clase.Materia,
						Presentes = r.Presentes, Tardanzas = r.Tardanzas, Ausentes = r.Ausentes, Pendientes = r.Pendientes,
					})
				end
				table.insert(clases, resumenClase)
			end
		end
	end

	table.sort(filas, function(a, b)
		local oa, ob = ordenActiva[a.RoomId], ordenActiva[b.RoomId]
		if oa and ob then
			return oa < ob
		end
		if oa or ob then
			return oa ~= nil
		end
		return a.RoomId < b.RoomId
	end)

	return {
		Jornada = self.NumeroJornada,
		Finalizada = jornada ~= nil and jornada.Finalizada == true,
		Inicio = jornada and jornada.Inicio or nil,
		Fin = jornada and jornada.Fin or nil,
		Estado = self.EstadoActual,
		NombreEstado = TimetableDefinitions.Nombre(self.EstadoActual),
		Modo = self.Modo,
		Pausada = self.Pausada,
		EnEspera = self.EnEspera,
		MaxPorAula = self.MaxPorAula,
		Totales = { Presentes = totales.Presentes, Tardanzas = totales.Tardanzas, Ausentes = totales.Ausentes, Pendientes = totales.Pendientes },
		Aulas = filas,
		Clases = clases,
		Anteriores = copiaSegura(self.Historial),
		Generado = os.time(),
	}
end

---------------------------------------------------------------------------------------------------
-- Jugadores
---------------------------------------------------------------------------------------------------
function SchoolDayService:_AlEntrar(player)
	if not esJugador(player) then
		return
	end
	if self.Pausada and self.MotivoPausa == "sin_jugadores" then
		self:_Reanudar("jugadores", nil, true)
	end
	self:_EnviarSnapshotA(player)
	task.delay(self.RepetirSnapshotEntradaSeg, function()
		if player.Parent ~= nil then
			self:_EnviarSnapshotA(player)
		end
	end)
end

function SchoolDayService:_AlSalir(player)
	if not esJugador(player) then
		return
	end
	local salon = self:AulaDe(player)
	if salon and self:_EsEstudiante(player) then
		self.UltimaAula[player.UserId] = salon
	end
	if self.PausarSinJugadores and not self.Pausada and not self.EnEspera then
		local quedan = 0
		for _, otro in ipairs(Players:GetPlayers()) do
			if otro ~= player then
				quedan = quedan + 1
			end
		end
		if quedan == 0 then
			self:_Pausar("sin_jugadores", nil, true)
		end
	end
end

-- RoleService ya resolvió el aula en Asignar; aquí solo se corrige lo que haya quedado incoherente.
function SchoolDayService:_AlCambiarCargo(player, cargo, _anterior)
	if not esJugador(player) or player.Parent == nil then
		return
	end
	local salon = self:AulaDe(player)
	if cargo == CARGO_ESTUDIANTE then
		if not salon then
			local aula = self:AsignarAula(player, nil)
			if aula then
				self:_Notificar(player, "Tu salón asignado: " .. nombreAula(aula), "info", 5)
			end
		end
	elseif RoleDefinitions.EsDocente(cargo) then
		if not salon and self:_EsDocenteDeAula(cargo) then
			local aula = self:AsignarAula(player, nil)
			if aula then
				self:_Notificar(player, "Tu aula de clase: " .. nombreAula(aula), "info", 5)
			end
		end
	elseif salon then
		self:LiberarAula(player)
	end
end

---------------------------------------------------------------------------------------------------
-- Remotos: JornadaControl, StateSnapshot y SettingsUpdate
---------------------------------------------------------------------------------------------------
function SchoolDayService:_RegistrarRemotos()
	local RemoteService = self:_Servicio("RemoteService")
	if not RemoteService or typeof(RemoteService.Registrar) ~= "function" then
		warn(PREFIJO .. " RemoteService no disponible: JornadaControl, StateSnapshot y SettingsUpdate no tendrán handler.")
		return
	end
	RemoteService:Registrar("JornadaControl", function(player, datos)
		return self:_ManejarControl(player, datos)
	end)
	RemoteService:Registrar("StateSnapshot", function(player, datos)
		return self:_ManejarSnapshot(player, datos)
	end)
	-- SettingsUpdate lo registra DataService (arranca antes); este respaldo solo se activa si nadie lo registró.
	local yaRegistrado = false
	if typeof(RemoteService.TieneHandler) == "function" then
		local ok, tiene = pcall(RemoteService.TieneHandler, RemoteService, "SettingsUpdate")
		yaRegistrado = ok and tiene == true
	end
	if not yaRegistrado then
		RemoteService:Registrar("SettingsUpdate", function(player, datos)
			return self:_ManejarAjustes(player, datos)
		end)
	end
end

function SchoolDayService:_RechazoControl(player, accion, motivo)
	self:_Auditar("Remoto", player, "JornadaControl", "rechazo_logico: " .. tostring(accion) .. " · " .. tostring(motivo))
	local respuesta = RemoteContracts.Error(motivo or "rechazado")
	-- Los códigos con detalle ("duracion_invalida:ESPERA") usan el texto de su prefijo.
	local codigo = tostring(motivo or "rechazado")
	local base = string.match(codigo, "^([%w_]+):") or codigo
	respuesta.datos = {
		Accion = accion,
		Mensaje = self.TextosError[codigo] or self.TextosError[base] or codigo,
		Jornada = self:Snapshot(),
	}
	return respuesta
end

function SchoolDayService:_ManejarControl(player, datos)
	local accion = datos.Accion
	if typeof(accion) ~= "string" or not ACCIONES_CONTROL[accion] then
		return self:_RechazoControl(player, tostring(accion), "accion_desconocida")
	end
	-- Defensa en profundidad: RemoteService ya comprobó jornada.control.
	local okPermiso, tiene = self:_Llamar("RoleService", "Tiene", player, "jornada.control")
	if okPermiso and tiene ~= true then
		return self:_RechazoControl(player, accion, "sin_permiso")
	end
	local ok, resultado
	if accion == "Iniciar" then
		ok, resultado = self:Iniciar(player)
	elseif accion == "Pausar" then
		ok, resultado = self:Pausar(player)
	elseif accion == "Reanudar" then
		ok, resultado = self:Reanudar(player)
	elseif accion == "Saltar" then
		ok, resultado = self:Saltar(player)
	elseif accion == "Reiniciar" then
		ok, resultado = self:Reiniciar(player)
	else
		if typeof(datos.Datos) ~= "table" then
			return self:_RechazoControl(player, accion, "datos_requeridos")
		end
		ok, resultado = self:Configurar(datos.Datos, player)
	end
	if not ok then
		return self:_RechazoControl(player, accion, resultado)
	end
	return RemoteContracts.Ok({
		Accion = accion,
		Resultado = copiaSegura(resultado),
		Jornada = self:Snapshot(),
		Configuracion = self:ConfiguracionActual(),
	})
end

function SchoolDayService:_RolDe(player)
	local rol = {
		Cargo = player:GetAttribute("Cargo"),
		Equipo = player:GetAttribute("Equipo"),
		Salon = self:AulaDe(player),
	}
	local ok, datos = self:_Llamar("RoleService", "DatosRol", player)
	if ok and typeof(datos) == "table" then
		for _, clave in ipairs({ "Nombre", "Abrev", "Descripcion", "Permisos", "EsDocente" }) do
			if datos[clave] ~= nil then
				rol[clave] = copiaSegura(datos[clave])
			end
		end
		if rol.Cargo == nil then
			rol.Cargo = datos.Cargo
		end
		if rol.Equipo == nil then
			rol.Equipo = datos.Equipo
		end
	end
	if rol.Salon then
		rol.SalonNombre = nombreAula(rol.Salon)
	end
	return rol
end

function SchoolDayService:_AjustesDe(player)
	local ok, perfil = self:_Llamar("DataService", "Obtener", player)
	if not ok or typeof(perfil) ~= "table" then
		ok, perfil = self:_Llamar("DataService", "EsperarPerfil", player, self.EsperaPerfilSnapshotSeg)
	end
	if ok and typeof(perfil) == "table" and typeof(perfil.Ajustes) == "table" then
		return copiaSegura(perfil.Ajustes)
	end
	return nil
end

-- Snapshot completo para el cliente: cada parte en pcall y solo si su servicio existe.
function SchoolDayService:_ManejarSnapshot(player, _datos)
	local resultado = {
		Jornada = self:Snapshot(),
		Rol = self:_RolDe(player),
		Version = tostring(Config.Version or ""),
		HoraServidor = ahora(),
	}
	local ajustes = self:_AjustesDe(player)
	if ajustes then
		resultado.Ajustes = ajustes
	end
	local function agregar(clave, servicio, metodo, ...)
		local ok, valor = self:_Llamar(servicio, metodo, ...)
		if ok and valor ~= nil then
			local copia = copiaSegura(valor)
			if copia ~= nil then
				resultado[clave] = copia
			end
		end
	end
	agregar("Economia", "EconomyService", "Snapshot", player)
	if resultado.Economia == nil then
		local okSaldo, saldo = self:_Llamar("EconomyService", "Saldo", player)
		if okSaldo and esFinito(saldo) then
			resultado.Economia = { Saldo = saldo }
		end
	end
	agregar("Aula", "ClassroomService", "Snapshot", player)
	agregar("Anuncios", "AnnouncementService", "Ultimos")
	if resultado.Anuncios == nil then
		agregar("Anuncios", "AnnouncementService", "Historial")
	end
	agregar("Comida", "FoodService", "Snapshot")
	agregar("Cafeteria", "CafeteriaService", "Snapshot")
	agregar("Futbol", "FootballService", "Estado")
	agregar("Personal", "StaffService", "Snapshot", player)
	local asistencia = self:AsistenciaDe(player)
	if asistencia then
		resultado.Asistencia = asistencia
	end
	self:_AgregarPartesAportadas(player, resultado)
	-- La hora del servidor se toma al final para que el cliente sincronice con el valor más reciente.
	resultado.HoraServidor = ahora()
	return RemoteContracts.Ok(resultado)
end

-- Este handler sustituye al StateSnapshot por defecto de RemoteService; para no perder lo que otros
-- servicios aportan con RemoteService:AportarSnapshot (Puertas, Futbol...), se añaden aquí esas partes
-- (sobrescriben, igual que en el snapshot por defecto). Jornada, Rol, Version y HoraServidor no se sustituyen.
local CLAVES_PROPIAS_SNAPSHOT = { Jornada = true, Rol = true, Version = true, HoraServidor = true }

function SchoolDayService:_AgregarPartesAportadas(player, resultado)
	local RemoteService = self:_Servicio("RemoteService")
	local partes = RemoteService and RemoteService.PartesSnapshot
	if typeof(partes) ~= "table" then
		return
	end
	for clave, fn in pairs(partes) do
		if typeof(clave) == "string" and typeof(fn) == "function" and not CLAVES_PROPIAS_SNAPSHOT[clave] then
			local ok, valor = pcall(fn, player)
			if ok then
				if valor ~= nil then
					local copia = copiaSegura(valor)
					if copia ~= nil then
						resultado[clave] = copia
					end
				end
			else
				self:_Avisar("snapshot_parte:" .. clave, valor)
			end
		end
	end
end

-- SettingsUpdate (RemoteEvent): RemoteService ya validó el esquema estricto; aquí se sanea cada clave
-- conocida de Perfil.Ajustes (tipo y rango) y se marca el perfil para guardarlo.
function SchoolDayService:_ManejarAjustes(player, datos)
	local ajustes = datos and datos.Ajustes
	if typeof(ajustes) ~= "table" then
		self:_Auditar("Remoto", player, "SettingsUpdate", "rechazo_logico: ajustes_invalidos")
		return RemoteContracts.Error("ajustes_invalidos")
	end
	local ok, perfil = self:_Llamar("DataService", "Obtener", player)
	if not ok or typeof(perfil) ~= "table" then
		return RemoteContracts.Error("perfil_no_cargado")
	end
	if typeof(perfil.Ajustes) ~= "table" then
		perfil.Ajustes = {}
	end
	local campos = (RemoteContracts.EsquemaAjustes and RemoteContracts.EsquemaAjustes.campos) or {}
	local cambiados, descartados = 0, 0
	for _, clave in ipairs(RemoteContracts.ClavesAjustes or {}) do
		local valor = ajustes[clave]
		local descriptor = campos[clave]
		if valor ~= nil and descriptor then
			local okValor = Validate.ComprobarValor(descriptor, valor, clave)
			if okValor then
				valor = normalizarAjuste(clave, valor)
				if perfil.Ajustes[clave] ~= valor then
					perfil.Ajustes[clave] = valor
					cambiados = cambiados + 1
				end
			else
				descartados = descartados + 1
			end
		end
	end
	for clave in pairs(ajustes) do
		if typeof(clave) ~= "string" or campos[clave] == nil then
			descartados = descartados + 1
		end
	end
	if cambiados > 0 then
		self:_Llamar("DataService", "Marcar", player)
	end
	if descartados > 0 then
		self:_Auditar("Remoto", player, "SettingsUpdate", "rechazo_logico: " .. descartados .. " valores descartados")
	end
	return RemoteContracts.Ok({ Cambiados = cambiados, Descartados = descartados, Ajustes = copiaSegura(perfil.Ajustes) })
end

return SchoolDayService
