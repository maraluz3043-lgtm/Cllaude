--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Services.StaffService
	Tipo: ModuleScript
	Funciones del personal del colegio (docs/ARQUITECTURA.md §6). Registra el handler del remoto StaffAction y
	despacha por Datos.Accion validando permisos (RoleService:Tiene), esquema de cada acción, estado y
	cooldowns: métricas de cliente, panel de dirección y eventos escolares, coordinación académica (horario,
	aulas, sesiones, conflictos), convivencia (avisos/notas/citaciones RP y mediaciones), orientación (agenda
	de citas y recursos de bienestar), enfermería (atención con aforo y botiquín ficticio), secretaría
	(matrícula RP, certificados, asistencia), finanzas (presupuesto virtual, auditoría, precios), recepción y
	seguridad (visitas, incidencias, portón) y limpieza (tareas temporales con ProximityPrompt en DESCANSO y
	ALMUERZO). Todo el estado vive en memoria del servidor; los textos de jugadores se filtran con TextService.
	Emite EventoCliente "Personal" { Sub = "Atendido" | "Tareas" | "Cita" | "Evento" | "Visita" | ... }.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local TimetableDefinitions = require(Shared:WaitForChild("TimetableDefinitions"))
local RemoteContracts = require(Shared:WaitForChild("RemoteContracts"))
local MapaLogico = require(Shared:WaitForChild("MapaLogico"))
local Validate = require(Util:WaitForChild("Validate"))
local Zones = require(Util:WaitForChild("Zones"))
local Format = require(Util:WaitForChild("Format"))

-- Catalogs es opcional para este servicio (tareas de limpieza y recursos de bienestar tienen respaldo propio).
local Catalogs = {}
do
	local ok, modulo = pcall(function()
		return require(Shared:WaitForChild("Catalogs", 10))
	end)
	if ok and typeof(modulo) == "table" then
		Catalogs = modulo
	end
end

local StaffService = {}
StaffService.Nombre = "StaffService"

local PREFIJO = "[ColegioRP][StaffService]"

---------------------------------------------------------------------------------------------------
-- Parámetros
---------------------------------------------------------------------------------------------------
local CONFIG_ENFERMERIA = Config.Enfermeria or {}
local CONFIG_LIMPIEZA = Config.Limpieza or {}
local CONFIG_CAFETERIA = Config.Cafeteria or {}
local RECOMPENSAS = (Config.Economia and Config.Economia.Recompensas) or {}

StaffService.AforoEnfermeria = tonumber(CONFIG_ENFERMERIA.AforoMax) or 4 -- Pacientes "Atendido" simultáneos.
StaffService.DuracionAtendidoSeg = tonumber(CONFIG_ENFERMERIA.DuracionAtendidoSeg) or 120 -- Duración del atributo Atendido.
StaffService.DistanciaAtender = 10 -- Studs máximos entre enfermero/a y paciente (salvo ambos en la zona de enfermería).
StaffService.ZonaEnfermeria = "ENTRADA" -- El mapa no tiene enfermería propia: se atiende en la entrada.
StaffService.MaxTareas = tonumber(CONFIG_LIMPIEZA.MaxSimultaneas) or 6 -- Tareas de limpieza visibles a la vez.
StaffService.MaxTareasJugador = tonumber(CONFIG_LIMPIEZA.MaxPorJugadorPorPeriodo) or 3 -- Por jugador y periodo.
StaffService.TareasPorPeriodo = StaffService.MaxTareas * 2 -- Tareas generadas como máximo por periodo (incluye reposiciones).
StaffService.HoldLimpiezaSeg = 2 -- HoldDuration del ProximityPrompt "Limpiar".
StaffService.DistanciaPromptLimpieza = 8 -- MaxActivationDistance del prompt.
StaffService.ReposicionTareaSeg = 20 -- Espera antes de reponer una tarea completada (si sigue el periodo).
StaffService.SeparacionTareas = 6 -- Distancia mínima entre dos marcadores de limpieza.
StaffService.RecompensaLimpieza = tonumber(RECOMPENSAS.TareaLimpieza) or 8
StaffService.DuracionEventoSeg = 600 -- Duración del flag EventoActivo (10 min).
StaffService.DuracionMinPeriodo = 15 -- Límites de EditarHorario (segundos reales por periodo).
StaffService.DuracionMaxPeriodo = 900
StaffService.PresupuestoInicial = 1500 -- Presupuesto virtual del colegio (monedas escolares ficticias).
StaffService.MaxVisitas = 50
StaffService.MaxCitas = 40
StaffService.MaxCertificados = 60
StaffService.MaxMediaciones = 30
StaffService.MaxCasosPorJugador = 10
StaffService.PuertaPorton = "Porton_Principal"
StaffService.TagTarea = "ColegioRP_TareaLimpieza" -- Tag de los marcadores (el cliente oculta el prompt a quien no limpia).

local NOMBRE_CARPETA_MAPA = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"
local MAX_USER_ID = RemoteContracts.MaxUserId or 9007199254740991
local PERIODOS_LIMPIEZA = { DESCANSO = true, ALMUERZO = true }
local ZONAS_LIMPIEZA_RESPALDO = { "PATIO_CENTRAL", "COMEDOR", "BANOS_1", "BANOS_2", "CANCHA" }

-- Eventos escolares que puede activar la dirección (eventos.activar).
StaffService.Eventos = {
	Deporte = { Nombre = "Jornada deportiva", Zona = "CANCHA", Texto = "¡Evento deportivo! La cancha queda abierta para partidos durante 10 minutos." },
	Recreo = { Nombre = "Recreo especial", Zona = "PATIO_CENTRAL", Texto = "Recreo especial: tiempo libre en los patios durante 10 minutos." },
	Asamblea = { Nombre = "Asamblea general", Zona = "AUDITORIO", Texto = "Asamblea general: todo el colegio se reúne en el auditorio." },
}
StaffService.OrdenEventos = { "Deporte", "Recreo", "Asamblea" }

-- Escala de convivencia por jornada (nunca castigos automáticos permanentes).
StaffService.NivelesConvivencia = {
	{ Id = "Aviso", Nombre = "Aviso verbal", Texto = "Has recibido un aviso de convivencia." },
	{ Id = "Nota", Nombre = "Nota de convivencia", Texto = "Se ha registrado una nota de convivencia." },
	{ Id = "Citacion", Nombre = "Citación", Texto = "Has sido citado/a a la coordinación de convivencia." },
}

-- Recursos de bienestar de respaldo (no clínicos) si Catalogs no define RecursosBienestar.
StaffService.RecursosBienestar = {
	{ Titulo = "Pausa y respiración", Texto = "Tómate un momento: respira despacio contando hasta cuatro al inhalar y otra vez al exhalar. Una pausa breve ayuda a concentrarse." },
	{ Titulo = "Organiza tu día", Texto = "Divide las tareas en pasos pequeños y decide cuál harás primero. Terminar algo pequeño da impulso para lo siguiente." },
	{ Titulo = "Convivir con respeto", Texto = "Escuchar con atención y hablar con calma ayuda a resolver desacuerdos. Si algo te molesta, cuéntaselo a un adulto del colegio." },
	{ Titulo = "Pide ayuda", Texto = "Hablar con alguien de confianza (tutor, orientación o tu familia) siempre es una buena opción. Nadie tiene que resolverlo todo solo." },
}

-- Botiquín ficticio de enfermería (nombres neutros; nunca se describen lesiones).
StaffService.InsumosBotiquin = {
	{ Id = "TIRITAS", Nombre = "Tiritas", Max = 20 },
	{ Id = "GASAS", Nombre = "Gasas estériles", Max = 15 },
	{ Id = "COMPRESAS", Nombre = "Compresas frías", Max = 10 },
	{ Id = "GEL", Nombre = "Gel antibacterial", Max = 12 },
	{ Id = "AGUA", Nombre = "Botellas de agua", Max = 24 },
	{ Id = "GUANTES", Nombre = "Guantes desechables", Max = 30 },
}
StaffService.CosteReposicionBotiquin = 30 -- Gasto ficticio que se anota en el presupuesto al reponer.

