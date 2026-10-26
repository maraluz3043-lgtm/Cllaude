--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.FoodController
	Tipo: ModuleScript
	Panel del comedor gratuito (docs/ARQUITECTURA.md §7): muestra el ESTADO (abierto/cerrado y periodo, raciones,
	lote, menú y el tiempo que falta para el próximo reclamo propio) cuando el jugador está en COCINA, en la fila de
	la ventana de servicio o en los comedores (detección de zona a 1 Hz). El reclamo se hace con el ProximityPrompt
	físico "Reclamar almuerzo" (lo procesa el servidor) o con el botón del panel junto a la ventana de servicio
	(FoodAction "Reclamar"; el servidor valida distancia, periodo, cooldown y raciones). Para el personal de cocina
	añade el panel de cocina: receta activa, pasos, progreso, lote y botones que llaman a FoodAction (IniciarReceta,
	Paso, Entregar, Reponer). Oculta localmente los prompts de las estaciones a quien no tiene permiso de cocina.
	ScreenGui "ColegioRP_Comedor" (DisplayOrder de paneles). Escucha EventoCliente Tipo "Comida".
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
		error("[ColegioRP][FoodController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local Config = require(esperarHijo(Shared, "Config"))
local UITheme = require(esperarHijo(Shared, "UITheme"))
local Catalogs = require(esperarHijo(Shared, "Catalogs"))
local MapaLogico = require(esperarHijo(Shared, "MapaLogico"))
local RoleDefinitions = require(esperarHijo(Shared, "RoleDefinitions"))
local Net = require(esperarHijo(Util, "Net"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local Zones = require(esperarHijo(Util, "Zones"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local Colores = UITheme.Colores

local FoodController = {}
FoodController.Nombre = "FoodController"
-- Este controlador atiende su propio evento "AbrirPanel" (InteractionController no lo delega).
FoodController.ManejaAperturaPropia = true

---------------------------------------------------------------------------------------------------
-- Constantes
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][FoodController] "
local ORDEN_PANTALLA = (UITheme.Capas and UITheme.Capas.Panel) or 50
local ZONA_COCINA = "COCINA"
local ZONAS_COMEDOR = { COCINA = true, COMEDOR = true, COMEDOR_COCINA = true }
local ACCION_HUD = "Comedor"
local CARPETA_MAPA = (Config.Nombres and Config.Nombres.CarpetaMapa) or "ColegioRP_Mapa"
local CARPETA_PROPIA = "ColegioRP_Comedor"
local INTERVALO_ZONA = 1
local INTERVALO_UI = 0.2
local CONSULTA_MIN_SEG = 5
local ANCHO_PANEL = 330
local ALTO_ESTADO = 340 -- incluye el botón «Reclamar almuerzo»
local ALTO_COCINA = 560
local MARGEN_BOTONES_HUD = 176 -- alto aproximado de la columna de botones del HUD (esquina superior derecha)
local RACIONES_POR_LOTE = math.max(1, math.floor(tonumber(Config.Comedor and Config.Comedor.RacionesPorLote) or 40))

local DISTANCIA_ESTACION_ZONA = 14 -- cerca de una estación se considera "en la cocina" (algunas quedan fuera de la caja)
local FILA = nil
local PUNTOS_ESTACION = {}
do
	local cocina = MapaLogico.Zonas and MapaLogico.Zonas[ZONA_COCINA]
	if cocina and typeof(cocina.FilaEstudiantes) == "table" and typeof(cocina.FilaEstudiantes.Centro) == "Vector3" and typeof(cocina.FilaEstudiantes.Tamano) == "Vector3" then
		FILA = cocina.FilaEstudiantes
	end
	if cocina and typeof(cocina.Estaciones) == "table" then
		for _, punto in pairs(cocina.Estaciones) do
			if typeof(punto) == "Vector3" then
				table.insert(PUNTOS_ESTACION, punto)
			end
		end
	end
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end
local HEX_VERDE = hex(Colores.Verde)
local HEX_ROJO = hex(Colores.Rojo)
local HEX_AMARILLO = hex(Colores.Amarillo)
local HEX_APAGADO = hex(Colores.TextoApagado)

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local abierto = false
local cerradoPorUsuario = false
local forzarCocina = false
local estado = nil -- último estado del comedor (servidor)
local personal = { ProximoReclamo = 0 }
local pasoActual = nil -- { Estacion, NombreEstacion, FinServidor, Duracion }
local zonaActual = nil -- "COCINA" | "COMEDOR" | "COMEDOR_COCINA" | "FILA" | nil
local pidiendo = false
local ultimaConsulta = -math.huge
local maid = Maid.new()
local maidPanel = Maid.new()
local maidPrompts = Maid.new()
local carpetasVigiladas = {}
local ui = {}

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function obtenerControlador(nombre)
	local registro = FoodController.registro
	if typeof(registro) ~= "table" or typeof(registro.Get) ~= "function" then
		return nil
	end
	local ok, controlador = pcall(registro.Get, nombre)
	if ok and typeof(controlador) == "table" then
		return controlador
	end
	return nil
end

local function notificar(texto, nivel, duracion)
	local Notif = obtenerControlador("NotificationController")
	if Notif and typeof(Notif.Notificar) == "function" then
		pcall(Notif.Notificar, Notif, texto, nivel or "info", duracion)
	else
		print(LOG .. tostring(texto))
	end
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

local function tiene(permiso)
	return RoleDefinitions.Tiene(LocalPlayer:GetAttribute("Cargo"), permiso) == true
end

local function esCocina()
	return tiene("cocina.operar")
end

local function puedeReponer()
	return tiene("comedor.reponer")
end

local function nombreEstacion(nombre)
	return (Catalogs.Estaciones and Catalogs.Estaciones[nombre]) or tostring(nombre or "")
end

local function posicionPropia()
	local personaje = LocalPlayer.Character
	local raiz = personaje and (personaje:FindFirstChild("HumanoidRootPart") or personaje.PrimaryPart)
	if raiz and raiz:IsA("BasePart") then
		return raiz.Position
	end
	return nil
end

-- Zona relevante para el comedor en la que está el jugador (o nil).
local function detectarZona()
	local pos = posicionPropia()
	if not pos then
		return nil
	end
	if Zones.Contiene(ZONA_COCINA, pos) then
		return ZONA_COCINA
	end
	for _, punto in ipairs(PUNTOS_ESTACION) do
		if (pos - punto).Magnitude <= DISTANCIA_ESTACION_ZONA then
			return ZONA_COCINA
		end
	end
	if FILA then
		local d = pos - FILA.Centro
		if math.abs(d.X) <= FILA.Tamano.X / 2 and math.abs(d.Y) <= FILA.Tamano.Y / 2 and math.abs(d.Z) <= FILA.Tamano.Z / 2 then
			return "FILA"
		end
	end
	local ok, zona = pcall(Zones.ZonaDe, pos)
	if ok and typeof(zona) == "table" and ZONAS_COMEDOR[zona.Id] then
		return zona.Id
	end
	return nil
end

local function mostrarCocina()
	if not (esCocina() or puedeReponer()) then
		return false
	end
	return zonaActual == ZONA_COCINA or forzarCocina
end

---------------------------------------------------------------------------------------------------
-- Prompts de las estaciones: se ocultan localmente a quien no puede usarlos (el servidor valida igual)
---------------------------------------------------------------------------------------------------
local function aplicarPrompt(prompt)
	if typeof(prompt) ~= "Instance" or not prompt:IsA("ProximityPrompt") then
		return
	end
	if prompt:GetAttribute("RPTipo") ~= "Cocina" then
		return
	end
	local permitido = esCocina()
	if prompt:GetAttribute("RPId") == "Reposicion" then
		permitido = puedeReponer()
	end
	pcall(function()
		prompt.Enabled = permitido
	end)
end

local function revisarCarpeta(carpeta)
	for _, d in ipairs(carpeta:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			aplicarPrompt(d)
		end
	end
end

local function vigilarCarpeta(carpeta)
	if typeof(carpeta) ~= "Instance" or carpetasVigiladas[carpeta] then
		return
	end
	carpetasVigiladas[carpeta] = true
	maidPrompts:GiveTask(carpeta.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then
			task.defer(aplicarPrompt, d)
		end
	end))
	maidPrompts:GiveTask(carpeta.AncestryChanged:Connect(function(_, padre)
		if padre == nil then
			carpetasVigiladas[carpeta] = nil
		end
	end))
	revisarCarpeta(carpeta)
end

local function buscarCarpetas()
	local mapa = workspace:FindFirstChild(CARPETA_MAPA)
	if mapa then
		local cocina = mapa:FindFirstChild("Cocina")
		if cocina then
			vigilarCarpeta(cocina)
		end
		if not carpetasVigiladas[mapa] then
			carpetasVigiladas[mapa] = true
			maidPrompts:GiveTask(mapa.ChildAdded:Connect(function(hijo)
				if hijo.Name == "Cocina" then
					task.defer(vigilarCarpeta, hijo)
				end
			end))
			maidPrompts:GiveTask(mapa.AncestryChanged:Connect(function(_, padre)
				if padre == nil then
					carpetasVigiladas[mapa] = nil
				end
			end))
		end
	end
	local propia = workspace:FindFirstChild(CARPETA_PROPIA)
	if propia then
		vigilarCarpeta(propia)
	end
end

local function revisarPrompts()
	for carpeta in pairs(carpetasVigiladas) do
		if carpeta.Parent ~= nil and carpeta.Name ~= CARPETA_MAPA then
			revisarCarpeta(carpeta)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Construcción del panel
---------------------------------------------------------------------------------------------------
local function texto(parent, contenido, orden, props)
	props = props or {}
	props.LayoutOrder = orden
	return UIBuilder.Texto(parent, contenido, props)
end

local function botonAncho(parent, contenido, onClick, orden, estilo, nombre)
	local alto = UIBuilder.AltoBoton()
	local boton = UIBuilder.Boton(parent, contenido, onClick, {
		Estilo = estilo or "Secundario", Alto = alto, LayoutOrder = orden, Nombre = nombre,
		Size = UDim2.new(1, 0, 0, alto),
	})
	return boton
end

local pedir -- declarada más abajo

local function construirUI()
	local gui = UIBuilder.Pantalla("Comedor", ORDEN_PANTALLA)
	ui.Gui = gui
	local contenedor = UIBuilder.Contenedor(gui)
	ui.Contenedor = contenedor
	local panel, lista = UIBuilder.Panel(contenedor, {
		Nombre = "PanelComedor",
		Titulo = "Comedor escolar",
		AlCerrar = function()
			FoodController.Cerrar(true)
		end,
		Scroll = true,
		Espaciado = 6,
		Size = UDim2.new(0, ANCHO_PANEL, 0, ALTO_ESTADO),
		Position = UDim2.new(1, 0, 0, MARGEN_BOTONES_HUD),
		AnchorPoint = Vector2.new(1, 0),
	})
	pcall(function()
		panel.SelectionGroup = true
	end)
	panel.Visible = false
	ui.Panel = panel
	ui.Lista = lista

	ui.Estado = texto(lista, "Cargando el estado del comedor…", 1, { Rico = true, Fuente = "Subtitulo" })
	ui.Raciones = texto(lista, "", 2)
	ui.BarraRaciones = UIBuilder.Barra(lista, 0, { LayoutOrder = 3, Alto = 8, Color = Colores.Verde, Nombre = "BarraRaciones" })
	ui.Lotes = texto(lista, "", 4, { Tamano = "Pequeno", Color = Colores.TextoSecundario })
	ui.Menu = texto(lista, "", 5, { Color = Colores.TextoSecundario })
	ui.Turno = texto(lista, "", 6, { Rico = true, Fuente = "Subtitulo" })
	-- Reclamo desde el panel (solo junto a la ventana de servicio; el servidor vuelve a validarlo todo).
	ui.BotonReclamar = botonAncho(lista, "Reclamar almuerzo", function()
		pedir("Reclamar", nil)
	end, 7, "Exito", "Reclamar")
	ui.Ayuda = texto(lista, "El almuerzo es gratis: acércate a la ventana de servicio de la cocina y usa «Reclamar almuerzo».", 8, {
		Tamano = "Pequeno", Color = Colores.TextoApagado,
	})

	-- Sección de cocina (solo personal con cocina.operar / comedor.reponer).
	local cocina = UIBuilder.Marco(lista, { Nombre = "Cocina", AutoAlto = true, LayoutOrder = 9 })
	UIBuilder.Disposicion(cocina, { Espaciado = 6 })
	ui.Cocina = cocina
	UIBuilder.Separador(cocina, { LayoutOrder = 1 })
	UIBuilder.Subtitulo(cocina, "Cocina", { LayoutOrder = 2, Color = Colores.TextoPrincipal })
	ui.Receta = texto(cocina, "", 3)
	ui.Pasos = texto(cocina, "", 4, { Rico = true })
	ui.PasoTexto = texto(cocina, "", 5, { Tamano = "Pequeno", Color = Colores.Amarillo })
	ui.BarraPaso = UIBuilder.Barra(cocina, 0, { LayoutOrder = 6, Alto = 10, Color = Colores.Amarillo, Nombre = "BarraPaso" })

	ui.BotonesReceta = {}
	local orden = 10
	for _, receta in ipairs(Catalogs.Recetas or {}) do
		local id = receta.Id
		local boton = botonAncho(cocina, "Preparar: " .. tostring(receta.Nombre), function()
			pedir("IniciarReceta", { RecetaId = id })
		end, orden, "Primario", "Receta_" .. tostring(id))
		table.insert(ui.BotonesReceta, boton)
		orden = orden + 1
	end
	ui.BotonPaso = botonAncho(cocina, "Hacer paso", function()
		local esperado = estado and estado.PasoEsperado
		pedir("Paso", { Estacion = esperado })
	end, 30, "Primario", "HacerPaso")
	ui.BotonEntregar = botonAncho(cocina, "Entregar en el mostrador", function()
		pedir("Entregar", nil)
	end, 31, "Exito", "Entregar")
	ui.BotonReponer = botonAncho(cocina, "Reponer lote (congeladores)", function()
		pedir("Reponer", nil)
	end, 32, "Secundario", "Reponer")
	ui.AyudaCocina = texto(cocina, "Acércate a la estación indicada (máx. 12 studs) y pulsa el botón o usa el aviso de la estación. Cada paso tarda unos segundos: no te alejes.", 40, {
		Tamano = "Pequeno", Color = Colores.TextoApagado,
	})
end

local function asegurarUI()
	if not ui.Gui or ui.Gui.Parent == nil or not ui.Panel or ui.Panel.Parent == nil then
		construirUI()
	end
end

-- Tamaño y posición: a la derecha bajo los botones del HUD; centrado si la pantalla es estrecha o baja.
local function ajustarPanel()
	if not ui.Panel or ui.Panel.Parent == nil then
		return
	end
	local esp = UITheme.Espaciado
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local arriba = math.ceil(UIBuilder.InsetSuperior() / escala) + esp
	local abajo = math.ceil(UIBuilder.MargenInferiorTactil() / escala) + esp
	local disponible = UIBuilder.AltoUI() - arriba - abajo
	local ancho = math.floor(math.min(ANCHO_PANEL, UIBuilder.AnchoUI() - 2 * esp - 8))
	local deseado = ALTO_ESTADO
	if ui.Cocina and ui.Cocina.Visible then
		deseado = ALTO_COCINA
	end
	local bajoHUD = disponible - MARGEN_BOTONES_HUD
	if not UIBuilder.EsEstrecho() and bajoHUD >= math.min(deseado, 240) then
		ui.Panel.AnchorPoint = Vector2.new(1, 0)
		ui.Panel.Position = UDim2.new(1, 0, 0, MARGEN_BOTONES_HUD)
		ui.Panel.Size = UDim2.new(0, ancho, 0, math.floor(math.min(deseado, bajoHUD)))
	else
		ui.Panel.AnchorPoint = Vector2.new(0.5, 0.5)
		ui.Panel.Position = UDim2.new(0.5, 0, 0.5, 0)
		ui.Panel.Size = UDim2.new(0, ancho, 0, math.floor(math.max(160, math.min(deseado, disponible))))
	end
end

---------------------------------------------------------------------------------------------------
-- Refresco
---------------------------------------------------------------------------------------------------
local function restanteReclamo()
	local proximo = tonumber(personal.ProximoReclamo) or 0
	if proximo <= 0 then
		return 0
	end
	return math.max(0, proximo - ahoraServidor())
end

local function textoTurno()
	if not estado then
		return ""
	end
	if not estado.Abierto then
		return "<font color=\"" .. HEX_APAGADO .. "\">Solo se sirve en el descanso y el almuerzo.</font>"
	end
	local restante = restanteReclamo()
	if restante > 0 then
		return "<font color=\"" .. HEX_AMARILLO .. "\">Próximo almuerzo en " .. Format.Tiempo(restante) .. "</font>"
	end
	if (tonumber(estado.RacionesDisponibles) or 0) <= 0 then
		return "<font color=\"" .. HEX_AMARILLO .. "\">Sin raciones por ahora: la cocina está preparando más.</font>"
	end
	return "<font color=\"" .. HEX_VERDE .. "\">¡Puedes reclamar tu almuerzo!</font>"
end

-- Botón de reclamo: visible en la fila de la ventana de servicio o en la cocina; activo si el servidor lo permitiría.
local function refrescarReclamo()
	if not ui.BotonReclamar then
		return
	end
	local visible = estado ~= nil and (zonaActual == "FILA" or zonaActual == ZONA_COCINA)
	ui.BotonReclamar.Visible = visible
	if visible then
		local raciones = tonumber(estado.RacionesDisponibles) or 0
		UIBuilder.Habilitar(ui.BotonReclamar, not pidiendo and estado.Abierto == true and restanteReclamo() <= 0 and raciones > 0)
	end
end

local function refrescarPaso()
	if not ui.PasoTexto then
		return
	end
	if pasoActual and tonumber(pasoActual.FinServidor) then
		local duracion = math.max(0.1, tonumber(pasoActual.Duracion) or 1)
		local restante = math.max(0, pasoActual.FinServidor - ahoraServidor())
		ui.PasoTexto.Text = "En curso: " .. tostring(pasoActual.NombreEstacion or nombreEstacion(pasoActual.Estacion)) .. " (" .. math.ceil(restante) .. " s)"
		ui.PasoTexto.Visible = true
		ui.BarraPaso.Frame.Visible = true
		ui.BarraPaso:Fijar(1 - restante / duracion, false)
	else
		ui.PasoTexto.Visible = false
		ui.BarraPaso.Frame.Visible = false
	end
end

local function textoPasos(receta)
	local lineas = {}
	local actual = tonumber(receta.PasoActual) or 1
	local incluyeEntrega = false
	for i, paso in ipairs(receta.Pasos or {}) do
		if paso == "Entrega" then
			incluyeEntrega = true
		end
		local icono = "○"
		local color = HEX_APAGADO
		if i < actual or receta.Lista then
			icono = "✔"
			color = HEX_VERDE
		elseif i == actual then
			icono = "▶"
			color = HEX_AMARILLO
		end
		table.insert(lineas, "<font color=\"" .. color .. "\">" .. icono .. "</font> " .. i .. ". " .. nombreEstacion(paso))
	end
	if not incluyeEntrega then
		local icono, color = "○", HEX_APAGADO
		if receta.Lista then
			icono, color = "▶", HEX_AMARILLO
		end
		table.insert(lineas, "<font color=\"" .. color .. "\">" .. icono .. "</font> " .. nombreEstacion("Entrega"))
	end
	return table.concat(lineas, "\n")
end

local function refrescarCocina()
	if not ui.Cocina then
		return
	end
	local visible = mostrarCocina()
	ui.Cocina.Visible = visible
	if not visible then
		return
	end
	local cocinero = esCocina()
	local receta = estado and estado.Receta
	local lotesRestantes = estado and tonumber(estado.LotesRestantes) or 0
	if not estado then
		ui.Receta.Text = "Esperando datos de la cocina…"
		ui.Pasos.Visible = false
	elseif typeof(receta) == "table" then
		local autor = ""
		if typeof(receta.Cocinero) == "string" and receta.Cocinero ~= "" then
			autor = " · " .. receta.Cocinero
		end
		ui.Receta.Text = "Receta: " .. tostring(receta.Nombre) .. autor .. " (" .. tostring(receta.Raciones or RACIONES_POR_LOTE) .. " raciones)"
		ui.Pasos.Text = textoPasos(receta)
		ui.Pasos.Visible = true
	else
		if lotesRestantes > 0 then
			ui.Receta.Text = "No hay receta en preparación. Quedan " .. Format.Plural(lotesRestantes, "lote", "lotes") .. " en esta jornada."
		else
			ui.Receta.Text = "La cocina ya preparó todos los lotes de esta jornada."
		end
		ui.Pasos.Visible = false
	end
	refrescarPaso()

	local hayReceta = typeof(receta) == "table"
	for _, boton in ipairs(ui.BotonesReceta) do
		boton.Visible = cocinero and estado ~= nil and not hayReceta
		UIBuilder.Habilitar(boton, not pidiendo and lotesRestantes > 0)
	end
	local esperado = estado and estado.PasoEsperado
	local listo = hayReceta and receta.Lista == true
	ui.BotonPaso.Visible = cocinero and hayReceta and not listo
	if ui.BotonPaso.Visible then
		UIBuilder.TextoBoton(ui.BotonPaso, "Hacer paso: " .. nombreEstacion(esperado))
		UIBuilder.Habilitar(ui.BotonPaso, not pidiendo and pasoActual == nil)
	end
	ui.BotonEntregar.Visible = cocinero and listo
	UIBuilder.Habilitar(ui.BotonEntregar, not pidiendo)
	ui.BotonReponer.Visible = puedeReponer() and estado ~= nil
	if ui.BotonReponer.Visible then
		local raciones = tonumber(estado.RacionesDisponibles) or 0
		local porLote = tonumber(estado.RacionesPorLote) or RACIONES_POR_LOTE
		UIBuilder.Habilitar(ui.BotonReponer, not pidiendo and lotesRestantes > 0 and raciones < porLote)
	end
end

local function refrescar()
	if not ui.Panel or ui.Panel.Parent == nil then
		return
	end
	if not estado then
		ui.Estado.Text = "Cargando el estado del comedor…"
		ui.Raciones.Text = ""
		ui.Lotes.Text = ""
		ui.Menu.Text = ""
		ui.Turno.Text = ""
		ui.BarraRaciones:Fijar(0, false)
	else
		local periodo = tostring(estado.Periodo or "")
		if estado.Abierto then
			ui.Estado.Text = "<font color=\"" .. HEX_VERDE .. "\">●</font> Abierto · " .. periodo
		else
			ui.Estado.Text = "<font color=\"" .. HEX_ROJO .. "\">●</font> Cerrado · " .. periodo
		end
		local raciones = math.max(0, math.floor(tonumber(estado.RacionesDisponibles) or 0))
		local porLote = math.max(1, tonumber(estado.RacionesPorLote) or RACIONES_POR_LOTE)
		ui.Raciones.Text = "Raciones disponibles: " .. raciones
		ui.BarraRaciones:Fijar(math.min(1, raciones / porLote), true)
		local lotes = "Lotes de la jornada: " .. tostring(estado.LoteActual or 0) .. " de " .. tostring(estado.LotesPorJornada or 0)
		if estado.ModoNPC then
			lotes = lotes .. " · servicio automático"
		end
		ui.Lotes.Text = lotes
		if typeof(estado.Menu) == "string" and estado.Menu ~= "" then
			ui.Menu.Text = "Menú: " .. estado.Menu
		else
			ui.Menu.Text = "Menú: aún sin preparar"
		end
		ui.Turno.Text = textoTurno()
	end
	refrescarReclamo()
	refrescarCocina()
	ajustarPanel()
end

---------------------------------------------------------------------------------------------------
-- Datos del servidor
---------------------------------------------------------------------------------------------------
local function aplicarPaso(receta)
	if typeof(receta) == "table" and typeof(receta.PasoEnCurso) == "table" then
		pasoActual = {
			Estacion = receta.PasoEnCurso.Estacion,
			NombreEstacion = receta.PasoEnCurso.NombreEstacion,
			FinServidor = tonumber(receta.PasoEnCurso.FinServidor),
			Duracion = tonumber(receta.PasoEnCurso.Duracion),
		}
	else
		pasoActual = nil
	end
end

-- Respuesta de FoodAction: Estado + Personal.
local function aplicarDatos(datos)
	if typeof(datos) ~= "table" then
		return
	end
	if datos.RacionesDisponibles ~= nil then
		estado = datos
		aplicarPaso(datos.Receta)
	end
	if typeof(datos.Personal) == "table" then
		personal.ProximoReclamo = tonumber(datos.Personal.ProximoReclamo) or 0
	end
end

local function consultarEstado(forzar)
	if not activo then
		return
	end
	if not forzar and os.clock() - ultimaConsulta < CONSULTA_MIN_SEG then
		return
	end
	ultimaConsulta = os.clock()
	task.spawn(function()
		local ok, respuesta = Net.Invocar("FoodAction", { Accion = "Estado" })
		if ok and typeof(respuesta.datos) == "table" then
			aplicarDatos(respuesta.datos)
			refrescar()
		end
	end)
end

pedir = function(accion, extra)
	if pidiendo or not activo then
		return
	end
	pidiendo = true
	refrescarReclamo()
	refrescarCocina()
	task.spawn(function()
		local datos = { Accion = accion }
		for clave, valor in pairs(extra or {}) do
			datos[clave] = valor
		end
		local ok, respuesta = Net.Invocar("FoodAction", datos)
		pidiendo = false
		if typeof(respuesta) == "table" and typeof(respuesta.datos) == "table" then
			aplicarDatos(respuesta.datos)
		end
		if not ok then
			notificar(UIBuilder.MensajeError(respuesta and respuesta.error), "aviso", 5)
		end
		refrescar()
	end)
end

local function alEvento(datos)
	local sub = datos.Sub
	if sub == "Estado" then
		estado = datos
		aplicarPaso(datos.Receta)
	elseif sub == "Paso" then
		if datos.Fase == "Inicio" then
			pasoActual = {
				Estacion = datos.Estacion,
				NombreEstacion = datos.NombreEstacion,
				FinServidor = tonumber(datos.FinServidor),
				Duracion = tonumber(datos.Duracion),
			}
		else
			pasoActual = nil
			if datos.Fase == "Cancelado" and (esCocina() and zonaActual == ZONA_COCINA) then
				notificar(tostring(datos.Motivo or "El paso se canceló."), "aviso", 5)
			end
		end
	elseif sub == "Reclamado" then
		personal.ProximoReclamo = tonumber(datos.ProximoReclamo) or 0
		if estado and datos.RacionesDisponibles ~= nil then
			estado.RacionesDisponibles = datos.RacionesDisponibles
		end
	elseif sub == "Lote" then
		if estado then
			estado.RacionesDisponibles = datos.RacionesDisponibles or estado.RacionesDisponibles
			estado.LoteActual = datos.LoteActual or estado.LoteActual
			estado.Menu = datos.Menu or estado.Menu
		end
		if zonaActual then
			notificar("Nuevo lote en el comedor: +" .. tostring(datos.Raciones or 0) .. " raciones (" .. tostring(datos.Menu or "menú del día") .. ").", "info", 4)
		end
	elseif sub == "AbrirPanel" then
		forzarCocina = datos.Seccion == "Cocina"
		cerradoPorUsuario = false
		FoodController.Abrir(true)
		return
	end
	refrescar()
end

---------------------------------------------------------------------------------------------------
-- Zona
---------------------------------------------------------------------------------------------------
local function quitarAccionHUD()
	local HUD = obtenerControlador("HUDController")
	if HUD and typeof(HUD.AccionContextual) == "function" then
		pcall(HUD.AccionContextual, HUD, ACCION_HUD, nil)
	end
end

local function ponerAccionHUD()
	local HUD = obtenerControlador("HUDController")
	if HUD and typeof(HUD.AccionContextual) == "function" then
		local ok = pcall(HUD.AccionContextual, HUD, ACCION_HUD, function()
			cerradoPorUsuario = false
			FoodController.Alternar()
		end)
		return ok
	end
	return false
end

local function alCambiarZona(anterior, nueva)
	if nueva == nil then
		forzarCocina = false
		quitarAccionHUD()
		FoodController.Cerrar(false)
		cerradoPorUsuario = false
		return
	end
	if anterior == nil then
		local conBoton = ponerAccionHUD()
		consultarEstado(false)
		-- En pantallas amplias el estado se muestra solo; en estrechas, con el botón "Comedor" del HUD.
		if not cerradoPorUsuario and (not UIBuilder.EsEstrecho() or not conBoton) then
			FoodController.Abrir(false)
		end
	end
	if nueva ~= ZONA_COCINA then
		forzarCocina = false
	end
	refrescar()
end

---------------------------------------------------------------------------------------------------
-- API pública (admite llamada con punto o con dos puntos)
---------------------------------------------------------------------------------------------------
function FoodController.EstaAbierto()
	return abierto
end

-- Abre el panel. enfocar = true pone el foco de mando en el panel (apertura explícita).
function FoodController.Abrir(a, b)
	if not activo then
		return
	end
	local enfocar = a
	if a == FoodController then
		enfocar = b
	end
	local ok, err = pcall(asegurarUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
		return
	end
	consultarEstado(false)
	refrescar()
	if abierto then
		if enfocar then
			UIBuilder.EnfocarPrimero(ui.Panel)
		end
		return
	end
	abierto = true
	ui.Gui.Enabled = true
	UIBuilder.Aparecer(ui.Panel)
	local conexion = UIBuilder.TeclaCerrar(function()
		FoodController.Cerrar(true)
	end)
	if conexion then
		maidPanel:GiveTask(conexion)
	end
	if enfocar then
		task.defer(function()
			if abierto and ui.Panel and ui.Panel.Parent ~= nil then
				UIBuilder.EnfocarPrimero(ui.Panel)
			end
		end)
	end
end

-- Cierra el panel. porUsuario = true evita que se vuelva a abrir solo hasta salir de la zona.
function FoodController.Cerrar(a, b)
	local porUsuario = a
	if a == FoodController then
		porUsuario = b
	end
	if porUsuario == true then
		cerradoPorUsuario = true
	end
	if not abierto then
		return
	end
	abierto = false
	maidPanel:DoCleaning()
	if ui.Panel and ui.Panel.Parent ~= nil then
		UIBuilder.Desenfocar(ui.Panel)
		UIBuilder.Desaparecer(ui.Panel)
	end
end

function FoodController.Alternar()
	if abierto then
		FoodController.Cerrar(true)
	else
		FoodController.Abrir(true)
	end
end

-- Último estado del comedor recibido del servidor (o nil).
function FoodController.Estado()
	return estado
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function FoodController:Init(registro)
	self.registro = registro
end

function FoodController:Start()
	if activo then
		return
	end
	activo = true
	local ok, err = pcall(construirUI)
	if not ok then
		warn(LOG .. "No se pudo construir el panel: " .. tostring(err))
	end

	-- Canal servidor -> cliente.
	task.spawn(function()
		local remoto = Net.Evento("EventoCliente")
		if not remoto then
			warn(LOG .. "EventoCliente no disponible; el panel del comedor no recibirá actualizaciones.")
			return
		end
		maid:GiveTask(remoto.OnClientEvent:Connect(function(carga)
			if typeof(carga) ~= "table" or carga.Tipo ~= "Comida" then
				return
			end
			local datos = carga.Datos
			if typeof(datos) ~= "table" then
				return
			end
			local exito, errEvento = pcall(alEvento, datos)
			if not exito then
				warn(LOG .. tostring(errEvento))
			end
		end))
	end)

	-- Cargo: visibilidad de prompts y de la sección de cocina.
	maid:GiveTask(LocalPlayer:GetAttributeChangedSignal("Cargo"):Connect(function()
		revisarPrompts()
		refrescar()
	end))
	maid:GiveTask(workspace.ChildAdded:Connect(function(hijo)
		if hijo.Name == CARPETA_MAPA or hijo.Name == CARPETA_PROPIA then
			task.defer(buscarCarpetas)
		end
	end))
	task.spawn(function()
		local mapa = workspace:FindFirstChild(CARPETA_MAPA) or workspace:WaitForChild(CARPETA_MAPA, TIMEOUT)
		if mapa then
			buscarCarpetas()
		end
	end)

	-- Cambio de tamaño de pantalla.
	local function vigilarCamara()
		local camara = workspace.CurrentCamera
		if camara then
			maid:GiveTask(camara:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if abierto then
					ajustarPanel()
				end
			end))
		end
	end
	pcall(vigilarCamara)

	-- Detección de zona (1 Hz).
	maid:GiveTask(task.spawn(function()
		while activo do
			local exito, zona = pcall(detectarZona)
			if exito and zona ~= zonaActual then
				local anterior = zonaActual
				zonaActual = zona
				local okZona, errZona = pcall(alCambiarZona, anterior, zona)
				if not okZona then
					warn(LOG .. tostring(errZona))
				end
			end
			task.wait(INTERVALO_ZONA)
		end
	end))

	-- Cuenta atrás del reclamo y progreso del paso (solo con el panel abierto).
	maid:GiveTask(task.spawn(function()
		local acumulado = 0
		while activo do
			task.wait(INTERVALO_UI)
			if abierto and ui.Panel and ui.Panel.Parent ~= nil then
				refrescarPaso()
				acumulado = acumulado + INTERVALO_UI
				if acumulado >= 1 then
					acumulado = 0
					if ui.Turno then
						ui.Turno.Text = textoTurno()
					end
					-- El cooldown vence en el cliente: el botón de reclamo vuelve a activarse sin esperar al servidor.
					refrescarReclamo()
					if pasoActual and tonumber(pasoActual.FinServidor) and ahoraServidor() > pasoActual.FinServidor + 3 then
						-- El paso debió terminar y no llegó la confirmación: se pide el estado.
						pasoActual = nil
						consultarEstado(true)
					end
				end
			end
		end
	end))
end

return FoodController
