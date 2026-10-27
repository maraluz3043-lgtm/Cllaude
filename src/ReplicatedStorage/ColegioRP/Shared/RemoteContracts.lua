--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.RemoteContracts
	Tipo: ModuleScript
	Contrato de todos los remotos (docs/ARQUITECTURA.md §5): tipo, dirección, límite de frecuencia,
	permiso requerido (fijo, nil o función(datos) -> permiso) y esquema Validate de los datos.
	RemoteService crea las instancias a partir de Nombres y aplica estas reglas antes de cada handler.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local RoleDefinitions = require(Shared:WaitForChild("RoleDefinitions"))
local Validate = require(Shared:WaitForChild("Util"):WaitForChild("Validate"))

local RemoteContracts = {}

-- Permiso centinela: ningún cargo lo tiene, así que la petición siempre se rechaza.
RemoteContracts.DENEGADO = "__denegado__"
-- Máximo entero exacto representable (UserId).
RemoteContracts.MaxUserId = 9007199254740991
-- Longitud máxima de un id de salón/aula.
RemoteContracts.MaxSalonCaracteres = 16

local Esq = Validate.Esquema
local Str, Int, Num, Bool = Validate.Str, Validate.Int, Validate.Num, Validate.Bool
local Enum, V3, Tabla, TablaLibre, Array = Validate.Enum, Validate.V3, Validate.Tabla, Validate.TablaLibre, Validate.Array

---------------------------------------------------------------------------------------------------
-- Enumeraciones (compartidas con servicios y controladores)
---------------------------------------------------------------------------------------------------
RemoteContracts.Acciones = {
	Clase = {
		"AbrirSesion", "CerrarSesion", "FijarTema", "EnviarAviso", "TomarAsistencia", "CrearActividad",
		"CerrarActividad", "InvitarTablero", "RevocarTablero", "Calificar", "Responder", "LevantarMano",
		"AceptarInvitacion", "ConsultarEstado", "PublicarResultados",
	},
	Tablero = { "Escribir", "Limpiar", "Plantilla", "Trazo", "Imagen" },
	Cuaderno = { "Guardar", "Cargar", "Compartir", "Vaciar", "Ver" },
	Cafeteria = { "Abrir", "Cerrar", "Precio", "Reponer", "Inventario", "Cierre" },
	Comida = { "Reclamar", "IniciarReceta", "Paso", "Reponer", "Estado", "Entregar" },
	Puerta = { "Abrir", "Cerrar", "Bloquear", "Desbloquear", "Privacidad" },
	PC = { "Usar", "Salir", "Encender", "Apagar", "Aplicacion", "Resultado", "Bloquear", "Desbloquear", "Proyectar" },
	Futbol = { "Unirse", "Salir", "Iniciar", "Reiniciar", "Finalizar", "Estado" },
	Moderacion = {
		"Silenciar", "QuitarSilencio", "Expulsar", "BloquearTemporal", "Advertir", "VerRegistro",
		"AsignarCargo", "RevocarCargo", "ConfirmarAccion",
	},
	Bano = { "LavarManos", "Usar", "Limpiar" },
	Jornada = { "Iniciar", "Pausar", "Reanudar", "Saltar", "Reiniciar", "Configurar" },
}

RemoteContracts.CategoriasReporte = { "Bug", "Abuso", "Duda", "Sugerencia" }
RemoteContracts.Alcances = { "Global", "Aula" }
RemoteContracts.EquiposFutbol = { "A", "B" }
RemoteContracts.ModosGraficos = { "Automatico", "Calidad", "Medio", "Bajos" }

-- Tipos del canal EventoCliente (servidor -> cliente).
RemoteContracts.TiposEventoCliente = {
	"Jornada", "Rol", "Aviso", "Notificacion", "Aula", "Tablero", "Economia", "Comida", "Cafeteria",
	"Futbol", "Puerta", "PC", "Moderacion", "Metricas", "Personal",
}

