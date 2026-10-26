--[[
	Ruta en el Explorer: ReplicatedFirst.ColegioRP_Carga
	Tipo: LocalScript
	Pantalla de carga real de Colegio RP (hitos finitos + ContentProvider:PreloadAsync) seguida de la intro
	"Horizon Studios by Adrian". Al terminar marca y dispara el BindableEvent ReplicatedFirst.ColegioRP_CargaLista
	(atributos Listo, IntroMostrada, AvisoRecursos) que espera StarterPlayerScripts.ColegioRP.Main. Nunca bloquea.
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local PREFIJO = "[ColegioRP][Carga]"
local TIEMPO_MAXIMO_SEG = 25 -- Tras este tiempo se continúa aunque falten recursos.
local ESPERA_PAQUETE_SEG = 10 -- Espera máxima de ReplicatedStorage.ColegioRP y de Shared.
local NOMBRE_PANTALLA = "ColegioRP_Carga"
local inicioCarga = os.clock()
local rng = Random.new()

pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

---------------------------------------------------------------------------------------------------
-- Valores por defecto embebidos (se usan hasta que Shared.Config esté disponible, o si no lo está)
---------------------------------------------------------------------------------------------------
local Config = {
	NombreColegio = "Instituto Educativo Jean Piaget",
	Lema = "Educación integral · Camino a la excelencia",
	Productora = "Horizon Studios",
	Autor = "by Adrian",
	Version = "2.0.0",
	LogoAssetId = 0,
	Sonidos = {},
	Nombres = { CarpetaRemotos = "Remotes", SenalCargaLista = "ColegioRP_CargaLista" },
}

local COLORES = {
	Fondo = Color3.fromRGB(10, 10, 12),
	Negro = Color3.fromRGB(0, 0, 0),
	Rojo = Color3.fromRGB(196, 30, 36),
	RojoOscuro = Color3.fromRGB(150, 22, 28),
	Blanco = Color3.fromRGB(245, 245, 245),
	Gris = Color3.fromRGB(34, 36, 40),
	Borde = Color3.fromRGB(60, 62, 68),
	TextoSecundario = Color3.fromRGB(190, 190, 195),
	TextoApagado = Color3.fromRGB(130, 132, 138),
	Amarillo = Color3.fromRGB(246, 196, 34),
}

-- Fuentes que usa la interfaz (se precargan con etiquetas ocultas).
local FUENTES = {
	{ Nombre = "Gotham Bold", Fuente = Enum.Font.GothamBold },
	{ Nombre = "Gotham Medium", Fuente = Enum.Font.GothamMedium },
	{ Nombre = "Gotham", Fuente = Enum.Font.Gotham },
	{ Nombre = "Code", Fuente = Enum.Font.Code },
}

-- string.upper que también convierte las vocales acentuadas y la ñ (UTF-8).
local ACENTOS = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ñ"] = "Ñ", ["ü"] = "Ü" }
local function mayusculas(valor)
	local resultado = string.upper(tostring(valor or ""))
	for minuscula, mayuscula in pairs(ACENTOS) do
		resultado = string.gsub(resultado, minuscula, mayuscula)
	end
	return resultado
end

local function nombreSenal()
	local nombres = Config.Nombres
	local nombre = typeof(nombres) == "table" and nombres.SenalCargaLista or nil
	if typeof(nombre) == "string" and nombre ~= "" then
		return nombre
	end
	return "ColegioRP_CargaLista"
end

local function nombreRemotos()
	local nombres = Config.Nombres
	local nombre = typeof(nombres) == "table" and nombres.CarpetaRemotos or nil
	if typeof(nombre) == "string" and nombre ~= "" then
		return nombre
	end
	return "Remotes"
end

local function idLogo()
	local id = tonumber(Config.LogoAssetId) or 0
	if id ~= id or id < 0 then
		return 0
	end
	return math.floor(id)
end

---------------------------------------------------------------------------------------------------
-- Señal de carga lista (BindableEvent en ReplicatedFirst). Se crea al principio con Listo = false.
---------------------------------------------------------------------------------------------------
local senal = ReplicatedFirst:FindFirstChild(nombreSenal())
if senal and senal:IsA("BindableEvent") and senal:GetAttribute("Listo") == true then
	-- La carga ya terminó en esta sesión (el script no debe repetirse).
	return
end
if not (senal and senal:IsA("BindableEvent")) then
	senal = Instance.new("BindableEvent")
	senal.Name = nombreSenal()
	senal:SetAttribute("Listo", false)
	senal:SetAttribute("IntroMostrada", false)
	senal.Parent = ReplicatedFirst
end

local player = Players.LocalPlayer
local conexiones = {}

local function conectar(evento, fn)
	local ok, conexion = pcall(function()
		return evento:Connect(fn)
	end)
	if ok and conexion then
		table.insert(conexiones, conexion)
		return conexion
	end
	return nil
end

local function desconectarTodo()
	for _, conexion in ipairs(conexiones) do
		pcall(function()
			conexion:Disconnect()
		end)
	end
	table.clear(conexiones)
end

-- Señal de cliente sin jugador local (no debería ocurrir): se libera Main y se termina.
if not player then
	warn(PREFIJO .. " No hay LocalPlayer; se omite la pantalla de carga.")
	senal:SetAttribute("Listo", true)
	senal:Fire({ IntroMostrada = false })
	return
end

local function movimientoReducido()
	local ok, valor = pcall(function()
		return player:GetAttribute("MovimientoReducido")
	end)
	return ok and valor == true
end

---------------------------------------------------------------------------------------------------
-- Estado y espera basada en eventos (sin bucles de espera activa)
---------------------------------------------------------------------------------------------------
local estado = {
	Fase = "carga", -- "carga" | "intro" | "final"
	Resueltos = {}, -- [clave] = true (ok) | false (falló o tiempo agotado)
	Progreso = 0,
	FraccionRecursos = 0,
	SaltarPedido = false,
	Vencido = false,
	HitosTerminados = false,
	IntroOmitida = false,
	Avisos = false,
	Pulsaciones = 0, -- Veces que se pulsó Saltar (para pausas interrumpibles).
}

local cambio = Instance.new("BindableEvent")
local function notificarCambio()
	pcall(function()
		cambio:Fire()
	end)
end

-- Espera hasta que condicion() sea verdadera o pasen 'limiteSeg' segundos (si se indica).
local function esperarHasta(condicion, limiteSeg)
	local vencido = false
	if limiteSeg then
		task.delay(limiteSeg, function()
			vencido = true
			notificarCambio()
		end)
	end
	while not condicion() do
		if vencido then
			return false
		end
		cambio.Event:Wait()
	end
	return true
end

local function segundosRestantes()
	return math.max(0.1, TIEMPO_MAXIMO_SEG - (os.clock() - inicioCarga))
end

local HITOS = {
	{ Clave = "RP", Peso = 0.15, Texto = "paquete principal (ReplicatedStorage.ColegioRP)" },
	{ Clave = "Shared", Peso = 0.15, Texto = "módulos compartidos (Shared)" },
	{ Clave = "Remotes", Peso = 0.15, Texto = "canales de red (Remotes)" },
	{ Clave = "PlayerScripts", Peso = 0.15, Texto = "scripts del jugador (PlayerScripts.ColegioRP)" },
	{ Clave = "Recursos", Peso = 0.40, Texto = "recursos (logo, sonidos y fuentes)" },
}

local function minimosListos()
	return estado.Resueltos.RP ~= nil and estado.Resueltos.Shared ~= nil and estado.Resueltos.Remotes ~= nil
end

---------------------------------------------------------------------------------------------------
-- Utilidades de interfaz
---------------------------------------------------------------------------------------------------
local function crear(clase, props, padre)
	local instancia = Instance.new(clase)
	for clave, valor in pairs(props or {}) do
		instancia[clave] = valor
	end
	if padre then
		instancia.Parent = padre
	end
	return instancia
end

local function esquinas(obj, radio)
	return crear("UICorner", { CornerRadius = radio or UDim.new(0, 8) }, obj)
end

local function borde(obj, color, grosor, transparencia)
	return crear("UIStroke", {
		Color = color or COLORES.Borde,
		Thickness = grosor or 1,
		Transparency = transparencia or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, obj)
end

local function texto(padre, props)
	local base = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextColor3 = COLORES.Blanco,
		TextSize = 16,
		TextWrapped = true,
		Text = "",
	}
	for clave, valor in pairs(props or {}) do
		base[clave] = valor
	end
	return crear("TextLabel", base, padre)
end

-- Anima propiedades. Con MovimientoReducido los cambios son instantáneos salvo los fundidos (0.15 s).
local function animar(obj, props, duracion, esFundido, estilo)
	if typeof(obj) ~= "Instance" or obj.Parent == nil then
		return nil
	end
	local t = tonumber(duracion) or 0.25
	if movimientoReducido() then
		if esFundido then
			t = math.min(t, 0.15)
		else
			t = 0
		end
	end
	if t <= 0 then
		for clave, valor in pairs(props) do
			pcall(function()
				obj[clave] = valor
			end)
		end
		return nil
	end
	local ok, tween = pcall(function()
		return TweenService:Create(obj, TweenInfo.new(t, estilo or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	end)
	if ok and tween then
		tween:Play()
		return tween
	end
	for clave, valor in pairs(props) do
		pcall(function()
			obj[clave] = valor
		end)
	end
	return nil
end

-- Transparencias actuales de un objeto de interfaz (para fundidos de entrada y salida).
local function transparenciasDe(obj)
	local props = {}
	if obj:IsA("GuiObject") then
		props.BackgroundTransparency = obj.BackgroundTransparency
	end
	if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
		props.TextTransparency = obj.TextTransparency
	end
	if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		props.ImageTransparency = obj.ImageTransparency
	end
	if obj:IsA("UIStroke") then
		props.Transparency = obj.Transparency
	end
	return props
end

local function objetosDe(raiz)
	local lista = { raiz }
	for _, d in ipairs(raiz:GetDescendants()) do
		table.insert(lista, d)
	end
	return lista
end

-- Deja la rama invisible y devuelve sus transparencias originales para FundirEntrada.
local function prepararFundido(raiz)
	local originales = {}
	for _, obj in ipairs(objetosDe(raiz)) do
		local props = transparenciasDe(obj)
		if next(props) ~= nil then
			originales[obj] = props
			for clave in pairs(props) do
				pcall(function()
					obj[clave] = 1
				end)
			end
		end
	end
	return originales
end

local function fundirEntrada(originales, duracion)
	for obj, props in pairs(originales) do
		animar(obj, props, duracion, true)
	end
end

local function fundirSalida(raiz, duracion)
	for _, obj in ipairs(objetosDe(raiz)) do
		local props = transparenciasDe(obj)
		if next(props) ~= nil then
			for clave in pairs(props) do
				props[clave] = 1
			end
			animar(obj, props, duracion, true)
		end
	end
end

-- Logo del colegio: imagen real si LogoAssetId > 0; si no, logo vectorial de respaldo.
local function crearLogo(padre, tamano)
	local marco = crear("Frame", {
		Name = "Logo",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(0, tamano, 0, tamano),
	})
	local id = idLogo()
	if id > 0 then
		crear("ImageLabel", {
			Name = "Imagen",
			BackgroundTransparency = 1,
			Image = "rbxassetid://" .. tostring(id),
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.new(1, 0, 1, 0),
		}, marco)
		marco.Parent = padre
		return marco
	end
	local circulo = crear("Frame", {
		Name = "Circulo",
		BackgroundColor3 = COLORES.Rojo,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
	}, marco)
	esquinas(circulo, UDim.new(0.5, 0))
	borde(circulo, COLORES.Blanco, math.max(2, math.floor(tamano * 0.03)))
	local anillo = crear("Frame", {
		Name = "Anillo",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.86, 0, 0.86, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
	}, circulo)
	esquinas(anillo, UDim.new(0.5, 0))
	borde(anillo, COLORES.Blanco, math.max(1, math.floor(tamano * 0.01)), 0.35)
	local function linea(nombre, contenido, fuente, ancho, alto, posY, transparencia)
		return texto(circulo, {
			Name = nombre,
			Font = fuente,
			TextScaled = true,
			TextTransparency = transparencia or 0,
			Text = contenido,
			Size = UDim2.new(ancho, 0, alto, 0),
			Position = UDim2.new(0.5, 0, posY, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
		})
	end
	linea("Instituto", "INSTITUTO EDUCATIVO", Enum.Font.GothamMedium, 0.72, 0.1, 0.3)
	linea("Nombre", "JEAN PIAGET", Enum.Font.GothamBold, 0.78, 0.2, 0.48)
	crear("Frame", {
		Name = "Linea",
		BackgroundColor3 = COLORES.Blanco,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = UDim2.new(0.5, 0, 0, math.max(1, math.floor(tamano * 0.012))),
		Position = UDim2.new(0.5, 0, 0.61, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
	}, circulo)
	linea("Lema", "EDUCACIÓN INTEGRAL · CAMINO A LA EXCELENCIA", Enum.Font.Gotham, 0.74, 0.075, 0.7, 0.1)
	marco.Parent = padre
	return marco
end

---------------------------------------------------------------------------------------------------
-- Construcción de la pantalla (una sola instancia)
---------------------------------------------------------------------------------------------------
local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)

local ui = {}

local function construirPantalla()
	local gui = playerGui:FindFirstChild(NOMBRE_PANTALLA)
	if gui and gui:IsA("ScreenGui") then
		gui:ClearAllChildren()
	else
		if gui then
			gui:Destroy()
		end
		gui = Instance.new("ScreenGui")
		gui.Name = NOMBRE_PANTALLA
	end
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 100
	gui.Enabled = true
	ui.Gui = gui

	local escala = crear("UIScale", { Name = "EscalaCarga", Scale = 1 }, gui)
	local function actualizarEscala()
		local tamano = Vector2.new(1280, 720)
		pcall(function()
			tamano = workspace.CurrentCamera.ViewportSize
		end)
		if tamano.X <= 0 or tamano.Y <= 0 then
			tamano = Vector2.new(1280, 720)
		end
		local factor = math.clamp(math.min(tamano.X / 1280, tamano.Y / 720), 0.6, 1.25)
		escala.Scale = factor
		-- El botón Saltar conserva un tamaño táctil grande (mínimo 48 px de alto reales) con cualquier escala.
		if ui.Saltar and ui.Saltar.Parent then
			ui.Saltar.Size = UDim2.new(0, math.ceil(math.max(200, 170 / factor)), 0, math.ceil(math.max(56, 48 / factor)))
		end
	end
	ui.ActualizarEscala = actualizarEscala
	local camaraEnganchada = nil
	local function engancharCamara()
		local camara = workspace.CurrentCamera
		if camara and camara ~= camaraEnganchada then
			camaraEnganchada = camara
			conectar(camara:GetPropertyChangedSignal("ViewportSize"), actualizarEscala)
		end
		actualizarEscala()
	end
	engancharCamara()
	conectar(workspace:GetPropertyChangedSignal("CurrentCamera"), engancharCamara)

	local fondo = crear("Frame", {
		Name = "Fondo",
		BackgroundColor3 = COLORES.Fondo,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 1,
	}, gui)
	ui.Fondo = fondo

	-- Capa de partículas (debajo del contenido).
	ui.Particulas = crear("Frame", {
		Name = "Particulas",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		ClipsDescendants = true,
		ZIndex = 2,
	}, gui)

	-- Contenido de carga centrado.
	local contenido = crear("Frame", {
		Name = "Contenido",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 520, 0, 470),
		Position = UDim2.new(0.5, 0, 0.47, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
	}, gui)
	ui.Contenido = contenido

	ui.MarcoLogo = crear("Frame", {
		Name = "MarcoLogo",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 220, 0, 220),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
	}, contenido)
	ui.Logo = crearLogo(ui.MarcoLogo, 220)

	ui.Nombre = texto(contenido, {
		Name = "NombreColegio",
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		Text = mayusculas(Config.NombreColegio),
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 0, 236),
	})
	ui.Principal = texto(contenido, {
		Name = "Principal",
		Font = Enum.Font.GothamMedium,
		TextSize = 20,
		Text = "Cargando…",
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 0, 280),
	})
	ui.Detalle = texto(contenido, {
		Name = "Detalle",
		TextSize = 15,
		TextColor3 = COLORES.TextoSecundario,
		Text = "Descargando paquetes…",
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 0, 310),
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	local barra = crear("Frame", {
		Name = "Barra",
		BackgroundColor3 = COLORES.Gris,
		BorderSizePixel = 0,
		Size = UDim2.new(0.86, 0, 0, 10),
		Position = UDim2.new(0.5, 0, 0, 362),
		AnchorPoint = Vector2.new(0.5, 0),
		ClipsDescendants = true,
	}, contenido)
	esquinas(barra, UDim.new(0.5, 0))
	borde(barra, COLORES.Borde, 1)
	ui.Relleno = crear("Frame", {
		Name = "Relleno",
		BackgroundColor3 = COLORES.Rojo,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
	}, barra)
	esquinas(ui.Relleno, UDim.new(0.5, 0))

	ui.Porcentaje = texto(contenido, {
		Name = "Porcentaje",
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = COLORES.TextoSecundario,
		Text = "0 %",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 380),
	})
	ui.Aviso = texto(contenido, {
		Name = "Aviso",
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		TextColor3 = COLORES.Amarillo,
		Text = "",
		Visible = false,
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 0, 408),
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	ui.Creditos = texto(gui, {
		Name = "Creditos",
		TextSize = 13,
		TextColor3 = COLORES.TextoApagado,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Text = tostring(Config.Productora) .. " " .. tostring(Config.Autor) .. " · v" .. tostring(Config.Version),
		Size = UDim2.new(0, 420, 0, 20),
		Position = UDim2.new(0, 24, 1, -24),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 3,
	})

	-- Capa de la intro (encima del contenido de carga, debajo del botón Saltar).
	ui.Intro = crear("Frame", {
		Name = "Intro",
		BackgroundColor3 = COLORES.Negro,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		Visible = false,
		ZIndex = 5,
	}, gui)

	-- Botón Saltar: grande y visible desde el inicio (también Enter / botón A del mando).
	ui.Saltar = crear("TextButton", {
		Name = "Saltar",
		AutoButtonColor = true,
		BackgroundColor3 = COLORES.Gris,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		TextColor3 = COLORES.Blanco,
		Text = "Saltar  ›",
		Size = UDim2.new(0, 200, 0, 56),
		Position = UDim2.new(1, -24, 1, -24),
		AnchorPoint = Vector2.new(1, 1),
		Selectable = true,
		ZIndex = 10,
	}, gui)
	esquinas(ui.Saltar, UDim.new(0, 10))
	local bordeSaltar = borde(ui.Saltar, COLORES.Borde, 1)
	conectar(ui.Saltar.SelectionGained, function()
		bordeSaltar.Color = COLORES.Amarillo
		bordeSaltar.Thickness = 2
	end)
	conectar(ui.Saltar.SelectionLost, function()
		bordeSaltar.Color = COLORES.Borde
		bordeSaltar.Thickness = 1
	end)
	actualizarEscala()
	crear("TextLabel", {
		Name = "Pista",
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = COLORES.TextoApagado,
		Text = "Enter / A",
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 0, -18),
		ZIndex = 10,
	}, ui.Saltar)

	-- Etiquetas ocultas para precargar las fuentes.
	ui.Fuentes = {}
	local carpetaFuentes = crear("Frame", {
		Name = "Fuentes",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 1, 0, 1),
		Position = UDim2.new(0, -10, 0, -10),
	}, gui)
	for _, def in ipairs(FUENTES) do
		local etiqueta = texto(carpetaFuentes, {
			Name = def.Nombre,
			Font = def.Fuente,
			Text = "Áa",
			TextTransparency = 1,
			Size = UDim2.new(0, 1, 0, 1),
		})
		table.insert(ui.Fuentes, { Nombre = def.Nombre, Instancia = etiqueta })
	end

	gui.Parent = playerGui
	return gui
end

if playerGui then
	local okUi, errUi = pcall(construirPantalla)
	if not okUi then
		warn(PREFIJO .. " No se pudo construir la pantalla de carga: " .. tostring(errUi))
		if ui.Gui then
			pcall(function()
				ui.Gui:Destroy()
			end)
		end
		ui = {}
	end
else
	warn(PREFIJO .. " PlayerGui no apareció; se carga sin pantalla.")
end

local function fijarTexto(etiqueta, contenido)
	if etiqueta and etiqueta.Parent then
		pcall(function()
			etiqueta.Text = contenido
		end)
	end
end

local function fijarDetalle(contenido)
	fijarTexto(ui.Detalle, contenido)
end

local function mostrarAviso(contenido)
	if ui.Aviso and ui.Aviso.Parent then
		ui.Aviso.Text = contenido
		ui.Aviso.Visible = true
	end
end

local function actualizarProgreso()
	local total = 0
	for _, hito in ipairs(HITOS) do
		if estado.Resueltos[hito.Clave] ~= nil then
			total = total + hito.Peso
		elseif hito.Clave == "Recursos" then
			total = total + hito.Peso * estado.FraccionRecursos
		end
	end
	total = math.clamp(total, 0, 1)
	estado.Progreso = total
	if ui.Relleno and ui.Relleno.Parent then
		animar(ui.Relleno, { Size = UDim2.new(total, 0, 1, 0) }, 0.2)
	end
	fijarTexto(ui.Porcentaje, tostring(math.floor(total * 100 + 0.5)) .. " %")
end

local function resolverHito(clave, ok)
	if estado.Resueltos[clave] == nil then
		estado.Resueltos[clave] = ok == true
		if ok ~= true then
			estado.Avisos = true
		end
	end
	actualizarProgreso()
	notificarCambio()
end

-- Sustituye el logo de la carga si Config trae un LogoAssetId real y actualiza textos.
local function aplicarConfig()
	if ui.MarcoLogo and ui.MarcoLogo.Parent and idLogo() > 0 then
		if ui.Logo then
			pcall(function()
				ui.Logo:Destroy()
			end)
		end
		ui.Logo = crearLogo(ui.MarcoLogo, 220)
	end
	fijarTexto(ui.Nombre, mayusculas(Config.NombreColegio or ""))
	fijarTexto(ui.Creditos, tostring(Config.Productora) .. " " .. tostring(Config.Autor) .. " · v" .. tostring(Config.Version))
	if senal and senal.Parent and senal.Name ~= nombreSenal() then
		senal.Name = nombreSenal()
	end
end

---------------------------------------------------------------------------------------------------
-- Partículas suaves (≤ 12 puntos con TweenService); desactivadas con MovimientoReducido
---------------------------------------------------------------------------------------------------
local particulasActivas = false
local tweensParticulas = {}

local function animarParticula(punto, primeraVez)
	if not particulasActivas or punto.Parent == nil then
		return
	end
	local x = rng:NextNumber(0.02, 0.98)
	local yInicio = 1.05
	if primeraVez then
		yInicio = rng:NextNumber(0.1, 1.05)
	end
	punto.Position = UDim2.new(x, 0, yInicio, 0)
	local recorrido = yInicio + 0.05
	local duracion = (9 + rng:NextNumber(0, 7)) * recorrido
	local ok, tween = pcall(function()
		return TweenService:Create(punto, TweenInfo.new(duracion, Enum.EasingStyle.Linear), {
			Position = UDim2.new(math.clamp(x + rng:NextNumber(-0.06, 0.06), 0, 1), 0, -0.05, 0),
		})
	end)
	if not ok or not tween then
		return
	end
	tweensParticulas[punto] = tween
	tween.Completed:Once(function(estadoTween)
		if estadoTween == Enum.PlaybackState.Completed then
			animarParticula(punto, false)
		end
	end)
	tween:Play()
end

local function detenerParticulas()
	particulasActivas = false
	for punto, tween in pairs(tweensParticulas) do
		pcall(function()
			tween:Cancel()
		end)
		pcall(function()
			punto:Destroy()
		end)
	end
	table.clear(tweensParticulas)
end

local function iniciarParticulas()
	if not ui.Particulas or movimientoReducido() then
		return
	end
	particulasActivas = true
	for i = 1, 12 do
		local tamano = rng:NextInteger(3, 7)
		local punto = crear("Frame", {
			Name = "Punto" .. i,
			BackgroundColor3 = (i % 3 == 0) and COLORES.Rojo or COLORES.Blanco,
			BackgroundTransparency = rng:NextNumber(0.75, 0.9),
			BorderSizePixel = 0,
			Size = UDim2.new(0, tamano, 0, tamano),
			AnchorPoint = Vector2.new(0.5, 0.5),
		}, ui.Particulas)
		esquinas(punto, UDim.new(0.5, 0))
		animarParticula(punto, true)
	end
end

pcall(iniciarParticulas)
conectar(player:GetAttributeChangedSignal("MovimientoReducido"), function()
	if movimientoReducido() then
		detenerParticulas()
	end
end)

---------------------------------------------------------------------------------------------------
-- Botón Saltar (y Enter / botón A)
---------------------------------------------------------------------------------------------------
local ultimoSalto = 0

local function pedirSaltar()
	if os.clock() - ultimoSalto < 0.3 then
		return
	end
	ultimoSalto = os.clock()
	estado.Pulsaciones = estado.Pulsaciones + 1
	if estado.Fase == "carga" then
		estado.SaltarPedido = true
		if not minimosListos() then
			fijarTexto(ui.Principal, "Preparando recursos esenciales…")
		end
	elseif estado.Fase == "intro" then
		estado.IntroOmitida = true
	end
	notificarCambio()
end

if ui.Saltar then
	conectar(ui.Saltar.Activated, pedirSaltar)
end
conectar(UserInputService.InputBegan, function(entrada, procesado)
	local tecla = entrada.KeyCode
	if tecla == Enum.KeyCode.Return or tecla == Enum.KeyCode.KeypadEnter then
		if not procesado then
			pedirSaltar()
		end
	elseif tecla == Enum.KeyCode.ButtonA then
		pedirSaltar()
	end
end)

pcall(function()
	if ui.Saltar and UserInputService.GamepadEnabled then
		GuiService.SelectedObject = ui.Saltar
	end
end)

---------------------------------------------------------------------------------------------------
-- Hitos de carga (en su propio hilo: la espera nunca bloquea al botón Saltar)
---------------------------------------------------------------------------------------------------
local RP = nil
local Shared = nil

local function esperarHijo(padre, nombre, limite)
	if not padre then
		return nil
	end
	local hijo = padre:FindFirstChild(nombre)
	if hijo then
		return hijo
	end
	local ok, resultado = pcall(function()
		return padre:WaitForChild(nombre, math.max(0.1, limite))
	end)
	if ok then
		return resultado
	end
	return nil
end

local function cargarConfig()
	local modulo = esperarHijo(Shared, "Config", math.min(ESPERA_PAQUETE_SEG, segundosRestantes()))
	if not modulo or not modulo:IsA("ModuleScript") then
		warn(PREFIJO .. " Shared.Config no está disponible; se usan valores por defecto.")
		return false
	end
	local ok, resultado = pcall(require, modulo)
	if not ok or typeof(resultado) ~= "table" then
		warn(PREFIJO .. " No se pudo cargar Shared.Config: " .. tostring(resultado))
		return false
	end
	if typeof(resultado.Nombres) ~= "table" then
		resultado.Nombres = Config.Nombres
	end
	if typeof(resultado.Sonidos) ~= "table" then
		resultado.Sonidos = {}
	end
	Config = resultado
	pcall(aplicarConfig)
	return true
end

local function listaRecursos()
	local lista = {}
	local id = idLogo()
	if id > 0 then
		table.insert(lista, { Nombre = "logo del colegio", Recurso = "rbxassetid://" .. tostring(id) })
	end
	local nombresSonidos = {}
	for nombre, valor in pairs(Config.Sonidos or {}) do
		local n = tonumber(valor) or 0
		if n > 0 then
			table.insert(nombresSonidos, nombre)
		end
	end
	table.sort(nombresSonidos)
	for _, nombre in ipairs(nombresSonidos) do
		local n = math.floor(tonumber(Config.Sonidos[nombre]) or 0)
		table.insert(lista, { Nombre = "sonido " .. tostring(nombre), Recurso = "rbxassetid://" .. tostring(n) })
	end
	for _, fuente in ipairs(ui.Fuentes or {}) do
		if fuente.Instancia and fuente.Instancia.Parent then
			table.insert(lista, { Nombre = "fuente " .. fuente.Nombre, Recurso = fuente.Instancia })
		end
	end
	return lista
end

local function precargarRecursos()
	local lista = listaRecursos()
	local total = #lista
	if total == 0 then
		estado.FraccionRecursos = 1
		return true
	end
	local fallos = 0
	for i, item in ipairs(lista) do
		fijarDetalle("Descargando paquetes… · " .. item.Nombre .. " (" .. i .. "/" .. total .. ")")
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ item.Recurso }, function(contenido, estadoRecurso)
				-- Callback por recurso: registra los fallos sin detener la carga.
				local fallo = false
				pcall(function()
					fallo = estadoRecurso == Enum.AssetFetchStatus.Failure or estadoRecurso == Enum.AssetFetchStatus.TimedOut
				end)
				if fallo then
					fallos = fallos + 1
					warn(PREFIJO .. " No se pudo descargar " .. tostring(contenido))
				end
			end)
		end)
		if not ok then
			fallos = fallos + 1
			warn(PREFIJO .. " Error al precargar " .. item.Nombre .. ": " .. tostring(err))
		end
		estado.FraccionRecursos = i / total
		actualizarProgreso()
	end
	return fallos == 0
