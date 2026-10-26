--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.PCController
	Tipo: ModuleScript
	"Escritorio escolar" de los computadores de la sala de tecnología (docs/ARQUITECTURA.md §7). Solo se abre
	cuando el servidor lo indica (EventoCliente "PC" Sub = "AbrirEscritorio") o con PCController.Abrir(datos).
	Barra superior (nombre del colegio, reloj escolar, Apagar, Salir) y aplicaciones en pestañas:
	- Procesador de texto: documento con contador; «Guardar en cuaderno» -> PCAction Resultado { App = "Procesador" }.
	- Cuestionario: cuestionarios públicos de Catalogs o la actividad abierta del aula; corrige el servidor.
	- Simulador educativo: caída libre y péndulo; «Calcular» es local (solo para mostrar) y «Validar» lo
	  comprueba el servidor con tolerancia del 2 %.
	- Programación básica: editor de comandos con ayuda y retos; el servidor ejecuta el programa y devuelve la
	  traza, que se anima localmente en una cuadrícula 8×8 dibujada con Frames.
	- Pantalla de clase: texto proyectado por el docente (y, con pc.bloquear, controles de proyección y bloqueo).
	Ventana centrada en PC y a pantalla completa con pestañas en móvil; navegable con mando; nunca tapa los
	controles táctiles (UIBuilder.Contenedor). Se cierra con «Salir» (envía PCAction Salir) o cuando el servidor
	informa "Estado" sin ocupante. Nunca simula Internet real ni controla un PC real.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TIMEOUT = 30
