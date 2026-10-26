--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.TimetableDefinitions
	Tipo: ModuleScript
	Periodos de la jornada escolar (máquina de estados de SchoolDayService), materias y tolerancias.
	El reloj escolar avanza desde la HoraEscolar de cada periodo hasta la del siguiente de forma lineal
	con el tiempo real del periodo (ver HoraEscolarEn).
]]

local TimetableDefinitions = {}

-- Estados en el orden en que se suceden. Tras REINICIO vuelve a ESPERA.
TimetableDefinitions.Estados = {
	"ESPERA", "ENTRADA", "CLASE_1", "TRANSICION", "DESCANSO", "CLASE_2", "ALMUERZO", "CLASE_3", "SALIDA", "REINICIO",
}

-- Duracion en segundos reales (por defecto); Nombre visible; HoraEscolar "HH:MM" al inicio del periodo.
-- EsClase: periodo lectivo con asistencia; ComidaGratis: el comedor reparte raciones; Deporte: cancha activa.
TimetableDefinitions.Periodos = {
	{ Estado = "ESPERA", Duracion = 60, Nombre = "Esperando inicio", HoraEscolar = "06:45" },
	{ Estado = "ENTRADA", Duracion = 90, Nombre = "Entrada", HoraEscolar = "07:00" },
	{ Estado = "CLASE_1", Duracion = 300, Nombre = "1ª clase", HoraEscolar = "07:15", EsClase = true, Materia = "MAT" },
	{ Estado = "TRANSICION", Duracion = 45, Nombre = "Cambio de clase", HoraEscolar = "08:15" },
	{ Estado = "DESCANSO", Duracion = 150, Nombre = "Descanso", HoraEscolar = "08:30", ComidaGratis = true, Deporte = true },
	{ Estado = "CLASE_2", Duracion = 300, Nombre = "2ª clase", HoraEscolar = "09:00", EsClase = true, Materia = "ESP" },
	{ Estado = "ALMUERZO", Duracion = 180, Nombre = "Almuerzo", HoraEscolar = "10:30", ComidaGratis = true, Deporte = true },
	{ Estado = "CLASE_3", Duracion = 300, Nombre = "3ª clase", HoraEscolar = "11:15", EsClase = true, Materia = "CIE" },
	{ Estado = "SALIDA", Duracion = 90, Nombre = "Salida", HoraEscolar = "12:30" },
	-- HoraEscolarFin: hora en la que termina el último periodo (el siguiente, ESPERA, es del día siguiente).
	{ Estado = "REINICIO", Duracion = 20, Nombre = "Reinicio de jornada", HoraEscolar = "12:45", HoraEscolarFin = "13:00" },
}

-- Materias disponibles (código -> nombre visible). CoordinadorAcademico puede cambiar la materia de cada clase.
TimetableDefinitions.Materias = {
	MAT = "Matemáticas",
	ESP = "Español",
	CIE = "Ciencias",
	SOC = "Sociales",
	ING = "Inglés",
	TEC = "Tecnología",
	EDF = "Educación física",
	ART = "Artes",
}

-- Códigos de materia en orden estable (selectores de la interfaz).
TimetableDefinitions.OrdenMaterias = { "MAT", "ESP", "CIE", "SOC", "ING", "TEC", "EDF", "ART" }

TimetableDefinitions.ToleranciaTardanzaSeg = 60 -- Segundos tras el inicio de la clase para contar como Presente.
TimetableDefinitions.MarcarAusenciaSeg = 180 -- Segundos tras el inicio de la clase para marcar Ausente.

---------------------------------------------------------------------------------------------------
-- Índices y totales (calculados una vez)
---------------------------------------------------------------------------------------------------
local indicePorEstado = {}
local inicioAcumulado = {}
local total = 0
for i, periodo in ipairs(TimetableDefinitions.Periodos) do
	assert(TimetableDefinitions.Estados[i] == periodo.Estado,
		"TimetableDefinitions: Estados y Periodos no coinciden en la posición " .. i)
	indicePorEstado[periodo.Estado] = i
	inicioAcumulado[periodo.Estado] = total
	total = total + periodo.Duracion
end

-- Duración total de la jornada en segundos reales (escala 1).
TimetableDefinitions.TotalJornadaSeg = total

