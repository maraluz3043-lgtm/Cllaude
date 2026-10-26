--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.RoleDefinitions
	Tipo: ModuleScript
	Definición de los 17 cargos del colegio, sus equipos (Teams), colores, permisos, zona de
	aparición y uniforme. El servidor (RoleService) es la única autoridad sobre qué cargo tiene cada
	jugador; este módulo solo describe los cargos y responde a consultas de permisos.
]]

local RoleDefinitions = {}

---------------------------------------------------------------------------------------------------
-- Permisos conocidos (docs/ARQUITECTURA.md §3). Cualquier permiso fuera de esta lista es un error.
---------------------------------------------------------------------------------------------------
RoleDefinitions.PermisosConocidos = {
	"aula.docente", -- Abrir sesiones de clase, actividades, asistencia, invitar al tablero.
	"aula.estudiante", -- Responder actividades, levantar la mano, aceptar invitaciones.
	"jornada.control", -- Iniciar/pausar/saltar/reiniciar la jornada escolar.
	"horario.editar", -- Cambiar materias y configuración del horario.
	"anuncios.global", -- Anuncios a todo el servidor (/anuncio).
	"anuncios.aula", -- Avisos al aula propia.
	"moderacion.basica", -- Silenciar, advertir, ver registro.
	"moderacion.avanzada", -- Expulsar y bloquear temporalmente.
	"cargos.asignar", -- Asignar cargos a otros jugadores.
	"cargos.revocar", -- Revocar cargos a otros jugadores.
	"auditoria.ver", -- Ver el registro de auditoría.
	"reportes.ver", -- Ver reportes de soporte y convivencia.
	"convivencia.gestionar", -- Gestionar casos de convivencia (avisos, notas, citaciones RP).
	"cafeteria.vender", -- Abrir/cerrar la tienda, reponer, cierre de caja.
	"cafeteria.precios", -- Cambiar precios de la cafetería.
	"cocina.operar", -- Preparar recetas en la cocina.
	"comedor.reponer", -- Reponer raciones del comedor.
	"economia.auditar", -- Ver movimientos económicos del servidor.
	"finanzas.presupuesto", -- Gestionar el presupuesto virtual.
	"enfermeria.atender", -- Atender jugadores en enfermería.
	"secretaria.matricular", -- Matrícula RP: asignar aula y certificado.
	"orientacion.agenda", -- Agenda de citas de orientación.
	"limpieza.tareas", -- Ver y completar tareas de limpieza.
	"seguridad.acceso", -- Portón, registro de visitas, avisos a moderación.
	"puertas.oficinas", -- Bloquear/desbloquear puertas de oficinas y portón.
	"puertas.aulas", -- Bloquear/desbloquear puertas de aulas.
	"pc.bloquear", -- Bloquear/desbloquear PCs y proyectar instrucciones.
	"futbol.arbitro", -- Iniciar/reiniciar/finalizar partidos.
	"eventos.activar", -- Activar eventos escolares especiales.
	"tablero.escribir", -- Escribir y dibujar en el tablero del aula.
}

local setPermisosConocidos = {}
for _, permiso in ipairs(RoleDefinitions.PermisosConocidos) do
	setPermisosConocidos[permiso] = true
end

-- Convierte una lista de permisos en un conjunto { permiso = true }.
local function conjunto(lista)
	local set = {}
	for _, permiso in ipairs(lista) do
		set[permiso] = true
	end
	return set
end

-- Conjunto con todos los permisos conocidos salvo los excluidos.
local function todosMenos(excluidos)
	local excluir = conjunto(excluidos)
	local set = {}
	for _, permiso in ipairs(RoleDefinitions.PermisosConocidos) do
		if not excluir[permiso] then
			set[permiso] = true
		end
	end
	return set
end

---------------------------------------------------------------------------------------------------
-- Equipos (Teams). El orden define el orden de la lista de cargos en el menú.
---------------------------------------------------------------------------------------------------
RoleDefinitions.OrdenEquipos = { "Estudiantes", "Equipo Directivo", "Docentes", "Bienestar", "Administración", "Servicios" }