-- Conceptos de gasto ficticio del presupuesto escolar (precio por unidad).
StaffService.ConceptosGasto = {
	{ Id = "LIMPIEZA", Nombre = "Insumos de limpieza", Precio = 40 },
	{ Id = "PAPELERIA", Nombre = "Papelería y material escolar", Precio = 60 },
	{ Id = "COCINA", Nombre = "Insumos de cocina", Precio = 80 },
	{ Id = "BOTIQUIN", Nombre = "Reposición del botiquín", Precio = 30 },
	{ Id = "MANTENIMIENTO", Nombre = "Mantenimiento de instalaciones", Precio = 100 },
	{ Id = "DEPORTE", Nombre = "Material deportivo", Precio = 50 },
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function esJugador(valor)
	return typeof(valor) == "Instance" and valor:IsA("Player")
end

local function nombreDe(player)
	if not esJugador(player) then
		return "—"
	end
	local ok, nombre = pcall(function()
		return player.DisplayName
	end)
	if ok and typeof(nombre) == "string" and nombre ~= "" then
		return nombre
	end
	return player.Name
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

local function jugadorPorId(userId)
	if typeof(userId) ~= "number" or userId ~= userId then
		return nil
	end
	local ok, player = pcall(Players.GetPlayerByUserId, Players, userId)
	if ok and esJugador(player) then
		return player
	end
	return nil
end

-- Nombre mostrado de un userId conectado; nunca datos de jugadores desconectados.
local function nombreDeId(userId)
	local player = jugadorPorId(tonumber(userId))
	if player then
		return nombreDe(player)
	end
	return "Jugador desconectado"
end

local function ahoraServidor()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(t) == "number" then
		return t
	end
	return os.time()
end

local function copiar(tabla)
	local copia = {}
	if typeof(tabla) == "table" then
		for clave, valor in pairs(tabla) do
			copia[clave] = valor
		end
	end
	return copia
end

local function contar(tabla)
	local n = 0
	if typeof(tabla) == "table" then
		for _ in pairs(tabla) do
			n = n + 1
		end
	end
	return n
end

local function limitarLista(lista, maximo)
	while #lista > maximo do
		table.remove(lista, 1)
	end
end

local function barajar(lista)
	for i = #lista, 2, -1 do
		local j = math.random(1, i)
		lista[i], lista[j] = lista[j], lista[i]
	end
	return lista
end

local function finito(n)
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Segundos del día a partir de un número o de "HH:MM".
local function segundosHora(valor)
	if finito(valor) then
		return valor
	end
	if typeof(valor) == "string" then
		return Format.SegundosDeHHMM(valor)
	end
	return nil
end

local function nombreZona(id)
	local zona = Zones.Zona(id)
	if zona and typeof(zona.Nombre) == "string" then
		return zona.Nombre
	end
	return tostring(id or "—")
end

local function esAula(id)
	return typeof(id) == "string" and Zones.EsAula(id)
end

-- Quita caracteres de control, espacios sobrantes y recorta a 'maximo' caracteres.
local function limpiarTexto(texto, maximo)
	if typeof(texto) ~= "string" then
		return ""
	end
	local limpio = string.gsub(texto, "[%c]", " ")
	limpio = string.gsub(limpio, "%s+", " ")
	limpio = Format.Recortar(limpio)
	if maximo then
		limpio = Format.Truncar(limpio, maximo)
	end
	return limpio
end

local function exito(datos)
	return { ok = true, datos = datos or {} }
end

local function fallo(mensaje)
	return { ok = false, error = tostring(mensaje or "No se pudo completar la acción.") }
end

-- Convierte cualquier valor en algo seguro y serializable para un RemoteFunction: sin funciones ni
-- instancias (un Player se convierte en su nombre mostrado), tablas acotadas en tamaño y profundidad y
-- sin claves mixtas (las tablas que no son listas continuas pasan a claves de texto).
local function paraCliente(valor, profundidad, presupuesto)
	profundidad = profundidad or 1
	presupuesto = presupuesto or { n = 0 }
	presupuesto.n = presupuesto.n + 1
	if presupuesto.n > 1500 then
		return nil
	end
	local tipo = typeof(valor)
	if tipo == "string" then
		return Format.Truncar(valor, 300)
	elseif tipo == "number" then
		if finito(valor) then
			return valor
		end
		return nil
	elseif tipo == "boolean" or tipo == "Vector3" or tipo == "Vector2" or tipo == "Color3" then
		return valor
	elseif tipo == "EnumItem" then
		return tostring(valor)
	elseif tipo == "Instance" then
		if valor:IsA("Player") then
			return nombreDe(valor)
		end
		return valor.Name
	elseif tipo == "table" then
		if profundidad > 6 then
			return nil
		end
		local n = #valor
		local total = 0
		for _ in pairs(valor) do
			total = total + 1
		end
		local salida = {}
		if n > 0 and total == n then
			for i = 1, math.min(n, 120) do
				local limpio = paraCliente(valor[i], profundidad + 1, presupuesto)
				if limpio == nil then
					limpio = "—"
				end
				salida[i] = limpio
			end
			return salida
		end
		local cantidad = 0
		for clave, v in pairs(valor) do
			local tipoClave = typeof(clave)
			if (tipoClave == "string" or tipoClave == "number") and cantidad < 120 then
				local limpio = paraCliente(v, profundidad + 1, presupuesto)
				if limpio ~= nil then
					salida[Format.Truncar(tostring(clave), 48)] = limpio
					cantidad = cantidad + 1
				end
			end
		end
		return salida
	end
	return nil
end
StaffService.ParaCliente = paraCliente

---------------------------------------------------------------------------------------------------
-- Esquemas de Datos por acción (estrictos: claves desconocidas se rechazan)
---------------------------------------------------------------------------------------------------
local Esq = Validate.Esquema
local Str, Int, Num, Bool, EnumV, Array, TablaLibre = Validate.Str, Validate.Int, Validate.Num, Validate.Bool, Validate.Enum, Validate.Array, Validate.TablaLibre
local function IdJugador(opcional)
	return Int(1, MAX_USER_ID, opcional)
end

local ESQ_VACIO = Esq({})
local ESQ_OBJETIVO = Esq({ ObjetivoUserId = IdJugador(false) })
local ESQ_EVENTO = Esq({ Tipo = EnumV(StaffService.OrdenEventos) })
local ESQ_APROBAR = Esq({ Aprobar = Bool(true), Id = Int(1, 1000000, true) })
local ESQ_EDITAR_HORARIO = Esq({ Duraciones = TablaLibre(true), Materias = TablaLibre(true), Aplicar = Bool(true) })
local ESQ_ASIGNAR_AULA = Esq({ ObjetivoUserId = IdJugador(false), RoomId = Str(16, false, 1) })
local ESQ_RESOLVER = Esq({ ObjetivoUserId = IdJugador(false), RoomId = Str(16, true, 1) })
local ESQ_CONVIVENCIA = Esq({ ObjetivoUserId = IdJugador(false), Motivo = Str(120, false, 3) })
local ESQ_MEDIACION = Esq({ Participantes = Array(IdJugador(false), 4), Nota = Str(160, true) })
local ESQ_CITA = Esq({
	Sub = EnumV({ "Crear", "Listar", "Cancelar", "Completar" }),
	ObjetivoUserId = IdJugador(true),
	Motivo = Str(120, true),
	Hora = Str(5, true),
	CitaId = Int(1, 1000000, true),
})
local ESQ_BOTIQUIN = Esq({ Sub = EnumV({ "Ver", "Usar", "Reponer" }, true), InsumoId = Str(24, true) })
local ESQ_MATRICULAR = Esq({ ObjetivoUserId = IdJugador(false), RoomId = Str(16, true, 1) })
local ESQ_CERTIFICADO = Esq({ Sub = EnumV({ "Listar", "Emitir" }, true), ObjetivoUserId = IdJugador(true) })
local ESQ_ASISTENCIA = Esq({ RoomId = Str(16, false, 1) })
local ESQ_PRESUPUESTO = Esq({ Sub = EnumV({ "Ver", "Gasto" }, true), Concepto = Str(24, true), Cantidad = Int(1, 10, true) })
local ESQ_PRECIO = Esq({ Sub = EnumV({ "Ver", "Fijar" }, true), ProductoId = Str(24, true), Precio = Num(0, 100000, true) })
local ESQ_VISITA = Esq({ ObjetivoUserId = IdJugador(false), Motivo = Str(80, false, 3) })
local ESQ_INCIDENCIA = Esq({ Descripcion = Str(160, false, 3), ObjetivoUserId = IdJugador(true) })
local ESQ_PORTON = Esq({ Bloquear = Bool(true) })
local ESQ_TAREA = Esq({ TareaId = Str(64, true) })

-- Tabla de acciones: Metodo, PermisoContrato (para RemoteContracts.PermisosStaff: clave | false),
-- Permisos (lista: basta con uno; nil = cualquier jugador), Esquema, Cooldown (s, tras éxito), Fijos (alias).
StaffService.Acciones = {
	-- Cualquier jugador
	Metrica = { Metodo = "AccionMetrica", PermisoContrato = false },
	MiEstado = { Metodo = "AccionMiEstado", PermisoContrato = false, Esquema = ESQ_VACIO },

	-- Dirección
	PanelDirector = { Metodo = "AccionPanelDirector", PermisoContrato = "auditoria.ver", Permisos = { "auditoria.ver" }, Esquema = ESQ_VACIO },
	Informe = { Metodo = "AccionInforme", PermisoContrato = "auditoria.ver", Permisos = { "auditoria.ver" }, Esquema = ESQ_VACIO },
	Auditoria = { Metodo = "AccionAuditoria", PermisoContrato = "auditoria.ver", Permisos = { "auditoria.ver" }, Esquema = ESQ_VACIO },
	Personal = { Metodo = "AccionPersonal", PermisoContrato = "cargos.asignar", Permisos = { "cargos.asignar", "auditoria.ver" }, Esquema = ESQ_VACIO },
	ActivarEvento = { Metodo = "AccionActivarEvento", PermisoContrato = "eventos.activar", Permisos = { "eventos.activar" }, Esquema = ESQ_EVENTO, Cooldown = 20 },
	Evento = { Metodo = "AccionActivarEvento", PermisoContrato = "eventos.activar", Permisos = { "eventos.activar" }, Esquema = ESQ_EVENTO, Cooldown = 20 },
	DesactivarEvento = { Metodo = "AccionDesactivarEvento", PermisoContrato = "eventos.activar", Permisos = { "eventos.activar" }, Esquema = ESQ_VACIO },
	AprobarHorario = { Metodo = "AccionAprobarHorario", PermisoContrato = "jornada.control", Permisos = { "jornada.control" }, Esquema = ESQ_APROBAR },

	-- Coordinación académica
	EditarHorario = { Metodo = "AccionEditarHorario", PermisoContrato = "horario.editar", Permisos = { "horario.editar" }, Esquema = ESQ_EDITAR_HORARIO, Cooldown = 3 },
	HorarioActual = { Metodo = "AccionHorarioActual", PermisoContrato = "horario.editar", Permisos = { "horario.editar" }, Esquema = ESQ_VACIO },
	Horario = { Metodo = "AccionHorarioActual", PermisoContrato = "horario.editar", Permisos = { "horario.editar" }, Esquema = ESQ_VACIO },
	AsignarAulaA = { Metodo = "AccionAsignarAula", PermisoContrato = "horario.editar", Permisos = { "horario.editar" }, Esquema = ESQ_ASIGNAR_AULA },
	VerSesiones = { Metodo = "AccionVerSesiones", PermisoContrato = "horario.editar", Permisos = { "horario.editar" }, Esquema = ESQ_VACIO },
	ResolverConflicto = { Metodo = "AccionResolverConflicto", PermisoContrato = "horario.editar", Permisos = { "horario.editar" }, Esquema = ESQ_RESOLVER },

	-- Convivencia
	ReporteConvivencia = { Metodo = "AccionReporteConvivencia", PermisoContrato = "convivencia.gestionar", Permisos = { "convivencia.gestionar" }, Esquema = ESQ_CONVIVENCIA },
	CasoConvivencia = { Metodo = "AccionReporteConvivencia", PermisoContrato = "convivencia.gestionar", Permisos = { "convivencia.gestionar" }, Esquema = ESQ_CONVIVENCIA },
	Mediacion = { Metodo = "AccionMediacion", PermisoContrato = "convivencia.gestionar", Permisos = { "convivencia.gestionar" }, Esquema = ESQ_MEDIACION, Cooldown = 10 },
	VerReportes = { Metodo = "AccionVerReportes", PermisoContrato = false, Permisos = { "reportes.ver", "convivencia.gestionar" }, Esquema = ESQ_VACIO },
	ListaCasos = { Metodo = "AccionVerReportes", PermisoContrato = "convivencia.gestionar", Permisos = { "convivencia.gestionar" }, Esquema = ESQ_VACIO },

	-- Orientación
	Cita = { Metodo = "AccionCita", PermisoContrato = "orientacion.agenda", Permisos = { "orientacion.agenda" }, Esquema = ESQ_CITA },
	Agenda = { Metodo = "AccionCita", PermisoContrato = "orientacion.agenda", Permisos = { "orientacion.agenda" }, Esquema = ESQ_CITA, Fijos = { Sub = "Listar" } },
	AgendarCita = { Metodo = "AccionCita", PermisoContrato = "orientacion.agenda", Permisos = { "orientacion.agenda" }, Esquema = ESQ_CITA, Fijos = { Sub = "Crear" } },
	CancelarCita = { Metodo = "AccionCita", PermisoContrato = "orientacion.agenda", Permisos = { "orientacion.agenda" }, Esquema = ESQ_CITA, Fijos = { Sub = "Cancelar" } },
	RecursosBienestar = { Metodo = "AccionRecursos", PermisoContrato = "orientacion.agenda", Permisos = { "orientacion.agenda" }, Esquema = ESQ_VACIO },

	-- Enfermería
	Atender = { Metodo = "AccionAtender", PermisoContrato = "enfermeria.atender", Permisos = { "enfermeria.atender" }, Esquema = ESQ_OBJETIVO },
	AltaAtendido = { Metodo = "AccionAlta", PermisoContrato = "enfermeria.atender", Permisos = { "enfermeria.atender" }, Esquema = ESQ_OBJETIVO },
	ListaAtendidos = { Metodo = "AccionListaAtendidos", PermisoContrato = "enfermeria.atender", Permisos = { "enfermeria.atender" }, Esquema = ESQ_VACIO },
	Botiquin = { Metodo = "AccionBotiquin", PermisoContrato = "enfermeria.atender", Permisos = { "enfermeria.atender" }, Esquema = ESQ_BOTIQUIN },

	-- Secretaría
	Matricular = { Metodo = "AccionMatricular", PermisoContrato = "secretaria.matricular", Permisos = { "secretaria.matricular" }, Esquema = ESQ_MATRICULAR, Cooldown = 2 },
	Certificado = { Metodo = "AccionCertificado", PermisoContrato = "secretaria.matricular", Permisos = { "secretaria.matricular" }, Esquema = ESQ_CERTIFICADO },
	Asistencia = { Metodo = "AccionAsistencia", PermisoContrato = "secretaria.matricular", Permisos = { "secretaria.matricular" }, Esquema = ESQ_ASISTENCIA },

	-- Finanzas
	Presupuesto = { Metodo = "AccionPresupuesto", PermisoContrato = "finanzas.presupuesto", Permisos = { "finanzas.presupuesto" }, Esquema = ESQ_PRESUPUESTO },
	AjustarPresupuesto = { Metodo = "AccionPresupuesto", PermisoContrato = "finanzas.presupuesto", Permisos = { "finanzas.presupuesto" }, Esquema = ESQ_PRESUPUESTO, Fijos = { Sub = "Gasto" } },
	AuditoriaEconomia = { Metodo = "AccionAuditoriaEconomia", PermisoContrato = "economia.auditar", Permisos = { "economia.auditar" }, Esquema = ESQ_VACIO },
	AuditoriaEconomica = { Metodo = "AccionAuditoriaEconomia", PermisoContrato = "economia.auditar", Permisos = { "economia.auditar" }, Esquema = ESQ_VACIO },
	PrecioCafeteria = { Metodo = "AccionPrecioCafeteria", PermisoContrato = "cafeteria.precios", Permisos = { "cafeteria.precios" }, Esquema = ESQ_PRECIO },

	-- Recepción y seguridad
	RegistrarVisita = { Metodo = "AccionRegistrarVisita", PermisoContrato = "seguridad.acceso", Permisos = { "seguridad.acceso" }, Esquema = ESQ_VISITA, Cooldown = 2 },
	ListaVisitas = { Metodo = "AccionListaVisitas", PermisoContrato = "seguridad.acceso", Permisos = { "seguridad.acceso" }, Esquema = ESQ_VACIO },
	Incidencia = { Metodo = "AccionIncidencia", PermisoContrato = "seguridad.acceso", Permisos = { "seguridad.acceso" }, Esquema = ESQ_INCIDENCIA, Cooldown = 20 },
	AvisoModeracion = { Metodo = "AccionIncidencia", PermisoContrato = "seguridad.acceso", Permisos = { "seguridad.acceso" }, Esquema = ESQ_INCIDENCIA, Cooldown = 20 },
	Porton = { Metodo = "AccionPorton", PermisoContrato = "seguridad.acceso", Permisos = { "seguridad.acceso" }, Esquema = ESQ_PORTON, Cooldown = 1 },

	-- Limpieza
	TareasPendientes = { Metodo = "AccionTareasPendientes", PermisoContrato = "limpieza.tareas", Permisos = { "limpieza.tareas" }, Esquema = ESQ_VACIO },
	TareasLimpieza = { Metodo = "AccionTareasPendientes", PermisoContrato = "limpieza.tareas", Permisos = { "limpieza.tareas" }, Esquema = ESQ_VACIO },
	CompletarTarea = { Metodo = "AccionCompletarTarea", PermisoContrato = "limpieza.tareas", Permisos = { "limpieza.tareas" }, Esquema = ESQ_TAREA },
}

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function StaffService:Init(registro)
	self.registro = registro
	self.Activo = false
	self.Conexiones = {}
	self.Cooldowns = {} -- userId -> clave -> os.clock()

	-- Enfermería
	self.Atendidos = {} -- userId -> { Hasta (os.time), Token, Por, PorNombre, T }
	self.TokenAtencion = 0
	self.Botiquin = {}
	self:ReponerBotiquinCompleto()

	-- Dirección / coordinación
	self.EventoActual = nil -- { Tipo, Nombre, Texto, Zona, Inicio, Hasta, Por, Token }
	self.TokenEvento = 0
	self.Propuesta = nil -- { Id, Cambios = { Duraciones, Materias }, Por, PorNombre, T }
	self.ContadorPropuestas = 0
	self.HorarioAplicado = { Duraciones = {}, Materias = {} }

	-- Memoria por jornada
	self:ReiniciarMemoriaJornada()
	self.UltimoReinicioJornada = -math.huge

	-- Finanzas
	self.Gastos = {} -- { T, Concepto, Nombre, Cantidad, Monto, Por }
	self.GastadoTotal = 0

	-- Limpieza
	self.Tareas = {} -- id -> tarea
	self.OrdenTareas = {} -- ids en orden de creación
	self.ContadorTareas = 0
	self.TokenPeriodo = 0
	self.PeriodoLimpieza = nil -- "DESCANSO" | "ALMUERZO" | nil
	self.GeneradasPeriodo = 0
	self.CompletadasPeriodo = 0
	self.LimpiezaPorJugador = {} -- userId -> tareas completadas en el periodo actual
	self.EstadoActual = nil
	self.CarpetaTareas = nil
end

-- Vacía el estado que solo vale para una jornada (convivencia, visitas, citas, certificados, mediaciones).
function StaffService:ReiniciarMemoriaJornada()
	self.Convivencia = {} -- userId -> { Casos = { {Id, T, Nivel, NivelNombre, Motivo, Por, PorNombre} } }
	self.ContadorCasos = 0
	self.Mediaciones = {}
	self.ContadorMediaciones = 0
	self.Visitas = {}
	self.ContadorVisitas = 0
	self.Citas = {}
	self.ContadorCitas = 0
	self.Certificados = {} -- array { Id, UserId, Nombre, Aula, AulaNombre, T, Emisor, Tipo }
	self.CertificadoPorUsuario = {} -- userId -> último certificado
	self.ContadorCertificados = 0
	self.Incidencias = {}
	self.ContadorIncidencias = 0
end

function StaffService:Start()
	self.Activo = true

	-- Permisos de las acciones propias en el contrato (las claves ya presentes no se tocan).
	local permisos = RemoteContracts.PermisosStaff
	if typeof(permisos) == "table" then
		for accion, def in pairs(self.Acciones) do
			if permisos[accion] == nil then
				permisos[accion] = def.PermisoContrato
			end
		end
	else
		warn(PREFIJO .. " RemoteContracts.PermisosStaff no existe; StaffAction rechazará las acciones nuevas.")
	end

	-- Handler del remoto StaffAction.
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Registrar) == "function" then
		RemoteService:Registrar("StaffAction", function(player, peticion)
			return self:Manejar(player, peticion)
		end)
		-- Parte "Personal" del StateSnapshot (Atendido, evento activo, visitas/tareas según cargo).
		if typeof(RemoteService.AportarSnapshot) == "function" then
			pcall(RemoteService.AportarSnapshot, RemoteService, "Personal", function(player)
				return self:Snapshot(player)
			end)
		end
	else
		warn(PREFIJO .. " RemoteService no disponible: StaffAction no tendrá handler.")
	end

	-- Jugadores que salen: limpiar su estado temporal.
	table.insert(self.Conexiones, Players.PlayerRemoving:Connect(function(player)
		self:AlSalir(player)
	end))

	-- Jornada escolar: tareas de limpieza en DESCANSO/ALMUERZO y reinicio de la memoria por jornada.
	self:ConectarJornada()

	-- Cambio de cargo: quien deja de ser enfermero/limpieza deja de recibir sus listas (sin estado extra).
	local RoleService = self:Servicio("RoleService")
	if RoleService and RoleService.CargoCambiado and typeof(RoleService.CargoCambiado.Connect) == "function" then
		local ok, conexion = pcall(function()
			return RoleService.CargoCambiado:Connect(function(player)
				self:AlCambiarCargo(player)
			end)
		end)
		if ok and conexion then
			table.insert(self.Conexiones, conexion)
		end
	end

	self:Auditar("Sistema", nil, "StaffService", "Funciones de personal activas (" .. contar(self.Acciones) .. " acciones)")
end

-- Detiene el servicio y retira los marcadores de limpieza (uso en pruebas/Studio).
function StaffService:Detener()
	self.Activo = false
	self:LimpiarTareas()
	for _, conexion in ipairs(self.Conexiones) do
		pcall(function()
			conexion:Disconnect()
		end)
	end
	self.Conexiones = {}
end

---------------------------------------------------------------------------------------------------
-- Infraestructura (acceso tolerante a otros servicios)
---------------------------------------------------------------------------------------------------
function StaffService:Servicio(nombre)
	if not self.registro or typeof(self.registro.Get) ~= "function" then
		return nil
	end
	local ok, servicio = pcall(self.registro.Get, nombre)
	if ok and typeof(servicio) == "table" then
		return servicio
	end
	return nil
end

-- Llama servicio:metodo(...) en pcall. Devuelve true, r1, r2, r3 | false, "sin_servicio" | "sin_metodo" | "error".
function StaffService:Llamar(nombreServicio, metodo, ...)
	local servicio = self:Servicio(nombreServicio)
	if not servicio then
		return false, "sin_servicio"
	end
	local fn = servicio[metodo]
	if typeof(fn) ~= "function" then
		return false, "sin_metodo"
	end
	local resultado = table.pack(pcall(fn, servicio, ...))
	if not resultado[1] then
		warn(PREFIJO .. " " .. nombreServicio .. ":" .. metodo .. " falló: " .. tostring(resultado[2]))
		return false, "error"
	end
	return true, resultado[2], resultado[3], resultado[4]
