--[[
	HERRAMIENTA DE STUDIO · Copia de seguridad de scripts existentes (Command Bar, modo edición).

	Antes de instalar Colegio RP por primera vez, crea una copia de TODOS los scripts del lugar
	(incluido Adonis, ventiladores, espejo, inodoros, cortinas) en ServerStorage/ColegioRP_Respaldos/<fecha>_scripts_originales,
	con sus rutas originales en el nombre y los Scripts desactivados. Además imprime un inventario para el CHANGELOG.
	No modifica los originales. Complementa (no sustituye) a "Archivo > Guardar como…" o publicar una versión.
]]

local ServerStorage = game:GetService("ServerStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local grabacion = ChangeHistoryService:TryBeginRecording("Respaldo de scripts originales")
local respaldos = ServerStorage:FindFirstChild("ColegioRP_Respaldos") or Instance.new("Folder")
respaldos.Name = "ColegioRP_Respaldos"
respaldos.Parent = ServerStorage
local carpeta = Instance.new("Folder")
carpeta.Name = os.date("%Y-%m-%d_%H-%M-%S") .. "_scripts_originales"
carpeta.Parent = respaldos

local function ruta(inst)
	local partes = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(partes, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(partes, "/")
end

local n = 0
for _, d in ipairs(game:GetDescendants()) do
	local ok, es = pcall(function() return d:IsA("LuaSourceContainer") end)
	if ok and es and not d:IsDescendantOf(ServerStorage) then
		local r = ruta(d)
		if not r:find("^ReplicatedStorage/ColegioRP") and not r:find("^ServerScriptService/ColegioRP") and not r:find("^ReplicatedFirst/ColegioRP") and not r:find("^StarterPlayer/StarterPlayerScripts/ColegioRP") then
			local okC, copia = pcall(function() return d:Clone() end)
			if okC and copia then
				copia.Name = r:gsub("/", "·")
				if copia:IsA("BaseScript") then copia.Disabled = true end
				copia.Parent = carpeta
				n = n + 1
				print("  respaldado: " .. r)
			end
		end
	end
end

if grabacion then ChangeHistoryService:FinishRecording(grabacion, Enum.FinishRecordingOperation.Commit) end
print(string.format("[ColegioRP] %d scripts originales copiados en ServerStorage/ColegioRP_Respaldos/%s", n, carpeta.Name))