RoleDefinitions.Equipos = {
	["Estudiantes"] = {
		Nombre = "Estudiantes", Orden = 1,
		Color = BrickColor.new("Bright blue"), Color3 = Color3.fromRGB(31, 78, 160),
		Descripcion = "Alumnado del colegio: asiste a clase, participa y usa los espacios comunes.",
	},
	["Equipo Directivo"] = {
		Nombre = "Equipo Directivo", Orden = 2,
		Color = BrickColor.new("Bright red"), Color3 = Color3.fromRGB(196, 30, 36),
		Descripcion = "Dirección y coordinaciones: gobiernan la jornada, los anuncios y la convivencia.",
	},
	["Docentes"] = {
		Nombre = "Docentes", Orden = 3,
		Color = BrickColor.new("Bright green"), Color3 = Color3.fromRGB(44, 160, 90),
		Descripcion = "Profesorado: dirige las clases, el tablero y las actividades del aula.",
	},
	["Bienestar"] = {
		Nombre = "Bienestar", Orden = 4,
		Color = BrickColor.new("Royal purple"), Color3 = Color3.fromRGB(120, 80, 170),
		Descripcion = "Orientación y enfermería: acompañan y atienden a la comunidad.",
	},
	["Administración"] = {
		Nombre = "Administración", Orden = 5,
		Color = BrickColor.new("Bright yellow"), Color3 = Color3.fromRGB(246, 196, 34),
		Descripcion = "Secretaría, finanzas y recepción: trámites, presupuesto y visitas.",
	},
	["Servicios"] = {
		Nombre = "Servicios", Orden = 6,
		Color = BrickColor.new("Medium stone grey"), Color3 = Color3.fromRGB(120, 125, 135),
		Descripcion = "Limpieza, seguridad, cocina y tienda: mantienen el colegio en marcha.",
	},
}

---------------------------------------------------------------------------------------------------
-- Zonas de aparición especiales
---------------------------------------------------------------------------------------------------
-- Valor especial de ZonaSpawn: el jugador aparece en el aula que tenga asignada (RoleService/SpawnService).
RoleDefinitions.ZonaSpawnAulaAsignada = "AULA_ASIGNADA"
-- Aula usada cuando un docente no tiene aula asignada todavía.
RoleDefinitions.AulaRespaldo = "AULA_ADAPTADA"

local PERMISOS_DOCENTE = { "aula.docente", "anuncios.aula", "puertas.aulas", "tablero.escribir", "pc.bloquear", "futbol.arbitro" }