end

local function ejecutarHitos()
	-- 1. ReplicatedStorage.ColegioRP
	fijarDetalle("Descargando paquetes… · " .. HITOS[1].Texto)
	RP = esperarHijo(ReplicatedStorage, "ColegioRP", math.min(ESPERA_PAQUETE_SEG, segundosRestantes()))
	resolverHito("RP", RP ~= nil)
	if not RP then
		warn(PREFIJO .. " ReplicatedStorage.ColegioRP no apareció en " .. ESPERA_PAQUETE_SEG .. " s.")
	end

	-- 2. Shared (+ Config)
	fijarDetalle("Descargando paquetes… · " .. HITOS[2].Texto)
	Shared = esperarHijo(RP, "Shared", math.min(ESPERA_PAQUETE_SEG, segundosRestantes()))
	local configOk = false
	if Shared then
		configOk = cargarConfig()
	end
	resolverHito("Shared", Shared ~= nil and configOk)

	-- 3. Remotes (los crea RemoteService en el servidor)
	fijarDetalle("Descargando paquetes… · " .. HITOS[3].Texto)
	local remotos = esperarHijo(RP, nombreRemotos(), segundosRestantes())
	resolverHito("Remotes", remotos ~= nil)

	-- 4. PlayerScripts.ColegioRP del jugador
	fijarDetalle("Descargando paquetes… · " .. HITOS[4].Texto)
	local playerScripts = esperarHijo(player, "PlayerScripts", segundosRestantes())
	local carpetaCliente = esperarHijo(playerScripts, "ColegioRP", segundosRestantes())
	resolverHito("PlayerScripts", carpetaCliente ~= nil)

	-- 5. Recursos (logo, sonidos con id > 0 y fuentes usadas)
	fijarDetalle("Descargando paquetes… · " .. HITOS[5].Texto)
	local recursosOk = precargarRecursos()
	resolverHito("Recursos", recursosOk)
	fijarDetalle("Paquetes descargados.")