end

-- ¿Existe servicio:metodo?
function StaffService:Expone(nombreServicio, metodo)
	local servicio = self:Servicio(nombreServicio)
	return servicio ~= nil and typeof(servicio[metodo]) == "function"
end

function StaffService:Enviar(player, tipo, datos)
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.Enviar) == "function" then
		local ok, resultado = pcall(RemoteService.Enviar, RemoteService, player, tipo, datos)
		return ok and resultado == true
	end
	return false
end

function StaffService:EnviarATodos(tipo, datos)
	local RemoteService = self:Servicio("RemoteService")
	if RemoteService and typeof(RemoteService.EnviarATodos) == "function" then
		local ok, resultado = pcall(RemoteService.EnviarATodos, RemoteService, tipo, datos)
		return ok and resultado == true
	end
	return false
end

-- Notificación (toast) para un jugador. nivel: "info" | "exito" | "aviso" | "error".
function StaffService:Notificar(player, texto, nivel, duracion)
	return self:Enviar(player, "Notificacion", {
		Texto = tostring(texto or ""), Nivel = nivel or "info", Tipo = nivel or "info", Duracion = duracion,
	})
end

function StaffService:Auditar(categoria, player, accion, detalle)
	local AuditLog = self:Servicio("AuditLogService")
	if AuditLog and typeof(AuditLog.Registrar) == "function" then
		pcall(AuditLog.Registrar, AuditLog, categoria, player, accion, detalle)
	end
end

-- Rechazo relevante de una acción: se audita en la categoría Remoto y se devuelve el error.
function StaffService:Rechazar(player, accion, motivo, mensaje)
	self:Auditar("Remoto", player, "StaffAction:" .. tostring(accion), "rechazado: " .. tostring(motivo))
	return fallo(mensaje or ("rechazado:" .. tostring(motivo)))
end

function StaffService:Cargo(player)
	local ok, cargo = self:Llamar("RoleService", "Cargo", player)
	if ok and RoleDefinitions.Existe(cargo) then
		return cargo
	end
	if esJugador(player) then
		local atributo = player:GetAttribute("Cargo")
		if RoleDefinitions.Existe(atributo) then
			return atributo
		end
	end
	return (Config.Spawns and Config.Spawns.CargoPorDefecto) or "Estudiante"
end

function StaffService:Tiene(player, permiso)
	if not esJugador(player) then
		return false
	end
	local ok, resultado = self:Llamar("RoleService", "Tiene", player, permiso)
	if ok then
		return resultado == true
	end
	return RoleDefinitions.Tiene(self:Cargo(player), permiso)
end

function StaffService:TieneAlguno(player, permisos)
	for _, permiso in ipairs(permisos) do
		if self:Tiene(player, permiso) then
			return true
		end
	end
	return false
end

-- Dirección = control de la jornada y auditoría (Director/a y Subdirector/a).
function StaffService:EsDireccion(player)
	return self:Tiene(player, "jornada.control") and self:Tiene(player, "auditoria.ver")
end

function StaffService:JugadoresCon(permiso)
	local lista = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if self:Tiene(player, permiso) then
			table.insert(lista, player)
		end
	end
	return lista
end

function StaffService:EnviarAPermiso(permiso, tipo, datos, excepto)
	local n = 0
	for _, player in ipairs(self:JugadoresCon(permiso)) do
		if player ~= excepto and self:Enviar(player, tipo, datos) then
			n = n + 1
		end
	end
	return n
end

function StaffService:EnCooldown(player, clave, segundos)
	local porJugador = self.Cooldowns[player.UserId]
	if not porJugador then
		return false, 0
	end
	local ultimo = porJugador[clave]
	if ultimo == nil then
		return false, 0
	end
	local transcurrido = os.clock() - ultimo
	if transcurrido < segundos then
		return true, segundos - transcurrido
	end
	return false, 0
end

function StaffService:MarcarCooldown(player, clave)
	local porJugador = self.Cooldowns[player.UserId]
	if not porJugador then
		porJugador = {}
		self.Cooldowns[player.UserId] = porJugador
	end
	porJugador[clave] = os.clock()
end