---------------------------------------------------------------------------------------------------
-- Esquema de ajustes (Perfil.Ajustes, docs/ARQUITECTURA.md §4). Todas las claves son opcionales.
---------------------------------------------------------------------------------------------------
RemoteContracts.EsquemaAjustes = Esq({
	ModoGraficos = Enum(RemoteContracts.ModosGraficos, true),
	Particulas = Bool(true),
	DecoracionLejana = Bool(true),
	Postprocesado = Bool(true),
	SonidosAmbiente = Bool(true),
	AnimacionesCosmeticas = Bool(true),
	LimiteEfectos = Int(0, 5, true),
	EscalaTexto = Num(0.7, 1.4, true),
	MovimientoReducido = Bool(true),
	Subtitulos = Bool(true),
	FormatoHora = Enum({ 12, 24 }, true),
	OcultarEtiquetas = Bool(true),
	IntroVista = Bool(true),
})

-- Claves de ajustes en orden estable (saneamiento en DataService y panel de ajustes).
RemoteContracts.ClavesAjustes = {
	"ModoGraficos", "Particulas", "DecoracionLejana", "Postprocesado", "SonidosAmbiente", "AnimacionesCosmeticas",
	"LimiteEfectos", "EscalaTexto", "MovimientoReducido", "Subtitulos", "FormatoHora", "OcultarEtiquetas", "IntroVista",
}

---------------------------------------------------------------------------------------------------
-- Construcción de funciones de permiso por acción
---------------------------------------------------------------------------------------------------
-- mapa[Accion] = "permiso" | false (sin permiso). Acción ausente -> porDefecto ("permiso" | false | nil = denegar).
local function porAccion(mapa, porDefecto)
	return function(datos)
		if typeof(datos) ~= "table" or typeof(datos.Accion) ~= "string" then
			return RemoteContracts.DENEGADO
		end
		local permiso = mapa[datos.Accion]
		if permiso == nil then
			permiso = porDefecto
			if permiso == nil then
				return RemoteContracts.DENEGADO
			end
		end
		if permiso == false then
			return nil
		end
		return permiso
	end
end

-- Permisos de StaffAction por acción. StaffService puede ampliarlo en Start()
-- (RemoteContracts.PermisosStaff.NuevaAccion = "permiso"). Acciones no listadas se deniegan.
RemoteContracts.PermisosStaff = {
	Atender = "enfermeria.atender", -- Enfermería: marcar "Atendido" a un jugador.
	AltaAtendido = "enfermeria.atender",
	ListaAtendidos = "enfermeria.atender",
	Matricular = "secretaria.matricular", -- Secretaría: asignar aula y certificado RP.
	Certificado = "secretaria.matricular",
	Presupuesto = "finanzas.presupuesto", -- Finanzas: ver/ajustar presupuesto virtual.
	AjustarPresupuesto = "finanzas.presupuesto",
	AuditoriaEconomica = "economia.auditar", -- Finanzas: movimientos de cafetería/comedor.
	Agenda = "orientacion.agenda", -- Orientación: ver agenda.
	AgendarCita = "orientacion.agenda",
	CancelarCita = "orientacion.agenda",
	TareasLimpieza = "limpieza.tareas", -- Limpieza: lista de tareas.
	CompletarTarea = "limpieza.tareas",
	Porton = "seguridad.acceso", -- Seguridad/Recepción: portón y visitas.
	RegistrarVisita = "seguridad.acceso",
	ListaVisitas = "seguridad.acceso",
	AvisoModeracion = "seguridad.acceso",
	CasoConvivencia = "convivencia.gestionar", -- Convivencia: avisos, notas, citaciones RP.
	ListaCasos = "convivencia.gestionar",
	Horario = "horario.editar", -- Coordinación: materias por clase y aulas activas.
	Informe = "auditoria.ver", -- Dirección: informe de métricas y auditoría.
	Auditoria = "auditoria.ver",
	Personal = "cargos.asignar", -- Dirección: lista de personal conectado.
	Evento = "eventos.activar", -- Dirección: eventos escolares.
	Metrica = false, -- Cualquier jugador: FPS medio (MetricsService aplica 1/30 s por jugador).
}

