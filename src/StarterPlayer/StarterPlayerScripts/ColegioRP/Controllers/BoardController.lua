--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.BoardController
	Tipo: ModuleScript
	Panel "Tablero · <aula>" (docs/ARQUITECTURA.md §7): vista del texto, la plantilla, los trazos, la imagen y la
	proyección del tablero del aula sobre un lienzo con la proporción del tablero físico. Con turno vigente o
	siendo el docente de la sesión muestra herramientas: texto, plantillas, 4 colores, grosor, borrar e imagen
	(solo docente); el dibujo con ratón o táctil se muestrea a <= 20 puntos/s y cada trazo (<= MaxTrazoPuntos)
	se envía al soltar por BoardAction, con una cola que respeta el límite del remoto. Temporizador del turno.
	Escucha EventoCliente "Tablero" (Estado | Trazo | Texto | Limpiar | Turno) y nunca mezcla aulas: solo guarda
	el aula del panel y la última aula cuyo estado envió el servidor; ignora el resto de RoomId.
	API: Abrir(roomId?), Cerrar(), Alternar(roomId?), EstaAbierto(), AulaActual(), Estado(roomId?).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local TIMEOUT = 30
local function esperarHijo(padre, nombre)
	local hijo = nil
	if padre then
		hijo = padre:FindFirstChild(nombre) or padre:WaitForChild(nombre, TIMEOUT)
	end
	if not hijo then
		error("[ColegioRP][BoardController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
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
local Net = require(esperarHijo(Util, "Net"))
local Signal = require(esperarHijo(Util, "Signal"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local Zones = require(esperarHijo(Util, "Zones"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local Colores = UITheme.Colores

local BoardController = {}
BoardController.Nombre = "BoardController"
BoardController.Abierto = Signal.new() -- (roomId)
BoardController.Cerrado = Signal.new()
BoardController.Actualizado = Signal.new() -- (roomId) tras aplicar un cambio del servidor

---------------------------------------------------------------------------------------------------
-- Constantes (deben coincidir con BoardService)
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][BoardController] "
local ORDEN_PANTALLA = UITheme.Capas.Panel
local TABLERO = Config.Tablero or {}
local MAX_CARACTERES = tonumber(TABLERO.MaxCaracteres) or 400
local MAX_TRAZOS = tonumber(TABLERO.MaxTrazos) or 300
local MAX_PUNTOS = tonumber(TABLERO.MaxTrazoPuntos) or 60
local TURNO_SEG = tonumber(TABLERO.TurnoSeg) or 90

local PUNTOS_POR_SEG = 20 -- Muestreo máximo del dibujo.
local INTERVALO_MUESTRA = 1 / PUNTOS_POR_SEG
local DISTANCIA_MIN_PUNTO = 0.004 -- Distancia mínima (fracción del ancho) entre puntos consecutivos.
local MAX_FRAMES_PANEL = 3000 -- Frames de trazos en el lienzo del panel (se quitan los más antiguos).
local PUNTOS_POR_FRAME = 2 -- Igual que el tablero físico: un segmento cada 2 puntos.
local MAX_COLA = 12 -- Trazos esperando envío.
local ESPACIO_ENVIO = 0.15 -- Segundos mínimos entre dos BoardAction.
local ESPERA_MAX_BOTON = 2 -- Si un botón tendría que esperar más que esto, se avisa en lugar de esperar.
local INTERVALO_RESYNC = 4 -- Segundos mínimos entre consultas de estado (RequestClassAction ConsultarEstado).
local ASPECTO_DEFECTO = 10 / 6
local ANCHO_HERRAMIENTAS = 290

-- Límite del remoto BoardAction (se deja un hueco libre para no rozar el rechazo del servidor).
local LIMITE_MAX, LIMITE_VENTANA = RemoteContracts.LimiteDe("BoardAction")
LIMITE_MAX = math.max(1, (tonumber(LIMITE_MAX) or 8) - 1)
LIMITE_VENTANA = tonumber(LIMITE_VENTANA) or 5

-- Esperas mínimas por acción (las mismas que BoardService.EsperaAccion).
local ESPERA_ACCION = { Escribir = 1, Plantilla = 0.5, Imagen = 2, Limpiar = 1, Trazo = 0.08 }

local COLORES_TIZA = {
	Color3.fromRGB(240, 240, 232), -- 1 Blanco tiza
	Color3.fromRGB(246, 206, 70), -- 2 Amarillo
	Color3.fromRGB(240, 110, 110), -- 3 Rojo claro
	Color3.fromRGB(120, 180, 250), -- 4 Azul claro
}
local NOMBRES_COLOR = { "Blanco", "Amarillo", "Rojo", "Azul" }
local GROSORES = { 0.008, 0.014, 0.022, 0.032 }
local OPCIONES_GROSOR = {
	{ Valor = 1, Texto = "Fino" },
	{ Valor = 2, Texto = "Medio" },
	{ Valor = 3, Texto = "Grueso" },
	{ Valor = 4, Texto = "Muy grueso" },
}
local COLOR_FONDO = Color3.fromRGB(30, 56, 44)
local COLOR_MARCO = Color3.fromRGB(96, 70, 44)
local COLOR_TEXTO_TIZA = Color3.fromRGB(240, 240, 232)
local COLOR_PLANTILLA = Color3.fromRGB(246, 206, 70)

-- Motivos de error que invalidan los trazos en cola (sin permiso para seguir dibujando).
local MOTIVOS_SIN_PERMISO = { sin_turno = true, distancia = true, solo_docente = true, silenciado = true, aula_desconocida = true }

local function fuenteSegura(nombre, respaldo)
	local ok, fuente = pcall(function()
		return Enum.Font[nombre]
	end)
	if ok and fuente ~= nil then
		return fuente
	end
	return respaldo
end
local FUENTE_TIZA = fuenteSegura("PatrickHand", UITheme.Fuente("Texto"))

---------------------------------------------------------------------------------------------------
-- Codificación de puntos (misma que BoardService)
---------------------------------------------------------------------------------------------------
local ALFABETO = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local CUANTOS = 4095
local VALOR_CARACTER = {}
for i = 1, 64 do
	VALOR_CARACTER[string.byte(ALFABETO, i)] = i - 1
end

local function clamp(valor, minimo, maximo)
	if valor < minimo then
		return minimo
	end
	if valor > maximo then
		return maximo
	end
	return valor
end

local function decodificarPuntos(cadena)
	local puntos = {}
	if typeof(cadena) ~= "string" then
		return puntos
	end
	local n = math.min(math.floor(#cadena / 4), MAX_PUNTOS)
	for i = 0, n - 1 do
		local base = i * 4
		local a1, a2, a3, a4 = string.byte(cadena, base + 1, base + 4)
		local v1, v2, v3, v4 = VALOR_CARACTER[a1], VALOR_CARACTER[a2], VALOR_CARACTER[a3], VALOR_CARACTER[a4]
		if v1 and v2 and v3 and v4 then
			table.insert(puntos, { clamp((v1 * 64 + v2) / CUANTOS, 0, 1), clamp((v3 * 64 + v4) / CUANTOS, 0, 1) })
		end
	end
	return puntos
end

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local abierto = false
local estados = {} -- roomId -> estado normalizado (solo roomActual y roomZona)
local roomActual = nil -- aula mostrada en el panel
local roomZona = nil -- última aula cuyo estado completo envió el servidor (donde está el jugador)
local herramientas = { Color = 1, Grosor = 2, ModoDibujo = true }
local dibujo = { Activo = false, EsRaton = false, Entrada = nil, Puntos = {}, Ultimo = 0, Previa = {}, RoomId = nil, Continuacion = false }
local cola = {} -- { RoomId, Vectores, Previa = {Frame...} }
local procesandoCola = false
local envios = {} -- os.clock() de los BoardAction recientes
local ultimoEnvio = -math.huge
local ultimaAccion = {} -- accion -> os.clock()
local ultimoResync = -math.huge
local consultando = false
local ultimoRol = "?"
local maid = Maid.new() -- conexiones permanentes
local maidPanel = Maid.new() -- conexiones mientras el panel está abierto
local vista = { Frames = {}, Orden = {}, Total = 0 } -- frames del lienzo del panel
local ui = {}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function ahoraServidor()
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	if ok and typeof(t) == "number" then
		return t
	end
	return os.time()
end

local function texto(valor)
	if typeof(valor) == "string" then
		return valor
	end
	return ""
end

local function entero(valor, minimo, maximo, porDefecto)
	local n = tonumber(valor)
	if n == nil or n ~= n then
		return porDefecto
	end
	n = math.floor(n)
	if n < minimo or n > maximo then
		return porDefecto
	end
	return n
end

local function nombreAula(roomId)
	local zona = Zones.Zona(roomId)
	if zona and typeof(zona.Nombre) == "string" and zona.Nombre ~= "" then
		return zona.Nombre
	end
	return tostring(roomId or "")
end

local function posicionPropia()
	local personaje = LocalPlayer.Character
	local raiz = personaje and (personaje:FindFirstChild("HumanoidRootPart") or personaje.PrimaryPart)
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Aula (zona de tipo aula) donde está el jugador, o nil.
local function aulaDeMiPosicion()
	local posicion = posicionPropia()
	if not posicion then
		return nil
	end
	local ok, zonas = pcall(Zones.ZonasEn, posicion)
	if not ok or typeof(zonas) ~= "table" then
		return nil
	end
	for _, zona in ipairs(zonas) do
		if Zones.EsAula(zona.Id) then
			return zona.Id
		end
	end
	return nil
end

local function obtenerControlador(nombre)
	local registro = BoardController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

local function notificar(mensaje, nivel)
	local Notificaciones = obtenerControlador("NotificationController")
	if Notificaciones and typeof(Notificaciones.Notificar) == "function" then
		pcall(Notificaciones.Notificar, Notificaciones, mensaje, nivel or "info")
	end
end

local COLORES_MENSAJE = { Info = Colores.TextoSecundario, Exito = Colores.Verde, Error = Colores.Rojo, Aviso = Colores.Amarillo }
local function mostrarMensaje(mensaje, nivel)
	if ui.Mensaje and ui.Mensaje.Parent ~= nil then
		ui.Mensaje.Text = tostring(mensaje or "")
		ui.Mensaje.TextColor3 = COLORES_MENSAJE[nivel] or Colores.TextoSecundario
	end
end

local function mensajeDeError(respuesta)
	local err = nil
	if typeof(respuesta) == "table" then
		err = respuesta.error
	end
	return UIBuilder.MensajeError(err)
end

local function motivoDe(respuesta)
	if typeof(respuesta) ~= "table" then
		return nil
	end
	if typeof(respuesta.Motivo) == "string" then
		return respuesta.Motivo
	end
	if typeof(respuesta.error) == "string" then
		return string.match(respuesta.error, "^rechazado:([%a_]+)")
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Normalización del estado recibido
---------------------------------------------------------------------------------------------------
local function normalizarTrazo(t)
	if typeof(t) ~= "table" then
		return nil
	end
	local puntos = nil
	if typeof(t.P) == "string" then
		puntos = decodificarPuntos(t.P)
	elseif typeof(t.Puntos) == "table" then
		puntos = {}
		for _, p in ipairs(t.Puntos) do
			if #puntos >= MAX_PUNTOS then
				break
			end
			if typeof(p) == "Vector3" or typeof(p) == "Vector2" then
				table.insert(puntos, { clamp(p.X, 0, 1), clamp(p.Y, 0, 1) })
			elseif typeof(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
				table.insert(puntos, { clamp(tonumber(p[1]), 0, 1), clamp(tonumber(p[2]), 0, 1) })
			end
		end
	end
	if not puntos or #puntos == 0 then
		return nil
	end
	return {
		Id = tonumber(t.Id) or 0,
		Color = entero(t.Color, 1, #COLORES_TIZA, 1),
		Grosor = entero(t.Grosor, 1, #GROSORES, 2),
		Autor = tonumber(t.Autor) or 0,
		Puntos = puntos,
	}
end

local function normalizarTurno(t)
	if typeof(t) ~= "table" or tonumber(t.UserId) == nil then
		return nil
	end
	return {
		UserId = tonumber(t.UserId),
		Nombre = texto(t.Nombre),
		Expira = tonumber(t.Expira) or 0,
		Segundos = tonumber(t.Segundos) or TURNO_SEG,
	}
end

local function estadoBase(roomId)
	return {
		RoomId = roomId,
		Version = 0,
		Nombre = nombreAula(roomId),
		Aspecto = ASPECTO_DEFECTO,
		Texto = "",
		Plantilla = 0,
		ImagenId = 0,
		Proyeccion = "",
		Autor = 0,
		AutorNombre = "",
		Actualizado = 0,
		Trazos = {},
		Ids = {},
		Turno = nil,
		DocenteUserId = nil,
		RequiereSesion = true,
		Provisional = false,
	}
end

local function aplicarMeta(e, datos)
	if datos.Autor ~= nil then
		e.Autor = tonumber(datos.Autor) or 0
	end
	if datos.AutorNombre ~= nil then
		e.AutorNombre = texto(datos.AutorNombre)
	end
	if datos.Actualizado ~= nil then
		e.Actualizado = tonumber(datos.Actualizado) or 0
	end
end

local function aplicarCamposTexto(e, datos)
	if datos.Texto ~= nil then
		e.Texto = texto(datos.Texto)
	end
	if datos.Plantilla ~= nil then
		e.Plantilla = entero(datos.Plantilla, 0, 1000, 0)
	end
	if datos.ImagenId ~= nil then
		e.ImagenId = math.max(0, math.floor(tonumber(datos.ImagenId) or 0))
	end
	if datos.Proyeccion ~= nil then
		e.Proyeccion = texto(datos.Proyeccion)
	end
	aplicarMeta(e, datos)
end

local function aplicarAutorizacion(e, datos)
	if datos.DocenteUserId ~= nil or datos.Sub == "Estado" or datos.Sub == "Turno" then
		e.DocenteUserId = tonumber(datos.DocenteUserId)
	end
	if datos.RequiereSesion ~= nil then
		e.RequiereSesion = datos.RequiereSesion == true
	end
end

local function normalizarEstado(datos)
	if typeof(datos) ~= "table" or typeof(datos.RoomId) ~= "string" or datos.RoomId == "" then
		return nil
	end
	local e = estadoBase(datos.RoomId)
	e.Version = tonumber(datos.Version) or 0
	if typeof(datos.Nombre) == "string" and datos.Nombre ~= "" then
		e.Nombre = datos.Nombre
	end
	local aspecto = tonumber(datos.Aspecto)
	if aspecto and aspecto == aspecto then
		e.Aspecto = clamp(aspecto, 0.5, 4)
	end
	aplicarCamposTexto(e, datos)
	if typeof(datos.Trazos) == "table" then
		for _, t in ipairs(datos.Trazos) do
			local trazo = normalizarTrazo(t)
			if trazo and not e.Ids[trazo.Id] then
				table.insert(e.Trazos, trazo)
				e.Ids[trazo.Id] = true
			end
		end
	end
	while #e.Trazos > MAX_TRAZOS do
		local viejo = table.remove(e.Trazos, 1)
		e.Ids[viejo.Id] = nil
	end
	e.Turno = normalizarTurno(datos.Turno)
	aplicarAutorizacion(e, datos)
	return e
end

local function estadoVacio(e)
	return e == nil or (e.Texto == "" and e.Plantilla == 0 and #e.Trazos == 0 and e.ImagenId == 0 and e.Proyeccion == "")
end

-- Conserva solo el aula del panel y la del jugador (nunca se acumulan estados de otras aulas).
local function podar()
	for roomId in pairs(estados) do
		if roomId ~= roomActual and roomId ~= roomZona then
			estados[roomId] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Rol local (solo para mostrar herramientas; el servidor decide)
---------------------------------------------------------------------------------------------------
local function turnoVigente(e)
	if not e or not e.Turno then
		return nil
	end
	if e.Turno.Expira > 0 and e.Turno.Expira <= ahoraServidor() then
		return nil
	end
	return e.Turno
end

local function rolLocal(e)
	if not e or e.Provisional then
		return nil
	end
	local uid = LocalPlayer.UserId
	if e.RequiereSesion then
		if e.DocenteUserId ~= nil and e.DocenteUserId == uid then
			return "Docente"
		end
	else
		local cargo = LocalPlayer:GetAttribute("Cargo")
		if typeof(cargo) == "string" and RoleDefinitions.Tiene(cargo, "tablero.escribir") then
			return "Docente"
		end
	end
	local turno = turnoVigente(e)
	if turno and turno.UserId == uid then
		return "Invitado"
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Dibujo en el lienzo del panel
---------------------------------------------------------------------------------------------------
local function aspectoActual()
	local e = roomActual and estados[roomActual]
	return (e and e.Aspecto) or ASPECTO_DEFECTO
end

-- Segmento entre dos puntos normalizados en escala del lienzo (misma geometría que el tablero físico).
local function crearSegmento(padre, a, b, color, grosor, aspecto, zIndex)
	local dx = b[1] - a[1]
	local dy = b[2] - a[2]
	local dyAncho = dy / aspecto
	local largo = math.sqrt(dx * dx + dyAncho * dyAncho)
	local frame = Instance.new("Frame")
	frame.Name = "T"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = color
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
	frame.Size = UDim2.fromScale(largo + grosor / aspecto, grosor)
	frame.Rotation = math.deg(math.atan2(dy, dx * aspecto))
	frame.ZIndex = zIndex or 1
	frame.Parent = padre
	return frame
end

local function framesNecesarios(numPuntos)
	if numPuntos <= 1 then
		return 1
	end
	return math.ceil((numPuntos - 1) / PUNTOS_POR_FRAME)
end

local function quitarFramesTrazo(id)
	local frames = vista.Frames[id]
	if not frames then
		return
	end
	vista.Frames[id] = nil
	for _, frame in ipairs(frames) do
		frame:Destroy()
	end
	vista.Total = math.max(0, vista.Total - #frames)
	for i, otro in ipairs(vista.Orden) do
		if otro == id then
			table.remove(vista.Orden, i)
			break
		end
	end
end

local function dibujarTrazo(trazo)
	if not ui.Capa or ui.Capa.Parent == nil then
		return
	end
	if vista.Frames[trazo.Id] then
		return
	end
	local necesarios = framesNecesarios(#trazo.Puntos)
	while vista.Total + necesarios > MAX_FRAMES_PANEL and #vista.Orden > 0 do
		quitarFramesTrazo(vista.Orden[1])
	end
	if vista.Total + necesarios > MAX_FRAMES_PANEL then
		return
	end
	local aspecto = aspectoActual()
	local color = COLORES_TIZA[trazo.Color] or COLORES_TIZA[1]
	local grosor = GROSORES[trazo.Grosor] or GROSORES[2]
	local puntos = trazo.Puntos
	local frames = {}
	if #puntos == 1 then
		table.insert(frames, crearSegmento(ui.Capa, puntos[1], puntos[1], color, grosor, aspecto, 1))
	else
		local i = 1
		while i < #puntos do
			local j = math.min(i + PUNTOS_POR_FRAME, #puntos)
			table.insert(frames, crearSegmento(ui.Capa, puntos[i], puntos[j], color, grosor, aspecto, 1))
			i = j
		end
	end
	vista.Frames[trazo.Id] = frames
	table.insert(vista.Orden, trazo.Id)
	vista.Total = vista.Total + #frames
end

local function limpiarCapa()
	for _, frames in pairs(vista.Frames) do
		for _, frame in ipairs(frames) do
			frame:Destroy()
		end
	end
	vista.Frames = {}
	vista.Orden = {}
	vista.Total = 0
end

local function renderTrazos(e)
	limpiarCapa()
	if not e then
		return
	end
	local desde = #e.Trazos + 1
	local suma = 0
	for i = #e.Trazos, 1, -1 do
		local n = framesNecesarios(#e.Trazos[i].Puntos)
		if suma + n > MAX_FRAMES_PANEL then
			break
		end
		suma = suma + n
		desde = i
	end
	for i = desde, #e.Trazos do
		dibujarTrazo(e.Trazos[i])
	end
end

local function horaCorta(unix)
	local ok, valor = pcall(os.date, "%H:%M", math.floor(tonumber(unix) or 0))
	if ok and typeof(valor) == "string" then
		return valor
	end
	return ""
end

local function renderTextos(e)
	if not ui.Lienzo or ui.Lienzo.Parent == nil then
		return
	end
	if not e then
		e = estadoBase(roomActual or "")
	end
	local plantilla = Catalogs.Plantillas[e.Plantilla]
	ui.Plantilla.Visible = plantilla ~= nil
	ui.Plantilla.Text = plantilla or ""
	local proyecta = e.Proyeccion ~= ""
	local arriba = plantilla and 0.16 or 0.05
	local abajo = proyecta and 0.78 or 0.94
	ui.TextoLienzo.Position = UDim2.fromScale(0.04, arriba)
	ui.TextoLienzo.Size = UDim2.fromScale(0.92, math.max(0.1, abajo - arriba))
	ui.TextoLienzo.Text = e.Texto
	ui.Proyeccion.Visible = proyecta
	ui.ProyeccionTexto.Text = proyecta and ("Proyección: " .. e.Proyeccion) or ""
	if e.ImagenId > 0 then
		ui.Imagen.Image = string.format("rbxthumb://type=Asset&id=%.0f&w=420&h=420", e.ImagenId)
		ui.Imagen.Visible = true
	else
		ui.Imagen.Image = ""
		ui.Imagen.Visible = false
	end
	if e.Provisional then
		ui.Vacio.Text = "Cargando el tablero…"
		ui.Vacio.Visible = true
	else
		ui.Vacio.Text = "El tablero está vacío"
		ui.Vacio.Visible = estadoVacio(e)
	end
	if ui.Info then
		if e.AutorNombre ~= "" and e.Actualizado > 0 then
			ui.Info.Text = "Última edición: " .. Format.Truncar(e.AutorNombre, 24) .. " · " .. horaCorta(e.Actualizado)
		elseif e.AutorNombre ~= "" then
			ui.Info.Text = "Última edición: " .. Format.Truncar(e.AutorNombre, 24)
		else
			ui.Info.Text = ""
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Herramientas y temporizador
---------------------------------------------------------------------------------------------------
local function pintarColores()
	if not ui.BotonesColor then
		return
	end
	for i, item in ipairs(ui.BotonesColor) do
		local elegido = i == herramientas.Color
		item.Marca.Transparency = elegido and 0 or 1
		item.Muestra.Size = elegido and UDim2.new(1, 0, 1, -6) or UDim2.new(1, -6, 1, -12)
	end
end

local function refrescarCaptura()
	if not ui.Captura then
		return
	end
	local e = roomActual and estados[roomActual]
	local puede = abierto and rolLocal(e) ~= nil and herramientas.ModoDibujo
	ui.Captura.Visible = puede
	ui.Captura.Active = puede
end

local function actualizarTurno()
	if not ui.EstadoRol or ui.EstadoRol.Parent == nil then
		return
	end
	local e = roomActual and estados[roomActual]
	local rol = rolLocal(e)
	local turno = turnoVigente(e)
	local restante = 0
	if turno then
		restante = math.max(0, turno.Expira - ahoraServidor())
	end
	local lineas = ""
	if not e or e.Provisional then
		lineas = "Cargando el estado del tablero…"
	elseif rol == "Docente" then
		if e.RequiereSesion then
			lineas = "Eres el docente de la sesión: puedes escribir, dibujar y borrar."
		else
			lineas = "Tu cargo puede escribir en el tablero."
		end
		if turno then
			lineas = lineas .. "\nTurno de " .. Format.Truncar(turno.Nombre, 20) .. ": " .. Format.Tiempo(restante)
		end
	elseif rol == "Invitado" then
		lineas = "Tu turno en el tablero: " .. Format.Tiempo(restante)
	else
		if e.RequiereSesion and e.DocenteUserId == nil then
			lineas = "Solo lectura · No hay una sesión de clase abierta."
		else
			lineas = "Solo lectura · El docente puede invitarte al tablero."
		end
		if turno then
			lineas = lineas .. "\nTurno de " .. Format.Truncar(turno.Nombre, 20) .. ": " .. Format.Tiempo(restante)
		end
	end
	ui.EstadoRol.Text = lineas
	if ui.BarraTurno then
		local mostrar = turno ~= nil and (turno.Segundos or 0) > 0
		ui.BarraTurno.Frame.Visible = mostrar
		if mostrar then
			ui.BarraTurno:Fijar(restante / math.max(1, turno.Segundos), false)
		end
	end
end

local function refrescarHerramientas()
	if not ui.Panel then
		return
	end
	local e = roomActual and estados[roomActual]
	local rol = rolLocal(e)
	if ui.Titulo then
		ui.Titulo.Text = "Tablero · " .. Format.Truncar((e and e.Nombre) or nombreAula(roomActual), 40)
	end
	if ui.Edicion then
		ui.Edicion.Visible = rol ~= nil
	end
	if ui.AyudaLectura then
		ui.AyudaLectura.Visible = rol == nil
	end
	if ui.GrupoImagen then
		ui.GrupoImagen.Visible = rol == "Docente"
	end
	if ui.BotonBorrar then
		if rol == "Docente" then
			UIBuilder.TextoBoton(ui.BotonBorrar, "Borrar tablero")
		else
			UIBuilder.TextoBoton(ui.BotonBorrar, "Borrar mis trazos y texto")
		end
	end
	if ui.SelectorPlantilla and e then
		ui.SelectorPlantilla:Fijar(e.Plantilla, true)
	end
	if rol ~= ultimoRol then
		-- Al perder el permiso se cancela el trazo en curso.
		if rol == nil and dibujo.Activo then
			dibujo.Activo = false
			for _, frame in ipairs(dibujo.Previa) do
				frame:Destroy()
			end
			dibujo.Previa = {}
			dibujo.Puntos = {}
		end
		ultimoRol = rol
	end
	refrescarCaptura()
	actualizarTurno()
end

-- Redibuja todo el panel (solo si está abierto; si no, se redibuja al abrir).
local function renderTodo()
	if not abierto or not ui.Lienzo or ui.Lienzo.Parent == nil then
		return
	end
	local e = roomActual and estados[roomActual]
	if ui.Aspecto then
		ui.Aspecto.AspectRatio = (e and e.Aspecto) or ASPECTO_DEFECTO
	end
	renderTrazos(e)
	renderTextos(e)
	refrescarHerramientas()
end

---------------------------------------------------------------------------------------------------
-- Consulta de estado y aplicación de cambios
---------------------------------------------------------------------------------------------------

-- Busca el estado del tablero dentro de la respuesta de ClassroomService (ConsultarEstado).
local function extraerTablero(datos, roomId)
	if typeof(datos) ~= "table" then
		return nil
	end
	local candidatos = {}
	for _, clave in ipairs({ "Tablero", "Board", "EstadoTablero" }) do
		if typeof(datos[clave]) == "table" then
			table.insert(candidatos, datos[clave])
		end
	end
	for _, contenedor in ipairs({ "Aula", "Sesion", "Estado" }) do
		local sub = datos[contenedor]
		if typeof(sub) == "table" and typeof(sub.Tablero) == "table" then
			table.insert(candidatos, sub.Tablero)
		end
	end
	if datos.Sub == "Estado" then
		table.insert(candidatos, datos)
	end
	for _, candidato in ipairs(candidatos) do
		if candidato.RoomId == nil then
			candidato.RoomId = roomId
		end
		if candidato.RoomId == roomId and (candidato.Trazos ~= nil or candidato.Texto ~= nil or candidato.Version ~= nil) then
			return candidato
		end
	end
	return nil
end

local aplicarSnapshot

local function consultarEstado(roomId, forzar)
	if typeof(roomId) ~= "string" or consultando then
		return
	end
	local ahora = os.clock()
	if not forzar and ahora - ultimoResync < INTERVALO_RESYNC then
		return
	end
	ultimoResync = ahora
	consultando = true
	task.spawn(function()
		local ok, respuesta = Net.Invocar("RequestClassAction", { Accion = "ConsultarEstado", Salon = roomId, Datos = {} })
		consultando = false
		if not ok or typeof(respuesta) ~= "table" then
			local e = estados[roomId]
			if e and e.Provisional and roomActual == roomId then
				e.Provisional = false
				renderTodo()
				mostrarMensaje("No se pudo consultar el tablero. Entra en el salón para recibirlo.", "Aviso")
			end
			return
		end
		local tablero = extraerTablero(respuesta.datos, roomId)
		if tablero then
			aplicarSnapshot(tablero, "Consulta")
		else
			local e = estados[roomId]
			if e and e.Provisional and roomActual == roomId then
				e.Provisional = false
				renderTodo()
				if aulaDeMiPosicion() ~= roomId then
					mostrarMensaje("Entra en el salón para recibir el contenido actual del tablero.", "Aviso")
				end
			end
		end
	end)
end

local function pedirResync(roomId)
	if abierto and roomId == roomActual then
		consultarEstado(roomId, false)
	end
end

function aplicarSnapshot(datos, origen)
	local nuevo = normalizarEstado(datos)
	if not nuevo then
		return
	end
	local roomId = nuevo.RoomId
	local actual = estados[roomId]
	if actual and not actual.Provisional and nuevo.Version < actual.Version then
		return -- copia más antigua que la que ya tenemos
	end
	estados[roomId] = nuevo
	if origen == "Servidor" then
		roomZona = roomId
	end
	podar()
	if roomId == roomActual then
		renderTodo()
	end
	BoardController.Actualizado:Fire(roomId)
end

-- Compara la versión de un cambio con la local: "aplicar" | "viejo" | "hueco" (falta algún cambio).
local function comprobarVersion(e, version)
	version = tonumber(version)
	if version == nil then
		return "aplicar"
	end
	if e.Provisional then
		return "hueco"
	end
	if version < e.Version then
		return "viejo"
	end
	if version > e.Version + 1 then
		e.Version = version
		return "hueco"
	end
	e.Version = version
	return "aplicar"
end

local function agregarTrazoConfirmado(e, datosTrazo, descartados)
	local mostrado = abierto and e.RoomId == roomActual
	if typeof(descartados) == "table" then
		for _, id in ipairs(descartados) do
			if e.Ids[id] then
				e.Ids[id] = nil
				for i, trazo in ipairs(e.Trazos) do
					if trazo.Id == id then
						table.remove(e.Trazos, i)
						break
					end
				end
			end
			if mostrado then
				quitarFramesTrazo(id)
			end
		end
	end
	local trazo = normalizarTrazo(datosTrazo)
	if trazo and not e.Ids[trazo.Id] then
		table.insert(e.Trazos, trazo)
		e.Ids[trazo.Id] = true
		while #e.Trazos > MAX_TRAZOS do
			local viejo = table.remove(e.Trazos, 1)
			e.Ids[viejo.Id] = nil
			if mostrado then
				quitarFramesTrazo(viejo.Id)
			end
		end
		if mostrado then
			dibujarTrazo(trazo)
		end
	end
end

local function alRecibirTablero(datos)
	local sub = datos.Sub
	local roomId = datos.RoomId
	if typeof(roomId) ~= "string" or roomId == "" then
		return
	end
	if sub == "Estado" then
		aplicarSnapshot(datos, "Servidor")
		return
	end

	if sub == "Turno" then
		local mio = datos.Activo == true and tonumber(datos.UserId) == LocalPlayer.UserId
		local e = estados[roomId]
		if e then
			if datos.Activo == true then
				e.Turno = normalizarTurno(datos)
			else
				e.Turno = nil
			end
			aplicarAutorizacion(e, datos)
		end
		if mio and datos.Motivo == "Concedido" and (not abierto or roomActual ~= roomId) then
			BoardController.Abrir(roomId)
			if estados[roomId] then
				local turno = normalizarTurno(datos)
				estados[roomId].Turno = turno
				aplicarAutorizacion(estados[roomId], datos)
			end
		end
		if roomId == roomActual then
			refrescarHerramientas()
		end
		BoardController.Actualizado:Fire(roomId)
		return
	end

	-- Cambios de contenido: solo para un aula de la que tenemos estado.
	local e = estados[roomId]
	if not e then
		return
	end
	local resultado = comprobarVersion(e, datos.Version)
	if resultado == "viejo" then
		return
	end
	if e.Provisional then
		pedirResync(roomId)
		return
	end
	local mostrado = abierto and roomId == roomActual
	if sub == "Trazo" then
		agregarTrazoConfirmado(e, datos.Trazo, datos.Descartados)
		aplicarMeta(e, datos)
		if mostrado then
			ui.Vacio.Visible = estadoVacio(e)
			renderTextos(e)
		end
	elseif sub == "Texto" then
		aplicarCamposTexto(e, datos)
		if mostrado then
			renderTextos(e)
			if ui.SelectorPlantilla then
				ui.SelectorPlantilla:Fijar(e.Plantilla, true)
			end
		end
	elseif sub == "Limpiar" then
		e.Texto = ""
		e.Plantilla = 0
		e.Trazos = {}
		e.Ids = {}
		e.ImagenId = 0
		if datos.Completo == true then
			e.Proyeccion = ""
		end
		aplicarMeta(e, datos)
		if mostrado then
			renderTrazos(e)
			renderTextos(e)
			refrescarHerramientas()
		end
	else
		return
	end
	if resultado == "hueco" then
		pedirResync(roomId)
	end
	BoardController.Actualizado:Fire(roomId)
end

---------------------------------------------------------------------------------------------------
-- Envío de acciones (límite local por ventana, espera por acción y validación previa)
---------------------------------------------------------------------------------------------------
local function depurarEnvios()
	local ahora = os.clock()
	while envios[1] ~= nil and envios[1] <= ahora - LIMITE_VENTANA do
		table.remove(envios, 1)
	end
end

-- Segundos que faltan para poder enviar la acción sin rozar los límites.
local function esperaPara(accion)
	depurarEnvios()
	local ahora = os.clock()
	local espera = 0
	if #envios >= LIMITE_MAX then
		espera = LIMITE_VENTANA - (ahora - envios[1]) + 0.05
	end
	local desdeUltimo = ahora - ultimoEnvio
	if desdeUltimo < ESPACIO_ENVIO then
		espera = math.max(espera, ESPACIO_ENVIO - desdeUltimo)
	end
	local ultima = ultimaAccion[accion]
	local minimo = ESPERA_ACCION[accion] or 0.2
	if ultima and ahora - ultima < minimo then
		espera = math.max(espera, minimo - (ahora - ultima) + 0.02)
	end
	return math.max(0, espera)
end

-- Envía BoardAction (cede el hilo: llamar desde task.spawn). Devuelve ok, respuesta.
local function invocar(datos)
	local valido, err = RemoteContracts.Validar("BoardAction", datos)
	if not valido then
		return false, { ok = false, error = "Datos no válidos: " .. tostring(err) }
	end
	local ahora = os.clock()
	table.insert(envios, ahora)
	ultimoEnvio = ahora
	ultimaAccion[datos.Accion] = ahora
	return Net.Invocar("BoardAction", datos)
end

-- Acción de botón: espera un poco si hace falta (o avisa) y muestra el resultado.
local function accionBoton(datos, alTerminar)
	if not roomActual then
		return
	end
	datos.Salon = roomActual
	local espera = esperaPara(datos.Accion)
	if espera > ESPERA_MAX_BOTON then
		mostrarMensaje(string.format("Demasiadas acciones seguidas; espera %d s.", math.ceil(espera)), "Aviso")
		return
	end
	task.spawn(function()
		if espera > 0 then
			task.wait(espera)
		end
		local ok, respuesta = invocar(datos)
		if ok then
			if typeof(alTerminar) == "function" then
				pcall(alTerminar, typeof(respuesta.datos) == "table" and respuesta.datos or {})
			end
		else
			mostrarMensaje(mensajeDeError(respuesta), "Error")
		end
	end)
end

local function quitarPrevia(item)
	for _, frame in ipairs(item.Previa or {}) do
		frame:Destroy()
	end
	item.Previa = {}
end

local function vaciarCola(motivo)
	for _, item in ipairs(cola) do
		quitarPrevia(item)
	end
	table.clear(cola)
	if motivo then
		mostrarMensaje(motivo, "Aviso")
	end
end

local function procesarCola()
	if procesandoCola then
		return
	end
	procesandoCola = true
	task.spawn(function()
		while #cola > 0 and activo do
			local espera = esperaPara("Trazo")
			if espera > 0 then
				task.wait(espera)
			end
			local item = table.remove(cola, 1)
			if item then
				if item.RoomId ~= roomActual then
					quitarPrevia(item)
				else
					local ok, respuesta = invocar({ Accion = "Trazo", Salon = item.RoomId, Trazo = item.Vectores })
					quitarPrevia(item)
					if ok then
						local datos = typeof(respuesta.datos) == "table" and respuesta.datos or {}
						local e = estados[item.RoomId]
						if e and not e.Provisional and datos.Trazo then
							agregarTrazoConfirmado(e, datos.Trazo, datos.Descartados)
							if abierto and item.RoomId == roomActual and ui.Vacio then
								ui.Vacio.Visible = estadoVacio(e)
							end
						end
					else
						local motivo = motivoDe(respuesta)
						mostrarMensaje(mensajeDeError(respuesta), "Error")
						if motivo and MOTIVOS_SIN_PERMISO[motivo] then
							vaciarCola(nil)
						end
					end
				end
			end
		end
		procesandoCola = false
	end)
end

---------------------------------------------------------------------------------------------------
-- Entrada de dibujo (ratón y táctil)
---------------------------------------------------------------------------------------------------
local function posicionNormalizada(posicion)
	local lienzo = ui.Lienzo
	if not lienzo or lienzo.Parent == nil then
		return nil, nil
	end
	local origen, tamano = lienzo.AbsolutePosition, lienzo.AbsoluteSize
	if tamano.X <= 1 or tamano.Y <= 1 then
		return nil, nil
	end
	return clamp((posicion.X - origen.X) / tamano.X, 0, 1), clamp((posicion.Y - origen.Y) / tamano.Y, 0, 1)
end

local function segmentoPrevio(a, b)
	if not ui.CapaPrevia then
		return
	end
	local frame = crearSegmento(ui.CapaPrevia, a, b, COLORES_TIZA[herramientas.Color] or COLORES_TIZA[1],
		GROSORES[herramientas.Grosor] or GROSORES[2], aspectoActual(), 1)
	table.insert(dibujo.Previa, frame)
end

-- Cierra el trazo actual y lo pone en la cola de envío.
local function encolarTrazo()
	local puntos = dibujo.Puntos
	if #puntos == 0 then
		for _, frame in ipairs(dibujo.Previa) do
			frame:Destroy()
		end
		dibujo.Previa = {}
		return
	end
	if #cola >= MAX_COLA then
		for _, frame in ipairs(dibujo.Previa) do
			frame:Destroy()
		end
		dibujo.Previa = {}
		mostrarMensaje("Dibujas muy rápido; espera a que se envíen los trazos.", "Aviso")
		return
	end
	local z = herramientas.Color * 0.1 + herramientas.Grosor * 0.01
	local vectores = table.create(#puntos)
	for i, p in ipairs(puntos) do
		vectores[i] = Vector3.new(p[1], p[2], z)
	end
	table.insert(cola, { RoomId = dibujo.RoomId, Vectores = vectores, Previa = dibujo.Previa })
	dibujo.Previa = {}
	procesarCola()
end

local function agregarPunto(posicion, forzar)
	local x, y = posicionNormalizada(posicion)
	if not x then
		return
	end
	local ahora = os.clock()
	local puntos = dibujo.Puntos
	local n = #puntos
	if n > 0 then
		local ultimo = puntos[n]
		local dx = x - ultimo[1]
		local dy = (y - ultimo[2]) / aspectoActual()
		if dx * dx + dy * dy < DISTANCIA_MIN_PUNTO * DISTANCIA_MIN_PUNTO then
			return
		end
		if ahora - dibujo.Ultimo < INTERVALO_MUESTRA then
			if not forzar then
				return
			end
			-- Punto final demasiado pronto: sustituye al último para no superar el muestreo.
			if n > 1 then
				puntos[n] = { x, y }
				local frame = table.remove(dibujo.Previa)
				if frame then
					frame:Destroy()
				end
				segmentoPrevio(puntos[n - 1], puntos[n])
			end
			return
		end
	end
	dibujo.Ultimo = ahora
	table.insert(puntos, { x, y })
	if n > 0 then
		segmentoPrevio(puntos[n], puntos[n + 1])
	else
		segmentoPrevio(puntos[1], puntos[1])
	end
	if #puntos >= MAX_PUNTOS then
		-- Trazo largo: se envía esta parte y se continúa desde el último punto.
		local final = puntos[#puntos]
		encolarTrazo()
		dibujo.Puntos = { { final[1], final[2] } }
		dibujo.Continuacion = true
	end
end

local function iniciarTrazo(entrada, esRaton)
	local e = roomActual and estados[roomActual]
	if not abierto or rolLocal(e) == nil or not herramientas.ModoDibujo then
		return
	end
	dibujo.Activo = true
	dibujo.EsRaton = esRaton
	dibujo.Entrada = entrada
	dibujo.Puntos = {}
	dibujo.Previa = {}
	dibujo.Ultimo = 0
	dibujo.RoomId = roomActual
	dibujo.Continuacion = false
	agregarPunto(entrada.Position, true)
end

local function terminarTrazo(posicion)
	if not dibujo.Activo then
		return
	end
	dibujo.Activo = false
	if posicion then
		agregarPunto(posicion, true)
	end
	-- Tras partir un trazo largo, un único punto final repetido no se envía.
	local soloContinuacion = dibujo.Continuacion and #dibujo.Puntos <= 1
	if soloContinuacion or dibujo.RoomId ~= roomActual or rolLocal(estados[roomActual]) == nil then
		for _, frame in ipairs(dibujo.Previa) do
			frame:Destroy()
		end
		dibujo.Previa = {}
		dibujo.Puntos = {}
		return
	end
	encolarTrazo()
	dibujo.Puntos = {}
end

local function cancelarTrazo()
	dibujo.Activo = false
	for _, frame in ipairs(dibujo.Previa) do
		frame:Destroy()
	end
	dibujo.Previa = {}
	dibujo.Puntos = {}
end

---------------------------------------------------------------------------------------------------
-- Acciones de herramientas
---------------------------------------------------------------------------------------------------
local function publicarTexto(valor)
	local contenido = Format.Recortar(texto(valor))
	if Format.Longitud(contenido) > MAX_CARACTERES then
		contenido = Format.Truncar(contenido, MAX_CARACTERES)
	end
	mostrarMensaje("Publicando…", "Info")
	accionBoton({ Accion = "Escribir", Texto = contenido }, function(datos)
		if typeof(datos.Texto) == "string" and ui.EntradaTexto and ui.EntradaTexto.Parent ~= nil then
			ui.EntradaTexto.Text = datos.Texto
		end
		if contenido == "" then
			mostrarMensaje("Texto del tablero borrado.", "Exito")
		elseif datos.SinCambios then
			mostrarMensaje("El tablero ya tenía ese texto.", "Info")
		else
			mostrarMensaje("Texto publicado en el tablero.", "Exito")
		end
	end)
end

local function elegirPlantilla(valor)
	local indice = nil
	if typeof(valor) == "number" and valor > 0 then
		indice = valor
	end
	accionBoton({ Accion = "Plantilla", Plantilla = indice }, function()
		mostrarMensaje(indice and "Plantilla aplicada." or "Plantilla quitada.", "Exito")
	end)
end

local function mostrarImagen(quitar)
	local id = 0
	if not quitar then
		id = tonumber(ui.EntradaImagen and ui.EntradaImagen.Text or "")
		if id == nil then
			local digitos = string.match(ui.EntradaImagen and ui.EntradaImagen.Text or "", "(%d+)")
			id = tonumber(digitos or "")
		end
		if id == nil or id <= 0 or math.floor(id) ~= id or id > 999999999999 then
			mostrarMensaje("Escribe el id numérico de una imagen (Decal) de Roblox.", "Error")
			return
		end
	end
	accionBoton({ Accion = "Imagen", ImagenId = id }, function()
		mostrarMensaje(id > 0 and "Imagen mostrada en el tablero." or "Imagen quitada.", "Exito")
	end)
end

local function borrar()
	local e = roomActual and estados[roomActual]
	local rol = rolLocal(e)
	if rol == nil then
		return
	end
	local function ejecutar()
		cancelarTrazo()
		vaciarCola(nil)
		accionBoton({ Accion = "Limpiar" }, function(datos)
			if datos.SinCambios then
				mostrarMensaje("No había nada que borrar.", "Info")
			else
				mostrarMensaje(rol == "Docente" and "Tablero borrado." or "Tus trazos se borraron.", "Exito")
			end
		end)
	end
	if rol == "Docente" then
		UIBuilder.Confirmar("Borrar tablero", "Se borrará el texto, la plantilla, los trazos y la imagen del tablero de este salón.", ejecutar, "Borrar", "Peligro")
	else
		ejecutar()
	end
end

local function fijarColor(indice)
	herramientas.Color = clamp(indice, 1, #COLORES_TIZA)
	pintarColores()
end

---------------------------------------------------------------------------------------------------
-- Construcción del panel
---------------------------------------------------------------------------------------------------
local function nuevoTextoLienzo(nombre, padre, props)
	local label = Instance.new("TextLabel")
	label.Name = nombre
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.RichText = false
	label.TextWrapped = true
	label.TextScaled = true
	label.Font = props.Fuente or FUENTE_TIZA
	label.TextColor3 = props.Color or COLOR_TEXTO_TIZA
	label.TextXAlignment = props.AlineacionX or Enum.TextXAlignment.Left
	label.TextYAlignment = props.AlineacionY or Enum.TextYAlignment.Top
	label.Position = props.Position or UDim2.fromScale(0, 0)
	label.Size = props.Size or UDim2.fromScale(1, 1)
	label.ZIndex = props.ZIndex or 3
	label.Text = ""
	local limite = Instance.new("UITextSizeConstraint")
	limite.MaxTextSize = props.MaxTexto or 28
	limite.MinTextSize = 8
	limite.Parent = label
	label.Parent = padre
	return label
end

local function construirLienzo(zona)
	local lienzo = Instance.new("Frame")
	lienzo.Name = "Lienzo"
	lienzo.BackgroundColor3 = COLOR_FONDO
	lienzo.BorderSizePixel = 0
	lienzo.AnchorPoint = Vector2.new(0.5, 0.5)
	lienzo.Position = UDim2.fromScale(0.5, 0.5)
	lienzo.Size = UDim2.fromScale(1, 1)
	lienzo.ClipsDescendants = true
	local aspecto = Instance.new("UIAspectRatioConstraint")
	aspecto.AspectRatio = ASPECTO_DEFECTO
	aspecto.AspectType = Enum.AspectType.FitWithinMaxSize
	aspecto.DominantAxis = Enum.DominantAxis.Width
	aspecto.Parent = lienzo
	UIBuilder.Esquinas(lienzo, 6)
	UIBuilder.Borde(lienzo, COLOR_MARCO, 3)
	ui.Aspecto = aspecto

	local imagen = Instance.new("ImageLabel")
	imagen.Name = "Imagen"
	imagen.BackgroundTransparency = 1
	imagen.BorderSizePixel = 0
	imagen.ScaleType = Enum.ScaleType.Fit
	imagen.AnchorPoint = Vector2.new(0.5, 0.5)
	imagen.Position = UDim2.fromScale(0.5, 0.5)
	imagen.Size = UDim2.fromScale(0.92, 0.86)
	imagen.ZIndex = 2
	imagen.Visible = false
	imagen.Parent = lienzo
	ui.Imagen = imagen

	ui.Plantilla = nuevoTextoLienzo("Plantilla", lienzo, {
		Fuente = UITheme.Fuente("Titulo"), Color = COLOR_PLANTILLA, Position = UDim2.fromScale(0.04, 0.03),
		Size = UDim2.fromScale(0.92, 0.12), AlineacionY = Enum.TextYAlignment.Center, MaxTexto = 26,
	})
	ui.Plantilla.Visible = false
	ui.TextoLienzo = nuevoTextoLienzo("Texto", lienzo, {
		Position = UDim2.fromScale(0.04, 0.05), Size = UDim2.fromScale(0.92, 0.89), MaxTexto = 30,
	})
	ui.Vacio = nuevoTextoLienzo("Vacio", lienzo, {
		Fuente = UITheme.Fuente("Texto"), Color = Color3.fromRGB(150, 175, 160), Position = UDim2.fromScale(0.1, 0.42),
		Size = UDim2.fromScale(0.8, 0.16), AlineacionX = Enum.TextXAlignment.Center,
		AlineacionY = Enum.TextYAlignment.Center, MaxTexto = 18,
	})
	ui.Vacio.Text = "El tablero está vacío"

	local capa = Instance.new("Frame")
	capa.Name = "Trazos"
	capa.BackgroundTransparency = 1
	capa.BorderSizePixel = 0
	capa.Size = UDim2.fromScale(1, 1)
	capa.ZIndex = 4
	capa.Parent = lienzo
	ui.Capa = capa

	local previa = Instance.new("Frame")
	previa.Name = "TrazoEnCurso"
	previa.BackgroundTransparency = 1
	previa.BorderSizePixel = 0
	previa.Size = UDim2.fromScale(1, 1)
	previa.ZIndex = 5
	previa.Parent = lienzo
	ui.CapaPrevia = previa

	local proyeccion = Instance.new("Frame")
	proyeccion.Name = "Proyeccion"
	proyeccion.BackgroundColor3 = Color3.fromRGB(18, 34, 26)
	proyeccion.BackgroundTransparency = 0.15
	proyeccion.BorderSizePixel = 0
	proyeccion.Position = UDim2.fromScale(0.03, 0.8)
	proyeccion.Size = UDim2.fromScale(0.94, 0.12)
	proyeccion.ZIndex = 6
	proyeccion.Visible = false
	proyeccion.Parent = lienzo
	UIBuilder.Esquinas(proyeccion, 4)
	ui.Proyeccion = proyeccion
	ui.ProyeccionTexto = nuevoTextoLienzo("Texto", proyeccion, {
		Fuente = UITheme.Fuente("Texto"), Color = Color3.fromRGB(200, 230, 255), Position = UDim2.fromScale(0.02, 0.08),
		Size = UDim2.fromScale(0.96, 0.84), AlineacionY = Enum.TextYAlignment.Center, ZIndex = 7, MaxTexto = 16,
	})

	-- Zona de captura del dibujo (solo visible con permiso y modo dibujo). Active = true absorbe el toque
	-- para que la cámara no gire mientras se dibuja.
	local captura = Instance.new("TextButton")
	captura.Name = "Captura"
	captura.BackgroundTransparency = 1
	captura.AutoButtonColor = false
	captura.Text = ""
	captura.Selectable = false
	captura.Size = UDim2.fromScale(1, 1)
	captura.ZIndex = 8
	captura.Visible = false
	captura.Active = false
	captura.Parent = lienzo
	ui.Captura = captura
	captura.InputBegan:Connect(function(entrada)
		if entrada.UserInputType == Enum.UserInputType.MouseButton1 then
			iniciarTrazo(entrada, true)
		elseif entrada.UserInputType == Enum.UserInputType.Touch and not dibujo.Activo then
			iniciarTrazo(entrada, false)
		end
	end)

	lienzo.Parent = zona
	ui.Lienzo = lienzo
end

local function construirHerramientas(lista)
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end

	ui.EstadoRol = UIBuilder.Texto(lista, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoSecundario, Nombre = "EstadoRol" })
	ui.BarraTurno = UIBuilder.Barra(lista, 1, { LayoutOrder = siguiente(), Nombre = "BarraTurno", Color = Colores.Amarillo, Alto = 6 })
	ui.BarraTurno.Frame.Visible = false
	ui.AyudaLectura = UIBuilder.Texto(lista, "Cuando el docente te invite al tablero tendrás un turno de " .. TURNO_SEG .. " s para escribir o dibujar desde este panel.", {
		LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado, Nombre = "AyudaLectura",
	})

	local edicion = UIBuilder.Marco(lista, { Nombre = "Edicion", AutoAlto = true, LayoutOrder = siguiente() })
	UIBuilder.Disposicion(edicion, { Espaciado = 6 })
	edicion.Visible = false
	ui.Edicion = edicion
	local o = 0
	local function s()
		o = o + 1
		return o
	end
	local alto = UIBuilder.AltoBoton()

	-- Dibujo
	UIBuilder.Texto(edicion, "Dibujo", { LayoutOrder = s(), Fuente = "Subtitulo", Tamano = "Pequeno" })
	ui.ModoDibujo = UIBuilder.Interruptor(edicion, "Dibujar con el dedo o el ratón", herramientas.ModoDibujo, function(valor)
		herramientas.ModoDibujo = valor == true
		if not herramientas.ModoDibujo then
			cancelarTrazo()
		end
		refrescarCaptura()
	end, { LayoutOrder = s(), Nombre = "ModoDibujo" })

	local filaColores = UIBuilder.Fila(edicion, { LayoutOrder = s(), Nombre = "Colores", Espaciado = 6, Alto = alto })
	ui.BotonesColor = {}
	local botonesColor = {}
	for i, color in ipairs(COLORES_TIZA) do
		local boton = UIBuilder.Boton(filaColores, "", function()
			fijarColor(i)
		end, { Estilo = "Secundario", Ancho = 52, Alto = alto, LayoutOrder = i, Nombre = "Color" .. NOMBRES_COLOR[i] })
		local muestra = Instance.new("Frame")
		muestra.Name = "Muestra"
		muestra.BackgroundColor3 = color
		muestra.BorderSizePixel = 0
		muestra.AnchorPoint = Vector2.new(0.5, 0.5)
		muestra.Position = UDim2.fromScale(0.5, 0.5)
		muestra.Size = UDim2.new(1, -6, 1, -12)
		UIBuilder.Esquinas(muestra, 4)
		local marca = UIBuilder.Borde(muestra, Colores.Amarillo, 3, 1)
		muestra.Parent = boton
		ui.BotonesColor[i] = { Boton = boton, Muestra = muestra, Marca = marca }
		table.insert(botonesColor, boton)
	end
	UIBuilder.Encadenar(botonesColor, true)
	pintarColores()

	ui.SelectorGrosor = UIBuilder.Selector(edicion, "Grosor", OPCIONES_GROSOR, herramientas.Grosor, function(valor)
		herramientas.Grosor = entero(valor, 1, #GROSORES, 2)
	end, { LayoutOrder = s(), Nombre = "Grosor", AnchoGrupo = 160 })

	-- Texto
	UIBuilder.Texto(edicion, "Texto del tablero", { LayoutOrder = s(), Fuente = "Subtitulo", Tamano = "Pequeno" })
	ui.EntradaTexto = UIBuilder.Entrada(edicion, "Escribe lo que verá toda la clase…", {
		Max = MAX_CARACTERES, Multilinea = true, Alto = 92, LayoutOrder = s(), Nombre = "EntradaTexto",
		AlCambiar = function(valor)
			if ui.Contador then
				ui.Contador.Text = Format.Longitud(valor) .. " / " .. MAX_CARACTERES
			end
		end,
	})
	ui.Contador = UIBuilder.Texto(edicion, "0 / " .. MAX_CARACTERES, {
		LayoutOrder = s(), Tamano = "Pequeno", Color = Colores.TextoApagado, Alineacion = Enum.TextXAlignment.Right, Nombre = "Contador",
	})
	local filaTexto = UIBuilder.Fila(edicion, { LayoutOrder = s(), Nombre = "AccionesTexto", Espaciado = 6, Alto = alto })
	ui.BotonPublicar = UIBuilder.Boton(filaTexto, "Publicar", function()
		publicarTexto(ui.EntradaTexto and ui.EntradaTexto.Text or "")
	end, { Estilo = "Primario", Ancho = 128, Alto = alto, LayoutOrder = 1, Nombre = "Publicar" })
	ui.BotonBorrarTexto = UIBuilder.Boton(filaTexto, "Quitar texto", function()
		if ui.EntradaTexto then
			ui.EntradaTexto.Text = ""
		end
		publicarTexto("")
	end, { Estilo = "Secundario", Ancho = 128, Alto = alto, LayoutOrder = 2, Nombre = "QuitarTexto" })

	local opcionesPlantilla = { { Valor = 0, Texto = "Sin plantilla" } }
	for i, nombre in ipairs(Catalogs.Plantillas or {}) do
		table.insert(opcionesPlantilla, { Valor = i, Texto = nombre })
	end
	ui.SelectorPlantilla = UIBuilder.Selector(edicion, "Plantilla", opcionesPlantilla, 0, function(valor)
		elegirPlantilla(valor)
	end, { LayoutOrder = s(), Nombre = "Plantilla", AnchoGrupo = 190 })

	-- Imagen (solo docente)
	local grupoImagen = UIBuilder.Marco(edicion, { Nombre = "GrupoImagen", AutoAlto = true, LayoutOrder = s() })
	UIBuilder.Disposicion(grupoImagen, { Espaciado = 6 })
	grupoImagen.Visible = false
	ui.GrupoImagen = grupoImagen
	UIBuilder.Texto(grupoImagen, "Imagen (id de Decal de Roblox)", { LayoutOrder = 1, Fuente = "Subtitulo", Tamano = "Pequeno" })
	ui.EntradaImagen = UIBuilder.Entrada(grupoImagen, "Ej.: 1234567890", { Max = 14, LayoutOrder = 2, Nombre = "EntradaImagen" })
	local filaImagen = UIBuilder.Fila(grupoImagen, { LayoutOrder = 3, Nombre = "AccionesImagen", Espaciado = 6, Alto = alto })
	ui.BotonImagen = UIBuilder.Boton(filaImagen, "Mostrar", function()
		mostrarImagen(false)
	end, { Estilo = "Secundario", Ancho = 128, Alto = alto, LayoutOrder = 1, Nombre = "MostrarImagen" })
	ui.BotonQuitarImagen = UIBuilder.Boton(filaImagen, "Quitar", function()
		mostrarImagen(true)
	end, { Estilo = "Secundario", Ancho = 128, Alto = alto, LayoutOrder = 2, Nombre = "QuitarImagen" })

	ui.BotonBorrar = UIBuilder.Boton(edicion, "Borrar tablero", borrar, {
		Estilo = "Peligro", Size = UDim2.new(1, 0, 0, alto), LayoutOrder = s(), Nombre = "Borrar",
	})

	ui.Mensaje = UIBuilder.Texto(lista, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Nombre = "Mensaje" })
	ui.Info = UIBuilder.Texto(lista, "", { LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado, Nombre = "Info" })
	UIBuilder.Boton(lista, "Cerrar", function()
		BoardController.Cerrar()
	end, { Estilo = "Secundario", Size = UDim2.new(1, 0, 0, alto), LayoutOrder = siguiente(), Nombre = "CerrarPanel" })

	UIBuilder.Encadenar({
		ui.ModoDibujo.Boton, botonesColor[1], ui.SelectorGrosor.Botones[1], ui.EntradaTexto, ui.BotonPublicar,
		ui.SelectorPlantilla.Botones[1], ui.EntradaImagen, ui.BotonImagen, ui.BotonBorrar,
	})
end

-- Lienzo a la izquierda y herramientas a la derecha; en pantallas estrechas o verticales, apilados.
local function reubicar()
	if not ui.ZonaLienzo or not ui.Herramientas then
		return
	end
	local vertical = UIBuilder.EsEstrecho() or UIBuilder.AltoUI() > UIBuilder.AnchoUI()
	if vertical then
		ui.ZonaLienzo.Position = UDim2.new(0, 0, 0, 0)
		ui.ZonaLienzo.Size = UDim2.new(1, 0, 0.5, -4)
		ui.Herramientas.Position = UDim2.new(0, 0, 0.5, 4)
		ui.Herramientas.Size = UDim2.new(1, 0, 0.5, -4)
	else
		ui.ZonaLienzo.Position = UDim2.new(0, 0, 0, 0)
		ui.ZonaLienzo.Size = UDim2.new(1, -(ANCHO_HERRAMIENTAS + 10), 1, 0)
		ui.Herramientas.Position = UDim2.new(1, -ANCHO_HERRAMIENTAS, 0, 0)
		ui.Herramientas.Size = UDim2.new(0, ANCHO_HERRAMIENTAS, 1, 0)
	end
end

local function construirUI()
	vista = { Frames = {}, Orden = {}, Total = 0 }
	local gui = UIBuilder.Pantalla("Tablero", ORDEN_PANTALLA)
	ui = { Gui = gui }
	local contenedor = UIBuilder.Contenedor(gui)
	local panel, cuerpo = UIBuilder.Panel(contenedor, {
		Nombre = "PanelTablero",
		Titulo = "Tablero",
		AlCerrar = function()
			BoardController.Cerrar()
		end,
		Size = UDim2.new(1, 0, 1, 0),
	})
	local limite = Instance.new("UISizeConstraint")
	limite.MaxSize = Vector2.new(1040, 680)
	limite.Parent = panel
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	ui.Panel = panel
	local cabecera = panel:FindFirstChild("Cabecera")
	ui.Titulo = cabecera and cabecera:FindFirstChild("Titulo") or nil

	local zona = Instance.new("Frame")
	zona.Name = "ZonaLienzo"
	zona.BackgroundTransparency = 1
	zona.BorderSizePixel = 0
	zona.Parent = cuerpo
	ui.ZonaLienzo = zona
	construirLienzo(zona)

	local lista = UIBuilder.Lista(cuerpo, { Espaciado = 6 })
	lista.Name = "Herramientas"
	ui.Herramientas = lista
	construirHerramientas(lista)
	reubicar()
end

local function asegurarUI()
	if not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil then
		construirUI()
	end
end

---------------------------------------------------------------------------------------------------
-- API pública (admite llamada con punto o con dos puntos)
---------------------------------------------------------------------------------------------------
function BoardController.EstaAbierto()
	return abierto
end

-- Aula mostrada en el panel (o nil).
function BoardController.AulaActual()
	return roomActual
end

-- Copia resumida del estado del tablero de un aula conocida (por defecto la del panel) o nil.
function BoardController.Estado(a, b)
	local roomId = a
	if a == BoardController then
		roomId = b
	end
	roomId = roomId or roomActual
	local e = roomId and estados[roomId]
	if not e then
		return nil
	end
	return {
		RoomId = e.RoomId, Version = e.Version, Nombre = e.Nombre, Texto = e.Texto, Plantilla = e.Plantilla,
		ImagenId = e.ImagenId, Proyeccion = e.Proyeccion, Trazos = #e.Trazos, Turno = e.Turno,
		DocenteUserId = e.DocenteUserId, Rol = rolLocal(e),
	}
end

-- Abre el panel del tablero de un aula (por defecto, el aula donde está el jugador).
function BoardController.Abrir(a, b)
	local roomId = a
	if a == BoardController then
		roomId = b
	end
	if not activo then
		return false
	end
	if typeof(roomId) ~= "string" or roomId == "" then
		roomId = aulaDeMiPosicion() or roomZona or roomActual
	end
	if typeof(roomId) ~= "string" or roomId == "" then
		notificar("Entra en un salón para ver su tablero.", "aviso")
		return false
	end
	local ok, err = pcall(asegurarUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
		return false
	end
	local cambioAula = roomId ~= roomActual
	if cambioAula then
		cancelarTrazo()
		vaciarCola(nil)
		roomActual = roomId
		if not estados[roomId] then
			local provisional = estadoBase(roomId)
			provisional.Provisional = true
			estados[roomId] = provisional
		end
		podar()
		mostrarMensaje("", "Info")
		if ui.EntradaTexto then
			ui.EntradaTexto.Text = estados[roomId].Texto or ""
		end
	end
	if not abierto then
		abierto = true
		ui.Gui.Enabled = true
		UIBuilder.Aparecer(ui.Panel)
		local conexion = UIBuilder.TeclaCerrar(function()
			BoardController.Cerrar()
		end)
		if conexion then
			maidPanel:GiveTask(conexion)
		end
		local acumulado = 0
		maidPanel:GiveTask(RunService.Heartbeat:Connect(function(dt)
			acumulado = acumulado + dt
			if acumulado < 0.25 then
				return
			end
			acumulado = 0
			-- Reabrir justo después de cerrar: la animación de Desaparecer puede ocultar el panel al terminar.
			if ui.Panel and ui.Panel.Parent ~= nil and not ui.Panel.Visible then
				ui.Panel.Visible = true
			end
			local e = roomActual and estados[roomActual]
			if e and e.Turno and e.Turno.Expira > 0 and e.Turno.Expira <= ahoraServidor() then
				e.Turno = nil
				refrescarHerramientas()
			else
				actualizarTurno()
			end
		end))
		task.defer(function()
			if abierto and ui.Panel then
				UIBuilder.EnfocarPrimero(ui.Panel)
			end
		end)
		BoardController.Abierto:Fire(roomId)
	end
	renderTodo()
	if ui.EntradaTexto and estados[roomId] and not estados[roomId].Provisional and ui.EntradaTexto.Text == "" then
		ui.EntradaTexto.Text = estados[roomId].Texto
	end
	consultarEstado(roomId, cambioAula)
	return true
end

function BoardController.Cerrar()
	if not abierto then
		return
	end
	abierto = false
	cancelarTrazo()
	maidPanel:DoCleaning()
	for _, caja in ipairs({ ui.EntradaTexto, ui.EntradaImagen }) do
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
	refrescarCaptura()
	BoardController.Cerrado:Fire()
end

function BoardController.Alternar(a, b)
	local roomId = a
	if a == BoardController then
		roomId = b
	end
	if abierto and (roomId == nil or roomId == roomActual) then
		BoardController.Cerrar()
	else
		BoardController.Abrir(roomId)
	end
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function BoardController:Init(registro)
	self.registro = registro
end

function BoardController:Start()
	if activo then
		return
	end
	activo = true
	local ok, err = pcall(construirUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
	end

	-- Entrada global del dibujo (movimiento y fin del trazo aunque el puntero salga del lienzo).
	maid:GiveTask(UserInputService.InputChanged:Connect(function(entrada)
		if not dibujo.Activo then
			return
		end
		if dibujo.EsRaton then
			if entrada.UserInputType == Enum.UserInputType.MouseMovement then
				agregarPunto(entrada.Position, false)
			end
		elseif entrada == dibujo.Entrada then
			agregarPunto(entrada.Position, false)
		end
	end))
	maid:GiveTask(UserInputService.InputEnded:Connect(function(entrada)
		if not dibujo.Activo then
			return
		end
		if dibujo.EsRaton then
			if entrada.UserInputType == Enum.UserInputType.MouseButton1 then
				terminarTrazo(entrada.Position)
			end
		elseif entrada == dibujo.Entrada then
			terminarTrazo(entrada.Position)
		end
	end))

	-- El cargo cambia lo que se puede hacer (sin ClassroomService el permiso tablero.escribir decide).
	maid:GiveTask(LocalPlayer:GetAttributeChangedSignal("Cargo"):Connect(function()
		refrescarHerramientas()
	end))

	-- Reubicación al cambiar el tamaño de la pantalla (rotación del móvil, ventana).
	local conexionCamara = nil
	local function vigilarCamara()
		if conexionCamara then
			conexionCamara:Disconnect()
			conexionCamara = nil
		end
		local camara = workspace.CurrentCamera
		if camara then
			conexionCamara = camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				reubicar()
			end)
		end
	end
	pcall(vigilarCamara)
	maid:GiveTask(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		pcall(vigilarCamara)
		reubicar()
	end))
	maid:GiveTask(function()
		if conexionCamara then
			conexionCamara:Disconnect()
		end
	end)

	-- Respawn: el panel sigue abierto; solo se cancela un trazo a medias.
	maid:GiveTask(LocalPlayer.CharacterAdded:Connect(function()
		cancelarTrazo()
	end))

	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn(LOG .. "EventoCliente no disponible; el tablero no recibirá cambios del servidor.")
			return
		end
		maid:GiveTask(remoto.OnClientEvent:Connect(function(carga)
			if typeof(carga) ~= "table" or carga.Tipo ~= "Tablero" or typeof(carga.Datos) ~= "table" then
				return
			end
			local exito, fallo = pcall(alRecibirTablero, carga.Datos)
			if not exito then
				warn(LOG .. tostring(fallo))
			end
		end))
	end)
end

return BoardController
