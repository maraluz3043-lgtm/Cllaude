--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Controllers.NametagController
	Tipo: ModuleScript
	Etiquetas sobre la cabeza (BillboardGui local por personaje): nombre mostrado, icono del colegio y
	abreviatura del cargo (atributo Cargo del Player, con su color). Visible a 60 studs, también la propia en
	tercera persona; se ocultan todas con el ajuste OcultarEtiquetas. Sustituye localmente la etiqueta de Roblox.
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
		error("[ColegioRP][NametagController] No apareció '" .. tostring(nombre) .. "' en " .. TIMEOUT .. " s")
	end
	return hijo
end

local RP = esperarHijo(ReplicatedStorage, "ColegioRP")
local Shared = esperarHijo(RP, "Shared")
local Util = esperarHijo(Shared, "Util")
local Config = require(esperarHijo(Shared, "Config"))
local UITheme = require(esperarHijo(Shared, "UITheme"))
local RoleDefinitions = require(esperarHijo(Shared, "RoleDefinitions"))
local Maid = require(esperarHijo(Util, "Maid"))
local Format = require(esperarHijo(Util, "Format"))
local UIBuilder = require(esperarHijo(esperarHijo(script.Parent.Parent, "UI"), "UIBuilder"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = esperarHijo(LocalPlayer, "PlayerGui")
local Colores = UITheme.Colores

local NametagController = {}
NametagController.Nombre = "NametagController"

---------------------------------------------------------------------------------------------------
-- Constantes
---------------------------------------------------------------------------------------------------
local LOG = "[ColegioRP][NametagController] "
local PREFIJO = ((Config.Nombres and Config.Nombres.PrefijoPantallas) or "ColegioRP_") .. "Etiqueta_"
local DISTANCIA_MAX = 60 -- studs
local ANCHO, ALTO = 220, 50 -- píxeles (tamaño constante en pantalla)
local DESPLAZAMIENTO = Vector3.new(0, 2.2, 0) -- sobre la cabeza
local DESPLAZAMIENTO_SIN_CABEZA = Vector3.new(0, 4.2, 0) -- sobre el HumanoidRootPart
local TAMANO_ICONO = 18
local INTERVALO_CAMARA = 0.25 -- comprobación de primera/tercera persona (no por frame)
local DISTANCIA_PRIMERA_PERSONA = 2 -- studs entre cámara y cabeza
local MAX_NOMBRE = 24

---------------------------------------------------------------------------------------------------
-- Estado
---------------------------------------------------------------------------------------------------
local activo = false
local ocultarTodas = false
local terceraPersona = true
local maid = Maid.new()
local jugadores = {} -- [Player] = { Maid, Etiqueta = { Gui, Nombre, Pastilla, TextoCargo }, Personaje }

---------------------------------------------------------------------------------------------------
-- Visibilidad
---------------------------------------------------------------------------------------------------
local function debeVerse(player)
	if ocultarTodas then
		return false
	end
	if player == LocalPlayer then
		return terceraPersona
	end
	return true
end

local function aplicarVisibilidad(player)
	local estado = jugadores[player]
	if estado and estado.Etiqueta and estado.Etiqueta.Gui and estado.Etiqueta.Gui.Parent ~= nil then
		estado.Etiqueta.Gui.Enabled = debeVerse(player)
	end
end

local function aplicarVisibilidadTodas()
	for player in pairs(jugadores) do
		aplicarVisibilidad(player)
	end
end

---------------------------------------------------------------------------------------------------
-- Contenido de la etiqueta
---------------------------------------------------------------------------------------------------
local function actualizarEtiqueta(player)
	local estado = jugadores[player]
	local etiqueta = estado and estado.Etiqueta
	if not etiqueta or not etiqueta.Gui or etiqueta.Gui.Parent == nil then
		return
	end
	local nombre = player.DisplayName
	if typeof(nombre) ~= "string" or nombre == "" then
		nombre = player.Name
	end
	etiqueta.Nombre.Text = Format.Truncar(nombre, MAX_NOMBRE)
	local cargo = player:GetAttribute("Cargo")
	local rol = RoleDefinitions.Obtener(cargo)
	if rol then
		local color = rol.Color or Colores.Gris
		etiqueta.Pastilla.Visible = true
		etiqueta.Pastilla.BackgroundColor3 = color
		etiqueta.TextoCargo.Text = RoleDefinitions.Abrev(cargo)
		etiqueta.TextoCargo.TextColor3 = UITheme.TextoSobre(color)
	else
		etiqueta.Pastilla.Visible = false
		etiqueta.TextoCargo.Text = ""
	end
	aplicarVisibilidad(player)
end

local function construirEtiqueta(player, adorno, sinCabeza)
	local gui = Instance.new("BillboardGui")
	gui.Name = PREFIJO .. tostring(player.UserId)
	gui.Adornee = adorno
	gui.Size = UDim2.new(0, ANCHO, 0, ALTO)
	if sinCabeza then
		gui.StudsOffset = DESPLAZAMIENTO_SIN_CABEZA
	else
		gui.StudsOffset = DESPLAZAMIENTO
	end
	gui.MaxDistance = DISTANCIA_MAX
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.ClipsDescendants = false
	gui.Active = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = debeVerse(player)

	local raiz = Instance.new("Frame")
	raiz.Name = "Contenido"
	raiz.BackgroundTransparency = 1
	raiz.Size = UDim2.new(1, 0, 1, 0)
	raiz.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = raiz

	-- Fila 1: icono del colegio + nombre mostrado.
	local fila = Instance.new("Frame")
	fila.Name = "FilaNombre"
	fila.BackgroundTransparency = 1
	fila.Size = UDim2.new(1, 0, 0, 24)
	fila.LayoutOrder = 1
	fila.Parent = raiz
	local layoutFila = Instance.new("UIListLayout")
	layoutFila.FillDirection = Enum.FillDirection.Horizontal
	layoutFila.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layoutFila.VerticalAlignment = Enum.VerticalAlignment.Center
	layoutFila.SortOrder = Enum.SortOrder.LayoutOrder
	layoutFila.Padding = UDim.new(0, 5)
	layoutFila.Parent = fila

	-- Logo: ImageLabel si Config.LogoAssetId > 0; si no, círculo rojo con "JP" (UIBuilder.Logo).
	UIBuilder.Logo(fila, TAMANO_ICONO, { Texto = false, LayoutOrder = 1, Nombre = "Icono" })

	local nombre = Instance.new("TextLabel")
	nombre.Name = "Nombre"
	nombre.BackgroundTransparency = 1
	nombre.Font = UITheme.Fuente("Titulo")
	nombre.TextSize = 16
	nombre.TextColor3 = Colores.Blanco
	nombre.TextStrokeColor3 = Colores.Sombra
	nombre.TextStrokeTransparency = 0.45
	nombre.AutomaticSize = Enum.AutomaticSize.X
	nombre.Size = UDim2.new(0, 0, 1, 0)
	nombre.TextXAlignment = Enum.TextXAlignment.Center
	nombre.LayoutOrder = 2
	nombre.Text = ""
	nombre.Parent = fila
	local limiteNombre = Instance.new("UISizeConstraint")
	limiteNombre.MaxSize = Vector2.new(ANCHO - TAMANO_ICONO - 10, 24)
	limiteNombre.Parent = nombre
	nombre.TextTruncate = Enum.TextTruncate.AtEnd

	-- Fila 2: pastilla con la abreviatura del cargo en su color.
	local pastilla = Instance.new("Frame")
	pastilla.Name = "Cargo"
	pastilla.BackgroundColor3 = Colores.Gris
	pastilla.BorderSizePixel = 0
	pastilla.AutomaticSize = Enum.AutomaticSize.X
	pastilla.Size = UDim2.new(0, 0, 0, 18)
	pastilla.LayoutOrder = 2
	pastilla.Visible = false
	pastilla.Parent = raiz
	local esquina = Instance.new("UICorner")
	esquina.CornerRadius = UDim.new(0.5, 0)
	esquina.Parent = pastilla
	local relleno = Instance.new("UIPadding")
	relleno.PaddingLeft = UDim.new(0, 8)
	relleno.PaddingRight = UDim.new(0, 8)
	relleno.Parent = pastilla
	local textoCargo = Instance.new("TextLabel")
	textoCargo.Name = "Abrev"
	textoCargo.BackgroundTransparency = 1
	textoCargo.Font = UITheme.Fuente("Titulo")
	textoCargo.TextSize = UITheme.Tamanos.Etiqueta
	textoCargo.TextColor3 = Colores.Blanco
	textoCargo.AutomaticSize = Enum.AutomaticSize.X
	textoCargo.Size = UDim2.new(0, 0, 1, 0)
	textoCargo.Text = ""
	textoCargo.Parent = pastilla

	gui.Parent = PlayerGui
	return { Gui = gui, Nombre = nombre, Pastilla = pastilla, TextoCargo = textoCargo }
end

---------------------------------------------------------------------------------------------------
-- Personajes
---------------------------------------------------------------------------------------------------
local function quitarEtiqueta(estado)
	if estado and estado.Etiqueta then
		UIBuilder.Destruir(estado.Etiqueta.Gui)
		estado.Etiqueta = nil
	end
	if estado and estado.MaidPersonaje then
		estado.MaidPersonaje:DoCleaning()
	end
	if estado then
		estado.Personaje = nil
	end
end

local function etiquetarPersonaje(player, personaje)
	local estado = jugadores[player]
	if not estado or not personaje then
		return
	end
	quitarEtiqueta(estado)
	estado.Personaje = personaje
	local maidPersonaje = estado.MaidPersonaje
	maidPersonaje:GiveTask(task.spawn(function()
		local cabeza = personaje:FindFirstChild("Head") or personaje:WaitForChild("Head", 10)
		local adorno = cabeza
		if not adorno then
			adorno = personaje:FindFirstChild("HumanoidRootPart") or personaje:WaitForChild("HumanoidRootPart", 5)
		end
		if not activo or estado.Personaje ~= personaje or jugadores[player] ~= estado or not adorno then
			return
		end
		-- Sustituye la etiqueta de Roblox solo localmente y solo en personajes que etiquetamos.
		local humanoide = personaje:FindFirstChildOfClass("Humanoid") or personaje:WaitForChild("Humanoid", 5)
		if humanoide then
			pcall(function()
				humanoide.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			end)
		end
		if estado.Personaje ~= personaje then
			return
		end
		local ok, etiqueta = pcall(construirEtiqueta, player, adorno, cabeza == nil)
		if not ok then
			warn(LOG .. "No se pudo crear la etiqueta de " .. player.Name .. ": " .. tostring(etiqueta))
			return
		end
		estado.Etiqueta = etiqueta
		actualizarEtiqueta(player)
		-- Si la cabeza se reemplaza (cambio de avatar), se reengancha.
		maidPersonaje:GiveTask(personaje.ChildAdded:Connect(function(hijo)
			if hijo.Name == "Head" and hijo:IsA("BasePart") and estado.Etiqueta and estado.Etiqueta.Gui then
				estado.Etiqueta.Gui.Adornee = hijo
				estado.Etiqueta.Gui.StudsOffset = DESPLAZAMIENTO
			end
		end))
	end))
end

local function agregarJugador(player)
	if jugadores[player] then
		return
	end
	local estado = { Maid = Maid.new(), MaidPersonaje = Maid.new(), Etiqueta = nil, Personaje = nil }
	jugadores[player] = estado
	estado.Maid:GiveTask(player.CharacterAdded:Connect(function(personaje)
		etiquetarPersonaje(player, personaje)
	end))
	estado.Maid:GiveTask(player.CharacterRemoving:Connect(function(personaje)
		if estado.Personaje == personaje then
			quitarEtiqueta(estado)
		end
	end))
	estado.Maid:GiveTask(player:GetAttributeChangedSignal("Cargo"):Connect(function()
		actualizarEtiqueta(player)
	end))
	estado.Maid:GiveTask(player:GetPropertyChangedSignal("DisplayName"):Connect(function()
		actualizarEtiqueta(player)
	end))
	if player.Character then
		etiquetarPersonaje(player, player.Character)
	end
end

local function quitarJugador(player)
	local estado = jugadores[player]
	if not estado then
		return
	end
	jugadores[player] = nil
	quitarEtiqueta(estado)
	estado.Maid:DoCleaning()
end

---------------------------------------------------------------------------------------------------
-- Ajuste OcultarEtiquetas (atributo local del Player y SettingsController)
---------------------------------------------------------------------------------------------------
local function fijarOcultar(valor)
	valor = valor == true
	if valor == ocultarTodas then
		return
	end
	ocultarTodas = valor
	aplicarVisibilidadTodas()
end

local function leerAjuste(registro)
	local valor = LocalPlayer:GetAttribute("OcultarEtiquetas")
	if valor ~= nil then
		return valor == true
	end
	local Settings = registro and typeof(registro.Get) == "function" and registro.Get("SettingsController")
	if Settings and typeof(Settings.Ajustes) == "function" then
		local ok, ajustes = pcall(Settings.Ajustes, Settings)
		if ok and typeof(ajustes) == "table" then
			return ajustes.OcultarEtiquetas == true
		end
	end
	return false
end

---------------------------------------------------------------------------------------------------
-- Primera / tercera persona (solo afecta a la etiqueta propia)
---------------------------------------------------------------------------------------------------
local function calcularTerceraPersona()
	if LocalPlayer.CameraMode == Enum.CameraMode.LockFirstPerson then
		return false
	end
	local camara = workspace.CurrentCamera
	local personaje = LocalPlayer.Character
	local cabeza = personaje and personaje:FindFirstChild("Head")
	if not camara or not cabeza then
		return true
	end
	return (camara.CFrame.Position - cabeza.Position).Magnitude > DISTANCIA_PRIMERA_PERSONA
end

---------------------------------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------------------------------

-- Fuerza la actualización de la etiqueta de un jugador (o de todas si no se indica).
function NametagController.Actualizar(a, b)
	local player = a
	if a == NametagController then
		player = b
	end
	if typeof(player) == "Instance" and player:IsA("Player") then
		actualizarEtiqueta(player)
		return
	end
	for jugador in pairs(jugadores) do
		actualizarEtiqueta(jugador)
	end
end

-- ¿Están ocultas todas las etiquetas por el ajuste?
function NametagController.Ocultas()
	return ocultarTodas
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------------------------------
function NametagController:Init(registro)
	self.registro = registro
end

function NametagController:Start()
	if activo then
		return
	end
	activo = true
	local registro = self.registro
	ocultarTodas = leerAjuste(registro)

	-- Limpia etiquetas huérfanas de una ejecución anterior (reconexión del script).
	for _, hijo in ipairs(PlayerGui:GetChildren()) do
		if hijo:IsA("BillboardGui") and string.sub(hijo.Name, 1, #PREFIJO) == PREFIJO then
			UIBuilder.Destruir(hijo)
		end
	end

	maid:GiveTask(LocalPlayer:GetAttributeChangedSignal("OcultarEtiquetas"):Connect(function()
		fijarOcultar(LocalPlayer:GetAttribute("OcultarEtiquetas") == true)
	end))
	local Settings = registro and typeof(registro.Get) == "function" and registro.Get("SettingsController")
	if Settings and typeof(Settings.Cambiado) == "table" and typeof(Settings.Cambiado.Connect) == "function" then
		maid:GiveTask(Settings.Cambiado:Connect(function(ajustes)
			if typeof(ajustes) == "table" and ajustes.OcultarEtiquetas ~= nil then
				fijarOcultar(ajustes.OcultarEtiquetas == true)
			end
		end))
	end

	maid:GiveTask(Players.PlayerAdded:Connect(agregarJugador))
	maid:GiveTask(Players.PlayerRemoving:Connect(quitarJugador))
	for _, player in ipairs(Players:GetPlayers()) do
		agregarJugador(player)
	end

	-- Etiqueta propia solo en tercera persona (comprobación cada 0.25 s, no por frame).
	maid:GiveTask(task.spawn(function()
		while activo do
			local ok, tercera = pcall(calcularTerceraPersona)
			if ok and tercera ~= terceraPersona then
				terceraPersona = tercera
				aplicarVisibilidad(LocalPlayer)
			end
			task.wait(INTERVALO_CAMARA)
		end
	end))
end

-- Detiene el controlador y retira todas las etiquetas.
function NametagController:Stop()
	if not activo then
		return
	end
	activo = false
	maid:DoCleaning()
	local lista = {}
	for player in pairs(jugadores) do
		table.insert(lista, player)
	end
	for _, player in ipairs(lista) do
		quitarJugador(player)
	end
end

return NametagController
