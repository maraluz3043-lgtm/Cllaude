--[[
	Ruta en el Explorer: ServerScriptService.ColegioRP.Main
	Tipo: Script
	Arranque del servidor de Colegio RP: carga los servicios de ServerScriptService.ColegioRP.Services en el
	orden de Config.OrdenServicios (tolerante a servicios ausentes), construye el registro compartido
	{ Get, Config, Shared }, ejecuta Init y luego Start de cada servicio en pcall, publica
	ReplicatedStorage.ColegioRP.Version e imprime un resumen del arranque (servicios, mapa, advertencias).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PREFIJO = "[ColegioRP]"
local inicioClock = os.clock()
local inicioUnix = os.time()

---------------------------------------------------------------------------------------------------
-- Localización de la capa Shared
---------------------------------------------------------------------------------------------------
local RP = ReplicatedStorage:WaitForChild("ColegioRP", 30)
if not RP then
	warn(PREFIJO .. " No se encontró ReplicatedStorage.ColegioRP; el servidor no puede arrancar.")
	return
end

local Shared = RP:WaitForChild("Shared", 30)
if not Shared then
	warn(PREFIJO .. " No se encontró ReplicatedStorage.ColegioRP.Shared; el servidor no puede arrancar.")
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
-- Versión publicada (ReplicatedStorage.ColegioRP.Version, StringValue)
---------------------------------------------------------------------------------------------------
local function publicarVersion()
	local version = tostring(Config.Version or "0.0.0")
	local valor = RP:FindFirstChild("Version")
	if valor and not valor:IsA("StringValue") then
		warn(PREFIJO .. " ReplicatedStorage.ColegioRP.Version existe pero no es StringValue; se crea uno nuevo.")
		valor = nil
	end
	if not valor then
		valor = Instance.new("StringValue")
		valor.Name = "Version"
		valor.Value = version
		valor.Parent = RP
	elseif valor.Value ~= version then
		warn(PREFIJO .. " Version publicada (" .. valor.Value .. ") distinta de Config.Version (" .. version .. "); se actualiza.")
		valor.Value = version
	end
	return valor
end

local okVersion, errVersion = pcall(publicarVersion)
if not okVersion then
	warn(PREFIJO .. " No se pudo publicar la versión: " .. tostring(errVersion))
end

---------------------------------------------------------------------------------------------------
-- Carga de servicios
---------------------------------------------------------------------------------------------------
local carpetaServicios = script.Parent:FindFirstChild("Services")
if not carpetaServicios then
	carpetaServicios = script.Parent:WaitForChild("Services", 10)
end
if not carpetaServicios then
	warn(PREFIJO .. " No existe la carpeta ServerScriptService.ColegioRP.Services; no hay servicios que cargar.")
end

local servicios = {} -- nombre -> tabla del servicio
local orden = {} -- nombres cargados, en orden de arranque
local omitidos = {} -- nombres de Config.OrdenServicios que no se encontraron
local fallosCarga = {} -- nombre -> error

local function cargarServicio(nombre, modulo)
	local ok, resultado = pcall(require, modulo)
	if not ok then
		fallosCarga[nombre] = tostring(resultado)
		warn(PREFIJO .. " Error al cargar el servicio " .. nombre .. ": " .. tostring(resultado))
		return
	end
	if typeof(resultado) ~= "table" then
		fallosCarga[nombre] = "el módulo no devuelve una tabla"
		warn(PREFIJO .. " El servicio " .. nombre .. " no devuelve una tabla; se omite.")
		return
	end
	if resultado.Nombre == nil then
		resultado.Nombre = nombre
	end
	servicios[nombre] = resultado
	table.insert(orden, nombre)
end

if carpetaServicios then
	local enOrden = {}
	for _, nombre in ipairs(Config.OrdenServicios or {}) do
		enOrden[nombre] = true
		local modulo = carpetaServicios:FindFirstChild(nombre)
		if not modulo then
			table.insert(omitidos, nombre)
			warn(PREFIJO .. " Servicio no encontrado (se omite y se continúa): " .. nombre)
		elseif not modulo:IsA("ModuleScript") then
			table.insert(omitidos, nombre)
			warn(PREFIJO .. " " .. nombre .. " no es un ModuleScript; se omite.")
		else
			cargarServicio(nombre, modulo)
		end
	end
	-- Módulos presentes en la carpeta pero ausentes de Config.OrdenServicios: se cargan al final con aviso.
	for _, hijo in ipairs(carpetaServicios:GetChildren()) do
		if hijo:IsA("ModuleScript") and not enOrden[hijo.Name] then
			warn(PREFIJO .. " El servicio " .. hijo.Name .. " no está en Config.OrdenServicios; se carga al final.")
			cargarServicio(hijo.Name, hijo)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Registro compartido
---------------------------------------------------------------------------------------------------
local registro = {}
registro.Config = Config
registro.Shared = Shared
registro.Servicios = orden
registro.Version = Config.Version
registro.Arranque = { InicioClock = inicioClock, InicioUnix = inicioUnix, DuracionSeg = nil, Listo = false }

-- Devuelve la tabla del servicio por nombre (nil si no se cargó).
function registro.Get(nombre)
	return servicios[nombre]
end

-- Carga un módulo de Shared por nombre ("Config", "Util/Validate") de forma segura; nil si falla.
function registro.Modulo(ruta)
	if typeof(ruta) ~= "string" then
		return nil
	end
	local actual = Shared
	for parte in string.gmatch(ruta, "[^/%.]+") do
		if not actual then
			return nil
		end
		actual = actual:FindFirstChild(parte)
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
-- Ciclo de vida: Init de todos, luego Start de todos (cada uno en pcall)
---------------------------------------------------------------------------------------------------
local fallosInit = {}
local fallosStart = {}
local iniciados = {}

for _, nombre in ipairs(orden) do
	local servicio = servicios[nombre]
	if typeof(servicio.Init) == "function" then
		local t0 = os.clock()
		local ok, err = pcall(servicio.Init, servicio, registro)
		if not ok then
			fallosInit[nombre] = tostring(err)
			warn(PREFIJO .. " Error en " .. nombre .. ":Init(): " .. tostring(err))
		elseif os.clock() - t0 > 1 then
			warn(PREFIJO .. " " .. nombre .. ":Init() tardó " .. string.format("%.2f", os.clock() - t0) .. " s (Init no debería esperar).")
		end
	else
		servicio.registro = registro
	end
end

for _, nombre in ipairs(orden) do
	local servicio = servicios[nombre]
	if fallosInit[nombre] then
		warn(PREFIJO .. " Se omite " .. nombre .. ":Start() porque Init falló.")
	elseif typeof(servicio.Start) == "function" then
		local t0 = os.clock()
		local ok, err = pcall(servicio.Start, servicio)
		if not ok then
			fallosStart[nombre] = tostring(err)
			warn(PREFIJO .. " Error en " .. nombre .. ":Start(): " .. tostring(err))
		else
			table.insert(iniciados, nombre)
			local dt = os.clock() - t0
			if dt > 2 then
				warn(PREFIJO .. " " .. nombre .. ":Start() tardó " .. string.format("%.2f", dt) .. " s.")
			end
		end
	else
		table.insert(iniciados, nombre)
	end
end

registro.Arranque.DuracionSeg = os.clock() - inicioClock
registro.Arranque.Listo = true
pcall(function()
	RP:SetAttribute("ServidorListo", true)
	RP:SetAttribute("ServiciosIniciados", #iniciados)
end)

---------------------------------------------------------------------------------------------------
-- Resumen del arranque
---------------------------------------------------------------------------------------------------
local function resumen()
	local lineas = {}
	table.insert(lineas, "")
	table.insert(lineas, "================= Colegio RP v" .. tostring(Config.Version) .. " · " .. tostring(Config.Productora) .. " " .. tostring(Config.Autor) .. " =================")
	table.insert(lineas, string.format("Arranque completado en %.2f s%s", registro.Arranque.DuracionSeg, RunService:IsStudio() and " (Studio)" or ""))
	table.insert(lineas, string.format("Servicios iniciados: %d/%d", #iniciados, #(Config.OrdenServicios or {})))
	for _, nombre in ipairs(orden) do
		local estado = "OK"
		if fallosInit[nombre] then
			estado = "ERROR Init: " .. fallosInit[nombre]
		elseif fallosStart[nombre] then
			estado = "ERROR Start: " .. fallosStart[nombre]
		end
		table.insert(lineas, "  - " .. nombre .. " ... " .. estado)
	end
	for _, nombre in ipairs(omitidos) do
		table.insert(lineas, "  - " .. nombre .. " ... AUSENTE (pendiente de implementar)")
	end
	for nombre, err in pairs(fallosCarga) do
		table.insert(lineas, "  - " .. nombre .. " ... NO CARGADO: " .. err)
	end

	local MapService = servicios["MapService"]
	if MapService and typeof(MapService.Inventario) == "function" then
		local ok, tabla, texto = pcall(MapService.Inventario, MapService)
		if ok and typeof(tabla) == "table" then
			table.insert(lineas, "Mapa lógico:")
			table.insert(lineas, string.format("  Zonas: %d · Aulas: %d · Asientos: %d · PCs: %d · Puertas: %d/%d · Estaciones: %d · Mostradores: %d · Decoración etiquetada: %d",
				tabla.Zonas or 0, tabla.Aulas or 0, tabla.Asientos or 0, tabla.PCs or 0,
				tabla.PuertasResueltas or 0, tabla.Puertas or 0, tabla.Estaciones or 0, tabla.Mostradores or 0, tabla.Decoracion or 0))
			local advertencias = tabla.Advertencias or {}
			if #advertencias > 0 then
				table.insert(lineas, string.format("  Advertencias de MapService (%d):", #advertencias))
				for i, aviso in ipairs(advertencias) do
					if i > 20 then
						table.insert(lineas, string.format("    ... y %d más (MapService:Inventario() para ver todas)", #advertencias - 20))
						break
					end
					table.insert(lineas, "    * " .. tostring(aviso))
				end
			else
				table.insert(lineas, "  Sin advertencias de MapService.")
			end
		elseif not ok then
			table.insert(lineas, "  (No se pudo obtener el inventario del mapa: " .. tostring(tabla) .. ")")
		end
		if typeof(texto) == "string" and texto ~= "" and RunService:IsStudio() then
			table.insert(lineas, texto)
		end
	else
		table.insert(lineas, "Mapa lógico: MapService no disponible.")
	end
	table.insert(lineas, "=====================================================================================")
	print(table.concat(lineas, "\n"))
end

local okResumen, errResumen = pcall(resumen)
if not okResumen then
	warn(PREFIJO .. " No se pudo imprimir el resumen de arranque: " .. tostring(errResumen))
end
