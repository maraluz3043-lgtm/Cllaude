--[[
	Ruta en el Explorer: ReplicatedStorage.ColegioRP.Shared.Util.Maid
	Tipo: ModuleScript
	Recolector de tareas de limpieza: acumula conexiones, instancias, funciones, hilos y objetos
	con Destroy/Disconnect/DoCleaning y los libera todos con :DoCleaning() (o :Destroy()).
	También admite claves: maid.Nombre = tarea (reemplazar una clave limpia la tarea anterior).
]]

local Maid = {}
Maid.ClassName = "Maid"

-- Libera una única tarea según su tipo. Nunca lanza: los errores se registran con warn.
local function limpiarTarea(tarea)
	local tipo = typeof(tarea)
	local ok, err = pcall(function()
		if tipo == "function" then
			tarea()
		elseif tipo == "RBXScriptConnection" then
			tarea:Disconnect()
		elseif tipo == "Instance" then
			tarea:Destroy()
		elseif tipo == "thread" then
			task.cancel(tarea)
		elseif tipo == "table" then
			if typeof(tarea.Disconnect) == "function" then
				tarea:Disconnect()
			elseif typeof(tarea.Destroy) == "function" then
				tarea:Destroy()
			elseif typeof(tarea.DoCleaning) == "function" then
				tarea:DoCleaning()
			end
		end
	end)
	if not ok then
		warn("[ColegioRP][Maid] Error al limpiar una tarea: " .. tostring(err))
	end
end

-- Crea un Maid vacío.
function Maid.new()
	local self = { _tareas = {}, _siguienteId = 0 }
	return setmetatable(self, Maid)
end

-- Comprueba si un valor es un Maid.
function Maid.Es(valor)
	return typeof(valor) == "table" and getmetatable(valor) == Maid
end

-- Acceso: métodos del Maid o tarea guardada bajo esa clave.
function Maid.__index(self, clave)
	if Maid[clave] ~= nil then
		return Maid[clave]
	end
	return rawget(self, "_tareas")[clave]
end

-- Asignación por clave: maid.Clave = tarea (nil limpia y quita la tarea).
function Maid.__newindex(self, clave, tarea)
	if Maid[clave] ~= nil then
		error("Maid: no se puede sobrescribir el método '" .. tostring(clave) .. "'", 2)
	end
	local tareas = rawget(self, "_tareas")
	local anterior = tareas[clave]
	tareas[clave] = tarea
	if anterior ~= nil and anterior ~= tarea then
		limpiarTarea(anterior)
	end
end

-- Añade una tarea y devuelve su id numérico (para quitarla luego con :Remove(id)).
function Maid:GiveTask(tarea)
	assert(tarea ~= nil, "Maid:GiveTask recibió nil")
	local tipo = typeof(tarea)
	assert(
		tipo == "function" or tipo == "RBXScriptConnection" or tipo == "Instance" or tipo == "thread" or tipo == "table",
		"Maid:GiveTask: tipo de tarea no admitido (" .. tipo .. ")"
	)
	local id = rawget(self, "_siguienteId") + 1
	rawset(self, "_siguienteId", id)
	rawget(self, "_tareas")[id] = tarea
	return id
end

Maid.Add = Maid.GiveTask

-- Atajo: crea y registra una conexión a una señal (RBXScriptSignal o Signal propio).
function Maid:Conectar(senal, fn)
	local conexion = senal:Connect(fn)
	self:GiveTask(conexion)
	return conexion
end

-- Limpia y quita la tarea con ese id o clave.
function Maid:Remove(idOClave)
	local tareas = rawget(self, "_tareas")
	local tarea = tareas[idOClave]
	if tarea ~= nil then
		tareas[idOClave] = nil
		limpiarTarea(tarea)
	end
end

-- Libera todas las tareas. El Maid queda vacío y puede reutilizarse.
function Maid:DoCleaning()
	local tareas = rawget(self, "_tareas")
	rawset(self, "_tareas", {})
	-- Primero las conexiones (evita que disparen durante la limpieza), luego el resto.
	for clave, tarea in pairs(tareas) do
		if typeof(tarea) == "RBXScriptConnection" then
			limpiarTarea(tarea)
			tareas[clave] = nil
		end
	end
	for _, tarea in pairs(tareas) do
		limpiarTarea(tarea)
	end
end

Maid.Destroy = Maid.DoCleaning

-- Número de tareas pendientes.
function Maid:Cantidad()
	local n = 0
	for _ in pairs(rawget(self, "_tareas")) do
		n = n + 1
	end
	return n
end

return Maid