---------------------------------------------------------------------------------------------------
-- Tabla de remotos
---------------------------------------------------------------------------------------------------
RemoteContracts.Nombres = {}
RemoteContracts.Remotos = {}

local function definir(nombre, def)
	def.Nombre = nombre
	RemoteContracts.Remotos[nombre] = def
	table.insert(RemoteContracts.Nombres, nombre)
end

local RoleIds = RoleDefinitions.Ids
local A = RemoteContracts.Acciones

definir("StateSnapshot", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 2, VentanaSeg = 5 }, Permiso = nil,
	Esquema = Esq({}),
	Descripcion = "Snapshot completo: { Jornada, Rol, Economia, Ajustes, Aula, Anuncios, Version, HoraServidor }.",
})

definir("RequestRoleList", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 3, VentanaSeg = 5 }, Permiso = nil,
	Esquema = Esq({}),
	Descripcion = "Lista de cargos con disponibilidad: { Cargos = { {Id, Nombre, Equipo, Disponible, Motivo} }, Actual }.",
})

definir("RequestJoinRole", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 3, VentanaSeg = 10 }, Permiso = nil,
	Esquema = Esq({ Cargo = Enum(RoleIds) }),
	Descripcion = "Asigna el cargo (si está autorizado) y hace spawn: { Cargo, Equipo, Zona, Salon }.",
})

definir("RequestClassAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 10, VentanaSeg = 5 },
	Permiso = porAccion({
		AbrirSesion = "aula.docente", CerrarSesion = "aula.docente", FijarTema = "aula.docente",
		EnviarAviso = "aula.docente", TomarAsistencia = "aula.docente", CrearActividad = "aula.docente",
		CerrarActividad = "aula.docente", InvitarTablero = "aula.docente", RevocarTablero = "aula.docente",
		Calificar = "aula.docente", PublicarResultados = "aula.docente",
		Responder = "aula.estudiante", LevantarMano = "aula.estudiante", AceptarInvitacion = "aula.estudiante",
		ConsultarEstado = false,
	}),
	Esquema = Esq({
		Accion = Enum(A.Clase),
		Salon = Str(RemoteContracts.MaxSalonCaracteres, false, 1),
		Datos = TablaLibre(true), -- Contenido según acción (tema, aviso, actividad, respuesta...); lo valida ClassroomService.
	}),
	Descripcion = "Acciones de sesión de clase (ClassroomService).",
})

definir("BoardAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 8, VentanaSeg = 5 },
	-- tablero.escribir O invitado activo de la sesión: depende del estado, lo comprueba BoardService.
	Permiso = nil,
	PermisoNota = "tablero.escribir o invitado activo (BoardService)",
	Esquema = Esq({
		Accion = Enum(A.Tablero),
		Salon = Str(RemoteContracts.MaxSalonCaracteres, false, 1),
		Texto = Str(Config.Tablero.MaxCaracteres, true),
		-- Puntos normalizados del trazo (coordenadas relativas al tablero, centradas o 0..1); magnitud máx. 1.5.
		Trazo = Array(V3(1.5), Config.Tablero.MaxTrazoPuntos, true),
		Plantilla = Int(1, 20, true),
		ImagenId = Int(0, 999999999999, true),
	}),
	Descripcion = "Actualiza el BoardState del aula y lo replica a la sala.",
})

definir("NotebookUpdate", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 6, VentanaSeg = 10 },
	Permiso = porAccion({ Guardar = false, Cargar = false, Compartir = false, Vaciar = false, Ver = "aula.docente" }),
	Esquema = Esq({
		Accion = Enum(A.Cuaderno),
		Pagina = Int(1, Config.Cuaderno.MaxPaginas, true),
		Materia = Str(8, true),
		Texto = Str(Config.Cuaderno.MaxCaracteresPagina, true),
		ObjetivoUserId = Int(1, RemoteContracts.MaxUserId, true),
	}),
	Descripcion = "Guarda/carga/comparte páginas del cuaderno; 'Ver' solo docente de la sesión sobre alumno presente que compartió.",
})