end

task.spawn(function()
	local ok, err = pcall(ejecutarHitos)
	if not ok then
		warn(PREFIJO .. " Error durante la carga: " .. tostring(err))
		estado.Avisos = true
	end
	estado.HitosTerminados = true
	notificarCambio()
end)

task.delay(TIEMPO_MAXIMO_SEG, function()
	estado.Vencido = true
	notificarCambio()
end)

---------------------------------------------------------------------------------------------------
-- Fase de carga: termina con todos los hitos, con Saltar (si los mínimos están) o por tiempo máximo
---------------------------------------------------------------------------------------------------
esperarHasta(function()
	if estado.HitosTerminados or estado.Vencido then
		return true
	end
	return estado.SaltarPedido and minimosListos()
end)

local saltadoPorJugador = not estado.HitosTerminados and not estado.Vencido
if not estado.HitosTerminados then
	estado.Avisos = true
end
if estado.Avisos and not saltadoPorJugador then
	-- Tiempo máximo agotado o algún hito falló: se continúa con aviso (pausa breve, omitible).
	fijarTexto(ui.Principal, "Listo")
	mostrarAviso("Algunos recursos siguen cargando; puedes jugar mientras terminan.")
	local pulsacionesAntes = estado.Pulsaciones
	esperarHasta(function()
		return estado.Pulsaciones > pulsacionesAntes
	end, 1.5)
