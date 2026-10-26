--[[
	Ruta: (dentro del paquete) ColegioRP_Paquete/Instalador · ModuleScript
	Instala el sistema Colegio RP en el lugar abierto en Roblox Studio (modo edición).

	Uso (Command Bar):  require(workspace.ColegioRP_Paquete.Instalador)()
	Opciones:           require(workspace.ColegioRP_Paquete.Instalador)({ SoloVerificar = true })
	                    require(workspace.ColegioRP_Paquete.Instalador)({ Desinstalar = true })

	Qué hace:
	  1. Verifica que se ejecuta en Studio y que el paquete está completo.
	  2. Respalda cualquier instalación anterior (carpetas ColegioRP y ColegioRP_Carga) en
	     ServerStorage/ColegioRP_Respaldos/<fecha-hora> (nunca se borran respaldos).
	  3. Mueve cada carpeta del paquete a su servicio: ReplicatedFirst, ReplicatedStorage,
	     ServerScriptService, StarterPlayer/StarterPlayerScripts.
	  4. No toca ningún otro objeto del lugar. Workspace/ColegioRP_Mapa lo crea el servidor al ejecutar.
	  5. Elimina el paquete y deja el resumen en Output. Todo queda en un solo paso de deshacer (Ctrl+Z).
]]

local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ServerStorage = game:GetService("ServerStorage")

local DESTINOS = {
	ReplicatedFirst = { servicio = "ReplicatedFirst", hijos = { "ColegioRP_Carga" } },
	ReplicatedStorage = { servicio = "ReplicatedStorage", hijos = { "ColegioRP" } },
	ServerScriptService = { servicio = "ServerScriptService", hijos = { "ColegioRP" } },
	StarterPlayer = { servicio = "StarterPlayer", subcarpeta = "StarterPlayerScripts", hijos = { "ColegioRP" } },
}

local function marcaTiempo()
	return os.date("%Y-%m-%d_%H-%M-%S")
end

local function contarScripts(raiz)
	local n = 0
	for _, d in ipairs(raiz:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then n = n + 1 end
	end
	return n
end

local function servicioDestino(clave)
	local info = DESTINOS[clave]
	local servicio = game:GetService(info.servicio)
	if info.subcarpeta then
		local sub = servicio:FindFirstChild(info.subcarpeta)
		if not sub then
			error("No existe " .. info.servicio .. "." .. info.subcarpeta)
		end
		return sub
	end
	return servicio
end

return function(opciones)
	opciones = opciones or {}
	assert(RunService:IsStudio(), "El instalador solo funciona en Roblox Studio (modo edición).")
	local paquete = script.Parent
	assert(paquete and paquete.Name == "ColegioRP_Paquete", "El instalador debe ejecutarse desde ColegioRP_Paquete.")

	-- 1. Verificación del paquete
	local faltantes = {}
	for clave, info in pairs(DESTINOS) do
		local carpeta = paquete:FindFirstChild(clave)
		if not carpeta then
			table.insert(faltantes, clave)
		else
			for _, hijo in ipairs(info.hijos) do
				if not carpeta:FindFirstChild(hijo) then
					table.insert(faltantes, clave .. "/" .. hijo)
				end
			end
		end
	end
	if #faltantes > 0 then
		error("Paquete incompleto; faltan: " .. table.concat(faltantes, ", "))
	end

	-- Modo desinstalar: respalda y retira la instalación actual (no toca el mapa).
	local grabacion = ChangeHistoryService:TryBeginRecording("ColegioRP " .. (opciones.Desinstalar and "desinstalar" or "instalar"))
	local respaldos = ServerStorage:FindFirstChild("ColegioRP_Respaldos")
	if not respaldos then
		respaldos = Instance.new("Folder")
		respaldos.Name = "ColegioRP_Respaldos"
		respaldos.Parent = ServerStorage
	end
	local carpetaRespaldo = nil
	local function respaldar(inst)
		if not carpetaRespaldo then
			carpetaRespaldo = Instance.new("Folder")
			carpetaRespaldo.Name = marcaTiempo()
			carpetaRespaldo.Parent = respaldos
		end
		local contenedor = carpetaRespaldo:FindFirstChild(inst.Parent.Name)
		if not contenedor then
			contenedor = Instance.new("Folder")
			contenedor.Name = inst.Parent.Name
			contenedor.Parent = carpetaRespaldo
		end
		inst.Parent = contenedor
		-- Los Scripts respaldados se desactivan para que nunca se ejecuten desde ServerStorage.
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("Script") or d:IsA("LocalScript") then d.Disabled = true end
		end
		if inst:IsA("Script") or inst:IsA("LocalScript") then inst.Disabled = true end
	end

	local resumen = { respaldados = 0, instalados = 0, scripts = 0 }

	if opciones.SoloVerificar then
		print("[ColegioRP] Paquete verificado: " .. contarScripts(paquete) .. " scripts listos para instalar.")
		if grabacion then ChangeHistoryService:FinishRecording(grabacion, Enum.FinishRecordingOperation.Cancel) end
		return true
	end

	for clave, info in pairs(DESTINOS) do
		local destino = servicioDestino(clave)
		for _, hijo in ipairs(info.hijos) do
			local existente = destino:FindFirstChild(hijo)
			if existente then
				respaldar(existente)
				resumen.respaldados = resumen.respaldados + 1
			end
		end
	end

	if not opciones.Desinstalar then
		for clave, info in pairs(DESTINOS) do
			local destino = servicioDestino(clave)
			local carpeta = paquete:FindFirstChild(clave)
			for _, hijo in ipairs(info.hijos) do
				local inst = carpeta:FindFirstChild(hijo)
				resumen.scripts = resumen.scripts + contarScripts(inst)
				inst.Parent = destino
				resumen.instalados = resumen.instalados + 1
			end
		end
	end

	local version = "?"
	local rp = game:GetService("ReplicatedStorage"):FindFirstChild("ColegioRP")
	if rp and rp:FindFirstChild("Shared") and rp.Shared:FindFirstChild("Config") then
		local okCfg, cfg = pcall(require, rp.Shared.Config)
		if okCfg and type(cfg) == "table" and cfg.Version then version = tostring(cfg.Version) end
	end

	paquete:Destroy()
	if grabacion then ChangeHistoryService:FinishRecording(grabacion, Enum.FinishRecordingOperation.Commit) end

	print("==============================================")
	if opciones.Desinstalar then
		print(" Colegio RP desinstalado. Carpetas respaldadas: " .. resumen.respaldados)
		print(" Workspace/ColegioRP_Mapa se regenera solo al ejecutar; puedes borrarlo si queda en el mapa.")
	else
		print(" Colegio RP v" .. version .. " instalado · Horizon Studios by Adrian")
		print(" Carpetas instaladas : " .. resumen.instalados .. " (" .. resumen.scripts .. " scripts)")
		print(" Versiones anteriores: " .. resumen.respaldados .. (carpetaRespaldo and (" (respaldo en ServerStorage/ColegioRP_Respaldos/" .. carpetaRespaldo.Name .. ")") or ""))
		print(" Siguiente paso      : Config (ReplicatedStorage/ColegioRP/Shared/Config) → LogoAssetId, Autorizaciones, sonidos.")
		print(" Prueba              : Play (F5) y revisa Output; el servidor imprime el inventario de zonas/aulas/puertas.")
	end
	print("==============================================")
	return true
end
