--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.HelpController
	Tipo: ModuleScript
	Panel de AYUDA: secciones de Catalogs.Ayuda (lista a la izquierda o pestañas en pantallas estrechas),
	párrafos con desplazamiento, controles del dispositivo detectado (Catalogs.Controles), preguntas
	frecuentes (Catalogs.FAQ) y búsqueda simple por texto (sin distinguir mayúsculas ni tildes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TIMEOUT = 30
local function esperarHijo(padre, nombre)
	local hijo = nil
	if padre then
		hijo = padre:FindFirstChild(nombre) or padre:WaitForChild(nombre, TIMEOUT)
	end
	if not hijo then
		error("[ColegioRP][HelpController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local UITheme = require(esperarHijo(Shared, "UITheme"))
local Catalogs = require(esperarHijo(Shared, "Catalogs"))
local Signal = require(esperarHijo(Util, "Signal"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local Colores = UITheme.Colores

local HelpController = {}
HelpController.Nombre = "HelpController"
HelpController.Abierto = Signal.new()
HelpController.Cerrado = Signal.new()

---------------------------------------------------------------------------------------------------
-- Constantes y datos
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][HelpController] "
-- Capa de paneles (50). MenuController oculta su fondo al delegar, así que el panel queda visible.
local ORDEN_PANTALLA = UITheme.Capas.Panel
local ANCHO_LISTA = 230
local MAX_BUSQUEDA = 40
local MIN_BUSQUEDA = 2
local MAX_PARRAFOS_RESULTADO = 3
local ESPERA_BUSQUEDA = 0.25

local SECCIONES = Catalogs.Ayuda or {}
local FAQ = Catalogs.FAQ or {}
local CONTROLES = Catalogs.Controles or {}

-- Catalogs.Controles tiene PC, Movil y Mando; la tableta usa los controles táctiles.
local CLAVE_CONTROLES = { PC = "PC", Movil = "Movil", Tableta = "Movil", Mando = "Mando" }
local PLATAFORMAS = {
	{ Clave = "PC", Texto = "PC" },
	{ Clave = "Movil", Texto = "Móvil / tableta" },
	{ Clave = "Mando", Texto = "Mando" },
}
local NOMBRE_PLATAFORMA = { PC = "PC (teclado y ratón)", Movil = "móvil o tableta (táctil)", Mando = "mando" }

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local abierto = false
local maidPanel = Maid.new()
local ui = {
	Gui = nil, Panel = nil, Busqueda = nil, Contenido = nil, Botones = {}, Estrecho = nil,
}
local seccionActual = nil
local plataformaControles = nil
local consultaActual = ""
local generacionBusqueda = 0

---------------------------------------------------------------------------------------------------
-- Utilidades de texto
---------------------------------------------------------------------------------------------------
local REEMPLAZOS = {
	{ "á", "a" }, { "é", "e" }, { "í", "i" }, { "ó", "o" }, { "ú", "u" }, { "ü", "u" }, { "ñ", "n" },
	{ "Á", "a" }, { "É", "e" }, { "Í", "i" }, { "Ó", "o" }, { "Ú", "u" }, { "Ü", "u" }, { "Ñ", "n" },
}

-- Minúsculas y sin tildes, para comparar sin distinguir mayúsculas ni acentos.
local function normalizar(texto)
	local resultado = string.lower(tostring(texto or ""))
	for _, par in ipairs(REEMPLAZOS) do
		resultado = string.gsub(resultado, par[1], par[2])
	end
	return resultado
end

-- Palabras de la consulta (separadas por espacios), ya normalizadas.
local function terminos(consulta)
	local lista = {}
	for palabra in string.gmatch(normalizar(consulta), "%S+") do
		table.insert(lista, palabra)
	end
	return lista
end

-- ¿El texto contiene todas las palabras? (búsqueda literal, sin patrones)
local function coincide(texto, palabras)
	if #palabras == 0 then
		return false
	end
	local normal = normalizar(texto)
	for _, palabra in ipairs(palabras) do
		if not string.find(normal, palabra, 1, true) then
			return false
		end
	end
	return true
end

local function obtenerControlador(nombre)
	local registro = HelpController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

local function plataformaDetectada()
	return CLAVE_CONTROLES[UITheme.Dispositivo()] or "PC"
end

---------------------------------------------------------------------------------------------------
-- Contenido
---------------------------------------------------------------------------------------------------
local function limpiarContenido()
	local contenido = ui.Contenido
	if not contenido then
		return
	end
	for _, hijo in ipairs(contenido:GetChildren()) do
		if hijo:IsA("GuiObject") then
			hijo:Destroy()
		end
	end
	pcall(function()
		contenido.CanvasPosition = Vector2.new(0, 0)
	end)
end

local function parrafo(texto, orden, props)
	props = props or {}
	return UIBuilder.Texto(ui.Contenido, texto, {
		LayoutOrder = orden,
		Color = props.Color or Colores.TextoSecundario,
		Tamano = props.Tamano or "Texto",
		Fuente = props.Fuente,
		Nombre = props.Nombre or "Parrafo",
	})
end

-- Tabla "acción — control" de una plataforma.
local function tablaControles(clave, ordenInicial)
	local orden = ordenInicial
	for _, fila in ipairs(CONTROLES[clave] or {}) do
		orden = orden + 1
		local marco = UIBuilder.Marco(ui.Contenido, { Nombre = "Control", LayoutOrder = orden, AutoAlto = true, Color = Colores.Gris, Transparencia = 0.55 })
		UIBuilder.Esquinas(marco, UITheme.RadioPequeno)
		UIBuilder.Relleno(marco, 6, 6, 10, 10)
		UIBuilder.Disposicion(marco, { Espaciado = 2 })
		UIBuilder.Texto(marco, tostring(fila.Accion or ""), { LayoutOrder = 1, Fuente = "Subtitulo", Tamano = "Texto" })
		UIBuilder.Texto(marco, tostring(fila.Control or ""), { LayoutOrder = 2, Color = Colores.Amarillo, Tamano = "Pequeno" })
	end
	return orden
end

local mostrarSeccion -- (id) declarado más abajo.

local function selectorPlataforma(orden)
	local fila = UIBuilder.Fila(ui.Contenido, { LayoutOrder = orden, Nombre = "Plataformas", Espaciado = 6 })
	local botones = {}
	for i, plataforma in ipairs(PLATAFORMAS) do
		local estilo = "Secundario"
		if plataforma.Clave == plataformaControles then
			estilo = "Primario"
		end
		local boton = UIBuilder.Boton(fila, plataforma.Texto, function()
			plataformaControles = plataforma.Clave
			mostrarSeccion("Controles")
		end, { Estilo = estilo, Ancho = 150, LayoutOrder = i, Nombre = "Plataforma_" .. plataforma.Clave })
		table.insert(botones, boton)
	end
	UIBuilder.Encadenar(botones, true)
end

local function bloqueFAQ(entrada, orden)
	local marco = UIBuilder.Marco(ui.Contenido, { Nombre = "Pregunta", LayoutOrder = orden, AutoAlto = true, Color = Colores.Gris, Transparencia = 0.55 })
	UIBuilder.Esquinas(marco, UITheme.RadioPequeno)
	UIBuilder.Relleno(marco, 8, 8, 10, 10)
	UIBuilder.Disposicion(marco, { Espaciado = 4 })
	UIBuilder.Texto(marco, tostring(entrada.Pregunta or ""), { LayoutOrder = 1, Fuente = "Subtitulo" })
	UIBuilder.Texto(marco, tostring(entrada.Respuesta or ""), { LayoutOrder = 2, Color = Colores.TextoSecundario, Tamano = "Pequeno" })
end

local function marcarBotones()
	for id, boton in pairs(ui.Botones) do
		if boton and boton.Parent ~= nil then
			if id == seccionActual and consultaActual == "" then
				boton:SetAttribute("Estilo", "Primario")
			else
				boton:SetAttribute("Estilo", "Fantasma")
			end
			UIBuilder.Habilitar(boton, true) -- Repinta con el estilo nuevo.
		end
	end
end

mostrarSeccion = function(id)
	local seccion = Catalogs.SeccionAyuda(id) or SECCIONES[1]
	if not seccion or not ui.Contenido then
		return
	end
	seccionActual = seccion.Id
	limpiarContenido()
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	UIBuilder.Titulo(ui.Contenido, seccion.Titulo or seccion.Id, { LayoutOrder = siguiente(), Tamano = "Subtitulo" })
	for _, texto in ipairs(seccion.Parrafos or {}) do
		parrafo(texto, siguiente())
	end
	if seccion.Id == "Controles" then
		if plataformaControles == nil then
			plataformaControles = plataformaDetectada()
		end
		UIBuilder.Espacio(ui.Contenido, 4, siguiente())
		parrafo("Dispositivo detectado: " .. (NOMBRE_PLATAFORMA[plataformaDetectada()] or "PC") .. ". Mostrando controles de " .. (NOMBRE_PLATAFORMA[plataformaControles] or plataformaControles) .. ":", siguiente(), { Color = Colores.TextoPrincipal, Tamano = "Pequeno" })
		selectorPlataforma(siguiente())
		orden = tablaControles(plataformaControles, orden)
	elseif seccion.Id == "FAQ" then
		for _, entrada in ipairs(FAQ) do
			bloqueFAQ(entrada, siguiente())
		end
	end
	marcarBotones()
end

-- Resultados de búsqueda: secciones (título o párrafos), controles y preguntas frecuentes.
local function mostrarResultados(consulta)
	if not ui.Contenido then
		return
	end
	local palabras = terminos(consulta)
	limpiarContenido()
	local orden = 0
	local function siguiente()
		orden = orden + 1
		return orden
	end
	UIBuilder.Titulo(ui.Contenido, "Resultados para «" .. Format.Truncar(consulta, MAX_BUSQUEDA) .. "»", { LayoutOrder = siguiente(), Tamano = "Subtitulo" })
	local encontrados = 0

	for _, seccion in ipairs(SECCIONES) do
		local enTitulo = coincide(seccion.Titulo, palabras)
		local parrafos = {}
		for _, texto in ipairs(seccion.Parrafos or {}) do
			if coincide(texto, palabras) then
				table.insert(parrafos, texto)
			end
		end
		if enTitulo or #parrafos > 0 then
			encontrados = encontrados + 1
			local fila = UIBuilder.Fila(ui.Contenido, { LayoutOrder = siguiente(), Nombre = "Resultado" })
			UIBuilder.Boton(fila, (seccion.Titulo or seccion.Id) .. "  ›", function()
				if ui.Busqueda then
					ui.Busqueda.Text = ""
				end
				consultaActual = ""
				mostrarSeccion(seccion.Id)
			end, { Estilo = "Secundario", Ancho = 360, Alineacion = Enum.TextXAlignment.Left, Nombre = "IrSeccion" })
			for i, texto in ipairs(parrafos) do
				if i <= MAX_PARRAFOS_RESULTADO then
					parrafo(texto, siguiente(), { Tamano = "Pequeno" })
				end
			end
		end
	end

	local controlesEncontrados = {}
	for _, plataforma in ipairs(PLATAFORMAS) do
		for _, fila in ipairs(CONTROLES[plataforma.Clave] or {}) do
			if coincide(tostring(fila.Accion) .. " " .. tostring(fila.Control), palabras) then
				table.insert(controlesEncontrados, plataforma.Texto .. ": " .. tostring(fila.Accion) .. " — " .. tostring(fila.Control))
			end
		end
	end
	if #controlesEncontrados > 0 then
		encontrados = encontrados + #controlesEncontrados
		UIBuilder.Subtitulo(ui.Contenido, "Controles", { LayoutOrder = siguiente() })
		for _, texto in ipairs(controlesEncontrados) do
			parrafo(texto, siguiente(), { Tamano = "Pequeno", Color = Colores.TextoPrincipal })
		end
	end

	local faqEncontradas = {}
	for _, entrada in ipairs(FAQ) do
		if coincide(tostring(entrada.Pregunta) .. " " .. tostring(entrada.Respuesta), palabras) then
			table.insert(faqEncontradas, entrada)
		end
	end
	if #faqEncontradas > 0 then
		encontrados = encontrados + #faqEncontradas
		UIBuilder.Subtitulo(ui.Contenido, "Preguntas frecuentes", { LayoutOrder = siguiente() })
		for _, entrada in ipairs(faqEncontradas) do
			bloqueFAQ(entrada, siguiente())
		end
	end

	if encontrados == 0 then
		parrafo("Sin resultados. Prueba con otra palabra (por ejemplo «cuaderno», «comida» o «asistencia») o envía una Duda desde SOPORTE.", siguiente())
	end
	marcarBotones()
end

local function buscar(texto)
	local consulta = Format.Recortar(texto or "")
	if Format.Longitud(consulta) < MIN_BUSQUEDA then
		if consultaActual ~= "" then
			consultaActual = ""
			mostrarSeccion(seccionActual)
		end
		return
	end
	consultaActual = consulta
	mostrarResultados(consulta)
end

-- Búsqueda con espera breve tras la última tecla (no se reconstruye por cada pulsación).
local function programarBusqueda(texto)
	generacionBusqueda = generacionBusqueda + 1
	local generacion = generacionBusqueda
	task.delay(ESPERA_BUSQUEDA, function()
		if generacion == generacionBusqueda and abierto then
			buscar(texto)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Construcción del panel
---------------------------------------------------------------------------------------------------
local function construirUI()
	local gui = UIBuilder.Pantalla("Ayuda", ORDEN_PANTALLA)
	ui.Gui = gui
	ui.Botones = {}
	ui.Estrecho = UIBuilder.EsEstrecho()
	local contenedor = UIBuilder.Contenedor(gui)
	local panel, cuerpo = UIBuilder.Panel(contenedor, {
		Nombre = "PanelAyuda",
		Titulo = "Ayuda",
		AlCerrar = function()
			HelpController.Cerrar()
		end,
		Size = UDim2.new(1, 0, 1, 0),
	})
	local limite = Instance.new("UISizeConstraint")
	limite.MaxSize = Vector2.new(900, 760)
	limite.Parent = panel
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	ui.Panel = panel

	local altoControl = UIBuilder.AltoBoton()
	local espacio = UITheme.Espaciado

	-- Barra de búsqueda.
	local barra = UIBuilder.Marco(cuerpo, { Nombre = "Busqueda", Alto = altoControl })
	ui.Busqueda = UIBuilder.Entrada(barra, "Buscar en la ayuda (p. ej. «cuaderno»)…", {
		Max = MAX_BUSQUEDA,
		Size = UDim2.new(1, -(altoControl + espacio), 1, 0),
		AlCambiar = programarBusqueda,
		AlEnviar = function(texto)
			generacionBusqueda = generacionBusqueda + 1
			buscar(texto)
		end,
	})
	UIBuilder.Boton(barra, "✕", function()
		if ui.Busqueda then
			ui.Busqueda.Text = ""
		end
		generacionBusqueda = generacionBusqueda + 1
		consultaActual = ""
		mostrarSeccion(seccionActual)
	end, { Estilo = "Secundario", Ancho = altoControl, Alto = altoControl, Nombre = "LimpiarBusqueda", Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0) })

	local arriba = altoControl + espacio
	local navegacion
	if ui.Estrecho then
		-- Pantallas estrechas (móvil): pestañas horizontales con desplazamiento.
		local altoPestanas = altoControl + 10
		navegacion = UIBuilder.Lista(cuerpo, {
			Nombre = "Pestanas", Horizontal = true, Espaciado = 6,
			Size = UDim2.new(1, 0, 0, altoPestanas), Position = UDim2.new(0, 0, 0, arriba),
		})
		local contenido = UIBuilder.Lista(cuerpo, {
			Nombre = "Contenido", Espaciado = 8,
			Size = UDim2.new(1, 0, 1, -(arriba + altoPestanas + espacio)),
			Position = UDim2.new(0, 0, 0, arriba + altoPestanas + espacio),
		})
		ui.Contenido = contenido
	else
		-- Pantallas anchas: lista de secciones a la izquierda y contenido a la derecha.
		navegacion = UIBuilder.Lista(cuerpo, {
			Nombre = "Secciones", Espaciado = 4,
			Size = UDim2.new(0, ANCHO_LISTA, 1, -arriba), Position = UDim2.new(0, 0, 0, arriba),
		})
		UIBuilder.Separador(cuerpo, {
			Size = UDim2.new(0, 1, 1, -arriba), Position = UDim2.new(0, ANCHO_LISTA + espacio, 0, arriba),
		})
		local contenido = UIBuilder.Lista(cuerpo, {
			Nombre = "Contenido", Espaciado = 8,
			Size = UDim2.new(1, -(ANCHO_LISTA + espacio * 2 + 1), 1, -arriba),
			Position = UDim2.new(0, ANCHO_LISTA + espacio * 2 + 1, 0, arriba),
		})
		ui.Contenido = contenido
	end

	local botones = {}
	for i, seccion in ipairs(SECCIONES) do
		local props = { Estilo = "Fantasma", LayoutOrder = i, Nombre = "Seccion_" .. tostring(seccion.Id) }
		if ui.Estrecho then
			props.Ancho = 170
		else
			props.Size = UDim2.new(1, 0, 0, altoControl)
			props.Alineacion = Enum.TextXAlignment.Left
		end
		local boton = UIBuilder.Boton(navegacion, seccion.Titulo or seccion.Id, function()
			if ui.Busqueda then
				ui.Busqueda.Text = ""
			end
			generacionBusqueda = generacionBusqueda + 1
			consultaActual = ""
			mostrarSeccion(seccion.Id)
		end, props)
		ui.Botones[seccion.Id] = boton
		table.insert(botones, boton)
	end
	UIBuilder.Encadenar(botones, ui.Estrecho == true)

	mostrarSeccion(seccionActual or (SECCIONES[1] and SECCIONES[1].Id))
end

local function asegurarUI()
	local necesita = not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil
	-- Si cambió el ancho de pantalla (rotación, ventana), se rehace con la disposición adecuada.
	if not necesita and ui.Estrecho ~= UIBuilder.EsEstrecho() then
		necesita = true
	end
	if necesita then
		construirUI()
	end
end

local function cerrarHermanos()
	for _, nombre in ipairs({ "SettingsController", "SupportController" }) do
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
function HelpController.EstaAbierto()
	return abierto
end

-- Abre la ayuda; opcionalmente en una sección (Id de Catalogs.Ayuda: "Controles", "FAQ", ...).
function HelpController.Abrir(a, b)
	if not activo then
		return
	end
	local seccionId = a
	if a == HelpController then
		seccionId = b
	end
	local ok, err = pcall(asegurarUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
		return
	end
	if typeof(seccionId) == "string" and Catalogs.SeccionAyuda(seccionId) then
		if ui.Busqueda then
			ui.Busqueda.Text = ""
		end
		consultaActual = ""
		mostrarSeccion(seccionId)
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
		HelpController.Cerrar()
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
		if abierto then
			local boton = seccionActual and ui.Botones[seccionActual]
			if boton then
				UIBuilder.Enfocar(boton)
			else
				UIBuilder.EnfocarPrimero(ui.Panel)
			end
		end
	end)
	HelpController.Abierto:Fire()
end

function HelpController.Cerrar()
	if not abierto then
		return
	end
	abierto = false
	generacionBusqueda = generacionBusqueda + 1
	maidPanel:DoCleaning()
	if ui.Busqueda then
		pcall(function()
			ui.Busqueda:ReleaseFocus()
		end)
	end
	if ui.Panel and ui.Panel.Parent ~= nil then
		UIBuilder.Desenfocar(ui.Panel)
		UIBuilder.Desaparecer(ui.Panel)
	end
	HelpController.Cerrado:Fire()
end

function HelpController.Alternar()
	if abierto then
		HelpController.Cerrar()
	else
		HelpController.Abrir()
	end
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function HelpController:Init(registro)
	self.registro = registro
end

function HelpController:Start()
	if activo then
		return
	end
	activo = true
	seccionActual = SECCIONES[1] and SECCIONES[1].Id or nil
	local ok, err = pcall(construirUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
	end
end

return HelpController