else
	fijarTexto(ui.Principal, "¡Listo!")
	actualizarProgreso()
end

---------------------------------------------------------------------------------------------------
-- Intro Horizon Studios (4-5 s, omitible; no se repite)
---------------------------------------------------------------------------------------------------
local function introYaVista()
	if script:GetAttribute("IntroMostrada") == true then
		return true
	end
	local ok, valor = pcall(function()
		return player:GetAttribute("IntroVista")
	end)
	return ok and valor == true
end

-- Espera interrumpible por el botón Saltar.
local function pausaIntro(segundos)
	if estado.IntroOmitida then
		return
	end
	esperarHasta(function()
		return estado.IntroOmitida
	end, segundos)
end

local function reproducirIntro()
	local capa = ui.Intro
	if not capa then
		return false
	end
	estado.Fase = "intro"
	estado.IntroOmitida = false
	capa.Visible = true
	fijarTexto(ui.Saltar, "Omitir  ›")
	local reducido = movimientoReducido()

	local marco = crear("Frame", {
		Name = "Marca",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 640, 0, 200),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 6,
	}, capa)
	local trazo = crear("Frame", {
		Name = "Trazo",
		BackgroundColor3 = COLORES.Blanco,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 0, 2),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 6,
	}, marco)
	local acento = crear("Frame", {
		Name = "Acento",
		BackgroundColor3 = COLORES.Rojo,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 0, 2),
		Position = UDim2.new(0.5, 0, 0.5, 4),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 6,
	}, marco)
	local productora = texto(marco, {
		Name = "Productora",
		Font = Enum.Font.GothamBold,
		TextSize = 44,
		TextWrapped = false,
		Text = mayusculas(Config.Productora or "Horizon Studios"),
		TextTransparency = 1,
		Size = UDim2.new(1, 0, 0, 52),
		Position = UDim2.new(0.5, 0, 0.5, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 6,
	})
	local autor = texto(marco, {
		Name = "Autor",
		Font = Enum.Font.GothamMedium,
		TextSize = 20,
		TextWrapped = false,
		TextColor3 = COLORES.TextoSecundario,
		Text = mayusculas(Config.Autor or "by Adrian"),
		TextTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0.5, 0, 0.5, 18),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 6,
	})

	if reducido then
		-- Sin animaciones: fotogramas estáticos.
		capa.BackgroundTransparency = 0
		ui.Contenido.Visible = false
		trazo.Size = UDim2.new(0.6, 0, 0, 2)
		acento.Size = UDim2.new(0.2, 0, 0, 2)
		productora.TextTransparency = 0
		autor.TextTransparency = 0
		pausaIntro(2.5)
		marco.Visible = false
		if not estado.IntroOmitida then
			local logo = crearLogo(capa, 220)
			logo.Position = UDim2.new(0.5, 0, 0.5, 0)
			logo.AnchorPoint = Vector2.new(0.5, 0.5)
			logo.ZIndex = 6
			pausaIntro(1.5)
		end
		return true
	end

	-- 1. Oscuridad (0.35 s).
	animar(capa, { BackgroundTransparency = 0 }, 0.35, true)
	if ui.Contenido then
		fundirSalida(ui.Contenido, 0.35)
	end
	pausaIntro(0.35)
	if ui.Contenido then
		ui.Contenido.Visible = false
	end
	-- 2. Trazo horizontal animado (0.6 s).
	animar(trazo, { Size = UDim2.new(0.62, 0, 0, 2) }, 0.6, false, Enum.EasingStyle.Quart)
	animar(acento, { Size = UDim2.new(0.22, 0, 0, 2) }, 0.8, false, Enum.EasingStyle.Quart)
	pausaIntro(0.55)
	-- 3. Aparición de HORIZON STUDIOS y BY ADRIAN (0.5 s + 0.4 s).
	productora.Position = UDim2.new(0.5, 0, 0.5, -6)
	animar(productora, { TextTransparency = 0, Position = UDim2.new(0.5, 0, 0.5, -16) }, 0.5, false)
	pausaIntro(0.35)
	animar(autor, { TextTransparency = 0 }, 0.4, true)
	-- 4. Pausa (1.1 s).
	pausaIntro(1.25)
	-- 5. Transición al logo del colegio (0.45 s + 0.5 s + 0.6 s).
	fundirSalida(marco, 0.45)
	pausaIntro(0.45)
	if not estado.IntroOmitida then
		local logo = crearLogo(capa, 220)
		logo.Position = UDim2.new(0.5, 0, 0.5, 0)
		logo.AnchorPoint = Vector2.new(0.5, 0.5)
		logo.ZIndex = 6
		local originales = prepararFundido(logo)
		fundirEntrada(originales, 0.5)
		pausaIntro(1.1)
	end
	return true