-- Filtra un texto escrito por 'player' para mostrarlo a terceros. Devuelve true, texto | false, mensaje.
-- Si el filtrado falla, el texto no se usa (docs/ARQUITECTURA.md §0.4).
function StaffService:Filtrar(player, texto, maximo)
	local limpio = limpiarTexto(texto, maximo)
	if limpio == "" then
		return true, ""
	end
	local ok, resultado = pcall(function()
		return TextService:FilterStringAsync(limpio, player.UserId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok or resultado == nil then
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

-- Jugador objetivo por UserId (conectado). Devuelve player | nil, mensaje.
function StaffService:Objetivo(userId, permitirPropio, solicitante)
	local objetivo = jugadorPorId(userId)
	if not objetivo then
		return nil, "El jugador no está conectado."
	end
	if not permitirPropio and objetivo == solicitante then
		return nil, "No puedes aplicarte esta acción a ti mismo/a."
	end
	return objetivo, nil
end

-- Hora escolar actual "HH:MM" a partir del snapshot de la jornada.
function StaffService:HoraEscolar()
	local ok, snap = self:Llamar("SchoolDayService", "Snapshot")
	if ok and typeof(snap) == "table" then
		local inicio = segundosHora(snap.HoraEscolarInicio)
		local fin = segundosHora(snap.HoraEscolarFin)
		local duracion = tonumber(snap.Duracion)
		local inicioServidor = tonumber(snap.InicioServidor)
		if inicio then
			if fin and duracion and duracion > 0 and inicioServidor then
				local transcurrido = ahoraServidor() - inicioServidor
				if snap.Pausada == true and finito(tonumber(snap.Transcurrido)) then
					transcurrido = tonumber(snap.Transcurrido)
				end
				local progreso = math.clamp(transcurrido / duracion, 0, 1)
				return Format.HoraHHMM(inicio + (fin - inicio) * progreso)
			end
			return Format.HoraHHMM(inicio)
		end
		if typeof(snap.Estado) == "string" then
			local segundos = TimetableDefinitions.HoraEscolarSegundos(snap.Estado)
			if segundos then
				return Format.HoraHHMM(segundos)
			end
		end
	end
	return "--:--"
end

function StaffService:EstadoJornada()
	local ok, estado = self:Llamar("SchoolDayService", "Estado")
	if ok and typeof(estado) == "string" then
		return estado
	end
	return self.EstadoActual
end

---------------------------------------------------------------------------------------------------
-- Despacho de StaffAction
---------------------------------------------------------------------------------------------------
function StaffService:Manejar(player, peticion)
	if not esJugador(player) or typeof(peticion) ~= "table" then
		return fallo("rechazado:datos")
	end
	local nombre = peticion.Accion
	local def = self.Acciones[nombre]
	if not def then
		return self:Rechazar(player, nombre, "accion_desconocida", "Acción de personal desconocida.")
	end
	local datos = peticion.Datos
	if datos == nil then
		datos = {}
	end
	if typeof(datos) ~= "table" then
		return self:Rechazar(player, nombre, "datos", "rechazado:esquema")
	end
	if def.Fijos then
		datos = copiar(datos)
		for clave, valor in pairs(def.Fijos) do
			datos[clave] = valor
		end
	end
	-- Permiso (además del fijo del contrato que ya comprobó RemoteService).
	if def.Permisos and not self:TieneAlguno(player, def.Permisos) then
		return self:Rechazar(player, nombre, "permiso", "rechazado:permiso")
	end
	if def.Esquema then
		local okEsquema, errEsquema = Validate.Comprobar(def.Esquema, datos)
		if not okEsquema then
			return self:Rechazar(player, nombre, "esquema: " .. tostring(errEsquema), "Datos no válidos: " .. tostring(errEsquema))
		end
	end
	if def.Cooldown then
		local enEspera, restante = self:EnCooldown(player, nombre, def.Cooldown)
		if enEspera then
			return fallo("Espera " .. math.max(1, math.ceil(restante)) .. " s antes de repetir esta acción.")
		end
	end
	local metodo = self[def.Metodo]
	if typeof(metodo) ~= "function" then
		return fallo("Acción no disponible.")
	end
	local respuesta = metodo(self, player, datos, nombre)
	if typeof(respuesta) == "table" and respuesta.ok == true and def.Cooldown then
		self:MarcarCooldown(player, nombre)
	end
	return respuesta
end

---------------------------------------------------------------------------------------------------
-- Acciones generales
---------------------------------------------------------------------------------------------------
function StaffService:AccionMetrica(player, datos)
	local ok, registrada, motivo = self:Llamar("MetricsService", "RegistrarMetricaCliente", player, datos)
	if not ok then
		return fallo("Las métricas no están disponibles.")
	end
	if registrada == false then
		if motivo == "limite" then
			return fallo("rechazado:limite")
		end
		return fallo("Métrica no válida.")
	end
	return exito({ Registrada = true })
end

function StaffService:AccionMiEstado(player)
	return exito(self:Snapshot(player))
end

---------------------------------------------------------------------------------------------------
-- Dirección: panel, personal, eventos, horario propuesto
---------------------------------------------------------------------------------------------------
-- Lista de jugadores conectados con cargo, equipo y salón (solo datos públicos del juego).
function StaffService:ListaPersonal()
	local lista = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local cargo = self:Cargo(player)
		local rol = RoleDefinitions.Obtener(cargo)
		local equipoInfo = RoleDefinitions.EquipoInfo(cargo)
		local salon = player:GetAttribute("Salon")
		if typeof(salon) ~= "string" or salon == "" then
			salon = nil
		end
		table.insert(lista, {
			UserId = player.UserId,
			Nombre = nombreDe(player),
			Usuario = player.Name,
			Cargo = cargo,
			CargoNombre = rol and rol.Nombre or tostring(cargo),
			Abrev = rol and rol.Abrev or "?",
			Equipo = rol and rol.Equipo or "—",
			OrdenEquipo = equipoInfo and equipoInfo.Orden or 99,
			OrdenCargo = rol and rol.Orden or 99,
			Salon = salon,
			SalonNombre = salon and nombreZona(salon) or nil,
			Atendido = self:EstaAtendido(player),
		})
	end
	table.sort(lista, function(a, b)
		if a.OrdenEquipo ~= b.OrdenEquipo then
			return a.OrdenEquipo < b.OrdenEquipo
		end
		if a.OrdenCargo ~= b.OrdenCargo then
			return a.OrdenCargo < b.OrdenCargo
		end
		return string.lower(a.Nombre) < string.lower(b.Nombre)
	end)
	return lista
end

-- Estadísticas calculadas aquí si SchoolDayService no expone Estadisticas().
function StaffService:EstadisticasLocales()
	local porEquipo = {}
	local porCargo = {}
	local estudiantes, conAula = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		local cargo = self:Cargo(player)
		local equipo = RoleDefinitions.Equipo(cargo) or "—"
		porEquipo[equipo] = (porEquipo[equipo] or 0) + 1
		local nombreCargo = RoleDefinitions.Nombre(cargo)
		porCargo[nombreCargo] = (porCargo[nombreCargo] or 0) + 1
		if cargo == "Estudiante" then
			estudiantes = estudiantes + 1
			local salon = player:GetAttribute("Salon")
			if typeof(salon) == "string" and salon ~= "" then
				conAula = conAula + 1
			end
		end
	end
	return {
		Jugadores = #Players:GetPlayers(),
		Estudiantes = estudiantes,
		EstudiantesConAula = conAula,
		EstudiantesSinAula = estudiantes - conAula,
		PorEquipo = porEquipo,
		PorCargo = porCargo,
		Estado = self:EstadoJornada(),
		HoraEscolar = self:HoraEscolar(),
		Fuente = "StaffService",
	}
end

function StaffService:ListaAuditoria(n)
	local AuditLog = self:Servicio("AuditLogService")
	if not AuditLog then
		return {}
	end
	if typeof(AuditLog.ParaCliente) == "function" then
		local ok, lista = pcall(AuditLog.ParaCliente, AuditLog, n)
		if ok and typeof(lista) == "table" then
			return paraCliente(lista)
		end
	end
	if typeof(AuditLog.Listar) == "function" then
		local ok, lista = pcall(AuditLog.Listar, AuditLog, n)
		if ok and typeof(lista) == "table" then
			return paraCliente(lista)
		end
	end
	return {}
end

function StaffService:ListaReportes(n)
	local ok, lista = self:Llamar("ReportService", "Listar", n)
	if ok and typeof(lista) == "table" then
		return paraCliente(lista)
	end
	return {}
end

function StaffService:AccionPanelDirector(player)
	local datos = {}
	local okJ, snap = self:Llamar("SchoolDayService", "Snapshot")
	if okJ and typeof(snap) == "table" then
		datos.Jornada = paraCliente(snap)
	end
	local okE, estadisticas = self:Llamar("SchoolDayService", "Estadisticas")
	if okE and typeof(estadisticas) == "table" then
		datos.Estadisticas = paraCliente(estadisticas)
	else
		datos.Estadisticas = self:EstadisticasLocales()
	end
	datos.Personal = self:ListaPersonal()
	local okM, informe = self:Llamar("MetricsService", "Informe")
	if okM and typeof(informe) == "table" then
		datos.Metricas = paraCliente(informe)
	end
	datos.Auditoria = self:ListaAuditoria(30)
	datos.Reportes = self:ListaReportes(20)
	datos.EventoActivo = self:EventoActivo()
	datos.Propuesta = self:PropuestaParaCliente()
	datos.Resumen = {
		Atendidos = self:CantidadAtendidos(),
		TareasLimpieza = self:CantidadTareas(),
		Visitas = #self.Visitas,
		Citas = #self.Citas,
		CasosConvivencia = self.ContadorCasos,
		Mediaciones = #self.Mediaciones,
		Incidencias = #self.Incidencias,
		PresupuestoSaldo = self:SaldoPresupuesto(),
	}
	datos.HoraEscolar = self:HoraEscolar()
	return exito(datos)
end

function StaffService:AccionInforme()
	local ok, informe = self:Llamar("MetricsService", "Informe")
	if not ok or typeof(informe) ~= "table" then
		return fallo("Las métricas no están disponibles.")
	end
	return exito({ Metricas = paraCliente(informe) })
end

function StaffService:AccionAuditoria()
	return exito({ Auditoria = self:ListaAuditoria(30) })
end

function StaffService:AccionPersonal()
	return exito({ Personal = self:ListaPersonal() })
end

-- Copia pública del evento activo (o nil). Consultable por otros servicios.
function StaffService:EventoActivo()
	local evento = self.EventoActual
	if not evento then
		return nil
	end
	if os.time() >= evento.Hasta then
		self:TerminarEvento(evento.Token, "expirado")
		return nil
	end
	return {
		Tipo = evento.Tipo, Nombre = evento.Nombre, Texto = evento.Texto, Zona = evento.Zona,
		ZonaNombre = nombreZona(evento.Zona), Inicio = evento.Inicio, Hasta = evento.Hasta,
		Restante = math.max(0, evento.Hasta - os.time()), PorNombre = evento.PorNombre,
	}
end

-- ¿Hay un evento activo (de un tipo concreto, opcional)?
function StaffService:HayEvento(tipo)
	local evento = self:EventoActivo()
	if not evento then
		return false
	end
	return tipo == nil or evento.Tipo == tipo
end

function StaffService:AccionActivarEvento(player, datos)
	local def = self.Eventos[datos.Tipo]
	if not def then
		return fallo("Tipo de evento desconocido.")
	end
	local actual = self:EventoActivo()
	if actual and actual.Tipo == datos.Tipo then
		return fallo("Ya hay un evento '" .. def.Nombre .. "' activo (quedan " .. Format.Duracion(actual.Restante) .. ").")
	end
	if actual then
		self:TerminarEvento(self.EventoActual.Token, "reemplazado", true)
	end
	self.TokenEvento = self.TokenEvento + 1
	local token = self.TokenEvento
	local ahora = os.time()
	self.EventoActual = {
		Tipo = datos.Tipo, Nombre = def.Nombre, Texto = def.Texto, Zona = def.Zona,
		Inicio = ahora, Hasta = ahora + self.DuracionEventoSeg, Por = player.UserId, PorNombre = nombreDe(player), Token = token,
	}
	pcall(function()
		RP:SetAttribute("EventoActivo", datos.Tipo)
		RP:SetAttribute("EventoActivoHasta", ahora + self.DuracionEventoSeg)
	end)
	local evento = self:EventoActivo()
	self:EnviarATodos("Personal", { Sub = "Evento", Evento = evento, Activo = true })
	-- Anuncio oficial (texto del sistema) o, si no hay AnnouncementService, notificación a todos.
	local texto = def.Texto .. " Dirígete a: " .. nombreZona(def.Zona) .. "."
	local okA, resultado = self:Llamar("AnnouncementService", "Anunciar", nil, texto, "Global", nil)
	if not okA or resultado == false then
		self:EnviarATodos("Notificacion", { Texto = def.Nombre .. ": " .. texto, Nivel = "aviso", Tipo = "aviso", Duracion = 8 })
	end
	task.delay(self.DuracionEventoSeg, function()
		self:TerminarEvento(token, "expirado")
	end)
	self:Auditar("Sistema", player, "Evento", def.Nombre .. " activado durante " .. Format.Duracion(self.DuracionEventoSeg))
	return exito({ Evento = evento })
end

function StaffService:AccionDesactivarEvento(player)
	local evento = self.EventoActual
	if not evento then
		return fallo("No hay ningún evento activo.")
	end
	self:TerminarEvento(evento.Token, "finalizado por " .. nombreDe(player))
	self:Auditar("Sistema", player, "Evento", evento.Nombre .. " finalizado")
	return exito({ Evento = nil })
end

-- Termina el evento si el token coincide (los temporizadores antiguos no afectan a eventos nuevos).
function StaffService:TerminarEvento(token, motivo, silencioso)
	local evento = self.EventoActual
	if not evento or evento.Token ~= token then
		return
	end
	self.EventoActual = nil
	pcall(function()
		RP:SetAttribute("EventoActivo", nil)
		RP:SetAttribute("EventoActivoHasta", nil)
	end)
	if silencioso then
		return
	end
	self:EnviarATodos("Personal", { Sub = "Evento", Evento = nil, Activo = false, Terminado = evento.Tipo, Motivo = tostring(motivo or "") })
	self:EnviarATodos("Notificacion", { Texto = "Ha terminado el evento: " .. evento.Nombre .. ".", Nivel = "info", Tipo = "info" })
end

---------------------------------------------------------------------------------------------------
-- Coordinación académica: horario, aulas, sesiones y conflictos
---------------------------------------------------------------------------------------------------
-- Valida los cambios de horario. Devuelve cambios | nil, mensaje.
function StaffService:ValidarCambiosHorario(datos)
	local cambios = { Duraciones = {}, Materias = {} }
	local n = 0
	if datos.Duraciones ~= nil then
		for estado, valor in pairs(datos.Duraciones) do
			if typeof(estado) ~= "string" or not TimetableDefinitions.Existe(estado) then
				return nil, "Periodo desconocido: " .. tostring(estado)
			end
			if typeof(valor) ~= "number" or not finito(valor) or math.floor(valor) ~= valor then
				return nil, "La duración de " .. TimetableDefinitions.Nombre(estado) .. " debe ser un número entero de segundos."
			end
			if valor < self.DuracionMinPeriodo or valor > self.DuracionMaxPeriodo then
				return nil, string.format("La duración de %s debe estar entre %d y %d s.", TimetableDefinitions.Nombre(estado), self.DuracionMinPeriodo, self.DuracionMaxPeriodo)
			end
			cambios.Duraciones[estado] = valor
			n = n + 1
		end
	end
	if datos.Materias ~= nil then
		for estado, codigo in pairs(datos.Materias) do
			if typeof(estado) ~= "string" or not TimetableDefinitions.EsClase(estado) then
				return nil, "Solo los periodos de clase tienen materia (" .. tostring(estado) .. ")."
			end
			if not TimetableDefinitions.ExisteMateria(codigo) then
				return nil, "Materia desconocida: " .. tostring(codigo)
			end
			cambios.Materias[estado] = codigo
			n = n + 1
		end
	end
	if n == 0 then
		return nil, "No hay cambios que aplicar."
	end
	return cambios, nil
end

local function describirCambios(cambios)
	local partes = {}
	for estado, valor in pairs(cambios.Duraciones or {}) do
		table.insert(partes, TimetableDefinitions.Nombre(estado) .. " = " .. Format.Duracion(valor))
	end
	for estado, codigo in pairs(cambios.Materias or {}) do
		table.insert(partes, TimetableDefinitions.Nombre(estado) .. " → " .. TimetableDefinitions.NombreMateria(codigo))
	end
	table.sort(partes)
	return table.concat(partes, "; ")
end

-- Códigos de rechazo de SchoolDayService traducidos para el panel.
local MENSAJES_JORNADA = {
	sin_cambios = "No hay cambios que aplicar.",
	clave_desconocida = "La jornada no admite uno de los cambios.",
	duracion_invalida = "Una de las duraciones no es válida para la jornada.",
	estado_invalido = "Periodo desconocido.",
	clase_invalida = "Solo los periodos de clase tienen materia.",
	materia_invalida = "Materia desconocida.",
	aula_invalida = "El aula indicada no existe.",
	aula_llena = "El aula está completa.",
	aula_con_docente = "El aula ya tiene un docente asignado.",
	cargo_sin_aula = "Ese cargo no tiene aula.",
	sin_aulas = "No hay aulas disponibles ahora.",
	jugador_invalido = "El jugador no es válido.",
}
local function mensajeJornada(codigo, porDefecto)
	if typeof(codigo) ~= "string" then
		return porDefecto
	end
	local base = string.match(codigo, "^([%a_]+)") or codigo
	return MENSAJES_JORNADA[base] or (porDefecto .. " (" .. Format.Truncar(codigo, 40) .. ")")
end

-- Aplica los cambios vía SchoolDayService:Configurar(tabla, actor). Devuelve true | false, mensaje.
function StaffService:AplicarHorario(cambios, player)
	local configuracion = {}
	if next(cambios.Duraciones) ~= nil then
		configuracion.Duraciones = copiar(cambios.Duraciones)
	end
	if next(cambios.Materias) ~= nil then
		configuracion.Materias = copiar(cambios.Materias)
	end
	local ok, r1, r2 = self:Llamar("SchoolDayService", "Configurar", configuracion, player)
	if not ok then
		if r1 == "sin_servicio" or r1 == "sin_metodo" then
			return false, "La jornada escolar no está disponible."
		end
		return false, "No se pudo aplicar el horario."
	end
	if r1 == false then
		return false, mensajeJornada(r2, "La jornada rechazó los cambios")
	end
	if typeof(r1) == "table" and r1.ok == false then
		return false, tostring(r1.error or "La jornada rechazó los cambios.")
	end
	for estado, valor in pairs(cambios.Duraciones) do
		self.HorarioAplicado.Duraciones[estado] = valor
	end
	for estado, codigo in pairs(cambios.Materias) do
		self.HorarioAplicado.Materias[estado] = codigo
	end
	self:Auditar("Sistema", player, "Horario", "Aplicado: " .. describirCambios(cambios))
	return true
end

function StaffService:PropuestaParaCliente()
	local p = self.Propuesta
	if not p then
		return nil
	end
	return {
		Id = p.Id, PorNombre = p.PorNombre, T = p.T, Descripcion = describirCambios(p.Cambios),
		Duraciones = copiar(p.Cambios.Duraciones), Materias = copiar(p.Cambios.Materias),
	}
end

function StaffService:AccionEditarHorario(player, datos)
	local cambios, err = self:ValidarCambiosHorario(datos)
	if not cambios then
		return fallo(err)
	end
	local direccion = {}
	for _, otro in ipairs(Players:GetPlayers()) do
		if otro ~= player and self:EsDireccion(otro) then
			table.insert(direccion, otro)
		end
	end
	-- La dirección aplica directamente; coordinación propone (o aplica si lo pide y no hay dirección conectada).
	if self:EsDireccion(player) or (datos.Aplicar == true and #direccion == 0) then
		local okAplicar, errAplicar = self:AplicarHorario(cambios, player)
		if not okAplicar then
			return fallo(errAplicar)
		end
		return exito({ Aplicado = true, Descripcion = describirCambios(cambios) })
	end
	self.ContadorPropuestas = self.ContadorPropuestas + 1
	self.Propuesta = { Id = self.ContadorPropuestas, Cambios = cambios, Por = player.UserId, PorNombre = nombreDe(player), T = os.time() }
	local propuesta = self:PropuestaParaCliente()
	for _, director in ipairs(direccion) do
		self:Enviar(director, "Personal", { Sub = "Horario", Propuesta = propuesta })
		self:Notificar(director, "Coordinación académica propone cambios de horario: " .. propuesta.Descripcion .. ". Revísalos en el panel de cargo.", "aviso", 8)
	end
	self:Auditar("Sistema", player, "HorarioPropuesto", propuesta.Descripcion)
	return exito({ Aplicado = false, Pendiente = true, Propuesta = propuesta, SinDireccion = #direccion == 0 })
end

function StaffService:AccionAprobarHorario(player, datos)
	if not self:EsDireccion(player) then
		return self:Rechazar(player, "AprobarHorario", "no_direccion", "Solo la dirección puede aprobar el horario.")
	end
	local propuesta = self.Propuesta
	if not propuesta then
		return fallo("No hay ninguna propuesta de horario pendiente.")
	end
	if datos.Id ~= nil and datos.Id ~= propuesta.Id then
		return fallo("La propuesta ha cambiado; actualiza el panel.")
	end
	local proponente = jugadorPorId(propuesta.Por)
	local descripcion = describirCambios(propuesta.Cambios)
	if datos.Aprobar == false then
		self.Propuesta = nil
		if proponente then
			self:Notificar(proponente, "La dirección no aprobó tu propuesta de horario.", "aviso")
		end
		self:Auditar("Sistema", player, "HorarioRechazado", descripcion)
		return exito({ Aprobado = false })
	end
	local ok, err = self:AplicarHorario(propuesta.Cambios, player)
	if not ok then
		return fallo(err)
	end
	self.Propuesta = nil
	if proponente then
		self:Notificar(proponente, "La dirección aprobó tu propuesta de horario: " .. descripcion .. ".", "exito")
	end
	return exito({ Aprobado = true, Descripcion = descripcion })
end

-- Periodos con duración y materia vigentes (SchoolDayService si lo expone; si no, definiciones + cambios aplicados).
function StaffService:AccionHorarioActual()
	local fuente = nil
	for _, metodo in ipairs({ "Periodos", "Horario" }) do
		if fuente == nil then
			local ok, lista = self:Llamar("SchoolDayService", metodo)
			if ok and typeof(lista) == "table" and #lista > 0 then
				fuente = lista
			end
		end
	end
	local porEstado = {}
	if fuente then
		for _, periodo in ipairs(fuente) do
			if typeof(periodo) == "table" and typeof(periodo.Estado) == "string" then
				porEstado[periodo.Estado] = periodo
			end
		end
	end
	local periodos = {}
	for _, base in ipairs(TimetableDefinitions.Periodos) do
		local real = porEstado[base.Estado] or {}
		local duracion = tonumber(real.Duracion) or self.HorarioAplicado.Duraciones[base.Estado] or base.Duracion
		local materia = nil
		if base.EsClase then
			materia = real.Materia or self.HorarioAplicado.Materias[base.Estado] or base.Materia
		end
		table.insert(periodos, {
			Estado = base.Estado, Nombre = base.Nombre, HoraEscolar = base.HoraEscolar, EsClase = base.EsClase == true,
			Duracion = duracion, Materia = materia, MateriaNombre = materia and TimetableDefinitions.NombreMateria(materia) or nil,
		})
	end
	return exito({
		Periodos = periodos, Propuesta = self:PropuestaParaCliente(), Estado = self:EstadoJornada(),
		Min = self.DuracionMinPeriodo, Max = self.DuracionMaxPeriodo,
	})
end

-- Asigna (o reasigna con roomId nil = reparto automático) el aula de un jugador. Devuelve aula | nil, mensaje.
function StaffService:AsignarAulaInterna(objetivo, roomId)
	if roomId ~= nil and not esAula(roomId) then
		return nil, "El aula indicada no existe."
	end
	local ok, r1, r2 = self:Llamar("SchoolDayService", "AsignarAula", objetivo, roomId)
	local aula = nil
	if ok then
		if esAula(r1) then
			aula = r1
		elseif r1 == true and esAula(r2) then
			aula = r2
		elseif typeof(r1) == "table" then
			local candidato = r1.RoomId or r1.Salon or r1.Aula
			if esAula(candidato) then
				aula = candidato
			end
		elseif r1 == false or (r1 == nil and typeof(r2) == "string") then
			-- AsignarAula devuelve nil, codigo (aula_llena, aula_con_docente, cargo_sin_aula, sin_aulas...).
			return nil, mensajeJornada(r2, "La jornada no pudo asignar el aula")
		end
		if aula == nil then
			-- AsignarAula sin valor de retorno: se toma el atributo Salon que haya fijado la jornada.
			local salon = objetivo:GetAttribute("Salon")
			if esAula(salon) and (roomId == nil or salon == roomId) then
				aula = salon
			end
		end
	elseif roomId ~= nil then
		-- Respaldo sin SchoolDayService: se fija el salón directamente.
		local okSalon, fijado = self:Llamar("RoleService", "FijarSalon", objetivo, roomId)
		if okSalon and fijado ~= false then
			aula = roomId
		end
	end
	if not aula then
		return nil, "No se pudo asignar el aula (servicio de jornada no disponible o aulas completas)."
	end
	-- Mantiene el atributo Salon coherente (RoleService reenvía el rol al cliente).
	if objetivo:GetAttribute("Salon") ~= aula then
		local okSalon = self:Llamar("RoleService", "FijarSalon", objetivo, aula)
		if not okSalon then
			pcall(function()
				objetivo:SetAttribute("Salon", aula)
			end)
		end
	end
	return aula, nil
end

function StaffService:AccionAsignarAula(player, datos)
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, true, player)
	if not objetivo then
		return fallo(err)
	end
	if not esAula(datos.RoomId) then
		return fallo("El aula indicada no existe.")
	end
	local aula, errAula = self:AsignarAulaInterna(objetivo, datos.RoomId)
	if not aula then
		return fallo(errAula)
	end
	self:Notificar(objetivo, "Coordinación académica te asignó el aula " .. aula .. " (" .. nombreZona(aula) .. ").", "info")
	self:Auditar("Sistema", player, "AsignarAula", nombreDe(objetivo) .. " → " .. aula)
	return exito({ UserId = objetivo.UserId, Nombre = nombreDe(objetivo), Aula = aula, AulaNombre = nombreZona(aula) })
end

function StaffService:AccionVerSesiones()
	local maxPorAula = (Config.Jornada and Config.Jornada.EstudiantesPorAulaMax) or 20
	local activas = {}
	for _, id in ipairs((Config.Jornada and Config.Jornada.AulasActivas) or {}) do
		activas[id] = true
	end
	local asignados = {} -- roomId -> { Estudiantes = {player}, Docentes = {player} }
	local conflictos = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local cargo = self:Cargo(player)
		local esDocente = RoleDefinitions.EsDocente(cargo)
		local esEstudiante = cargo == "Estudiante"
		if esDocente or esEstudiante then
			local salon = player:GetAttribute("Salon")
			if typeof(salon) == "string" and esAula(salon) then
				local grupo = asignados[salon]
				if not grupo then
					grupo = { Estudiantes = {}, Docentes = {} }
					asignados[salon] = grupo
				end
				if esDocente then
					table.insert(grupo.Docentes, player)
				else
					table.insert(grupo.Estudiantes, player)
					if next(activas) ~= nil and not activas[salon] then
						table.insert(conflictos, {
							Tipo = "AulaInactiva", RoomId = salon, UserId = player.UserId, Nombre = nombreDe(player),
							Texto = nombreDe(player) .. " está en " .. salon .. ", que no es un aula activa.",
						})
					end
				end
			else
				table.insert(conflictos, {
					Tipo = "SinAula", UserId = player.UserId, Nombre = nombreDe(player),
					Texto = nombreDe(player) .. " (" .. RoleDefinitions.Nombre(cargo) .. ") no tiene aula asignada.",
				})
			end
		end
	end

	local aulas = {}
	for _, roomId in ipairs(MapaLogico.Aulas or {}) do
		local grupo = asignados[roomId] or { Estudiantes = {}, Docentes = {} }
		local fila = {
			RoomId = roomId, Nombre = nombreZona(roomId), Activa = (next(activas) == nil) or activas[roomId] == true,
			Estudiantes = #grupo.Estudiantes, Docentes = {},
		}
		for _, docente in ipairs(grupo.Docentes) do
			table.insert(fila.Docentes, nombreDe(docente))
		end
		local okS, sesion = self:Llamar("ClassroomService", "SesionDe", roomId)
		if okS and typeof(sesion) == "table" then
			local presentes = 0
			if typeof(sesion.PresentUserIds) == "table" then
				presentes = contar(sesion.PresentUserIds)
			end
			fila.Sesion = {
				Estado = tostring(sesion.State or sesion.Estado or "Abierta"),
				Tema = typeof(sesion.Tema) == "string" and Format.Truncar(sesion.Tema, 80) or nil,
				Docente = nombreDeId(sesion.TeacherUserId),
				Presentes = presentes,
				Desde = tonumber(sesion.StartedAt),
				Actividad = sesion.ActiveActivityId ~= nil,
			}
		end
		local okO, ocupacion = self:Llamar("RoomService", "Ocupacion", roomId)
		if okO and typeof(ocupacion) == "table" then
			fila.Sentados = typeof(ocupacion.Sentados) == "table" and #ocupacion.Sentados or 0
			fila.DePie = typeof(ocupacion.DePie) == "table" and #ocupacion.DePie or 0
			fila.Capacidad = tonumber(ocupacion.Capacidad)
		end
		-- Conflictos: varios docentes y sobrecupo.
		if #grupo.Docentes > 1 then
			for i = 2, #grupo.Docentes do
				local docente = grupo.Docentes[i]
				table.insert(conflictos, {
					Tipo = "VariosDocentes", RoomId = roomId, UserId = docente.UserId, Nombre = nombreDe(docente),
					Texto = roomId .. " tiene " .. #grupo.Docentes .. " docentes asignados (" .. nombreDe(docente) .. " puede reasignarse).",
				})
			end
		end
		local limite = maxPorAula
		if fila.Capacidad and fila.Capacidad > 0 then
			limite = math.min(limite, fila.Capacidad)
		end
		if #grupo.Estudiantes > limite then
			for i = limite + 1, math.min(#grupo.Estudiantes, limite + 10) do
				local estudiante = grupo.Estudiantes[i]
				table.insert(conflictos, {
					Tipo = "Sobrecupo", RoomId = roomId, UserId = estudiante.UserId, Nombre = nombreDe(estudiante),
					Texto = roomId .. " supera su cupo (" .. #grupo.Estudiantes .. "/" .. limite .. "): " .. nombreDe(estudiante) .. " puede reasignarse.",
				})
			end
		end
		table.insert(aulas, fila)
	end
	return exito({ Aulas = aulas, Conflictos = conflictos, Estado = self:EstadoJornada() })
end

function StaffService:AccionResolverConflicto(player, datos)
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, true, player)
	if not objetivo then
		return fallo(err)
	end
	local cargo = self:Cargo(objetivo)
	if cargo ~= "Estudiante" and not RoleDefinitions.EsDocente(cargo) then
		return fallo("Solo se reasignan aulas a estudiantes y docentes.")
	end
	local anterior = objetivo:GetAttribute("Salon")
	local aula, errAula = self:AsignarAulaInterna(objetivo, datos.RoomId)
	if not aula then
		return fallo(errAula)
	end
	if aula ~= anterior then
		self:Notificar(objetivo, "Tu aula ha cambiado a " .. aula .. " (" .. nombreZona(aula) .. ").", "aviso")
	end
	self:Auditar("Sistema", player, "ResolverConflicto", nombreDe(objetivo) .. ": " .. tostring(anterior or "sin aula") .. " → " .. aula)
	return exito({ UserId = objetivo.UserId, Nombre = nombreDe(objetivo), Aula = aula, Anterior = anterior })
end

---------------------------------------------------------------------------------------------------
-- Convivencia: escala aviso → nota → citación (por jornada) y mediaciones
---------------------------------------------------------------------------------------------------
-- Respaldo si ModerationService no expone Advertir: se anota en Perfil.Moderacion.Advertencias.
function StaffService:AdvertenciaEnPerfil(objetivo, motivo)
	local ok, perfil = self:Llamar("DataService", "Obtener", objetivo)
	if not ok or typeof(perfil) ~= "table" then
		return false
	end
	if typeof(perfil.Moderacion) ~= "table" then
		perfil.Moderacion = { Advertencias = {}, BloqueoHasta = 0 }
	end
	if typeof(perfil.Moderacion.Advertencias) ~= "table" then
		perfil.Moderacion.Advertencias = {}
	end
	table.insert(perfil.Moderacion.Advertencias, { T = os.time(), Motivo = Format.Truncar(motivo, 120) })
	limitarLista(perfil.Moderacion.Advertencias, (Config.Moderacion and Config.Moderacion.MaxAdvertencias) or 20)
	self:Llamar("DataService", "Marcar", objetivo)
	return true
end

function StaffService:CasosParaCliente()
	local lista = {}
	for userId, registro in pairs(self.Convivencia) do
		local ultimo = registro.Casos[#registro.Casos]
		table.insert(lista, {
			UserId = userId, Nombre = registro.Nombre, Conectado = jugadorPorId(userId) ~= nil,
			Cantidad = #registro.Casos, Nivel = ultimo and ultimo.NivelNombre or "—",
			Ultimo = ultimo and ultimo.Motivo or "", T = ultimo and ultimo.T or 0,
			Casos = paraCliente(registro.Casos),
		})
	end
	table.sort(lista, function(a, b)
		return a.T > b.T
	end)
	return lista
end

function StaffService:AccionReporteConvivencia(player, datos)
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, false, player)
	if not objetivo then
		return fallo(err)
	end
	local clave = "Conv:" .. objetivo.UserId
	local enEspera, restante = self:EnCooldown(player, clave, 20)
	if enEspera then
		return fallo("Ya registraste un caso de esta persona hace poco; espera " .. math.ceil(restante) .. " s.")
	end
	local okTexto, motivo = self:Filtrar(player, datos.Motivo, 120)
	if not okTexto then
		return fallo(motivo)
	end
	if motivo == "" then
		return fallo("Escribe el motivo del caso.")
	end
	local registro = self.Convivencia[objetivo.UserId]
	if not registro then
		registro = { Nombre = nombreDe(objetivo), Casos = {} }
		self.Convivencia[objetivo.UserId] = registro
	end
	local indice = math.min(#registro.Casos + 1, #self.NivelesConvivencia)
	local nivel = self.NivelesConvivencia[indice]
	self.ContadorCasos = self.ContadorCasos + 1
	local caso = {
		Id = self.ContadorCasos, T = os.time(), Hora = self:HoraEscolar(), Nivel = nivel.Id, NivelNombre = nivel.Nombre,
		Motivo = motivo, Por = player.UserId, PorNombre = nombreDe(player),
	}
	table.insert(registro.Casos, caso)
	limitarLista(registro.Casos, self.MaxCasosPorJugador)
	self:MarcarCooldown(player, clave)

	-- Advertencia en el perfil (ModerationService si existe; respaldo directo en el perfil).
	local textoAdvertencia = "[Convivencia · " .. nivel.Nombre .. "] " .. motivo
	local okMod, resultadoMod = self:Llamar("ModerationService", "Advertir", player, objetivo, textoAdvertencia)
	local enPerfil = okMod and resultadoMod ~= false
	if not okMod and (resultadoMod == "sin_servicio" or resultadoMod == "sin_metodo") then
		enPerfil = self:AdvertenciaEnPerfil(objetivo, textoAdvertencia)
	end

	-- Aviso al implicado (texto filtrado) y refresco de la coordinación.
	local mensaje = "Convivencia · " .. nivel.Nombre .. ": " .. motivo .. ". " .. nivel.Texto
	if nivel.Id == "Citacion" then
		mensaje = mensaje .. " Acude a la coordinación cuando termine la actividad actual."
	end
	self:Notificar(objetivo, mensaje, nivel.Id == "Aviso" and "info" or "aviso", 8)
	self:Enviar(objetivo, "Personal", { Sub = "Convivencia", Nivel = nivel.Id, NivelNombre = nivel.Nombre, Motivo = motivo })
	self:EnviarAPermiso("convivencia.gestionar", "Personal", { Sub = "Convivencia", Casos = self:CasosParaCliente() })
	if nivel.Id == "Citacion" then
		for _, coordinador in ipairs(self:JugadoresCon("convivencia.gestionar")) do
			if coordinador ~= player then
				self:Notificar(coordinador, nombreDe(objetivo) .. " ha sido citado/a a convivencia (3.er caso de la jornada).", "aviso")
			end
		end
	end
	self:Auditar("Moderacion", player, "Convivencia:" .. nivel.Id, nombreDe(objetivo) .. " (" .. objetivo.UserId .. "): " .. motivo)
	return exito({ Caso = caso, Nivel = nivel.Id, NivelNombre = nivel.Nombre, Cantidad = #registro.Casos, EnPerfil = enPerfil == true, Nombre = nombreDe(objetivo) })
end

function StaffService:AccionMediacion(player, datos)
	local participantes = datos.Participantes or {}
	if #participantes < 2 then
		return fallo("Selecciona al menos dos participantes para la mediación.")
	end
	local vistos = {}
	local jugadores = {}
	for _, userId in ipairs(participantes) do
		if vistos[userId] then
			return fallo("Hay participantes repetidos.")
		end
		vistos[userId] = true
		local participante = jugadorPorId(userId)
		if not participante then
			return fallo("Uno de los participantes no está conectado.")
		end
		if participante == player then
			return fallo("Quien media no puede ser participante.")
		end
		table.insert(jugadores, participante)
	end
	local okTexto, nota = self:Filtrar(player, datos.Nota or "", 160)
	if not okTexto then
		return fallo(nota)
	end
	self.ContadorMediaciones = self.ContadorMediaciones + 1
	local nombres = {}
	for _, participante in ipairs(jugadores) do
		table.insert(nombres, nombreDe(participante))
	end
	local mediacion = {
		Id = self.ContadorMediaciones, T = os.time(), Hora = self:HoraEscolar(), Participantes = nombres,
		Nota = nota, Mediador = nombreDe(player),
	}
	table.insert(self.Mediaciones, mediacion)
	limitarLista(self.Mediaciones, self.MaxMediaciones)
	for _, participante in ipairs(jugadores) do
		self:Notificar(participante, "Convivencia: " .. nombreDe(player) .. " te convoca a una mediación con " .. table.concat(nombres, ", ") .. ".", "info", 8)
	end
	self:Auditar("Moderacion", player, "Mediacion", table.concat(nombres, ", ") .. (nota ~= "" and (" · " .. nota) or ""))
	return exito({ Mediacion = mediacion })
end

function StaffService:AccionVerReportes(player)
	local datos = {}
	if self:Tiene(player, "reportes.ver") or self:Tiene(player, "convivencia.gestionar") then
		datos.Reportes = self:ListaReportes(20)
	end
	if self:Tiene(player, "convivencia.gestionar") then
		datos.Casos = self:CasosParaCliente()
		datos.Mediaciones = paraCliente(self.Mediaciones)
		datos.Incidencias = paraCliente(self.Incidencias)
	end
	return exito(datos)
end

---------------------------------------------------------------------------------------------------
-- Orientación: agenda de citas RP y recursos de bienestar
---------------------------------------------------------------------------------------------------
function StaffService:CitaPorId(id)
	for _, cita in ipairs(self.Citas) do
		if cita.Id == id then
			return cita
		end
	end
	return nil
end

function StaffService:CitasParaCliente()
	local lista = {}
	for _, cita in ipairs(self.Citas) do
		local copia = copiar(cita)
		copia.Conectado = jugadorPorId(cita.UserId) ~= nil
		table.insert(lista, copia)
	end
	return lista
end

function StaffService:DifundirCitas()
	self:EnviarAPermiso("orientacion.agenda", "Personal", { Sub = "Cita", Citas = self:CitasParaCliente() })
end

function StaffService:AccionCita(player, datos)
	local sub = datos.Sub
	if sub == "Listar" then
		return exito({ Citas = self:CitasParaCliente(), HoraEscolar = self:HoraEscolar() })
	end
	if sub == "Crear" then
		local objetivo, err = self:Objetivo(datos.ObjetivoUserId, false, player)
		if not objetivo then
			return fallo(err or "Elige a la persona de la cita.")
		end
		local pendientes = 0
		for _, cita in ipairs(self.Citas) do
			if cita.Estado == "Pendiente" then
				pendientes = pendientes + 1
				if cita.UserId == objetivo.UserId then
					return fallo(nombreDe(objetivo) .. " ya tiene una cita pendiente (" .. cita.Hora .. ").")
				end
			end
		end
		if pendientes >= self.MaxCitas then
			return fallo("La agenda está completa; completa o cancela alguna cita.")
		end
		local hora = nil
		if datos.Hora ~= nil and datos.Hora ~= "" then
			if Format.SegundosDeHHMM(datos.Hora) == nil then
				return fallo("La hora debe tener el formato HH:MM (hora escolar).")
			end
			hora = datos.Hora
		else
			hora = self:HoraEscolar()
		end
		local okTexto, motivo = self:Filtrar(player, datos.Motivo or "", 120)
		if not okTexto then
			return fallo(motivo)
		end
		if motivo == "" then
			motivo = "Seguimiento general"
		end
		self.ContadorCitas = self.ContadorCitas + 1
		local cita = {
			Id = self.ContadorCitas, UserId = objetivo.UserId, Nombre = nombreDe(objetivo), Motivo = motivo, Hora = hora,
			Estado = "Pendiente", Orientador = nombreDe(player), OrientadorId = player.UserId, T = os.time(),
		}
		table.insert(self.Citas, cita)
		limitarLista(self.Citas, self.MaxCitas * 2)
		self:Notificar(objetivo, "Orientación: tienes una cita con " .. nombreDe(player) .. " a las " .. hora .. " (hora escolar).", "info", 8)
		self:Enviar(objetivo, "Personal", { Sub = "Cita", Cita = copiar(cita) })
		self:DifundirCitas()
		self:Auditar("Sistema", player, "Cita", "Cita " .. cita.Id .. " con " .. cita.Nombre .. " a las " .. hora)
		return exito({ Cita = cita, Citas = self:CitasParaCliente() })
	end
	-- Cancelar / Completar
	local cita = self:CitaPorId(datos.CitaId)
	if not cita then
		return fallo("La cita no existe.")
	end
	if cita.Estado ~= "Pendiente" then
		return fallo("La cita ya está " .. string.lower(cita.Estado) .. ".")
	end
	if sub == "Cancelar" then
		cita.Estado = "Cancelada"
	else
		cita.Estado = "Completada"
	end
	cita.Cierre = os.time()
	local implicado = jugadorPorId(cita.UserId)
	if implicado and sub == "Cancelar" then
		self:Notificar(implicado, "Orientación: tu cita de las " .. cita.Hora .. " ha sido cancelada.", "info")
	end
	if implicado then
		self:Enviar(implicado, "Personal", { Sub = "Cita", Cita = copiar(cita) })
	end
	self:DifundirCitas()
	self:Auditar("Sistema", player, "Cita", "Cita " .. cita.Id .. " " .. string.lower(cita.Estado))
	return exito({ Cita = cita, Citas = self:CitasParaCliente() })
end

function StaffService:AccionRecursos()
	local recursos = {}
	if typeof(Catalogs.RecursosBienestar) == "table" then
		for _, recurso in ipairs(Catalogs.RecursosBienestar) do
			if typeof(recurso) == "table" and typeof(recurso.Texto) == "string" then
				table.insert(recursos, { Titulo = tostring(recurso.Titulo or "Recurso"), Texto = recurso.Texto })
			elseif typeof(recurso) == "string" then
				table.insert(recursos, { Titulo = "Recurso", Texto = recurso })
			end
		end
	end
	if #recursos == 0 then
		for _, recurso in ipairs(self.RecursosBienestar) do
			table.insert(recursos, copiar(recurso))
		end
	end
	return exito({ Recursos = recursos, Nota = "Recursos orientativos de convivencia y bienestar (sin carácter clínico)." })
end

---------------------------------------------------------------------------------------------------
-- Enfermería: atención con aforo, alta y botiquín ficticio
---------------------------------------------------------------------------------------------------
function StaffService:EstaAtendido(player)
	if not esJugador(player) then
		return false
	end
	local registro = self.Atendidos[player.UserId]
	return registro ~= nil and os.time() < registro.Hasta
end

function StaffService:CantidadAtendidos()
	local n = 0
	local ahora = os.time()
	for _, registro in pairs(self.Atendidos) do
		if ahora < registro.Hasta then
			n = n + 1
		end
	end
	return n
end

function StaffService:ListaAtendidos()
	local lista = {}
	local ahora = os.time()
	for userId, registro in pairs(self.Atendidos) do
		if ahora < registro.Hasta then
			table.insert(lista, {
				UserId = userId, Nombre = nombreDeId(userId), Restante = registro.Hasta - ahora,
				Hasta = registro.Hasta, PorNombre = registro.PorNombre,
			})
		end
	end
	table.sort(lista, function(a, b)
		return a.Restante < b.Restante
	end)
	return lista
end

function StaffService:DifundirAtendidos()
	self:EnviarAPermiso("enfermeria.atender", "Personal", {
		Sub = "Atendido", Atendidos = self:ListaAtendidos(), Aforo = self.AforoEnfermeria,
	})
end

-- Quita la etiqueta Atendido si el token coincide (los temporizadores viejos no afectan a atenciones nuevas).
function StaffService:FinAtencion(userId, token, motivo)
	local registro = self.Atendidos[userId]
	if not registro or (token ~= nil and registro.Token ~= token) then
		return
	end
	self.Atendidos[userId] = nil
	local player = jugadorPorId(userId)
	if player then
		pcall(function()
			player:SetAttribute("Atendido", nil)
		end)
		self:Enviar(player, "Personal", { Sub = "Atendido", Atendido = false, Motivo = motivo })
	end
	self:DifundirAtendidos()
end

function StaffService:AccionAtender(player, datos)
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, false, player)
	if not objetivo then
		return fallo(err)
	end
	local posEnfermero = posicionDe(player)
	local posPaciente = posicionDe(objetivo)
	if not posEnfermero or not posPaciente then
		return fallo("La persona no está en el mapa ahora mismo.")
	end
	local distancia = (posEnfermero - posPaciente).Magnitude
	local enEnfermeria = Zones.Contiene(self.ZonaEnfermeria, posPaciente) and Zones.Contiene(self.ZonaEnfermeria, posEnfermero)
	if distancia > self.DistanciaAtender + 2 and not enEnfermeria then
		return self:Rechazar(player, "Atender", string.format("distancia %.1f", distancia),
			"Acércate a la persona (máx. " .. self.DistanciaAtender .. " studs) o atiéndela en " .. nombreZona(self.ZonaEnfermeria) .. ".")
	end
	local yaAtendido = self:EstaAtendido(objetivo)
	if not yaAtendido and self:CantidadAtendidos() >= self.AforoEnfermeria then
		return fallo("Aforo completo en enfermería (" .. self.AforoEnfermeria .. "/" .. self.AforoEnfermeria .. "). Da de alta a alguien primero.")
	end
	self.TokenAtencion = self.TokenAtencion + 1
	local token = self.TokenAtencion
	local hasta = os.time() + self.DuracionAtendidoSeg
	self.Atendidos[objetivo.UserId] = { Hasta = hasta, Token = token, Por = player.UserId, PorNombre = nombreDe(player), T = os.time() }
	pcall(function()
		objetivo:SetAttribute("Atendido", true)
	end)
	local userId = objetivo.UserId
	task.delay(self.DuracionAtendidoSeg, function()
		self:FinAtencion(userId, token, "fin")
	end)
	self:Enviar(objetivo, "Personal", { Sub = "Atendido", Atendido = true, Hasta = hasta, Duracion = self.DuracionAtendidoSeg, PorNombre = nombreDe(player) })
	self:Notificar(objetivo, "Enfermería: " .. nombreDe(player) .. " te ha atendido. Descansa unos minutos antes de volver a la actividad.", "exito", 6)
	self:DifundirAtendidos()
	self:Auditar("Sistema", player, "Enfermeria:Atender", nombreDe(objetivo) .. " (" .. objetivo.UserId .. ")")
	return exito({ UserId = objetivo.UserId, Nombre = nombreDe(objetivo), Hasta = hasta, Atendidos = self:ListaAtendidos(), Aforo = self.AforoEnfermeria, Renovado = yaAtendido })
end

function StaffService:AccionAlta(player, datos)
	local userId = datos.ObjetivoUserId
	if not self.Atendidos[userId] then
		return fallo("Esa persona no está siendo atendida.")
	end
	self:FinAtencion(userId, nil, "alta")
	local objetivo = jugadorPorId(userId)
	if objetivo then
		self:Notificar(objetivo, "Enfermería: has recibido el alta. ¡Que te vaya bien!", "info")
	end
	self:Auditar("Sistema", player, "Enfermeria:Alta", nombreDeId(userId))
	return exito({ Atendidos = self:ListaAtendidos(), Aforo = self.AforoEnfermeria })
end

function StaffService:AccionListaAtendidos()
	return exito({ Atendidos = self:ListaAtendidos(), Aforo = self.AforoEnfermeria })
end

function StaffService:ReponerBotiquinCompleto()
	self.Botiquin = {}
	for _, insumo in ipairs(self.InsumosBotiquin) do
		table.insert(self.Botiquin, { Id = insumo.Id, Nombre = insumo.Nombre, Stock = insumo.Max, Max = insumo.Max })
	end
end

function StaffService:BotiquinParaCliente()
	local lista = {}
	for _, insumo in ipairs(self.Botiquin) do
		table.insert(lista, copiar(insumo))
	end
	return lista
end

function StaffService:AccionBotiquin(player, datos)
	local sub = datos.Sub or "Ver"
	if sub == "Ver" then
		return exito({ Botiquin = self:BotiquinParaCliente() })
	end
	if sub == "Usar" then
		local insumo = nil
		for _, item in ipairs(self.Botiquin) do
			if item.Id == datos.InsumoId then
				insumo = item
			end
		end
		if not insumo then
			return fallo("Insumo desconocido.")
		end
		if insumo.Stock <= 0 then
			return fallo("No quedan " .. string.lower(insumo.Nombre) .. ". Repón el botiquín.")
		end
		local enEspera = self:EnCooldown(player, "BotiquinUsar", 1)
		if enEspera then
			return fallo("Espera un momento.")
		end
		self:MarcarCooldown(player, "BotiquinUsar")
		insumo.Stock = insumo.Stock - 1
		self:Auditar("Sistema", player, "Enfermeria:Botiquin", "Usa " .. insumo.Nombre .. " (quedan " .. insumo.Stock .. ")")
		return exito({ Botiquin = self:BotiquinParaCliente(), Usado = insumo.Nombre })
	end
	-- Reponer: todo al máximo, con gasto ficticio en el presupuesto.
	local enEspera, restante = self:EnCooldown(player, "BotiquinReponer", 60)
	if enEspera then
		return fallo("El botiquín se acaba de pedir; espera " .. math.ceil(restante) .. " s.")
	end
	local faltan = 0
	for _, item in ipairs(self.Botiquin) do
		faltan = faltan + (item.Max - item.Stock)
	end
	if faltan == 0 then
		return fallo("El botiquín ya está completo.")
	end
	self:MarcarCooldown(player, "BotiquinReponer")
	self:ReponerBotiquinCompleto()
	self:RegistrarGasto("BOTIQUIN", "Reposición del botiquín", 1, self.CosteReposicionBotiquin, nombreDe(player))
	self:Auditar("Sistema", player, "Enfermeria:Botiquin", "Botiquín repuesto (" .. faltan .. " unidades)")
	return exito({ Botiquin = self:BotiquinParaCliente(), Repuesto = faltan })
end

---------------------------------------------------------------------------------------------------
-- Secretaría: matrícula RP, certificados y asistencia (sin datos personales)
---------------------------------------------------------------------------------------------------
function StaffService:EmitirCertificado(objetivo, aula, emisor, tipo)
	self.ContadorCertificados = self.ContadorCertificados + 1
	local certificado = {
		Id = string.format("CERT-%04d", self.ContadorCertificados),
		UserId = objetivo.UserId,
		Nombre = nombreDe(objetivo),
		Aula = aula,
		AulaNombre = aula and nombreZona(aula) or "Sin aula",
		T = os.time(),
		Hora = self:HoraEscolar(),
		Emisor = nombreDe(emisor),
		Tipo = tipo or "Matrícula",
		Colegio = Config.NombreColegio,
	}
	table.insert(self.Certificados, certificado)
	limitarLista(self.Certificados, self.MaxCertificados)
	self.CertificadoPorUsuario[objetivo.UserId] = certificado
	return certificado
end

function StaffService:AccionMatricular(player, datos)
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, false, player)
	if not objetivo then
		return fallo(err)
	end
	if self:Cargo(objetivo) ~= "Estudiante" then
		return fallo("Solo se matricula a estudiantes.")
	end
	if datos.RoomId ~= nil and not esAula(datos.RoomId) then
		return fallo("El aula indicada no existe.")
	end
	local aula, errAula = self:AsignarAulaInterna(objetivo, datos.RoomId)
	if not aula then
		return fallo(errAula)
	end
	local certificado = self:EmitirCertificado(objetivo, aula, player, "Matrícula")
	self:Notificar(objetivo, "Secretaría: matrícula completada en el aula " .. aula .. " (" .. nombreZona(aula) .. "). Certificado " .. certificado.Id .. ".", "exito", 7)
	self:Enviar(objetivo, "Personal", { Sub = "Certificado", Certificado = copiar(certificado) })
	self:EnviarAPermiso("secretaria.matricular", "Personal", { Sub = "Certificado", Certificados = paraCliente(self.Certificados) })
	self:Auditar("Sistema", player, "Matricula", nombreDe(objetivo) .. " → " .. aula .. " (" .. certificado.Id .. ")")
	return exito({ Certificado = certificado })
end

function StaffService:AccionCertificado(player, datos)
	if (datos.Sub or "Listar") == "Listar" then
		return exito({ Certificados = paraCliente(self.Certificados) })
	end
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, false, player)
	if not objetivo then
		return fallo(err or "Elige a la persona.")
	end
	local enEspera = self:EnCooldown(player, "Certificado:" .. objetivo.UserId, 10)
	if enEspera then
		return fallo("Ya emitiste un certificado a esta persona hace un momento.")
	end
	self:MarcarCooldown(player, "Certificado:" .. objetivo.UserId)
	local salon = objetivo:GetAttribute("Salon")
	if typeof(salon) ~= "string" or not esAula(salon) then
		salon = nil
	end
	local tipo = "Constancia de estudios"
	if self:Cargo(objetivo) ~= "Estudiante" then
		tipo = "Constancia de servicio"
	end
	local certificado = self:EmitirCertificado(objetivo, salon, player, tipo)
	self:Notificar(objetivo, "Secretaría: se ha emitido tu " .. string.lower(tipo) .. " (" .. certificado.Id .. ").", "info")
	self:Enviar(objetivo, "Personal", { Sub = "Certificado", Certificado = copiar(certificado) })
	self:Auditar("Sistema", player, "Certificado", nombreDe(objetivo) .. " (" .. certificado.Id .. ")")
	return exito({ Certificado = certificado, Certificados = paraCliente(self.Certificados) })
end

-- Normaliza la asistencia de SchoolDayService a { Lista = { {Nombre, Estado} }, Resumen = { Estado = n } }.
local function normalizarAsistencia(asistencia)
	local lista = {}
	local resumen = {}
	local function agregar(userId, estado, nombre)
		local textoEstado = "—"
		if typeof(estado) == "string" then
			textoEstado = estado
		elseif typeof(estado) == "table" then
			textoEstado = tostring(estado.Estado or estado.Estatus or "—")
		elseif estado == true then
			textoEstado = "Presente"
		end
		local nombreFinal = nombre
		if typeof(nombreFinal) ~= "string" or nombreFinal == "" then
			nombreFinal = nombreDeId(userId)
		end
		table.insert(lista, { Nombre = Format.Truncar(nombreFinal, 40), Estado = Format.Truncar(textoEstado, 24) })
		resumen[textoEstado] = (resumen[textoEstado] or 0) + 1
	end
	if typeof(asistencia) == "table" then
		local base = asistencia.Registros or asistencia.Lista or asistencia.Estudiantes or asistencia.Asistencia or asistencia
		if typeof(base) == "table" then
			for clave, valor in pairs(base) do
				local idClave = tonumber(clave)
				if typeof(valor) == "table" and (valor.UserId ~= nil or valor.Nombre ~= nil) then
					agregar(valor.UserId, valor.Estado or valor, valor.Nombre)
				elseif idClave and idClave > 100 then
					agregar(idClave, valor, nil)
				end
			end
		end
	end
	table.sort(lista, function(a, b)
		return string.lower(a.Nombre) < string.lower(b.Nombre)
	end)
	return { Lista = lista, Resumen = resumen }
end

function StaffService:AccionAsistencia(player, datos)
	if not esAula(datos.RoomId) then
		return fallo("El aula indicada no existe.")
	end
	local ok, asistencia = self:Llamar("SchoolDayService", "Asistencia", datos.RoomId)
	if not ok then
		return fallo("La asistencia no está disponible (servicio de jornada ausente).")
	end
	local normal = normalizarAsistencia(asistencia)
	normal.RoomId = datos.RoomId
	normal.AulaNombre = nombreZona(datos.RoomId)
	normal.Estado = self:EstadoJornada()
	if typeof(asistencia) == "table" then
		normal.Clase = typeof(asistencia.NombreClase) == "string" and asistencia.NombreClase or nil
		normal.Materia = typeof(asistencia.MateriaNombre) == "string" and asistencia.MateriaNombre or nil
		normal.Activa = asistencia.Activa == true
	end
	return exito(normal)
end

---------------------------------------------------------------------------------------------------
-- Finanzas: presupuesto virtual, auditoría económica y precios de cafetería
---------------------------------------------------------------------------------------------------
-- Suma de las ventas de cafetería (formato tolerante: Total / Monto / Importe / Recibo.Total).
function StaffService:IngresosCafeteria()
	local ok, ventas = self:Llamar("CafeteriaService", "Ventas", 500)
	local total, cantidad = 0, 0
	if ok and typeof(ventas) == "table" then
		for _, venta in pairs(ventas) do
			if typeof(venta) == "table" then
				local monto = tonumber(venta.Total) or tonumber(venta.Monto) or tonumber(venta.Importe)
				if monto == nil and typeof(venta.Recibo) == "table" then
					monto = tonumber(venta.Recibo.Total)
				end
				if finito(monto) and monto > 0 then
					total = total + monto
					cantidad = cantidad + 1
				end
			end
		end
	end
	return total, cantidad, ok
end

function StaffService:SaldoPresupuesto()
	local ingresos = self:IngresosCafeteria()
	return self.PresupuestoInicial + ingresos - self.GastadoTotal
end

function StaffService:RegistrarGasto(conceptoId, nombre, cantidad, monto, porNombre)
	local gasto = { T = os.time(), Concepto = conceptoId, Nombre = nombre, Cantidad = cantidad, Monto = monto, Por = porNombre }
	table.insert(self.Gastos, gasto)
	limitarLista(self.Gastos, 100)
	self.GastadoTotal = self.GastadoTotal + monto
	return gasto
end

function StaffService:ResumenPresupuesto()
	local ingresos, ventas, hayCafeteria = self:IngresosCafeteria()
	local gastos = {}
	for i = #self.Gastos, math.max(1, #self.Gastos - 19), -1 do
		table.insert(gastos, copiar(self.Gastos[i]))
	end
	return {
		Inicial = self.PresupuestoInicial,
		Ingresos = ingresos,
		Ventas = ventas,
		CafeteriaDisponible = hayCafeteria,
		Gastos = self.GastadoTotal,
		Saldo = self.PresupuestoInicial + ingresos - self.GastadoTotal,
		DetalleGastos = gastos,
		Conceptos = paraCliente(self.ConceptosGasto),
		Moneda = (Config.Economia and Config.Economia.MonedaSimbolo) or "◎",
	}
end

function StaffService:AccionPresupuesto(player, datos)
	if (datos.Sub or "Ver") == "Ver" then
		return exito(self:ResumenPresupuesto())
	end
	local concepto = nil
	for _, item in ipairs(self.ConceptosGasto) do
		if item.Id == datos.Concepto then
			concepto = item
		end
	end
	if not concepto then
		return fallo("Concepto de gasto desconocido.")
	end
	local cantidad = datos.Cantidad or 1
	local monto = concepto.Precio * cantidad
	local saldo = self:SaldoPresupuesto()
	if monto > saldo then
		return fallo("Presupuesto insuficiente: el gasto (" .. Format.Moneda(monto) .. ") supera el saldo (" .. Format.Moneda(saldo) .. ").")
	end
	local enEspera = self:EnCooldown(player, "Gasto", 3)
	if enEspera then
		return fallo("Espera un momento antes de registrar otro gasto.")
	end
	self:MarcarCooldown(player, "Gasto")
	self:RegistrarGasto(concepto.Id, concepto.Nombre, cantidad, monto, nombreDe(player))
	self:Auditar("Economia", player, "Presupuesto:Gasto", concepto.Nombre .. " x" .. cantidad .. " = " .. monto)
	local resumen = self:ResumenPresupuesto()
	resumen.Registrado = concepto.Nombre .. " x" .. cantidad
	return exito(resumen)
end

function StaffService:AccionAuditoriaEconomia()
	local datos = {}
	local okT, transacciones = self:Llamar("EconomyService", "Transacciones", 50)
	if okT and typeof(transacciones) == "table" then
		datos.Transacciones = paraCliente(transacciones)
	end
	local okR, resumen = self:Llamar("EconomyService", "ResumenGlobal")
	if okR and typeof(resumen) == "table" then
		datos.Resumen = paraCliente(resumen)
	end
	local okV, ventas = self:Llamar("CafeteriaService", "Ventas", 20)
	if okV and typeof(ventas) == "table" then
		datos.VentasCafeteria = paraCliente(ventas)
	end
	local okC, comedor = self:Llamar("FoodService", "Snapshot")
	if not okC or typeof(comedor) ~= "table" then
		okC, comedor = self:Llamar("FoodService", "Estado")
	end
	if okC and typeof(comedor) == "table" then
		datos.Comedor = paraCliente(comedor)
	end
	datos.Presupuesto = self:ResumenPresupuesto()
	if datos.Transacciones == nil and datos.Resumen == nil then
		datos.Aviso = "El servicio de economía no está disponible; solo se muestra el presupuesto."
	end
	return exito(datos)
end

-- Lista de productos con precio y stock (CafeteriaService:Inventario o catálogo).
function StaffService:ProductosCafeteria()
	local lista = {}
	local vistos = {}
	local ok, inventario = self:Llamar("CafeteriaService", "Inventario")
	if ok and typeof(inventario) == "table" then
		local fuente = inventario.Productos or inventario.Inventario or inventario
		if typeof(fuente) == "table" then
			for clave, valor in pairs(fuente) do
				if typeof(valor) == "table" then
					local id = valor.Id or valor.ProductoId
					if id == nil and typeof(clave) == "string" then
						id = clave
					end
					if typeof(id) == "string" and not vistos[id] then
						vistos[id] = true
						local catalogo = typeof(Catalogs.Producto) == "function" and Catalogs.Producto(id) or nil
						table.insert(lista, {
							Id = id,
							Nombre = tostring(valor.Nombre or (catalogo and catalogo.Nombre) or id),
							Precio = tonumber(valor.Precio) or (catalogo and catalogo.Precio) or 0,
							Stock = tonumber(valor.Stock),
						})
					end
				end
			end
		end
	end
	if #lista == 0 and typeof(Catalogs.Productos) == "table" then
		for _, producto in ipairs(Catalogs.Productos) do
			table.insert(lista, { Id = producto.Id, Nombre = producto.Nombre, Precio = producto.Precio, Stock = producto.Stock, Catalogo = true })
		end
	end
	table.sort(lista, function(a, b)
		return a.Nombre < b.Nombre
	end)
	return lista
end

function StaffService:AccionPrecioCafeteria(player, datos)
	local sub = datos.Sub
	if sub == nil then
		if datos.ProductoId ~= nil then
			sub = "Fijar"
		else
			sub = "Ver"
		end
	end
	local minimo = tonumber(CONFIG_CAFETERIA.PrecioMin) or 1
	local maximo = tonumber(CONFIG_CAFETERIA.PrecioMax) or 200
	if sub == "Ver" then
		return exito({ Productos = self:ProductosCafeteria(), Min = minimo, Max = maximo })
	end
	local productoId = datos.ProductoId
	local precio = datos.Precio
	if typeof(productoId) ~= "string" then
		return fallo("Elige un producto.")
	end
	local existe = false
	for _, producto in ipairs(self:ProductosCafeteria()) do
		if producto.Id == productoId then
			existe = true
		end
	end
	if not existe then
		return fallo("Producto desconocido.")
	end
	if typeof(precio) ~= "number" or math.floor(precio) ~= precio or precio < minimo or precio > maximo then
		return fallo(string.format("El precio debe ser un número entero entre %d y %d.", minimo, maximo))
	end
	local metodo = nil
	for _, nombre in ipairs({ "AjustarPrecio", "FijarPrecio" }) do
		if metodo == nil and self:Expone("CafeteriaService", nombre) then
			metodo = nombre
		end
	end
	if not metodo then
		-- El cliente reintenta por CafeteriaManage { Accion = "Precio" } (permiso cafeteria.precios).
		return fallo("delegar:CafeteriaManage")
	end
	local ok, r1, r2 = self:Llamar("CafeteriaService", metodo, productoId, precio, player)
	if not ok then
		return fallo("La cafetería no pudo cambiar el precio.")
	end
	if r1 == false then
		return fallo(tostring(r2 or "La cafetería rechazó el precio."))
	end
	if typeof(r1) == "table" and r1.ok == false then
		return fallo(tostring(r1.error or "La cafetería rechazó el precio."))
	end
	self:Auditar("Economia", player, "PrecioCafeteria", productoId .. " = " .. precio)
	return exito({ ProductoId = productoId, Precio = precio, Productos = self:ProductosCafeteria(), Min = minimo, Max = maximo })
end

---------------------------------------------------------------------------------------------------
-- Recepción y seguridad: visitas, incidencias y portón
---------------------------------------------------------------------------------------------------
function StaffService:VisitasParaCliente()
	local lista = {}
	for i = #self.Visitas, 1, -1 do
		table.insert(lista, copiar(self.Visitas[i]))
	end
	return lista
end

function StaffService:AccionRegistrarVisita(player, datos)
	local objetivo, err = self:Objetivo(datos.ObjetivoUserId, false, player)
	if not objetivo then
		return fallo(err)
	end
	local okTexto, motivo = self:Filtrar(player, datos.Motivo, 80)
	if not okTexto then
		return fallo(motivo)
	end
	if motivo == "" then
		return fallo("Escribe el motivo de la visita.")
	end
	self.ContadorVisitas = self.ContadorVisitas + 1
	local visita = {
		Id = self.ContadorVisitas, UserId = objetivo.UserId, Nombre = nombreDe(objetivo), Motivo = motivo,
		Hora = self:HoraEscolar(), T = os.time(), Registro = nombreDe(player),
	}
	table.insert(self.Visitas, visita)
	limitarLista(self.Visitas, self.MaxVisitas)
	local lista = self:VisitasParaCliente()
	self:EnviarAPermiso("seguridad.acceso", "Personal", { Sub = "Visita", Visitas = lista, Visita = copiar(visita) })
	self:Notificar(objetivo, "Recepción: has quedado registrado/a como visita (" .. motivo .. "). ¡Bienvenido/a al " .. tostring(Config.NombreCorto or "colegio") .. "!", "info")
	self:Auditar("Sistema", player, "Visita", visita.Nombre .. ": " .. motivo)
	return exito({ Visita = visita, Visitas = lista })
end

function StaffService:AccionListaVisitas()
	return exito({ Visitas = self:VisitasParaCliente() })
end

function StaffService:AccionIncidencia(player, datos)
	local okTexto, descripcion = self:Filtrar(player, datos.Descripcion, 160)
	if not okTexto then
		return fallo(descripcion)
	end
	if Format.Longitud(descripcion) < 3 then
		return fallo("Describe la incidencia.")
	end
	local implicado = nil
	if datos.ObjetivoUserId ~= nil then
		implicado = jugadorPorId(datos.ObjetivoUserId)
		if not implicado then
			return fallo("La persona implicada no está conectada.")
		end
	end
	local posicion = posicionDe(player)
	local zona = posicion and Zones.ZonaDe(posicion) or nil
	local ubicacion = zona and tostring(zona.Nombre or zona.Id) or "Fuera de las zonas del colegio"
	self.ContadorIncidencias = self.ContadorIncidencias + 1
	local incidencia = {
		Id = self.ContadorIncidencias, T = os.time(), Hora = self:HoraEscolar(), Descripcion = descripcion,
		Ubicacion = ubicacion, Reporta = nombreDe(player), ReportaId = player.UserId,
		Implicado = implicado and nombreDe(implicado) or nil, ImplicadoId = implicado and implicado.UserId or nil,
	}
	table.insert(self.Incidencias, incidencia)
	limitarLista(self.Incidencias, 50)
	-- Aviso a moderación (moderacion.basica): canal Moderacion + toast.
	local avisados = 0
	for _, moderador in ipairs(self:JugadoresCon("moderacion.basica")) do
		if moderador ~= player then
			self:Enviar(moderador, "Moderacion", {
				Tipo = "Incidencia", Id = incidencia.Id, Descripcion = descripcion, Ubicacion = ubicacion,
				Reporta = incidencia.Reporta, Implicado = incidencia.Implicado, ImplicadoUserId = incidencia.ImplicadoId,
			})
			self:Notificar(moderador, "Incidencia de seguridad en " .. ubicacion .. ": " .. descripcion, "aviso", 8)
			avisados = avisados + 1
		end
	end
	self:EnviarAPermiso("seguridad.acceso", "Personal", { Sub = "Incidencia", Incidencia = copiar(incidencia) }, player)
	-- Persistencia como reporte de soporte si ReportService lo permite (sin bloquear si falla).
	local okReporte, creado = self:Llamar("ReportService", "Crear", player, "Abuso", Format.Truncar(ubicacion, 60),
		Format.Truncar("[Seguridad] " .. descripcion .. (incidencia.Implicado and (" · Implicado: " .. incidencia.Implicado) or ""), 300))
	self:Auditar("Moderacion", player, "Incidencia", ubicacion .. ": " .. descripcion .. (incidencia.Implicado and (" · " .. incidencia.Implicado) or ""))
	return exito({ Incidencia = incidencia, Avisados = avisados, Reporte = okReporte and creado ~= false })
end

function StaffService:AccionPorton(player, datos)
	local puerta = self.PuertaPorton
	if datos.Bloquear == nil then
		local ok, estado = self:Llamar("DoorService", "Estado", puerta)
		if not ok then
			return fallo("El control de puertas no está disponible.")
		end
		return exito({ Puerta = puerta, Estado = paraCliente(estado) })
	end
	local ok, r1, r2 = self:Llamar("DoorService", "Bloquear", puerta, datos.Bloquear == true, player)
	if not ok then
		if r1 == "sin_servicio" or r1 == "sin_metodo" then
			return fallo("El control de puertas no está disponible.")
		end
		return fallo("No se pudo cambiar el portón.")
	end
	if r1 == false or (typeof(r1) == "table" and r1.ok == false) then
		local mensaje = tostring((typeof(r1) == "table" and r1.error) or r2 or "No se pudo cambiar el portón.")
		-- DoorService exige estar junto a la puerta cuando actúa un jugador (control físico del portón).
		if string.find(mensaje, "Acércate", 1, true) then
			local def = MapaLogico.Puertas and MapaLogico.Puertas[puerta]
			local distancia = (Config.Distancias and Config.Distancias.Puerta) or 14
			mensaje = "Acércate al portón principal (" .. nombreZona(def and def.Zona or "ENTRADA") .. ", máx. " .. distancia .. " studs) para operarlo."
		end
		return fallo(mensaje)
	end
	local okEstado, estado = self:Llamar("DoorService", "Estado", puerta)
	local texto = datos.Bloquear and "bloqueado" or "desbloqueado"
	self:Auditar("Sistema", player, "Porton", "Portón principal " .. texto)
	self:EnviarAPermiso("seguridad.acceso", "Notificacion", { Texto = "Seguridad: " .. nombreDe(player) .. " ha " .. texto .. " el portón principal.", Nivel = "info", Tipo = "info" }, player)
	return exito({ Puerta = puerta, Bloqueado = datos.Bloquear == true, Estado = okEstado and paraCliente(estado) or nil })
end

---------------------------------------------------------------------------------------------------
-- Limpieza: tareas temporales en DESCANSO / ALMUERZO
---------------------------------------------------------------------------------------------------
function StaffService:ConectarJornada()
	local SchoolDayService = self:Servicio("SchoolDayService")
	if not SchoolDayService then
		warn(PREFIJO .. " SchoolDayService no disponible: no habrá tareas de limpieza automáticas.")
		return
	end
	local function conectar(senal, fn)
		if senal == nil then
			return false
		end
		local ok, conexion = pcall(function()
			return senal:Connect(fn)
		end)
		if ok and conexion then
			table.insert(self.Conexiones, conexion)
			return true
		end
		return false
	end
	local conEstado = conectar(SchoolDayService.EstadoCambiado, function(estado)
		self:AlCambiarEstado(estado)
	end)
	conectar(SchoolDayService.JornadaTerminada, function()
		self:FinDeJornada("JornadaTerminada")
	end)
	-- Estado inicial (la jornada puede estar ya en DESCANSO/ALMUERZO).
	task.defer(function()
		self:AlCambiarEstado(self:EstadoJornada())
	end)
	if not conEstado then
		-- Sin señal: sondeo ligero del estado cada 3 s.
		task.spawn(function()
			while self.Activo do
				task.wait(3)
				if not self.Activo then
					break
				end
				local ok, estado = self:Llamar("SchoolDayService", "Estado")
				if ok and typeof(estado) == "string" then
					self:AlCambiarEstado(estado)
				end
			end
		end)
	end
end

-- Reinicio de la memoria por jornada (protegido contra dobles disparos).
function StaffService:FinDeJornada(motivo)
	local ahora = os.clock()
	if ahora - self.UltimoReinicioJornada < 30 then
		return
	end
	self.UltimoReinicioJornada = ahora
	self:ReiniciarMemoriaJornada()
	self:ReponerBotiquinCompleto()
	self.Propuesta = nil
	self:Auditar("Sistema", nil, "StaffService", "Memoria de la jornada reiniciada (" .. tostring(motivo) .. ")")
end

function StaffService:AlCambiarEstado(estado)
	if typeof(estado) ~= "string" or estado == self.EstadoActual then
		return
	end
	self.EstadoActual = estado
	if estado == "REINICIO" then
		self:FinDeJornada("REINICIO")
	end
	if PERIODOS_LIMPIEZA[estado] then
		self.TokenPeriodo = self.TokenPeriodo + 1
		self.PeriodoLimpieza = estado
		self.GeneradasPeriodo = 0
		self.CompletadasPeriodo = 0
		self.LimpiezaPorJugador = {}
		self:LimpiarTareas()
		local creadas = self:GenerarTareas()
		if creadas > 0 then
			for _, limpiador in ipairs(self:JugadoresCon("limpieza.tareas")) do
				self:Notificar(limpiador, "Comienza " .. string.lower(TimetableDefinitions.Nombre(estado)) .. ": hay " .. creadas .. " tareas de limpieza. Ábrelas con la tecla P o con «Panel de cargo».", "info", 6)
			end
		end
	elseif self.PeriodoLimpieza ~= nil then
		self.PeriodoLimpieza = nil
		self.TokenPeriodo = self.TokenPeriodo + 1
		self:LimpiarTareas()
		self:DifundirTareas()
	end
end

function StaffService:AlCambiarCargo(player)
	if not esJugador(player) then
		return
	end
	if self:Tiene(player, "limpieza.tareas") then
		self:Enviar(player, "Personal", self:DatosTareas(player))
	end
end

function StaffService:AlSalir(player)
	local userId = player.UserId
	self.Cooldowns[userId] = nil
	if self.Atendidos[userId] then
		self.Atendidos[userId] = nil
		self:DifundirAtendidos()
	end
end

function StaffService:CarpetaLimpieza()
	if self.CarpetaTareas and self.CarpetaTareas.Parent ~= nil then
		return self.CarpetaTareas
	end
	local raiz = workspace:FindFirstChild(NOMBRE_CARPETA_MAPA)
	if not raiz then
		raiz = Instance.new("Folder")
		raiz.Name = NOMBRE_CARPETA_MAPA
		raiz.Parent = workspace
	end
	local carpeta = raiz:FindFirstChild("Limpieza")
	if not carpeta then
		carpeta = Instance.new("Folder")
		carpeta.Name = "Limpieza"
		carpeta.Parent = raiz
	end
	self.CarpetaTareas = carpeta
	return carpeta
end

-- Definiciones de tareas (Catalogs.TareasLimpieza con zonas existentes; si no, zonas de respaldo).
function StaffService:DefinicionesLimpieza()
	local lista = {}
	if typeof(Catalogs.TareasLimpieza) == "table" then
		for _, def in ipairs(Catalogs.TareasLimpieza) do
			if typeof(def) == "table" and typeof(def.Zona) == "string" and Zones.Zona(def.Zona) then
				local recompensa = tonumber(def.Recompensa) or self.RecompensaLimpieza
				table.insert(lista, {
					Id = tostring(def.Id or ("LIMP_" .. def.Zona)), Zona = def.Zona,
					Nombre = tostring(def.Nombre or ("Limpiar: " .. nombreZona(def.Zona))),
					Recompensa = math.clamp(math.floor(recompensa), 0, 50),
				})
			end
		end
	end
	if #lista == 0 then
		for _, zona in ipairs(ZONAS_LIMPIEZA_RESPALDO) do
			if Zones.Zona(zona) then
				table.insert(lista, { Id = "LIMP_" .. zona, Zona = zona, Nombre = "Limpiar: " .. nombreZona(zona), Recompensa = self.RecompensaLimpieza })
			end
		end
	end
	return lista
end

function StaffService:CantidadTareas()
	local n = 0
	for _ in pairs(self.Tareas) do
		n = n + 1
	end
	return n
end

function StaffService:TareaCerca(posicion, distancia)
	for _, tarea in pairs(self.Tareas) do
		if (tarea.Posicion - posicion).Magnitude < distancia then
			return true
		end
	end
	return false
end

-- Punto a ras de suelo (Y de piso + 1) dentro de la zona; usa un rayo hacia abajo para encontrar el piso real.
function StaffService:PuntoTarea(zonaId)
	local zona = Zones.Zona(zonaId)
	if not zona then
		return nil
	end
	local sueloY = Zones.AlturasDe(zona)
	local excluir = {}
	local carpetaMapa = workspace:FindFirstChild(NOMBRE_CARPETA_MAPA)
	if carpetaMapa then
		table.insert(excluir, carpetaMapa)
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excluir, player.Character)
		end
	end
	local parametros = RaycastParams.new()
	local okFiltro = pcall(function()
		parametros.FilterType = Enum.RaycastFilterType.Exclude
	end)
	if not okFiltro then
		pcall(function()
			parametros.FilterType = Enum.RaycastFilterType.Blacklist
		end)
	end
	parametros.FilterDescendantsInstances = excluir
	parametros.IgnoreWater = true
	pcall(function()
		parametros.RespectCanCollide = true
	end)
	local intentos = 6
	for intento = 1, intentos do
		local base = Zones.PuntoAleatorio(zona, 3)
		if base then
			local candidato = nil
			local origen = Vector3.new(base.X, sueloY + 4, base.Z)
			local okRayo, impacto = pcall(function()
				return workspace:Raycast(origen, Vector3.new(0, -10, 0), parametros)
			end)
			if okRayo and impacto and math.abs(impacto.Position.Y - sueloY) <= 2.5 then
				candidato = Vector3.new(base.X, impacto.Position.Y + 1, base.Z)
			elseif intento == intentos then
				candidato = Vector3.new(base.X, sueloY + 1, base.Z)
			end
			if candidato and (intento == intentos or not self:TareaCerca(candidato, self.SeparacionTareas)) then
				return candidato
			end
		end
	end
	return nil
end

function StaffService:CrearTarea(def)
	local posicion = self:PuntoTarea(def.Zona)
	if not posicion then
		return nil
	end
	self.ContadorTareas = self.ContadorTareas + 1
	local id = def.Id .. "_" .. self.ContadorTareas
	local ok, parte, prompt = pcall(function()
		local p = Instance.new("Part")
		p.Name = "Tarea_" .. id
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Transparency = 1
		p.Size = Vector3.new(2, 0.4, 2)
		p.CFrame = CFrame.new(posicion)
		p:SetAttribute("TareaId", id)
		p:SetAttribute("Zona", def.Zona)
		p:SetAttribute("RPTipo", "Limpieza")
		p:SetAttribute("RPId", id)
		local pr = Instance.new("ProximityPrompt")
		pr.Name = "PromptLimpieza"
		pr.ActionText = "Limpiar"
		pr.ObjectText = Format.Truncar(def.Nombre, 40)
		pr.HoldDuration = self.HoldLimpiezaSeg
		pr.MaxActivationDistance = self.DistanciaPromptLimpieza
		pr.RequiresLineOfSight = false
		pr:SetAttribute("RPTipo", "Limpieza")
		pr:SetAttribute("RPId", id)
		pr:SetAttribute("RPAccion", "Limpiar")
		pr.Parent = p
		return p, pr
	end)
	if not ok or not parte then
		warn(PREFIJO .. " No se pudo crear la tarea de limpieza " .. id .. ": " .. tostring(parte))
		return nil
	end
	pcall(CollectionService.AddTag, CollectionService, parte, self.TagTarea)
	local tarea = {
		Id = id, DefId = def.Id, Zona = def.Zona, ZonaNombre = nombreZona(def.Zona), Nombre = def.Nombre,
		Recompensa = def.Recompensa, Posicion = posicion, Parte = parte, Prompt = prompt, Creada = os.time(),
		Completada = false, Periodo = self.TokenPeriodo,
	}
	tarea.Conexion = prompt.Triggered:Connect(function(player)
		self:AlActivarTarea(player, id)
	end)
	parte.Parent = self:CarpetaLimpieza()
	self.Tareas[id] = tarea
	table.insert(self.OrdenTareas, id)
	self.GeneradasPeriodo = self.GeneradasPeriodo + 1
	return tarea
end

-- Crea tareas hasta MaxTareas (sin repetir definición activa). Devuelve cuántas creó.
function StaffService:GenerarTareas()
	if not self.PeriodoLimpieza then
		return 0
	end
	local activas = {}
	for _, tarea in pairs(self.Tareas) do
		activas[tarea.DefId] = true
	end
	local creadas = 0
	for _, def in ipairs(barajar(self:DefinicionesLimpieza())) do
		if self:CantidadTareas() < self.MaxTareas and self.GeneradasPeriodo < self.TareasPorPeriodo and not activas[def.Id] then
			if self:CrearTarea(def) then
				creadas = creadas + 1
				activas[def.Id] = true
			end
		end
	end
	if creadas > 0 then
		self:DifundirTareas()
	end
	return creadas
end

function StaffService:EliminarTarea(id)
	local tarea = self.Tareas[id]
	if not tarea then
		return
	end
	self.Tareas[id] = nil
	for i = #self.OrdenTareas, 1, -1 do
		if self.OrdenTareas[i] == id then
			table.remove(self.OrdenTareas, i)
		end
	end
	if tarea.Conexion then
		pcall(function()
			tarea.Conexion:Disconnect()
		end)
	end
	if tarea.Parte then
		pcall(function()
			tarea.Parte:Destroy()
		end)
	end
end

function StaffService:LimpiarTareas()
	local ids = {}
	for id in pairs(self.Tareas) do
		table.insert(ids, id)
	end
	for _, id in ipairs(ids) do
		self:EliminarTarea(id)
	end
	-- Restos de una ejecución anterior (p. ej. tras recargar el servicio).
	if self.CarpetaTareas and self.CarpetaTareas.Parent ~= nil then
		for _, hijo in ipairs(self.CarpetaTareas:GetChildren()) do
			pcall(function()
				hijo:Destroy()
			end)
		end
	end
end

-- Lista pública de tareas (sin instancias).
function StaffService:ListaTareas()
	local lista = {}
	for _, id in ipairs(self.OrdenTareas) do
		local tarea = self.Tareas[id]
		if tarea and not tarea.Completada then
			table.insert(lista, {
				Id = tarea.Id, Nombre = tarea.Nombre, Zona = tarea.Zona, ZonaNombre = tarea.ZonaNombre,
				Posicion = tarea.Posicion, Recompensa = tarea.Recompensa,
			})
		end
	end
	return lista
end

function StaffService:DatosTareas(player)
	return {
		Sub = "Tareas",
		Tareas = self:ListaTareas(),
		Activo = self.PeriodoLimpieza ~= nil,
		Periodo = self.PeriodoLimpieza,
		PeriodoNombre = self.PeriodoLimpieza and TimetableDefinitions.Nombre(self.PeriodoLimpieza) or nil,
		Completadas = esJugador(player) and (self.LimpiezaPorJugador[player.UserId] or 0) or 0,
		Maximo = self.MaxTareasJugador,
		CompletadasPeriodo = self.CompletadasPeriodo,
	}
end

function StaffService:DifundirTareas()
	for _, limpiador in ipairs(self:JugadoresCon("limpieza.tareas")) do
		self:Enviar(limpiador, "Personal", self:DatosTareas(limpiador))
	end
end

function StaffService:AlActivarTarea(player, id)
	local tarea = self.Tareas[id]
	if not esJugador(player) or not tarea or tarea.Completada then
		return
	end
	if not self:Tiene(player, "limpieza.tareas") then
		self:Notificar(player, "Solo el personal de limpieza puede completar esta tarea.", "aviso")
		return
	end
	local posicion = posicionDe(player)
	if not posicion or (posicion - tarea.Posicion).Magnitude > self.DistanciaPromptLimpieza + 6 then
		self:Auditar("Remoto", player, "Limpieza:" .. id, "rechazado: distancia")
		return
	end
	local hechas = self.LimpiezaPorJugador[player.UserId] or 0
	if hechas >= self.MaxTareasJugador then
		self:Notificar(player, "Ya completaste " .. hechas .. " tareas en este periodo; deja las demás a tus compañeros/as.", "aviso")
		return
	end
	local enEspera = self:EnCooldown(player, "Limpieza", 2)
	if enEspera then
		return
	end
	self:MarcarCooldown(player, "Limpieza")
	-- Se marca antes de cualquier espera: dos activaciones simultáneas no cobran dos veces.
	tarea.Completada = true
	self.LimpiezaPorJugador[player.UserId] = hechas + 1
	self.CompletadasPeriodo = self.CompletadasPeriodo + 1
	local tokenPeriodo = tarea.Periodo
	self:EliminarTarea(id)

	local okEco, acreditado, saldo = self:Llamar("EconomyService", "Acreditar", player, tarea.Recompensa, "TareaLimpieza", tarea.Nombre)
	local mensaje = "Tarea completada: " .. tarea.Nombre .. "."
	if okEco and acreditado ~= false then
		mensaje = mensaje .. " +" .. Format.Moneda(tarea.Recompensa)
	elseif okEco then
		mensaje = mensaje .. " (sin monedas: límite diario alcanzado)"
	else
		mensaje = mensaje .. " (la economía no está disponible)"
	end
	self:Notificar(player, mensaje, "exito")
	-- Progreso del perfil (Progreso.TareasLimpieza).
	local okPerfil, perfil = self:Llamar("DataService", "Obtener", player)
	if okPerfil and typeof(perfil) == "table" and typeof(perfil.Progreso) == "table" then
		perfil.Progreso.TareasLimpieza = (tonumber(perfil.Progreso.TareasLimpieza) or 0) + 1
		self:Llamar("DataService", "Marcar", player)
	end
	self:Auditar("Economia", player, "Limpieza", tarea.Nombre .. " (+" .. tostring(tarea.Recompensa) .. ", saldo " .. tostring(saldo) .. ")")
	self:DifundirTareas()

	-- Reposición diferida si el periodo sigue activo y no se ha alcanzado el tope de tareas del periodo.
	task.delay(self.ReposicionTareaSeg, function()
		if self.Activo and self.PeriodoLimpieza ~= nil and self.TokenPeriodo == tokenPeriodo then
			self:GenerarTareas()
		end
	end)
end

function StaffService:AccionTareasPendientes(player)
	local datos = self:DatosTareas(player)
	datos.Sub = nil
	return exito(datos)
end

function StaffService:AccionCompletarTarea()
	return fallo("Las tareas se completan en el marcador: acércate y mantén pulsado «Limpiar».")
end

-- Tareas activas (otros servicios).
function StaffService:Tareas()
	return self:ListaTareas()
end

---------------------------------------------------------------------------------------------------
-- Snapshot por jugador (StateSnapshot.Personal y acción MiEstado)
---------------------------------------------------------------------------------------------------
function StaffService:Snapshot(player)
	if not esJugador(player) then
		return nil
	end
	local registro = self.Atendidos[player.UserId]
	local atendido = registro ~= nil and os.time() < registro.Hasta
	local datos = {
		Atendido = atendido,
		AtendidoHasta = atendido and registro.Hasta or nil,
		EventoActivo = self:EventoActivo(),
	}
	if self:Tiene(player, "seguridad.acceso") then
		datos.Visitas = self:VisitasParaCliente()
	end
	if self:Tiene(player, "limpieza.tareas") then
		local tareas = self:DatosTareas(player)
		tareas.Sub = nil
		datos.Tareas = tareas.Tareas
		datos.Limpieza = tareas
	end
	if self:Tiene(player, "enfermeria.atender") then
		datos.Atendidos = self:ListaAtendidos()
	end
	if self:Tiene(player, "orientacion.agenda") then
		datos.Citas = self:CitasParaCliente()
	end
	for _, cita in ipairs(self.Citas) do
		if cita.UserId == player.UserId and cita.Estado == "Pendiente" then
			datos.MiCita = copiar(cita)
		end
	end
	local certificado = self.CertificadoPorUsuario[player.UserId]
	if certificado then
		datos.Certificado = copiar(certificado)
	end
	return datos
end

return StaffService
