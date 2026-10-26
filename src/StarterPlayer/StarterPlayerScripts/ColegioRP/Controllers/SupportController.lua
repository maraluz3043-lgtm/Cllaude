--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.SupportController
	Tipo: ModuleScript
	Formulario de SOPORTE: categoría (Bug / Abuso / Duda / Sugerencia), ubicación prefijada con la zona actual
	(Util.Zones.ZonaDe, editable), descripción con contador y envío por ReportSubmit con estado
	("Enviando…", "Reporte recibido (id …)" o el error). Nunca muestra datos de otros jugadores.
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
		error("[ColegioRP][SupportController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local Config = require(esperarHijo(Shared, "Config"))
local UITheme = require(esperarHijo(Shared, "UITheme"))
local RemoteContracts = require(esperarHijo(Shared, "RemoteContracts"))
local Net = require(esperarHijo(Util, "Net"))
local Signal = require(esperarHijo(Util, "Signal"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local Zones = require(esperarHijo(Util, "Zones"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local Colores = UITheme.Colores

local SupportController = {}
SupportController.Nombre = "SupportController"
SupportController.Abierto = Signal.new()
SupportController.Cerrado = Signal.new()
SupportController.Enviado = Signal.new() -- (idReporte) tras una confirmación del servidor.

---------------------------------------------------------------------------------------------------
-- Constantes
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][SupportController] "
-- Capa de paneles (50). MenuController oculta su fondo al delegar, así que el panel queda visible.
local ORDEN_PANTALLA = UITheme.Capas.Panel
local REPORTES = Config.Reportes or {}
local MAX_DESCRIPCION = tonumber(REPORTES.MaxCaracteres) or 300
local MAX_UBICACION = tonumber(REPORTES.MaxUbicacionCaracteres) or 60
local MAX_POR_MINUTO = tonumber(REPORTES.MaxPorMinuto) or 2
local MIN_DESCRIPCION = 3
local ALTO_DESCRIPCION = 132

local CATEGORIAS = {
	{ Valor = "Bug", Texto = "Error (bug)" },
	{ Valor = "Abuso", Texto = "Abuso o conducta" },
	{ Valor = "Duda", Texto = "Duda" },
	{ Valor = "Sugerencia", Texto = "Sugerencia" },
}
local AYUDA_CATEGORIA = {
	Bug = "Cuenta qué estabas haciendo, qué esperabas que pasara y qué pasó en realidad.",
	Abuso = "Describe lo ocurrido y cuándo. La coordinación de convivencia lo revisará. No incluyas datos personales.",
	Duda = "Escribe tu pregunta. Revisa también AYUDA: quizá ya esté respondida.",
	Sugerencia = "Cuéntanos tu idea para mejorar el colegio.",
}
-- Solo se aceptan las categorías del contrato (RemoteContracts.CategoriasReporte).
do
	local validas = {}
	for _, categoria in ipairs(RemoteContracts.CategoriasReporte or {}) do
		validas[categoria] = true
	end
	if next(validas) ~= nil then
		local filtradas = {}
		for _, opcion in ipairs(CATEGORIAS) do
			if validas[opcion.Valor] then
				table.insert(filtradas, opcion)
			end
		end
		CATEGORIAS = filtradas
	end
end

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local abierto = false
local enviando = false
local ubicacionEditada = false
local textoUbicacionAuto = "" -- Último texto puesto automáticamente (para distinguir ediciones del jugador).
local envios = {} -- os.clock() de los envíos recientes (límite local, el servidor también limita).
local maidPanel = Maid.new()
local ui = {
	Gui = nil, Panel = nil, Categoria = nil, Ubicacion = nil, Descripcion = nil, Contador = nil,
	AyudaCategoria = nil, Estado = nil, BotonEnviar = nil,
}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function obtenerControlador(nombre)
	local registro = SupportController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

-- Nombre de la zona donde está el propio jugador (solo su personaje; nunca el de otros).
local function nombreZonaActual()
	local personaje = LocalPlayer.Character
	local raiz = personaje and (personaje:FindFirstChild("HumanoidRootPart") or personaje.PrimaryPart)
	if not raiz then
		return ""
	end
	local ok, zona = pcall(Zones.ZonaDe, raiz.Position)
	if ok and typeof(zona) == "table" then
		return Format.Truncar(tostring(zona.Nombre or zona.Id or ""), MAX_UBICACION)
	end
	return "Fuera de las zonas del colegio"
end

local function depurarEnvios()
	local ahora = os.clock()
	local i = 1
	while i <= #envios do
		if ahora - envios[i] >= 60 then
			table.remove(envios, i)
		else
			i = i + 1
		end
	end
end

local COLORES_ESTADO = { Info = Colores.TextoSecundario, Exito = Colores.Verde, Error = Colores.Rojo, Aviso = Colores.Amarillo }

local function mostrarEstado(texto, nivel)
	if ui.Estado and ui.Estado.Parent ~= nil then
		ui.Estado.Text = tostring(texto or "")
		ui.Estado.TextColor3 = COLORES_ESTADO[nivel] or Colores.TextoSecundario
	end
end

local function actualizarContador()
	if not ui.Contador or not ui.Descripcion then
		return
	end
	local n = Format.Longitud(ui.Descripcion.Text)
	ui.Contador.Text = tostring(n) .. " / " .. tostring(MAX_DESCRIPCION)
	if n >= MAX_DESCRIPCION then
		ui.Contador.TextColor3 = Colores.Amarillo
	elseif n > 0 and n < MIN_DESCRIPCION then
		ui.Contador.TextColor3 = Colores.Amarillo
	else
		ui.Contador.TextColor3 = Colores.TextoApagado
	end
end

local function actualizarAyudaCategoria(valor)
	if ui.AyudaCategoria then
		ui.AyudaCategoria.Text = AYUDA_CATEGORIA[valor] or ""
	end
end

local function rellenarUbicacion(forzar)
	if not ui.Ubicacion then
		return
	end
	if forzar or not ubicacionEditada or ui.Ubicacion.Text == "" then
		textoUbicacionAuto = nombreZonaActual()
		ubicacionEditada = false
		ui.Ubicacion.Text = textoUbicacionAuto
	end
end

---------------------------------------------------------------------------------------------------
-- Envío
---------------------------------------------------------------------------------------------------
local function enviar()
	if enviando or not ui.Descripcion then
		return
	end
	local descripcion = Format.Recortar(ui.Descripcion.Text)
	if Format.Longitud(descripcion) < MIN_DESCRIPCION then
		mostrarEstado("Escribe una descripción de al menos " .. MIN_DESCRIPCION .. " caracteres.", "Error")
		return
	end
	if Format.Longitud(descripcion) > MAX_DESCRIPCION then
		descripcion = Format.Truncar(descripcion, MAX_DESCRIPCION)
	end
	local ubicacion = Format.Recortar(ui.Ubicacion and ui.Ubicacion.Text or "")
	if Format.Longitud(ubicacion) > MAX_UBICACION then
		ubicacion = Format.Truncar(ubicacion, MAX_UBICACION)
	end
	depurarEnvios()
	if #envios >= MAX_POR_MINUTO then
		local espera = math.max(1, math.ceil(60 - (os.clock() - envios[1])))
		mostrarEstado("Has enviado " .. MAX_POR_MINUTO .. " reportes en el último minuto. Espera " .. espera .. " s.", "Aviso")
		return
	end
	local categoria = ui.Categoria and ui.Categoria:Valor() or "Duda"
	local datos = { Categoria = categoria, Ubicacion = ubicacion, Descripcion = descripcion }
	local valido, err = RemoteContracts.Validar("ReportSubmit", datos)
	if not valido then
		mostrarEstado("Revisa el formulario: " .. tostring(err), "Error")
		return
	end

	enviando = true
	table.insert(envios, os.clock())
	if ui.BotonEnviar then
		UIBuilder.Habilitar(ui.BotonEnviar, false)
		ui.BotonEnviar.Text = "Enviando…"
	end
	mostrarEstado("Enviando…", "Info")
	task.spawn(function()
		local ok, respuesta = Net.Invocar("ReportSubmit", datos)
		enviando = false
		if ui.BotonEnviar and ui.BotonEnviar.Parent ~= nil then
			UIBuilder.Habilitar(ui.BotonEnviar, true)
			ui.BotonEnviar.Text = "Enviar reporte"
		end
		if ok then
			local id = nil
			if typeof(respuesta) == "table" and typeof(respuesta.datos) == "table" then
				id = respuesta.datos.Id
			end
			local textoId = "—"
			if typeof(id) == "string" or typeof(id) == "number" then
				textoId = Format.Truncar(tostring(id), 40)
			end
			mostrarEstado("Reporte recibido (id " .. textoId .. "). ¡Gracias!", "Exito")
			if ui.Descripcion and ui.Descripcion.Parent ~= nil then
				ui.Descripcion.Text = ""
				actualizarContador()
			end
			SupportController.Enviado:Fire(id)
		else
			local mensaje = UIBuilder.MensajeError(typeof(respuesta) == "table" and respuesta.error or nil)
			mostrarEstado("No se pudo enviar: " .. mensaje, "Error")
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Construcción del panel
---------------------------------------------------------------------------------------------------
local function construirUI()
	local gui = UIBuilder.Pantalla("Soporte", ORDEN_PANTALLA)
	ui.Gui = gui
	local contenedor = UIBuilder.Contenedor(gui)
	local panel, lista = UIBuilder.Panel(contenedor, {
		Nombre = "PanelSoporte",
		Titulo = "Soporte",
		AlCerrar = function()
			SupportController.Cerrar()
		end,
		Scroll = true,
		Espaciado = 6,
		Size = UDim2.new(1, 0, 1, 0),
	})
	local limite = Instance.new("UISizeConstraint")
	limite.MaxSize = Vector2.new(580, 700)
	limite.Parent = panel
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	ui.Panel = panel

	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end

	UIBuilder.Texto(lista, "Envía un reporte al equipo del colegio. No escribas datos personales (nombre real, teléfono, dirección ni contraseñas).", {
		LayoutOrder = siguiente(), Color = Colores.TextoSecundario, Tamano = "Pequeno",
	})

	local primera = CATEGORIAS[1] and CATEGORIAS[1].Valor or "Duda"
	ui.Categoria = UIBuilder.Selector(lista, "Categoría", CATEGORIAS, primera, function(valor)
		actualizarAyudaCategoria(valor)
	end, { LayoutOrder = siguiente(), Nombre = "Categoria", AnchoGrupo = 230 })
	ui.AyudaCategoria = UIBuilder.Texto(lista, AYUDA_CATEGORIA[primera] or "", {
		LayoutOrder = siguiente(), Color = Colores.TextoApagado, Tamano = "Pequeno", Nombre = "AyudaCategoria",
	})

	UIBuilder.Texto(lista, "Ubicación (zona actual; puedes editarla)", { LayoutOrder = siguiente(), Fuente = "Subtitulo", Tamano = "Pequeno" })
	local altoControl = UIBuilder.AltoBoton()
	local filaUbicacion = UIBuilder.Marco(lista, { Nombre = "FilaUbicacion", Alto = altoControl, LayoutOrder = siguiente() })
	local anchoBotonZona = 150
	textoUbicacionAuto = nombreZonaActual()
	ubicacionEditada = false
	ui.Ubicacion = UIBuilder.Entrada(filaUbicacion, "¿Dónde ocurrió?", {
		Max = MAX_UBICACION,
		Texto = textoUbicacionAuto,
		Size = UDim2.new(1, -(anchoBotonZona + UITheme.Espaciado), 1, 0),
		AlCambiar = function(texto)
			-- Con señales diferidas el cambio automático también llega aquí: solo cuenta si difiere.
			if texto ~= textoUbicacionAuto then
				ubicacionEditada = true
			end
		end,
	})
	UIBuilder.Boton(filaUbicacion, "Mi ubicación", function()
		rellenarUbicacion(true)
	end, {
		Estilo = "Secundario", Ancho = anchoBotonZona, Alto = altoControl, Nombre = "UsarUbicacion",
		Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0),
	})

	UIBuilder.Texto(lista, "Descripción", { LayoutOrder = siguiente(), Fuente = "Subtitulo", Tamano = "Pequeno" })
	ui.Descripcion = UIBuilder.Entrada(lista, "Describe lo ocurrido con el mayor detalle posible…", {
		Max = MAX_DESCRIPCION,
		Multilinea = true,
		Alto = ALTO_DESCRIPCION,
		LayoutOrder = siguiente(),
		Nombre = "Descripcion",
		AlCambiar = function()
			actualizarContador()
		end,
	})
	ui.Contador = UIBuilder.Texto(lista, "0 / " .. MAX_DESCRIPCION, {
		LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado,
		Alineacion = Enum.TextXAlignment.Right, Nombre = "Contador",
	})

	local fila = UIBuilder.Fila(lista, { LayoutOrder = siguiente(), Nombre = "Acciones" })
	ui.BotonEnviar = UIBuilder.Boton(fila, "Enviar reporte", enviar, { Estilo = "Primario", Ancho = 190, LayoutOrder = 1, Nombre = "Enviar" })
	UIBuilder.Boton(fila, "Cerrar", function()
		SupportController.Cerrar()
	end, { Estilo = "Secundario", Ancho = 120, LayoutOrder = 2, Nombre = "CerrarPanel" })

	ui.Estado = UIBuilder.Texto(lista, "", { LayoutOrder = siguiente(), Nombre = "Estado" })
	UIBuilder.Texto(lista, "Máximo " .. MAX_POR_MINUTO .. " reportes por minuto. Recibirás un id de confirmación; los reportes los revisan la coordinación de convivencia y la dirección.", {
		LayoutOrder = siguiente(), Tamano = "Pequeno", Color = Colores.TextoApagado,
	})

	UIBuilder.Encadenar({ ui.Categoria.Botones[1], ui.Ubicacion, ui.Descripcion, ui.BotonEnviar })
	actualizarContador()
end

local function asegurarUI()
	if not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil then
		construirUI()
	end
end

local function cerrarHermanos()
	for _, nombre in ipairs({ "SettingsController", "HelpController" }) do
		local otro = obtenerControlador(nombre)
		if otro and typeof(otro.Cerrar) == "function" then
			local estaAbierto = true
			if typeof(otro.EstaAbierto) == "function" then
				local ok, valor = pcall(otro.EstaAbierto)
				estaAbierto = ok and valor == true
			end
			if estaAbierto then
				pcall(otro.Cerrar)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- API pública (admite llamada con punto o con dos puntos)
---------------------------------------------------------------------------------------------------
function SupportController.EstaAbierto()
	return abierto
end

-- Abre el formulario; opcionalmente con una categoría preseleccionada ("Bug" | "Abuso" | "Duda" | "Sugerencia").
function SupportController.Abrir(a, b)
	if not activo then
		return
	end
	local categoria = a
	if a == SupportController then
		categoria = b
	end
	local ok, err = pcall(asegurarUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
		return
	end
	if typeof(categoria) == "string" and ui.Categoria then
		ui.Categoria:Fijar(categoria, true)
		actualizarAyudaCategoria(ui.Categoria:Valor())
	end
	rellenarUbicacion(false)
	if not enviando then
		mostrarEstado("", "Info")
	end
	if abierto then
		UIBuilder.EnfocarPrimero(ui.Panel)
		return
	end
	cerrarHermanos()
	abierto = true
	ui.Gui.Enabled = true
	UIBuilder.Aparecer(ui.Panel)
	local conexion = UIBuilder.TeclaCerrar(function()
		SupportController.Cerrar()
	end)
	if conexion then
		maidPanel:GiveTask(conexion)
	end
	task.delay(UITheme.Animacion.Rapida + 0.05, function()
		if abierto and ui.Panel and ui.Panel.Parent ~= nil then
			ui.Panel.Visible = true
		end
	end)
	task.defer(function()
		if abierto and ui.Categoria and ui.Categoria.Botones[1] then
			UIBuilder.Enfocar(ui.Categoria.Botones[1])
		end
	end)
	SupportController.Abierto:Fire()
end

function SupportController.Cerrar()
	if not abierto then
		return
	end
	abierto = false
	maidPanel:DoCleaning()
	for _, caja in ipairs({ ui.Ubicacion, ui.Descripcion }) do
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
	SupportController.Cerrado:Fire()
end

function SupportController.Alternar()
	if abierto then
		SupportController.Cerrar()
	else
		SupportController.Abrir()
	end
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function SupportController:Init(registro)
	self.registro = registro
end

function SupportController:Start()
	if activo then
		return
	end
	activo = true
	local ok, err = pcall(construirUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
	end
end

return SupportController