end

-- DataService fija el atributo IntroVista al cargar el perfil. Si aún no existe (perfil en carga), se espera
-- como mucho 3 s para no repetir la intro a quien ya la vio; pulsar Saltar durante la espera omite la intro.
local function esperarDatosIntro()
	local ok, valor = pcall(function()
		return player:GetAttribute("IntroVista")
	end)
	if not ok or valor ~= nil then
		return false
	end
	conectar(player:GetAttributeChangedSignal("IntroVista"), notificarCambio)
	local pulsacionesAntes = estado.Pulsaciones
	esperarHasta(function()
		return player:GetAttribute("IntroVista") ~= nil or estado.Pulsaciones > pulsacionesAntes
	end, 3)
	return player:GetAttribute("IntroVista") == nil and estado.Pulsaciones > pulsacionesAntes
end

local introMostrada = false
local okDatos, omitirIntro = pcall(esperarDatosIntro)
if not okDatos then
	omitirIntro = false
end
if not omitirIntro and not introYaVista() then
	local okIntro, resultado = pcall(reproducirIntro)
	if okIntro then
		introMostrada = resultado == true
	else
		warn(PREFIJO .. " Error en la intro: " .. tostring(resultado))
		introMostrada = true
	end
	if introMostrada then
		script:SetAttribute("IntroMostrada", true)
	end
