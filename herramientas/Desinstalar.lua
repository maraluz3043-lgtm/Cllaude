--[[
	HERRAMIENTA DE STUDIO · Desinstalar Colegio RP (Command Bar, modo edición).

	Mueve las carpetas del sistema a ServerStorage/ColegioRP_Respaldos/<fecha> (desactivando sus scripts),
	borra Workspace/ColegioRP_Mapa (se regenera solo al ejecutar; no contiene geometría del colegio) y retira
	las etiquetas/atributos añadidos a objetos existentes (RoomId, PcId, PuertaId, ObjetoId, tags ColegioRP_*).
	No toca ningún otro objeto. Se puede deshacer con Ctrl+Z.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local grabacion = ChangeHistoryService:TryBeginRecording("Desinstalar Colegio RP")
local respaldos = ServerStorage:FindFirstChild("ColegioRP_Respaldos") or Instance.new("Folder")
respaldos.Name = "ColegioRP_Respaldos"
respaldos.Parent = ServerStorage
local carpeta = Instance.new("Folder")
carpeta.Name = os.date("%Y-%m-%d_%H-%M-%S") .. "_desinstalacion"
carpeta.Parent = respaldos

local movidos = 0
local objetivos = {
	{ game:GetService("ReplicatedFirst"), "ColegioRP_Carga" },
	{ game:GetService("ReplicatedStorage"), "ColegioRP" },
	{ game:GetService("ServerScriptService"), "ColegioRP" },
	{ game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"), "ColegioRP" },
}
for _, par in ipairs(objetivos) do
	local padre, nombre = par[1], par[2]
	local inst = padre and padre:FindFirstChild(nombre)
	if inst then
		local cont = Instance.new("Folder")
		cont.Name = padre.Name
		cont.Parent = carpeta
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("Script") or d:IsA("LocalScript") then d.Disabled = true end
		end
		if inst:IsA("Script") or inst:IsA("LocalScript") then inst.Disabled = true end
		inst.Parent = cont
		movidos = movidos + 1
	end
end

local mapa = workspace:FindFirstChild("ColegioRP_Mapa")
if mapa then mapa:Destroy() end

local limpiados = 0
local tags = { "ColegioRP_Asiento", "ColegioRP_PantallaPC", "ColegioRP_Puerta", "ColegioRP_Bano", "ColegioRP_Decoracion" }
for _, tag in ipairs(tags) do
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		CollectionService:RemoveTag(inst, tag)
		limpiados = limpiados + 1
	end
end
for _, d in ipairs(workspace:GetDescendants()) do
	for _, attr in ipairs({ "RoomId", "PcId", "PuertaId", "ObjetoId" }) do
		if d:GetAttribute(attr) ~= nil then d:SetAttribute(attr, nil) end
	end
end

if grabacion then ChangeHistoryService:FinishRecording(grabacion, Enum.FinishRecordingOperation.Commit) end
print(string.format("[ColegioRP] Desinstalado: %d carpetas respaldadas en ServerStorage/ColegioRP_Respaldos/%s · %d etiquetas retiradas", movidos, carpeta.Name, limpiados))