definir("CafeteriaPurchase", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 4, VentanaSeg = 5 }, Permiso = nil,
	Esquema = Esq({
		ProductoId = Str(24, false, 1),
		Cantidad = Int(1, Config.Cafeteria.CantidadMaxPorCompra or 5),
	}),
	Descripcion = "Compra atómica; devuelve { Recibo = { Id, Total, Saldo, Items } }.",
})

definir("CafeteriaManage", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 6, VentanaSeg = 5 },
	Permiso = porAccion({
		Abrir = "cafeteria.vender", Cerrar = "cafeteria.vender", Reponer = "cafeteria.vender",
		Inventario = "cafeteria.vender", Cierre = "cafeteria.vender", Precio = "cafeteria.precios",
	}),
	Esquema = Esq({
		Accion = Enum(A.Cafeteria),
		ProductoId = Str(24, true),
		Valor = Num(0, 100000, true), -- Precio (dentro de [PrecioMin, PrecioMax]) o cantidad a reponer.
	}),
	Descripcion = "Administración de la tienda escolar.",
})

definir("FoodAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 6, VentanaSeg = 5 },
	Permiso = porAccion({
		Reclamar = false, Estado = false,
		IniciarReceta = "cocina.operar", Paso = "cocina.operar", Entregar = "cocina.operar",
		Reponer = "comedor.reponer",
	}),
	Esquema = Esq({
		Accion = Enum(A.Comida),
		RecetaId = Str(24, true),
		Estacion = Str(24, true),
	}),
	Descripcion = "Comedor gratuito (coste 0, cooldown, solo en periodos ComidaGratis) y cocina por pasos.",
})

definir("SettingsUpdate", {
	Tipo = "RemoteEvent", Direccion = "C2S", Limite = { Max = 2, VentanaSeg = 5 }, Permiso = nil,
	Esquema = Esq({ Ajustes = Tabla(RemoteContracts.EsquemaAjustes) }),
	Descripcion = "Guarda ajustes saneados en Perfil.Ajustes.",
})

definir("ReportSubmit", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 2, VentanaSeg = 60 }, Permiso = nil,
	Esquema = Esq({
		Categoria = Enum(RemoteContracts.CategoriasReporte),
		Ubicacion = Str(Config.Reportes.MaxUbicacionCaracteres or 60),
		Descripcion = Str(Config.Reportes.MaxCaracteres, false, 3),
	}),
	Descripcion = "Reporte de soporte filtrado y guardado; devuelve { Id }.",
})

definir("DoorAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 4, VentanaSeg = 2 },
	-- Abrir/Cerrar: cualquiera a <= 14 studs. Bloquear/Desbloquear: según CargosBloqueo de la puerta
	-- (puertas.aulas / puertas.oficinas); Privacidad: cualquiera dentro del baño. Lo resuelve DoorService.
	Permiso = nil,
	PermisoNota = "puertas.aulas / puertas.oficinas según MapaLogico.Puertas[id].CargosBloqueo (DoorService)",
	Distancia = Config.Distancias.Puerta,
	Esquema = Esq({
		PuertaId = Str(40, false, 1),
		Accion = Enum(A.Puerta),
	}),
	Descripcion = "Acciones sobre puertas; distancia máxima Config.Distancias.Puerta.",
})

definir("PCAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 8, VentanaSeg = 5 },
	Permiso = porAccion({
		Usar = false, Salir = false, Encender = false, Apagar = false, Aplicacion = false, Resultado = false,
		Bloquear = "pc.bloquear", Desbloquear = "pc.bloquear", Proyectar = "pc.bloquear",
	}),
	Distancia = Config.Distancias.PC,
	Esquema = Esq({
		PcId = Str(24, false, 1),
		Accion = Enum(A.PC),
		Datos = TablaLibre(true), -- App, respuestas de cuestionario, líneas de programa, entradas del simulador...
	}),
	Descripcion = "Escritorio escolar: ocupación única por PC; resultados validados en servidor.",
})