local function esperarHijo(padre, nombre)
	local hijo = nil
	if padre then
		hijo = padre:FindFirstChild(nombre) or padre:WaitForChild(nombre, TIMEOUT)
	end
	if not hijo then
		error("[ColegioRP][PCController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local Config = require(esperarHijo(Shared, "Config"))
local UITheme = require(esperarHijo(Shared, "UITheme"))
local Catalogs = require(esperarHijo(Shared, "Catalogs"))
local RemoteContracts = require(esperarHijo(Shared, "RemoteContracts"))
local RoleDefinitions = require(esperarHijo(Shared, "RoleDefinitions"))
local TimetableDefinitions = require(esperarHijo(Shared, "TimetableDefinitions"))
local Net = require(esperarHijo(Util, "Net"))
local Signal = require(esperarHijo(Util, "Signal"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local Colores = UITheme.Colores

local PCController = {}
PCController.Nombre = "PCController"
-- InteractionController no delega "AbrirEscritorio": este controlador ya atiende su propio evento.
PCController.ManejaAperturaPropia = true
PCController.Abierto = Signal.new() -- (pcId)
PCController.Cerrado = Signal.new() -- (pcId)

---------------------------------------------------------------------------------------------------
-- Constantes
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][PCController] "
local ORDEN_PANTALLA = UITheme.Capas.Panel
local MAX_TEXTO = (Config.Cuaderno and Config.Cuaderno.MaxCaracteresPagina) or 1200
local MAX_PROYECCION = 300
local MAX_RESPUESTA = (Config.Limites and Config.Limites.MaxRespuestaCaracteres) or 300
local MAX_ANIDAMIENTO_DEF = 2
local PASO_ANIMACION = 0.25
local DEBOUNCE_APP = 0.6
local ALTO_BARRA = 54
local ALTO_ESTADO = 24
local TAMANO_MAX_VENTANA = Vector2.new(1040, 700)
local APP_PANTALLA = "PantallaClase"
local AULA = "__AULA__"
local Programacion = Catalogs.Programacion or {}
local Simulador = Catalogs.Simulador or { Orden = {}, Experimentos = {} }
local N = Programacion.Cuadricula or 8
local MAX_LINEAS = Programacion.MaxLineas or 40
local MAX_EDITOR = MAX_LINEAS * ((Programacion.MaxCaracteresLinea or 32) + 1)
local FLECHAS = { N = "▲", E = "▶", S = "▼", O = "◀" }
local LETRAS = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J" }
local CORTOS = { Procesador = "Texto", Cuestionario = "Test", Simulador = "Física", Programacion = "Código", PantallaClase = "Clase" }
local COMANDOS_RAPIDOS = { "AVANZAR", "GIRAR_IZQ", "GIRAR_DER", "REPETIR 2", "FIN" }
local COLORES_NIVEL = {
	Info = Colores.TextoSecundario, Exito = Colores.Verde, Error = Colores.Rojo, Aviso = Colores.Amarillo,
	Neutro = Colores.TextoPrincipal,
}

-- Aplicaciones del escritorio: las de Catalogs.ActividadesPC y la pantalla de clase.
local APPS = {}
for _, actividad in ipairs(Catalogs.ActividadesPC or {}) do
	table.insert(APPS, { Id = actividad.Id, Nombre = actividad.Nombre, Icono = actividad.Icono, Ayuda = actividad.Ayuda })
end
table.insert(APPS, {
	Id = APP_PANTALLA, Nombre = "Pantalla de clase", Icono = "▣",
	Ayuda = "Muestra el texto que el docente proyecta en todas las pantallas de la sala.",
})

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local pendiente = nil -- AbrirEscritorio recibido antes de Start
local estado = {
	Abierto = false, PcId = nil, RoomId = nil, NombreSala = nil, Numero = nil, TieneSeat = false,
	Encendido = true, Bloqueado = false, App = "Procesador", AppEnviada = nil, AvisoAppPendiente = false,
	Proyeccion = nil, ProyeccionesPorSala = {}, Actividad = nil, Entregas = {}, Materia = "TEC",
	Jornada = nil, ProgresoCongelado = nil, MaxAnidamiento = MAX_ANIDAMIENTO_DEF, Movil = false,
	Solicitud = 0, Ocupado = {}, Mostradas = {}, NumMostradas = 0, Novedad = false,
}
local borrador = {
	Texto = "", MateriaTexto = nil, CuestionarioId = nil, RespuestasPor = {}, RespuestaAula = nil,
	Experimento = (Simulador.Orden and Simulador.Orden[1]) or "CaidaLibre", Entradas = {}, Salidas = {},
	RetoId = (Programacion.Retos and Programacion.Retos[1] and Programacion.Retos[1].Id) or "RETO_1", Programas = {},
	TextoProyeccion = "",
}
local ui = { Apps = {}, Pestanas = {} }
local cuadricula = { Celdas = {}, Robot = nil, Flecha = nil, Marco = nil, Lado = 0, Obstaculos = {}, Reto = nil }
local maidUI = Maid.new() -- conexiones de la interfaz construida
local maidVentana = Maid.new() -- conexiones mientras la ventana está abierta
local maidGlobal = Maid.new() -- eventos del servidor y del jugador
local tokenAnimacion = 0

-- Declaraciones adelantadas (funciones que se usan antes de su definición).
local seleccionarApp, refrescarOverlays, refrescarSelectorCuestionario, renderPreguntas, refrescarPantallaClase
local refrescarControlesDocente, actualizarDisposicion, mostrarResultado, ajustarCuadricula, cambiarReto
local renderExperimento, fijarBarraEstado

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function obtenerControlador(nombre)
	local registro = PCController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

-- Toast de NotificationController ("info" | "exito" | "aviso" | "error"); sin él, la barra de estado.
local function notificar(texto, nivel)
	local nc = obtenerControlador("NotificationController")
	if nc and typeof(nc.Notificar) == "function" then
		local ok = pcall(nc.Notificar, nc, texto, nivel)
		if ok then
			return
		end
	end
	if fijarBarraEstado then
		local mapa = { exito = "Exito", aviso = "Aviso", error = "Error" }
		fijarBarraEstado(texto, mapa[nivel] or "Info")
	end
end

local function fijar(label, texto, nivel)
	if label and label.Parent ~= nil then
		label.Text = tostring(texto or "")
		label.TextColor3 = COLORES_NIVEL[nivel] or Colores.TextoPrincipal
	end
end

local function numero(valor)
	local n = tonumber(valor)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- Número escrito por el jugador (acepta coma decimal).
local function parsearNumero(texto)
	if typeof(texto) ~= "string" then
		return nil
	end
	local limpio = Format.Recortar(texto)
	local conPunto = string.gsub(limpio, ",", ".")
	return numero(conPunto)
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

local function horaCorta(unix)
	local t = numero(unix)
	if not t then
		return ""
	end
	local ok, texto = pcall(os.date, "%H:%M", math.floor(t))
	if ok and typeof(texto) == "string" then
		return texto
	end
	return ""
end

local function limpiarHijos(marco)
	if not marco then
		return
	end
	for _, hijo in ipairs(marco:GetChildren()) do
		if not hijo:IsA("UIListLayout") and not hijo:IsA("UIPadding") and not hijo:IsA("UICorner") and not hijo:IsA("UIStroke") then
			hijo:Destroy()
		end
	end
end

local function contadorOrden()
	local orden = 0
	return function()
		orden = orden + 1
		return orden
	end
end

local function tienePermisoDocente()
	local cargo = LocalPlayer:GetAttribute("Cargo")
	if typeof(cargo) ~= "string" then
		return false
	end
	local ok, tiene = pcall(RoleDefinitions.Tiene, cargo, "pc.bloquear")
	return ok and tiene == true
end

local function ayudaApp(id)
	for _, app in ipairs(APPS) do
		if app.Id == id then
			return app.Ayuda or ""
		end
	end
	return ""
end

local function opcionesMaterias()
	local opciones = {}
	for _, codigo in ipairs(TimetableDefinitions.OrdenMaterias or {}) do
		table.insert(opciones, { Valor = codigo, Texto = TimetableDefinitions.NombreMateria(codigo) })
	end
	return opciones
end

local function siguienteSolicitud()
	estado.Solicitud = estado.Solicitud + 1
	return estado.Solicitud
end

-- Un mismo resultado llega por la respuesta de la RemoteFunction y por el evento "Resultado": se muestra una vez.
local function yaMostrado(solicitud)
	if typeof(solicitud) ~= "number" then
		return false
	end
	if estado.Mostradas[solicitud] then
		return true
	end
	estado.NumMostradas = estado.NumMostradas + 1
	if estado.NumMostradas > 100 then
		estado.Mostradas = {}
		estado.NumMostradas = 1
	end
	estado.Mostradas[solicitud] = true
	return false
end

local function mensajeDe(respuesta)
	return UIBuilder.MensajeError(typeof(respuesta) == "table" and respuesta.error or nil)
end

-- PCAction { PcId, Accion, Datos }. Bloquea el hilo actual: llamar dentro de task.spawn. Devuelve ok, respuesta.
local function enviarAccion(accion, extra, pcId)
	pcId = pcId or estado.PcId
	if typeof(pcId) ~= "string" or pcId == "" then
		return false, { ok = false, error = "No estás usando ningún equipo." }
	end
	local datos = { PcId = pcId, Accion = accion }
	if extra ~= nil then
		datos.Datos = extra
	end
	local valido, err = RemoteContracts.Validar("PCAction", datos)
	if not valido then
		return false, { ok = false, error = "Datos no válidos: " .. tostring(err) }
	end
	return Net.Invocar("PCAction", datos)
end

-- Ejecuta una acción con guardia de "ocupado" por clave y botón deshabilitado mientras espera.
local function ejecutarAccion(clave, boton, accion, extra, alResponder)
	if estado.Ocupado[clave] then
		return
	end
	estado.Ocupado[clave] = true
	if boton then
		UIBuilder.Habilitar(boton, false)
	end
	task.spawn(function()
		local ok, respuesta = enviarAccion(accion, extra)
		estado.Ocupado[clave] = nil
		if boton and boton.Parent ~= nil then
			UIBuilder.Habilitar(boton, true)
		end
		if typeof(alResponder) == "function" then
			local exito, err = pcall(alResponder, ok, respuesta)
			if not exito then
				warn(LOG .. "Error procesando la respuesta de " .. tostring(accion) .. ": " .. tostring(err))
			end
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Reloj escolar (snapshot "Jornada": InicioServidor + Duracion con workspace:GetServerTimeNow())
---------------------------------------------------------------------------------------------------
local function segundosDeHora(valor)
	if typeof(valor) == "number" then
		return numero(valor)
	end
	if typeof(valor) == "string" then
		return Format.SegundosDeHHMM(valor)
	end
	return nil
end

local function ahoraServidor()
	local ok, valor = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(valor) == "number" then
		return valor
	end
	return os.time()
end

local function textoReloj()
	local j = estado.Jornada
	if typeof(j) == "table" and typeof(j.Estado) == "string" then
		local inicio = segundosDeHora(j.HoraEscolarInicio) or TimetableDefinitions.HoraEscolarSegundos(j.Estado)
		if inicio then
			local fin = segundosDeHora(j.HoraEscolarFin) or TimetableDefinitions.HoraEscolarFinSegundos(j.Estado) or inicio
			local duracion = numero(j.Duracion)
			if duracion == nil then
				local periodo = TimetableDefinitions.Periodo(j.Estado)
				duracion = (periodo and periodo.Duracion) or 0
			end
			local progreso = 0
			if j.Pausada == true then
				progreso = numero(j.Progreso)
				if progreso == nil and estado.ProgresoCongelado and estado.ProgresoCongelado.Estado == j.Estado then
					progreso = estado.ProgresoCongelado.Valor
				end
				progreso = progreso or 0
			else
				local inicioServidor = numero(j.InicioServidor)
				if inicioServidor and duracion > 0 then
					progreso = (ahoraServidor() - inicioServidor) / duracion
				end
			end
			progreso = math.clamp(progreso, 0, 1)
			estado.ProgresoCongelado = { Estado = j.Estado, Valor = progreso }
			return Format.HoraHHMM(inicio + (fin - inicio) * progreso)
		end
	end
	local t = os.date("*t")
	if typeof(t) == "table" then
		return string.format("%02d:%02d", t.hour or 0, t.min or 0)
	end
	return "--:--"
end

---------------------------------------------------------------------------------------------------
-- Actividad del aula (ClassroomService:Snapshot -> ActividadActiva, o evento "Aula" -> Actividad)
---------------------------------------------------------------------------------------------------
local function normalizarActividad(act, salon)
	if typeof(act) ~= "table" then
		return nil
	end
	if act.Estado ~= nil and act.Estado ~= "Abierta" then
		return nil
	end
	local id = act.Id or act.ActividadId
	local prompt = act.Prompt or act.Pregunta or act.Texto
	if typeof(id) ~= "string" or typeof(prompt) ~= "string" or prompt == "" then
		return nil
	end
	local opciones = {}
	local fuente = act.Options or act.Opciones
	if typeof(fuente) == "table" then
		for i = 1, math.min(#fuente, #LETRAS) do
			opciones[i] = tostring(fuente[i])
		end
	end
	local tipo = act.Type or act.Tipo
	if tipo ~= "Texto" and #opciones > 0 then
		tipo = "Opciones"
	else
		tipo = "Texto"
	end
	local mia = act.MiRespuesta
	local respondida = typeof(mia) == "table"
	return {
		Id = id, Tipo = tipo, Prompt = prompt, Opciones = opciones, Salon = salon,
		YaRespondida = respondida,
		MiRespuesta = respondida and mia.Respuesta or nil,
		MiIndice = respondida and numero(mia.Indice) or nil,
	}
end

local function extraerActividad(snap)
	if typeof(snap) ~= "table" or snap.Rol == "Docente" or snap.Docente == true then
		return nil
	end
	local salon = snap.RoomId or snap.Salon
	if typeof(salon) ~= "string" then
		salon = nil
	end
	return normalizarActividad(snap.ActividadActiva, salon) or normalizarActividad(snap.Actividad, salon)
end

---------------------------------------------------------------------------------------------------
-- Construcción: barra superior, pestañas, barra de estado y capas
---------------------------------------------------------------------------------------------------
local function textoPestana(app)
	local nombre = app.Nombre
	if estado.Movil then
		nombre = CORTOS[app.Id] or app.Nombre
	end
	local texto = (app.Icono and (tostring(app.Icono) .. "  ") or "") .. nombre
	if app.Id == APP_PANTALLA and estado.Novedad then
		texto = texto .. " •"
	end
	return texto
end

local function construirBarraSuperior(cuerpo)
	local barra = Instance.new("Frame")
	barra.Name = "BarraSuperior"
	barra.BackgroundColor3 = Colores.RojoOscuro
	barra.BorderSizePixel = 0
	barra.Size = UDim2.new(1, 0, 0, ALTO_BARRA)
	barra.Parent = cuerpo
	UIBuilder.Logo(barra, 38, { Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Texto = false })
	ui.Titulo = UIBuilder.Texto(barra, "Escritorio escolar", {
		Nombre = "Titulo", Fuente = "Titulo", Tamano = "Subtitulo", AutoAlto = false, Ajustar = false, Truncar = true,
		Size = UDim2.new(1, -340, 0, 24), Position = UDim2.new(0, 56, 0, 5), AlineacionY = Enum.TextYAlignment.Center,
	})
	ui.Subtitulo = UIBuilder.Texto(barra, tostring(Config.NombreCorto or Config.NombreColegio or ""), {
		Nombre = "Colegio", Tamano = "Pequeno", Color = Colores.Blanco, AutoAlto = false, Ajustar = false, Truncar = true,
		Size = UDim2.new(1, -340, 0, 18), Position = UDim2.new(0, 56, 0, 30), AlineacionY = Enum.TextYAlignment.Center,
	})
	local acciones = Instance.new("Frame")
	acciones.Name = "Acciones"
	acciones.BackgroundTransparency = 1
	acciones.Size = UDim2.new(0, 280, 1, -8)
	acciones.Position = UDim2.new(1, -8, 0.5, 0)
	acciones.AnchorPoint = Vector2.new(1, 0.5)
	acciones.Parent = barra
	UIBuilder.Disposicion(acciones, { Horizontal = true, Espaciado = 6, Alineacion = Enum.HorizontalAlignment.Right })
	ui.Reloj = UIBuilder.Texto(acciones, "--:--", {
		Nombre = "Reloj", Fuente = "Titulo", Tamano = "Subtitulo", Color = Colores.Amarillo, AutoAlto = false, Ajustar = false,
		Size = UDim2.new(0, 66, 1, 0), Alineacion = Enum.TextXAlignment.Center, AlineacionY = Enum.TextYAlignment.Center,
		LayoutOrder = 1,
	})
	ui.BotonApagar = UIBuilder.Boton(acciones, "Apagar", function()
		PCController.Apagar()
	end, { Estilo = "Secundario", Ancho = 100, Alto = ALTO_BARRA - 14, LayoutOrder = 2, Nombre = "Apagar" })
	ui.BotonSalir = UIBuilder.Boton(acciones, "Salir", function()
		PCController.Cerrar(true)
	end, { Estilo = "Peligro", Ancho = 90, Alto = ALTO_BARRA - 14, LayoutOrder = 3, Nombre = "Salir" })
end

local function construirPestanas(cuerpo)
	local alto = UIBuilder.AltoBoton()
	local lista = UIBuilder.Lista(cuerpo, {
		Horizontal = true, Espaciado = 6,
		Size = UDim2.new(1, -20, 0, alto + 10), Position = UDim2.new(0, 10, 0, ALTO_BARRA + 6),
	})
	lista.Name = "Pestanas"
	lista.ScrollBarThickness = 4
	ui.ListaPestanas = lista
	ui.AltoPestanas = alto + 10
	local botones = {}
	for i, app in ipairs(APPS) do
		local id = app.Id
		local boton = UIBuilder.Boton(lista, textoPestana(app), function()
			seleccionarApp(id, true)
		end, { Estilo = "Secundario", Ancho = 196, Alto = alto, LayoutOrder = i, Nombre = "Pestana_" .. id })
		ui.Pestanas[id] = boton
		table.insert(botones, boton)
	end
	UIBuilder.Encadenar(botones, true)
	ui.ListaBotonesPestana = botones
end

local function nuevaApp(area, id)
	local marco = Instance.new("Frame")
	marco.Name = "App_" .. id
	marco.BackgroundTransparency = 1
	marco.BorderSizePixel = 0
	marco.Size = UDim2.new(1, 0, 1, 0)
	marco.Visible = false
	marco.Parent = area
	local lista = UIBuilder.Lista(marco, { Espaciado = 8 })
	ui.Apps[id] = { Marco = marco, Lista = lista }
	return lista
end

-- Caja de texto multilínea dentro de un ScrollingFrame (crece con el contenido y se desplaza).
local function editorMultilinea(padre, placeholder, props)
	local marco = UIBuilder.Lista(padre, {
		Color = Colores.Entrada, Transparencia = 0, Espaciado = 0,
		Size = UDim2.new(1, -4, 0, props.AltoMarco or 220), LayoutOrder = props.LayoutOrder,
	})
	marco.Name = props.NombreMarco or "MarcoEditor"
	UIBuilder.Esquinas(marco, UITheme.RadioPequeno)
	local caja = UIBuilder.Entrada(marco, placeholder, {
		Max = props.Max, Multilinea = true, Alto = (props.AltoMarco or 220) - 8, Texto = props.Texto or "",
		Nombre = props.Nombre, AlCambiar = props.AlCambiar,
	})
	caja.AutomaticSize = Enum.AutomaticSize.Y
	if props.Fuente then
		caja.Font = UITheme.Fuente(props.Fuente)
	end
	return caja, marco
end

local function construirBarraEstado(cuerpo)
	ui.BarraEstado = UIBuilder.Texto(cuerpo, "", {
		Nombre = "BarraEstado", Tamano = "Pequeno", Color = Colores.TextoSecundario, AutoAlto = false, Ajustar = false,
		Truncar = true, Size = UDim2.new(1, -20, 0, ALTO_ESTADO), Position = UDim2.new(0, 10, 1, -(ALTO_ESTADO + 4)),
		AlineacionY = Enum.TextYAlignment.Center,
	})
end

function fijarBarraEstado(texto, nivel)
	fijar(ui.BarraEstado, texto, nivel or "Info")
end

local function construirCapa(cuerpo, nombre, color, transparencia, z)
	local capa = Instance.new("Frame")
	capa.Name = nombre
	capa.BackgroundColor3 = color
	capa.BackgroundTransparency = transparencia
	capa.BorderSizePixel = 0
	capa.Position = UDim2.new(0, 0, 0, ALTO_BARRA)
	capa.Size = UDim2.new(1, 0, 1, -ALTO_BARRA)
	capa.ZIndex = z
	capa.Active = true
	capa.Visible = false
	capa.Parent = cuerpo
	pcall(function()
		capa.SelectionGroup = true
	end)
	local centro = UIBuilder.Marco(capa, {
		AutoAlto = true, Size = UDim2.new(0.9, 0, 0, 0), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
		Nombre = "Centro",
	})
	UIBuilder.Disposicion(centro, { Espaciado = 12, Alineacion = Enum.HorizontalAlignment.Center })
	return capa, centro
end

local function construirCapas(cuerpo)
	local apagado, centroApagado = construirCapa(cuerpo, "CapaApagado", Color3.new(0, 0, 0), 0, 5)
	UIBuilder.Titulo(centroApagado, "El equipo está apagado", { LayoutOrder = 1, Alineacion = Enum.TextXAlignment.Center })
	UIBuilder.Texto(centroApagado, "Pulsa «Encender» para volver al escritorio o «Salir» para dejar el equipo libre.", {
		LayoutOrder = 2, Alineacion = Enum.TextXAlignment.Center, Color = Colores.TextoSecundario,
	})
	local filaApagado = UIBuilder.Fila(centroApagado, { LayoutOrder = 3, Alineacion = Enum.HorizontalAlignment.Center })
	ui.BotonEncender = UIBuilder.Boton(filaApagado, "Encender", function()
		PCController.Encender()
	end, { Estilo = "Exito", Ancho = 150, LayoutOrder = 1, Nombre = "Encender" })
	local salirApagado = UIBuilder.Boton(filaApagado, "Salir", function()
		PCController.Cerrar(true)
	end, { Estilo = "Peligro", Ancho = 120, LayoutOrder = 2, Nombre = "SalirApagado" })
	UIBuilder.Encadenar({ ui.BotonEncender, salirApagado }, true)
	ui.CapaApagado = apagado

	local bloqueo, centroBloqueo = construirCapa(cuerpo, "CapaBloqueo", Colores.RojoOscuro, 0.08, 6)
	UIBuilder.Titulo(centroBloqueo, "Equipo bloqueado por el docente", { LayoutOrder = 1, Alineacion = Enum.TextXAlignment.Center })
	ui.TextoBloqueo = UIBuilder.Texto(centroBloqueo, "Presta atención a las instrucciones de tu docente. Tu trabajo sigue guardado en este escritorio.", {
		LayoutOrder = 2, Alineacion = Enum.TextXAlignment.Center, Color = Colores.Blanco,
	})
	local filaBloqueo = UIBuilder.Fila(centroBloqueo, { LayoutOrder = 3, Alineacion = Enum.HorizontalAlignment.Center })
	ui.BotonSalirBloqueo = UIBuilder.Boton(filaBloqueo, "Salir", function()
		PCController.Cerrar(true)
	end, { Estilo = "Secundario", Ancho = 140, LayoutOrder = 1, Nombre = "SalirBloqueo" })
	ui.CapaBloqueo = bloqueo
end

---------------------------------------------------------------------------------------------------
-- App: Procesador de texto
---------------------------------------------------------------------------------------------------
local function actualizarContadorTexto()
	if not ui.ContadorTexto or not ui.Documento then
		return
	end
	local n = Format.Longitud(ui.Documento.Text)
	ui.ContadorTexto.Text = tostring(n) .. " / " .. tostring(MAX_TEXTO) .. " caracteres"
	if n >= MAX_TEXTO then
		ui.ContadorTexto.TextColor3 = Colores.Amarillo
	else
		ui.ContadorTexto.TextColor3 = Colores.TextoApagado
	end
end

local function guardarTexto()
	if not ui.Documento then
		return
	end
	local texto = Format.Recortar(ui.Documento.Text)
	if texto == "" then
		fijar(ui.EstadoTexto, "Escribe algo antes de guardar.", "Aviso")
		return
	end
	if Format.Longitud(texto) > MAX_TEXTO then
		fijar(ui.EstadoTexto, "El documento supera los " .. MAX_TEXTO .. " caracteres.", "Error")
		return
	end
	local materia = estado.Materia
	if ui.SelectorMateria then
		materia = ui.SelectorMateria:Valor() or materia
	end
	fijar(ui.EstadoTexto, "Guardando en tu cuaderno…", "Info")
	ejecutarAccion("Procesador", ui.BotonGuardarTexto, "Resultado", {
		App = "Procesador", Texto = texto, Materia = materia, Solicitud = siguienteSolicitud(),
	}, function(ok, respuesta)
		if ok then
			mostrarResultado(respuesta.datos)
		else
			fijar(ui.EstadoTexto, "No se pudo guardar: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

local function construirProcesador(area)
	local lista = nuevaApp(area, "Procesador")
	local sig = contadorOrden()
	UIBuilder.Titulo(lista, "Procesador de texto", { LayoutOrder = sig(), Tamano = "Subtitulo" })
	UIBuilder.Texto(lista, ayudaApp("Procesador"), { LayoutOrder = sig(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	ui.SelectorMateria = UIBuilder.Selector(lista, "Materia de la página", opcionesMaterias(), borrador.MateriaTexto or estado.Materia, function(valor)
		borrador.MateriaTexto = valor
	end, { LayoutOrder = sig(), Nombre = "Materia", AnchoGrupo = 230 })
	local caja, marco = editorMultilinea(lista, "Escribe tus apuntes o tu tarea…", {
		Max = MAX_TEXTO, Texto = borrador.Texto, Nombre = "Documento", NombreMarco = "MarcoDocumento",
		AltoMarco = 240, LayoutOrder = sig(),
		AlCambiar = function(texto)
			borrador.Texto = texto
			actualizarContadorTexto()
		end,
	})
	ui.Documento = caja
	ui.MarcoDocumento = marco
	ui.ContadorTexto = UIBuilder.Texto(lista, "", {
		LayoutOrder = sig(), Tamano = "Pequeno", Color = Colores.TextoApagado, Alineacion = Enum.TextXAlignment.Right,
	})
	local fila = UIBuilder.Fila(lista, { LayoutOrder = sig(), Nombre = "AccionesTexto" })
	ui.BotonGuardarTexto = UIBuilder.Boton(fila, "Guardar en cuaderno", function()
		guardarTexto()
	end, { Estilo = "Primario", Ancho = 220, LayoutOrder = 1, Nombre = "Guardar" })
	local limpiar = UIBuilder.Boton(fila, "Limpiar", function()
		if ui.Documento then
			ui.Documento.Text = ""
		end
		fijar(ui.EstadoTexto, "", "Info")
	end, { Estilo = "Secundario", Ancho = 120, LayoutOrder = 2, Nombre = "Limpiar" })
	UIBuilder.Encadenar({ ui.BotonGuardarTexto, limpiar }, true)
	ui.EstadoTexto = UIBuilder.Texto(lista, "", { LayoutOrder = sig(), Nombre = "EstadoTexto" })
	actualizarContadorTexto()
end

---------------------------------------------------------------------------------------------------
-- App: Cuestionario
---------------------------------------------------------------------------------------------------
local function respuestasDe(id)
	local t = borrador.RespuestasPor[id]
	if not t then
		t = {}
		borrador.RespuestasPor[id] = t
	end
	return t
end

local function opcionesCuestionario()
	local opciones = {}
	if estado.Actividad then
		table.insert(opciones, { Valor = AULA, Texto = "Actividad del aula" })
	end
	for _, cuestionario in ipairs(Catalogs.CuestionariosPublicos or {}) do
		table.insert(opciones, { Valor = cuestionario.Id, Texto = cuestionario.Titulo })
	end
	return opciones
end

local function cuestionarioPorDefecto()
	if estado.Actividad then
		return AULA
	end
	local deMateria = Catalogs.CuestionarioDeMateria(estado.Materia)
	if deMateria then
		return deMateria.Id
	end
	local primero = Catalogs.CuestionariosPublicos and Catalogs.CuestionariosPublicos[1]
	return primero and primero.Id or nil
end

local function pintarOpcion(boton, seleccionada)
	boton:SetAttribute("Estilo", seleccionada and "Primario" or "Secundario")
	UIBuilder.Habilitar(boton, true)
end

local function elegirOpcion(pregunta, opcion)
	local id = borrador.CuestionarioId
	if id == AULA then
		borrador.RespuestaAula = opcion
	else
		respuestasDe(id)[pregunta] = opcion
	end
	for j, boton in pairs((ui.BotonesOpcion and ui.BotonesOpcion[pregunta]) or {}) do
		pintarOpcion(boton, j == opcion)
	end
end

local function construirPregunta(marco, indice, texto, opciones, seleccion)
	local bloque = UIBuilder.Marco(marco, {
		AutoAlto = true, LayoutOrder = indice, Nombre = "Pregunta_" .. indice, Color = Colores.Gris, Transparencia = 0.25,
	})
	UIBuilder.Esquinas(bloque, UITheme.Radio)
	UIBuilder.Relleno(bloque, 10)
	UIBuilder.Disposicion(bloque, { Espaciado = 6 })
	UIBuilder.Texto(bloque, tostring(indice) .. ". " .. tostring(texto), { Fuente = "Subtitulo", LayoutOrder = 1 })
	local opcionesMarco = UIBuilder.Marco(bloque, { AutoAlto = true, LayoutOrder = 2, Nombre = "Opciones" })
	UIBuilder.Disposicion(opcionesMarco, { Horizontal = true, Espaciado = 6, Wraps = true })
	local ancho = 230
	if estado.Movil then
		ancho = 180
	end
	local botones = {}
	for j, opcion in ipairs(opciones) do
		local letra = LETRAS[j] or tostring(j)
		local boton = UIBuilder.Boton(opcionesMarco, letra .. ")  " .. tostring(opcion), function()
			elegirOpcion(indice, j)
		end, { Estilo = (seleccion == j) and "Primario" or "Secundario", Ancho = ancho, LayoutOrder = j, Nombre = "Opcion_" .. j, Alineacion = Enum.TextXAlignment.Left })
		botones[j] = boton
	end
	ui.BotonesOpcion[indice] = botones
	ui.MarcasPregunta[indice] = UIBuilder.Texto(bloque, "", { Tamano = "Pequeno", LayoutOrder = 3, Nombre = "Marca" })
end

local function mostrarEntrega(id, r)
	if typeof(r) ~= "table" then
		return
	end
	local aciertos = math.floor(numero(r.Aciertos) or 0)
	local total = math.floor(numero(r.Total) or 0)
	local porcentaje = math.floor(numero(r.Porcentaje) or 0)
	local texto = string.format("Aciertos: %d de %d (%d %%)", aciertos, total, porcentaje)
	if r.YaEntregado then
		texto = "Ya enviaste este cuestionario en esta jornada. " .. texto
	end
	local recompensa = numero(r.Recompensa) or 0
	if recompensa > 0 then
		texto = texto .. " · +" .. Format.Moneda(recompensa) .. " por participación"
	elseif r.Aprobado == false then
		texto = texto .. " · Necesitas el 60 % para ganar la recompensa de participación."
	elseif typeof(r.SinRecompensa) == "string" and r.SinRecompensa ~= "" then
		texto = texto .. " · " .. r.SinRecompensa
	end
	local nivel = "Aviso"
	if porcentaje >= 60 then
		nivel = "Exito"
	end
	fijar(ui.ResultadoCuestionario, texto, nivel)
	local detalle = typeof(r.Detalle) == "table" and r.Detalle or {}
	for i, marca in pairs(ui.MarcasPregunta or {}) do
		if detalle[i] == true then
			fijar(marca, "✔ Correcta", "Exito")
		elseif detalle[i] == false then
			fijar(marca, "✖ Incorrecta", "Error")
		end
	end
	for _, botones in pairs(ui.BotonesOpcion or {}) do
		for _, boton in pairs(botones) do
			UIBuilder.Habilitar(boton, false)
		end
	end
	if ui.BotonEnviarCuestionario then
		UIBuilder.Habilitar(ui.BotonEnviarCuestionario, false)
	end
end

function renderPreguntas()
	local marco = ui.Preguntas
	if not marco then
		return
	end
	limpiarHijos(marco)
	ui.BotonesOpcion = {}
	ui.MarcasPregunta = {}
	ui.RespuestaAulaCaja = nil
	fijar(ui.ResultadoCuestionario, "", "Info")
	if ui.BotonEnviarCuestionario then
		UIBuilder.Habilitar(ui.BotonEnviarCuestionario, true)
	end
	local id = borrador.CuestionarioId
	if id == AULA then
		local act = estado.Actividad
		if not act then
			fijar(ui.InfoCuestionario, "No hay ninguna actividad abierta en tu clase ahora mismo.", "Info")
			if ui.BotonEnviarCuestionario then
				UIBuilder.Habilitar(ui.BotonEnviarCuestionario, false)
			end
			return
		end
		local info = "Actividad de tu docente"
		if act.Salon then
			info = info .. " · " .. act.Salon
		end
		fijar(ui.InfoCuestionario, info .. ". Tu respuesta es privada: solo la ve tu docente.", "Info")
		if act.Tipo == "Opciones" then
			construirPregunta(marco, 1, act.Prompt, act.Opciones, act.MiIndice or borrador.RespuestaAula)
		else
			UIBuilder.Texto(marco, act.Prompt, { Fuente = "Subtitulo", LayoutOrder = 1 })
			local inicial = ""
			if typeof(act.MiRespuesta) == "string" then
				inicial = act.MiRespuesta
			elseif typeof(borrador.RespuestaAula) == "string" then
				inicial = borrador.RespuestaAula
			end
			ui.RespuestaAulaCaja = UIBuilder.Entrada(marco, "Escribe tu respuesta…", {
				Max = MAX_RESPUESTA, Multilinea = true, Alto = 96, LayoutOrder = 2, Texto = inicial,
				Editable = not act.YaRespondida,
				AlCambiar = function(texto)
					borrador.RespuestaAula = texto
				end,
			})
		end
		if act.YaRespondida then
			fijar(ui.ResultadoCuestionario, "Ya respondiste esta actividad. Espera el resultado de tu docente.", "Info")
			for _, botones in pairs(ui.BotonesOpcion) do
				for _, boton in pairs(botones) do
					UIBuilder.Habilitar(boton, false)
				end
			end
			if ui.BotonEnviarCuestionario then
				UIBuilder.Habilitar(ui.BotonEnviarCuestionario, false)
			end
		end
		return
	end
	local cuestionario = Catalogs.Cuestionario(id)
	if not cuestionario then
		fijar(ui.InfoCuestionario, "Elige un cuestionario.", "Info")
		if ui.BotonEnviarCuestionario then
			UIBuilder.Habilitar(ui.BotonEnviarCuestionario, false)
		end
		return
	end
	fijar(ui.InfoCuestionario, TimetableDefinitions.NombreMateria(cuestionario.Materia) .. " · " .. #cuestionario.Preguntas
		.. " preguntas · Una entrega por jornada; con el 60 % o más ganas " .. Format.Moneda(tonumber(Config.Economia and Config.Economia.Recompensas and Config.Economia.Recompensas.Participacion) or 3) .. ".", "Info")
	local propias = respuestasDe(id)
	for i, pregunta in ipairs(cuestionario.Preguntas) do
		construirPregunta(marco, i, pregunta.Texto, pregunta.Opciones, propias[i])
	end
	local entrega = estado.Entregas[id]
	if entrega then
		mostrarEntrega(id, entrega)
	end
end

function refrescarSelectorCuestionario()
	local marco = ui.MarcoSelectorCuestionario
	if not marco then
		return
	end
	limpiarHijos(marco)
	local opciones = opcionesCuestionario()
	local valor = borrador.CuestionarioId
	local valido = false
	for _, opcion in ipairs(opciones) do
		if opcion.Valor == valor then
			valido = true
		end
	end
	if not valido then
		valor = cuestionarioPorDefecto()
	end
	borrador.CuestionarioId = valor
	ui.SelectorCuestionario = UIBuilder.Selector(marco, "Cuestionario", opciones, valor, function(nuevo)
		borrador.CuestionarioId = nuevo
		renderPreguntas()
	end, { Nombre = "Cuestionario", AnchoGrupo = 300, LayoutOrder = 1 })
	renderPreguntas()
end

local function enviarCuestionario()
	local id = borrador.CuestionarioId
	local extra = nil
	if id == AULA then
		local act = estado.Actividad
		if not act then
			fijar(ui.ResultadoCuestionario, "No hay ninguna actividad abierta.", "Aviso")
			return
		end
		extra = { App = "Cuestionario", ActividadId = act.Id, Salon = act.Salon }
		if act.Tipo == "Opciones" then
			if typeof(borrador.RespuestaAula) ~= "number" then
				fijar(ui.ResultadoCuestionario, "Elige una opción antes de enviar.", "Aviso")
				return
			end
			extra.Respuesta = borrador.RespuestaAula
		else
			local texto = Format.Recortar(ui.RespuestaAulaCaja and ui.RespuestaAulaCaja.Text or "")
			if texto == "" then
				fijar(ui.ResultadoCuestionario, "Escribe tu respuesta antes de enviar.", "Aviso")
				return
			end
			extra.Respuesta = texto
		end
	else
		local cuestionario = Catalogs.Cuestionario(id)
		if not cuestionario then
			return
		end
		local propias = respuestasDe(id)
		local lista = {}
		local faltan = 0
		for i = 1, #cuestionario.Preguntas do
			if typeof(propias[i]) == "number" then
				lista[i] = propias[i]
			else
				faltan = faltan + 1
			end
		end
		if faltan > 0 then
			fijar(ui.ResultadoCuestionario, "Te falta responder " .. Format.Plural(faltan, "pregunta") .. ".", "Aviso")
			return
		end
		extra = { App = "Cuestionario", CuestionarioId = id, Respuestas = lista }
	end
	extra.Solicitud = siguienteSolicitud()
	fijar(ui.ResultadoCuestionario, "Enviando respuestas…", "Info")
	ejecutarAccion("Cuestionario", ui.BotonEnviarCuestionario, "Resultado", extra, function(ok, respuesta)
		if ok then
			mostrarResultado(respuesta.datos)
		else
			fijar(ui.ResultadoCuestionario, "No se pudo enviar: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

local function construirCuestionario(area)
	local lista = nuevaApp(area, "Cuestionario")
	local sig = contadorOrden()
	UIBuilder.Titulo(lista, "Cuestionario", { LayoutOrder = sig(), Tamano = "Subtitulo" })
	UIBuilder.Texto(lista, ayudaApp("Cuestionario"), { LayoutOrder = sig(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	ui.MarcoSelectorCuestionario = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Nombre = "SelectorCuestionario" })
	UIBuilder.Disposicion(ui.MarcoSelectorCuestionario, {})
	ui.InfoCuestionario = UIBuilder.Texto(lista, "", { LayoutOrder = sig(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	ui.Preguntas = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Nombre = "Preguntas" })
	UIBuilder.Disposicion(ui.Preguntas, { Espaciado = 10 })
	local fila = UIBuilder.Fila(lista, { LayoutOrder = sig(), Nombre = "AccionesCuestionario" })
	ui.BotonEnviarCuestionario = UIBuilder.Boton(fila, "Enviar respuestas", function()
		enviarCuestionario()
	end, { Estilo = "Primario", Ancho = 210, LayoutOrder = 1, Nombre = "Enviar" })
	ui.ResultadoCuestionario = UIBuilder.Texto(lista, "", { LayoutOrder = sig(), Fuente = "Subtitulo", Nombre = "ResultadoCuestionario" })
	ui.BotonesOpcion = {}
	ui.MarcasPregunta = {}
end

---------------------------------------------------------------------------------------------------
-- App: Simulador educativo
---------------------------------------------------------------------------------------------------
local function experimentoActual()
	return Simulador.Experimentos and Simulador.Experimentos[borrador.Experimento] or nil
end

local function valoresDe(tabla, id)
	local t = tabla[id]
	if not t then
		t = {}
		tabla[id] = t
	end
	return t
end

local function filaNumero(padre, texto, valor, orden, alCambiar)
	local fila = UIBuilder.Marco(padre, { Alto = UIBuilder.AltoBoton(), LayoutOrder = orden, Nombre = "Fila_" .. orden })
	local anchoCaja = 150
	UIBuilder.Texto(fila, texto, {
		AutoAlto = false, Size = UDim2.new(1, -(anchoCaja + 10), 1, 0), AlineacionY = Enum.TextYAlignment.Center,
		Tamano = "Pequeno", Truncar = true, Ajustar = false,
	})
	local caja = UIBuilder.Entrada(fila, "0", {
		Max = 14, Texto = valor or "", Size = UDim2.new(0, anchoCaja, 1, 0), Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0), AlCambiar = alCambiar,
	})
	return caja
end

function renderExperimento()
	local experimento = experimentoActual()
	if not experimento or not ui.EntradasSim then
		return
	end
	limpiarHijos(ui.EntradasSim)
	limpiarHijos(ui.SalidasSim)
	ui.DescripcionExperimento.Text = tostring(experimento.Descripcion or "")
	ui.FormulaExperimento.Text = tostring(experimento.Formula or "")
	ui.CajasEntrada = {}
	ui.CajasSalida = {}
	local entradas = valoresDe(borrador.Entradas, experimento.Id)
	local salidas = valoresDe(borrador.Salidas, experimento.Id)
	local orden = 0
	for _, def in ipairs(experimento.Entradas) do
		orden = orden + 1
		local clave = def.Clave
		if entradas[clave] == nil then
			entradas[clave] = Format.Decimal(def.PorDefecto, 1)
		end
		local etiqueta = def.Nombre .. "  [" .. Format.Decimal(def.Min, 1) .. " – " .. Format.Decimal(def.Max, 1) .. "]"
		ui.CajasEntrada[clave] = filaNumero(ui.EntradasSim, etiqueta, entradas[clave], orden, function(texto)
			entradas[clave] = texto
		end)
		if def.Nota then
			orden = orden + 1
			UIBuilder.Texto(ui.EntradasSim, def.Nota, { LayoutOrder = orden, Tamano = "Pequeno", Color = Colores.TextoApagado })
		end
	end
	orden = 0
	for _, def in ipairs(experimento.Salidas) do
		orden = orden + 1
		local clave = def.Clave
		ui.CajasSalida[clave] = filaNumero(ui.SalidasSim, def.Nombre .. " (" .. def.Unidad .. ")", salidas[clave] or "", orden, function(texto)
			salidas[clave] = texto
		end)
	end
	fijar(ui.ResultadoSim, "", "Info")
end

-- Lee y valida las entradas. Devuelve tabla | nil, mensaje.
local function leerEntradas(experimento)
	local valores = {}
	for _, def in ipairs(experimento.Entradas) do
		local caja = ui.CajasEntrada and ui.CajasEntrada[def.Clave]
		local valor = parsearNumero(caja and caja.Text or "")
		if valor == nil then
			return nil, "Escribe un número en «" .. def.Nombre .. "»."
		end
		if valor < def.Min or valor > def.Max then
			return nil, "«" .. def.Nombre .. "» debe estar entre " .. Format.Decimal(def.Min, 1) .. " y " .. Format.Decimal(def.Max, 1) .. "."
		end
		valores[def.Clave] = valor
	end
	return valores, nil
end

-- Cálculo local (solo para mostrar): rellena tus resultados con las fórmulas de Catalogs.Simulador.
local function calcularLocal()
	local experimento = experimentoActual()
	if not experimento then
		return
	end
	local entradas, err = leerEntradas(experimento)
	if not entradas then
		fijar(ui.ResultadoSim, err, "Aviso")
		return
	end
	local ok, resultado = pcall(Simulador.Calcular, experimento.Id, entradas)
	if not ok or typeof(resultado) ~= "table" then
		fijar(ui.ResultadoSim, "No se pudo calcular.", "Error")
		return
	end
	for clave, valor in pairs(resultado.Salidas or {}) do
		local caja = ui.CajasSalida and ui.CajasSalida[clave]
		if caja then
			caja.Text = Format.Decimal(valor, 3)
		end
	end
	fijar(ui.ResultadoSim, "Cálculo local listo. Pulsa «Validar» para que el servidor compruebe tus resultados.", "Info")
end

local function validarSimulador()
	local experimento = experimentoActual()
	if not experimento then
		return
	end
	local entradas, err = leerEntradas(experimento)
	if not entradas then
		fijar(ui.ResultadoSim, err, "Aviso")
		return
	end
	local salidas = {}
	for _, def in ipairs(experimento.Salidas) do
		local caja = ui.CajasSalida and ui.CajasSalida[def.Clave]
		local valor = parsearNumero(caja and caja.Text or "")
		if valor == nil then
			fijar(ui.ResultadoSim, "Completa «" .. def.Nombre .. "» (o pulsa «Calcular»).", "Aviso")
			return
		end
		salidas[def.Clave] = valor
	end
	fijar(ui.ResultadoSim, "Validando con el servidor…", "Info")
	ejecutarAccion("Simulador", ui.BotonValidarSim, "Resultado", {
		App = "Simulador", Experimento = experimento.Id, Entradas = entradas, Salidas = salidas, Solicitud = siguienteSolicitud(),
	}, function(ok, respuesta)
		if ok then
			mostrarResultado(respuesta.datos)
		else
			fijar(ui.ResultadoSim, "No se pudo validar: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

local function construirSimulador(area)
	local lista = nuevaApp(area, "Simulador")
	local sig = contadorOrden()
	UIBuilder.Titulo(lista, "Simulador educativo", { LayoutOrder = sig(), Tamano = "Subtitulo" })
	UIBuilder.Texto(lista, ayudaApp("Simulador"), { LayoutOrder = sig(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	local opciones = {}
	for _, id in ipairs(Simulador.Orden or {}) do
		local experimento = Simulador.Experimentos[id]
		if experimento then
			table.insert(opciones, { Valor = id, Texto = experimento.Nombre })
		end
	end
	ui.SelectorExperimento = UIBuilder.Selector(lista, "Experimento", opciones, borrador.Experimento, function(valor)
		borrador.Experimento = valor
		renderExperimento()
	end, { LayoutOrder = sig(), Nombre = "Experimento", AnchoGrupo = 260 })
	ui.DescripcionExperimento = UIBuilder.Texto(lista, "", { LayoutOrder = sig(), Color = Colores.TextoSecundario })
	ui.FormulaExperimento = UIBuilder.Texto(lista, "", { LayoutOrder = sig(), Fuente = "Mono", Color = Colores.Amarillo })
	UIBuilder.Subtitulo(lista, "Datos de entrada", { LayoutOrder = sig(), Tamano = "Texto" })
	ui.EntradasSim = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Nombre = "Entradas" })
	UIBuilder.Disposicion(ui.EntradasSim, { Espaciado = 6 })
	UIBuilder.Subtitulo(lista, "Tus resultados", { LayoutOrder = sig(), Tamano = "Texto" })
	ui.SalidasSim = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Nombre = "Salidas" })
	UIBuilder.Disposicion(ui.SalidasSim, { Espaciado = 6 })
	local fila = UIBuilder.Fila(lista, { LayoutOrder = sig(), Nombre = "AccionesSimulador" })
	local calcular = UIBuilder.Boton(fila, "Calcular", function()
		calcularLocal()
	end, { Estilo = "Secundario", Ancho = 140, LayoutOrder = 1, Nombre = "Calcular" })
	ui.BotonValidarSim = UIBuilder.Boton(fila, "Validar con el servidor", function()
		validarSimulador()
	end, { Estilo = "Primario", Ancho = 230, LayoutOrder = 2, Nombre = "Validar" })
	UIBuilder.Encadenar({ calcular, ui.BotonValidarSim }, true)
	ui.ResultadoSim = UIBuilder.Texto(lista, "", { LayoutOrder = sig(), Nombre = "ResultadoSimulador" })
	renderExperimento()
end

---------------------------------------------------------------------------------------------------
-- App: Programación básica (cuadrícula 8×8 con Frames)
---------------------------------------------------------------------------------------------------
local function textoAyudaProgramacion()
	local lineas = {}
	for _, linea in ipairs(Programacion.Ayuda or {}) do
		local ajustada = string.gsub(linea, "hasta %d+ niveles", "hasta " .. tostring(estado.MaxAnidamiento) .. " niveles")
		table.insert(lineas, "• " .. ajustada)
	end
	table.insert(lineas, "• Máximo " .. tostring(MAX_LINEAS) .. " líneas y " .. tostring(Programacion.MaxPasos or 200) .. " pasos por ejecución.")
	return table.concat(lineas, "\n")
end

local function construirCuadricula(padre)
	local marco = Instance.new("Frame")
	marco.Name = "Cuadricula"
	marco.BackgroundColor3 = Colores.GrisPanel
	marco.BorderSizePixel = 0
	marco.Size = UDim2.new(0, 300, 0, 300)
	marco.LayoutOrder = 1
	marco.ClipsDescendants = true
	marco.Parent = padre
	UIBuilder.Esquinas(marco, UITheme.RadioPequeno)
	UIBuilder.Borde(marco, Colores.Borde)
	cuadricula.Marco = marco
	cuadricula.Lado = 300
	cuadricula.Celdas = {}
	for y = 1, N do
		for x = 1, N do
			local celda = Instance.new("Frame")
			celda.Name = "C" .. x .. "_" .. y
			celda.BackgroundColor3 = Colores.Gris
			celda.BorderSizePixel = 0
			celda.Size = UDim2.new(1 / N, -2, 1 / N, -2)
			celda.Position = UDim2.new((x - 1) / N, 1, (y - 1) / N, 1)
			celda.Parent = marco
			cuadricula.Celdas[x .. "," .. y] = celda
		end
	end
	local robot = Instance.new("Frame")
	robot.Name = "Robot"
	robot.BackgroundColor3 = Colores.Amarillo
	robot.BorderSizePixel = 0
	robot.AnchorPoint = Vector2.new(0.5, 0.5)
	robot.Size = UDim2.new(1 / N, -8, 1 / N, -8)
	robot.Position = UDim2.new(0.5 / N, 0, 0.5 / N, 0)
	robot.ZIndex = 3
	robot.Parent = marco
	UIBuilder.Esquinas(robot, UDim.new(0.3, 0))
	local flecha = Instance.new("TextLabel")
	flecha.Name = "Flecha"
	flecha.BackgroundTransparency = 1
	flecha.Size = UDim2.new(1, 0, 1, 0)
	flecha.Font = UITheme.Fuente("Titulo")
	flecha.TextScaled = true
	flecha.TextColor3 = Colores.GrisPanel
	flecha.Text = FLECHAS.E
	flecha.ZIndex = 4
	flecha.Parent = robot
	cuadricula.Robot = robot
	cuadricula.Flecha = flecha
end

function ajustarCuadricula()
	if not ui.ColTablero or not cuadricula.Marco or ui.ColTablero.Parent == nil then
		return
	end
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local ancho = ui.ColTablero.AbsoluteSize.X / escala
	if ancho <= 0 then
		return
	end
	local lado = math.floor(math.clamp(ancho - 8, 160, 340))
	if cuadricula.Lado ~= lado then
		cuadricula.Lado = lado
		cuadricula.Marco.Size = UDim2.new(0, lado, 0, lado)
	end
end

local function pintarTablero(reto)
	if not reto then
		return
	end
	local obstaculos = {}
	for _, o in ipairs(reto.Obstaculos or {}) do
		obstaculos[o.X .. "," .. o.Y] = true
	end
	local meta = reto.Meta.X .. "," .. reto.Meta.Y
	local inicio = reto.Inicio.X .. "," .. reto.Inicio.Y
	for clave, celda in pairs(cuadricula.Celdas) do
		local color = Colores.Gris
		if obstaculos[clave] then
			color = Colores.RojoOscuro
		elseif clave == meta then
			color = Colores.Verde
		elseif clave == inicio then
			color = Colores.Azul
		end
		celda.BackgroundColor3 = color
	end
	cuadricula.Obstaculos = obstaculos
	cuadricula.Reto = reto
	if cuadricula.Robot then
		cuadricula.Robot.BackgroundColor3 = Colores.Amarillo
	end
end

local function marcarVisitada(x, y)
	local reto = cuadricula.Reto
	local clave = tostring(x) .. "," .. tostring(y)
	local celda = cuadricula.Celdas[clave]
	if not celda or not reto or cuadricula.Obstaculos[clave] then
		return
	end
	if clave == reto.Meta.X .. "," .. reto.Meta.Y or clave == reto.Inicio.X .. "," .. reto.Inicio.Y then
		return
	end
	celda.BackgroundColor3 = UITheme.Aclarar(Colores.Gris, 0.22)
end

local function colocarRobot(x, y, dir, animar)
	if not cuadricula.Robot then
		return
	end
	local cx = math.clamp(math.floor(numero(x) or 1), 1, N)
	local cy = math.clamp(math.floor(numero(y) or 1), 1, N)
	local posicion = UDim2.new((cx - 0.5) / N, 0, (cy - 0.5) / N, 0)
	if animar then
		UIBuilder.Tween(cuadricula.Robot, { Position = posicion }, PASO_ANIMACION * 0.8)
	else
		cuadricula.Robot.Position = posicion
	end
	cuadricula.Flecha.Text = FLECHAS[dir] or "●"
end

local function reiniciarRobot()
	tokenAnimacion = tokenAnimacion + 1
	local reto = Programacion.Reto and Programacion.Reto(borrador.RetoId)
	if not reto then
		return
	end
	pintarTablero(reto)
	colocarRobot(reto.Inicio.X, reto.Inicio.Y, reto.Inicio.Dir, false)
	fijar(ui.PasoProg, string.format("Inicio (%d,%d) mirando %s · Meta (%d,%d)", reto.Inicio.X, reto.Inicio.Y, tostring(reto.Inicio.Dir), reto.Meta.X, reto.Meta.Y), "Info")
end

local function actualizarLineas()
	if not ui.ContadorLineas or not ui.Editor then
		return
	end
	local n = 0
	for linea in string.gmatch(ui.Editor.Text .. "\n", "([^\n]*)\n") do
		if Format.Recortar(linea) ~= "" then
			n = n + 1
		end
	end
	ui.ContadorLineas.Text = string.format("Líneas: %d / %d · REPETIR anidado: máx. %d", n, MAX_LINEAS, estado.MaxAnidamiento)
	if n > MAX_LINEAS then
		ui.ContadorLineas.TextColor3 = Colores.Amarillo
	else
		ui.ContadorLineas.TextColor3 = Colores.TextoApagado
	end
end

local function insertarComando(comando)
	if not ui.Editor then
		return
	end
	local texto = ui.Editor.Text
	if texto ~= "" and string.sub(texto, -1) ~= "\n" then
		texto = texto .. "\n"
	end
	ui.Editor.Text = texto .. comando
end

local function borrarUltimaLinea()
	if not ui.Editor then
		return
	end
	local sinFinal = string.gsub(ui.Editor.Text, "\n+$", "")
	local recortado = string.gsub(sinFinal, "\n?[^\n]*$", "")
	ui.Editor.Text = recortado
end

function cambiarReto(id)
	local reto = Programacion.Reto and Programacion.Reto(id)
	if not reto then
		reto = Programacion.Retos and Programacion.Retos[1]
	end
	if not reto then
		return
	end
	borrador.RetoId = reto.Id
	if ui.DescripcionReto then
		ui.DescripcionReto.Text = tostring(reto.Descripcion or "")
	end
	if ui.PistaReto then
		ui.PistaReto.Text = "Pista: " .. tostring(reto.Pista or "")
		ui.PistaReto.Visible = false
	end
	if ui.Editor then
		ui.Editor.Text = borrador.Programas[reto.Id] or ""
	end
	fijar(ui.ResultadoProg, "", "Info")
	reiniciarRobot()
	actualizarLineas()
end

-- Anima la traza devuelta por el servidor paso a paso (cancelable con tokenAnimacion).
local function animarTraza(reto, traza, alTerminar)
	tokenAnimacion = tokenAnimacion + 1
	local token = tokenAnimacion
	pintarTablero(reto)
	colocarRobot(reto.Inicio.X, reto.Inicio.Y, reto.Inicio.Dir, false)
	if UIBuilder.MovimientoReducido() or #traza == 0 then
		for _, paso in ipairs(traza) do
			marcarVisitada(paso.X, paso.Y)
		end
		local ultimo = traza[#traza]
		if ultimo then
			colocarRobot(ultimo.X, ultimo.Y, ultimo.Dir, false)
		end
		alTerminar()
		return
	end
	task.spawn(function()
		for i, paso in ipairs(traza) do
			task.wait(PASO_ANIMACION)
			if token ~= tokenAnimacion or not estado.Abierto then
				return
			end
			marcarVisitada(paso.X, paso.Y)
			colocarRobot(paso.X, paso.Y, paso.Dir, true)
			fijar(ui.PasoProg, string.format("Paso %d de %d: %s → (%d,%d)", i, #traza, tostring(paso.Comando or ""),
				math.floor(numero(paso.X) or 0), math.floor(numero(paso.Y) or 0)), "Info")
		end
		task.wait(PASO_ANIMACION)
		if token == tokenAnimacion and estado.Abierto then
			alTerminar()
		end
	end)
end

local function ejecutarPrograma()
	if not ui.Editor then
		return
	end
	local texto = ui.Editor.Text
	if Format.Recortar(texto) == "" then
		fijar(ui.ResultadoProg, "Escribe al menos un comando (usa los botones de arriba si lo prefieres).", "Aviso")
		return
	end
	reiniciarRobot()
	fijar(ui.ResultadoProg, "Ejecutando el programa en el servidor…", "Info")
	ejecutarAccion("Programacion", ui.BotonEjecutar, "Resultado", {
		App = "Programacion", RetoId = borrador.RetoId, Programa = texto, Solicitud = siguienteSolicitud(),
	}, function(ok, respuesta)
		if ok then
			mostrarResultado(respuesta.datos)
		else
			fijar(ui.ResultadoProg, "No se pudo ejecutar: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

local function construirProgramacion(area)
	local lista = nuevaApp(area, "Programacion")
	local sig = contadorOrden()
	UIBuilder.Titulo(lista, "Programación básica", { LayoutOrder = sig(), Tamano = "Subtitulo" })
	local columnas = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Nombre = "Columnas" })
	ui.LayoutColumnas = UIBuilder.Disposicion(columnas, { Horizontal = true, Espaciado = 12, AlineacionVertical = Enum.VerticalAlignment.Top })
	local colEditor = UIBuilder.Marco(columnas, { AutoAlto = true, LayoutOrder = 1, Nombre = "ColEditor" })
	UIBuilder.Disposicion(colEditor, { Espaciado = 8 })
	local colTablero = UIBuilder.Marco(columnas, { AutoAlto = true, LayoutOrder = 2, Nombre = "ColTablero" })
	UIBuilder.Disposicion(colTablero, { Espaciado = 8, Alineacion = Enum.HorizontalAlignment.Center })
	ui.ColEditor = colEditor
	ui.ColTablero = colTablero

	local opciones = {}
	for _, reto in ipairs(Programacion.Retos or {}) do
		table.insert(opciones, { Valor = reto.Id, Texto = reto.Nombre .. " (nivel " .. tostring(reto.Dificultad or 1) .. ")" })
	end
	ui.SelectorReto = UIBuilder.Selector(colEditor, "Reto", opciones, borrador.RetoId, function(valor)
		cambiarReto(valor)
	end, { LayoutOrder = 1, Nombre = "Reto", AnchoGrupo = 240 })
	ui.DescripcionReto = UIBuilder.Texto(colEditor, "", { LayoutOrder = 2, Color = Colores.TextoSecundario })
	local filaAyuda = UIBuilder.Fila(colEditor, { LayoutOrder = 3, Nombre = "FilaAyuda" })
	UIBuilder.Boton(filaAyuda, "Ver pista", function()
		if ui.PistaReto then
			ui.PistaReto.Visible = not ui.PistaReto.Visible
		end
	end, { Estilo = "Fantasma", Ancho = 120, LayoutOrder = 1, Nombre = "Pista" })
	UIBuilder.Boton(filaAyuda, "Ayuda de comandos", function()
		if ui.AyudaProg then
			ui.AyudaProg.Text = textoAyudaProgramacion()
			ui.AyudaProg.Visible = not ui.AyudaProg.Visible
		end
	end, { Estilo = "Fantasma", Ancho = 200, LayoutOrder = 2, Nombre = "AyudaComandos" })
	ui.PistaReto = UIBuilder.Texto(colEditor, "", { LayoutOrder = 4, Color = Colores.Amarillo, Tamano = "Pequeno", Visible = false })
	ui.AyudaProg = UIBuilder.Texto(colEditor, textoAyudaProgramacion(), {
		LayoutOrder = 5, Tamano = "Pequeno", Color = Colores.TextoSecundario, Visible = false,
	})
	local rapidos = UIBuilder.Marco(colEditor, { AutoAlto = true, LayoutOrder = 6, Nombre = "ComandosRapidos" })
	UIBuilder.Disposicion(rapidos, { Horizontal = true, Espaciado = 6, Wraps = true })
	local botonesRapidos = {}
	for i, comando in ipairs(COMANDOS_RAPIDOS) do
		table.insert(botonesRapidos, UIBuilder.Boton(rapidos, comando, function()
			insertarComando(comando)
		end, { Estilo = "Secundario", Ancho = 118, LayoutOrder = i, Tamano = "Pequeno", Nombre = "Cmd_" .. i }))
	end
	table.insert(botonesRapidos, UIBuilder.Boton(rapidos, "Borrar línea", function()
		borrarUltimaLinea()
	end, { Estilo = "Fantasma", Ancho = 124, LayoutOrder = 20, Tamano = "Pequeno", Nombre = "BorrarLinea" }))
	UIBuilder.Encadenar(botonesRapidos, true)
	local editor, marcoEditor = editorMultilinea(colEditor, "AVANZAR\nGIRAR_IZQ\nREPETIR 3\nAVANZAR\nFIN", {
		Max = MAX_EDITOR, Texto = borrador.Programas[borrador.RetoId] or "", Nombre = "Codigo", NombreMarco = "MarcoCodigo",
		AltoMarco = 200, LayoutOrder = 7, Fuente = "Mono",
		AlCambiar = function(texto)
			borrador.Programas[borrador.RetoId] = texto
			actualizarLineas()
		end,
	})
	ui.Editor = editor
	ui.MarcoCodigo = marcoEditor
	ui.ContadorLineas = UIBuilder.Texto(colEditor, "", {
		LayoutOrder = 8, Tamano = "Pequeno", Color = Colores.TextoApagado, Alineacion = Enum.TextXAlignment.Right,
	})
	local filaEjecutar = UIBuilder.Fila(colEditor, { LayoutOrder = 9, Nombre = "AccionesProgramacion" })
	ui.BotonEjecutar = UIBuilder.Boton(filaEjecutar, "Ejecutar", function()
		ejecutarPrograma()
	end, { Estilo = "Primario", Ancho = 150, LayoutOrder = 1, Icono = "▶", Nombre = "Ejecutar" })
	local limpiar = UIBuilder.Boton(filaEjecutar, "Limpiar", function()
		if ui.Editor then
			ui.Editor.Text = ""
		end
	end, { Estilo = "Secundario", Ancho = 110, LayoutOrder = 2, Nombre = "LimpiarCodigo" })
	local reiniciar = UIBuilder.Boton(filaEjecutar, "Reiniciar robot", function()
		reiniciarRobot()
		fijar(ui.ResultadoProg, "", "Info")
	end, { Estilo = "Fantasma", Ancho = 160, LayoutOrder = 3, Nombre = "Reiniciar" })
	UIBuilder.Encadenar({ ui.BotonEjecutar, limpiar, reiniciar }, true)
	ui.ResultadoProg = UIBuilder.Texto(colEditor, "", { LayoutOrder = 10, Nombre = "ResultadoProgramacion" })

	construirCuadricula(colTablero)
	ui.PasoProg = UIBuilder.Texto(colTablero, "", {
		LayoutOrder = 2, Tamano = "Pequeno", Color = Colores.TextoSecundario, Alineacion = Enum.TextXAlignment.Center,
	})
	UIBuilder.Texto(colTablero, string.format(
		'<font color="%s">■</font> Inicio   <font color="%s">■</font> Meta   <font color="%s">■</font> Obstáculo   <font color="%s">■</font> Robot',
		hex(Colores.Azul), hex(Colores.Verde), hex(Colores.RojoOscuro), hex(Colores.Amarillo)), {
		LayoutOrder = 3, Tamano = "Pequeno", Rico = true, Alineacion = Enum.TextXAlignment.Center, Color = Colores.TextoSecundario,
	})
	maidUI:GiveTask(colTablero:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		ajustarCuadricula()
	end))
	cambiarReto(borrador.RetoId)
end

---------------------------------------------------------------------------------------------------
-- App: Pantalla de clase (+ controles del docente)
---------------------------------------------------------------------------------------------------
function refrescarPantallaClase()
	if not ui.TextoProyeccion then
		return
	end
	local proyeccion = estado.Proyeccion
	if proyeccion and typeof(proyeccion.Texto) == "string" and proyeccion.Texto ~= "" then
		ui.TextoProyeccion.Text = proyeccion.Texto
		ui.TextoProyeccion.TextColor3 = Colores.TextoPrincipal
		local pie = "Proyectado por " .. tostring(proyeccion.Autor or "el docente")
		local hora = horaCorta(proyeccion.T)
		if hora ~= "" then
			pie = pie .. " · " .. hora
		end
		ui.AutorProyeccion.Text = pie
	else
		ui.TextoProyeccion.Text = "El docente todavía no ha proyectado nada en esta sala."
		ui.TextoProyeccion.TextColor3 = Colores.TextoApagado
		ui.AutorProyeccion.Text = ""
	end
end

function refrescarControlesDocente()
	if ui.ControlesDocente then
		ui.ControlesDocente.Visible = tienePermisoDocente()
	end
end

local function actualizarContadorProyeccion()
	if ui.ContadorProyeccion and ui.EntradaProyeccion then
		ui.ContadorProyeccion.Text = tostring(Format.Longitud(ui.EntradaProyeccion.Text)) .. " / " .. MAX_PROYECCION
	end
end

-- Destino de las acciones docentes: el PC en uso o, sin él, la sala actual (el servidor valida todo).
local function destinoDocente()
	return estado.PcId or estado.RoomId or "SALA"
end

local function accionDocenteUI(accion, extra, boton, textoOk)
	if estado.Ocupado["Docente"] then
		return
	end
	estado.Ocupado["Docente"] = true
	if boton then
		UIBuilder.Habilitar(boton, false)
	end
	fijar(ui.EstadoDocente, "Enviando…", "Info")
	task.spawn(function()
		local ok, respuesta = enviarAccion(accion, extra, destinoDocente())
		estado.Ocupado["Docente"] = nil
		if boton and boton.Parent ~= nil then
			UIBuilder.Habilitar(boton, true)
		end
		if ok then
			local mensaje = textoOk
			if typeof(respuesta.datos) == "table" and typeof(respuesta.datos.Mensaje) == "string" then
				mensaje = respuesta.datos.Mensaje
			end
			fijar(ui.EstadoDocente, mensaje, "Exito")
		else
			fijar(ui.EstadoDocente, "No se pudo: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

local function construirPantallaClase(area)
	local lista = nuevaApp(area, APP_PANTALLA)
	local sig = contadorOrden()
	UIBuilder.Titulo(lista, "Pantalla de clase", { LayoutOrder = sig(), Tamano = "Subtitulo" })
	UIBuilder.Texto(lista, ayudaApp(APP_PANTALLA), { LayoutOrder = sig(), Tamano = "Pequeno", Color = Colores.TextoSecundario })
	local marco = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Color = Colores.Gris, Transparencia = 0, Nombre = "Proyeccion" })
	UIBuilder.Esquinas(marco, UITheme.Radio)
	UIBuilder.Borde(marco, Colores.Borde)
	UIBuilder.Relleno(marco, 16)
	UIBuilder.Disposicion(marco, { Espaciado = 8 })
	local minimo = Instance.new("UISizeConstraint")
	minimo.MinSize = Vector2.new(0, 150)
	minimo.Parent = marco
	ui.TextoProyeccion = UIBuilder.Texto(marco, "", { LayoutOrder = 1, Fuente = "Subtitulo", Tamano = "Titulo", Nombre = "TextoProyeccion" })
	ui.AutorProyeccion = UIBuilder.Texto(marco, "", { LayoutOrder = 2, Tamano = "Pequeno", Color = Colores.TextoApagado, Nombre = "AutorProyeccion" })

	local docente = UIBuilder.Marco(lista, { AutoAlto = true, LayoutOrder = sig(), Nombre = "ControlesDocente", Visible = false })
	UIBuilder.Disposicion(docente, { Espaciado = 8 })
	UIBuilder.Separador(docente, { LayoutOrder = 1 })
	UIBuilder.Subtitulo(docente, "Controles del docente", { LayoutOrder = 2 })
	UIBuilder.Texto(docente, "Proyecta instrucciones en todas las pantallas de la sala y en el tablero (máximo " .. MAX_PROYECCION
		.. " caracteres; el texto se filtra antes de mostrarse). También puedes bloquear todos los equipos de la sala.", {
		LayoutOrder = 3, Tamano = "Pequeno", Color = Colores.TextoSecundario,
	})
	ui.EntradaProyeccion = UIBuilder.Entrada(docente, "Instrucciones para la clase…", {
		Max = MAX_PROYECCION, Multilinea = true, Alto = 90, LayoutOrder = 4, Texto = borrador.TextoProyeccion, Nombre = "EntradaProyeccion",
		AlCambiar = function(texto)
			borrador.TextoProyeccion = texto
			actualizarContadorProyeccion()
		end,
	})
	ui.ContadorProyeccion = UIBuilder.Texto(docente, "", {
		LayoutOrder = 5, Tamano = "Pequeno", Color = Colores.TextoApagado, Alineacion = Enum.TextXAlignment.Right,
	})
	local fila1 = UIBuilder.Fila(docente, { LayoutOrder = 6, Nombre = "FilaProyeccion" })
	local proyectar
	proyectar = UIBuilder.Boton(fila1, "Proyectar", function()
		local texto = Format.Recortar(ui.EntradaProyeccion and ui.EntradaProyeccion.Text or "")
		if texto == "" then
			fijar(ui.EstadoDocente, "Escribe el texto que quieres proyectar.", "Aviso")
			return
		end
		accionDocenteUI("Proyectar", { Texto = texto }, proyectar, "Texto proyectado en la sala.")
	end, { Estilo = "Primario", Ancho = 150, LayoutOrder = 1, Nombre = "Proyectar" })
	local quitar
	quitar = UIBuilder.Boton(fila1, "Quitar proyección", function()
		accionDocenteUI("Proyectar", { Texto = "" }, quitar, "Proyección retirada.")
	end, { Estilo = "Secundario", Ancho = 190, LayoutOrder = 2, Nombre = "QuitarProyeccion" })
	local fila2 = UIBuilder.Fila(docente, { LayoutOrder = 7, Nombre = "FilaBloqueo" })
	local bloquear
	bloquear = UIBuilder.Boton(fila2, "Bloquear sala", function()
		accionDocenteUI("Bloquear", nil, bloquear, "Equipos de la sala bloqueados.")
	end, { Estilo = "Peligro", Ancho = 160, LayoutOrder = 1, Nombre = "BloquearSala" })
	local desbloquear
	desbloquear = UIBuilder.Boton(fila2, "Desbloquear sala", function()
		accionDocenteUI("Desbloquear", nil, desbloquear, "Equipos de la sala desbloqueados.")
	end, { Estilo = "Exito", Ancho = 180, LayoutOrder = 2, Nombre = "DesbloquearSala" })
	UIBuilder.Encadenar({ proyectar, quitar }, true)
	UIBuilder.Encadenar({ bloquear, desbloquear }, true)
	ui.EstadoDocente = UIBuilder.Texto(docente, "", { LayoutOrder = 8, Nombre = "EstadoDocente" })
	ui.ControlesDocente = docente
	actualizarContadorProyeccion()
	refrescarPantallaClase()
	refrescarControlesDocente()
end

---------------------------------------------------------------------------------------------------
-- Ventana
---------------------------------------------------------------------------------------------------
local function construirVentana()
	maidUI:DoCleaning()
	ui = { Apps = {}, Pestanas = {}, BotonesOpcion = {}, MarcasPregunta = {} }
	cuadricula = { Celdas = {}, Robot = nil, Flecha = nil, Marco = nil, Lado = 0, Obstaculos = {}, Reto = nil }
	local gui = UIBuilder.Pantalla("PC", ORDEN_PANTALLA, { Visible = false })
	ui.Gui = gui
	local contenedor = UIBuilder.Contenedor(gui)
	ui.Contenedor = contenedor
	local panel, cuerpo = UIBuilder.Panel(contenedor, {
		Nombre = "EscritorioEscolar", Size = UDim2.new(1, 0, 1, 0), SinPadding = true,
	})
	panel.Visible = false
	pcall(function()
		panel.SelectionGroup = true
	end)
	local limite = Instance.new("UISizeConstraint")
	limite.MaxSize = TAMANO_MAX_VENTANA
	limite.Parent = panel
	ui.Panel = panel
	ui.Limite = limite
	ui.Cuerpo = cuerpo

	construirBarraSuperior(cuerpo)
	construirPestanas(cuerpo)
	local arriba = ALTO_BARRA + ui.AltoPestanas + 12
	local area = Instance.new("Frame")
	area.Name = "Area"
	area.BackgroundTransparency = 1
	area.BorderSizePixel = 0
	area.ClipsDescendants = true
	area.Position = UDim2.new(0, 10, 0, arriba)
	area.Size = UDim2.new(1, -20, 1, -(arriba + ALTO_ESTADO + 10))
	area.Parent = cuerpo
	ui.Area = area
	construirProcesador(area)
	construirCuestionario(area)
	construirSimulador(area)
	construirProgramacion(area)
	construirPantallaClase(area)
	construirBarraEstado(cuerpo)
	construirCapas(cuerpo)
	refrescarSelectorCuestionario()
end

local function asegurarUI()
	if not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil then
		construirVentana()
	end
end

local function esMovil()
	local viewport = UIBuilder.Viewport()
	return UIBuilder.EsEstrecho() or (UIBuilder.EsTactil() and viewport.Y < 560)
end

-- Márgenes del contenedor: barra superior de Roblox arriba y 150 px inferiores libres en táctil. En pantallas
-- táctiles bajas (móvil en horizontal) la ventana ocupa todo el alto y deja libres las dos franjas laterales,
-- donde están el joystick y el botón de salto, en lugar de la franja inferior.
local function ajustarContenedor()
	local relleno = ui.Contenedor and ui.Contenedor:FindFirstChildOfClass("UIPadding")
	if not relleno then
		return
	end
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local espacio = UITheme.Espaciado
	local arriba = math.ceil(UIBuilder.InsetSuperior() / escala) + espacio
	local abajo = math.ceil(UIBuilder.MargenInferiorTactil() / escala) + espacio
	local lados = espacio
	if UIBuilder.EsTactil() and UIBuilder.AltoUI() - arriba - abajo < 380 then
		abajo = espacio
		lados = math.ceil(UIBuilder.MargenTactilPx / escala) + espacio
	end
	relleno.PaddingTop = UDim.new(0, arriba)
	relleno.PaddingBottom = UDim.new(0, abajo)
	relleno.PaddingLeft = UDim.new(0, lados)
	relleno.PaddingRight = UDim.new(0, lados)
end

function actualizarDisposicion()
	if not ui.Panel or ui.Panel.Parent == nil then
		return
	end
	local movil = esMovil()
	estado.Movil = movil
	ajustarContenedor()
	if movil then
		ui.Limite.MaxSize = Vector2.new(math.huge, math.huge)
	else
		ui.Limite.MaxSize = TAMANO_MAX_VENTANA
	end
	for _, app in ipairs(APPS) do
		local boton = ui.Pestanas[app.Id]
		if boton then
			boton.Text = textoPestana(app)
			local ancho = 196
			if movil then
				ancho = 128
			end
			boton.Size = UDim2.new(0, ancho, 0, boton.Size.Y.Offset)
		end
	end
	if ui.Titulo then
		if movil then
			ui.Titulo.Text = "Escritorio"
		else
			ui.Titulo.Text = "Escritorio escolar"
		end
	end
	if ui.LayoutColumnas then
		if movil then
			ui.LayoutColumnas.FillDirection = Enum.FillDirection.Vertical
			ui.ColEditor.Size = UDim2.new(1, 0, 0, 0)
			ui.ColTablero.Size = UDim2.new(1, 0, 0, 0)
		else
			ui.LayoutColumnas.FillDirection = Enum.FillDirection.Horizontal
			ui.ColEditor.Size = UDim2.new(0.56, -6, 0, 0)
			ui.ColTablero.Size = UDim2.new(0.44, -6, 0, 0)
		end
	end
	if ui.MarcoDocumento then
		local alto = 260
		if movil then
			alto = 180
		end
		ui.MarcoDocumento.Size = UDim2.new(1, -4, 0, alto)
	end
	task.defer(ajustarCuadricula)
end

function refrescarOverlays()
	if not ui.CapaApagado or not ui.CapaBloqueo then
		return
	end
	-- El docente con pc.bloquear no ve la capa de bloqueo: desde su equipo desbloquea la sala (el servidor lo permite).
	local bloqueado = estado.Bloqueado == true and not tienePermisoDocente()
	local apagado = (not bloqueado) and estado.Encendido == false
	local antesBloqueo = ui.CapaBloqueo.Visible
	local antesApagado = ui.CapaApagado.Visible
	ui.CapaBloqueo.Visible = bloqueado
	ui.CapaApagado.Visible = apagado
	if ui.BotonApagar then
		UIBuilder.Habilitar(ui.BotonApagar, estado.Encendido == true and not bloqueado)
	end
	if estado.Abierto then
		if bloqueado and not antesBloqueo then
			UIBuilder.Enfocar(ui.BotonSalirBloqueo)
			fijarBarraEstado("El docente bloqueó los equipos de la sala.", "Aviso")
		elseif apagado and not antesApagado then
			UIBuilder.Enfocar(ui.BotonEncender)
			fijarBarraEstado("Equipo apagado.", "Info")
		elseif (antesBloqueo or antesApagado) and not bloqueado and not apagado then
			UIBuilder.EnfocarPrimero(ui.ListaPestanas)
			fijarBarraEstado("Escritorio listo.", "Exito")
		end
	end
end

-- Informa al servidor de la app activa (con espera para no gastar el límite de PCAction al cambiar rápido).
local function programarAvisoApp()
	if estado.AvisoAppPendiente then
		return
	end
	estado.AvisoAppPendiente = true
	task.delay(DEBOUNCE_APP, function()
		estado.AvisoAppPendiente = false
		if not estado.Abierto or estado.Encendido ~= true or (estado.Bloqueado and not tienePermisoDocente()) then
			return
		end
		local app = estado.App
		if app == estado.AppEnviada then
			return
		end
		estado.AppEnviada = app
		local ok = enviarAccion("Aplicacion", { App = app })
		if not ok then
			estado.AppEnviada = nil
		end
	end)
end

function seleccionarApp(id, avisarServidor)
	if not ui.Apps[id] then
		id = "Procesador"
	end
	estado.App = id
	for appId, app in pairs(ui.Apps) do
		app.Marco.Visible = appId == id
	end
	for appId, boton in pairs(ui.Pestanas) do
		boton:SetAttribute("Estilo", appId == id and "Primario" or "Secundario")
		UIBuilder.Habilitar(boton, true)
	end
	if id == APP_PANTALLA and estado.Novedad then
		estado.Novedad = false
		for _, app in ipairs(APPS) do
			if app.Id == APP_PANTALLA and ui.Pestanas[app.Id] then
				ui.Pestanas[app.Id].Text = textoPestana(app)
			end
		end
	end
	if id == APP_PANTALLA then
		refrescarPantallaClase()
	elseif id == "Programacion" then
		task.defer(ajustarCuadricula)
	end
	if avisarServidor then
		programarAvisoApp()
	end
end

local function marcarNovedad()
	estado.Novedad = true
	for _, app in ipairs(APPS) do
		if app.Id == APP_PANTALLA and ui.Pestanas[app.Id] then
			ui.Pestanas[app.Id].Text = textoPestana(app)
		end
	end
end

local function textoCabecera()
	local partes = { tostring(Config.NombreCorto or Config.NombreColegio or "") }
	if estado.Numero then
		table.insert(partes, "Equipo " .. tostring(estado.Numero))
	elseif estado.PcId then
		table.insert(partes, estado.PcId)
	end
	if estado.NombreSala then
		table.insert(partes, estado.NombreSala)
	end
	return table.concat(partes, " · ")
end

local function refrescarContenido()
	if ui.Subtitulo then
		ui.Subtitulo.Text = textoCabecera()
	end
	if ui.Reloj then
		ui.Reloj.Text = textoReloj()
	end
	if ui.SelectorMateria and borrador.MateriaTexto == nil then
		ui.SelectorMateria:Fijar(estado.Materia, true)
	end
	refrescarSelectorCuestionario()
	refrescarPantallaClase()
	refrescarControlesDocente()
	actualizarContadorTexto()
	actualizarLineas()
	refrescarOverlays()
end

local function bucleReloj()
	while estado.Abierto do
		if ui.Reloj and ui.Reloj.Parent ~= nil then
			local texto = textoReloj()
			if ui.Reloj.Text ~= texto then
				ui.Reloj.Text = texto
			end
		end
		task.wait(1)
	end
end

local function conectarCamara()
	local camara = workspace.CurrentCamera
	if camara then
		maidVentana:GiveTask(camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			actualizarDisposicion()
		end))
	end
end

---------------------------------------------------------------------------------------------------
-- Resultados del servidor
---------------------------------------------------------------------------------------------------
local function resultadoProcesador(r)
	local texto = "Guardado en tu cuaderno"
	if typeof(r.NombreMateria) == "string" then
		texto = texto .. " (" .. r.NombreMateria .. ")"
	end
	if numero(r.Pagina) then
		texto = texto .. ", página " .. tostring(math.floor(numero(r.Pagina)))
	end
	fijar(ui.EstadoTexto, texto .. " · " .. tostring(math.floor(numero(r.Caracteres) or 0)) .. " caracteres.", "Exito")
end

local function resultadoCuestionario(r)
	if r.Aula then
		fijar(ui.ResultadoCuestionario, tostring(r.Mensaje or "Respuesta enviada a tu docente."), "Exito")
		if estado.Actividad and estado.Actividad.Id == r.ActividadId then
			estado.Actividad.YaRespondida = true
		end
		for _, botones in pairs(ui.BotonesOpcion or {}) do
			for _, boton in pairs(botones) do
				UIBuilder.Habilitar(boton, false)
			end
		end
		if ui.BotonEnviarCuestionario then
			UIBuilder.Habilitar(ui.BotonEnviarCuestionario, false)
		end
		return
	end
	local id = r.CuestionarioId
	if typeof(id) ~= "string" then
		return
	end
	estado.Entregas[id] = r
	if borrador.CuestionarioId == id then
		mostrarEntrega(id, r)
	end
	if not r.YaEntregado and (numero(r.Recompensa) or 0) > 0 then
		notificar("¡Bien hecho! +" .. Format.Moneda(numero(r.Recompensa)) .. " por participación.", "exito")
	end
end

local function resultadoSimulador(r)
	local experimento = Simulador.Experimentos and Simulador.Experimentos[r.Experimento]
	if not experimento then
		return
	end
	local lineas = {}
	local tolerancia = math.floor(numero(r.ToleranciaPorcentaje) or 2)
	if r.Correcto then
		table.insert(lineas, "✔ ¡Resultados correctos! (tolerancia " .. tolerancia .. " %)")
	else
		table.insert(lineas, "✖ Hay resultados fuera de la tolerancia del " .. tolerancia .. " %.")
	end
	for _, def in ipairs(experimento.Salidas) do
		local revision = typeof(r.Revision) == "table" and r.Revision[def.Clave] or nil
		if typeof(revision) == "table" then
			local esperado = Format.Decimal(numero(revision.Esperado) or 0, 3)
			if revision.Correcto then
				table.insert(lineas, "✔ " .. def.Nombre .. ": " .. esperado .. " " .. def.Unidad)
			else
				local enviado = "—"
				if numero(revision.Enviado) then
					enviado = Format.Decimal(numero(revision.Enviado), 3)
				end
				table.insert(lineas, "✖ " .. def.Nombre .. ": tu valor " .. enviado .. " · correcto " .. esperado .. " " .. def.Unidad)
			end
		end
	end
	local nivel = "Aviso"
	if r.Correcto then
		nivel = "Exito"
	end
	fijar(ui.ResultadoSim, table.concat(lineas, "\n"), nivel)
end

local function resultadoProgramacion(r)
	local reto = Programacion.Reto and Programacion.Reto(r.RetoId)
	if not reto then
		return
	end
	if borrador.RetoId ~= reto.Id then
		borrador.RetoId = reto.Id
		if ui.SelectorReto then
			ui.SelectorReto:Fijar(reto.Id, true)
		end
		cambiarReto(reto.Id)
	end
	local traza = typeof(r.Traza) == "table" and r.Traza or {}
	local pasos = math.floor(numero(r.Pasos) or #traza)
	fijar(ui.ResultadoProg, "El robot recorre " .. Format.Plural(#traza, "paso") .. "…", "Info")
	animarTraza(reto, traza, function()
		if r.Exito then
			fijar(ui.ResultadoProg, "✔ ¡Meta alcanzada en " .. Format.Plural(pasos, "paso") .. "!", "Exito")
			if cuadricula.Robot then
				cuadricula.Robot.BackgroundColor3 = Colores.Verde
			end
		else
			fijar(ui.ResultadoProg, "✖ " .. tostring(r.Error or "El robot no llegó a la meta."), "Error")
			if cuadricula.Robot then
				cuadricula.Robot.BackgroundColor3 = Colores.Rojo
			end
		end
	end)
end

function mostrarResultado(r)
	if typeof(r) ~= "table" or yaMostrado(r.Solicitud) then
		return
	end
	local app = r.App
	local ok, err = true, nil
	if app == "Procesador" then
		ok, err = pcall(resultadoProcesador, r)
	elseif app == "Cuestionario" then
		ok, err = pcall(resultadoCuestionario, r)
	elseif app == "Simulador" then
		ok, err = pcall(resultadoSimulador, r)
	elseif app == "Programacion" then
		ok, err = pcall(resultadoProgramacion, r)
	end
	if not ok then
		warn(LOG .. "Error mostrando el resultado de " .. tostring(app) .. ": " .. tostring(err))
	end
end

---------------------------------------------------------------------------------------------------
-- Eventos del servidor
---------------------------------------------------------------------------------------------------
local function alEstado(datos)
	if not estado.Abierto or datos.PcId ~= estado.PcId then
		return
	end
	if datos.Ocupante == nil or datos.Ocupante ~= LocalPlayer.UserId then
		if typeof(datos.Motivo) == "string" and datos.Motivo ~= "" then
			notificar(datos.Motivo, "aviso")
		end
		PCController.Cerrar(false)
		return
	end
	estado.Encendido = datos.Encendido == true
	estado.Bloqueado = datos.Bloqueado == true
	refrescarOverlays()
end

local function alProyeccion(datos)
	if typeof(datos.RoomId) ~= "string" then
		return
	end
	local info = nil
	if typeof(datos.Texto) == "string" and datos.Texto ~= "" then
		info = { Texto = datos.Texto, Autor = datos.Autor, T = datos.T }
	end
	estado.ProyeccionesPorSala[datos.RoomId] = info
	if datos.RoomId == estado.RoomId then
		estado.Proyeccion = info
		refrescarPantallaClase()
		if estado.Abierto and info and estado.App ~= APP_PANTALLA then
			marcarNovedad()
			fijarBarraEstado("El docente proyectó un texto nuevo: abre «Pantalla de clase».", "Aviso")
		end
	end
end

local function alBloqueo(datos)
	if typeof(datos.RoomId) ~= "string" then
		return
	end
	if estado.Abierto and datos.RoomId == estado.RoomId then
		estado.Bloqueado = datos.Bloqueado == true
		refrescarOverlays()
	end
	if ui.EstadoDocente and tienePermisoDocente() then
		local texto = "Sala " .. datos.RoomId .. (datos.Bloqueado and " bloqueada." or " desbloqueada.")
		fijar(ui.EstadoDocente, texto, "Info")
	end
end

local function alEventoPC(datos)
	local sub = datos.Sub
	if sub == "AbrirEscritorio" then
		PCController.Abrir(datos)
	elseif sub == "Estado" then
		alEstado(datos)
	elseif sub == "Resultado" then
		if estado.Abierto and datos.PcId == estado.PcId then
			mostrarResultado(datos)
		end
	elseif sub == "Proyeccion" then
		alProyeccion(datos)
	elseif sub == "Bloqueo" then
		alBloqueo(datos)
	end
end

local function alJornada(datos)
	estado.Jornada = datos
	if typeof(datos.Materia) == "string" and TimetableDefinitions.Materias[datos.Materia] then
		estado.Materia = datos.Materia
	end
end

-- Actividades del aula (ClassroomService: Sub "Actividad" / "ActividadCerrada" / "SesionCerrada").
local function alAula(datos)
	local sub = datos.Sub
	local cambio = false
	if sub == "ActividadCerrada" then
		if estado.Actividad and (datos.ActividadId == nil or datos.ActividadId == estado.Actividad.Id) then
			estado.Actividad = nil
			cambio = true
		end
	elseif sub == "SesionCerrada" then
		if estado.Actividad then
			estado.Actividad = nil
			cambio = true
		end
	elseif sub == "Actividad" or sub == "SesionAbierta" then
		local actividad = extraerActividad(datos)
		if actividad then
			estado.Actividad = actividad
			cambio = true
			if borrador.CuestionarioId ~= AULA then
				borrador.CuestionarioId = AULA
			end
			borrador.RespuestaAula = nil
		end
	end
	if cambio and estado.Abierto then
		refrescarSelectorCuestionario()
		if estado.Actividad then
			fijarBarraEstado("Tu docente abrió una actividad: la tienes en «Cuestionario».", "Aviso")
		end
	end
end

local function alRol()
	refrescarControlesDocente()
end

---------------------------------------------------------------------------------------------------
-- API pública (admite llamada con punto o con dos puntos)
---------------------------------------------------------------------------------------------------
function PCController.EstaAbierto()
	return estado.Abierto
end

function PCController.PcActual()
	return estado.PcId
end

-- Abre el escritorio con el payload de "AbrirEscritorio": { PcId, RoomId, NombreSala, Estado, Proyeccion,
-- ActividadAula, Entregas, Materia, MaxAnidamiento, ... }. Si ya está abierto en ese PC, solo refresca.
function PCController.Abrir(a, b)
	local datos = a
	if a == PCController then
		datos = b
	end
	if typeof(datos) ~= "table" or typeof(datos.PcId) ~= "string" or datos.PcId == "" then
		return false
	end
	if not activo then
		pendiente = datos
		return false
	end
	local okUI, errUI = pcall(asegurarUI)
	if not okUI then
		warn(LOG .. "No se pudo construir el escritorio: " .. tostring(errUI))
		return false
	end
	local mismo = estado.Abierto and estado.PcId == datos.PcId
	estado.PcId = datos.PcId
	estado.RoomId = typeof(datos.RoomId) == "string" and datos.RoomId or nil
	estado.NombreSala = typeof(datos.NombreSala) == "string" and datos.NombreSala or estado.RoomId
	local publico = typeof(datos.Estado) == "table" and datos.Estado or {}
	estado.Numero = numero(publico.Numero)
	estado.TieneSeat = publico.TieneSeat == true
	estado.Encendido = publico.Encendido ~= false
	estado.Bloqueado = publico.Bloqueado == true or datos.Bloqueado == true
	if typeof(datos.Materia) == "string" and TimetableDefinitions.Materias[datos.Materia] then
		estado.Materia = datos.Materia
	end
	if typeof(datos.Proyeccion) == "table" and typeof(datos.Proyeccion.Texto) == "string" and datos.Proyeccion.Texto ~= "" then
		estado.Proyeccion = { Texto = datos.Proyeccion.Texto, Autor = datos.Proyeccion.Autor, T = datos.Proyeccion.T }
	else
		estado.Proyeccion = nil
	end
	local actividad = extraerActividad(datos.ActividadAula)
	if not (estado.Actividad and actividad and estado.Actividad.Id == actividad.Id) then
		borrador.RespuestaAula = nil
	end
	estado.Actividad = actividad
	estado.Entregas = typeof(datos.Entregas) == "table" and datos.Entregas or {}
	estado.MaxAnidamiento = numero(datos.MaxAnidamiento) or MAX_ANIDAMIENTO_DEF
	estado.AppEnviada = nil
	actualizarDisposicion()
	refrescarContenido()
	if mismo then
		return true
	end

	estado.Abierto = true
	ui.Gui.Enabled = true
	maidVentana:DoCleaning()
	local conexion = UIBuilder.TeclaCerrar(function()
		if estado.Abierto then
			PCController.Cerrar(true)
		end
	end)
	if conexion then
		maidVentana:GiveTask(conexion)
	end
	maidVentana:GiveTask(task.spawn(bucleReloj))
	conectarCamara()
	seleccionarApp(estado.App or "Procesador", true)
	UIBuilder.Aparecer(ui.Panel)
	refrescarOverlays()
	if estado.Proyeccion and estado.App ~= APP_PANTALLA then
		marcarNovedad()
	end
	fijarBarraEstado("Usa las pestañas para cambiar de aplicación. «Salir» deja el equipo libre.", "Info")
	task.defer(function()
		if not estado.Abierto then
			return
		end
		if ui.CapaBloqueo and ui.CapaBloqueo.Visible then
			UIBuilder.Enfocar(ui.BotonSalirBloqueo)
		elseif ui.CapaApagado and ui.CapaApagado.Visible then
			UIBuilder.Enfocar(ui.BotonEncender)
		elseif ui.Pestanas[estado.App] then
			UIBuilder.Enfocar(ui.Pestanas[estado.App])
		end
	end)
	PCController.Abierto:Fire(estado.PcId)
	return true
end

-- Cierra el escritorio. enviarSalir = true avisa al servidor (PCAction Salir) para liberar el equipo.
function PCController.Cerrar(a, b)
	local enviarSalir = a
	if a == PCController then
		enviarSalir = b
	end
	if not estado.Abierto then
		return
	end
	local pcId = estado.PcId
	estado.Abierto = false
	tokenAnimacion = tokenAnimacion + 1
	maidVentana:DoCleaning()
	for _, clave in ipairs({ "Documento", "Editor", "EntradaProyeccion", "RespuestaAulaCaja" }) do
		local caja = ui[clave]
		if caja then
			pcall(function()
				caja:ReleaseFocus()
			end)
		end
	end
	if ui.Panel and ui.Panel.Parent ~= nil then
		UIBuilder.Desenfocar(ui.Panel)
		UIBuilder.Desaparecer(ui.Panel)
	end
	task.delay(UITheme.Animacion.Rapida + 0.1, function()
		if not estado.Abierto and ui.Gui and ui.Gui.Parent ~= nil then
			ui.Gui.Enabled = false
		end
	end)
	estado.PcId = nil
	if enviarSalir == true and pcId then
		task.spawn(function()
			local ok, respuesta = enviarAccion("Salir", nil, pcId)
			if not ok then
				warn(LOG .. "Salir: " .. mensajeDe(respuesta))
			end
		end)
	end
	PCController.Cerrado:Fire(pcId)
end

function PCController.Salir()
	PCController.Cerrar(true)
end

-- Apaga el equipo (sigue ocupado; la capa "apagado" permite encenderlo de nuevo o salir).
function PCController.Apagar()
	if not estado.Abierto then
		return
	end
	ejecutarAccion("Energia", ui.BotonApagar, "Apagar", nil, function(ok, respuesta)
		if ok then
			local publico = typeof(respuesta.datos) == "table" and respuesta.datos or {}
			estado.Encendido = publico.Encendido == true
			estado.Bloqueado = publico.Bloqueado == true
			estado.AppEnviada = nil
			refrescarOverlays()
		else
			fijarBarraEstado("No se pudo apagar: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

function PCController.Encender()
	if not estado.Abierto then
		return
	end
	ejecutarAccion("Energia", ui.BotonEncender, "Encender", nil, function(ok, respuesta)
		if ok then
			local publico = typeof(respuesta.datos) == "table" and respuesta.datos or {}
			estado.Encendido = publico.Encendido ~= false
			estado.Bloqueado = publico.Bloqueado == true
			refrescarOverlays()
			programarAvisoApp()
		else
			fijarBarraEstado("No se pudo encender: " .. mensajeDe(respuesta), "Error")
		end
	end)
end

-- Cambia de aplicación desde otro controlador ("Procesador" | "Cuestionario" | "Simulador" | "Programacion" | "PantallaClase").
function PCController.AbrirApp(a, b)
	local id = a
	if a == PCController then
		id = b
	end
	if estado.Abierto and typeof(id) == "string" then
		seleccionarApp(id, true)
	end
end

-- Acción docente desde otro panel (StaffController): accion = "Proyectar" | "Bloquear" | "Desbloquear";
-- destino = PcId o id de sala (por defecto el PC en uso, la sala actual o "SALA" = la del docente).
function PCController.AccionDocente(a, b, c, d)
	local accion, destino, texto = a, b, c
	if a == PCController then
		accion, destino, texto = b, c, d
	end
	if accion ~= "Proyectar" and accion ~= "Bloquear" and accion ~= "Desbloquear" then
		return false
	end
	local extra = nil
	if accion == "Proyectar" then
		extra = { Texto = tostring(texto or "") }
	end
	task.spawn(function()
		local ok, respuesta = enviarAccion(accion, extra, destino or destinoDocente())
		if ok then
			local textos = { Proyectar = "Proyección actualizada.", Bloquear = "Sala bloqueada.", Desbloquear = "Sala desbloqueada." }
			notificar(textos[accion], "exito")
		else
			notificar("No se pudo: " .. mensajeDe(respuesta), "error")
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function PCController:Init(registro)
	self.registro = registro
end

function PCController:Start()
	if activo then
		return
	end
	activo = true
	local okUI, errUI = pcall(asegurarUI)
	if not okUI then
		warn(LOG .. "No se pudo construir el escritorio: " .. tostring(errUI))
	end

	-- Jornada inicial desde el último StateSnapshot del HUD (si existe).
	local hud = obtenerControlador("HUDController")
	if hud and typeof(hud.Snapshot) == "function" then
		local okS, snap = pcall(hud.Snapshot, hud)
		if okS and typeof(snap) == "table" and typeof(snap.Jornada) == "table" then
			alJornada(snap.Jornada)
		end
	end

	maidGlobal:GiveTask(LocalPlayer.CharacterRemoving:Connect(function()
		if estado.Abierto then
			PCController.Cerrar(false)
		end
	end))
	maidGlobal:GiveTask(LocalPlayer:GetAttributeChangedSignal("Cargo"):Connect(function()
		refrescarControlesDocente()
		refrescarOverlays()
	end))

	local remoto = Net.Evento(Net.NombreEventoCliente or "EventoCliente")
	if remoto then
		maidGlobal:GiveTask(remoto.OnClientEvent:Connect(function(carga)
			if typeof(carga) ~= "table" then
				return
			end
			local datos = carga.Datos
			if typeof(datos) ~= "table" then
				datos = {}
			end
			local manejador = nil
			if carga.Tipo == "PC" then
				manejador = alEventoPC
			elseif carga.Tipo == "Jornada" then
				manejador = alJornada
			elseif carga.Tipo == "Aula" then
				manejador = alAula
			elseif carga.Tipo == "Rol" then
				manejador = alRol
			end
			if manejador then
				local ok, err = pcall(manejador, datos)
				if not ok then
					warn(LOG .. "Error en el evento " .. tostring(carga.Tipo) .. ": " .. tostring(err))
				end
			end
		end))
	else
		warn(LOG .. "EventoCliente no está disponible: el escritorio no podrá abrirse.")
	end

	if pendiente then
		local datos = pendiente
		pendiente = nil
		PCController.Abrir(datos)
	end
end

return PCController