end

---------------------------------------------------------------------------------------------------
-- Final: señal de carga lista + fundido y destrucción de la pantalla
---------------------------------------------------------------------------------------------------
estado.Fase = "final"
detenerParticulas()
desconectarTodo()

pcall(function()
	senal.Name = nombreSenal()
	senal:SetAttribute("IntroMostrada", introMostrada)
	senal:SetAttribute("AvisoRecursos", estado.Avisos == true)
	senal:SetAttribute("Progreso", estado.Progreso)
	senal:SetAttribute("Listo", true)
	senal:Fire({ IntroMostrada = introMostrada, AvisoRecursos = estado.Avisos == true })
end)

if ui.Gui and ui.Gui.Parent then
	pcall(function()
		if ui.Saltar then
			ui.Saltar.Active = false
			ui.Saltar.Selectable = false
			if GuiService.SelectedObject == ui.Saltar then
				GuiService.SelectedObject = nil
			end
		end
	end)
	local duracion = 0.5
	if movimientoReducido() then
		duracion = 0.15
	end
	for _, hijo in ipairs(ui.Gui:GetChildren()) do
		if hijo:IsA("GuiObject") then
			pcall(fundirSalida, hijo, duracion)
		end
	end
	task.delay(duracion + 0.1, function()
		pcall(function()
			ui.Gui:Destroy()
		end)
	end)
end

pcall(function()
	cambio:Destroy()
end)