definir("FootballKick", {
	Tipo = "RemoteEvent", Direccion = "C2S", Limite = { Max = 5, VentanaSeg = 2 }, Permiso = nil,
	Distancia = Config.Futbol.DistanciaPatada,
	Esquema = Esq({
		Direccion = V3(1), -- Vector unitario de la cámara.
		Fuerza = Num(0, 1), -- Fracción de Config.Futbol.FuerzaMax.
	}),
	Descripcion = "Patada: el servidor valida distancia y cooldown y aplica el impulso.",
})

definir("FootballAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 4, VentanaSeg = 5 },
	Permiso = porAccion({
		Unirse = false, Salir = false, Estado = false,
		Iniciar = false, -- FootballService valida: árbitro, o inicio libre si no hay árbitro y el periodo permite deporte
		Reiniciar = "futbol.arbitro", Finalizar = "futbol.arbitro",
	}),
	Esquema = Esq({
		Accion = Enum(A.Futbol),
		Equipo = Enum(RemoteContracts.EquiposFutbol, true),
	}),
	Descripcion = "Equipos y partido de la cancha.",
})

definir("AnnouncementBroadcast", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 2, VentanaSeg = 30 },
	Permiso = function(datos)
		if typeof(datos) ~= "table" then
			return RemoteContracts.DENEGADO
		end
		if datos.Alcance == "Aula" then
			return "anuncios.aula"
		end
		return "anuncios.global"
	end,
	Esquema = Esq({
		Texto = Str(Config.Limites.MaxAvisoCaracteres, false, 1),
		Alcance = Enum(RemoteContracts.Alcances),
	}),
	Descripcion = "Anuncio filtrado al HUD de todos (Global) o del aula propia (Aula).",
})

definir("ModerationAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 6, VentanaSeg = 10 },
	Permiso = porAccion({
		Silenciar = "moderacion.basica", QuitarSilencio = "moderacion.basica", Advertir = "moderacion.basica",
		VerRegistro = "moderacion.basica", ConfirmarAccion = "moderacion.basica",
		Expulsar = "moderacion.avanzada", BloquearTemporal = "moderacion.avanzada",
		AsignarCargo = "cargos.asignar", RevocarCargo = "cargos.revocar",
	}),
	Esquema = Esq({
		Accion = Enum(A.Moderacion),
		ObjetivoUserId = Int(1, RemoteContracts.MaxUserId, true), -- Obligatorio en acciones sobre un jugador (lo exige ModerationService).
		Motivo = Str(Config.Limites.MaxMotivoCaracteres or 120, true), -- Obligatorio en acciones sobre un jugador.
		Cargo = Enum(RoleIds, true),
		DuracionSeg = Int(10, 86400, true),
		Token = Str(64, true), -- Token de confirmación emitido por el servidor (acciones críticas, dos pasos).
	}),
	Descripcion = "Moderación y gestión de cargos; acciones críticas requieren Token de confirmación.",
})

definir("StaffAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 6, VentanaSeg = 5 },
	Permiso = porAccion(RemoteContracts.PermisosStaff), -- Acciones no listadas en PermisosStaff -> denegadas.
	Esquema = Esq({
		Accion = Str(32, false, 1),
		Datos = TablaLibre(true),
	}),
	Descripcion = "Funciones de cargo (StaffService): enfermería, secretaría, finanzas, orientación, limpieza, seguridad, convivencia, métricas.",
})

definir("BathroomAction", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 4, VentanaSeg = 5 },
	Permiso = porAccion({ LavarManos = false, Usar = false, Limpiar = "limpieza.tareas" }),
	Distancia = Config.Distancias.Bano,
	Esquema = Esq({
		ObjetoId = Str(40, false, 1),
		Accion = Enum(A.Bano),
	}),
	Descripcion = "Interacciones de baño con cooldown; distancia máxima Config.Distancias.Bano.",
})

