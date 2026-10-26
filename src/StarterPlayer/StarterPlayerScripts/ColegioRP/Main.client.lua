--[[
	Ruta en el Explorer: StarterPlayer.StarterPlayerScripts.ColegioRP.Main
	Tipo: LocalScript
	Arranque del cliente de Colegio RP: espera la señal de ReplicatedFirst.ColegioRP_CargaLista (máximo 40 s),
	carga los controladores de StarterPlayerScripts.ColegioRP.Controllers en el orden de Config.OrdenControladores
	(tolerante a ausentes), construye el registro { Get, Config, Shared, UIBuilder }, ejecuta Init y Start de cada
	uno en pcall y, al final, abre el menú principal (MenuController:Abrir()).
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PREFIJO = "[ColegioRP]"
local ESPERA_SENAL_SEG = 40 -- Nunca se espera más que esto a la pantalla de carga.
local ESPERA_CARPETA_SEG = 30
local AVISO_START_LENTO_SEG = 5
local inicioClock = os.clock()

local player = Players.LocalPlayer

-- Evita un segundo arranque si el script se ejecutara dos veces en la misma sesión.
if script:GetAttribute("Arrancado") == true then
	return
end
script:SetAttribute("Arrancado", true)

---------------------------------------------------------------------------------------------------
-- Localización de la capa Shared
---------------------------------------------------------------------------------------------------
local RP = ReplicatedStorage:WaitForChild("ColegioRP", ESPERA_CARPETA_SEG)
if not RP then
	warn(PREFIJO .. " No se encontró ReplicatedStorage.ColegioRP; el cliente no puede arrancar.")
	return
end

local Shared = RP:WaitForChild("Shared", ESPERA_CARPETA_SEG)
if not Shared then
	warn(PREFIJO .. " No se encontró ReplicatedStorage.ColegioRP.Shared; el cliente no puede arrancar.")
	return
end

local okConfig, Config = pcall(function()
	return require(Shared:WaitForChild("Config", 10))
end)
if not okConfig or typeof(Config) ~= "table" then
	warn(PREFIJO .. " No se pudo cargar Shared.Config: " .. tostring(Config))
	return
end

---------------------------------------------------------------------------------------------------
-- Espera de la pantalla de carga (evento o atributo Listo; con tiempo máximo para no bloquear nunca)
---------------------------------------------------------------------------------------------------
local function nombreSenal()
	local nombre = Config.Nombres and Config.Nombres.SenalCargaLista
	if typeof(nombre) == "string" and nombre ~= "" then
		return nombre
	end
	return "ColegioRP_CargaLista"
end

local function esperarCarga()
	local limite = os.clock() + ESPERA_SENAL_SEG
	local senal = ReplicatedFirst:FindFirstChild(nombreSenal())
	if not senal then
		senal = ReplicatedFirst:FindFirstChild("ColegioRP_CargaLista")
	end
	if not senal then
		senal = ReplicatedFirst:WaitForChild(nombreSenal(), ESPERA_SENAL_SEG)
	end
	if not senal then
		warn(PREFIJO .. " No apareció ReplicatedFirst." .. nombreSenal() .. " en " .. ESPERA_SENAL_SEG .. " s; se continúa sin esperar a la carga.")
		return false
	end
	if senal:GetAttribute("Listo") == true then
		return true
	end
	local restante = limite - os.clock()
	if restante <= 0 then
		warn(PREFIJO .. " La pantalla de carga no terminó a tiempo; se continúa.")
		return false
	end

	local listo = false
	local despertador = Instance.new("BindableEvent")
	local conexiones = {}
	local function despertar()
		pcall(function()
			despertador:Fire()
		end)
	end
	table.insert(conexiones, senal:GetAttributeChangedSignal("Listo"):Connect(function()
		if senal:GetAttribute("Listo") == true then
			listo = true
			despertar()
		end
	end))
	if senal:IsA("BindableEvent") then
		table.insert(conexiones, senal.Event:Connect(function()
			listo = true
			despertar()
		end))
	end
	local vencido = false
	task.delay(restante, function()
		vencido = true
		despertar()
	end)
	while not listo and not vencido do
		if senal:GetAttribute("Listo") == true then
			listo = true
		else
			despertador.Event:Wait()
		end
	end
	for _, conexion in ipairs(conexiones) do
		conexion:Disconnect()
	end
	despertador:Destroy()
	if not listo then
		warn(PREFIJO .. " La pantalla de carga no terminó en " .. ESPERA_SENAL_SEG .. " s; se continúa.")
	end
	return listo
end

local okEspera, resultadoEspera = pcall(esperarCarga)
if not okEspera then
	warn(PREFIJO .. " Error esperando la pantalla de carga: " .. tostring(resultadoEspera))
end

---------------------------------------------------------------------------------------------------
-- UIBuilder y carpeta de controladores
---------------------------------------------------------------------------------------------------
local carpetaUI = script.Parent:FindFirstChild("UI") or script.Parent:WaitForChild("UI", 10)
local UIBuilder = nil
if carpetaUI then
	local moduloUI = carpetaUI:FindFirstChild("UIBuilder") or carpetaUI:WaitForChild("UIBuilder", 10)
	if moduloUI and moduloUI:IsA("ModuleScript") then
		local okUI, resultado = pcall(require, moduloUI)
		if okUI and typeof(resultado) == "table" then
			UIBuilder = resultado
		else
			warn(PREFIJO .. " No se pudo cargar UIBuilder: " .. tostring(resultado))
		end
	end
end
if not UIBuilder then
	warn(PREFIJO .. " UIBuilder no está disponible; los controladores con interfaz pueden fallar.")
end

local carpetaControladores = script.Parent:FindFirstChild("Controllers") or script.Parent:WaitForChild("Controllers", 10)
if not carpetaControladores then
	warn(PREFIJO .. " No existe StarterPlayerScripts.ColegioRP.Controllers; no hay controladores que cargar.")
end

local controladores = {} -- nombre -> tabla del controlador
local orden = {} -- nombres cargados, en orden de arranque
local omitidos = {}

local function cargarControlador(nombre, modulo)
	local ok, resultado = pcall(require, modulo)
	if not ok then
		warn(PREFIJO .. " " .. nombre .. ": " .. tostring(resultado))
		return
	end
	if typeof(resultado) ~= "table" then
		warn(PREFIJO .. " " .. nombre .. ": el módulo no devuelve una tabla; se omite.")
		return
	end
	if resultado.Nombre == nil then
		resultado.Nombre = nombre
	end
	controladores[nombre] = resultado
	table.insert(orden, nombre)
end

if carpetaControladores then
	local enOrden = {}
	for _, nombre in ipairs(Config.OrdenControladores or {}) do
		enOrden[nombre] = true
		local modulo = carpetaControladores:FindFirstChild(nombre)
		if not modulo then
			table.insert(omitidos, nombre)
			warn(PREFIJO .. " Controlador no encontrado (se omite y se continúa): " .. nombre)
		elseif not modulo:IsA("ModuleScript") then
			table.insert(omitidos, nombre)
			warn(PREFIJO .. " " .. nombre .. " no es un ModuleScript; se omite.")
		else
			cargarControlador(nombre, modulo)
		end
	end
	for _, hijo in ipairs(carpetaControladores:GetChildren()) do
		if hijo:IsA("ModuleScript") and not enOrden[hijo.Name] then
			warn(PREFIJO .. " El controlador " .. hijo.Name .. " no está en Config.OrdenControladores; se carga al final.")
			cargarControlador(hijo.Name, hijo)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Registro compartido
---------------------------------------------------------------------------------------------------
local registro = {}
registro.Config = Config
registro.Shared = Shared
registro.UIBuilder = UIBuilder
registro.Player = player
registro.Controladores = orden
registro.Version = Config.Version

-- Devuelve la tabla del controlador por nombre (nil si no se cargó).
function registro.Get(nombre)
	return controladores[nombre]
end

-- Carga un módulo de Shared por ruta ("UITheme", "Util/Net") de forma segura; nil si falla.
function registro.Modulo(ruta)
	if typeof(ruta) ~= "string" then
		return nil
	end
	local actual = Shared
	for parte in string.gmatch(ruta, "[^/%.]+") do
		if not actual then
			return nil
		end
		actual = actual:FindFirstChild(parte) or actual:WaitForChild(parte, 5)
	end
	if not actual or not actual:IsA("ModuleScript") then
		return nil
	end
	local ok, modulo = pcall(require, actual)
	if ok then
		return modulo
	end
	warn(PREFIJO .. " No se pudo cargar Shared." .. ruta .. ": " .. tostring(modulo))
	return nil
end

---------------------------------------------------------------------------------------------------
-- Ciclo de vida: Init de todos y luego Start de todos (cada uno en pcall)
---------------------------------------------------------------------------------------------------
local fallosInit = {}
local fallosStart = {}
local iniciados = 0

for _, nombre in ipairs(orden) do
	local controlador = controladores[nombre]
	if typeof(controlador.Init) == "function" then
		local ok, err = pcall(controlador.Init, controlador, registro)
		if not ok then
			fallosInit[nombre] = tostring(err)
			warn(PREFIJO .. " " .. nombre .. ": " .. tostring(err))
		end
	else
		controlador.registro = registro
	end
end

-- Start corre en su propio hilo: si un controlador espera (red, WaitForChild), los demás no se bloquean.
for _, nombre in ipairs(orden) do
	local controlador = controladores[nombre]
	if fallosInit[nombre] then
		warn(PREFIJO .. " " .. nombre .. ": se omite Start porque Init falló.")
	elseif typeof(controlador.Start) == "function" then
		local terminado = false
		task.spawn(function()
			local ok, err = pcall(controlador.Start, controlador)
			terminado = true
			if ok then
				iniciados = iniciados + 1
			else
				fallosStart[nombre] = tostring(err)
				warn(PREFIJO .. " " .. nombre .. ": " .. tostring(err))
			end
		end)
		if not terminado then
			task.delay(AVISO_START_LENTO_SEG, function()
				if not terminado then
					warn(PREFIJO .. " " .. nombre .. ":Start() sigue en curso tras " .. AVISO_START_LENTO_SEG .. " s.")
				end
			end)
		end
	else
		iniciados = iniciados + 1
	end
end

pcall(function()
	script:SetAttribute("ClienteListo", true)
	script:SetAttribute("Controladores", #orden)
end)

print(string.format("%s Cliente listo en %.2f s: %d controladores cargados (%d ausentes).",
	PREFIJO, os.clock() - inicioClock, #orden, #omitidos))

---------------------------------------------------------------------------------------------------
-- Menú principal tras la carga
---------------------------------------------------------------------------------------------------
local Menu = controladores["MenuController"]
if Menu and not fallosInit["MenuController"] and typeof(Menu.Abrir) == "function" then
	local ok, err = pcall(Menu.Abrir, Menu)
	if not ok then
		warn(PREFIJO .. " MenuController: " .. tostring(err))
	end
else
	-- Sin menú: se muestra el HUD directamente para no dejar al jugador sin interfaz.
	local HUD = controladores["HUDController"]
	if HUD and typeof(HUD.Visible) == "function" then
		pcall(HUD.Visible, HUD, true)
	end
end
