--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.UI.UIBuilder
	Tipo: ModuleScript
	Constructor de widgets de interfaz con el tema UITheme: pantallas, paneles, títulos, textos, botones,
	entradas, listas, interruptores, selectores, modales, toasts, barras y logo. Garantiza tamaño táctil
	mínimo (44 px), UIScale por dispositivo y por ajuste de accesibilidad, foco de mando, sonido de clic
	opcional y animaciones que respetan MovimientoReducido (ajuste o atributo local del Player). Deja libres
	150 px inferiores en táctil (Contenedor) y ofrece cierre por Escape / botón B (TeclaCerrar).

	Convención de props: las claves Size / Position / AnchorPoint / LayoutOrder / ZIndex / Nombre se pasan tal
	cual a la instancia; el resto son semánticas en español (Estilo, Tamano, Color, Fuente, Alineacion, ...).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")

local RP = ReplicatedStorage:WaitForChild("ColegioRP")
local Shared = RP:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UITheme = require(Shared:WaitForChild("UITheme"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local UIBuilder = {}

-- Ajustes de accesibilidad que afectan a los widgets (los actualiza SettingsController con AplicarAjustes).
UIBuilder.Ajustes = { MovimientoReducido = false, EscalaTexto = 1 }
-- Píxeles inferiores que se dejan libres a ambos lados en pantallas táctiles (joystick y salto).
UIBuilder.MargenTactilPx = 150
-- Prefijo de todas las ScreenGui del sistema.
UIBuilder.Prefijo = (Config.Nombres and Config.Nombres.PrefijoPantallas) or "ColegioRP_"
-- Ancho de pantalla (px) por debajo del cual los paneles se apilan en vertical.
UIBuilder.AnchoEstrechoPx = 760

local Colores = UITheme.Colores
-- Registros fuertes (no débiles: el envoltorio Lua de una Instance puede recolectarse aunque siga viva);
-- se depuran quitando las entradas cuyo Parent es nil.
local escalasRegistradas = {}
local restriccionesTactiles = {}
local registradasTactiles = 0
local sonidos = {}
local pantallaModal = nil
local ultimaEscalaTotal = nil

---------------------------------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------------------------------
local function clamp(valor, minimo, maximo)
	return math.max(minimo, math.min(maximo, valor))
end

local function aplicarComunes(instancia, props)
	if props == nil then
		return
	end
	if props.Size ~= nil then
		instancia.Size = props.Size
	end
	if props.Position ~= nil then
		instancia.Position = props.Position
	end
	if props.AnchorPoint ~= nil then
		instancia.AnchorPoint = props.AnchorPoint
	end
	if props.LayoutOrder ~= nil then
		instancia.LayoutOrder = props.LayoutOrder
	end
	if props.ZIndex ~= nil then
		instancia.ZIndex = props.ZIndex
	end
	if props.Visible ~= nil then
		instancia.Visible = props.Visible == true
	end
	if props.Nombre ~= nil then
		instancia.Name = tostring(props.Nombre)
	end
end

-- Content string de un asset ("rbxassetid://<id>") o cadena vacía si el id no es válido.
function UIBuilder.Asset(id)
	local n = tonumber(id) or 0
	if n <= 0 then
		return ""
	end
	return "rbxassetid://" .. tostring(math.floor(n))
end

-- Tamaño del viewport en píxeles (respaldo 1280x720).
function UIBuilder.Viewport()
	local ok, tamano = pcall(function()
		return workspace.CurrentCamera.ViewportSize
	end)
	if ok and typeof(tamano) == "Vector2" and tamano.X > 0 and tamano.Y > 0 then
		return tamano
	end
	return Vector2.new(1280, 720)
end

-- Alto (px) de la barra superior de Roblox que no debe taparse con IgnoreGuiInset = true.
function UIBuilder.InsetSuperior()
	local ok, arriba = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(arriba) == "Vector2" then
		return math.max(0, arriba.Y)
	end
	return 36
end

function UIBuilder.EsTactil()
	return UITheme.EsTactil()
end

function UIBuilder.EsMando()
	return UITheme.EsMando()
end

function UIBuilder.Dispositivo()
	return UITheme.Dispositivo()
end

-- ¿Hay un mando conectado (aunque también haya teclado)?
function UIBuilder.TieneMando()
	local ok, valor = pcall(function()
		return UserInputService.GamepadEnabled
	end)
	return ok and valor == true
end

-- Margen inferior (px) que se deja libre para los controles táctiles.
function UIBuilder.MargenInferiorTactil()
	if UIBuilder.EsTactil() then
		return UIBuilder.MargenTactilPx
	end
	return 0
end

-- Escala total aplicada a las pantallas: dispositivo x ajuste de usuario.
function UIBuilder.EscalaTotal()
	local usuario = tonumber(UIBuilder.Ajustes.EscalaTexto) or 1
	return UITheme.Escala() * clamp(usuario, 0.7, 1.4)
end

-- Alto de botón en unidades de UI para que, tras la UIScale, mida al menos 44 px en táctil.
function UIBuilder.AltoBoton()
	local base = 40
	if UIBuilder.EsTactil() then
		base = UIBuilder.MinimoTactil()
	end
	return math.max(base, 36)
end

-- ¿La pantalla es estrecha (teléfono en horizontal, ventana pequeña)?
function UIBuilder.EsEstrecho()
	return UIBuilder.Viewport().X < UIBuilder.AnchoEstrechoPx
end

-- Ancho disponible en unidades de UI (píxeles divididos por la escala).
function UIBuilder.AnchoUI()
	return UIBuilder.Viewport().X / math.max(0.5, UIBuilder.EscalaTotal())
end

function UIBuilder.AltoUI()
	return UIBuilder.Viewport().Y / math.max(0.5, UIBuilder.EscalaTotal())
end

-- Movimiento reducido: ajuste local de UIBuilder o atributo local "MovimientoReducido" del Player
-- (lo fija SettingsController; también lo lee la pantalla de carga).
function UIBuilder.MovimientoReducido()
	if UIBuilder.Ajustes.MovimientoReducido == true then
		return true
	end
	local ok, valor = pcall(function()
		return LocalPlayer:GetAttribute("MovimientoReducido")
	end)
	return ok and valor == true
end

-- Lado mínimo (en unidades de UI, antes de la UIScale) para que un control táctil mida 44 px en pantalla.
function UIBuilder.MinimoTactil()
	return math.ceil(UITheme.TamanoMinimoTactil / math.max(0.5, UIBuilder.EscalaTotal()))
end

-- Aplica el tamaño táctil mínimo a un GuiObject (UISizeConstraint) si la entrada principal es táctil.
function UIBuilder.AsegurarTactil(obj)
	if typeof(obj) ~= "Instance" or not obj:IsA("GuiObject") or not UIBuilder.EsTactil() then
		return nil
	end
	local minimo = UIBuilder.MinimoTactil()
	local restriccion = obj:FindFirstChild("MinimoTactil")
	if not restriccion then
		restriccion = Instance.new("UISizeConstraint")
		restriccion.Name = "MinimoTactil"
		restriccion.Parent = obj
	end
	restriccion.MinSize = Vector2.new(minimo, minimo)
	if not restriccionesTactiles[restriccion] then
		restriccionesTactiles[restriccion] = true
		registradasTactiles = registradasTactiles + 1
		if registradasTactiles % 200 == 0 then
			for r in pairs(restriccionesTactiles) do
				if r.Parent == nil then
					restriccionesTactiles[r] = nil
				end
			end
		end
	end
	return restriccion
end

-- Destruye una instancia sin lanzar errores.
function UIBuilder.Destruir(instancia)
	if typeof(instancia) == "Instance" then
		pcall(function()
			instancia:Destroy()
		end)
	end
end

-- Traduce un error de remoto ("rechazado:<motivo>" u otro texto) a un mensaje legible en español.
local mensajesRechazo = {
	limite = "Demasiadas peticiones seguidas; espera un momento.",
	frecuencia = "Demasiadas peticiones seguidas; espera un momento.",
	ratelimit = "Demasiadas peticiones seguidas; espera un momento.",
	permiso = "No tienes permiso para esta acción.",
	permisos = "No tienes permiso para esta acción.",
	esquema = "Los datos enviados no son válidos.",
	datos = "Los datos enviados no son válidos.",
	tipo = "Los datos enviados no son válidos.",
	distancia = "Estás demasiado lejos.",
	bloqueado = "Esta acción está bloqueada temporalmente.",
	cooldown = "Espera un momento antes de repetir la acción.",
	desconocido = "El servidor rechazó la petición.",
}
function UIBuilder.MensajeError(err)
	if typeof(err) ~= "string" or err == "" then
		return "Ocurrió un error inesperado."
	end
	local motivo = string.match(err, "^rechazado:(.+)$")
	if motivo then
		local clave = string.lower(string.match(motivo, "^([%a_]+)") or motivo)
		return mensajesRechazo[clave] or ("Petición rechazada: " .. motivo)
	end
	if string.find(err, "remoto no disponible", 1, true) then
		return "El servidor todavía no está listo. Inténtalo en unos segundos."
	end
	if string.find(err, "error de red", 1, true) then
		return "Error de conexión con el servidor."
	end
	return err
end

---------------------------------------------------------------------------------------------------
-- Escala, ajustes y animación
---------------------------------------------------------------------------------------------------

-- Añade (o reutiliza) una UIScale en la instancia y la registra para actualizarla al cambiar la escala.
function UIBuilder.Escalar(gui, extra)
	if typeof(gui) ~= "Instance" then
		return nil
	end
	local escala = gui:FindFirstChildOfClass("UIScale")
	if not escala then
		escala = Instance.new("UIScale")
		escala.Name = "EscalaColegioRP"
		escala.Parent = gui
	end
	local factor = tonumber(extra) or escalasRegistradas[escala] or 1
	escalasRegistradas[escala] = factor
	escala.Scale = UIBuilder.EscalaTotal() * factor
	return escala
end

-- Recalcula todas las UIScale registradas (cambio de dispositivo o de ajuste de texto).
function UIBuilder.RefrescarEscalas()
	local total = UIBuilder.EscalaTotal()
	for escala, factor in pairs(escalasRegistradas) do
		if escala.Parent ~= nil then
			escala.Scale = total * factor
		else
			escalasRegistradas[escala] = nil
		end
	end
	-- Con otra escala cambia el lado mínimo en unidades de UI para seguir midiendo 44 px.
	local minimo = UIBuilder.MinimoTactil()
	local tactil = UIBuilder.EsTactil()
	for restriccion in pairs(restriccionesTactiles) do
		if restriccion.Parent == nil then
			restriccionesTactiles[restriccion] = nil
		elseif tactil then
			restriccion.MinSize = Vector2.new(minimo, minimo)
		end
	end
	ultimaEscalaTotal = total
end

-- ¿Es una ScreenGui del sistema ("ColegioRP_*") que admite escala? Se excluyen las marcadas con el atributo
-- SinEscala y las que gestionan su propia UIScale (p. ej. la pantalla de carga, con "EscalaCarga").
function UIBuilder.EsPantallaSistema(gui)
	if typeof(gui) ~= "Instance" or not gui:IsA("ScreenGui") then
		return false
	end
	if string.sub(gui.Name, 1, #UIBuilder.Prefijo) ~= UIBuilder.Prefijo or gui:GetAttribute("SinEscala") == true then
		return false
	end
	local propia = gui:FindFirstChildOfClass("UIScale")
	if propia and propia.Name ~= "EscalaColegioRP" then
		return false
	end
	return true
end

-- Aplica (o actualiza) la UIScale en todas las ScreenGui "ColegioRP_*" de PlayerGui. Devuelve cuántas.
function UIBuilder.EscalarPantallas()
	local n = 0
	for _, hijo in ipairs(PlayerGui:GetChildren()) do
		if UIBuilder.EsPantallaSistema(hijo) then
			UIBuilder.Escalar(hijo)
			n = n + 1
		end
	end
	return n
end

-- Fija la escala de texto del usuario (0.7 .. 1.4) y refresca las pantallas.
function UIBuilder.FijarEscalaUsuario(valor)
	UIBuilder.Ajustes.EscalaTexto = clamp(tonumber(valor) or 1, 0.7, 1.4)
	UIBuilder.RefrescarEscalas()
end

-- Aplica los ajustes de accesibilidad relevantes (MovimientoReducido, EscalaTexto).
function UIBuilder.AplicarAjustes(ajustes)
	if typeof(ajustes) ~= "table" then
		return
	end
	if ajustes.MovimientoReducido ~= nil then
		UIBuilder.Ajustes.MovimientoReducido = ajustes.MovimientoReducido == true
	end
	if ajustes.EscalaTexto ~= nil then
		UIBuilder.FijarEscalaUsuario(ajustes.EscalaTexto)
	end
end

local function soloTransparencias(props)
	for clave in pairs(props) do
		if not string.find(tostring(clave), "Transparency", 1, true) then
			return false
		end
	end
	return true
end

local function fijarDirecto(obj, props)
	for clave, valor in pairs(props) do
		pcall(function()
			obj[clave] = valor
		end)
	end
end

-- Anima propiedades con TweenService. 't' = "Rapida" | "Normal" | "Lenta" | segundos. Con MovimientoReducido
-- los cambios son instantáneos (salvo fundidos, que duran 0.12 s). Devuelve el Tween o nil.
function UIBuilder.Tween(obj, props, t, alTerminar)
	if typeof(obj) ~= "Instance" or typeof(props) ~= "table" then
		return nil
	end
	local info = nil
	if UIBuilder.MovimientoReducido() then
		if soloTransparencias(props) then
			info = TweenInfo.new(0.12, UITheme.Estilo, UITheme.Direccion)
		end
	elseif t ~= 0 then
		info = UITheme.TweenInfo(t or "Normal", false)
	end
	if info == nil then
		fijarDirecto(obj, props)
		if typeof(alTerminar) == "function" then
			task.defer(alTerminar)
		end
		return nil
	end
	local ok, tween = pcall(TweenService.Create, TweenService, obj, info, props)
	if not ok or tween == nil then
		fijarDirecto(obj, props)
		if typeof(alTerminar) == "function" then
			task.defer(alTerminar)
		end
		return nil
	end
	if typeof(alTerminar) == "function" then
		tween.Completed:Once(function()
			pcall(alTerminar)
		end)
	end
	tween:Play()
	return tween
end

local function escalaAnimacion(frame)
	local escala = frame:FindFirstChild("AnimColegioRP")
	if not escala then
		escala = Instance.new("UIScale")
		escala.Name = "AnimColegioRP"
		escala.Scale = 1
		escala.Parent = frame
	end
	return escala
end

-- Muestra un panel con una animación breve de escala (o directamente con MovimientoReducido).
function UIBuilder.Aparecer(frame)
	if typeof(frame) ~= "Instance" then
		return
	end
	frame.Visible = true
	if UIBuilder.MovimientoReducido() then
		return
	end
	local escala = escalaAnimacion(frame)
	escala.Scale = 0.94
	UIBuilder.Tween(escala, { Scale = 1 }, "Rapida")
end

-- Oculta (o destruye) un panel con una animación breve.
function UIBuilder.Desaparecer(frame, destruir)
	if typeof(frame) ~= "Instance" then
		return
	end
	local function final()
		if destruir then
			UIBuilder.Destruir(frame)
		elseif frame.Parent ~= nil then
			frame.Visible = false
		end
	end
	if UIBuilder.MovimientoReducido() then
		final()
		return
	end
	local escala = escalaAnimacion(frame)
	UIBuilder.Tween(escala, { Scale = 0.94 }, "Rapida", function()
		if frame.Parent ~= nil then
			escala.Scale = 1
		end
		final()
	end)
end

---------------------------------------------------------------------------------------------------
-- Sonidos de interfaz
---------------------------------------------------------------------------------------------------

-- Reproduce un sonido de Config.Sonidos (ClickUI, Notificacion, Timbre...) solo si su id es > 0.
function UIBuilder.Sonido(nombre, volumen)
	local id = tonumber(Config.Sonidos and Config.Sonidos[nombre]) or 0
	if id <= 0 then
		return false
	end
	local sonido = sonidos[nombre]
	if not sonido or sonido.Parent == nil then
		local ok, creado = pcall(function()
			local s = Instance.new("Sound")
			s.Name = "ColegioRP_" .. tostring(nombre)
			s.SoundId = UIBuilder.Asset(id)
			s.Volume = tonumber(volumen) or 0.5
			s.Parent = SoundService
			return s
		end)
		if not ok or creado == nil then
			return false
		end
		sonido = creado
		sonidos[nombre] = sonido
	end
	local okPlay = pcall(function()
		sonido:Play()
	end)
	return okPlay
end

-- Clic de la interfaz (si Config.Sonidos.ClickUI > 0).
function UIBuilder.Sonar()
	return UIBuilder.Sonido("ClickUI", 0.4)
end

---------------------------------------------------------------------------------------------------
-- Foco de mando
---------------------------------------------------------------------------------------------------

-- Pone el foco de mando en el objeto si hay mando conectado. Devuelve true si lo hizo.
function UIBuilder.Enfocar(obj)
	if typeof(obj) ~= "Instance" or obj.Parent == nil then
		return false
	end
	if not UIBuilder.TieneMando() then
		return false
	end
	local ok = pcall(function()
		GuiService.SelectedObject = obj
	end)
	return ok
end

-- Quita el foco si está dentro de la raíz indicada (o cualquiera si raiz es nil).
function UIBuilder.Desenfocar(raiz)
	pcall(function()
		local seleccion = GuiService.SelectedObject
		if seleccion == nil then
			return
		end
		if raiz == nil or seleccion == raiz or seleccion:IsDescendantOf(raiz) then
			GuiService.SelectedObject = nil
		end
	end)
end

-- Enlaza NextSelection entre una lista de controles (vertical por defecto).
function UIBuilder.Encadenar(lista, horizontal)
	if typeof(lista) ~= "table" then
		return
	end
	for i, control in ipairs(lista) do
		if typeof(control) == "Instance" then
			local anterior = lista[i - 1]
			local siguiente = lista[i + 1]
			pcall(function()
				if horizontal then
					control.NextSelectionLeft = anterior
					control.NextSelectionRight = siguiente
				else
					control.NextSelectionUp = anterior
					control.NextSelectionDown = siguiente
				end
			end)
		end
	end
end

-- Primer control seleccionable y visible dentro de una raíz (por LayoutOrder y luego por orden de árbol).
function UIBuilder.PrimerSeleccionable(raiz)
	if typeof(raiz) ~= "Instance" then
		return nil
	end
	local mejor = nil
	for _, descendiente in ipairs(raiz:GetDescendants()) do
		if descendiente:IsA("GuiObject") and descendiente.Selectable and descendiente.Visible then
			if descendiente:GetAttribute("Desactivado") ~= true then
				if mejor == nil or descendiente.LayoutOrder < mejor.LayoutOrder then
					mejor = descendiente
				end
			end
		end
	end
	return mejor
end

-- Enfoca el primer control seleccionable de la raíz (si hay mando).
function UIBuilder.EnfocarPrimero(raiz)
	local control = UIBuilder.PrimerSeleccionable(raiz)
	if control then
		return UIBuilder.Enfocar(control)
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Decoración básica
---------------------------------------------------------------------------------------------------

function UIBuilder.Esquinas(obj, radio)
	local esquina = Instance.new("UICorner")
	if typeof(radio) == "UDim" then
		esquina.CornerRadius = radio
	else
		esquina.CornerRadius = UDim.new(0, tonumber(radio) or UITheme.Radio)
	end
	esquina.Parent = obj
	return esquina
end

function UIBuilder.Borde(obj, color, grosor, transparencia)
	local borde = Instance.new("UIStroke")
	borde.Color = color or Colores.Borde
	borde.Thickness = tonumber(grosor) or UITheme.GrosorBorde
	borde.Transparency = tonumber(transparencia) or 0
	borde.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	borde.Parent = obj
	return borde
end

-- UIPadding: Relleno(obj, todos) o Relleno(obj, arriba, abajo, izquierda, derecha).
function UIBuilder.Relleno(obj, arriba, abajo, izquierda, derecha)
	local padding = Instance.new("UIPadding")
	arriba = tonumber(arriba) or UITheme.Espaciado
	abajo = tonumber(abajo) or arriba
	izquierda = tonumber(izquierda) or arriba
	derecha = tonumber(derecha) or izquierda
	padding.PaddingTop = UDim.new(0, arriba)
	padding.PaddingBottom = UDim.new(0, abajo)
	padding.PaddingLeft = UDim.new(0, izquierda)
	padding.PaddingRight = UDim.new(0, derecha)
	padding.Parent = obj
	return padding
end

-- UIListLayout vertical (u horizontal) con el espaciado del tema.
function UIBuilder.Disposicion(parent, props)
	props = props or {}
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, tonumber(props.Espaciado) or UITheme.Espaciado)
	if props.Horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = props.AlineacionVertical or Enum.VerticalAlignment.Center
		layout.HorizontalAlignment = props.Alineacion or Enum.HorizontalAlignment.Left
	else
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = props.Alineacion or Enum.HorizontalAlignment.Left
		layout.VerticalAlignment = props.AlineacionVertical or Enum.VerticalAlignment.Top
	end
	if props.Wraps then
		layout.Wraps = true
	end
	layout.Parent = parent
	return layout
end

-- Frame transparente auxiliar.
function UIBuilder.Marco(parent, props)
	props = props or {}
	local marco = Instance.new("Frame")
	marco.Name = "Marco"
	marco.BackgroundTransparency = 1
	if props.Color then
		marco.BackgroundColor3 = props.Color
		marco.BackgroundTransparency = tonumber(props.Transparencia) or 0
	end
	marco.BorderSizePixel = 0
	marco.Size = UDim2.new(1, 0, 0, tonumber(props.Alto) or 0)
	if props.AutoAlto then
		marco.AutomaticSize = Enum.AutomaticSize.Y
	end
	aplicarComunes(marco, props)
	marco.Parent = parent
	return marco
end

-- Fila horizontal (UIListLayout horizontal) de altura fija.
function UIBuilder.Fila(parent, props)
	props = props or {}
	local fila = UIBuilder.Marco(parent, {
		Alto = props.Alto or UIBuilder.AltoBoton(),
		Nombre = props.Nombre or "Fila",
		LayoutOrder = props.LayoutOrder,
		Size = props.Size,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
	})
	UIBuilder.Disposicion(fila, { Horizontal = true, Espaciado = props.Espaciado, Alineacion = props.Alineacion })
	return fila
end

-- Espacio vertical vacío.
function UIBuilder.Espacio(parent, alto, layoutOrder)
	local marco = UIBuilder.Marco(parent, { Alto = alto or UITheme.Espaciado, Nombre = "Espacio", LayoutOrder = layoutOrder })
	return marco
end

-- Línea separadora.
function UIBuilder.Separador(parent, props)
	props = props or {}
	local linea = Instance.new("Frame")
	linea.Name = "Separador"
	linea.BackgroundColor3 = props.Color or Colores.Borde
	linea.BorderSizePixel = 0
	linea.Size = UDim2.new(1, 0, 0, 1)
	aplicarComunes(linea, props)
	linea.Parent = parent
	return linea
end

-- Contenedor a pantalla completa que respeta la barra superior y los 150 px inferiores táctiles.
function UIBuilder.Contenedor(pantalla, props)
	props = props or {}
	local marco = Instance.new("Frame")
	marco.Name = props.Nombre or "Contenido"
	marco.BackgroundTransparency = 1
	marco.BorderSizePixel = 0
	marco.Size = UDim2.new(1, 0, 1, 0)
	local espacio = tonumber(props.Espaciado) or UITheme.Espaciado
	local escala = math.max(0.5, UIBuilder.EscalaTotal())
	local arriba = math.ceil(UIBuilder.InsetSuperior() / escala) + espacio
	local abajo = math.ceil(UIBuilder.MargenInferiorTactil() / escala) + espacio
	if props.SinInset then
		arriba = espacio
	end
	if props.SinMargenTactil then
		abajo = espacio
	end
	UIBuilder.Relleno(marco, arriba, abajo, espacio, espacio)
	marco.Parent = pantalla
	return marco
end

---------------------------------------------------------------------------------------------------
-- Pantallas y paneles
---------------------------------------------------------------------------------------------------

-- Crea (o reutiliza vaciando) la ScreenGui "ColegioRP_<nombre>" en PlayerGui con la configuración estándar.
-- Devuelve la ScreenGui y true si ya existía (duplicado evitado).
function UIBuilder.Pantalla(nombre, displayOrder, props)
	props = props or {}
	local nombreCompleto = tostring(nombre or "Pantalla")
	if string.sub(nombreCompleto, 1, #UIBuilder.Prefijo) ~= UIBuilder.Prefijo then
		nombreCompleto = UIBuilder.Prefijo .. nombreCompleto
	end
	local existente = PlayerGui:FindFirstChild(nombreCompleto)
	local gui
	if existente and existente:IsA("ScreenGui") then
		gui = existente
		gui:ClearAllChildren()
	else
		if existente then
			UIBuilder.Destruir(existente)
		end
		gui = Instance.new("ScreenGui")
		gui.Name = nombreCompleto
	end
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = tonumber(displayOrder) or UITheme.Capas.Panel
	gui.Enabled = props.Visible ~= false
	gui:SetAttribute("SinEscala", props.SinEscala == true)
	if props.SinEscala ~= true then
		UIBuilder.Escalar(gui)
	end
	gui.Parent = PlayerGui
	return gui, existente ~= nil
end

-- Panel con fondo, borde, cabecera opcional (Titulo, AlCerrar) y cuerpo. Devuelve panel, cuerpo.
-- props.Scroll = true -> el cuerpo es una Lista (ScrollingFrame). props.AutoAlto = true -> crece con el contenido.
function UIBuilder.Panel(parent, props)
	props = props or {}
	local panel = Instance.new("Frame")
	panel.Name = props.Nombre or "Panel"
	panel.BackgroundColor3 = props.Color or Colores.GrisPanel
	panel.BackgroundTransparency = tonumber(props.Transparencia) or UITheme.Transparencias.Panel
	panel.BorderSizePixel = 0
	panel.Size = props.Size or UDim2.new(0, UITheme.AnchoPanel, 0, 420)
	panel.Position = props.Position or UDim2.new(0.5, 0, 0.5, 0)
	panel.AnchorPoint = props.AnchorPoint or Vector2.new(0.5, 0.5)
	panel.ClipsDescendants = props.Recortar ~= false
	if props.LayoutOrder then
		panel.LayoutOrder = props.LayoutOrder
	end
	if props.ZIndex then
		panel.ZIndex = props.ZIndex
	end
	UIBuilder.Esquinas(panel, UITheme.Radio)
	UIBuilder.Borde(panel, props.ColorBorde or Colores.Borde)

	local alturaCabecera = 0
	if props.Titulo ~= nil then
		alturaCabecera = 48
		if UIBuilder.EsTactil() then
			alturaCabecera = math.max(48, UIBuilder.MinimoTactil() + 4)
		end
		local cabecera = Instance.new("Frame")
		cabecera.Name = "Cabecera"
		cabecera.BackgroundTransparency = 1
		cabecera.Size = UDim2.new(1, 0, 0, alturaCabecera)
		cabecera.Parent = panel
		local franja = Instance.new("Frame")
		franja.Name = "Franja"
		franja.BackgroundColor3 = Colores.Rojo
		franja.BorderSizePixel = 0
		franja.Size = UDim2.new(0, 4, 0, 22)
		franja.Position = UDim2.new(0, 12, 0.5, 0)
		franja.AnchorPoint = Vector2.new(0, 0.5)
		UIBuilder.Esquinas(franja, 2)
		franja.Parent = cabecera
		local titulo = Instance.new("TextLabel")
		titulo.Name = "Titulo"
		titulo.BackgroundTransparency = 1
		titulo.Font = UITheme.Fuente("Titulo")
		titulo.TextSize = UITheme.Tamanos.Subtitulo
		titulo.TextColor3 = Colores.TextoPrincipal
		titulo.TextXAlignment = Enum.TextXAlignment.Left
		titulo.TextYAlignment = Enum.TextYAlignment.Center
		titulo.TextTruncate = Enum.TextTruncate.AtEnd
		titulo.Text = tostring(props.Titulo)
		titulo.Position = UDim2.new(0, 24, 0, 0)
		titulo.Size = UDim2.new(1, -(props.AlCerrar and 76 or 36), 1, 0)
		titulo.Parent = cabecera
		if typeof(props.AlCerrar) == "function" then
			UIBuilder.Boton(cabecera, "✕", props.AlCerrar, {
				Estilo = "Fantasma", Ancho = 40, Alto = 36, Nombre = "Cerrar",
				Position = UDim2.new(1, -6, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
			})
		end
		UIBuilder.Separador(panel, { Position = UDim2.new(0, 0, 0, alturaCabecera - 1) })
	end

	local cuerpo = Instance.new("Frame")
	cuerpo.Name = "Cuerpo"
	cuerpo.BackgroundTransparency = 1
	cuerpo.BorderSizePixel = 0
	cuerpo.Position = UDim2.new(0, 0, 0, alturaCabecera)
	if props.AutoAlto then
		panel.AutomaticSize = Enum.AutomaticSize.Y
		panel.Size = UDim2.new(panel.Size.X.Scale, panel.Size.X.Offset, 0, alturaCabecera)
		cuerpo.Size = UDim2.new(1, 0, 0, 0)
		cuerpo.AutomaticSize = Enum.AutomaticSize.Y
		UIBuilder.Disposicion(cuerpo, { Espaciado = props.Espaciado })
	else
		cuerpo.Size = UDim2.new(1, 0, 1, -alturaCabecera)
	end
	if not props.SinPadding then
		UIBuilder.Relleno(cuerpo, UITheme.Espaciado + 4, UITheme.Espaciado + 4, UITheme.Espaciado + 6, UITheme.Espaciado + 6)
	end
	cuerpo.Parent = panel
	panel.Parent = parent

	if props.Scroll then
		local lista = UIBuilder.Lista(cuerpo, { Espaciado = props.Espaciado })
		return panel, lista
	end
	return panel, cuerpo
end

---------------------------------------------------------------------------------------------------
-- Textos
---------------------------------------------------------------------------------------------------

-- TextLabel con ajuste de línea y alto automático por defecto.
-- props: Tamano (nombre de UITheme.Tamanos o número), Color, Fuente, Alineacion, AlineacionY, Rico,
-- Ajustar (TextWrapped), AutoAlto (false = tamaño fijo), Truncar, Transparencia, Escalado (TextScaled).
function UIBuilder.Texto(parent, texto, props)
	props = props or {}
	local label = Instance.new("TextLabel")
	label.Name = "Texto"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = UITheme.Fuente(props.Fuente or "Texto")
	label.TextSize = UITheme.Tamanos[props.Tamano] or tonumber(props.Tamano) or UITheme.Tamanos.Texto
	label.TextColor3 = props.Color or Colores.TextoPrincipal
	label.TextXAlignment = props.Alineacion or Enum.TextXAlignment.Left
	label.TextYAlignment = props.AlineacionY or Enum.TextYAlignment.Top
	label.TextWrapped = props.Ajustar ~= false
	label.RichText = props.Rico == true
	label.TextScaled = props.Escalado == true
	label.TextTransparency = tonumber(props.Transparencia) or 0
	label.Text = tostring(texto == nil and "" or texto)
	if props.Truncar then
		label.TextTruncate = Enum.TextTruncate.AtEnd
	end
	label.Size = UDim2.new(1, 0, 0, 0)
	if props.AutoAlto ~= false and props.Size == nil then
		label.AutomaticSize = Enum.AutomaticSize.Y
	elseif props.AutoAlto == true then
		label.AutomaticSize = Enum.AutomaticSize.Y
	end
	aplicarComunes(label, props)
	label.Parent = parent
	return label
end

-- Título de sección.
function UIBuilder.Titulo(parent, texto, props)
	props = props or {}
	local copia = {}
	for clave, valor in pairs(props) do
		copia[clave] = valor
	end
	copia.Fuente = props.Fuente or "Titulo"
	copia.Tamano = props.Tamano or "Titulo"
	copia.Nombre = props.Nombre or "Titulo"
	return UIBuilder.Texto(parent, texto, copia)
end

-- Subtítulo (texto secundario de sección).
function UIBuilder.Subtitulo(parent, texto, props)
	props = props or {}
	local copia = {}
	for clave, valor in pairs(props) do
		copia[clave] = valor
	end
	copia.Fuente = props.Fuente or "Subtitulo"
	copia.Tamano = props.Tamano or "Subtitulo"
	copia.Color = props.Color or Colores.TextoSecundario
	copia.Nombre = props.Nombre or "Subtitulo"
	return UIBuilder.Texto(parent, texto, copia)
end

-- Etiqueta tipo "pastilla" (fondo de color y texto corto). Devuelve el marco.
function UIBuilder.Etiqueta(parent, texto, color, props)
	props = props or {}
	local marco = Instance.new("Frame")
	marco.Name = props.Nombre or "Etiqueta"
	marco.BackgroundColor3 = color or Colores.Gris
	marco.BorderSizePixel = 0
	marco.AutomaticSize = Enum.AutomaticSize.X
	marco.Size = UDim2.new(0, 0, 0, tonumber(props.Alto) or 22)
	UIBuilder.Esquinas(marco, UDim.new(0.5, 0))
	UIBuilder.Relleno(marco, 0, 0, 8, 8)
	local label = Instance.new("TextLabel")
	label.Name = "Texto"
	label.BackgroundTransparency = 1
	label.Font = UITheme.Fuente("Boton")
	label.TextSize = UITheme.Tamanos[props.Tamano] or tonumber(props.Tamano) or UITheme.Tamanos.Etiqueta
	label.TextColor3 = props.Color or UITheme.TextoSobre(marco.BackgroundColor3)
	label.Text = tostring(texto or "")
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.new(0, 0, 1, 0)
	label.Parent = marco
	aplicarComunes(marco, props)
	marco.Parent = parent
	return marco
end

---------------------------------------------------------------------------------------------------
-- Botones
---------------------------------------------------------------------------------------------------
local estilosBoton = {
	Primario = {
		Fondo = Colores.Rojo, Hover = UITheme.Aclarar(Colores.Rojo, 0.12), Pulsado = Colores.RojoOscuro,
		Texto = Colores.Blanco, Borde = Colores.RojoOscuro, Transparencia = 0,
	},
	Secundario = {
		Fondo = Colores.Gris, Hover = UITheme.Aclarar(Colores.Gris, 0.1), Pulsado = UITheme.Oscurecer(Colores.Gris, 0.25),
		Texto = Colores.TextoPrincipal, Borde = Colores.Borde, Transparencia = 0,
	},
	Peligro = {
		Fondo = UITheme.Oscurecer(Colores.Rojo, 0.4), Hover = UITheme.Oscurecer(Colores.Rojo, 0.25), Pulsado = UITheme.Oscurecer(Colores.Rojo, 0.55),
		Texto = Colores.Blanco, Borde = Colores.RojoOscuro, Transparencia = 0,
	},
	Exito = {
		Fondo = Colores.Verde, Hover = UITheme.Aclarar(Colores.Verde, 0.12), Pulsado = UITheme.Oscurecer(Colores.Verde, 0.25),
		Texto = Colores.Blanco, Borde = UITheme.Oscurecer(Colores.Verde, 0.3), Transparencia = 0,
	},
	Fantasma = {
		Fondo = Colores.Gris, Hover = UITheme.Aclarar(Colores.Gris, 0.1), Pulsado = UITheme.Oscurecer(Colores.Gris, 0.25),
		Texto = Colores.TextoSecundario, Borde = Colores.Borde, Transparencia = 0.6,
	},
}

local function estiloDe(boton)
	return estilosBoton[boton:GetAttribute("Estilo")] or estilosBoton.Secundario
end

local function pintarBoton(boton, estado)
	local estilo = estiloDe(boton)
	local borde = boton:FindFirstChildOfClass("UIStroke")
	if boton:GetAttribute("Desactivado") == true then
		boton.BackgroundColor3 = Colores.Desactivado
		boton.BackgroundTransparency = estilo.Transparencia
		boton.TextColor3 = Colores.TextoApagado
		if borde then
			borde.Color = Colores.Borde
		end
		return
	end
	boton.TextColor3 = estilo.Texto
	if estado == "Hover" then
		boton.BackgroundColor3 = estilo.Hover
		boton.BackgroundTransparency = math.max(0, estilo.Transparencia - 0.3)
	elseif estado == "Pulsado" then
		boton.BackgroundColor3 = estilo.Pulsado
		boton.BackgroundTransparency = 0
	else
		boton.BackgroundColor3 = estilo.Fondo
		boton.BackgroundTransparency = estilo.Transparencia
	end
	if borde then
		borde.Color = estilo.Borde
	end
end

-- Botón con hover, pulsado, foco de mando, sonido opcional y tamaño táctil mínimo.
-- props: Estilo ("Primario" | "Secundario" | "Peligro" | "Exito" | "Fantasma"), Ancho (px), Alto (px),
-- Size (UDim2, prioridad), Tamano (texto), Icono (prefijo), Desactivado, Selectable, Alineacion.
function UIBuilder.Boton(parent, texto, onClick, props)
	props = props or {}
	local boton = Instance.new("TextButton")
	boton.Name = "Boton"
	boton.AutoButtonColor = false
	boton.BorderSizePixel = 0
	boton.Font = UITheme.Fuente("Boton")
	boton.TextSize = UITheme.Tamanos[props.Tamano] or tonumber(props.Tamano) or UITheme.Tamanos.Boton
	boton.TextWrapped = false
	boton.TextTruncate = Enum.TextTruncate.AtEnd
	boton.TextXAlignment = props.Alineacion or Enum.TextXAlignment.Center
	boton.Text = (props.Icono and (tostring(props.Icono) .. "  ") or "") .. tostring(texto or "")
	local alto = tonumber(props.Alto) or UIBuilder.AltoBoton()
	local ancho = tonumber(props.Ancho) or 160
	local tactil = UIBuilder.EsTactil() and props.SinMinimoTactil ~= true
	if tactil then
		local minimo = UIBuilder.MinimoTactil()
		alto = math.max(alto, minimo)
		ancho = math.max(ancho, minimo)
	end
	boton.Size = UDim2.new(0, ancho, 0, alto)
	boton.Selectable = props.Selectable ~= false
	boton:SetAttribute("Estilo", estilosBoton[props.Estilo] and props.Estilo or "Secundario")
	boton:SetAttribute("Desactivado", props.Desactivado == true)
	UIBuilder.Esquinas(boton, UITheme.Radio)
	local borde = UIBuilder.Borde(boton, Colores.Borde)
	UIBuilder.Relleno(boton, 0, 0, 12, 12)
	pintarBoton(boton, "Normal")

	boton.MouseEnter:Connect(function()
		pintarBoton(boton, "Hover")
	end)
	boton.MouseLeave:Connect(function()
		pintarBoton(boton, "Normal")
	end)
	boton.MouseButton1Down:Connect(function()
		pintarBoton(boton, "Pulsado")
	end)
	boton.MouseButton1Up:Connect(function()
		pintarBoton(boton, "Hover")
	end)
	boton.SelectionGained:Connect(function()
		borde.Color = Colores.Amarillo
		borde.Thickness = 2
	end)
	boton.SelectionLost:Connect(function()
		borde.Thickness = UITheme.GrosorBorde
		pintarBoton(boton, "Normal")
	end)
	boton.Activated:Connect(function()
		if boton:GetAttribute("Desactivado") == true then
			return
		end
		UIBuilder.Sonar()
		if typeof(onClick) == "function" then
			local ok, err = pcall(onClick, boton)
			if not ok then
				warn("[ColegioRP][UIBuilder] Error en botón '" .. boton.Text .. "': " .. tostring(err))
			end
		end
	end)
	aplicarComunes(boton, props)
	if tactil then
		-- Garantiza 44 px aunque props.Size use un tamaño menor.
		UIBuilder.AsegurarTactil(boton)
	end
	boton.Parent = parent
	return boton
end

-- Activa o desactiva un botón creado con Boton (color apagado, sin foco de mando).
function UIBuilder.Habilitar(boton, habilitado)
	if typeof(boton) ~= "Instance" then
		return
	end
	boton:SetAttribute("Desactivado", habilitado == false)
	pcall(function()
		boton.Selectable = habilitado ~= false
	end)
	pintarBoton(boton, "Normal")
end

-- Cambia el texto de un botón conservando el icono inicial si lo tenía.
function UIBuilder.TextoBoton(boton, texto)
	if typeof(boton) == "Instance" then
		boton.Text = tostring(texto or "")
	end
end

---------------------------------------------------------------------------------------------------
-- Entradas de texto
---------------------------------------------------------------------------------------------------

-- TextBox con límite de caracteres (props.Max), multilínea (props.Multilinea), AlCambiar(texto),
-- AlEnviar(texto) al pulsar Enter y Texto inicial.
function UIBuilder.Entrada(parent, placeholder, props)
	props = props or {}
	local caja = Instance.new("TextBox")
	caja.Name = "Entrada"
	caja.BackgroundColor3 = Colores.Entrada
	caja.BorderSizePixel = 0
	caja.TextColor3 = Colores.TextoPrincipal
	caja.PlaceholderColor3 = Colores.TextoApagado
	caja.PlaceholderText = tostring(placeholder or "")
	caja.Font = UITheme.Fuente("Texto")
	caja.TextSize = UITheme.Tamanos[props.Tamano] or tonumber(props.Tamano) or UITheme.Tamanos.Texto
	caja.ClearTextOnFocus = false
	caja.Text = tostring(props.Texto or "")
	caja.MultiLine = props.Multilinea == true
	caja.TextWrapped = props.Multilinea == true
	caja.TextXAlignment = Enum.TextXAlignment.Left
	if props.Multilinea then
		caja.TextYAlignment = Enum.TextYAlignment.Top
	else
		caja.TextYAlignment = Enum.TextYAlignment.Center
	end
	caja.TextEditable = props.Editable ~= false
	local altoCaja = tonumber(props.Alto) or UIBuilder.AltoBoton()
	if UIBuilder.EsTactil() then
		altoCaja = math.max(altoCaja, UIBuilder.MinimoTactil())
	end
	caja.Size = UDim2.new(1, 0, 0, altoCaja)
	caja.Selectable = true
	UIBuilder.Esquinas(caja, UITheme.RadioPequeno)
	local borde = UIBuilder.Borde(caja, Colores.Borde)
	UIBuilder.Relleno(caja, 8, 8, 10, 10)

	if UIBuilder.EsTactil() then
		UIBuilder.AsegurarTactil(caja)
	end
	local max = tonumber(props.Max)
	local recortando = false
	caja:GetPropertyChangedSignal("Text"):Connect(function()
		if recortando then
			return
		end
		local actual = caja.Text
		if max then
			local longitud = utf8.len(actual)
			if longitud == nil then
				recortando = true
				caja.Text = ""
				recortando = false
				actual = ""
			elseif longitud > max then
				local corte = utf8.offset(actual, max + 1)
				if corte then
					recortando = true
					caja.Text = string.sub(actual, 1, corte - 1)
					recortando = false
					actual = caja.Text
				end
			end
		end
		if typeof(props.AlCambiar) == "function" then
			pcall(props.AlCambiar, actual)
		end
	end)
	caja.Focused:Connect(function()
		borde.Color = Colores.Amarillo
		borde.Thickness = 2
	end)
	caja.FocusLost:Connect(function(enterPulsado)
		borde.Color = Colores.Borde
		borde.Thickness = UITheme.GrosorBorde
		if enterPulsado and typeof(props.AlEnviar) == "function" then
			pcall(props.AlEnviar, caja.Text)
		end
	end)
	aplicarComunes(caja, props)
	caja.Parent = parent
	return caja
end

---------------------------------------------------------------------------------------------------
-- Listas
---------------------------------------------------------------------------------------------------

-- ScrollingFrame con UIListLayout y tamaño de lienzo automático. Devuelve scroll, layout.
function UIBuilder.Lista(parent, props)
	props = props or {}
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Lista"
	scroll.BackgroundTransparency = 1
	if props.Color then
		scroll.BackgroundColor3 = props.Color
		scroll.BackgroundTransparency = tonumber(props.Transparencia) or 0
	end
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, 0, 1, 0)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = Colores.Borde
	scroll.ClipsDescendants = true
	scroll.Selectable = false
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	if props.Horizontal then
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.X
		scroll.ScrollingDirection = Enum.ScrollingDirection.X
	else
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	end
	local layout = UIBuilder.Disposicion(scroll, { Horizontal = props.Horizontal, Espaciado = props.Espaciado, Alineacion = props.Alineacion })
	if props.Relleno ~= false then
		UIBuilder.Relleno(scroll, 2, 2, 2, props.Horizontal and 2 or 10)
	end
	aplicarComunes(scroll, props)
	scroll.Parent = parent
	return scroll, layout
end

---------------------------------------------------------------------------------------------------
-- Interruptor y selector
---------------------------------------------------------------------------------------------------

local function filaControl(parent, texto, props)
	props = props or {}
	local alto = UIBuilder.AltoBoton()
	local fila = Instance.new("Frame")
	fila.Name = props.Nombre or "Control"
	fila.BackgroundColor3 = Colores.Gris
	fila.BackgroundTransparency = 0.55
	fila.BorderSizePixel = 0
	fila.Size = UDim2.new(1, 0, 0, props.Descripcion and (alto + 20) or alto)
	if props.LayoutOrder then
		fila.LayoutOrder = props.LayoutOrder
	end
	UIBuilder.Esquinas(fila, UITheme.RadioPequeno)
	UIBuilder.Relleno(fila, 0, 0, 10, 8)
	if UIBuilder.EsTactil() then
		-- La fila entera es zona táctil: nunca menos de 44 px aunque baje la escala de texto.
		UIBuilder.AsegurarTactil(fila)
	end
	local anchoDerecha = tonumber(props.AnchoDerecha) or 80
	local etiqueta = Instance.new("TextLabel")
	etiqueta.Name = "Etiqueta"
	etiqueta.BackgroundTransparency = 1
	etiqueta.Font = UITheme.Fuente("Texto")
	etiqueta.TextSize = UITheme.Tamanos.Texto
	etiqueta.TextColor3 = Colores.TextoPrincipal
	etiqueta.TextXAlignment = Enum.TextXAlignment.Left
	etiqueta.TextYAlignment = Enum.TextYAlignment.Center
	etiqueta.TextTruncate = Enum.TextTruncate.AtEnd
	etiqueta.Text = tostring(texto or "")
	etiqueta.Size = UDim2.new(1, -anchoDerecha - 8, 0, alto)
	etiqueta.Parent = fila
	if props.Descripcion then
		local descripcion = Instance.new("TextLabel")
		descripcion.Name = "Descripcion"
		descripcion.BackgroundTransparency = 1
		descripcion.Font = UITheme.Fuente("Texto")
		descripcion.TextSize = UITheme.Tamanos.Pequeno
		descripcion.TextColor3 = Colores.TextoApagado
		descripcion.TextXAlignment = Enum.TextXAlignment.Left
		descripcion.TextYAlignment = Enum.TextYAlignment.Top
		descripcion.TextWrapped = true
		descripcion.Text = tostring(props.Descripcion)
		descripcion.Position = UDim2.new(0, 0, 0, alto - 6)
		descripcion.Size = UDim2.new(1, -anchoDerecha - 8, 0, 22)
		descripcion.Parent = fila
	end
	return fila, etiqueta, alto
end

-- Interruptor (toggle). onChange(valor). Devuelve control { Frame, Boton, Valor(), Fijar(valor, silencioso) }.
function UIBuilder.Interruptor(parent, texto, valor, onChange, props)
	props = props or {}
	local fila, _, alto = filaControl(parent, texto, props)
	local estado = valor == true
	local boton = Instance.new("TextButton")
	boton.Name = "Interruptor"
	boton.AutoButtonColor = false
	boton.BorderSizePixel = 0
	boton.Text = ""
	boton.Size = UDim2.new(0, 58, 0, 30)
	boton.Position = UDim2.new(1, 0, 0, alto / 2)
	boton.AnchorPoint = Vector2.new(1, 0.5)
	boton.BackgroundColor3 = estado and Colores.Verde or Colores.Desactivado
	boton.Selectable = true
	UIBuilder.Esquinas(boton, UDim.new(0.5, 0))
	local borde = UIBuilder.Borde(boton, Colores.Borde, 1, 1)
	local perilla = Instance.new("Frame")
	perilla.Name = "Perilla"
	perilla.BackgroundColor3 = Colores.Blanco
	perilla.BorderSizePixel = 0
	perilla.Size = UDim2.new(0, 24, 0, 24)
	perilla.AnchorPoint = Vector2.new(0, 0.5)
	perilla.Position = estado and UDim2.new(1, -27, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
	UIBuilder.Esquinas(perilla, UDim.new(0.5, 0))
	perilla.Parent = boton
	boton.Parent = fila

	local control = { Frame = fila, Boton = boton }
	local function pintar(animar)
		local velocidad = animar and "Rapida" or 0
		UIBuilder.Tween(boton, { BackgroundColor3 = estado and Colores.Verde or Colores.Desactivado }, velocidad)
		UIBuilder.Tween(perilla, { Position = estado and UDim2.new(1, -27, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, velocidad)
	end
	function control:Valor()
		return estado
	end
	function control:Fijar(nuevo, silencioso)
		nuevo = nuevo == true
		local cambio = nuevo ~= estado
		estado = nuevo
		pintar(true)
		if cambio and not silencioso and typeof(onChange) == "function" then
			local ok, err = pcall(onChange, estado)
			if not ok then
				warn("[ColegioRP][UIBuilder] Error en interruptor '" .. tostring(texto) .. "': " .. tostring(err))
			end
		end
	end
	boton.Activated:Connect(function()
		UIBuilder.Sonar()
		control:Fijar(not estado)
	end)
	boton.SelectionGained:Connect(function()
		borde.Color = Colores.Amarillo
		borde.Transparency = 0
		borde.Thickness = 2
	end)
	boton.SelectionLost:Connect(function()
		borde.Transparency = 1
		borde.Thickness = 1
	end)
	-- Toda la fila responde al toque (zona táctil amplia).
	local zona = Instance.new("TextButton")
	zona.Name = "Zona"
	zona.BackgroundTransparency = 1
	zona.Text = ""
	zona.Selectable = false
	zona.Size = UDim2.new(1, -70, 1, 0)
	if UIBuilder.EsTactil() then
		-- En táctil toda la fila (alto >= 44 px) cambia el valor, incluido el propio interruptor.
		zona.Size = UDim2.new(1, 0, 1, 0)
	end
	zona.ZIndex = fila.ZIndex
	zona.Parent = fila
	zona.Activated:Connect(function()
		UIBuilder.Sonar()
		control:Fijar(not estado)
	end)
	return control
end

-- Selector cíclico "‹ valor ›". opciones = { valor, ... } o { { Valor = x, Texto = "..." }, ... }.
-- onChange(valor). Devuelve control { Frame, Valor(), Fijar(valor, silencioso), Indice(), Botones }.
function UIBuilder.Selector(parent, texto, opciones, valor, onChange, props)
	props = props or {}
	local anchoGrupo = tonumber(props.AnchoGrupo) or 212
	local copia = {}
	for clave, v in pairs(props) do
		copia[clave] = v
	end
	copia.AnchoDerecha = anchoGrupo
	local fila, _, alto = filaControl(parent, texto, copia)
	local lista = {}
	for _, opcion in ipairs(opciones or {}) do
		if typeof(opcion) == "table" then
			table.insert(lista, { Valor = opcion.Valor, Texto = tostring(opcion.Texto or opcion.Valor) })
		else
			table.insert(lista, { Valor = opcion, Texto = tostring(opcion) })
		end
	end
	if #lista == 0 then
		table.insert(lista, { Valor = nil, Texto = "—" })
	end
	local indice = 1
	for i, opcion in ipairs(lista) do
		if opcion.Valor == valor then
			indice = i
			break
		end
	end

	local grupo = Instance.new("Frame")
	grupo.Name = "Grupo"
	grupo.BackgroundTransparency = 1
	local altoGrupo = alto - 6
	if UIBuilder.EsTactil() then
		altoGrupo = alto
	end
	grupo.Size = UDim2.new(0, anchoGrupo, 0, altoGrupo)
	grupo.Position = UDim2.new(1, 0, 0, alto / 2)
	grupo.AnchorPoint = Vector2.new(1, 0.5)
	grupo.Parent = fila
	local anchoFlecha = 40
	if UIBuilder.EsTactil() then
		anchoFlecha = math.max(anchoFlecha, UIBuilder.MinimoTactil())
	end
	local etiquetaValor = Instance.new("TextLabel")
	etiquetaValor.Name = "Valor"
	etiquetaValor.BackgroundColor3 = Colores.Entrada
	etiquetaValor.BorderSizePixel = 0
	etiquetaValor.Font = UITheme.Fuente("Boton")
	etiquetaValor.TextSize = UITheme.Tamanos.Texto
	etiquetaValor.TextColor3 = Colores.TextoPrincipal
	etiquetaValor.TextTruncate = Enum.TextTruncate.AtEnd
	etiquetaValor.Text = lista[indice].Texto
	etiquetaValor.Position = UDim2.new(0, anchoFlecha + 4, 0, 0)
	etiquetaValor.Size = UDim2.new(1, -(anchoFlecha + 4) * 2, 1, 0)
	UIBuilder.Esquinas(etiquetaValor, UITheme.RadioPequeno)
	etiquetaValor.Parent = grupo

	local control = { Frame = fila, Etiqueta = etiquetaValor, Botones = {} }
	local function mostrar()
		etiquetaValor.Text = lista[indice].Texto
	end
	function control:Valor()
		return lista[indice].Valor
	end
	function control:Indice()
		return indice
	end
	function control:Fijar(nuevoValor, silencioso)
		local nuevoIndice = nil
		for i, opcion in ipairs(lista) do
			if opcion.Valor == nuevoValor then
				nuevoIndice = i
				break
			end
		end
		if nuevoIndice == nil then
			return
		end
		local cambio = nuevoIndice ~= indice
		indice = nuevoIndice
		mostrar()
		if cambio and not silencioso and typeof(onChange) == "function" then
			local ok, err = pcall(onChange, lista[indice].Valor)
			if not ok then
				warn("[ColegioRP][UIBuilder] Error en selector '" .. tostring(texto) .. "': " .. tostring(err))
			end
		end
	end
	local function mover(delta)
		local nuevo = indice + delta
		if nuevo < 1 then
			nuevo = #lista
		elseif nuevo > #lista then
			nuevo = 1
		end
		control:Fijar(lista[nuevo].Valor)
	end
	local izquierda = UIBuilder.Boton(grupo, "‹", function()
		mover(-1)
	end, { Estilo = "Secundario", Ancho = anchoFlecha, Alto = altoGrupo, Nombre = "Anterior", Tamano = "Subtitulo", Position = UDim2.new(0, 0, 0, 0) })
	local derecha = UIBuilder.Boton(grupo, "›", function()
		mover(1)
	end, { Estilo = "Secundario", Ancho = anchoFlecha, Alto = altoGrupo, Nombre = "Siguiente", Tamano = "Subtitulo", Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0) })
	izquierda.NextSelectionRight = derecha
	derecha.NextSelectionLeft = izquierda
	control.Botones = { izquierda, derecha }
	return control
end

---------------------------------------------------------------------------------------------------
-- Barra de progreso
---------------------------------------------------------------------------------------------------

-- Barra horizontal 0..1. Devuelve control { Frame, Relleno, Valor(), Fijar(valor, animar) }.
function UIBuilder.Barra(parent, progreso, props)
	props = props or {}
	local alto = tonumber(props.Alto) or 8
	local fondo = Instance.new("Frame")
	fondo.Name = props.Nombre or "Barra"
	fondo.BackgroundColor3 = props.ColorFondo or Colores.Gris
	fondo.BorderSizePixel = 0
	fondo.Size = props.Size or UDim2.new(1, 0, 0, alto)
	fondo.ClipsDescendants = true
	UIBuilder.Esquinas(fondo, UDim.new(0.5, 0))
	local relleno = Instance.new("Frame")
	relleno.Name = "Relleno"
	relleno.BackgroundColor3 = props.Color or Colores.Rojo
	relleno.BorderSizePixel = 0
	local inicial = clamp(tonumber(progreso) or 0, 0, 1)
	relleno.Size = UDim2.new(inicial, 0, 1, 0)
	UIBuilder.Esquinas(relleno, UDim.new(0.5, 0))
	relleno.Parent = fondo
	aplicarComunes(fondo, props)
	fondo.Parent = parent
	local control = { Frame = fondo, Relleno = relleno, _valor = inicial }
	function control:Fijar(valor, animar)
		valor = clamp(tonumber(valor) or 0, 0, 1)
		self._valor = valor
		if animar then
			UIBuilder.Tween(relleno, { Size = UDim2.new(valor, 0, 1, 0) }, "Rapida")
		else
			relleno.Size = UDim2.new(valor, 0, 1, 0)
		end
	end
	function control:Valor()
		return self._valor
	end
	return control
end

---------------------------------------------------------------------------------------------------
-- Logo del colegio
---------------------------------------------------------------------------------------------------

-- Logo cuadrado de 'tamano' px: imagen real si Config.LogoAssetId > 0; si no, logo vectorial de respaldo
-- (círculo rojo con "INSTITUTO EDUCATIVO" / "JEAN PIAGET" / lema). props.Texto = false -> solo "JP".
function UIBuilder.Logo(parent, tamano, props)
	props = props or {}
	tamano = math.max(16, tonumber(tamano) or 96)
	local marco = Instance.new("Frame")
	marco.Name = "Logo"
	marco.BackgroundTransparency = 1
	marco.BorderSizePixel = 0
	marco.Size = UDim2.new(0, tamano, 0, tamano)
	aplicarComunes(marco, props)

	local id = tonumber(Config.LogoAssetId) or 0
	if id > 0 then
		local imagen = Instance.new("ImageLabel")
		imagen.Name = "Imagen"
		imagen.BackgroundTransparency = 1
		imagen.Image = UIBuilder.Asset(id)
		imagen.ScaleType = Enum.ScaleType.Fit
		imagen.Size = UDim2.new(1, 0, 1, 0)
		imagen.Parent = marco
		marco.Parent = parent
		return marco
	end

	local circulo = Instance.new("Frame")
	circulo.Name = "Circulo"
	circulo.BackgroundColor3 = Colores.Rojo
	circulo.BorderSizePixel = 0
	circulo.Size = UDim2.new(1, 0, 1, 0)
	UIBuilder.Esquinas(circulo, UDim.new(0.5, 0))
	UIBuilder.Borde(circulo, Colores.Blanco, math.max(2, math.floor(tamano * 0.035)))
	circulo.Parent = marco

	local anillo = Instance.new("Frame")
	anillo.Name = "Anillo"
	anillo.BackgroundTransparency = 1
	anillo.Size = UDim2.new(0.86, 0, 0.86, 0)
	anillo.Position = UDim2.new(0.5, 0, 0.5, 0)
	anillo.AnchorPoint = Vector2.new(0.5, 0.5)
	UIBuilder.Esquinas(anillo, UDim.new(0.5, 0))
	UIBuilder.Borde(anillo, Colores.Blanco, math.max(1, math.floor(tamano * 0.012)), 0.35)
	anillo.Parent = circulo

	local function textoLogo(nombre, contenido, fuente, tamanoRel, posY, transparencia)
		local label = Instance.new("TextLabel")
		label.Name = nombre
		label.BackgroundTransparency = 1
		label.Font = UITheme.Fuente(fuente)
		label.TextScaled = true
		label.TextColor3 = Colores.Blanco
		label.TextTransparency = transparencia or 0
		label.Text = contenido
		label.Size = UDim2.new(tamanoRel.X, 0, tamanoRel.Y, 0)
		label.Position = UDim2.new(0.5, 0, posY, 0)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Parent = circulo
		return label
	end

	if tamano >= 56 and props.Texto ~= false then
		textoLogo("Instituto", "INSTITUTO EDUCATIVO", "Subtitulo", Vector2.new(0.72, 0.1), 0.3)
		textoLogo("Nombre", "JEAN PIAGET", "Titulo", Vector2.new(0.78, 0.2), 0.48)
		local linea = Instance.new("Frame")
		linea.Name = "Linea"
		linea.BackgroundColor3 = Colores.Blanco
		linea.BackgroundTransparency = 0.2
		linea.BorderSizePixel = 0
		linea.Size = UDim2.new(0.5, 0, 0, math.max(1, math.floor(tamano * 0.012)))
		linea.Position = UDim2.new(0.5, 0, 0.61, 0)
		linea.AnchorPoint = Vector2.new(0.5, 0.5)
		linea.Parent = circulo
		textoLogo("Lema", "EDUCACIÓN INTEGRAL · CAMINO A LA EXCELENCIA", "Texto", Vector2.new(0.74, 0.075), 0.7, 0.1)
	else
		textoLogo("Siglas", "JP", "Titulo", Vector2.new(0.7, 0.5), 0.5)
	end
	marco.Parent = parent
	return marco
end

---------------------------------------------------------------------------------------------------
-- Modales
---------------------------------------------------------------------------------------------------

local function pantallaModales()
	if pantallaModal and pantallaModal.Parent ~= nil then
		return pantallaModal
	end
	pantallaModal = UIBuilder.Pantalla("Modal", UITheme.Capas.Modal)
	return pantallaModal
end

-- Ventana modal. contenido = string | function(cuerpo) | Instance. botones = { { Texto, Accion(cerrar), Estilo, NoCerrar } }.
-- props: Ancho, CerrarAlFondo, Cerrable (false = sin ✕ ni botón B), AlCerrar. Devuelve { Frame, Panel, Cuerpo, Cerrar() }.
function UIBuilder.Modal(titulo, contenido, botones, props)
	props = props or {}
	local gui = pantallaModales()
	local fondo = Instance.new("TextButton")
	fondo.Name = "Modal"
	fondo.AutoButtonColor = false
	fondo.Text = ""
	fondo.BackgroundColor3 = Colores.Sombra
	fondo.BackgroundTransparency = 1
	fondo.BorderSizePixel = 0
	fondo.Size = UDim2.new(1, 0, 1, 0)
	fondo.Selectable = false
	fondo.ZIndex = 1 + #gui:GetChildren()
	fondo.Parent = gui

	local handle = { Frame = fondo, Cerrado = false }
	local conexiones = {}
	local seleccionAnterior = nil
	pcall(function()
		seleccionAnterior = GuiService.SelectedObject
	end)
	local function cerrar()
		if handle.Cerrado then
			return
		end
		handle.Cerrado = true
		for _, conexion in ipairs(conexiones) do
			pcall(function()
				conexion:Disconnect()
			end)
		end
		UIBuilder.Desenfocar(fondo)
		if seleccionAnterior and seleccionAnterior.Parent ~= nil and UIBuilder.TieneMando() then
			pcall(function()
				GuiService.SelectedObject = seleccionAnterior
			end)
		end
		UIBuilder.Tween(fondo, { BackgroundTransparency = 1 }, "Rapida")
		if handle.Panel then
			UIBuilder.Desaparecer(handle.Panel, true)
		end
		task.delay(UITheme.Animacion.Rapida + 0.05, function()
			UIBuilder.Destruir(fondo)
		end)
		if typeof(props.AlCerrar) == "function" then
			pcall(props.AlCerrar)
		end
	end
	handle.Cerrar = cerrar

	local ancho = math.min(tonumber(props.Ancho) or UITheme.AnchoPanel, math.max(240, UIBuilder.AnchoUI() - 32))
	local panel, cuerpo = UIBuilder.Panel(fondo, {
		Titulo = titulo or "",
		Nombre = "Ventana",
		Size = UDim2.new(0, ancho, 0, 0),
		AutoAlto = true,
		AlCerrar = (props.Cerrable ~= false) and cerrar or nil,
	})
	handle.Panel = panel
	handle.Cuerpo = cuerpo

	if typeof(contenido) == "string" then
		UIBuilder.Texto(cuerpo, contenido, { Color = Colores.TextoSecundario, LayoutOrder = 1 })
	elseif typeof(contenido) == "function" then
		local ok, err = pcall(contenido, cuerpo, handle)
		if not ok then
			warn("[ColegioRP][UIBuilder] Error construyendo un modal: " .. tostring(err))
		end
	elseif typeof(contenido) == "Instance" then
		contenido.Parent = cuerpo
	end

	local primerBoton = nil
	if typeof(botones) == "table" and #botones > 0 then
		UIBuilder.Espacio(cuerpo, 4, 98)
		local fila = UIBuilder.Fila(cuerpo, { LayoutOrder = 99, Alineacion = Enum.HorizontalAlignment.Right, Nombre = "Botones" })
		fila.Size = UDim2.new(1, 0, 0, UIBuilder.AltoBoton())
		local creados = {}
		for i, def in ipairs(botones) do
			local boton = UIBuilder.Boton(fila, def.Texto or "Aceptar", function()
				local mantener = false
				if typeof(def.Accion) == "function" then
					local ok, resultado = pcall(def.Accion, cerrar, handle)
					if not ok then
						warn("[ColegioRP][UIBuilder] Error en botón de modal: " .. tostring(resultado))
					end
					mantener = resultado == true
				end
				if not mantener and def.NoCerrar ~= true then
					cerrar()
				end
			end, { Estilo = def.Estilo or ((i == #botones) and "Primario" or "Secundario"), Ancho = def.Ancho or 140, LayoutOrder = i })
			table.insert(creados, boton)
			if primerBoton == nil then
				primerBoton = boton
			end
		end
		UIBuilder.Encadenar(creados, true)
	end

	if props.CerrarAlFondo then
		fondo.Activated:Connect(cerrar)
	end
	if props.Cerrable ~= false then
		local ok, conexion = pcall(function()
			return UserInputService.InputBegan:Connect(function(entrada, procesado)
				if entrada.KeyCode == Enum.KeyCode.ButtonB then
					cerrar()
				end
			end)
		end)
		if ok and conexion then
			table.insert(conexiones, conexion)
		end
	end

	UIBuilder.Tween(fondo, { BackgroundTransparency = 0.45 }, "Rapida")
	UIBuilder.Aparecer(panel)
	task.defer(function()
		if not handle.Cerrado then
			if primerBoton then
				UIBuilder.Enfocar(primerBoton)
			else
				UIBuilder.EnfocarPrimero(panel)
			end
		end
	end)
	return handle
end

-- Modal de confirmación rápida: Confirmar(titulo, mensaje, alAceptar, textoAceptar, estilo).
function UIBuilder.Confirmar(titulo, mensaje, alAceptar, textoAceptar, estilo)
	return UIBuilder.Modal(titulo, mensaje, {
		{ Texto = "Cancelar", Estilo = "Secundario" },
		{ Texto = textoAceptar or "Aceptar", Estilo = estilo or "Primario", Accion = function()
			if typeof(alAceptar) == "function" then
				pcall(alAceptar)
			end
		end },
	}, { CerrarAlFondo = true })
end

---------------------------------------------------------------------------------------------------
-- Toasts
---------------------------------------------------------------------------------------------------
local iconosNivel = { Exito = "✔", Aviso = "!", Error = "✖", Info = "i", Neutro = "•" }

-- Toast individual dentro de un contenedor (NotificationController gestiona la cola).
-- Devuelve marco, cerrar(). duracion en segundos (0 = no se cierra solo).
function UIBuilder.Toast(parent, texto, nivel, duracion, props)
	props = props or {}
	nivel = (UITheme.ColoresEstado[nivel] and nivel) or "Info"
	local color = UITheme.ColoresEstado[nivel]
	duracion = tonumber(duracion)
	if duracion == nil then
		duracion = 4
	end
	local marco = Instance.new("Frame")
	marco.Name = "Toast"
	marco.BackgroundColor3 = Colores.GrisPanel
	marco.BackgroundTransparency = 1
	marco.BorderSizePixel = 0
	marco.Size = UDim2.new(1, 0, 0, 0)
	marco.AutomaticSize = Enum.AutomaticSize.Y
	marco.ClipsDescendants = false
	UIBuilder.Esquinas(marco, UITheme.Radio)
	local borde = UIBuilder.Borde(marco, Colores.Borde, 1, 1)
	UIBuilder.Relleno(marco, 10, 10, 46, 12)
	local franja = Instance.new("Frame")
	franja.Name = "Franja"
	franja.BackgroundColor3 = color
	franja.BorderSizePixel = 0
	franja.Size = UDim2.new(0, 4, 1, -12)
	franja.Position = UDim2.new(0, -40, 0, -4)
	UIBuilder.Esquinas(franja, 2)
	franja.Parent = marco
	local icono = Instance.new("TextLabel")
	icono.Name = "Icono"
	icono.BackgroundColor3 = color
	icono.BorderSizePixel = 0
	icono.Font = UITheme.Fuente("Titulo")
	icono.TextSize = UITheme.Tamanos.Pequeno
	icono.TextColor3 = UITheme.TextoSobre(color)
	icono.Text = props.Icono or iconosNivel[nivel] or "•"
	icono.Size = UDim2.new(0, 22, 0, 22)
	icono.Position = UDim2.new(0, -32, 0, 0)
	UIBuilder.Esquinas(icono, UDim.new(0.5, 0))
	icono.Parent = marco
	local label = UIBuilder.Texto(marco, texto, { Nombre = "Mensaje", Tamano = props.Tamano or "Texto", Transparencia = 1, Rico = props.Rico })
	if props.Titulo then
		label.Text = tostring(props.Titulo) .. "\n" .. tostring(texto or "")
	end
	if props.LayoutOrder then
		marco.LayoutOrder = props.LayoutOrder
	end
	marco.Parent = parent

	local cerrado = false
	local function cerrar()
		if cerrado then
			return
		end
		cerrado = true
		UIBuilder.Tween(label, { TextTransparency = 1 }, "Rapida")
		UIBuilder.Tween(icono, { BackgroundTransparency = 1, TextTransparency = 1 }, "Rapida")
		UIBuilder.Tween(franja, { BackgroundTransparency = 1 }, "Rapida")
		UIBuilder.Tween(borde, { Transparency = 1 }, "Rapida")
		UIBuilder.Tween(marco, { BackgroundTransparency = 1 }, "Rapida", function()
			UIBuilder.Destruir(marco)
		end)
		if typeof(props.AlCerrar) == "function" then
			pcall(props.AlCerrar)
		end
	end
	UIBuilder.Tween(marco, { BackgroundTransparency = UITheme.Transparencias.Panel }, "Rapida")
	UIBuilder.Tween(borde, { Transparency = 0 }, "Rapida")
	UIBuilder.Tween(label, { TextTransparency = 0 }, "Rapida")
	if duracion > 0 then
		task.delay(duracion, cerrar)
	end
	return marco, cerrar
end

---------------------------------------------------------------------------------------------------
-- Cierre por teclado / mando
---------------------------------------------------------------------------------------------------

-- Conecta Escape y el botón B del mando a 'fn' (cierre de paneles). Escape se ignora mientras se escribe
-- en un TextBox. Devuelve la RBXScriptConnection (guardarla en un Maid) o nil.
function UIBuilder.TeclaCerrar(fn)
	if typeof(fn) ~= "function" then
		return nil
	end
	local ok, conexion = pcall(function()
		return UserInputService.InputBegan:Connect(function(entrada)
			local tecla = entrada.KeyCode
			if tecla ~= Enum.KeyCode.ButtonB and tecla ~= Enum.KeyCode.Escape then
				return
			end
			if tecla == Enum.KeyCode.Escape and UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			local exito, err = pcall(fn)
			if not exito then
				warn("[ColegioRP][UIBuilder] Error al cerrar con tecla: " .. tostring(err))
			end
		end)
	end)
	if ok then
		return conexion
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Reacción a cambios de dispositivo (mando conectado, teclado, tamaño de pantalla) y de ajustes
---------------------------------------------------------------------------------------------------
local function refrescarSiCambia()
	local total = UIBuilder.EscalaTotal()
	if ultimaEscalaTotal == nil or math.abs(total - ultimaEscalaTotal) > 0.001 then
		UIBuilder.RefrescarEscalas()
	end
end

pcall(function()
	UserInputService.LastInputTypeChanged:Connect(refrescarSiCambia)
end)

-- El umbral móvil/tableta depende del tamaño del viewport (rotación de pantalla, ventana).
local conexionViewport = nil
local function vigilarCamara()
	if conexionViewport then
		conexionViewport:Disconnect()
		conexionViewport = nil
	end
	local camara = workspace.CurrentCamera
	if camara then
		conexionViewport = camara:GetPropertyChangedSignal("ViewportSize"):Connect(refrescarSiCambia)
	end
end
pcall(vigilarCamara)
pcall(function()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		pcall(vigilarCamara)
		refrescarSiCambia()
	end)
end)

-- El atributo local MovimientoReducido del Player (SettingsController) se refleja en UIBuilder.Ajustes.
pcall(function()
	UIBuilder.Ajustes.MovimientoReducido = LocalPlayer:GetAttribute("MovimientoReducido") == true
	LocalPlayer:GetAttributeChangedSignal("MovimientoReducido"):Connect(function()
		UIBuilder.Ajustes.MovimientoReducido = LocalPlayer:GetAttribute("MovimientoReducido") == true
	end)
end)

return UIBuilder