definir("JornadaControl", {
	Tipo = "RemoteFunction", Direccion = "C2S", Limite = { Max = 4, VentanaSeg = 10 }, Permiso = "jornada.control",
	Esquema = Esq({
		Accion = Enum(A.Jornada),
		Datos = TablaLibre(true), -- Configurar: { Modo, EscalaTiempo, Materias = { CLASE_1 = "MAT", ... }, AulasActivas }.
	}),
	Descripcion = "Control de la jornada escolar (SchoolDayService).",
})

definir("EventoCliente", {
	Tipo = "RemoteEvent", Direccion = "S2C", Limite = nil, Permiso = nil,
	Esquema = Esq({ Tipo = Enum(RemoteContracts.TiposEventoCliente), Datos = TablaLibre(true) }),
	Descripcion = "Único canal servidor -> cliente: { Tipo, Datos }. Los controladores filtran por Tipo.",
})

---------------------------------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------------------------------

-- Definición de un remoto por nombre (o nil).
function RemoteContracts.Obtener(nombre)
	if typeof(nombre) ~= "string" then
		return nil
	end
	return RemoteContracts.Remotos[nombre]
end

-- ¿Existe el remoto en el contrato?
function RemoteContracts.Existe(nombre)
	return RemoteContracts.Obtener(nombre) ~= nil
end

-- Permiso requerido para una petición concreta: string (clave de permiso), nil (ninguno) o DENEGADO.
function RemoteContracts.PermisoPara(nombre, datos)
	local def = RemoteContracts.Obtener(nombre)
	if not def then
		return RemoteContracts.DENEGADO
	end
	local permiso = def.Permiso
	if typeof(permiso) == "function" then
		local ok, resultado = pcall(permiso, datos)
		if not ok then
			return RemoteContracts.DENEGADO
		end
		if resultado ~= nil and typeof(resultado) ~= "string" then
			return RemoteContracts.DENEGADO
		end
		return resultado
	end
	return permiso
end

-- Valida los datos de una petición C2S contra su esquema. Devuelve ok, error.
function RemoteContracts.Validar(nombre, datos)
	local def = RemoteContracts.Obtener(nombre)
	if not def then
		return false, "remoto desconocido"
	end
	if def.Direccion ~= "C2S" then
		return false, "el remoto no acepta peticiones del cliente"
	end
	if typeof(datos) ~= "table" then
		return false, "los datos deben ser una tabla"
	end
	return Validate.Comprobar(def.Esquema, datos)
end

-- Límite de frecuencia del remoto: Max, VentanaSeg (nil, nil si no tiene).
function RemoteContracts.LimiteDe(nombre)
	local def = RemoteContracts.Obtener(nombre)
	if not def or not def.Limite then
		return nil, nil
	end
	return def.Limite.Max, def.Limite.VentanaSeg
end

-- Distancia máxima (studs) asociada al remoto, o nil si no aplica.
function RemoteContracts.DistanciaDe(nombre)
	local def = RemoteContracts.Obtener(nombre)
	if not def then
		return nil
	end
	return def.Distancia
end

-- Nombres de los remotos C2S (los que el servidor registra con handler).
function RemoteContracts.NombresC2S()
	local lista = {}
	for _, nombre in ipairs(RemoteContracts.Nombres) do
		if RemoteContracts.Remotos[nombre].Direccion == "C2S" then
			table.insert(lista, nombre)
		end
	end
	return lista
end

-- Respuesta estándar de éxito de una RemoteFunction.
function RemoteContracts.Ok(datos)
	return { ok = true, datos = datos }
end

-- Respuesta estándar de error de una RemoteFunction.
function RemoteContracts.Error(mensaje)
	return { ok = false, error = tostring(mensaje or "error") }
end

-- Respuesta estándar de rechazo de RemoteService ("rechazado:<motivo>").
function RemoteContracts.Rechazo(motivo)
	return { ok = false, error = "rechazado:" .. tostring(motivo or "desconocido") }
end

-- ¿Es un tipo válido del canal EventoCliente?
local setTipos = {}
for _, tipo in ipairs(RemoteContracts.TiposEventoCliente) do
	setTipos[tipo] = true
end
function RemoteContracts.EsTipoEvento(tipo)
	return setTipos[tipo] == true
end

return RemoteContracts