---------------------------------------------------------------------------------------------------
-- Cargos
---------------------------------------------------------------------------------------------------
RoleDefinitions.Roles = {
	Estudiante = {
		Id = "Estudiante", Nombre = "Estudiante", Abrev = "EST", Equipo = "Estudiantes", Orden = 1,
		Color = Color3.fromRGB(31, 78, 160),
		Permisos = conjunto({ "aula.estudiante" }),
		ZonaSpawn = "PATIO_CENTRAL", RequiereAutorizacion = false,
		Descripcion = "Asiste a clase en su aula asignada, responde actividades, usa el cuaderno, el comedor, la cafetería y la cancha.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},

	Director = {
		Id = "Director", Nombre = "Director/a", Abrev = "DIR", Equipo = "Equipo Directivo", Orden = 1,
		Color = Color3.fromRGB(196, 30, 36),
		Permisos = todosMenos({ "cafeteria.vender", "cocina.operar" }),
		ZonaSpawn = "DIRECCION", RequiereAutorizacion = true,
		Descripcion = "Dirige el colegio: controla la jornada, anuncia, asigna y revoca cargos, modera y revisa auditoría y métricas.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
		CargosNoAsignables = {},
	},
	Subdirector = {
		Id = "Subdirector", Nombre = "Subdirector/a", Abrev = "SUBD", Equipo = "Equipo Directivo", Orden = 2,
		Color = Color3.fromRGB(176, 40, 46),
		Permisos = todosMenos({ "cafeteria.vender", "cocina.operar" }),
		ZonaSpawn = "DIRECCION", RequiereAutorizacion = true,
		Descripcion = "Apoya a la dirección con los mismos poderes, salvo asignar el cargo de Director/a.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
		CargosNoAsignables = { "Director" }, -- Puede asignar cargos (cargos.asignar) excepto estos; lo comprueba RoleService.
	},
	CoordinadorAcademico = {
		Id = "CoordinadorAcademico", Nombre = "Coordinador/a académico/a", Abrev = "CACA", Equipo = "Equipo Directivo", Orden = 3,
		Color = Color3.fromRGB(210, 80, 60),
		Permisos = conjunto({ "horario.editar", "aula.docente", "anuncios.global", "anuncios.aula", "puertas.aulas", "reportes.ver", "jornada.control", "tablero.escribir", "pc.bloquear" }),
		ZonaSpawn = "COORDINACION", RequiereAutorizacion = true,
		Descripcion = "Organiza horario, materias y aulas; controla la jornada y puede dirigir clases y anunciar.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	CoordinadorConvivencia = {
		Id = "CoordinadorConvivencia", Nombre = "Coordinador/a de convivencia", Abrev = "CONV", Equipo = "Equipo Directivo", Orden = 4,
		Color = Color3.fromRGB(220, 110, 70),
		Permisos = conjunto({ "convivencia.gestionar", "moderacion.basica", "reportes.ver", "anuncios.global", "anuncios.aula", "puertas.aulas" }),
		ZonaSpawn = "COORDINACION", RequiereAutorizacion = true,
		Descripcion = "Gestiona la convivencia: reportes, avisos y notas RP, moderación básica y anuncios.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},

	ProfesorTitular = {
		Id = "ProfesorTitular", Nombre = "Profesor/a titular", Abrev = "PROF", Equipo = "Docentes", Orden = 1,
		Color = Color3.fromRGB(44, 160, 90),
		Permisos = conjunto(PERMISOS_DOCENTE),
		ZonaSpawn = "AULA_ASIGNADA", RequiereAutorizacion = true,
		Descripcion = "Dirige la clase de su aula: sesión, tema, asistencia, actividades, tablero y calificaciones.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	Tutor = {
		Id = "Tutor", Nombre = "Tutor/a de grupo", Abrev = "TUT", Equipo = "Docentes", Orden = 2,
		Color = Color3.fromRGB(60, 175, 110),
		Permisos = conjunto(PERMISOS_DOCENTE),
		ZonaSpawn = "AULA_ASIGNADA", RequiereAutorizacion = true,
		Descripcion = "Acompaña a un grupo: puede dirigir clases, tomar asistencia y enviar avisos al aula.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	ProfesorApoyo = {
		Id = "ProfesorApoyo", Nombre = "Profesor/a de apoyo", Abrev = "APOY", Equipo = "Docentes", Orden = 3,
		Color = Color3.fromRGB(90, 190, 130),
		Permisos = conjunto(PERMISOS_DOCENTE),
		ZonaSpawn = "AULA_ASIGNADA", RequiereAutorizacion = true,
		Descripcion = "Refuerza el aula adaptada y apoya a otros docentes en sus clases y actividades.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},

	Orientador = {
		Id = "Orientador", Nombre = "Orientador/a escolar", Abrev = "ORIE", Equipo = "Bienestar", Orden = 1,
		Color = Color3.fromRGB(120, 80, 170),
		Permisos = conjunto({ "orientacion.agenda", "puertas.oficinas" }),
		ZonaSpawn = "OFICINA_ADMIN", RequiereAutorizacion = true,
		Descripcion = "Lleva la agenda de citas de orientación (RP, sin tratamiento clínico) y acompaña a los estudiantes.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	Enfermero = {
		Id = "Enfermero", Nombre = "Enfermero/a", Abrev = "ENF", Equipo = "Bienestar", Orden = 2,
		Color = Color3.fromRGB(150, 110, 200),
		Permisos = conjunto({ "enfermeria.atender", "puertas.oficinas" }),
		ZonaSpawn = "ENTRADA", RequiereAutorizacion = true,
		Descripcion = "Atiende a quien lo solicite (etiqueta 'Atendido'), con aforo máximo y registro de atenciones.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},

	Secretario = {
		Id = "Secretario", Nombre = "Secretario/a académico/a", Abrev = "SECR", Equipo = "Administración", Orden = 1,
		Color = Color3.fromRGB(246, 196, 34),
		Permisos = conjunto({ "secretaria.matricular", "reportes.ver", "puertas.oficinas" }),
		ZonaSpawn = "OFICINA_ADMIN", RequiereAutorizacion = true,
		Descripcion = "Matrícula RP: asigna aula y entrega certificados; consulta reportes.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	AdministradorFinanciero = {
		Id = "AdministradorFinanciero", Nombre = "Administrador/a financiero/a", Abrev = "ADMF", Equipo = "Administración", Orden = 2,
		Color = Color3.fromRGB(230, 170, 30),
		Permisos = conjunto({ "finanzas.presupuesto", "economia.auditar", "cafeteria.precios", "puertas.oficinas" }),
		ZonaSpawn = "OFICINA_ADMIN", RequiereAutorizacion = true,
		Descripcion = "Gestiona el presupuesto virtual, audita cafetería y comedor y fija los precios.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	Recepcionista = {
		Id = "Recepcionista", Nombre = "Recepcionista", Abrev = "RECP", Equipo = "Administración", Orden = 3,
		Color = Color3.fromRGB(240, 210, 90),
		Permisos = conjunto({ "seguridad.acceso", "puertas.oficinas" }),
		ZonaSpawn = "ENTRADA", RequiereAutorizacion = true,
		Descripcion = "Recibe visitas en la entrada, las registra y orienta a quien llega al colegio.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},

	Limpieza = {
		Id = "Limpieza", Nombre = "Personal de limpieza", Abrev = "LIMP", Equipo = "Servicios", Orden = 1,
		Color = Color3.fromRGB(120, 125, 135),
		Permisos = conjunto({ "limpieza.tareas" }),
		ZonaSpawn = "BANOS_2", RequiereAutorizacion = true,
		Descripcion = "Completa tareas de limpieza por zonas durante descansos y almuerzo; recibe recompensa por tarea.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	Seguridad = {
		Id = "Seguridad", Nombre = "Seguridad", Abrev = "SEG", Equipo = "Servicios", Orden = 2,
		Color = Color3.fromRGB(70, 75, 85),
		Permisos = conjunto({ "seguridad.acceso", "puertas.oficinas", "puertas.aulas" }),
		ZonaSpawn = "ENTRADA", RequiereAutorizacion = true,
		Descripcion = "Controla el portón y las puertas, registra visitas y avisa a moderación ante incidentes.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	Cocinero = {
		Id = "Cocinero", Nombre = "Cocinero/a", Abrev = "COC", Equipo = "Servicios", Orden = 3,
		Color = Color3.fromRGB(200, 150, 100),
		Permisos = conjunto({ "cocina.operar", "comedor.reponer" }),
		ZonaSpawn = "COCINA", RequiereAutorizacion = true,
		Descripcion = "Prepara las recetas del comedor por pasos en las estaciones y repone las raciones gratuitas.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
	VendedorCafeteria = {
		Id = "VendedorCafeteria", Nombre = "Vendedor/a de cafetería", Abrev = "VEND", Equipo = "Servicios", Orden = 4,
		Color = Color3.fromRGB(230, 130, 60),
		Permisos = conjunto({ "cafeteria.vender" }),
		ZonaSpawn = "TIENDA", RequiereAutorizacion = true,
		Descripcion = "Atiende la tienda escolar: abre y cierra, repone productos y hace el cierre de caja.",
		Uniforme = { Camisa = 0, Pantalon = 0 },
	},
}

-- Ids de cargo en orden estable (menú, enumeraciones de remotos).
RoleDefinitions.Ids = {
	"Estudiante",
	"Director", "Subdirector", "CoordinadorAcademico", "CoordinadorConvivencia",
	"ProfesorTitular", "Tutor", "ProfesorApoyo",
	"Orientador", "Enfermero",
	"Secretario", "AdministradorFinanciero", "Recepcionista",
	"Limpieza", "Seguridad", "Cocinero", "VendedorCafeteria",
}

---------------------------------------------------------------------------------------------------
-- Autocomprobación al cargar (detecta errores de edición en Studio)
---------------------------------------------------------------------------------------------------
do
	local vistos = {}
	for _, id in ipairs(RoleDefinitions.Ids) do
		local rol = RoleDefinitions.Roles[id]
		assert(rol ~= nil, "RoleDefinitions: el cargo '" .. id .. "' está en Ids pero no en Roles")
		assert(rol.Id == id, "RoleDefinitions: el cargo '" .. id .. "' tiene un Id distinto")
		assert(RoleDefinitions.Equipos[rol.Equipo] ~= nil, "RoleDefinitions: equipo desconocido en '" .. id .. "'")
		for permiso in pairs(rol.Permisos) do
			assert(setPermisosConocidos[permiso], "RoleDefinitions: permiso desconocido '" .. tostring(permiso) .. "' en '" .. id .. "'")
		end
		vistos[id] = true
	end
	for id in pairs(RoleDefinitions.Roles) do
		assert(vistos[id], "RoleDefinitions: el cargo '" .. id .. "' no está en Ids")
	end
end

---------------------------------------------------------------------------------------------------
-- Consultas
---------------------------------------------------------------------------------------------------

-- ¿Existe el cargo?
function RoleDefinitions.Existe(cargoId)
	return typeof(cargoId) == "string" and RoleDefinitions.Roles[cargoId] ~= nil
end

-- Definición completa del cargo o nil.
function RoleDefinitions.Obtener(cargoId)
	if typeof(cargoId) ~= "string" then
		return nil
	end
	return RoleDefinitions.Roles[cargoId]
end

-- ¿El cargo tiene el permiso? Cargos o permisos desconocidos -> false.
function RoleDefinitions.Tiene(cargoId, permiso)
	local rol = RoleDefinitions.Obtener(cargoId)
	if not rol or typeof(permiso) ~= "string" then
		return false
	end
	return rol.Permisos[permiso] == true
end

-- Nombre del equipo del cargo ("Docentes") o nil.
function RoleDefinitions.Equipo(cargoId)
	local rol = RoleDefinitions.Obtener(cargoId)
	if not rol then
		return nil
	end
	return rol.Equipo
end

-- Tabla del equipo (Nombre, Color (BrickColor), Color3, Orden, Descripcion) del cargo o nil.
function RoleDefinitions.EquipoInfo(cargoId)
	local equipo = RoleDefinitions.Equipo(cargoId)
	if not equipo then
		return nil
	end
	return RoleDefinitions.Equipos[equipo]
end

-- Nombre visible del cargo (o el id si no existe).
function RoleDefinitions.Nombre(cargoId)
	local rol = RoleDefinitions.Obtener(cargoId)
	if rol then
		return rol.Nombre
	end
	return tostring(cargoId)
end

-- Abreviatura del cargo para etiquetas (o "?" si no existe).
function RoleDefinitions.Abrev(cargoId)
	local rol = RoleDefinitions.Obtener(cargoId)
	if rol then
		return rol.Abrev
	end
	return "?"
end

-- ¿Es un cargo docente (puede abrir sesiones de clase)?
function RoleDefinitions.EsDocente(cargoId)
	return RoleDefinitions.Tiene(cargoId, "aula.docente")
end

-- Lista ordenada (por equipo y luego por Orden) de las definiciones de cargo. Se calcula una vez.
local listaOrdenada = nil
function RoleDefinitions.Lista()
	if listaOrdenada then
		return listaOrdenada
	end
	local lista = {}
	for _, id in ipairs(RoleDefinitions.Ids) do
		table.insert(lista, RoleDefinitions.Roles[id])
	end
	table.sort(lista, function(a, b)
		local ea, eb = RoleDefinitions.Equipos[a.Equipo].Orden, RoleDefinitions.Equipos[b.Equipo].Orden
		if ea ~= eb then
			return ea < eb
		end
		if a.Orden ~= b.Orden then
			return a.Orden < b.Orden
		end
		return a.Id < b.Id
	end)
	listaOrdenada = lista
	return lista
end

-- Ids de los cargos que tienen un permiso.
function RoleDefinitions.ConPermiso(permiso)
	local ids = {}
	for _, rol in ipairs(RoleDefinitions.Lista()) do
		if rol.Permisos[permiso] then
			table.insert(ids, rol.Id)
		end
	end
	return ids
end

-- Ids de los cargos de un equipo, ordenados.
function RoleDefinitions.CargosDeEquipo(nombreEquipo)
	local ids = {}
	for _, rol in ipairs(RoleDefinitions.Lista()) do
		if rol.Equipo == nombreEquipo then
			table.insert(ids, rol.Id)
		end
	end
	return ids
end

-- ¿Puede un cargo administrador asignar el cargo objetivo? (cargos.asignar y no está en CargosNoAsignables)
function RoleDefinitions.PuedeAsignar(cargoAdmin, cargoObjetivo)
	local admin = RoleDefinitions.Obtener(cargoAdmin)
	if not admin or not RoleDefinitions.Existe(cargoObjetivo) then
		return false
	end
	if not admin.Permisos["cargos.asignar"] then
		return false
	end
	if admin.CargosNoAsignables then
		for _, prohibido in ipairs(admin.CargosNoAsignables) do
			if prohibido == cargoObjetivo then
				return false
			end
		end
	end
	return true
end

-- Zona de aparición efectiva: resuelve "AULA_ASIGNADA" con el aula del jugador o el aula de respaldo.
function RoleDefinitions.ZonaSpawnDe(cargoId, aulaAsignada)
	local rol = RoleDefinitions.Obtener(cargoId)
	if not rol then
		return nil
	end
	if rol.ZonaSpawn == RoleDefinitions.ZonaSpawnAulaAsignada then
		if typeof(aulaAsignada) == "string" and aulaAsignada ~= "" then
			return aulaAsignada
		end
		return RoleDefinitions.AulaRespaldo
	end
	return rol.ZonaSpawn
end

-- Resumen público de un cargo para enviar al cliente (sin tablas internas).
function RoleDefinitions.Resumen(cargoId)
	local rol = RoleDefinitions.Obtener(cargoId)
	if not rol then
		return nil
	end
	return {
		Id = rol.Id, Nombre = rol.Nombre, Abrev = rol.Abrev, Equipo = rol.Equipo,
		Descripcion = rol.Descripcion, RequiereAutorizacion = rol.RequiereAutorizacion,
	}
end

return RoleDefinitions