-- Primer y último estado de la jornada.
TimetableDefinitions.EstadoInicial = TimetableDefinitions.Estados[1]
TimetableDefinitions.EstadoFinal = TimetableDefinitions.Estados[#TimetableDefinitions.Estados]

---------------------------------------------------------------------------------------------------
-- Consultas
---------------------------------------------------------------------------------------------------

-- Convierte "HH:MM" en segundos del día (nil si el formato no es válido).
local function hhmmASegundos(texto)
	if typeof(texto) ~= "string" then
		return nil
	end
	local h, m = string.match(texto, "^(%d%d?):(%d%d)$")
	if not h then
		return nil
	end
	h, m = tonumber(h), tonumber(m)
	if h > 23 or m > 59 then
		return nil
	end
	return h * 3600 + m * 60
end
TimetableDefinitions.HHMMASegundos = hhmmASegundos

-- ¿Es un estado válido?
function TimetableDefinitions.Existe(estado)
	return indicePorEstado[estado] ~= nil
end

-- Índice (1..n) del estado o nil.
function TimetableDefinitions.Indice(estado)
	return indicePorEstado[estado]
end

-- Tabla del periodo del estado o nil.
function TimetableDefinitions.Periodo(estado)
	local i = indicePorEstado[estado]
	if not i then
		return nil
	end
	return TimetableDefinitions.Periodos[i]
end

-- Estado siguiente (tras el último vuelve al primero). Estado desconocido -> primer estado.
function TimetableDefinitions.Siguiente(estado)
	local i = indicePorEstado[estado]
	if not i then
		return TimetableDefinitions.Estados[1]
	end
	local siguiente = i + 1
	if siguiente > #TimetableDefinitions.Estados then
		siguiente = 1
	end
	return TimetableDefinitions.Estados[siguiente]
end

-- Estado anterior (antes del primero está el último).
function TimetableDefinitions.Anterior(estado)
	local i = indicePorEstado[estado]
	if not i then
		return TimetableDefinitions.Estados[1]
	end
	local anterior = i - 1
	if anterior < 1 then
		anterior = #TimetableDefinitions.Estados
	end
	return TimetableDefinitions.Estados[anterior]
end

-- Segundos del día en que empieza el periodo (HoraEscolar "HH:MM" -> segundos). nil si no existe.
function TimetableDefinitions.HoraEscolarSegundos(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	if not periodo then
		return nil
	end
	return hhmmASegundos(periodo.HoraEscolar)
end

-- Segundos del día en que termina el periodo: HoraEscolarFin si la tiene, si no la HoraEscolar del siguiente.
function TimetableDefinitions.HoraEscolarFinSegundos(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	if not periodo then
		return nil
	end
	if periodo.HoraEscolarFin then
		return hhmmASegundos(periodo.HoraEscolarFin)
	end
	local inicio = hhmmASegundos(periodo.HoraEscolar)
	local fin = TimetableDefinitions.HoraEscolarSegundos(TimetableDefinitions.Siguiente(estado))
	if fin == nil or inicio == nil or fin <= inicio then
		-- Sin siguiente coherente: el periodo "dura" lo mismo en reloj escolar que en tiempo real.
		return (inicio or 0) + periodo.Duracion
	end
	return fin
end

-- Hora escolar (segundos del día) en un punto del periodo. progreso = 0..1 (tiempo real transcurrido / duración).
function TimetableDefinitions.HoraEscolarEn(estado, progreso)
	local inicio = TimetableDefinitions.HoraEscolarSegundos(estado)
	if inicio == nil then
		return 0
	end
	local fin = TimetableDefinitions.HoraEscolarFinSegundos(estado) or inicio
	progreso = tonumber(progreso) or 0
	if progreso ~= progreso then
		progreso = 0
	end
	progreso = math.max(0, math.min(1, progreso))
	return math.floor(inicio + (fin - inicio) * progreso)
end

-- Nombre visible del periodo ("1ª clase") o el estado si no existe.
function TimetableDefinitions.Nombre(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	if periodo then
		return periodo.Nombre
	end
	return tostring(estado)
end

-- ¿Es un periodo de clase?
function TimetableDefinitions.EsClase(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	return periodo ~= nil and periodo.EsClase == true
end

-- ¿El comedor reparte comida gratis en este periodo?
function TimetableDefinitions.EsComidaGratis(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	return periodo ~= nil and periodo.ComidaGratis == true
end

-- ¿La cancha está activa en este periodo?
function TimetableDefinitions.EsDeporte(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	return periodo ~= nil and periodo.Deporte == true
end

-- Código de materia del periodo (o nil si no es clase).
function TimetableDefinitions.MateriaDe(estado)
	local periodo = TimetableDefinitions.Periodo(estado)
	if periodo and periodo.EsClase then
		return periodo.Materia
	end
	return nil
end

-- Nombre visible de una materia por código ("MAT" -> "Matemáticas"); devuelve el código si no existe.
function TimetableDefinitions.NombreMateria(codigo)
	if typeof(codigo) ~= "string" then
		return "—"
	end
	return TimetableDefinitions.Materias[codigo] or codigo
end

-- ¿Existe el código de materia?
function TimetableDefinitions.ExisteMateria(codigo)
	return typeof(codigo) == "string" and TimetableDefinitions.Materias[codigo] ~= nil
end

-- Duración real del periodo aplicando una escala (Config.Jornada.EscalaTiempo). Mínimo 5 s.
function TimetableDefinitions.DuracionReal(estado, escala)
	local periodo = TimetableDefinitions.Periodo(estado)
	if not periodo then
		return 0
	end
	escala = tonumber(escala) or 1
	if escala ~= escala or escala <= 0 then
		escala = 1
	end
	return math.max(5, periodo.Duracion * escala)
end

-- Segundos (escala 1) desde el inicio de la jornada hasta el inicio del periodo.
function TimetableDefinitions.InicioAcumulado(estado)
	return inicioAcumulado[estado]
end

-- Estado en el que se encuentra la jornada tras 'transcurrido' segundos reales desde su inicio (escala 1).
-- Devuelve estado, segundos restantes del periodo, progreso 0..1. Si supera el total, devuelve el último.
function TimetableDefinitions.EstadoEnTiempo(transcurrido)
	transcurrido = tonumber(transcurrido) or 0
	if transcurrido ~= transcurrido or transcurrido < 0 then
		transcurrido = 0
	end
	local acumulado = 0
	for _, periodo in ipairs(TimetableDefinitions.Periodos) do
		local fin = acumulado + periodo.Duracion
		if transcurrido < fin then
			local enPeriodo = transcurrido - acumulado
			return periodo.Estado, fin - transcurrido, enPeriodo / periodo.Duracion
		end
		acumulado = fin
	end
	return TimetableDefinitions.EstadoFinal, 0, 1
end

-- Lista de los periodos de clase (para el panel de horario).
function TimetableDefinitions.Clases()
	local lista = {}
	for _, periodo in ipairs(TimetableDefinitions.Periodos) do
		if periodo.EsClase then
			table.insert(lista, periodo)
		end
	end
	return lista
end

return TimetableDefinitions
